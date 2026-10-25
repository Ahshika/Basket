part of 'api_server.dart';

/// الموردين، وفواتير الشرا، ودفعات الصلاحية والهالك.
extension _StockRoutes on BasketServer {
  void _registerStockRoutes(Router r) {
    r.get('/api/suppliers', _authed(_listSuppliers, only: _cashStaff));
    r.post('/api/suppliers', _authed(_createSupplier, only: _cashStaff));
    r.get('/api/suppliers/<id>', _authed(_getSupplier, only: _cashStaff));
    r.patch('/api/suppliers/<id>', _authed(_updateSupplier, only: _cashStaff));
    r.post('/api/suppliers/<id>/payments', _authed(_paySupplier, only: _cashStaff));

    r.get('/api/purchases', _authed(_listPurchases, only: _cashStaff));
    r.post('/api/purchases', _authed(_createPurchase, only: _cashStaff));
    r.get('/api/purchases/<id>', _authed(_getPurchase, only: _cashStaff));

    r.get('/api/batches/expiring', _authed(_expiringBatches, only: _cashStaff));
    r.post('/api/batches/<id>/waste', _authed(_wasteBatch, only: {'owner', 'supervisor'}));
  }

  // ================================================================ suppliers

  int _supplierBalance(String id) {
    final bought = db.selectOne('SELECT COALESCE(SUM(total_cents), 0) AS s FROM purchases WHERE supplier_id = ?', [id])!['s'] as int;
    final paidOnInvoices = db.selectOne('SELECT COALESCE(SUM(paid_cents), 0) AS s FROM purchases WHERE supplier_id = ?', [id])!['s'] as int;
    final paid = db.selectOne('SELECT COALESCE(SUM(amount_cents), 0) AS s FROM supplier_payments WHERE supplier_id = ?', [id])!['s'] as int;
    return bought - paidOnInvoices - paid;
  }

  Map<String, Object?> _supplierJson(Map<String, Object?> s) => {
        'id': s['id'],
        'name': s['name'],
        'phone': s['phone'],
        'notes': s['notes'],
        'balanceCents': _supplierBalance(s['id'] as String),
      };

  Object? _listSuppliers(Request req, AuthUser u) {
    final rows = db.select('SELECT * FROM suppliers WHERE active = 1 ORDER BY name COLLATE NOCASE');
    return {'suppliers': rows.map(_supplierJson).toList()};
  }

  Future<Object?> _createSupplier(Request req, AuthUser u) async {
    final body = await _body(req);
    final id = _uuid.v4();
    final now = nowIso();
    db.execute(
      'INSERT INTO suppliers(id, name, phone, notes, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)',
      [id, _requiredText(body, 'name', 'اسم المورد'), _optionalText(body, 'phone'), _optionalText(body, 'notes'), now, now],
    );
    _broadcast('suppliers');
    return {'supplier': _supplierJson(db.selectOne('SELECT * FROM suppliers WHERE id = ?', [id])!)};
  }

  Future<Object?> _updateSupplier(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final s = db.selectOne('SELECT * FROM suppliers WHERE id = ?', [id]);
    if (s == null) throw ApiError(404, 'المورد ده مش موجود');
    final body = await _body(req);
    db.execute(
      'UPDATE suppliers SET name = ?, phone = ?, notes = ?, active = ?, updated_at = ? WHERE id = ?',
      [
        body.containsKey('name') ? _requiredText(body, 'name', 'اسم المورد') : s['name'],
        body.containsKey('phone') ? _optionalText(body, 'phone') : s['phone'],
        body.containsKey('notes') ? _optionalText(body, 'notes') : s['notes'],
        body['active'] == false ? 0 : 1,
        nowIso(),
        id,
      ],
    );
    _broadcast('suppliers');
    return {'supplier': _supplierJson(db.selectOne('SELECT * FROM suppliers WHERE id = ?', [id])!)};
  }

  Object? _getSupplier(Request req, AuthUser u) {
    final id = req.params['id']!;
    final s = db.selectOne('SELECT * FROM suppliers WHERE id = ?', [id]);
    if (s == null) throw ApiError(404, 'المورد ده مش موجود');
    final purchases = db.select('$_purchaseSelect WHERE p.supplier_id = ? ORDER BY p.created_at DESC LIMIT 200', [id]);
    final payments = db.select(
      'SELECT sp.*, u.name AS user_name FROM supplier_payments sp LEFT JOIN users u ON u.id = sp.user_id WHERE sp.supplier_id = ? ORDER BY sp.created_at DESC',
      [id],
    );
    return {
      'supplier': _supplierJson(s),
      'purchases': purchases.map(_purchaseSummary).toList(),
      'payments': payments
          .map((p) => {'amountCents': p['amount_cents'], 'method': p['method'], 'note': p['note'], 'userName': p['user_name'], 'createdAt': p['created_at']})
          .toList(),
    };
  }

  Future<Object?> _paySupplier(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final s = db.selectOne('SELECT * FROM suppliers WHERE id = ?', [id]);
    if (s == null) throw ApiError(404, 'المورد ده مش موجود');
    final body = await _body(req);
    final amount = _cents(body['amountCents'], 'المبلغ');
    if (amount <= 0) throw ApiError(400, 'اكتب المبلغ');
    final method = PaymentMethod.parse(body['method'] as String?);
    db.transaction(() {
      db.execute(
        'INSERT INTO supplier_payments(id, supplier_id, amount_cents, method, note, user_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)',
        [_uuid.v4(), id, amount, method.name, _optionalText(body, 'note'), u.id, nowIso()],
      );
      _cashMove('supplier_payment', -amount, method, userId: u.id, refType: 'supplier', refId: id, note: s['name'] as String, deviceName: _deviceName(u));
    });
    _audit(u.id, 'supplier.payment', 'supplier', id, '${s['name']}: ${_money(amount)}');
    _broadcast('suppliers');
    _broadcast('cash');
    return {'supplier': _supplierJson(s)};
  }

  // ================================================================ purchases

  static const _purchaseSelect = '''
    SELECT p.*, s.name AS supplier_name, u.name AS user_name,
           (SELECT COUNT(*) FROM purchase_items i WHERE i.purchase_id = p.id) AS items_count
    FROM purchases p LEFT JOIN suppliers s ON s.id = p.supplier_id LEFT JOIN users u ON u.id = p.user_id''';

  Map<String, Object?> _purchaseSummary(Map<String, Object?> p) => {
        'id': p['id'],
        'number': p['number'],
        'supplierId': p['supplier_id'],
        'supplierName': p['supplier_name'],
        'totalCents': p['total_cents'],
        'paidCents': p['paid_cents'],
        'dueCents': (p['total_cents'] as int) - (p['paid_cents'] as int),
        'itemsCount': p['items_count'],
        'note': p['note'],
        'userName': p['user_name'],
        'createdAt': p['created_at'],
      };

  Object? _listPurchases(Request req, AuthUser u) {
    final rows = db.select('$_purchaseSelect ORDER BY p.created_at DESC LIMIT 200');
    return {'purchases': rows.map(_purchaseSummary).toList()};
  }

  Object? _getPurchase(Request req, AuthUser u) {
    final p = db.selectOne('$_purchaseSelect WHERE p.id = ?', [req.params['id']]);
    if (p == null) throw ApiError(404, 'الفاتورة دي مش موجودة');
    final items = db.select(
      'SELECT i.*, pr.unit FROM purchase_items i LEFT JOIN products pr ON pr.id = i.product_id WHERE i.purchase_id = ? ORDER BY i.rowid',
      [p['id']],
    );
    return {
      'purchase': _purchaseSummary(p),
      'items': items
          .map((i) => {
                'productId': i['product_id'],
                'name': i['name'],
                'unit': i['unit'] ?? 'piece',
                'qtyMilli': i['qty_milli'],
                'unitCostCents': i['unit_cost_cents'],
                'totalCents': i['total_cents'],
                'expiresOn': i['expires_on'],
              })
          .toList(),
    };
  }

  /// فاتورة شرا من مورد: البضاعة بتدخل المخزون (ولو الصنف بيتتبع صلاحيته بتبقى دفعة بتاريخها)،
  /// والمدفوع بيطلع من درج اللي سجّلها.
  Future<Object?> _createPurchase(Request req, AuthUser u) async {
    await _requireLicense();
    final body = await _body(req);
    final supplierId = body['supplierId'] as String?;
    if (supplierId != null && db.selectOne('SELECT id FROM suppliers WHERE id = ?', [supplierId]) == null) {
      throw ApiError(400, 'المورد ده مش موجود');
    }
    final items = body['items'];
    if (items is! List || items.isEmpty) throw ApiError(400, 'الفاتورة فاضية');
    final updateCost = body['updateCost'] != false;

    final plan = <({Map<String, Object?> product, int qty, int cost, int total, String? expiresOn})>[];
    var total = 0;
    for (final it in items) {
      if (it is! Map) continue;
      final p = db.selectOne('SELECT * FROM products WHERE id = ?', [it['productId']]);
      if (p == null) throw ApiError(400, 'فيه صنف مش موجود');
      final cost = _cents(it['unitCostCents'], 'سعر الشرا');
      final qty = _milli(it['qtyMilli']);
      _checkUnitQty(p, qty);
      final expiresOn = _validDay(it['expiresOn']);
      if (p['track_expiry'] == 1 && expiresOn == null) throw ApiError(400, 'اكتب تاريخ صلاحية "${p['name']}"');
      final lineCost = lineTotal(cost, qty);
      plan.add((product: p, qty: qty, cost: cost, total: lineCost, expiresOn: expiresOn));
      total += lineCost;
    }
    final paid = body['paidCents'] == null ? total : _cents(body['paidCents'], 'المدفوع');
    if (paid > total) throw ApiError(400, 'المدفوع أكبر من الفاتورة');
    if (paid < total && supplierId == null) throw ApiError(400, 'الشرا الآجل لازم يكون من مورد');
    final method = PaymentMethod.parse(body['method'] as String?);

    final id = _uuid.v4();
    final now = nowIso();
    final number = db.transaction(() {
      final number = db.selectOne('SELECT COALESCE(MAX(number), 0) + 1 AS n FROM purchases')!['n'] as int;
      db.execute(
        'INSERT INTO purchases(id, number, supplier_id, total_cents, paid_cents, note, user_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)',
        [id, number, supplierId, total, paid, _optionalText(body, 'note'), u.id, now],
      );
      for (final line in plan) {
        final p = line.product;
        final takes = _moveStock(p['id'] as String, line.qty, 'purchase',
            refType: 'purchase', refId: id, userId: u.id, note: 'فاتورة شرا #$number', expiresOn: line.expiresOn, costCents: line.cost, purchaseId: id);
        db.execute(
          'INSERT INTO purchase_items(id, purchase_id, product_id, name, qty_milli, unit_cost_cents, total_cents, expires_on, batch_id) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [_uuid.v4(), id, p['id'], p['name'], line.qty, line.cost, line.total, line.expiresOn, takes.firstOrNull?.batchId],
        );
        if (updateCost) db.execute('UPDATE products SET cost_cents = ? WHERE id = ?', [line.cost, p['id']]);
      }
      if (paid > 0) {
        _cashMove('purchase_payment', -paid, method, userId: u.id, refType: 'purchase', refId: id, note: 'شرا #$number', deviceName: _deviceName(u));
      }
      return number;
    });
    _audit(u.id, 'purchase.create', 'purchase', id, '#$number ${_money(total)}');
    _broadcast('products');
    _broadcast('suppliers');
    _broadcast('cash');
    return {'purchase': _purchaseSummary(db.selectOne('$_purchaseSelect WHERE p.id = ?', [id])!), 'number': number};
  }

  // ================================================================ expiry & waste

  static const _batchSelect =
      'SELECT b.*, p.name AS product_name, p.unit, p.barcode FROM batches b JOIN products p ON p.id = b.product_id';

  /// الدفعات اللي صلاحيتها قربت تخلص (أو خلصت) ولسه في المخزون. الأقرب الأول.
  Object? _expiringBatches(Request req, AuthUser u) {
    final days = int.tryParse(req.url.queryParameters['days'] ?? '') ?? _expiryAlertDays;
    final rows = db.select(
      '$_batchSelect WHERE p.active = 1 AND b.qty_milli > 0 AND b.expires_on IS NOT NULL AND b.expires_on <= ? ORDER BY b.expires_on, p.name LIMIT 500',
      [_localToday(days.clamp(0, 3650))],
    );
    return {'days': days, 'today': _localToday(), 'batches': rows.map((b) => _batchJson(b, showCost: u.isManager)).toList()};
  }

  /// شيل دفعة من المخزون كهالك (صلاحيتها خلصت أو باظت). القيمة بتظهر في تقرير الهالك.
  Future<Object?> _wasteBatch(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final b = db.selectOne('$_batchSelect WHERE b.id = ?', [id]);
    if (b == null) throw ApiError(404, 'الدفعة دي مش موجودة');
    final body = await _body(req);
    final qty = body['qtyMilli'] == null ? b['qty_milli'] as int : _milli(body['qtyMilli']);
    if (qty <= 0) throw ApiError(400, 'الدفعة دي فاضية');
    if (qty > (b['qty_milli'] as int)) throw ApiError(400, 'الدفعة فيها ${_qty(b, b['qty_milli'] as int)} بس');
    final reason = body['reason'] == 'damaged' ? 'damaged' : 'expired';
    db.transaction(() => _moveStock(b['product_id'] as String, -qty, reason, batchId: id, userId: u.id, note: _optionalText(body, 'note')));
    final value = (qty * (b['cost_cents'] as int) / milli).round();
    _audit(u.id, 'stock.waste', 'product', b['product_id'] as String, '${b['product_name']}: ${_qty(b, qty)} (${reason == 'expired' ? 'منتهي الصلاحية' : 'تالف'}) ${_money(value)}');
    _broadcast('products');
    return {'wasteValueCents': value, 'batch': _batchJson(db.selectOne('$_batchSelect WHERE b.id = ?', [id])!, showCost: u.isManager)};
  }
}
