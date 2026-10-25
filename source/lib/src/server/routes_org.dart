part of 'api_server.dart';

/// ربط فروع المحل الواحد عن طريق Firebase: ملخص كل فرع، والمخزون في الفروع التانية، والتحويلات بينها.
extension _OrgRoutes on BasketServer {
  void _registerOrgRoutes(Router r) {
    r.get('/api/org', _authed(_orgInfo, only: {'owner'}));
    r.post('/api/org/create', _authed(_orgCreate, only: {'owner'}));
    r.post('/api/org/invite', _authed(_orgInvite, only: {'owner'}));
    r.post('/api/org/join', _authed(_orgJoin, only: {'owner'}));
    r.post('/api/org/leave', _authed(_orgLeave, only: {'owner'}));
    r.get('/api/org/summary', _authed(_orgSummary, only: {'owner'}));
    r.get('/api/org/stock', _authed(_orgStock, only: _cashStaff));
    r.get('/api/org/transfers', _authed(_orgTransfers, only: _cashStaff));
    r.post('/api/org/transfers', _authed(_orgSendTransfer, only: _cashStaff));
    r.post('/api/org/transfers/<id>/receive', _authed(_orgReceiveTransfer, only: _cashStaff));
  }

  FirebaseSync get _fb {
    final c = _cloud;
    if (c == null) throw ApiError(400, 'ربط الفروع محتاج المزامنة مع النت تكون شغالة');
    return c;
  }

  String get _orgId {
    final id = db.setting('org_id');
    if (id == null || id.isEmpty) throw ApiError(400, 'الفرع ده مش مربوط بفروع تانية');
    return id;
  }

  String _localBranchName() => (db.selectOne('SELECT name FROM branches WHERE is_local = 1 LIMIT 1')?['name'] as String?) ?? 'الفرع';
  String _localShopName() => (db.selectOne('SELECT name FROM shop LIMIT 1')?['name'] as String?) ?? '';

  Future<Object?> _orgInfo(Request req, AuthUser u) async {
    final orgId = db.setting('org_id');
    if (orgId == null || orgId.isEmpty) return {'linked': false, 'cloud': _cloud != null};
    final fb = _fb;
    final org = await fb.getDoc('orgs/$orgId');
    final members = await fb.listDocs('orgs/$orgId/members');
    final uid = await fb.uid();
    return {
      'linked': true,
      'orgId': orgId,
      'name': org?['name'],
      'isOrgOwner': org?['ownerUid'] == uid,
      'members': [
        for (final m in members)
          {'uid': m.id, 'branchName': m.data['branchName'], 'shopName': m.data['shopName'], 'isMe': m.id == uid, 'joinedAt': (m.data['joinedAt'] as DateTime?)?.toIso8601String()},
      ],
    };
  }

  Future<Object?> _orgCreate(Request req, AuthUser u) async {
    if ((db.setting('org_id') ?? '').isNotEmpty) throw ApiError(400, 'الفرع ده مربوط بالفعل');
    final body = await _body(req);
    final fb = _fb;
    final uid = await fb.uid();
    final orgId = _uuid.v4();
    await fb.setDoc('orgs/$orgId', {'ownerUid': uid, 'name': _optionalText(body, 'name') ?? _localShopName(), 'createdAt': DateTime.now().toUtc()});
    await fb.setDoc('orgs/$orgId/members/$uid', {'branchName': _localBranchName(), 'shopName': _localShopName(), 'joinedAt': DateTime.now().toUtc()});
    db.setSetting('org_id', orgId);
    _audit(u.id, 'org.create', 'org', orgId, null);
    unawaited(_pushOrgData());
    return _orgInfo(req, u);
  }

  Future<Object?> _orgInvite(Request req, AuthUser u) async {
    final orgId = _orgId;
    final fb = _fb;
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final code = List.generate(8, (_) => alphabet[randomBytes(1)[0] % alphabet.length]).join();
    final expires = DateTime.now().toUtc().add(const Duration(hours: 24));
    await fb.setDoc('orgInvites/$code', {'orgId': orgId, 'createdBy': await fb.uid(), 'expiresAt': expires});
    return {'code': code, 'expiresAt': expires.toIso8601String()};
  }

  Future<Object?> _orgJoin(Request req, AuthUser u) async {
    if ((db.setting('org_id') ?? '').isNotEmpty) throw ApiError(400, 'الفرع ده مربوط بالفعل. افصله الأول');
    final body = await _body(req);
    final code = (body['code'] as String? ?? '').trim().toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (code.length != 8) throw ApiError(400, 'الكود 8 حروف وأرقام');
    final fb = _fb;
    final invite = await fb.getDoc('orgInvites/$code');
    if (invite == null) throw ApiError(404, 'الكود ده مش صحيح');
    if ((invite['expiresAt'] as DateTime).isBefore(DateTime.now())) throw ApiError(400, 'الكود ده خلص، اطلب كود جديد');
    final orgId = invite['orgId'] as String;
    final uid = await fb.uid();
    await fb.setDoc('orgs/$orgId/members/$uid', {
      'branchName': _localBranchName(),
      'shopName': _localShopName(),
      'joinedAt': DateTime.now().toUtc(),
      'inviteCode': code,
    });
    db.setSetting('org_id', orgId);
    _audit(u.id, 'org.join', 'org', orgId, null);
    unawaited(_pushOrgData());
    return _orgInfo(req, u);
  }

  Future<Object?> _orgLeave(Request req, AuthUser u) async {
    final orgId = _orgId;
    final fb = _fb;
    await fb.deleteDoc('orgs/$orgId/members/${await fb.uid()}');
    db.setSetting('org_id', '');
    _audit(u.id, 'org.leave', 'org', orgId, null);
    return {'linked': false};
  }

  /// بيبعت ملخص النهارده وامبارح، ومخزون الفرع، للمجموعة.
  Future<void> _pushOrgData() async {
    final orgId = db.setting('org_id');
    final fb = _cloud;
    if (orgId == null || orgId.isEmpty || fb == null) return;
    try {
      final uid = await fb.uid();
      for (final back in [0, 1]) {
        final n = DateTime.now();
        final day = DateTime(n.year, n.month, n.day - back);
        final r = buildReport(day.toUtc().toIso8601String(), DateTime(day.year, day.month, day.day + 1).toUtc().toIso8601String());
        final s = r['sales'] as Map, del = r['delivery'] as Map;
        String two(int x) => x.toString().padLeft(2, '0');
        final key = '${day.year}-${two(day.month)}-${two(day.day)}';
        await fb.setDoc('orgs/$orgId/branches/$uid/days/$key', {
          'date': key,
          'salesCount': s['count'],
          'salesCents': s['revenueCents'],
          'salesProfitCents': s['profitCents'],
          'deliveries': del['delivered'],
          'deliveryCents': del['totalCents'],
          'wasteCents': (r['waste'] as Map)['totalCents'],
          'expensesCents': (r['expenses'] as Map)['totalCents'],
          'netProfitCents': r['netProfitCents'],
          'updatedAt': DateTime.now().toUtc(),
        });
      }
      final items = db
          .select('SELECT name, barcode, unit, qty_milli, price_cents FROM products WHERE active = 1 AND track_stock = 1 AND qty_milli > 0 ORDER BY name LIMIT 3000')
          .map((p) => {'n': p['name'], 'b': p['barcode'], 'u': p['unit'], 'q': p['qty_milli'], 'p': p['price_cents']})
          .toList();
      final hash = sha256Hex(jsonEncode(items));
      if (db.setting('org_stock_hash') != hash) {
        await fb.setDoc('orgs/$orgId/branches/$uid', {'branchName': _localBranchName(), 'items': items, 'updatedAt': DateTime.now().toUtc()});
        db.setSetting('org_stock_hash', hash);
      }
    } catch (e) {
      stderr.writeln('org push: $e');
    }
  }

  Future<Object?> _orgSummary(Request req, AuthUser u) async {
    final orgId = _orgId;
    final fb = _fb;
    await _pushOrgData();
    final from = (req.url.queryParameters['from'] ?? '').trim();
    final to = (req.url.queryParameters['to'] ?? '').trim();
    final members = await fb.listDocs('orgs/$orgId/members');
    final uid = await fb.uid();
    final branches = <Map<String, Object?>>[];
    for (final m in members) {
      final days = (await fb.listDocs('orgs/$orgId/branches/${m.id}/days'))
          .where((d) => (from.isEmpty || (d.data['date'] as String).compareTo(from) >= 0) && (to.isEmpty || (d.data['date'] as String).compareTo(to) <= 0))
          .toList();
      int total(String k) => days.fold<int>(0, (s, d) => s + ((d.data[k] as int?) ?? 0));
      DateTime? updated;
      for (final d in days) {
        final t = d.data['updatedAt'] as DateTime?;
        if (t != null && (updated == null || t.isAfter(updated))) updated = t;
      }
      branches.add({
        'uid': m.id,
        'branchName': m.data['branchName'],
        'isMe': m.id == uid,
        'salesCount': total('salesCount'),
        'salesCents': total('salesCents'),
        'salesProfitCents': total('salesProfitCents'),
        'deliveries': total('deliveries'),
        'deliveryCents': total('deliveryCents'),
        'wasteCents': total('wasteCents'),
        'expensesCents': total('expensesCents'),
        'netProfitCents': total('netProfitCents'),
        'updatedAt': updated?.toIso8601String(),
      });
    }
    return {'branches': branches};
  }

  Future<Object?> _orgStock(Request req, AuthUser u) async {
    final orgId = _orgId;
    final fb = _fb;
    final q = (req.url.queryParameters['q'] ?? '').trim().toLowerCase();
    if (q.length < 2) return {'results': []};
    final uid = await fb.uid();
    final results = <Map<String, Object?>>[];
    for (final m in await fb.listDocs('orgs/$orgId/members')) {
      if (m.id == uid) continue;
      final b = await fb.getDoc('orgs/$orgId/branches/${m.id}');
      for (final it in (b?['items'] as List? ?? const []).whereType<Map>()) {
        final name = (it['n'] as String? ?? '').toLowerCase();
        if (name.contains(q) || it['b'] == q) {
          results.add({'branchUid': m.id, 'branchName': m.data['branchName'], 'name': it['n'], 'barcode': it['b'], 'unit': it['u'] ?? 'piece', 'qtyMilli': it['q'], 'priceCents': it['p']});
        }
      }
    }
    return {'results': results.take(100).toList()};
  }

  Future<Object?> _orgTransfers(Request req, AuthUser u) async {
    final orgId = _orgId;
    final fb = _fb;
    final uid = await fb.uid();
    final all = await fb.listDocs('orgs/$orgId/transfers');
    Map<String, Object?> json(FsDoc d) => {
          'id': d.id,
          ...d.data.map((k, v) => MapEntry(k, v is DateTime ? v.toIso8601String() : v)),
        };
    final list = all.map(json).toList()..sort((a, b) => '${b['createdAt']}'.compareTo('${a['createdAt']}'));
    return {
      'incoming': list.where((t) => t['toUid'] == uid && t['status'] == 'sent').toList(),
      'history': list.where((t) => t['fromUid'] == uid || (t['toUid'] == uid && t['status'] != 'sent')).take(50).toList(),
    };
  }

  /// تحويل بضاعة لفرع تاني: بتتخصم من هنا وتستنى الفرع التاني يأكد الاستلام.
  Future<Object?> _orgSendTransfer(Request req, AuthUser u) async {
    final orgId = _orgId;
    final fb = _fb;
    final body = await _body(req);
    final toUid = body['toUid'] as String?;
    final uid = await fb.uid();
    if (toUid == null || toUid == uid) throw ApiError(400, 'اختار الفرع اللي هتحوّل له');
    final members = await fb.listDocs('orgs/$orgId/members');
    final to = members.where((m) => m.id == toUid).firstOrNull;
    if (to == null) throw ApiError(400, 'الفرع ده مش في المجموعة');
    final wanted = (body['items'] as List? ?? const []).whereType<Map>().toList();
    if (wanted.isEmpty) throw ApiError(400, 'اختار الأصناف');
    final items = <Map<String, Object?>>[];
    for (final w in wanted) {
      final p = db.selectOne('SELECT * FROM products WHERE id = ?', [w['productId']]);
      final qty = w['qtyMilli'] is int ? w['qtyMilli'] as int : 0;
      if (p == null || qty <= 0) throw ApiError(400, 'صنف أو كمية مش صحيحة');
      _checkUnitQty(p, qty);
      if ((p['qty_milli'] as int) < qty) throw ApiError(400, 'المتاح من "${p['name']}" ${_qty(p, p['qty_milli'] as int)} بس');
      items.add({
        'productId': p['id'], 'name': p['name'], 'barcode': p['barcode'], 'plu': p['plu'], 'category': p['category'], 'unit': p['unit'],
        'trackExpiry': p['track_expiry'] == 1, 'qtyMilli': qty, 'costCents': p['cost_cents'], 'priceCents': p['price_cents'],
      });
    }
    // تواريخ الصلاحية بتتنقل مع البضاعة: الدفعات اللي هتتسحب (FEFO) بتتبعت بتواريخها
    for (final i in items) {
      var need = i['qtyMilli'] as int;
      final batches = <Map<String, Object?>>[];
      if (i['trackExpiry'] == true) {
        for (final b in db.select(
            'SELECT qty_milli, expires_on FROM batches WHERE product_id = ? AND qty_milli > 0 ORDER BY expires_on IS NULL, expires_on, created_at',
            [i['productId']])) {
          if (need == 0) break;
          final take = need < (b['qty_milli'] as int) ? need : b['qty_milli'] as int;
          batches.add({'q': take, 'e': b['expires_on']});
          need -= take;
        }
      }
      i['batches'] = batches;
    }
    final id = _uuid.v4();
    await fb.setDoc('orgs/$orgId/transfers/$id', {
      'fromUid': uid,
      'fromName': _localBranchName(),
      'toUid': toUid,
      'toName': to.data['branchName'],
      'items': [for (final i in items) {...i}..remove('productId')],
      'status': 'sent',
      'note': _optionalText(body, 'note'),
      'createdAt': DateTime.now().toUtc(),
    });
    // بيتخصم بعد ما التحويل يتبعت، عشان لو النت فصل البضاعة ماتضيعش
    db.transaction(() {
      for (final i in items) {
        _moveStock(i['productId'] as String, -(i['qtyMilli'] as int), 'transfer_out', refType: 'transfer', refId: id, userId: u.id, note: 'تحويل لـ ${to.data['branchName']}');
      }
    });
    _audit(u.id, 'org.transfer_out', 'transfer', id, '${to.data['branchName']}: ${items.length} صنف');
    _broadcast('products');
    return {'id': id};
  }

  /// استلام تحويل: الأصناف بتتطابق بالباركود أو الاسم، واللي مش موجود بيتعمل.
  Future<Object?> _orgReceiveTransfer(Request req, AuthUser u) async {
    final orgId = _orgId;
    final fb = _fb;
    final id = req.params['id']!;
    final t = await fb.getDoc('orgs/$orgId/transfers/$id');
    if (t == null) throw ApiError(404, 'التحويل ده مش موجود');
    if (t['toUid'] != await fb.uid()) throw ApiError(403, 'التحويل ده مش للفرع ده');
    if (t['status'] != 'sent') throw ApiError(400, 'التحويل ده اتستلم قبل كده');
    await fb.setDoc('orgs/$orgId/transfers/$id', {...t, 'status': 'received', 'receivedAt': DateTime.now().toUtc()});
    db.transaction(() {
      for (final it in (t['items'] as List).whereType<Map>()) {
        final barcode = it['barcode'] as String?;
        var p = barcode != null ? db.selectOne('SELECT * FROM products WHERE barcode = ?', [barcode]) : null;
        p ??= db.selectOne('SELECT * FROM products WHERE name = ?', [it['name']]);
        String pid;
        if (p == null) {
          pid = _uuid.v4();
          final now = nowIso();
          db.execute(
            'INSERT INTO products(id, name, barcode, category, unit, cost_cents, price_cents, track_stock, track_expiry, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)',
            [pid, it['name'], barcode, it['category'], it['unit'] == 'kg' ? 'kg' : 'piece', it['costCents'] ?? 0, it['priceCents'] ?? 0, it['trackExpiry'] == true ? 1 : 0, now, now],
          );
        } else {
          pid = p['id'] as String;
          db.execute('UPDATE products SET active = 1 WHERE id = ?', [pid]);
        }
        final note = 'تحويل من ${t['fromName']}';
        final qty = it['qtyMilli'] as int;
        var batched = 0;
        for (final b in (it['batches'] as List? ?? const []).whereType<Map>()) {
          _moveStock(pid, b['q'] as int, 'transfer_in', refType: 'transfer', refId: id, userId: u.id, note: note, expiresOn: b['e'] as String?, costCents: it['costCents'] as int?);
          batched += b['q'] as int;
        }
        if (qty > batched) _moveStock(pid, qty - batched, 'transfer_in', refType: 'transfer', refId: id, userId: u.id, note: note, costCents: it['costCents'] as int?);
      }
    });
    _audit(u.id, 'org.transfer_in', 'transfer', id, '${t['fromName']}');
    _broadcast('products');
    return {'ok': true};
  }
}
