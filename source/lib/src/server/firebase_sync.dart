part of 'api_server.dart';

/// الاتصال بـ Firestore عشان ربط فروع المحل الواحد (ملخصات الأيام، ومخزون الفروع، والتحويلات).
///
/// كل محل ليه حساب Firebase خاص بيه بيتعمل أوتوماتيك أول مرة (إيميل داخلي وكلمة سر عشوائية
/// متخزنين في إعدادات السيرفر)، وقواعد Firestore بتمنع أي محل يقرا أو يعدّل بيانات مجموعة مش عضو فيها.
/// لو مفيش نت، الشغل بيكمل عادي وملخص الفروع بيتبعت أول ما النت يرجع.
class FirebaseSync {
  FirebaseSync(this.server);

  final BasketServer server;
  final _http = http.Client();

  String? _idToken;
  DateTime _idTokenExpiry = DateTime(2000);
  String? _uid;

  AppDb get db => server.db;
  static const _docsBase = 'https://firestore.googleapis.com/v1/projects/$firebaseProjectId/databases/(default)/documents';

  void stop() => _http.close();

  /// بيمسح حساب المحل من Firebase (للاختبارات بس).
  Future<void> deleteAccount() async {
    await _http.post(
      Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:delete?key=$firebaseApiKey'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'idToken': await _token()}),
    );
  }

  // ---------------------------------------------------------------- auth

  Future<String> _token() async {
    if (_idToken != null && DateTime.now().isBefore(_idTokenExpiry)) return _idToken!;
    final refresh = db.setting('cloud_refresh_token');
    if (refresh != null && refresh.isNotEmpty) {
      final res = await _http.post(
        Uri.parse('https://securetoken.googleapis.com/v1/token?key=$firebaseApiKey'),
        body: {'grant_type': 'refresh_token', 'refresh_token': refresh},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        return _saveAuth(j['id_token'] as String, j['refresh_token'] as String, j['user_id'] as String, j['expires_in']);
      }
    }
    var email = db.setting('cloud_email');
    var password = db.setting('cloud_password');
    var endpoint = 'signInWithPassword';
    if (email == null || password == null) {
      email = 'shop-${db.setting('server_id')}@shops.basket.app';
      password = randomToken();
      db.setSetting('cloud_email', email);
      db.setSetting('cloud_password', password);
      endpoint = 'signUp';
    }
    final res = await _http
        .post(
          Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:$endpoint?key=$firebaseApiKey'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password, 'returnSecureToken': true}),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('Firebase auth ${res.statusCode}: ${res.body}');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return _saveAuth(j['idToken'] as String, j['refreshToken'] as String, j['localId'] as String, j['expiresIn']);
  }

  String _saveAuth(String idToken, String refreshToken, String uid, Object? expiresIn) {
    db.setSetting('cloud_refresh_token', refreshToken);
    db.setSetting('cloud_uid', uid);
    _uid = uid;
    _idToken = idToken;
    final seconds = int.tryParse('$expiresIn') ?? 3600;
    _idTokenExpiry = DateTime.now().add(Duration(seconds: seconds - 120));
    return idToken;
  }

  Future<Map<String, String>> _headers() async => {
        'authorization': 'Bearer ${await _token()}',
        'content-type': 'application/json',
      };

  // ---------------------------------------------------------------- generic document access (للفروع)

  Future<String> uid() async {
    await _token();
    return _uid ?? db.setting('cloud_uid')!;
  }

  Future<Map<String, Object?>?> getDoc(String path) async {
    final res = await _http.get(Uri.parse('$_docsBase/$path'), headers: await _headers()).timeout(const Duration(seconds: 20));
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) throw ApiError(502, _cloudError(res));
    return _decodeMap((jsonDecode(res.body) as Map<String, dynamic>)['fields'] as Map<String, dynamic>? ?? {});
  }

  Future<void> setDoc(String path, Map<String, Object?> data) async {
    final res = await _http
        .patch(Uri.parse('$_docsBase/$path'), headers: await _headers(), body: jsonEncode({'fields': _encodeMap(data)}))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw ApiError(502, _cloudError(res));
  }

  Future<void> deleteDoc(String path) async {
    final res = await _http.delete(Uri.parse('$_docsBase/$path'), headers: await _headers()).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200 && res.statusCode != 404) throw ApiError(502, _cloudError(res));
  }

  Future<List<FsDoc>> listDocs(String collectionPath) async {
    final out = <FsDoc>[];
    String? page;
    do {
      final uri = Uri.parse('$_docsBase/$collectionPath').replace(queryParameters: {'pageSize': '300', 'pageToken': ?page});
      final res = await _http.get(uri, headers: await _headers()).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw ApiError(502, _cloudError(res));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      for (final d in (body['documents'] as List? ?? const []).cast<Map<String, dynamic>>()) {
        out.add(FsDoc((d['name'] as String).split('/').last, _decodeMap(d['fields'] as Map<String, dynamic>? ?? {})));
      }
      page = body['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }

  String _cloudError(http.Response res) {
    if (res.statusCode == 403) return 'مش مسموح (اتأكد إن الفرع لسه في المجموعة)';
    return 'مشكلة في الاتصال بالنت (${res.statusCode})';
  }

  // ---------------------------------------------------------------- Firestore value encoding

  static Map<String, Object?> _encodeMap(Map<String, Object?> m) => {for (final e in m.entries) e.key: _encode(e.value)};

  static Map<String, Object?> _encode(Object? v) => switch (v) {
        null => {'nullValue': null},
        bool b => {'booleanValue': b},
        int i => {'integerValue': '$i'},
        double d => {'doubleValue': d},
        DateTime d => {'timestampValue': d.toUtc().toIso8601String()},
        String s => {'stringValue': s},
        List l => {
            'arrayValue': {'values': l.map(_encode).toList()},
          },
        Map m => {
            'mapValue': {'fields': _encodeMap(m.cast<String, Object?>())},
          },
        _ => {'stringValue': '$v'},
      };

  static Map<String, Object?> _decodeMap(Map<String, dynamic> fields) => {for (final e in fields.entries) e.key: _decode(e.value as Map<String, dynamic>)};

  static Object? _decode(Map<String, dynamic> v) {
    if (v.containsKey('stringValue')) return v['stringValue'];
    if (v.containsKey('integerValue')) return int.tryParse('${v['integerValue']}');
    if (v.containsKey('doubleValue')) return (v['doubleValue'] as num).toDouble();
    if (v.containsKey('booleanValue')) return v['booleanValue'];
    if (v.containsKey('timestampValue')) return DateTime.tryParse(v['timestampValue'] as String);
    if (v.containsKey('mapValue')) return _decodeMap((v['mapValue'] as Map<String, dynamic>)['fields'] as Map<String, dynamic>? ?? {});
    if (v.containsKey('arrayValue')) {
      return ((v['arrayValue'] as Map<String, dynamic>)['values'] as List? ?? const []).map((e) => _decode(e as Map<String, dynamic>)).toList();
    }
    return null;
  }
}

class FsDoc {
  FsDoc(this.id, this.data);
  final String id;
  final Map<String, Object?> data;
}
