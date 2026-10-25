import 'package:sqlite3/sqlite3.dart';

/// قاعدة بيانات السوبر ماركت. موجودة على كمبيوتر السيرفر بس.
///
/// كل تعديل على شكل الجداول بيتضاف كـ migration جديدة في آخر [_migrations]،
/// وماينفعش نعدّل migration قديمة لأنها ممكن تكون اتنفذت عند محلات بالفعل.
class AppDb {
  AppDb._(this.raw);

  final Database raw;

  /// الجمل المجهزة بتتحفظ وتتعاد بدل ما SQLite يحللها من الأول مع كل طلب.
  final _statements = <String, PreparedStatement>{};
  static const _maxStatements = 300;

  PreparedStatement _prepared(String sql) {
    final cached = _statements.remove(sql);
    if (cached != null) return _statements[sql] = cached; // آخر واحدة اتستخدمت بتروح للآخر
    if (_statements.length >= _maxStatements) _statements.remove(_statements.keys.first)!.close();
    return _statements[sql] = raw.prepare(sql, persistent: true);
  }

  static AppDb open(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA busy_timeout = 5000;');
    db.execute('PRAGMA synchronous = NORMAL;');
    final appDb = AppDb._(db);
    appDb._migrate();
    return appDb;
  }

  void _migrate() {
    if (raw.userVersion >= _migrations.length) return;
    // بعض الـ migrations ممكن تعيد بنا جدول، فالربط بين الجداول بيتقفل لحد ما تخلص
    // وبنتأكد قبل الحفظ إن مفيش ربط اتكسر.
    raw.execute('PRAGMA foreign_keys = OFF;');
    try {
      for (var v = raw.userVersion; v < _migrations.length; v++) {
        transaction(() {
          raw.execute(_migrations[v]);
          if (raw.select('PRAGMA foreign_key_check;').isNotEmpty) throw StateError('migration v${v + 1} broke a foreign key');
          raw.userVersion = v + 1;
        });
      }
    } finally {
      raw.execute('PRAGMA foreign_keys = ON;');
    }
  }

  T transaction<T>(T Function() body) {
    raw.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      raw.execute('COMMIT');
      return result;
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  List<Map<String, Object?>> select(String sql, [List<Object?> params = const []]) =>
      _prepared(sql).select(params).map((r) => Map<String, Object?>.from(r)).toList();

  Map<String, Object?>? selectOne(String sql, [List<Object?> params = const []]) {
    final rows = select(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  /// من غير باراميترز ممكن تبقى أكتر من جملة (زي الـ migrations)، فبتتنفذ على طول.
  void execute(String sql, [List<Object?> params = const []]) =>
      params.isEmpty ? raw.execute(sql) : _prepared(sql).execute(params);

  String? setting(String key) =>
      selectOne('SELECT value FROM settings WHERE key = ?', [key])?['value'] as String?;

  void setSetting(String key, String value) => execute(
        'INSERT INTO settings(key, value) VALUES(?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );

  /// فحص سريع إن ملف قاعدة البيانات سليم ('ok' لو تمام).
  String integrity() {
    try {
      final rows = raw.select('PRAGMA quick_check;');
      final msgs = rows.map((r) => '${r.values.first}').toList();
      return msgs.length == 1 && msgs.first == 'ok' ? 'ok' : msgs.take(5).join(' | ');
    } catch (e) {
      return '$e';
    }
  }

  /// صيانة بتتعمل كل ساعة: تحسين الفهارس، وتصغير ملف الـ WAL.
  void maintenance() {
    try {
      raw.execute('PRAGMA optimize;');
      raw.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } catch (_) {}
  }

  void close() {
    for (final s in _statements.values) {
      s.close();
    }
    _statements.clear();
    raw.close();
  }
}

const _migrations = <String>[
  // v1: كل الجداول.
  // الفلوس كلها بالقروش، والكميات كلها بالألف (INTEGER): القطعة = 1000، والكيلو = 1000 جرام،
  // يعني 1.250 كيلو = 1250. كده مفيش كسور double في الحسابات خالص.
  '''
  CREATE TABLE shop (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    phone       TEXT,
    address     TEXT,
    created_at  TEXT NOT NULL
  );

  CREATE TABLE branches (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    phone       TEXT,
    address     TEXT,
    is_local    INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL
  );

  CREATE TABLE users (
    id             TEXT PRIMARY KEY,
    branch_id      TEXT REFERENCES branches(id),
    name           TEXT NOT NULL,
    username       TEXT NOT NULL UNIQUE,
    password_hash  TEXT NOT NULL,
    role           TEXT NOT NULL CHECK (role IN ('owner', 'supervisor', 'cashier', 'driver')),
    active         INTEGER NOT NULL DEFAULT 1,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
  );

  CREATE TABLE sessions (
    token_hash    TEXT PRIMARY KEY,
    user_id       TEXT NOT NULL REFERENCES users(id),
    device_name   TEXT,
    created_at    TEXT NOT NULL,
    last_seen_at  TEXT NOT NULL
  );
  CREATE INDEX idx_sessions_user ON sessions(user_id);

  CREATE TABLE settings (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
  );

  CREATE TABLE audit_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     TEXT,
    action      TEXT NOT NULL,
    entity      TEXT,
    entity_id   TEXT,
    details     TEXT,
    created_at  TEXT NOT NULL
  );
  CREATE INDEX idx_audit_created ON audit_log(created_at);

  CREATE TABLE customers (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    phone       TEXT NOT NULL,
    phone_norm  TEXT NOT NULL,
    whatsapp    TEXT,
    address     TEXT,
    notes       TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  );
  CREATE INDEX idx_customers_phone ON customers(phone_norm);
  CREATE INDEX idx_customers_name ON customers(name);

  -- الصنف بيتباع بالقطعة أو بالكيلو. السعر والتكلفة لكل قطعة أو لكل كيلو.
  -- plu: رقم الصنف على الميزان (اللي بيتطبع جوه باركود الميزان).
  CREATE TABLE products (
    id               TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    barcode          TEXT UNIQUE,
    plu              INTEGER UNIQUE,
    category         TEXT,
    unit             TEXT NOT NULL DEFAULT 'piece' CHECK (unit IN ('piece', 'kg')),
    cost_cents       INTEGER NOT NULL DEFAULT 0,
    price_cents      INTEGER NOT NULL DEFAULT 0,
    qty_milli        INTEGER NOT NULL DEFAULT 0,
    low_stock_milli  INTEGER NOT NULL DEFAULT 0,
    track_stock      INTEGER NOT NULL DEFAULT 1,
    track_expiry     INTEGER NOT NULL DEFAULT 0,
    active           INTEGER NOT NULL DEFAULT 1,
    notes            TEXT,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
  );
  CREATE INDEX idx_products_name ON products(name);
  CREATE INDEX idx_products_category ON products(category);

  CREATE TABLE suppliers (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    phone       TEXT,
    notes       TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
  );

  CREATE TABLE purchases (
    id           TEXT PRIMARY KEY,
    number       INTEGER NOT NULL UNIQUE,
    supplier_id  TEXT REFERENCES suppliers(id),
    total_cents  INTEGER NOT NULL,
    paid_cents   INTEGER NOT NULL DEFAULT 0,
    note         TEXT,
    user_id      TEXT REFERENCES users(id),
    created_at   TEXT NOT NULL
  );
  CREATE INDEX idx_purchases_supplier ON purchases(supplier_id);

  -- دفعات البضاعة بتاريخ الصلاحية: كل دخلة لصنف بيتتبع صلاحيته بتبقى دفعة لوحدها،
  -- والبيع بيسحب من الدفعة اللي هتخلص صلاحيتها الأول (FEFO). qty_milli = الباقي منها.
  CREATE TABLE batches (
    id              TEXT PRIMARY KEY,
    product_id      TEXT NOT NULL REFERENCES products(id),
    expires_on      TEXT,
    qty_milli       INTEGER NOT NULL,
    received_milli  INTEGER NOT NULL,
    cost_cents      INTEGER NOT NULL DEFAULT 0,
    purchase_id     TEXT REFERENCES purchases(id),
    created_at      TEXT NOT NULL
  );
  CREATE INDEX idx_batches_product ON batches(product_id, expires_on);
  CREATE INDEX idx_batches_expiry ON batches(expires_on);

  CREATE TABLE purchase_items (
    id               TEXT PRIMARY KEY,
    purchase_id      TEXT NOT NULL REFERENCES purchases(id),
    product_id       TEXT NOT NULL REFERENCES products(id),
    name             TEXT NOT NULL,
    qty_milli        INTEGER NOT NULL,
    unit_cost_cents  INTEGER NOT NULL,
    total_cents      INTEGER NOT NULL,
    expires_on       TEXT,
    batch_id         TEXT REFERENCES batches(id)
  );
  CREATE INDEX idx_purchase_items_purchase ON purchase_items(purchase_id);

  CREATE TABLE supplier_payments (
    id            TEXT PRIMARY KEY,
    supplier_id   TEXT NOT NULL REFERENCES suppliers(id),
    amount_cents  INTEGER NOT NULL,
    method        TEXT NOT NULL,
    note          TEXT,
    user_id       TEXT REFERENCES users(id),
    created_at    TEXT NOT NULL
  );
  CREATE INDEX idx_supplier_payments_supplier ON supplier_payments(supplier_id);

  -- cost_cents: تكلفة القطعة أو الكيلو وقت الحركة (عشان قيمة الهالك تتحسب صح).
  CREATE TABLE stock_moves (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id        TEXT NOT NULL REFERENCES products(id),
    batch_id          TEXT REFERENCES batches(id),
    qty_change_milli  INTEGER NOT NULL,
    qty_after_milli   INTEGER NOT NULL,
    cost_cents        INTEGER NOT NULL DEFAULT 0,
    reason            TEXT NOT NULL,
    ref_type          TEXT,
    ref_id            TEXT,
    note              TEXT,
    user_id           TEXT REFERENCES users(id),
    created_at        TEXT NOT NULL
  );
  CREATE INDEX idx_stock_moves_product ON stock_moves(product_id);
  CREATE INDEX idx_stock_moves_reason ON stock_moves(reason, created_at);

  -- درج كل كاشير: كل كاشير ليه وردية ودرج لوحده، فكذا جهاز يبيعوا في نفس الوقت.
  CREATE TABLE register_sessions (
    id                   TEXT PRIMARY KEY,
    branch_id            TEXT REFERENCES branches(id),
    user_id              TEXT REFERENCES users(id),
    device_name          TEXT,
    opened_by            TEXT REFERENCES users(id),
    opened_at            TEXT NOT NULL,
    opening_cash_cents   INTEGER NOT NULL DEFAULT 0,
    closed_by            TEXT REFERENCES users(id),
    closed_at            TEXT,
    expected_cash_cents  INTEGER,
    counted_cash_cents   INTEGER,
    kept_cash_cents      INTEGER,
    note                 TEXT
  );
  CREATE INDEX idx_register_open ON register_sessions(user_id, closed_at);

  CREATE TABLE sales (
    id              TEXT PRIMARY KEY,
    number          INTEGER NOT NULL UNIQUE,
    customer_id     TEXT REFERENCES customers(id),
    session_id      TEXT REFERENCES register_sessions(id),
    subtotal_cents  INTEGER NOT NULL,
    discount_cents  INTEGER NOT NULL DEFAULT 0,
    total_cents     INTEGER NOT NULL,
    paid_cents      INTEGER NOT NULL DEFAULT 0,
    returned_cents  INTEGER NOT NULL DEFAULT 0,
    note            TEXT,
    user_id         TEXT REFERENCES users(id),
    created_at      TEXT NOT NULL
  );
  CREATE INDEX idx_sales_created ON sales(created_at);
  CREATE INDEX idx_sales_customer ON sales(customer_id);
  CREATE INDEX idx_sales_session ON sales(session_id);

  -- total_cents متخزن بنفسه: في باركود الميزان اللي فيه السعر، الإجمالي هو المطبوع بالظبط.
  -- cost_cents = تكلفة القطعة أو الكيلو (من الدفعات اللي اتسحب منها).
  CREATE TABLE sale_items (
    id                TEXT PRIMARY KEY,
    sale_id           TEXT NOT NULL REFERENCES sales(id),
    product_id        TEXT REFERENCES products(id),
    name              TEXT NOT NULL,
    unit              TEXT NOT NULL DEFAULT 'piece',
    qty_milli         INTEGER NOT NULL,
    unit_price_cents  INTEGER NOT NULL,
    total_cents       INTEGER NOT NULL,
    cost_cents        INTEGER NOT NULL DEFAULT 0,
    returned_milli    INTEGER NOT NULL DEFAULT 0,
    returned_cents    INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX idx_sale_items_sale ON sale_items(sale_id);
  CREATE INDEX idx_sale_items_product ON sale_items(product_id);

  -- البيع سحب كام من كل دفعة، عشان المرتجع يرجع لنفس الدفعة بنفس الصلاحية.
  CREATE TABLE sale_item_batches (
    sale_item_id    TEXT NOT NULL REFERENCES sale_items(id),
    batch_id        TEXT NOT NULL REFERENCES batches(id),
    qty_milli       INTEGER NOT NULL,
    returned_milli  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (sale_item_id, batch_id)
  );

  -- كل فلوس داخلة أو خارجة من درج (بيع، مصروف، تحصيل دين، مرتجع، توريد طيار...)
  CREATE TABLE cash_moves (
    id            TEXT PRIMARY KEY,
    session_id    TEXT NOT NULL REFERENCES register_sessions(id),
    type          TEXT NOT NULL,
    amount_cents  INTEGER NOT NULL,
    method        TEXT NOT NULL,
    category      TEXT,
    ref_type      TEXT,
    ref_id        TEXT,
    note          TEXT,
    user_id       TEXT REFERENCES users(id),
    created_at    TEXT NOT NULL
  );
  CREATE INDEX idx_cash_moves_session ON cash_moves(session_id);
  CREATE INDEX idx_cash_moves_ref ON cash_moves(ref_type, ref_id);
  CREATE INDEX idx_cash_moves_type ON cash_moves(type, created_at);

  CREATE TABLE customer_payments (
    id            TEXT PRIMARY KEY,
    customer_id   TEXT NOT NULL REFERENCES customers(id),
    amount_cents  INTEGER NOT NULL,
    method        TEXT NOT NULL,
    note          TEXT,
    user_id       TEXT REFERENCES users(id),
    created_at    TEXT NOT NULL
  );
  CREATE INDEX idx_customer_payments_customer ON customer_payments(customer_id);

  -- طيارين التوصيل: ممكن يكون ليه حساب على البرنامج (user_id) أو يكون اسم بس.
  CREATE TABLE drivers (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    phone       TEXT,
    user_id     TEXT UNIQUE REFERENCES users(id),
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL
  );

  -- توريد الطيار: الفلوس اللي حصّلها من الطلبات بتدخل درج اللي استلمها منه.
  CREATE TABLE driver_settlements (
    id              TEXT PRIMARY KEY,
    driver_id       TEXT NOT NULL REFERENCES drivers(id),
    orders_count    INTEGER NOT NULL,
    expected_cents  INTEGER NOT NULL,
    counted_cents   INTEGER NOT NULL,
    session_id      TEXT REFERENCES register_sessions(id),
    note            TEXT,
    user_id         TEXT REFERENCES users(id),
    created_at      TEXT NOT NULL
  );
  CREATE INDEX idx_settlements_driver ON driver_settlements(driver_id, created_at);

  -- طلبات التوصيل (تليفون أو واتساب): جديد ← بيتجهز ← خرج مع الطيار ← اتسلم / اتلغى.
  -- المخزون بيتخصم والفاتورة بتتعمل لما الطلب يتسلم للعميل، والفلوس بتفضل مع الطيار لحد التوريد.
  CREATE TABLE delivery_orders (
    id                  TEXT PRIMARY KEY,
    number              INTEGER NOT NULL UNIQUE,
    customer_id         TEXT NOT NULL REFERENCES customers(id),
    address             TEXT NOT NULL,
    channel             TEXT NOT NULL DEFAULT 'phone',
    status              TEXT NOT NULL CHECK (status IN ('new', 'preparing', 'out', 'delivered', 'cancelled')),
    subtotal_cents      INTEGER NOT NULL,
    delivery_fee_cents  INTEGER NOT NULL DEFAULT 0,
    total_cents         INTEGER NOT NULL,
    driver_id           TEXT REFERENCES drivers(id),
    sale_id             TEXT REFERENCES sales(id),
    collected_cents     INTEGER,
    settlement_id       TEXT REFERENCES driver_settlements(id),
    note                TEXT,
    cancel_reason       TEXT,
    created_by          TEXT REFERENCES users(id),
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    out_at              TEXT,
    delivered_at        TEXT,
    cancelled_at        TEXT
  );
  CREATE INDEX idx_delivery_status ON delivery_orders(status, created_at);
  CREATE INDEX idx_delivery_driver ON delivery_orders(driver_id, settlement_id);

  CREATE TABLE delivery_items (
    id                TEXT PRIMARY KEY,
    order_id          TEXT NOT NULL REFERENCES delivery_orders(id),
    product_id        TEXT NOT NULL REFERENCES products(id),
    name              TEXT NOT NULL,
    unit              TEXT NOT NULL DEFAULT 'piece',
    qty_milli         INTEGER NOT NULL,
    unit_price_cents  INTEGER NOT NULL,
    total_cents       INTEGER NOT NULL
  );
  CREATE INDEX idx_delivery_items_order ON delivery_items(order_id);
  ''',
];
