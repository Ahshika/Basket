part of 'api_server.dart';

/// اللي بيقدروا يبيعوا ويتعاملوا مع الدرج والعملاء والمخزون.
const _cashStaff = {'owner', 'supervisor', 'cashier'};

/// العملاء، والموظفين، والشاشة الرئيسية، ودوال التحقق المشتركة بين كل المسارات.
extension _CustomerRoutes on BasketServer {
  void _registerCustomerRoutes(Router r) {
    r.get('/api/staff', _authed(_listStaff));
    r.get('/api/dashboard', _authed(_dashboard));

    r.get('/api/customers', _authed(_listCustomers, only: _cashStaff));
    r.post('/api/customers', _authed(_createCustomer, only: _cashStaff));
    r.get('/api/customers/lookup', _authed(_lookupCustomer, only: _cashStaff));
    r.get('/api/customers/<id>', _authed(_getCustomer, only: _cashStaff));
    r.patch('/api/customers/<id>', _authed(_updateCustomer, only: _cashStaff));
    r.get('/api/customers/<id>/ledger', _authed(_customerLedger, only: _cashStaff));
    r.post('/api/customers/<id>/payments', _authed(_collectFromCustomer, only: _cashStaff));
  }

  // ---------------------------------------------------------------- staff & dashboard

  Object? _listStaff(Request req, AuthUser u) {
    final rows = db.select('SELECT id, name, role FROM users WHERE active = 1 ORDER BY name');
    return {'staff': rows};
  }

  Object? _dashboard(Request req, AuthUser u) {
    final todayStart = _localDayStartUtc();
    int count(String sql, [List<Object?> params = const []]) => db.selectOne(sql, params)!.values.first as int? ?? 0;
    final result = <String, Object?>{};

    if (u.role == 'driver') {
      final driverId = _driverIdOfUser(u.id);
      result['myOpenDeliveries'] = driverId == null ? 0 : count("SELECT COUNT(*) FROM delivery_orders WHERE driver_id = ? AND status = 'out'", [driverId]);
      result['myCashCents'] = driverId == null ? 0 : _driverOutstanding(driverId);
      return result;
    }

    final sales = db.selectOne(
      'SELECT COUNT(*) AS c, COALESCE(SUM(total_cents - returned_cents), 0) AS s FROM sales WHERE created_at >= ?',
      [todayStart],
    )!;
    result['salesTodayCount'] = sales['c'];
    result['salesTodayCents'] = sales['s'];
    result['mySalesTodayCents'] = count('SELECT COALESCE(SUM(total_cents - returned_cents), 0) FROM sales WHERE created_at >= ? AND user_id = ?', [todayStart, u.id]);
    result['lowStockCount'] = count('SELECT COUNT(*) FROM products WHERE active = 1 AND track_stock = 1 AND qty_milli <= low_stock_milli');
    final today = _localToday();
    result['expiringCount'] = count(
      'SELECT COUNT(*) FROM batches b JOIN products p ON p.id = b.product_id WHERE p.active = 1 AND b.qty_milli > 0 AND b.expires_on >= ? AND b.expires_on <= ?',
      [today, _localToday(_expiryAlertDays)],
    );
    result['expiredCount'] = count(
      'SELECT COUNT(*) FROM batches b JOIN products p ON p.id = b.product_id WHERE p.active = 1 AND b.qty_milli > 0 AND b.expires_on < ?',
      [today],
    );
    result['expiryAlertDays'] = _expiryAlertDays;
    for (final s in const ['new', 'preparing', 'out']) {
      result['delivery_$s'] = count('SELECT COUNT(*) FROM delivery_orders WHERE status = ?', [s]);
    }
    if (u.isManager) {
      result['openDrawers'] = count('SELECT COUNT(*) FROM register_sessions WHERE closed_at IS NULL');
      result['driversCashCents'] = count(
        "SELECT COALESCE(SUM(collected_cents), 0) FROM delivery_orders WHERE status = 'delivered' AND settlement_id IS NULL",
      );
    }
    if (u.isOwner) {
      result['profitTodayCents'] = count(
        'SELECT COALESCE(SUM(i.total_cents - i.returned_cents - (i.cost_cents * (i.qty_milli - i.returned_milli) / 1000)), 0) '
        'FROM sale_items i JOIN sales s ON s.id = i.sale_id WHERE s.created_at >= ?',
        [todayStart],
      );
    }
    return result;
  }

  String _localDayStartUtc([int addDays = 0]) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day + addDays).toUtc().toIso8601String();
  }

  /// تاريخ النهارده (بتوقيت المحل) بشكل YYYY-MM-DD، زي تواريخ الصلاحية.
  String _localToday([int addDays = 0]) {
    final n = DateTime.now();
    return _dayKey(DateTime(n.year, n.month, n.day + addDays));
  }

  String _dayKey(DateTime d) => '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';

  // ---------------------------------------------------------------- customers

  Object? _listCustomers(Request req, AuthUser u) {
    final q = (req.url.queryParameters['q'] ?? '').trim();
    final limit = (int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 50).clamp(1, 200);
    final offset = int.tryParse(req.url.queryParameters['offset'] ?? '') ?? 0;
    final where = <String>[];
    final params = <Object?>[];
    if (q.isNotEmpty) {
      final phone = normalizePhone(q);
      where.add('(c.name LIKE ?${phone.length >= 3 ? ' OR c.phone_norm LIKE ?' : ''})');
      params.add('%$q%');
      if (phone.length >= 3) params.add('%$phone%');
    }
    final rows = db.select(
      'SELECT c.*, (SELECT MAX(s.created_at) FROM sales s WHERE s.customer_id = c.id) AS last_visit '
      'FROM customers c ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
      'ORDER BY COALESCE(last_visit, c.created_at) DESC LIMIT ? OFFSET ?',
      [...params, limit, offset],
    );
    return {'customers': rows.map((r) => {..._customerJson(r), 'balanceCents': _customerBalance(r['id'] as String)}).toList()};
  }

  Object? _lookupCustomer(Request req, AuthUser u) {
    final phone = normalizePhone(req.url.queryParameters['phone'] ?? '');
    if (phone.length < 6) return {'customer': null};
    final row = db.selectOne('SELECT * FROM customers WHERE phone_norm = ? ORDER BY updated_at DESC LIMIT 1', [phone]);
    return {'customer': row == null ? null : {..._customerJson(row), 'balanceCents': _customerBalance(row['id'] as String)}};
  }

  Object? _getCustomer(Request req, AuthUser u) {
    final row = db.selectOne('SELECT * FROM customers WHERE id = ?', [req.params['id']]);
    if (row == null) throw ApiError(404, 'العميل ده مش موجود');
    final sales = db.select('${_PosRoutes._saleSelect} WHERE s.customer_id = ? ORDER BY s.created_at DESC LIMIT 100', [row['id']]);
    final orders = db.select('${_DeliveryRoutes._orderSelect} WHERE o.customer_id = ? ORDER BY o.created_at DESC LIMIT 50', [row['id']]);
    return {
      'customer': {..._customerJson(row), 'balanceCents': _customerBalance(row['id'] as String)},
      'sales': sales.map(_saleSummary).toList(),
      'deliveries': orders.map(_orderSummary).toList(),
    };
  }

  Future<Object?> _createCustomer(Request req, AuthUser u) async {
    final body = await _body(req);
    final phone = _validPhone(body['phone']);
    final existing = db.selectOne('SELECT * FROM customers WHERE phone_norm = ?', [normalizePhone(phone)]);
    if (existing != null) {
      // نفس الرقم: بنرجع العميل الموجود، ولو مكتوب عنوان جديد بيتحفظ
      final address = _optionalText(body, 'address');
      if (address != null && address != existing['address']) {
        db.execute('UPDATE customers SET address = ?, updated_at = ? WHERE id = ?', [address, nowIso(), existing['id']]);
      }
      return {'customer': _customerJson(db.selectOne('SELECT * FROM customers WHERE id = ?', [existing['id']])!), 'existing': true};
    }
    final id = _uuid.v4();
    final now = nowIso();
    db.execute(
      'INSERT INTO customers(id, name, phone, phone_norm, whatsapp, address, notes, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [id, _requiredText(body, 'name', 'اسم العميل'), phone, normalizePhone(phone), _optionalText(body, 'whatsapp'),
       _optionalText(body, 'address'), _optionalText(body, 'notes'), now, now],
    );
    _broadcast('customers');
    return {'customer': _customerJson(db.selectOne('SELECT * FROM customers WHERE id = ?', [id])!)};
  }

  Future<Object?> _updateCustomer(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final row = db.selectOne('SELECT * FROM customers WHERE id = ?', [id]);
    if (row == null) throw ApiError(404, 'العميل ده مش موجود');
    final body = await _body(req);
    final name = body.containsKey('name') ? _requiredText(body, 'name', 'اسم العميل') : row['name'] as String;
    final phone = body.containsKey('phone') ? _validPhone(body['phone']) : row['phone'] as String;
    String? text(String key) => body.containsKey(key) ? _optionalText(body, key) : row[key] as String?;
    db.execute(
      'UPDATE customers SET name = ?, phone = ?, phone_norm = ?, whatsapp = ?, address = ?, notes = ?, updated_at = ? WHERE id = ?',
      [name, phone, normalizePhone(phone), text('whatsapp'), text('address'), text('notes'), nowIso(), id],
    );
    _audit(u.id, 'customer.update', 'customer', id, name);
    _broadcast('customers');
    return {'customer': _customerJson(db.selectOne('SELECT * FROM customers WHERE id = ?', [id])!)};
  }

  Map<String, Object?> _customerJson(Map<String, Object?> r) => {
        'id': r['id'],
        'name': r['name'],
        'phone': r['phone'],
        'whatsapp': r['whatsapp'],
        'address': r['address'],
        'notes': r['notes'],
        'createdAt': r['created_at'],
        if (r.containsKey('last_visit')) 'lastVisit': r['last_visit'],
      };

  /// اللي على العميل: فواتير آجل − اللي سدده.
  int _customerBalance(String customerId) {
    final sales = db.selectOne(
      'SELECT COALESCE(SUM(total_cents - returned_cents - paid_cents), 0) AS s FROM sales WHERE customer_id = ?', [customerId])!['s'] as int;
    final paid = db.selectOne('SELECT COALESCE(SUM(amount_cents), 0) AS s FROM customer_payments WHERE customer_id = ?', [customerId])!['s'] as int;
    return sales - paid;
  }

  Object? _customerLedger(Request req, AuthUser u) {
    final id = req.params['id']!;
    if (db.selectOne('SELECT id FROM customers WHERE id = ?', [id]) == null) throw ApiError(404, 'العميل ده مش موجود');
    final entries = <Map<String, Object?>>[
      for (final s in db.select('SELECT id, number, total_cents, paid_cents, returned_cents, created_at FROM sales WHERE customer_id = ? AND total_cents - returned_cents - paid_cents <> 0', [id]))
        {'type': 'sale', 'refId': s['id'], 'label': 'فاتورة بيع #${s['number']}', 'amountCents': (s['total_cents'] as int) - (s['returned_cents'] as int) - (s['paid_cents'] as int), 'createdAt': s['created_at']},
      for (final p in db.select('SELECT * FROM customer_payments WHERE customer_id = ?', [id]))
        {'type': 'payment', 'refId': p['id'], 'label': 'تحصيل (${PaymentMethod.parse(p['method'] as String?).label})', 'amountCents': -(p['amount_cents'] as int), 'createdAt': p['created_at'], 'note': p['note']},
    ]..sort((a, b) => (b['createdAt'] as String? ?? '').compareTo(a['createdAt'] as String? ?? ''));
    return {'balanceCents': _customerBalance(id), 'entries': entries};
  }

  Future<Object?> _collectFromCustomer(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final c = db.selectOne('SELECT * FROM customers WHERE id = ?', [id]);
    if (c == null) throw ApiError(404, 'العميل ده مش موجود');
    final body = await _body(req);
    final amount = _cents(body['amountCents'], 'المبلغ');
    if (amount <= 0) throw ApiError(400, 'اكتب المبلغ');
    final balance = _customerBalance(id);
    if (amount > balance) throw ApiError(400, 'المبلغ أكبر من اللي على العميل (${_money(balance)})');
    final method = PaymentMethod.parse(body['method'] as String?);
    final pid = _uuid.v4();
    db.transaction(() {
      db.execute(
        'INSERT INTO customer_payments(id, customer_id, amount_cents, method, note, user_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)',
        [pid, id, amount, method.name, _optionalText(body, 'note'), u.id, nowIso()],
      );
      _cashMove('customer_payment', amount, method, userId: u.id, refType: 'customer', refId: id, note: c['name'] as String);
    });
    _audit(u.id, 'customer.payment', 'customer', id, '${c['name']}: ${_money(amount)}');
    _broadcast('customers');
    _broadcast('cash');
    return {'balanceCents': _customerBalance(id)};
  }

  // ---------------------------------------------------------------- validation helpers

  String _validPhone(Object? raw) {
    final v = (raw as String? ?? '').trim();
    final digits = normalizePhone(v);
    if (digits.length < 6 || digits.length > 15) throw ApiError(400, 'رقم التليفون مش صحيح');
    return v;
  }

  int _cents(Object? raw, String label) {
    final v = raw is int ? raw : (raw is double ? raw.round() : int.tryParse('$raw'));
    if (v == null || v < 0) throw ApiError(400, '$label مش صحيح');
    if (v > 100000000000) throw ApiError(400, '$label كبير جداً');
    return v;
  }

  /// كمية بالألف (القطعة = 1000، الكيلو = 1000 جرام). لازم تكون أكبر من صفر.
  int _milli(Object? raw, {String label = 'الكمية'}) {
    final v = raw is int ? raw : null;
    if (v == null || v <= 0) throw ApiError(400, '$label مش صحيحة');
    if (v > 1000000000) throw ApiError(400, '$label كبيرة جداً');
    return v;
  }

  /// الأصناف بالقطعة ماينفعش يتباع منها نص قطعة.
  void _checkUnitQty(Map<String, Object?> product, int qtyMilli) {
    if (product['unit'] == 'piece' && qtyMilli % milli != 0) {
      throw ApiError(400, '"${product['name']}" بيتباع بالقطعة، الكمية لازم تكون رقم صحيح');
    }
  }

  String _money(int cents) {
    final pounds = cents / 100;
    return '${pounds == pounds.roundToDouble() ? pounds.toStringAsFixed(0) : pounds.toStringAsFixed(2)} ج.م';
  }

  String _qty(Map<String, Object?> product, int qtyMilli) => qtyLabel(qtyMilli, SaleUnit.parse(product['unit'] as String?));

  String? _validDate(Object? raw) {
    if (raw == null || raw == '') return null;
    final d = DateTime.tryParse('$raw');
    if (d == null) throw ApiError(400, 'التاريخ مش صحيح');
    return d.toUtc().toIso8601String();
  }

  /// تاريخ يوم بس (زي تاريخ الصلاحية) بشكل YYYY-MM-DD.
  String? _validDay(Object? raw, {String label = 'تاريخ الصلاحية'}) {
    if (raw == null || raw == '') return null;
    final v = latinDigits('$raw'.trim());
    final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(v);
    final d = m == null ? null : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    if (d == null || d.month != int.parse(m![2]!) || d.year < 2000 || d.year > 2100) throw ApiError(400, '$label مش صحيح');
    return _dayKey(d);
  }

  int get _expiryAlertDays => int.tryParse(db.setting('expiry_alert_days') ?? '') ?? 30;
}
