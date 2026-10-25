import 'package:basket/src/core/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  final shop = TestShop();
  late ApiClient cashier;

  setUp(() async {
    await shop.start('expiry');
    cashier = await shop.staff('sara', 'cashier');
  });

  tearDown(() => shop.stop());

  Future<List<Map<String, dynamic>>> batches(String productId) async =>
      ((await shop.owner.get('/api/products/$productId/batches'))['batches'] as List).cast<Map<String, dynamic>>();

  test('FEFO: sales take from the batch that expires first, returns go back to the same batch', () async {
    final milk = await shop.product('لبن جهينة 1 لتر', price: 4000, cost: 3000, qtyMilli: 0, trackExpiry: true);
    final supplier = (await shop.owner.post('/api/suppliers', {'name': 'جهينة'}))['supplier'] as Map;
    // دفعتين: واحدة بتخلص بعد 20 يوم (اتشرت الأول)، وواحدة بعد 5 أيام (وصلت بعدها)
    await shop.owner.post('/api/purchases', {
      'supplierId': supplier['id'],
      'items': [{'productId': milk['id'], 'qtyMilli': 10000, 'unitCostCents': 3000, 'expiresOn': dayFromToday(20)}],
    });
    await shop.owner.post('/api/purchases', {
      'supplierId': supplier['id'],
      'items': [{'productId': milk['id'], 'qtyMilli': 6000, 'unitCostCents': 3200, 'expiresOn': dayFromToday(5)}],
    });
    // الصنف ده لازم ياخد تاريخ صلاحية في الشرا
    await expectApiError(shop.owner.post('/api/purchases', {
      'items': [{'productId': milk['id'], 'qtyMilli': 1000, 'unitCostCents': 3000}],
    }), 400);
    expect(await shop.qtyOf(milk['id'] as String), 16000);

    // بيع 8: الـ 6 اللي بتخلص الأول + 2 من التانية
    final sale = await cashier.post('/api/sales', {
      'items': [{'productId': milk['id'], 'qtyMilli': 8000}],
      'payments': [{'method': 'cash', 'amountCents': 32000}],
    });
    var b = await batches(milk['id'] as String);
    expect(b.length, 1);
    expect(b.single['expiresOn'], dayFromToday(20));
    expect(b.single['qtyMilli'], 8000);
    // التكلفة متوسط الدفعتين: (6 × 32 + 2 × 30) ÷ 8 = 31.5
    final item = (sale['items'] as List).single;
    expect((await shop.owner.get('/api/sales/${sale['sale']['id']}'))['items'][0]['costCents'], 3150);

    // مرتجع 7: بيرجع للدفعتين اللي اتسحب منهم، فالدفعة القريبة بترجع
    await cashier.post('/api/sales/${sale['sale']['id']}/return', {'items': [{'saleItemId': item['id'], 'qtyMilli': 7000}]});
    b = await batches(milk['id'] as String);
    expect(b.length, 2);
    expect(b.first['expiresOn'], dayFromToday(5));
    expect(b.map((x) => x['qtyMilli'] as int).fold<int>(0, (s, q) => s + q), 15000);
    expect(await shop.qtyOf(milk['id'] as String), 15000);
  });

  test('near-expiry alert, writing off an expired batch, and the expiry/waste report', () async {
    await shop.owner.patch('/api/shop', {'expiryAlertDays': 7});
    final yogurt = await shop.product('زبادي', price: 1000, cost: 600, qtyMilli: 12000, trackExpiry: true, expiresOn: dayFromToday(-1));
    await shop.owner.post('/api/products/${yogurt['id']}/adjust', {'qtyChangeMilli': 20000, 'reason': 'purchase', 'expiresOn': dayFromToday(3)});
    await shop.owner.post('/api/products/${yogurt['id']}/adjust', {'qtyChangeMilli': 30000, 'reason': 'purchase', 'expiresOn': dayFromToday(60)});

    var dash = await shop.owner.get('/api/dashboard');
    expect(dash['expiredCount'], 1);
    expect(dash['expiringCount'], 1);
    final expiring = await cashier.get('/api/batches/expiring');
    final list = (expiring['batches'] as List).cast<Map<String, dynamic>>();
    expect(list.length, 2);
    expect(list.first['daysLeft'], -1);
    expect(list.last['daysLeft'], 3);

    // الكاشير مايقدرش يشيل هالك، مسؤول الشفت يقدر
    final expired = list.first;
    await expectApiError(cashier.post('/api/batches/${expired['id']}/waste', {}), 403);
    final sup = await shop.staff('mona', 'supervisor');
    final w = await sup.post('/api/batches/${expired['id']}/waste', {'reason': 'expired'});
    expect(w['wasteValueCents'], 7200); // 12 × 6 جنيه
    expect(await shop.qtyOf(yogurt['id'] as String), 50000);
    // جزء من دفعة تالف
    final soon = list.last;
    await sup.post('/api/batches/${soon['id']}/waste', {'reason': 'damaged', 'qtyMilli': 2000});

    dash = await shop.owner.get('/api/dashboard');
    expect(dash['expiredCount'], 0);

    final report = await sup.get('/api/reports/expiry');
    expect(report['wasteValueCents'], 7200 + 1200);
    expect((report['waste'] as List).map((x) => x['reason']), containsAll(['expired', 'damaged']));
    expect((report['expiring'] as List).single['qtyMilli'], 18000);
    expect(report['expiringValueCents'], 10800);
    expect(report['expired'], isEmpty);

    // الهالك بيقلل صافي الربح في التقرير العام
    final summary = await shop.owner.get('/api/reports/summary');
    expect(summary['waste']['totalCents'], 8400);
    expect(summary['netProfitCents'], -8400);
  });

  test('turning expiry tracking on keeps the current stock as one undated batch', () async {
    final p = await shop.product('بسكويت', qtyMilli: 9000);
    await shop.owner.patch('/api/products/${p['id']}', {'trackExpiry': true});
    final b = await batches(p['id'] as String);
    expect(b.single['qtyMilli'], 9000);
    expect(b.single['expiresOn'], isNull);
    // جرد دفعة بعينها
    await shop.owner.post('/api/products/${p['id']}/adjust', {'batchId': b.single['id'], 'setQtyMilli': 7000, 'reason': 'count'});
    expect(await shop.qtyOf(p['id'] as String), 7000);
    await expectApiError(shop.owner.post('/api/products/${p['id']}/adjust', {'qtyChangeMilli': 1000, 'reason': 'expired'}), 400);
  });
}
