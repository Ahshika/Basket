import 'dart:io';

import 'package:basket/src/core/api_client.dart';
import 'package:basket/src/server/api_server.dart';
import 'package:flutter_test/flutter_test.dart';

/// سيرفر لكل اختبار: محل جديد بصاحب محل (owner / owner123)، وكل موظف بيدخل من جهاز لوحده.
class TestShop {
  late Directory dir;
  late BasketServer server;
  late ApiClient owner;
  final _clients = <ApiClient>[];

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start(String name) async {
    dir = await Directory.systemTemp.createTemp('basket_$name');
    server = BasketServer(dataDir: dir.path, requestedPort: 0, cloudSync: false);
    await server.start();
    owner = _track(ApiClient(base));
    owner.token = (await owner.post('/api/setup', {
      'shopName': 'سوبر ماركت النور', 'ownerName': 'أحمد', 'username': 'owner', 'password': 'owner123', 'deviceName': 'PC-owner',
    }))['token'] as String;
  }

  Future<void> stop() async {
    for (final c in _clients) {
      c.close();
    }
    _clients.clear();
    await server.stop();
    await dir.delete(recursive: true);
  }

  ApiClient _track(ApiClient c) {
    _clients.add(c);
    return c;
  }

  /// موظف جديد داخل من جهاز اسمه [device].
  Future<ApiClient> staff(String username, String role, {String? device, String name = 'موظف'}) async {
    await owner.post('/api/users', {'name': name, 'username': username, 'password': '${username}1234', 'role': role});
    final c = _track(ApiClient(base));
    c.token = (await c.post('/api/auth/login', {'username': username, 'password': '${username}1234', 'deviceName': device ?? 'device-$username'}))['token'] as String;
    return c;
  }

  Future<Map<String, dynamic>> product(
    String name, {
    String? barcode,
    int cost = 3000,
    int price = 5000,
    int qtyMilli = 10000,
    String unit = 'piece',
    int? plu,
    bool trackExpiry = false,
    String? expiresOn,
    String category = 'بقالة',
  }) async =>
      (await owner.post('/api/products', {
        'name': name, 'barcode': ?barcode, 'category': category, 'costCents': cost, 'priceCents': price, 'qtyMilli': qtyMilli,
        'lowStockMilli': 2000, 'unit': unit, 'plu': ?plu, 'trackExpiry': trackExpiry, 'expiresOn': ?expiresOn,
      }))['product'] as Map<String, dynamic>;

  Future<int> qtyOf(String productId) async {
    final all = (await owner.get('/api/products', query: {'limit': '500'}))['products'] as List;
    return all.firstWhere((p) => p['id'] == productId)['qtyMilli'] as int;
  }
}

Future<void> expectApiError(Future<Object?> f, int status) async {
  try {
    await f;
    fail('expected $status');
  } on ApiException catch (e) {
    expect(e.status, status, reason: e.message);
  }
}

/// تاريخ يوم بعد [days] من النهارده بشكل YYYY-MM-DD.
String dayFromToday(int days) {
  final n = DateTime.now();
  final d = DateTime(n.year, n.month, n.day + days);
  return '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';
}
