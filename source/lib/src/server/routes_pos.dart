part of 'api_server.dart';

/// اتسحب كام من أنهي دفعة، وبتكلفة كام (للقطعة أو الكيلو). batchId = null لو الصنف مش بيتتبع صلاحيته.
typedef _Take = ({String? batchId, int qty, int cost});

/// سطر في فاتورة: product = null لسطر من غير مخزون (زي رسوم التوصيل).
typedef _SaleLine = ({Map<String, Object?>? product, String name, String unit, int qty, int price, int total});

/// أسباب حركة المخزون اللي بتتسجل في الجرد اليدوي.
const _adjustReasons = {'purchase', 'count', 'damaged', 'expired', 'lost', 'return_supplier', 'other'};

extension _PosRoutes on BasketServer {
  void _registerPosRoutes(Router r) {
    r.get('/api/products', _authed(_listProducts));
    r.get('/api/products/lookup', _authed(_lookupProduct));
    r.get('/api/products/categories', _authed(_productCategories));
    r.post('/api/products', _authed(_createProduct, only: _cashStaff));
    r.post('/api/products/barcode', _authed((req, u) => {'barcode': _newBarcode()}, only: _cashStaff));
    r.post('/api/products/import', _authed(_importProducts, only: {'owner'}));
    r.patch('/api/products/<id>', _authed(_updateProduct, only: _cashStaff));
    r.post('/api/products/<id>/adjust', _authed(_adjustStock, only: _cashStaff));
    r.get('/api/products/<id>/moves', _authed(_productMoves, only: _cashStaff));
    r.get('/api/products/<id>/batches', _authed(_productBatches, only: _cashStaff));

    r.post('/api/sales', _authed(_createSale, only: _cashStaff));
    r.get('/api/sales', _authed(_listSales, only: _cashStaff));
    r.get('/api/sales/<id>', _authed(_getSale, only: _cashStaff));
    r.post('/api/sales/<id>/return', _authed(_returnSale, only: _cashStaff));
  }

  // ================================================================ products

  static const _productSelect =
      'SELECT p.*, (SELECT MIN(b.expires_on) FROM batches b WHERE b.product_id = p.id AND b.qty_milli > 0) AS next_expiry FROM products p';

  Map<String, Object?> _productJson(Map<String, Object?> p) => {
        'id': p['id'],
        'name': p['name'],
        'barcode': p['barcode'],
        'plu': p['plu'],
        'category': p['category'],
        'unit': p['unit'],
        'costCents': p['cost_cents'],
        'priceCents': p['price_cents'],
        'qtyMilli': p['qty_milli'],
        'lowStockMilli': p['low_stock_milli'],
        'trackStock': p['track_stock'] == 1,
        'trackExpiry': p['track_expiry'] == 1,
        'nextExpiry': p['next_expiry'],
        'active': p['active'] == 1,
        'notes': p['notes'],
        'updatedAt': p['updated_at'],
      };

  Map<String, Object?> _loadProduct(String id) {
    final p = db.selectOne('$_productSelect WHERE p.id = ?', [id]);
    if (p == null) throw ApiError(404, 'الصنف ده مش موجود');
    return p;
  }

  Object? _listProducts(Request req, AuthUser u) {
    final qp = req.url.queryParameters;
    final q = (qp['q'] ?? '').trim();
    final where = <String>['p.active = 1'];
    final params = <Object?>[];
    if (q.isNotEmpty) {
      final plu = int.tryParse(latinDigits(q));
      where.add('(p.name LIKE ? OR p.barcode = ? OR p.category LIKE ?${plu != null ? ' OR p.plu = ?' : ''})');
      params.addAll(['%$q%', latinDigits(q), '%$q%', ?plu]);
    }
    if ((qp['category'] ?? '').isNotEmpty) {
      where.add('p.category = ?');
      params.add(qp['category']);
    }
    if (qp['low'] == '1') where.add('p.track_stock = 1 AND p.qty_milli <= p.low_stock_milli');
    if (qp['inactive'] == '1') where[0] = 'p.active = 0';
    final limit = (int.tryParse(qp['limit'] ?? '') ?? 100).clamp(1, 500);
    final offset = int.tryParse(qp['offset'] ?? '') ?? 0;
    final rows = db.select(
      '$_productSelect WHERE ${where.join(' AND ')} ORDER BY p.name COLLATE NOCASE LIMIT ? OFFSET ?',
      [...params, limit, offset],
    );
    final totals = db.selectOne(
      'SELECT COUNT(*) AS c, COALESCE(SUM(CASE WHEN track_stock = 1 AND qty_milli > 0 THEN qty_milli * cost_cents / 1000 ELSE 0 END), 0) AS value, '
      'COALESCE(SUM(CASE WHEN track_stock = 1 AND qty_milli <= low_stock_milli THEN 1 ELSE 0 END), 0) AS low FROM products WHERE active = 1',
    )!;
    return {
      'products': rows.map(_productJson).toList(),
      'count': totals['c'],
      'lowCount': totals['low'],
      if (u.isOwner) 'stockValueCents': totals['value'],
    };
  }

  ScaleFormat get _scaleFormat {
    final j = _jsonSetting('scale_format', const ScaleFormat().toJson());
    return ScaleFormat.fromJson(j);
  }

  /// باركود صنف، أو باركود ميزان (الوزن أو السعر جواه)، أو رقم الصنف على الميزان (PLU) مكتوب بالإيد.
  Object? _lookupProduct(Request req, AuthUser u) {
    final code = latinDigits((req.url.queryParameters['barcode'] ?? '').trim());
    if (code.isEmpty) return {'product': null};
    final p = db.selectOne('$_productSelect WHERE p.barcode = ? AND p.active = 1', [code]);
    if (p != null) return {'product': _productJson(p)};

    final read = parseScaleBarcode(code, _scaleFormat);
    if (read != null) {
      final w = db.selectOne('$_productSelect WHERE p.plu = ? AND p.active = 1', [read.plu]);
      if (w == null) return {'product': null, 'error': 'مفيش صنف رقمه على الميزان ${read.plu}'};
      final scale = _scaleLine(w, code);
      return {'product': _productJson(w), 'scale': {'barcode': code, 'qtyMilli': scale.qty, 'totalCents': scale.total}};
    }
    if (RegExp(r'^\d{1,6}$').hasMatch(code)) {
      final byPlu = db.selectOne('$_productSelect WHERE p.plu = ? AND p.active = 1', [int.parse(code)]);
      if (byPlu != null) return {'product': _productJson(byPlu)};
    }
    return {'product': null};
  }

  /// الكمية والإجمالي من باركود الميزان. لو الميزان بيطبع السعر، الإجمالي هو المطبوع بالظبط والكمية بتتحسب منه.
  ({int qty, int total}) _scaleLine(Map<String, Object?> product, String barcode) {
    final read = parseScaleBarcode(barcode, _scaleFormat);
    if (read == null || read.plu != product['plu']) throw ApiError(400, 'باركود الميزان ده مش لـ "${product['name']}"');
    if (product['unit'] != 'kg') throw ApiError(400, '"${product['name']}" مش متسجل إنه بيتباع بالكيلو');
    final price = product['price_cents'] as int;
    if (read.grams != null) return (qty: read.grams!, total: lineTotal(price, read.grams!));
    final total = read.priceCents!;
    if (price <= 0) throw ApiError(400, 'سعر الكيلو من "${product['name']}" مش متسجل');
    return (qty: (total * milli / price).round(), total: total);
  }

  Object? _productCategories(Request req, AuthUser u) {
    final rows = db.select("SELECT DISTINCT category FROM products WHERE category IS NOT NULL AND category <> '' AND active = 1 ORDER BY category");
    return {'categories': rows.map((r) => r['category']).toList()};
  }

  String? _validBarcode(Object? raw, {String? exceptId}) {
    final v = latinDigits((raw as String? ?? '').trim());
    if (v.isEmpty) return null;
    if (v.length > 64) throw ApiError(400, 'الباركود طويل جداً');
    final other = db.selectOne('SELECT id, name FROM products WHERE barcode = ?', [v]);
    if (other != null && other['id'] != exceptId) throw ApiError(409, 'الباركود ده متسجل على صنف تاني: ${other['name']}');
    return v;
  }

  int? _validPlu(Object? raw, {String? exceptId}) {
    if (raw == null || raw == '') return null;
    final v = raw is int ? raw : int.tryParse(latinDigits('$raw'.trim()));
    final maxPlu = int.parse('9' * _scaleFormat.pluLength);
    if (v == null || v <= 0 || v > maxPlu) throw ApiError(400, 'رقم الصنف على الميزان لازم يكون من 1 لـ $maxPlu');
    final other = db.selectOne('SELECT id, name FROM products WHERE plu = ?', [v]);
    if (other != null && other['id'] != exceptId) throw ApiError(409, 'رقم الميزان $v متسجل على صنف تاني: ${other['name']}');
    return v;
  }

  String _validUnit(Object? raw) => raw == 'kg' ? 'kg' : 'piece';

  /// باركود داخلي EAN-13 بيبدأ بـ 20 (مخصص للاستخدام الداخلي في المحلات، ومش من بادئات الميزان).
  String _newBarcode() {
    for (var i = 0; i < 50; i++) {
      final body = '20${List.generate(10, (_) => randomBytes(1)[0] % 10).join()}';
      var sum = 0;
      for (var j = 0; j < 12; j++) {
        sum += int.parse(body[j]) * (j.isEven ? 1 : 3);
      }
      final code = '$body${(10 - sum % 10) % 10}';
      if (db.selectOne('SELECT id FROM products WHERE barcode = ?', [code]) == null) return code;
    }
    throw ApiError(500, 'مش قادر أعمل باركود جديد');
  }

  Future<Object?> _createProduct(Request req, AuthUser u) async {
    final body = await _body(req);
    final id = _uuid.v4();
    final now = nowIso();
    final unit = _validUnit(body['unit']);
    final qty = body['qtyMilli'] is int ? body['qtyMilli'] as int : 0;
    final trackExpiry = body['trackExpiry'] == true;
    db.transaction(() {
      db.execute(
        'INSERT INTO products(id, name, barcode, plu, category, unit, cost_cents, price_cents, qty_milli, low_stock_milli, track_stock, track_expiry, notes, created_at, updated_at) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)',
        [
          id, _requiredText(body, 'name', 'اسم الصنف'), _validBarcode(body['barcode']), _validPlu(body['plu']), _optionalText(body, 'category'), unit,
          body['costCents'] == null ? 0 : _cents(body['costCents'], 'سعر الشرا'),
          body['priceCents'] == null ? 0 : _cents(body['priceCents'], 'سعر البيع'),
          body['lowStockMilli'] is int ? (body['lowStockMilli'] as int).clamp(0, 100000000) : 0,
          trackExpiry || body['trackStock'] != false ? 1 : 0,
          trackExpiry ? 1 : 0,
          _optionalText(body, 'notes'), now, now,
        ],
      );
      final p = db.selectOne('SELECT * FROM products WHERE id = ?', [id])!;
      if (qty < 0) throw ApiError(400, 'الكمية مش صحيحة');
      if (qty > 0) {
        _checkUnitQty(p, qty);
        _moveStock(id, qty, 'initial', userId: u.id, note: 'رصيد أول المدة', expiresOn: _validDay(body['expiresOn']));
      }
    });
    _audit(u.id, 'product.create', 'product', id, body['name'] as String?);
    _broadcast('products');
    return {'product': _productJson(_loadProduct(id))};
  }

  Future<Object?> _updateProduct(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final p = _loadProduct(id);
    final body = await _body(req);
    // سعر الشرا بيبان لصاحب المحل بس، فالكاشير مايقدرش يغيّره
    if (!u.isOwner && body.containsKey('costCents')) throw ApiError(403, 'سعر الشرا بيتعدل من صاحب المحل بس');
    final sets = <String, Object?>{};
    if (body.containsKey('name')) sets['name'] = _requiredText(body, 'name', 'اسم الصنف');
    if (body.containsKey('barcode')) sets['barcode'] = _validBarcode(body['barcode'], exceptId: id);
    if (body.containsKey('plu')) sets['plu'] = _validPlu(body['plu'], exceptId: id);
    if (body.containsKey('category')) sets['category'] = _optionalText(body, 'category');
    if (body.containsKey('costCents')) sets['cost_cents'] = _cents(body['costCents'], 'سعر الشرا');
    if (body.containsKey('priceCents')) sets['price_cents'] = _cents(body['priceCents'], 'سعر البيع');
    if (body.containsKey('lowStockMilli')) sets['low_stock_milli'] = (body['lowStockMilli'] as int? ?? 0).clamp(0, 100000000);
    if (body.containsKey('unit')) {
      final unit = _validUnit(body['unit']);
      if (unit == 'piece' && (p['qty_milli'] as int) % milli != 0) throw ApiError(400, 'الكمية الحالية فيها كسور، ظبّط الجرد الأول وبعدين خليه بالقطعة');
      sets['unit'] = unit;
    }
    if (body.containsKey('trackStock') && p['track_expiry'] != 1) sets['track_stock'] = body['trackStock'] == false ? 0 : 1;
    if (body.containsKey('notes')) sets['notes'] = _optionalText(body, 'notes');
    if (body.containsKey('active')) sets['active'] = body['active'] == false ? 0 : 1;
    final enableExpiry = body['trackExpiry'] == true && p['track_expiry'] != 1;
    final disableExpiry = body['trackExpiry'] == false && p['track_expiry'] == 1;
    if (enableExpiry) {
      sets['track_expiry'] = 1;
      sets['track_stock'] = 1;
    }
    if (disableExpiry) sets['track_expiry'] = 0;
    if (sets.isNotEmpty) {
      db.transaction(() {
        db.execute('UPDATE products SET ${sets.keys.map((k) => '$k = ?').join(', ')}, updated_at = ? WHERE id = ?', [...sets.values, nowIso(), id]);
        // الكمية الموجودة وقت تفعيل الصلاحية بتبقى دفعة واحدة من غير تاريخ لحد ما يتعمل جرد
        final qty = p['qty_milli'] as int;
        if (enableExpiry && qty > 0) {
          db.execute(
            'INSERT INTO batches(id, product_id, expires_on, qty_milli, received_milli, cost_cents, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)',
            [_uuid.v4(), id, _validDay(body['expiresOn']), qty, qty, p['cost_cents'], nowIso()],
          );
        }
        if (disableExpiry) db.execute('UPDATE batches SET qty_milli = 0 WHERE product_id = ?', [id]);
      });
      if (sets.containsKey('price_cents') && sets['price_cents'] != p['price_cents']) {
        _audit(u.id, 'product.price', 'product', id, '${p['name']}: من ${_money(p['price_cents'] as int)} لـ ${_money(sets['price_cents'] as int)}');
      }
      _broadcast('products');
    }
    return {'product': _productJson(_loadProduct(id))};
  }

  /// كل تغيير في الكمية بيعدي من هنا عشان يتسجل في حركة المخزون.
  ///
  /// الأصناف اللي بتتتبع صلاحيتها: الزيادة بتعمل دفعة جديدة بتاريخ [expiresOn] (أو بترجع لدفعة [batchId])،
  /// والنقص بيسحب من الدفعة اللي هتخلص صلاحيتها الأول (FEFO)، أو من دفعة [batchId] بالتحديد.
  /// لو الدفعات خلصت والمخزون مسموح يبقى بالسالب، الباقي بيتسجل من غير دفعة.
  List<_Take> _moveStock(String productId, int change, String reason,
      {String? refType, String? refId, String? note, String? userId, String? expiresOn, String? batchId, int? costCents, String? purchaseId}) {
    final p = db.selectOne('SELECT qty_milli, track_stock, track_expiry, cost_cents FROM products WHERE id = ?', [productId]);
    if (p == null) throw ApiError(400, 'صنف مش موجود');
    final productCost = costCents ?? p['cost_cents'] as int;
    if (p['track_stock'] != 1) return [(batchId: null, qty: change.abs(), cost: productCost)];
    var qty = p['qty_milli'] as int;
    final now = nowIso();
    final takes = <_Take>[];
    void log(String? batch, int delta, int cost) {
      qty += delta;
      takes.add((batchId: batch, qty: delta.abs(), cost: cost));
      db.execute(
        'INSERT INTO stock_moves(product_id, batch_id, qty_change_milli, qty_after_milli, cost_cents, reason, ref_type, ref_id, note, user_id, created_at) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [productId, batch, delta, qty, cost, reason, refType, refId, note, userId, now],
      );
    }

    if (p['track_expiry'] != 1) {
      log(null, change, productCost);
    } else if (change > 0) {
      if (batchId != null) {
        final b = db.selectOne('SELECT cost_cents FROM batches WHERE id = ? AND product_id = ?', [batchId, productId]);
        if (b == null) throw ApiError(400, 'الدفعة دي مش موجودة');
        db.execute('UPDATE batches SET qty_milli = qty_milli + ? WHERE id = ?', [change, batchId]);
        log(batchId, change, b['cost_cents'] as int);
      } else {
        final id = _uuid.v4();
        db.execute(
          'INSERT INTO batches(id, product_id, expires_on, qty_milli, received_milli, cost_cents, purchase_id, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)',
          [id, productId, expiresOn, change, change, productCost, purchaseId, now],
        );
        log(id, change, productCost);
      }
    } else if (change < 0) {
      var need = -change;
      final rows = batchId != null
          ? db.select('SELECT id, qty_milli, cost_cents FROM batches WHERE id = ? AND product_id = ?', [batchId, productId])
          : db.select(
              'SELECT id, qty_milli, cost_cents FROM batches WHERE product_id = ? AND qty_milli > 0 '
              'ORDER BY expires_on IS NULL, expires_on, created_at',
              [productId],
            );
      if (batchId != null && rows.isEmpty) throw ApiError(400, 'الدفعة دي مش موجودة');
      for (final b in rows) {
        if (need == 0) break;
        final take = need < (b['qty_milli'] as int) ? need : b['qty_milli'] as int;
        if (take <= 0) continue;
        db.execute('UPDATE batches SET qty_milli = qty_milli - ? WHERE id = ?', [take, b['id']]);
        log(b['id'] as String, -take, b['cost_cents'] as int);
        need -= take;
      }
      if (need > 0) {
        if (batchId != null) throw ApiError(400, 'الدفعة دي فيها أقل من الكمية دي');
        log(null, -need, productCost);
      }
    }
    db.execute('UPDATE products SET qty_milli = ?, updated_at = ? WHERE id = ?', [qty, now, productId]);
    return takes;
  }

  /// متوسط تكلفة القطعة أو الكيلو من الدفعات اللي اتسحب منها.
  int _avgCost(List<_Take> takes, int fallback) {
    final qty = takes.fold<int>(0, (s, t) => s + t.qty);
    if (qty == 0) return fallback;
    return (takes.fold<int>(0, (s, t) => s + t.qty * t.cost) / qty).round();
  }

  Future<Object?> _adjustStock(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final p = _loadProduct(id);
    final body = await _body(req);
    final batchId = body['batchId'] as String?;
    int change;
    if (body['setQtyMilli'] is int) {
      if (batchId != null) {
        final b = db.selectOne('SELECT qty_milli FROM batches WHERE id = ? AND product_id = ?', [batchId, id]);
        if (b == null) throw ApiError(400, 'الدفعة دي مش موجودة');
        change = (body['setQtyMilli'] as int) - (b['qty_milli'] as int);
      } else {
        change = (body['setQtyMilli'] as int) - (p['qty_milli'] as int);
      }
    } else if (body['qtyChangeMilli'] is int) {
      change = body['qtyChangeMilli'] as int;
    } else {
      throw ApiError(400, 'اكتب الكمية');
    }
    if (change == 0) return {'product': _productJson(p)};
    _checkUnitQty(p, change.abs());
    final reason = _adjustReasons.contains(body['reason']) ? body['reason'] as String : 'other';
    // الكاشير يقدر يضيف بضاعة وصلت بس، والجرد والهالك لصاحب المحل أو مسؤول الشفت
    if (!u.isManager && (reason != 'purchase' || change <= 0)) throw ApiError(403, 'تعديل الجرد لصاحب المحل أو مسؤول الشفت بس. تقدر تضيف كمية وصلت');
    if (const {'damaged', 'expired', 'lost'}.contains(reason) && change > 0) throw ApiError(400, 'الهالك بيقلل الكمية، مش بيزودها');
    final paid = u.isOwner && body['costCents'] is int && (body['costCents'] as int) > 0 && change > 0 ? body['costCents'] as int : null;
    final expiresOn = _validDay(body['expiresOn']);
    db.transaction(() {
      int? unitCost;
      if (paid != null) {
        // سعر الشرا الجديد = متوسط القديم والجديد
        final oldQty = (p['qty_milli'] as int) < 0 ? 0 : p['qty_milli'] as int;
        unitCost = (paid * milli / change).round();
        final newCost = ((oldQty * (p['cost_cents'] as int) + paid * milli) / (oldQty + change)).round();
        db.execute('UPDATE products SET cost_cents = ?, updated_at = ? WHERE id = ?', [newCost, nowIso(), id]);
      }
      _moveStock(id, change, reason, userId: u.id, note: _optionalText(body, 'note'), expiresOn: expiresOn, batchId: batchId, costCents: unitCost);
    });
    _audit(u.id, 'product.adjust', 'product', id, '${p['name']}: ${change > 0 ? '+' : '-'}${_qty(p, change.abs())} ($reason)');
    _broadcast('products');
    return {'product': _productJson(_loadProduct(id))};
  }

  Object? _productMoves(Request req, AuthUser u) {
    final rows = db.select(
      'SELECT m.*, u.name AS user_name, b.expires_on FROM stock_moves m LEFT JOIN users u ON u.id = m.user_id '
      'LEFT JOIN batches b ON b.id = m.batch_id WHERE m.product_id = ? ORDER BY m.id DESC LIMIT 200',
      [req.params['id']],
    );
    return {
      'moves': rows
          .map((m) => {
                'changeMilli': m['qty_change_milli'],
                'afterMilli': m['qty_after_milli'],
                'reason': m['reason'],
                'refType': m['ref_type'],
                'refId': m['ref_id'],
                'expiresOn': m['expires_on'],
                'note': m['note'],
                'userName': m['user_name'],
                'createdAt': m['created_at'],
              })
          .toList(),
    };
  }

  Object? _productBatches(Request req, AuthUser u) {
    final rows = db.select(
      'SELECT * FROM batches WHERE product_id = ? AND qty_milli > 0 ORDER BY expires_on IS NULL, expires_on, created_at',
      [req.params['id']],
    );
    return {'batches': rows.map((b) => _batchJson(b, showCost: u.isOwner)).toList()};
  }

  Map<String, Object?> _batchJson(Map<String, Object?> b, {bool showCost = false}) {
    final expires = b['expires_on'] as String?;
    return {
      'id': b['id'],
      'productId': b['product_id'],
      if (b.containsKey('product_name')) 'productName': b['product_name'],
      if (b.containsKey('unit')) 'unit': b['unit'],
      'expiresOn': expires,
      'daysLeft': expires == null ? null : DateTime.parse(expires).difference(DateTime.parse(_localToday())).inDays,
      'qtyMilli': b['qty_milli'],
      'receivedMilli': b['received_milli'],
      if (showCost) 'costCents': b['cost_cents'],
      if (showCost) 'valueCents': ((b['qty_milli'] as int) * (b['cost_cents'] as int) / milli).round(),
      'createdAt': b['created_at'],
    };
  }

  /// استيراد الأصناف من البرنامج القديم (الصفوف جاية من Excel بعد ما المستخدم اختار الأعمدة).
  /// لو الباركود أو الاسم موجود بيتحدّث، وإلا بيتضاف.
  Future<Object?> _importProducts(Request req, AuthUser u) async {
    final body = await _body(req);
    final rows = body['rows'];
    if (rows is! List || rows.isEmpty) throw ApiError(400, 'مفيش بيانات');
    if (rows.length > 5000) throw ApiError(400, 'الدفعة كبيرة، ابعت 5000 صنف بالكتير في المرة');
    final updateQty = body['updateQty'] != false;
    var created = 0, updated = 0;
    final errors = <String>[];
    final now = nowIso();

    db.transaction(() {
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        if (r is! Map) continue;
        final name = (r['name'] as String? ?? '').trim();
        final barcode = latinDigits((r['barcode'] as String? ?? '').trim());
        if (name.isEmpty) {
          errors.add('صف ${i + 1}: الاسم فاضي');
          continue;
        }
        int? cents(Object? v) => v is int && v >= 0 ? v : null;
        final existing = barcode.isNotEmpty
            ? db.selectOne('SELECT * FROM products WHERE barcode = ?', [barcode])
            : db.selectOne('SELECT * FROM products WHERE name = ? AND barcode IS NULL', [name]);
        final qty = r['qtyMilli'] is int ? r['qtyMilli'] as int : null;
        final unit = r['unit'] == 'kg' ? 'kg' : (r['unit'] == 'piece' ? 'piece' : null);
        int? plu;
        try {
          plu = _validPlu(r['plu'], exceptId: existing?['id'] as String?);
        } on ApiError catch (e) {
          errors.add('صف ${i + 1}: ${e.message}');
        }
        if (existing == null) {
          final id = _uuid.v4();
          db.execute(
            'INSERT INTO products(id, name, barcode, plu, category, unit, cost_cents, price_cents, qty_milli, low_stock_milli, track_stock, created_at, updated_at) '
            'VALUES(?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 1, ?, ?)',
            [id, name, barcode.isEmpty ? null : barcode, plu, (r['category'] as String?)?.trim(), unit ?? 'piece',
             cents(r['costCents']) ?? 0, cents(r['priceCents']) ?? 0, r['lowStockMilli'] is int ? r['lowStockMilli'] : 0, now, now],
          );
          if (qty != null && qty != 0) _moveStock(id, qty, 'import', userId: u.id, note: 'استيراد');
          created++;
        } else {
          db.execute(
            'UPDATE products SET name = ?, category = COALESCE(?, category), cost_cents = COALESCE(?, cost_cents), '
            'price_cents = COALESCE(?, price_cents), unit = COALESCE(?, unit), plu = COALESCE(?, plu), active = 1, updated_at = ? WHERE id = ?',
            [name, (r['category'] as String?)?.trim(), cents(r['costCents']), cents(r['priceCents']), unit, plu, now, existing['id']],
          );
          if (updateQty && qty != null && qty != existing['qty_milli']) {
            _moveStock(existing['id'] as String, qty - (existing['qty_milli'] as int), 'import', userId: u.id, note: 'استيراد');
          }
          updated++;
        }
      }
    });
    _audit(u.id, 'product.import', 'product', null, 'جديد $created، تحديث $updated');
    _broadcast('products');
    return {'created': created, 'updated': updated, 'errors': errors.take(50).toList()};
  }

  // ================================================================ sales

  /// بيحوّل أصناف جاية من البرنامج لسطور فاتورة: الكمية بالألف، وباركود الميزان بيتقري من السيرفر نفسه.
  List<_SaleLine> _parseLines(Object? items, {required bool canDiscount, bool checkStock = true}) {
    if (items is! List || items.isEmpty) throw ApiError(400, 'الفاتورة فاضية');
    final lines = <_SaleLine>[];
    for (final it in items) {
      if (it is! Map) continue;
      final p = db.selectOne('SELECT * FROM products WHERE id = ? AND active = 1', [it['productId']]);
      if (p == null) throw ApiError(400, 'فيه صنف في الفاتورة مش موجود');
      final listPrice = p['price_cents'] as int;
      int qty, price, total;
      final scale = it['scaleBarcode'] as String?;
      if (scale != null && scale.isNotEmpty) {
        final s = _scaleLine(p, latinDigits(scale));
        (qty, price, total) = (s.qty, listPrice, s.total);
      } else {
        qty = _milli(it['qtyMilli']);
        _checkUnitQty(p, qty);
        price = it['unitPriceCents'] == null ? listPrice : _cents(it['unitPriceCents'], 'السعر');
        if (price < listPrice && !canDiscount) throw ApiError(403, 'مش مسموحلك تبيع بأقل من السعر');
        total = lineTotal(price, qty);
      }
      if (checkStock && p['track_stock'] == 1 && db.setting('allow_negative_stock') == '0') {
        final wanted = qty + lines.where((l) => l.product?['id'] == p['id']).fold<int>(0, (s, l) => s + l.qty);
        if ((p['qty_milli'] as int) < wanted) throw ApiError(400, 'المتاح من "${p['name']}" ${_qty(p, p['qty_milli'] as int)} بس');
      }
      lines.add((product: p, name: p['name'] as String, unit: p['unit'] as String, qty: qty, price: price, total: total));
    }
    if (lines.isEmpty) throw ApiError(400, 'الفاتورة فاضية');
    return lines;
  }

  List<(PaymentMethod, int)> _parsePayments(Object? raw) {
    final payments = <(PaymentMethod, int)>[];
    for (final pay in (raw as List? ?? const [])) {
      if (pay is! Map) continue;
      final amount = _cents(pay['amountCents'], 'المبلغ');
      if (amount > 0) payments.add((PaymentMethod.parse(pay['method'] as String?), amount));
    }
    return payments;
  }

  Future<Object?> _createSale(Request req, AuthUser u) async {
    await _requireLicense();
    final body = await _body(req);
    final customerId = body['customerId'] as String?;
    if (customerId != null && db.selectOne('SELECT id FROM customers WHERE id = ?', [customerId]) == null) {
      throw ApiError(400, 'العميل ده مش موجود');
    }
    final canDiscount = u.isManager || db.setting('cashier_can_discount') != '0';
    final lines = _parseLines(body['items'], canDiscount: canDiscount);
    final subtotal = lines.fold<int>(0, (s, l) => s + l.total);
    final discount = body['discountCents'] == null ? 0 : _cents(body['discountCents'], 'الخصم');
    if (discount > 0 && !canDiscount) throw ApiError(403, 'مش مسموحلك تعمل خصم');
    if (discount > subtotal) throw ApiError(400, 'الخصم أكبر من الفاتورة');
    final total = subtotal - discount;
    final payments = _parsePayments(body['payments']);
    final paid = payments.fold<int>(0, (s, p) => s + p.$2);
    if (paid > total) throw ApiError(400, 'المدفوع أكبر من الفاتورة');
    if (paid < total && customerId == null) throw ApiError(400, 'البيع الآجل لازم يكون على عميل. اختار العميل الأول');

    final sale = db.transaction(() => _insertSale(
          lines: lines,
          customerId: customerId,
          discount: discount,
          payments: payments,
          note: _optionalText(body, 'note'),
          userId: u.id,
          deviceName: _deviceName(u),
        ));
    _audit(u.id, 'sale.create', 'sale', sale.id, '#${sale.number} ${_money(total)}${paid < total ? ' (آجل ${_money(total - paid)})' : ''}');
    _broadcast('products');
    _broadcast('sales');
    _broadcast('cash');
    if (customerId != null) _broadcast('customers');
    return _saleDetail(sale.id);
  }

  /// بيسجل الفاتورة وسطورها ويخصم المخزون ويدخّل المدفوع درج [userId]. لازم يتنادى جوه transaction.
  /// [useDrawer] = false لفواتير التوصيل: الفلوس بتدخل الدرج وقت توريد الطيار، مش وقت التسليم.
  ({String id, int number}) _insertSale({
    required List<_SaleLine> lines,
    String? customerId,
    int discount = 0,
    required List<(PaymentMethod, int)> payments,
    int? paidOverride,
    String? note,
    required String userId,
    String? deviceName,
    bool useDrawer = true,
  }) {
    final id = _uuid.v4();
    final now = nowIso();
    final subtotal = lines.fold<int>(0, (s, l) => s + l.total);
    final paid = paidOverride ?? payments.fold<int>(0, (s, p) => s + p.$2);
    final number = db.selectOne('SELECT COALESCE(MAX(number), 0) + 1 AS n FROM sales')!['n'] as int;
    final session = useDrawer ? _openSessionId(userId, deviceName: deviceName) : null;
    db.execute(
      'INSERT INTO sales(id, number, customer_id, session_id, subtotal_cents, discount_cents, total_cents, paid_cents, note, user_id, created_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [id, number, customerId, session, subtotal, discount, subtotal - discount, paid, note, userId, now],
    );
    for (final l in lines) {
      final p = l.product;
      final itemId = _uuid.v4();
      var takes = const <_Take>[];
      if (p != null) takes = _moveStock(p['id'] as String, -l.qty, 'sale', refType: 'sale', refId: id, userId: userId);
      db.execute(
        'INSERT INTO sale_items(id, sale_id, product_id, name, unit, qty_milli, unit_price_cents, total_cents, cost_cents) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [itemId, id, p?['id'], l.name, l.unit, l.qty, l.price, l.total, p == null ? 0 : _avgCost(takes, p['cost_cents'] as int)],
      );
      for (final t in takes.where((t) => t.batchId != null)) {
        db.execute('INSERT INTO sale_item_batches(sale_item_id, batch_id, qty_milli) VALUES(?, ?, ?)', [itemId, t.batchId, t.qty]);
      }
    }
    for (final (method, amount) in payments) {
      _cashMove('sale', amount, method, userId: userId, refType: 'sale', refId: id, note: 'فاتورة #$number', deviceName: deviceName);
    }
    return (id: id, number: number);
  }

  Map<String, Object?> _saleSummary(Map<String, Object?> s) => {
        'id': s['id'],
        'number': s['number'],
        'customerId': s['customer_id'],
        'customerName': s['customer_name'],
        'subtotalCents': s['subtotal_cents'],
        'discountCents': s['discount_cents'],
        'totalCents': s['total_cents'],
        'paidCents': s['paid_cents'],
        'returnedCents': s['returned_cents'],
        'dueCents': (s['total_cents'] as int) - (s['returned_cents'] as int) - (s['paid_cents'] as int),
        'itemsCount': s['items_count'],
        'userName': s['user_name'],
        'deliveryNumber': s['delivery_number'],
        'note': s['note'],
        'createdAt': s['created_at'],
      };

  static const _saleSelect = '''
    SELECT s.*, c.name AS customer_name, u.name AS user_name,
           (SELECT COUNT(*) FROM sale_items i WHERE i.sale_id = s.id) AS items_count,
           (SELECT d.number FROM delivery_orders d WHERE d.sale_id = s.id) AS delivery_number
    FROM sales s LEFT JOIN customers c ON c.id = s.customer_id LEFT JOIN users u ON u.id = s.user_id''';

  Object? _listSales(Request req, AuthUser u) {
    final qp = req.url.queryParameters;
    final q = (qp['q'] ?? '').trim();
    final where = <String>[];
    final params = <Object?>[];
    if (q.isNotEmpty) {
      final n = int.tryParse(latinDigits(q));
      where.add('(c.name LIKE ?${n != null ? ' OR s.number = ?' : ''} OR EXISTS (SELECT 1 FROM sale_items i WHERE i.sale_id = s.id AND i.name LIKE ?))');
      params.add('%$q%');
      if (n != null) params.add(n);
      params.add('%$q%');
    }
    if (qp['from'] != null) {
      where.add('s.created_at >= ?');
      params.add(_validDate(qp['from']));
    }
    if (qp['to'] != null) {
      where.add('s.created_at < ?');
      params.add(_validDate(qp['to']));
    }
    if ((qp['userId'] ?? '').isNotEmpty) {
      where.add('s.user_id = ?');
      params.add(qp['userId']);
    }
    if (qp['due'] == '1') where.add('s.total_cents - s.returned_cents - s.paid_cents > 0');
    final limit = (int.tryParse(qp['limit'] ?? '') ?? 100).clamp(1, 500);
    final rows = db.select('$_saleSelect ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} ORDER BY s.created_at DESC LIMIT ?', [...params, limit]);
    return {'sales': rows.map(_saleSummary).toList()};
  }

  Object? _getSale(Request req, AuthUser u) => _saleDetail(req.params['id']!, showCost: u.isOwner);

  Map<String, Object?> _saleDetail(String id, {bool showCost = false}) {
    final s = db.selectOne('$_saleSelect WHERE s.id = ?', [id]);
    if (s == null) throw ApiError(404, 'الفاتورة دي مش موجودة');
    final items = db.select('SELECT * FROM sale_items WHERE sale_id = ? ORDER BY rowid', [id]);
    final moves = db.select("SELECT * FROM cash_moves WHERE ref_type = 'sale' AND ref_id = ? ORDER BY created_at", [id]);
    return {
      'sale': _saleSummary(s),
      'items': items
          .map((i) => {
                'id': i['id'],
                'productId': i['product_id'],
                'name': i['name'],
                'unit': i['unit'],
                'qtyMilli': i['qty_milli'],
                'unitPriceCents': i['unit_price_cents'],
                'totalCents': i['total_cents'],
                'returnedMilli': i['returned_milli'],
                'returnedCents': i['returned_cents'],
                if (showCost) 'costCents': i['cost_cents'],
              })
          .toList(),
      'payments': moves
          .map((m) => {'type': m['type'], 'amountCents': m['amount_cents'], 'method': m['method'], 'createdAt': m['created_at']})
          .toList(),
    };
  }

  Future<Object?> _returnSale(Request req, AuthUser u) async {
    final id = req.params['id']!;
    final s = db.selectOne('SELECT * FROM sales WHERE id = ?', [id]);
    if (s == null) throw ApiError(404, 'الفاتورة دي مش موجودة');
    final body = await _body(req);
    final wanted = body['items'];
    if (wanted is! List || wanted.isEmpty) throw ApiError(400, 'اختار الأصناف اللي هترجع');
    final method = PaymentMethod.parse(body['method'] as String?);

    var value = 0;
    final plan = <(Map<String, Object?>, int, int)>[];
    for (final w in wanted) {
      if (w is! Map) continue;
      final item = db.selectOne('SELECT * FROM sale_items WHERE id = ? AND sale_id = ?', [w['saleItemId'], id]);
      if (item == null) throw ApiError(400, 'صنف مش في الفاتورة دي');
      final qty = w['qtyMilli'] is int ? w['qtyMilli'] as int : 0;
      final left = (item['qty_milli'] as int) - (item['returned_milli'] as int);
      if (qty <= 0) continue;
      final unit = SaleUnit.parse(item['unit'] as String?);
      if (qty > left) throw ApiError(400, 'مينفعش ترجع أكتر من ${qtyLabel(left, unit)} من "${item['name']}"');
      if (unit == SaleUnit.piece && qty % milli != 0) throw ApiError(400, '"${item['name']}" بيرجع بالقطعة');
      // آخر جزء بيرجع بالباقي بالظبط، عشان التقريب مايسيبش قروش
      final itemValue = qty == left
          ? (item['total_cents'] as int) - (item['returned_cents'] as int)
          : ((item['total_cents'] as int) * qty / (item['qty_milli'] as int)).round();
      plan.add((item, qty, itemValue));
      value += itemValue;
    }
    if (plan.isEmpty) throw ApiError(400, 'اختار الأصناف اللي هترجع');
    // الخصم بيتوزع على الأصناف بالنسبة، فالمرتجع بيتحسب بعد الخصم
    final subtotal = s['subtotal_cents'] as int;
    if ((s['discount_cents'] as int) > 0 && subtotal > 0) value = (value * (s['total_cents'] as int) / subtotal).round();

    // المرتجع بيقلل الآجل الأول، والباقي بيرجع للعميل فلوس
    final due = (s['total_cents'] as int) - (s['returned_cents'] as int) - (s['paid_cents'] as int);
    final cashBack = (value - (due > 0 ? due : 0)).clamp(0, value);

    db.transaction(() {
      for (final (item, qty, itemValue) in plan) {
        db.execute('UPDATE sale_items SET returned_milli = returned_milli + ?, returned_cents = returned_cents + ? WHERE id = ?', [qty, itemValue, item['id']]);
        if (item['product_id'] != null) _restock(item, qty, refId: id, userId: u.id);
      }
      db.execute('UPDATE sales SET returned_cents = returned_cents + ?, paid_cents = paid_cents - ? WHERE id = ?', [value, cashBack, id]);
      if (cashBack > 0) {
        _cashMove('sale_refund', -cashBack, method, userId: u.id, refType: 'sale', refId: id, note: 'مرتجع فاتورة #${s['number']}', deviceName: _deviceName(u));
      }
    });
    _audit(u.id, 'sale.return', 'sale', id, '#${s['number']} ${_money(value)}');
    _broadcast('products');
    _broadcast('sales');
    _broadcast('cash');
    return {..._saleDetail(id), 'refundCents': cashBack, 'returnValueCents': value};
  }

  /// المرتجع بيرجع لنفس الدفعات اللي اتسحب منها (بنفس الصلاحية)، والباقي بيدخل كحركة عادية.
  void _restock(Map<String, Object?> item, int qty, {required String refId, required String userId}) {
    final productId = item['product_id'] as String;
    var left = qty;
    for (final b in db.select('SELECT * FROM sale_item_batches WHERE sale_item_id = ? AND qty_milli > returned_milli', [item['id']])) {
      if (left == 0) break;
      final back = left < (b['qty_milli'] as int) - (b['returned_milli'] as int) ? left : (b['qty_milli'] as int) - (b['returned_milli'] as int);
      db.execute('UPDATE sale_item_batches SET returned_milli = returned_milli + ? WHERE sale_item_id = ? AND batch_id = ?', [back, item['id'], b['batch_id']]);
      _moveStock(productId, back, 'return', refType: 'sale', refId: refId, userId: userId, batchId: b['batch_id'] as String);
      left -= back;
    }
    if (left > 0) _moveStock(productId, left, 'return', refType: 'sale', refId: refId, userId: userId, costCents: item['cost_cents'] as int);
  }
}
