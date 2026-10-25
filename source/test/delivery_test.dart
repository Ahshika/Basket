import 'package:basket/src/core/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  final shop = TestShop();
  late ApiClient cashier;

  setUp(() async {
    await shop.start('delivery');
    cashier = await shop.staff('sara', 'cashier', name: 'سارة');
  });

  tearDown(() => shop.stop());

  test('a phone order through to the driver handing in the cash', () async {
    await shop.owner.patch('/api/shop', {'deliveryFeeCents': 1500});
    final oil = await shop.product('زيت كريستال', price: 9000, qtyMilli: 20000);
    final cheese = await shop.product('جبنة بيضا', price: 16000, unit: 'kg', qtyMilli: 10000, trackExpiry: true, expiresOn: dayFromToday(10));
    // طيار ليه حساب على البرنامج (بيستخدمه من موبايله)
    final driverApi = await shop.staff('hamada', 'driver', name: 'حمادة');
    final drivers = ((await cashier.get('/api/drivers'))['drivers'] as List).cast<Map<String, dynamic>>();
    final driver = drivers.singleWhere((d) => d['name'] == 'حمادة');

    // طلب جديد بالتليفون من عميل جديد
    var res = await cashier.post('/api/delivery', {
      'customerName': 'أم كريم', 'phone': '01001112223', 'address': 'شارع التحرير، عمارة 5، الدور 3',
      'channel': 'whatsapp',
      'items': [
        {'productId': oil['id'], 'qtyMilli': 2000},
        {'productId': cheese['id'], 'qtyMilli': 750},
      ],
    });
    final order = res['order'] as Map;
    final id = order['id'];
    expect(order['status'], 'new');
    expect(order['subtotalCents'], 18000 + 12000);
    expect(order['deliveryFeeCents'], 1500);
    expect(order['totalCents'], 31500);
    // الطلب لسه ماخصمش من المخزون
    expect(await shop.qtyOf(oil['id'] as String), 20000);

    // تعديل قبل ما يخرج: الزيت بقى 3
    res = await cashier.patch('/api/delivery/$id', {
      'items': [
        {'productId': oil['id'], 'qtyMilli': 3000},
        {'productId': cheese['id'], 'qtyMilli': 750},
      ],
    });
    expect(res['order']['totalCents'], 27000 + 12000 + 1500);

    // الطيار مايشوفش الطلب لحد ما يتسلمه
    await expectApiError(driverApi.get('/api/delivery/$id'), 403);
    await cashier.post('/api/delivery/$id/status', {'status': 'preparing'});
    await expectApiError(cashier.post('/api/delivery/$id/status', {'status': 'out'}), 400); // من غير طيار
    await cashier.post('/api/delivery/$id/status', {'status': 'out', 'driverId': driver['id']});
    await expectApiError(cashier.patch('/api/delivery/$id', {'deliveryFeeCents': 0}), 400); // خرج خلاص
    await expectApiError(driverApi.post('/api/delivery/$id/status', {'status': 'preparing'}), 403);

    // الطيار من موبايله: شايف الطلب، وبيقول اتسلم
    final mine = (await driverApi.get('/api/delivery'))['orders'] as List;
    expect(mine.single['id'], id);
    expect((await driverApi.get('/api/dashboard'))['myOpenDeliveries'], 1);
    res = await driverApi.post('/api/delivery/$id/status', {'status': 'delivered'});
    expect(res['order']['status'], 'delivered');
    expect(res['order']['collectedCents'], 40500);
    expect(res['order']['settled'], false);

    // التسليم عمل فاتورة على العميل وخصم المخزون (FEFO للجبنة)، بس الفلوس لسه مع الطيار
    final sale = await shop.owner.get('/api/sales/${res['order']['saleId']}');
    expect(sale['sale']['totalCents'], 40500);
    expect(sale['sale']['dueCents'], 0);
    expect(sale['sale']['deliveryNumber'], order['number']);
    expect((sale['items'] as List).map((i) => i['name']), contains('رسوم توصيل'));
    expect(await shop.qtyOf(oil['id'] as String), 17000);
    expect(await shop.qtyOf(cheese['id'] as String), 9250);
    final customer = (await cashier.get('/api/customers/lookup', query: {'phone': '01001112223'}))['customer'] as Map;
    expect(customer['balanceCents'], 0);
    expect(customer['address'], 'شارع التحرير، عمارة 5، الدور 3');
    expect(((await cashier.get('/api/cash/current'))['session'] as Map)['expectedCashCents'], 0);
    expect((await shop.owner.get('/api/dashboard'))['driversCashCents'], 40500);
    expect((await shop.owner.get('/api/cash/drawers'))['drivers'][0]['outstandingCents'], 40500);

    // التوريد: حمادة سلّم 400 بس، فيه عجز 5 جنيه، والفلوس دخلت درج سارة
    final pending = await cashier.get('/api/drivers/${driver['id']}/pending');
    expect(pending['expectedCents'], 40500);
    expect((pending['orders'] as List).length, 1);
    final settled = await cashier.post('/api/drivers/${driver['id']}/settle', {'countedCents': 40000});
    expect(settled['differenceCents'], -500);
    expect(settled['ordersCount'], 1);
    final drawer = (await cashier.get('/api/cash/current'))['session'] as Map;
    expect(drawer['expectedCashCents'], 40000);
    expect(drawer['byType']['driver_settlement'], 40000);
    await expectApiError(cashier.post('/api/drivers/${driver['id']}/settle', {}), 400); // مفيش حاجة تانية
    expect(((await shop.owner.get('/api/delivery/$id'))['order'] as Map)['settled'], true);

    final report = await shop.owner.get('/api/reports/summary');
    expect(report['delivery']['delivered'], 1);
    expect(report['delivery']['feesCents'], 1500);
    expect(report['delivery']['shortageCents'], -500);
    expect(report['delivery']['withDriversCents'], 0);
    expect(report['sales']['revenueCents'], 40500);
  });

  test('cancelling, drivers without a login, and who can do what', () async {
    final p = await shop.product('مياه معدنية', price: 700, qtyMilli: 50000);
    final sup = await shop.staff('mona', 'supervisor');
    // طيار اسم بس (من غير حساب)
    final d = (await sup.post('/api/drivers', {'name': 'سيد', 'phone': '01111111111'}))['driver'] as Map;
    await expectApiError(cashier.post('/api/drivers', {'name': 'x'}), 403);

    final c = (await cashier.post('/api/customers', {'name': 'منى', 'phone': '01222222222', 'address': 'المعادي'}))['customer'] as Map;
    final o = (await cashier.post('/api/delivery', {
      'customerId': c['id'], 'address': 'المعادي، شارع 9', 'deliveryFeeCents': 0,
      'items': [{'productId': p['id'], 'qtyMilli': 6000}],
    }))['order'] as Map;
    await cashier.post('/api/delivery/${o['id']}/status', {'status': 'out', 'driverId': d['id']});
    await expectApiError(cashier.post('/api/delivery/${o['id']}/status', {'status': 'cancelled'}), 400); // من غير سبب
    final res = await cashier.post('/api/delivery/${o['id']}/status', {'status': 'cancelled', 'reason': 'العميل مارد'});
    expect(res['order']['status'], 'cancelled');
    await expectApiError(cashier.post('/api/delivery/${o['id']}/status', {'status': 'delivered'}), 400);
    expect(await shop.qtyOf(p['id'] as String), 50000);

    // قايمة الطلبات المفتوحة فاضية، وكل الطلبات فيها الملغي
    expect((await cashier.get('/api/delivery'))['orders'], isEmpty);
    expect(((await cashier.get('/api/delivery', query: {'status': 'all'}))['orders'] as List).single['cancelReason'], 'العميل مارد');
    // الطيار اللي معاه فلوس مايتوقفش؛ ده مش معاه حاجة
    await sup.patch('/api/drivers/${d['id']}', {'active': false});
    expect(((await cashier.get('/api/drivers'))['drivers'] as List), isEmpty);
    // الطيار (الحساب) مايقدرش يبيع أو يعمل طلبات
    final driverApi = await shop.staff('hamada', 'driver');
    await expectApiError(driverApi.post('/api/delivery', {'address': 'x', 'items': []}), 403);
    await expectApiError(driverApi.get('/api/products/${p['id']}/moves'), 403);
    expect((await driverApi.get('/api/delivery'))['orders'], isEmpty);
  });
}
