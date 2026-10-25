part of 'api_server.dart';

/// أقصى عدد حركات بيظهر في شاشة الدرج (الإجماليات بتتحسب من كل الحركات).
const _cashMovesShown = 200;

/// أنواع حركات الدرج. الموجب داخل للدرج والسالب خارج.
const cashMoveTypes = {
  'sale': 'بيع',
  'sale_refund': 'مرتجع بيع',
  'customer_payment': 'تحصيل من عميل',
  'driver_settlement': 'توريد طيار',
  'expense': 'مصروف',
  'deposit': 'إيداع في الدرج',
  'withdraw': 'سحب من الدرج',
  'supplier_payment': 'دفعة لمورد',
  'purchase_payment': 'فاتورة شرا',
};

const defaultExpenseCategories = ['إيجار', 'كهرباء', 'مرتبات', 'أكياس وتغليف', 'بنزين التوصيل', 'نظافة', 'نت وتليفون', 'تصليحات للمحل', 'أخرى'];

/// درج كل كاشير: كل كاشير ليه وردية لوحده بتتفتح أول ما يبيع أو يفتحها بنفسه،
/// فكذا جهاز يبيعوا في نفس الوقت وكل واحد يقفل درجه ويتحاسب عليه لوحده.
/// صاحب المحل ومسؤول الشفت بيشوفوا كل الأدراج المفتوحة ويقدروا يقفلوا أي درج.
extension _CashRoutes on BasketServer {
  void _registerCashRoutes(Router r) {
    r.get('/api/cash/current', _authed(_cashCurrent, only: _cashStaff));
    r.post('/api/cash/open', _authed(_openCash, only: _cashStaff));
    r.post('/api/cash/moves', _authed(_addCashMove, only: _cashStaff));
    r.post('/api/cash/close', _authed(_closeOwnCash, only: _cashStaff));
    r.get('/api/cash/drawers', _authed(_openDrawers, only: {'owner', 'supervisor'}));
    r.get('/api/cash/sessions', _authed(_cashSessions, only: {'owner', 'supervisor'}));
    r.get('/api/cash/sessions/<id>', _authed(_cashSession, only: {'owner', 'supervisor'}));
    r.post('/api/cash/sessions/<id>/close', _authed(_closeAnyCash, only: {'owner', 'supervisor'}));
  }

  /// اسم الجهاز اللي الموظف داخل منه (بيتكتب على الدرج عشان يبان أنهي كاشير).
  String? _deviceName(AuthUser u) =>
      db.selectOne('SELECT device_name FROM sessions WHERE token_hash = ?', [u.tokenHash])?['device_name'] as String?;

  /// وردية [userId] المفتوحة، ولو مفيش بتتفتح واحدة جديدة بالفلوس اللي سابها في درجه آخر مرة.
  String _openSessionId(String userId, {String? deviceName, int? openingCents}) {
    final open = db.selectOne('SELECT id FROM register_sessions WHERE user_id = ? AND closed_at IS NULL ORDER BY opened_at DESC LIMIT 1', [userId]);
    if (open != null) return open['id'] as String;
    final last = db.selectOne(
      'SELECT kept_cash_cents FROM register_sessions WHERE user_id = ? AND closed_at IS NOT NULL ORDER BY closed_at DESC LIMIT 1',
      [userId],
    );
    final id = _uuid.v4();
    db.execute(
      'INSERT INTO register_sessions(id, branch_id, user_id, device_name, opened_by, opened_at, opening_cash_cents) VALUES(?, ?, ?, ?, ?, ?, ?)',
      [id, db.selectOne('SELECT id FROM branches WHERE is_local = 1 LIMIT 1')?['id'], userId, deviceName, userId, nowIso(),
       openingCents ?? last?['kept_cash_cents'] ?? 0],
    );
    return id;
  }

  void _cashMove(String type, int amount, PaymentMethod method,
      {required String userId, String? refType, String? refId, String? category, String? note, String? deviceName}) {
    db.execute(
      'INSERT INTO cash_moves(id, session_id, type, amount_cents, method, category, ref_type, ref_id, note, user_id, created_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [_uuid.v4(), _openSessionId(userId, deviceName: deviceName), type, amount, method.name, category, refType, refId, note, userId, nowIso()],
    );
  }

  Map<String, Object?> _sessionSummary(String sessionId, {bool withMoves = false}) {
    final s = db.selectOne(
      'SELECT r.*, w.name AS user_name, c.name AS closed_by_name FROM register_sessions r '
      'LEFT JOIN users w ON w.id = r.user_id LEFT JOIN users c ON c.id = r.closed_by WHERE r.id = ?',
      [sessionId],
    );
    if (s == null) throw ApiError(404, 'الوردية دي مش موجودة');
    final byMethod = <String, int>{for (final m in PaymentMethod.values) m.name: 0};
    final byType = <String, int>{};
    for (final r in db.select('SELECT type, method, SUM(amount_cents) AS s FROM cash_moves WHERE session_id = ? GROUP BY type, method', [sessionId])) {
      byMethod[r['method'] as String] = (byMethod[r['method']] ?? 0) + (r['s'] as int);
      byType[r['type'] as String] = (byType[r['type']] ?? 0) + (r['s'] as int);
    }
    final sales = db.selectOne('SELECT COUNT(*) AS c, COALESCE(SUM(total_cents - returned_cents), 0) AS s FROM sales WHERE session_id = ?', [sessionId])!;
    final opening = s['opening_cash_cents'] as int;
    return {
      'id': s['id'],
      'userId': s['user_id'],
      'userName': s['user_name'],
      'deviceName': s['device_name'],
      'openedAt': s['opened_at'],
      'closedAt': s['closed_at'],
      'closedBy': s['closed_by_name'],
      'openingCashCents': opening,
      'byMethod': byMethod,
      'byType': byType,
      'salesCount': sales['c'],
      'salesCents': sales['s'],
      'expectedCashCents': s['closed_at'] == null ? opening + byMethod['cash']! : s['expected_cash_cents'],
      'countedCashCents': s['counted_cash_cents'],
      'keptCashCents': s['kept_cash_cents'],
      'differenceCents': s['counted_cash_cents'] == null ? null : (s['counted_cash_cents'] as int) - (s['expected_cash_cents'] as int),
      'note': s['note'],
      // آخر الحركات بس: لو الوردية ما اتقفلتش أيام، الحركات بتبقى بالآلاف
      if (withMoves) 'movesCount': db.selectOne('SELECT COUNT(*) AS c FROM cash_moves WHERE session_id = ?', [sessionId])!['c'],
      if (withMoves)
        'moves': db
            .select('SELECT m.*, u.name AS user_name FROM cash_moves m LEFT JOIN users u ON u.id = m.user_id WHERE m.session_id = ? '
                'ORDER BY m.created_at DESC LIMIT $_cashMovesShown', [sessionId])
            .map((m) => {
                  'id': m['id'],
                  'type': m['type'],
                  'amountCents': m['amount_cents'],
                  'method': m['method'],
                  'category': m['category'],
                  'refType': m['ref_type'],
                  'refId': m['ref_id'],
                  'note': m['note'],
                  'userName': m['user_name'],
                  'createdAt': m['created_at'],
                })
            .toList(),
    };
  }

  Object? _cashCurrent(Request req, AuthUser u) {
    final id = db.transaction(() => _openSessionId(u.id, deviceName: _deviceName(u)));
    return {'session': _sessionSummary(id, withMoves: true), 'expenseCategories': defaultExpenseCategories};
  }

  /// فتح الوردية بفكة البداية اللي الكاشير استلمها.
  Future<Object?> _openCash(Request req, AuthUser u) async {
    final body = await _body(req);
    final opening = _cents(body['openingCashCents'], 'فكة البداية');
    final id = db.transaction(() {
      if (db.selectOne('SELECT id FROM register_sessions WHERE user_id = ? AND closed_at IS NULL', [u.id]) != null) {
        throw ApiError(409, 'ورديتك مفتوحة بالفعل');
      }
      return _openSessionId(u.id, deviceName: _deviceName(u), openingCents: opening);
    });
    _audit(u.id, 'cash.open', 'cash', id, 'فكة ${_money(opening)}');
    _broadcast('cash');
    return {'session': _sessionSummary(id, withMoves: true)};
  }

  Future<Object?> _addCashMove(Request req, AuthUser u) async {
    final body = await _body(req);
    final type = body['type'];
    if (!const {'expense', 'deposit', 'withdraw'}.contains(type)) throw ApiError(400, 'نوع الحركة مش صحيح');
    final amount = _cents(body['amountCents'], 'المبلغ');
    if (amount <= 0) throw ApiError(400, 'اكتب المبلغ');
    if (type == 'withdraw' && !u.isOwner) throw ApiError(403, 'السحب من الدرج لصاحب المحل بس');
    final note = _optionalText(body, 'note');
    if (type == 'expense' && note == null && _optionalText(body, 'category') == null) throw ApiError(400, 'اكتب المصروف ده إيه');
    final id = db.transaction(() {
      _cashMove(type as String, type == 'deposit' ? amount : -amount, PaymentMethod.parse(body['method'] as String?),
          userId: u.id, category: _optionalText(body, 'category'), note: note, deviceName: _deviceName(u));
      return _openSessionId(u.id);
    });
    _audit(u.id, 'cash.$type', 'cash', null, '${_money(amount)} ${note ?? body['category'] ?? ''}');
    _broadcast('cash');
    // الشاشة بتعيد تحميل الدرج لوحدها، فمش لازم نبعت الحركات كلها هنا
    return {'session': _sessionSummary(id)};
  }

  Future<Object?> _closeOwnCash(Request req, AuthUser u) async {
    final body = await _body(req);
    final id = db.selectOne('SELECT id FROM register_sessions WHERE user_id = ? AND closed_at IS NULL', [u.id])?['id'] as String?;
    if (id == null) throw ApiError(400, 'مفيش وردية مفتوحة ليك');
    return _closeSession(id, body, u);
  }

  Future<Object?> _closeAnyCash(Request req, AuthUser u) async => _closeSession(req.params['id']!, await _body(req), u);

  Object? _closeSession(String id, Map<String, dynamic> body, AuthUser u) {
    final counted = _cents(body['countedCashCents'], 'النقدية اللي في الدرج');
    final kept = body['keptCashCents'] == null ? counted : _cents(body['keptCashCents'], 'اللي هيفضل في الدرج');
    if (kept > counted) throw ApiError(400, 'اللي هيفضل في الدرج أكبر من اللي اتعد');
    final summary = _sessionSummary(id);
    if (summary['closedAt'] != null) throw ApiError(400, 'الوردية دي اتقفلت قبل كده');
    final expected = summary['expectedCashCents'] as int;
    db.execute(
      'UPDATE register_sessions SET closed_by = ?, closed_at = ?, expected_cash_cents = ?, counted_cash_cents = ?, kept_cash_cents = ?, note = ? '
      'WHERE id = ? AND closed_at IS NULL',
      [u.id, nowIso(), expected, counted, kept, _optionalText(body, 'note'), id],
    );
    final diff = counted - expected;
    _audit(u.id, 'cash.close', 'cash', id,
        '${summary['userName'] ?? ''}: متوقع ${_money(expected)} • اتعد ${_money(counted)}${diff != 0 ? ' • فرق ${_money(diff)}' : ''}');
    _broadcast('cash');
    return {'closed': _sessionSummary(id)};
  }

  /// كل الأدراج المفتوحة دلوقتي، وفلوس التوصيل اللي لسه مع الطيارين.
  Object? _openDrawers(Request req, AuthUser u) {
    final rows = db.select('SELECT id FROM register_sessions WHERE closed_at IS NULL ORDER BY opened_at');
    final drawers = rows.map((r) => _sessionSummary(r['id'] as String)).toList();
    return {
      'drawers': drawers,
      'totalExpectedCashCents': drawers.fold<int>(0, (s, d) => s + (d['expectedCashCents'] as int)),
      'drivers': [
        for (final d in db.select('SELECT * FROM drivers WHERE active = 1 ORDER BY name'))
          if (_driverOutstanding(d['id'] as String) > 0) {'id': d['id'], 'name': d['name'], 'outstandingCents': _driverOutstanding(d['id'] as String)},
      ],
    };
  }

  Object? _cashSessions(Request req, AuthUser u) {
    final userId = req.url.queryParameters['userId'];
    final rows = (userId ?? '').isEmpty
        ? db.select('SELECT id FROM register_sessions ORDER BY opened_at DESC LIMIT 100')
        : db.select('SELECT id FROM register_sessions WHERE user_id = ? ORDER BY opened_at DESC LIMIT 100', [userId]);
    return {'sessions': rows.map((r) => _sessionSummary(r['id'] as String)).toList()};
  }

  Object? _cashSession(Request req, AuthUser u) => {'session': _sessionSummary(req.params['id']!, withMoves: true)};
}
