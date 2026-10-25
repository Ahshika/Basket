part of 'api_server.dart';

const receiptPapers = {'80mm', '58mm', 'a5', 'a4'};

extension _ShopRoutes on BasketServer {
  void _registerShopRoutes(Router r) {
    r.get('/api/shop', _authed((req, u) => _shopJson()));
    r.patch('/api/shop', _authed(_updateShop, only: {'owner'}));
    r.put('/api/shop/logo', _authed(_setLogo, only: {'owner'}));
    r.delete('/api/shop/logo', _authed((req, u) {
      final f = File(p.join(dataDir, 'logo.png'));
      if (f.existsSync()) f.deleteSync();
      _broadcast('shop');
      return {'ok': true};
    }, only: {'owner'}));
  }

  // ---------------------------------------------------------------- shop profile

  Map<String, Object?> _jsonSetting(String key, Map<String, Object?> defaults) {
    final raw = db.setting(key);
    if (raw == null) return {...defaults};
    try {
      return {...defaults, ...(jsonDecode(raw) as Map<String, dynamic>)};
    } catch (_) {
      return {...defaults};
    }
  }

  Map<String, Object?> _shopJson() {
    final shop = db.selectOne('SELECT * FROM shop LIMIT 1');
    final branch = db.selectOne('SELECT * FROM branches WHERE is_local = 1 LIMIT 1');
    final logo = File(p.join(dataDir, 'logo.png'));
    return {
      'name': shop?['name'],
      'phone': shop?['phone'],
      'address': shop?['address'],
      'branchName': branch?['name'],
      'logoBase64': logo.existsSync() ? base64.encode(logo.readAsBytesSync()) : null,
      'receiptTerms': db.setting('receipt_terms') ?? _defaultTerms,
      'receiptPaper': db.setting('receipt_paper') ?? '80mm',
      'cashierCanDiscount': db.setting('cashier_can_discount') != '0',
      'allowNegativeStock': db.setting('allow_negative_stock') != '0',
      'scaleFormat': _scaleFormat.toJson(),
      'expiryAlertDays': _expiryAlertDays,
      'deliveryFeeCents': _defaultDeliveryFee,
    };
  }

  static const _defaultTerms = 'البضاعة المباعة تُرد أو تُستبدل خلال 3 أيام بالفاتورة.\n'
      'المنتجات المبردة والمجمدة والخضار والفاكهة لا تُرد.';

  Future<Object?> _updateShop(Request req, AuthUser u) async {
    final body = await _body(req);
    final shop = db.selectOne('SELECT id FROM shop LIMIT 1');
    if (shop == null) throw ApiError(400, 'المحل لسه ما اتسجلش');

    db.transaction(() {
      if (body.containsKey('name')) {
        db.execute('UPDATE shop SET name = ? WHERE id = ?', [_requiredText(body, 'name', 'اسم المحل'), shop['id']]);
      }
      for (final key in ['phone', 'address']) {
        if (body.containsKey(key)) {
          db.execute('UPDATE shop SET $key = ? WHERE id = ?', [_optionalText(body, key), shop['id']]);
          db.execute('UPDATE branches SET $key = ? WHERE is_local = 1', [_optionalText(body, key)]);
        }
      }
      if (body.containsKey('branchName')) {
        db.execute('UPDATE branches SET name = ? WHERE is_local = 1', [_requiredText(body, 'branchName', 'اسم الفرع')]);
      }
      if (body.containsKey('receiptTerms')) db.setSetting('receipt_terms', (body['receiptTerms'] as String? ?? '').trim());
      if (body.containsKey('receiptPaper')) {
        final paper = body['receiptPaper'];
        if (!receiptPapers.contains(paper)) throw ApiError(400, 'مقاس الورق مش صحيح');
        db.setSetting('receipt_paper', paper as String);
      }
      for (final e in const {'cashierCanDiscount': 'cashier_can_discount', 'allowNegativeStock': 'allow_negative_stock'}.entries) {
        if (body[e.key] is bool) db.setSetting(e.value, body[e.key] == true ? '1' : '0');
      }
      if (body['scaleFormat'] is Map) {
        final f = ScaleFormat.fromJson((body['scaleFormat'] as Map).cast<String, Object?>());
        final error = f.validate();
        if (error != null) throw ApiError(400, error);
        db.setSetting('scale_format', jsonEncode(f.toJson()));
      }
      if (body['expiryAlertDays'] is int) db.setSetting('expiry_alert_days', '${(body['expiryAlertDays'] as int).clamp(1, 365)}');
      if (body.containsKey('deliveryFeeCents')) db.setSetting('delivery_fee_cents', '${_cents(body['deliveryFeeCents'], 'رسوم التوصيل')}');
    });
    _audit(u.id, 'shop.update', 'shop', shop['id'] as String, body.keys.join('، '));
    _broadcast('shop');
    return _shopJson();
  }

  Future<Object?> _setLogo(Request req, AuthUser u) async {
    final body = await _body(req);
    final List<int> bytes;
    try {
      bytes = base64.decode(body['png'] as String? ?? '');
    } catch (_) {
      throw ApiError(400, 'الصورة مش صحيحة');
    }
    const pngMagic = [0x89, 0x50, 0x4E, 0x47];
    if (bytes.length < 8 || !List.generate(4, (i) => bytes[i] == pngMagic[i]).every((b) => b)) {
      throw ApiError(400, 'الصورة لازم تكون PNG');
    }
    if (bytes.length > 1024 * 1024) throw ApiError(400, 'الصورة كبيرة جداً');
    File(p.join(dataDir, 'logo.png')).writeAsBytesSync(bytes);
    _audit(u.id, 'shop.logo', 'shop', null, null);
    _broadcast('shop');
    return {'ok': true};
  }
}
