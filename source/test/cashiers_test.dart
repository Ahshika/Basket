import 'package:basket/src/core/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  final shop = TestShop();
  late ApiClient sara;
  late ApiClient omar;

  setUp(() async {
    await shop.start('cashiers');
    sara = await shop.staff('sara', 'cashier', device: 'كاشير 1', name: 'سارة');
    omar = await shop.staff('omar', 'cashier', device: 'كاشير 2', name: 'عمر');
  });

  tearDown(() => shop.stop());

  test('two cashiers sell at the same time, each into their own drawer', () async {
    final rice = await shop.product('أرز الضحى 1 كيلو', price: 3000, qtyMilli: 100000);
    // سارة بتبدأ ورديتها بفكة 200 جنيه
    await sara.post('/api/cash/open', {'openingCashCents': 20000});
    await expectApiError(sara.post('/api/cash/open', {'openingCashCents': 0}), 409);

    // الاتنين بيبيعوا في نفس اللحظة
    Future<Object?> sell(ApiClient c, int qty) => c.post('/api/sales', {
          'items': [{'productId': rice['id'], 'qtyMilli': qty * 1000}],
          'payments': [{'method': 'cash', 'amountCents': qty * 3000}],
        });
    await Future.wait([
      for (var i = 0; i < 5; i++) sell(sara, 1),
      for (var i = 0; i < 5; i++) sell(omar, 2),
    ]);
    await omar.post('/api/cash/moves', {'type': 'expense', 'amountCents': 1000, 'category': 'أكياس وتغليف'});

    final s = (await sara.get('/api/cash/current'))['session'] as Map;
    final o = (await omar.get('/api/cash/current'))['session'] as Map;
    expect(s['id'] == o['id'], false);
    expect(s['userName'], 'سارة');
    expect(s['deviceName'], 'كاشير 1');
    expect(s['salesCount'], 5);
    expect(s['expectedCashCents'], 20000 + 15000);
    expect(o['salesCount'], 5);
    expect(o['expectedCashCents'], 30000 - 1000);
    expect(await shop.qtyOf(rice['id'] as String), 100000 - 15000);

    // المالك ومسؤول الشفت بيشوفوا كل الأدراج المفتوحة، والكاشير لا
    final sup = await shop.staff('mona', 'supervisor');
    final drawers = await sup.get('/api/cash/drawers');
    final list = (drawers['drawers'] as List).cast<Map<String, dynamic>>();
    expect(list.map((d) => d['userName']), containsAll(['سارة', 'عمر']));
    expect(drawers['totalExpectedCashCents'], 35000 + 29000);
    await expectApiError(sara.get('/api/cash/drawers'), 403);
    expect((await shop.owner.get('/api/dashboard'))['openDrawers'], 2);

    // سارة بتقفل درجها؛ درج عمر بيفضل مفتوح زي ما هو
    final closed = await sara.post('/api/cash/close', {'countedCashCents': 35000, 'keptCashCents': 20000});
    expect(closed['closed']['differenceCents'], 0);
    expect(((await sup.get('/api/cash/drawers'))['drawers'] as List).single['userName'], 'عمر');
    expect(((await omar.get('/api/cash/current'))['session'] as Map)['id'], o['id']);

    // الوردية الجديدة لسارة بتبدأ بالفكة اللي سابتها في درجها هي
    final next = (await sara.get('/api/cash/current'))['session'] as Map;
    expect(next['openingCashCents'], 20000);
    expect(next['salesCount'], 0);

    // مسؤول الشفت يقفل درج عمر بالنيابة عنه، والعجز بيتسجل
    final byManager = await sup.post('/api/cash/sessions/${o['id']}/close', {'countedCashCents': 28500});
    expect(byManager['closed']['differenceCents'], -500);
    await expectApiError(sup.post('/api/cash/sessions/${o['id']}/close', {'countedCashCents': 1}), 400);
    await expectApiError(omar.post('/api/cash/close', {'countedCashCents': 0}), 400);

    // تقرير اليوم بيقسم المبيعات على الكاشيرية
    final report = await shop.owner.get('/api/reports/summary');
    final byCashier = (report['sales']['byCashier'] as List).cast<Map<String, dynamic>>();
    expect(byCashier.firstWhere((c) => c['name'] == 'عمر')['revenue'], 30000);
    expect(byCashier.firstWhere((c) => c['name'] == 'سارة')['revenue'], 15000);
    expect(report['cashDifferenceCents'], -500);

    // تاريخ ورديات كاشير واحد
    final history = await shop.owner.get('/api/cash/sessions', query: {'userId': next['userId'] as String});
    expect((history['sessions'] as List).length, 2);
  });

  test('returns and expenses go to the drawer of whoever made them', () async {
    final p = await shop.product('زيت', price: 10000);
    final sale = await sara.post('/api/sales', {
      'items': [{'productId': p['id'], 'qtyMilli': 2000}],
      'payments': [{'method': 'cash', 'amountCents': 20000}],
    });
    // عمر هو اللي رجّع للزبون من درجه
    await omar.post('/api/sales/${sale['sale']['id']}/return', {
      'items': [{'saleItemId': (sale['items'] as List).single['id'], 'qtyMilli': 1000}],
    });
    expect(((await sara.get('/api/cash/current'))['session'] as Map)['expectedCashCents'], 20000);
    expect(((await omar.get('/api/cash/current'))['session'] as Map)['expectedCashCents'], -10000);
  });
}
