part of 'api_server.dart';

/// طلبات التوصيل (تليفون أو واتساب) وطيارين التوصيل وتوريد فلوسهم.
///
/// الطلب بيمشي: جديد ← بيتجهز ← خرج مع الطيار ← اتسلم (أو اتلغى في أي وقت قبل التسليم).
/// المخزون بيتخصم والفاتورة بتتعمل لما الطلب يتسلم للعميل. الطيار بيحصّل الفلوس وبتفضل معاه
/// لحد ما يورّدها، ووقتها بتدخل درج الكاشير اللي استلمها منه.
extension _DeliveryRoutes on BasketServer {
  void _registerDeliveryRoutes(Router r) {
    r.get('/api/drivers', _authed(_listDrivers, only: _cashStaff));
    r.post('/api/drivers', _authed(_createDriver, only: {'owner', 'supervisor'}));
    r.patch('/api/drivers/<id>', _authed(_updateDriver, only: {'owner', 'supervisor'}));
    r.get('/api/drivers/<id>/pending', _authed(_driverPending, only: _cashStaff));
    r.post('/api/drivers/<id>/settle', _authed(_settleDriver, only: _cashStaff));
    r.get('/api/drivers/<id>/settlements', _authed(_driverSettlements, only: {'owner', 'supervisor'}));

    r.get('/api/delivery', _authed(_listOrders));
    r.post('/api/delivery', _authed(_createOrder, only: _cashStaff));
    r.get('/api/delivery/<id>', _authed(_getOrder));
    r.patch('/api/delivery/<id>', _authed(_updateOrder, only: _cashStaff));
    r.post('/api/delivery/<id>/status', _authed(_changeOrderStatus));
  }

  // ================================================================ drivers

  String? _driverIdOfUser(String userId) => db.selectOne('SELECT id FROM drivers WHERE user_id = ?', [userId])?['id'] as String?;

  /// الموظف اللي صلاحيته "طيار" بيبقى طيار في قايمة التوصيل.
  void _linkDriver(String userId, String name, String? phone) {
    if (_driverIdOfUser(userId) != null) return;
    db.execute('INSERT INTO drivers(id, name, phone, user_id, active, created_at) VALUES(?, ?, ?, ?, 1, ?)', [_uuid.v4(), name, phone, userId, nowIso()]);
    _broadcast('drivers');
  }

  /// الفلوس اللي الطيار حصّلها من طلبات اتسلمت ولسه ماورّدهاش.
  int _driverOutstanding(String driverId) => db.selectOne(
        "SELECT COALESCE(SUM(collected_cents), 0) AS s FROM delivery_orders WHERE driver_id = ? AND status = 'delivered' AND settlement_id IS NULL",
        [driverId],
      )!['s'] as int;

  Map<String, Object?> _driverJson(Map<String, Object?> d) => {
        'id': d['id'],
        'name': d['name'],
        'phone': d['phone'],
        'userId': d['user_id'],
        'active': d['active'] == 1,
        'outstandingCents': _driverOutstanding(d['id'] as String),
        'openOrders': db.selectOne("SELECT COUNT(*) AS c FROM delivery_orders WHERE driver_id = ? AND status = 'out'", [d['id']])!['c'],
      };

  Object? _listDrivers(Request req, AuthUser u) {
    final all = req.url.queryParameters['all'] == '1';
    final rows = db.select('SELECT * FROM drivers ${all ? '' : 'WHERE active = 1'} ORDER BY active DESC, name');
    return {'drivers': rows.map(_driverJson).toList()};
  }

  Future<Object?> _createDriver(Request req, AuthUser u) async {
    final body = await _body(req);
    final id = _uuid.v4();
    db.execute(
      'INSERT INTO drivers(id, name, phone, active, created_at) VALUES(?, ?, ?, 1, ?)',
      [id, _requiredText(body, 'name', 'اسم الطيار'), body['phone'] == null ? null : _validPhone(body['phone']), nowIso()],
    );
    _audit(u.id, 'driver.create', 'driver', id, body['name'] as String?);
    _broadcast('drivers');
    return {'driver': _driverJson(db.selectOne('SELECT * FROM drivers WHERE id = ?', [id])!)};
  }

  Future<Object?> _updateDriver(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final d = db.selectOne('SELECT * FROM drivers WHERE id = ?', [id]);
    if (d == null) throw ApiError(404, 'الطيار ده مش موجود');
    final body = await _body(req);
    final active = body.containsKey('active') ? (body['active'] == true ? 1 : 0) : d['active'] as int;
    if (active == 0 && _driverOutstanding(id) > 0) throw ApiError(400, 'الطيار ده معاه فلوس لسه ماورّدهاش، ورّدها الأول');
    db.execute('UPDATE drivers SET name = ?, phone = ?, active = ? WHERE id = ?', [
      body.containsKey('name') ? _requiredText(body, 'name', 'اسم الطيار') : d['name'],
      body.containsKey('phone') ? (body['phone'] == null || body['phone'] == '' ? null : _validPhone(body['phone'])) : d['phone'],
      active,
      id,
    ]);
    _broadcast('drivers');
    return {'driver': _driverJson(db.selectOne('SELECT * FROM drivers WHERE id = ?', [id])!)};
  }

  Map<String, Object?> _loadDriver(String id) {
    final d = db.selectOne('SELECT * FROM drivers WHERE id = ?', [id]);
    if (d == null) throw ApiError(404, 'الطيار ده مش موجود');
    return d;
  }

  Object? _driverPending(Request req, AuthUser u) {
    final d = _loadDriver(req.params['id']!);
    final orders = db.select(
      "$_orderSelect WHERE o.driver_id = ? AND o.status = 'delivered' AND o.settlement_id IS NULL ORDER BY o.delivered_at",
      [d['id']],
    );
    return {
      'driver': _driverJson(d),
      'orders': orders.map(_orderSummary).toList(),
      'expectedCents': orders.fold<int>(0, (s, o) => s + ((o['collected_cents'] as int?) ?? 0)),
    };
  }

  /// توريد الطيار: كل الطلبات اللي سلّمها ولسه ماتوردتش، وفلوسها بتدخل درج اللي استلم.
  Future<Object?> _settleDriver(Request req, AuthUser u) async {
    final d = _loadDriver(req.params['id']!);
    final body = await _body(req);
    final result = db.transaction(() {
      final orders = db.select(
        "SELECT id, number, collected_cents FROM delivery_orders WHERE driver_id = ? AND status = 'delivered' AND settlement_id IS NULL",
        [d['id']],
      );
      if (orders.isEmpty) throw ApiError(400, 'مفيش طلبات مستنية توريد مع ${d['name']}');
      final expected = orders.fold<int>(0, (s, o) => s + ((o['collected_cents'] as int?) ?? 0));
      final counted = body['countedCents'] == null ? expected : _cents(body['countedCents'], 'المبلغ اللي اتورد');
      final id = _uuid.v4();
      final session = _openSessionId(u.id, deviceName: _deviceName(u));
      db.execute(
        'INSERT INTO driver_settlements(id, driver_id, orders_count, expected_cents, counted_cents, session_id, note, user_id, created_at) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [id, d['id'], orders.length, expected, counted, session, _optionalText(body, 'note'), u.id, nowIso()],
      );
      for (final o in orders) {
        db.execute('UPDATE delivery_orders SET settlement_id = ? WHERE id = ?', [id, o['id']]);
      }
      if (counted > 0) {
        _cashMove('driver_settlement', counted, PaymentMethod.cash,
            userId: u.id, refType: 'settlement', refId: id, note: 'توريد ${d['name']} (${orders.length} طلب)', deviceName: _deviceName(u));
      }
      return (id: id, expected: expected, counted: counted, count: orders.length);
    });
    final diff = result.counted - result.expected;
    _audit(u.id, 'driver.settle', 'driver', d['id'] as String,
        '${d['name']}: ${result.count} طلب • متوقع ${_money(result.expected)} • اتورد ${_money(result.counted)}${diff != 0 ? ' • فرق ${_money(diff)}' : ''}');
    _broadcast('delivery');
    _broadcast('drivers');
    _broadcast('cash');
    return {
      'settlementId': result.id,
      'ordersCount': result.count,
      'expectedCents': result.expected,
      'countedCents': result.counted,
      'differenceCents': diff,
    };
  }

  Object? _driverSettlements(Request req, AuthUser u) {
    final d = _loadDriver(req.params['id']!);
    final rows = db.select(
      'SELECT s.*, u.name AS user_name FROM driver_settlements s LEFT JOIN users u ON u.id = s.user_id WHERE s.driver_id = ? ORDER BY s.created_at DESC LIMIT 100',
      [d['id']],
    );
    return {
      'settlements': rows
          .map((s) => {
                'id': s['id'],
                'ordersCount': s['orders_count'],
                'expectedCents': s['expected_cents'],
                'countedCents': s['counted_cents'],
                'differenceCents': (s['counted_cents'] as int) - (s['expected_cents'] as int),
                'note': s['note'],
                'userName': s['user_name'],
                'createdAt': s['created_at'],
              })
          .toList(),
    };
  }

  // ================================================================ orders

  static const _orderSelect = '''
    SELECT o.*, c.name AS customer_name, c.phone AS customer_phone, c.whatsapp AS customer_whatsapp,
           d.name AS driver_name, d.phone AS driver_phone, u.name AS created_by_name,
           (SELECT COUNT(*) FROM delivery_items i WHERE i.order_id = o.id) AS items_count
    FROM delivery_orders o
    JOIN customers c ON c.id = o.customer_id
    LEFT JOIN drivers d ON d.id = o.driver_id
    LEFT JOIN users u ON u.id = o.created_by''';

  Map<String, Object?> _orderSummary(Map<String, Object?> o) => {
        'id': o['id'],
        'number': o['number'],
        'status': o['status'],
        'customerId': o['customer_id'],
        'customerName': o['customer_name'],
        'customerPhone': o['customer_phone'],
        'customerWhatsapp': o['customer_whatsapp'],
        'address': o['address'],
        'channel': o['channel'],
        'subtotalCents': o['subtotal_cents'],
        'deliveryFeeCents': o['delivery_fee_cents'],
        'totalCents': o['total_cents'],
        'driverId': o['driver_id'],
        'driverName': o['driver_name'],
        'driverPhone': o['driver_phone'],
        'saleId': o['sale_id'],
        'collectedCents': o['collected_cents'],
        'settled': o['settlement_id'] != null,
        'note': o['note'],
        'cancelReason': o['cancel_reason'],
        'itemsCount': o['items_count'],
        'createdBy': o['created_by_name'],
        'createdAt': o['created_at'],
        'outAt': o['out_at'],
        'deliveredAt': o['delivered_at'],
        'cancelledAt': o['cancelled_at'],
      };

  Map<String, Object?> _orderDetail(String id) {
    final o = db.selectOne('$_orderSelect WHERE o.id = ?', [id]);
    if (o == null) throw ApiError(404, 'الطلب ده مش موجود');
    final items = db.select('SELECT * FROM delivery_items WHERE order_id = ? ORDER BY rowid', [id]);
    return {
      'order': _orderSummary(o),
      'items': items
          .map((i) => {
                'id': i['id'],
                'productId': i['product_id'],
                'name': i['name'],
                'unit': i['unit'],
                'qtyMilli': i['qty_milli'],
                'unitPriceCents': i['unit_price_cents'],
                'totalCents': i['total_cents'],
              })
          .toList(),
    };
  }

  /// الطيار بيشوف الطلبات اللي معاه بس.
  Map<String, Object?> _orderFor(String id, AuthUser u) {
    final o = db.selectOne('SELECT * FROM delivery_orders WHERE id = ?', [id]);
    if (o == null) throw ApiError(404, 'الطلب ده مش موجود');
    if (u.role == 'driver' && (o['driver_id'] == null || o['driver_id'] != _driverIdOfUser(u.id))) {
      throw ApiError(403, 'الطلب ده مش معاك');
    }
    return o;
  }

  Object? _listOrders(Request req, AuthUser u) {
    final qp = req.url.queryParameters;
    final where = <String>[];
    final params = <Object?>[];
    final status = qp['status'] ?? 'open';
    if (status == 'open') {
      where.add("o.status IN ('new', 'preparing', 'out')");
    } else if (DeliveryStatus.tryParse(status) != null) {
      where.add('o.status = ?');
      params.add(status);
    }
    if (u.role == 'driver') {
      where.add('o.driver_id = ?');
      params.add(_driverIdOfUser(u.id) ?? '-');
    } else if ((qp['driverId'] ?? '').isNotEmpty) {
      where.add('o.driver_id = ?');
      params.add(qp['driverId']);
    }
    final q = (qp['q'] ?? '').trim();
    if (q.isNotEmpty) {
      final n = int.tryParse(latinDigits(q));
      final phone = normalizePhone(q);
      where.add('(c.name LIKE ? OR o.address LIKE ?${phone.length >= 3 ? ' OR c.phone_norm LIKE ?' : ''}${n != null ? ' OR o.number = ?' : ''})');
      params.addAll(['%$q%', '%$q%', if (phone.length >= 3) '%$phone%', ?n]);
    }
    if (qp['from'] != null) {
      where.add('o.created_at >= ?');
      params.add(_validDate(qp['from']));
    }
    final limit = (int.tryParse(qp['limit'] ?? '') ?? 200).clamp(1, 500);
    final rows = db.select(
      "$_orderSelect ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} "
      "ORDER BY CASE o.status WHEN 'new' THEN 0 WHEN 'preparing' THEN 1 WHEN 'out' THEN 2 ELSE 3 END, o.created_at DESC LIMIT ?",
      [...params, limit],
    );
    return {'orders': rows.map(_orderSummary).toList()};
  }

  Object? _getOrder(Request req, AuthUser u) => _orderDetail(_orderFor(req.params['id']!, u)['id'] as String);

  String? _validDriver(Object? raw) {
    if (raw == null || raw == '') return null;
    final d = db.selectOne('SELECT id FROM drivers WHERE id = ? AND active = 1', [raw]);
    if (d == null) throw ApiError(400, 'الطيار ده مش موجود');
    return raw as String;
  }

  String _validChannel(Object? raw) => deliveryChannels.containsKey(raw) ? raw as String : 'phone';

  int get _defaultDeliveryFee => int.tryParse(db.setting('delivery_fee_cents') ?? '') ?? 0;

  void _insertOrderItems(String orderId, List<_SaleLine> lines) {
    for (final l in lines) {
      db.execute(
        'INSERT INTO delivery_items(id, order_id, product_id, name, unit, qty_milli, unit_price_cents, total_cents) VALUES(?, ?, ?, ?, ?, ?, ?, ?)',
        [_uuid.v4(), orderId, l.product!['id'], l.name, l.unit, l.qty, l.price, l.total],
      );
    }
  }

  Future<Object?> _createOrder(Request req, AuthUser u) async {
    await _requireLicense();
    final body = await _body(req);
    final canDiscount = u.isManager || db.setting('cashier_can_discount') != '0';
    final lines = _parseLines(body['items'], canDiscount: canDiscount, checkStock: false);
    final address = _requiredText(body, 'address', 'العنوان');
    final fee = body['deliveryFeeCents'] == null ? _defaultDeliveryFee : _cents(body['deliveryFeeCents'], 'رسوم التوصيل');
    final driverId = _validDriver(body['driverId']);
    final subtotal = lines.fold<int>(0, (s, l) => s + l.total);
    final id = _uuid.v4();
    final now = nowIso();

    final number = db.transaction(() {
      // العميل: موجود، أو بيتعمل من الاسم والرقم. آخر عنوان بيتحفظ عليه للمرة الجاية.
      var customerId = body['customerId'] as String?;
      if (customerId != null) {
        if (db.selectOne('SELECT id FROM customers WHERE id = ?', [customerId]) == null) throw ApiError(400, 'العميل ده مش موجود');
      } else {
        final phone = _validPhone(body['phone']);
        customerId = db.selectOne('SELECT id FROM customers WHERE phone_norm = ?', [normalizePhone(phone)])?['id'] as String?;
        if (customerId == null) {
          customerId = _uuid.v4();
          db.execute(
            'INSERT INTO customers(id, name, phone, phone_norm, whatsapp, address, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)',
            [customerId, _requiredText(body, 'customerName', 'اسم العميل'), phone, normalizePhone(phone),
             body['channel'] == 'whatsapp' ? phone : null, address, now, now],
          );
        }
      }
      db.execute('UPDATE customers SET address = ?, updated_at = ? WHERE id = ?', [address, now, customerId]);
      final number = db.selectOne('SELECT COALESCE(MAX(number), 0) + 1 AS n FROM delivery_orders')!['n'] as int;
      db.execute(
        'INSERT INTO delivery_orders(id, number, customer_id, address, channel, status, subtotal_cents, delivery_fee_cents, total_cents, driver_id, note, created_by, created_at, updated_at) '
        "VALUES(?, ?, ?, ?, ?, 'new', ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, number, customerId, address, _validChannel(body['channel']), subtotal, fee, subtotal + fee, driverId, _optionalText(body, 'note'), u.id, now, now],
      );
      _insertOrderItems(id, lines);
      return number;
    });
    _audit(u.id, 'delivery.create', 'delivery', id, '#$number ${_money(subtotal + fee)}');
    _broadcast('delivery');
    _broadcast('customers');
    return _orderDetail(id);
  }

  /// تعديل الطلب قبل ما يخرج: الأصناف، والعنوان، والرسوم، والطيار.
  Future<Object?> _updateOrder(Request req, AuthUser u) async {
    final o = _orderFor(req.params['id']!, u);
    final status = DeliveryStatus.parse(o['status'] as String?);
    final body = await _body(req);
    final changesItems = body.containsKey('items') || body.containsKey('deliveryFeeCents') || body.containsKey('address');
    if (changesItems && !status.editable) throw ApiError(400, 'الطلب ده ${status.label}، مينفعش تعدّل أصنافه أو عنوانه');
    if (!status.isOpen) throw ApiError(400, 'الطلب ده ${status.label}');
    final canDiscount = u.isManager || db.setting('cashier_can_discount') != '0';
    final lines = body.containsKey('items') ? _parseLines(body['items'], canDiscount: canDiscount, checkStock: false) : null;
    final id = o['id'] as String;
    db.transaction(() {
      var subtotal = o['subtotal_cents'] as int;
      if (lines != null) {
        db.execute('DELETE FROM delivery_items WHERE order_id = ?', [id]);
        _insertOrderItems(id, lines);
        subtotal = lines.fold<int>(0, (s, l) => s + l.total);
      }
      final fee = body.containsKey('deliveryFeeCents') ? _cents(body['deliveryFeeCents'], 'رسوم التوصيل') : o['delivery_fee_cents'] as int;
      db.execute(
        'UPDATE delivery_orders SET address = ?, channel = ?, subtotal_cents = ?, delivery_fee_cents = ?, total_cents = ?, driver_id = ?, note = ?, updated_at = ? WHERE id = ?',
        [
          body.containsKey('address') ? _requiredText(body, 'address', 'العنوان') : o['address'],
          body.containsKey('channel') ? _validChannel(body['channel']) : o['channel'],
          subtotal, fee, subtotal + fee,
          body.containsKey('driverId') ? _validDriver(body['driverId']) : o['driver_id'],
          body.containsKey('note') ? _optionalText(body, 'note') : o['note'],
          nowIso(), id,
        ],
      );
    });
    _audit(u.id, 'delivery.update', 'delivery', id, '#${o['number']}');
    _broadcast('delivery');
    return _orderDetail(id);
  }

  Future<Object?> _changeOrderStatus(Request req, AuthUser u) async {
    final o = _orderFor(req.params['id']!, u);
    final body = await _body(req);
    final from = DeliveryStatus.parse(o['status'] as String?);
    final to = DeliveryStatus.tryParse(body['status'] as String?);
    if (to == null) throw ApiError(400, 'المرحلة مش صحيحة');
    if (!from.isOpen) throw ApiError(400, 'الطلب ده ${from.label} خلاص');
    if (from == to) return _orderDetail(o['id'] as String);
    // الطيار يقدر يقول اتسلم أو العميل رفض، للطلبات اللي معاه بس
    if (u.role == 'driver' && !(from == DeliveryStatus.out && (to == DeliveryStatus.delivered || to == DeliveryStatus.cancelled))) {
      throw ApiError(403, 'مش مسموحلك تعمل العملية دي');
    }
    final allowed = switch (to) {
      DeliveryStatus.preparing => from == DeliveryStatus.newOrder,
      DeliveryStatus.out => from.editable,
      DeliveryStatus.delivered => from == DeliveryStatus.out,
      DeliveryStatus.cancelled => true,
      DeliveryStatus.newOrder => false,
    };
    if (!allowed) throw ApiError(400, 'مينفعش الطلب يروح من "${from.label}" لـ "${to.label}"');
    final id = o['id'] as String;
    final now = nowIso();
    String? saleId;
    db.transaction(() {
      switch (to) {
        case DeliveryStatus.preparing:
          db.execute("UPDATE delivery_orders SET status = 'preparing', updated_at = ? WHERE id = ?", [now, id]);
        case DeliveryStatus.out:
          final driverId = body.containsKey('driverId') ? _validDriver(body['driverId']) : o['driver_id'] as String?;
          if (driverId == null) throw ApiError(400, 'اختار الطيار اللي خارج بالطلب');
          db.execute("UPDATE delivery_orders SET status = 'out', driver_id = ?, out_at = ?, updated_at = ? WHERE id = ?", [driverId, now, now, id]);
        case DeliveryStatus.delivered:
          saleId = _deliverOrder(o, u.id);
        case DeliveryStatus.cancelled:
          final reason = _optionalText(body, 'reason');
          if (reason == null) throw ApiError(400, 'اكتب سبب الإلغاء');
          db.execute("UPDATE delivery_orders SET status = 'cancelled', cancel_reason = ?, cancelled_at = ?, updated_at = ? WHERE id = ?", [reason, now, now, id]);
        case DeliveryStatus.newOrder:
          break;
      }
    });
    _audit(u.id, 'delivery.status', 'delivery', id, '#${o['number']}: من ${from.label} لـ ${to.label}');
    _broadcast('delivery');
    if (saleId != null) {
      _broadcast('sales');
      _broadcast('products');
      _broadcast('drivers');
    }
    return _orderDetail(id);
  }

  /// التسليم: فاتورة بيع على العميل (الأصناف + رسوم التوصيل) والمخزون بيتخصم.
  /// الفاتورة مدفوعة لأن الطيار حصّل، لكن الفلوس مش بتدخل أي درج غير وقت التوريد.
  String _deliverOrder(Map<String, Object?> o, String userId) {
    final items = db.select('SELECT * FROM delivery_items WHERE order_id = ? ORDER BY rowid', [o['id']]);
    final lines = <_SaleLine>[
      for (final i in items)
        (
          product: db.selectOne('SELECT * FROM products WHERE id = ?', [i['product_id']]),
          name: i['name'] as String,
          unit: i['unit'] as String,
          qty: i['qty_milli'] as int,
          price: i['unit_price_cents'] as int,
          total: i['total_cents'] as int,
        ),
      if ((o['delivery_fee_cents'] as int) > 0)
        (product: null, name: 'رسوم توصيل', unit: 'piece', qty: milli, price: o['delivery_fee_cents'] as int, total: o['delivery_fee_cents'] as int),
    ];
    final total = lines.fold<int>(0, (s, l) => s + l.total);
    final sale = _insertSale(
      lines: lines,
      customerId: o['customer_id'] as String,
      payments: const [],
      paidOverride: total,
      note: 'توصيل #${o['number']}',
      userId: userId,
      useDrawer: false,
    );
    final now = nowIso();
    db.execute(
      "UPDATE delivery_orders SET status = 'delivered', sale_id = ?, collected_cents = ?, total_cents = ?, delivered_at = ?, updated_at = ? WHERE id = ?",
      [sale.id, total, total, now, now, o['id']],
    );
    return sale.id;
  }
}
