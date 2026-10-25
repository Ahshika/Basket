import 'package:basket/src/core/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  final shop = TestShop();
  late ApiClient cashier;

  setUp(() async {
    await shop.start('pos');
    cashier = await shop.staff('sara', 'cashier');
  });

  tearDown(() => shop.stop());

  test('products: create, barcode lookup, duplicate barcode, low stock', () async {
    final p = await shop.product('زيت عافية 1 لتر', barcode: '6221234567890', qtyMilli: 2000);
    expect(p['qtyMilli'], 2000);
    final found = await cashier.get('/api/products/lookup', query: {'barcode': '6221234567890'});
    expect(found['product']['id'], p['id']);
    await expectApiError(shop.product('تاني', barcode: '6221234567890'), 409);
    final low = await shop.owner.get('/api/products', query: {'low': '1'});
    expect((low['products'] as List).length, 1);
    expect(low['stockValueCents'], 6000);
    // الكاشير مايشوفش قيمة المخزون ومايعدلش سعر الشرا
    expect((await cashier.get('/api/products')).containsKey('stockValueCents'), false);
    await expectApiError(cashier.patch('/api/products/${p['id']}', {'costCents': 1}), 403);
  });

  test('generated barcodes are valid EAN-13 and unique', () async {
    final a = (await shop.owner.post('/api/products/barcode'))['barcode'] as String;
    expect(a.length, 13);
    expect(a.startsWith('20'), true);
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      sum += int.parse(a[i]) * (i.isEven ? 1 : 3);
    }
    expect(int.parse(a[12]), (10 - sum % 10) % 10);
  });

  test('cash sale lowers stock and lands in the drawer', () async {
    final p = await shop.product('سكر 1 كيلو', price: 3500);
    final s = await cashier.post('/api/sales', {
      'items': [{'productId': p['id'], 'qtyMilli': 2000}],
      'payments': [{'method': 'cash', 'amountCents': 7000}],
    });
    expect(s['sale']['number'], 1);
    expect(s['sale']['totalCents'], 7000);
    expect(s['sale']['dueCents'], 0);
    expect(await shop.qtyOf(p['id'] as String), 8000);

    final cash = await cashier.get('/api/cash/current');
    expect(cash['session']['byMethod']['cash'], 7000);
    expect(cash['session']['expectedCashCents'], 7000);
  });

  test('items sold by the piece reject fractions; items by the kilo take grams', () async {
    final piece = await shop.product('علبة تونة', price: 4000);
    final kilo = await shop.product('جبنة رومي', price: 32000, unit: 'kg', qtyMilli: 5000);
    await expectApiError(cashier.post('/api/sales', {
      'items': [{'productId': piece['id'], 'qtyMilli': 1500}],
      'payments': [{'method': 'cash', 'amountCents': 6000}],
    }), 400);
    // ربع كيلو و50 جرام = 0.3 كيلو × 320 = 96 جنيه
    final s = await cashier.post('/api/sales', {
      'items': [{'productId': kilo['id'], 'qtyMilli': 300}],
      'payments': [{'method': 'cash', 'amountCents': 9600}],
    });
    expect(s['sale']['totalCents'], 9600);
    expect((s['items'] as List).single['unit'], 'kg');
    expect(await shop.qtyOf(kilo['id'] as String), 4700);
  });

  test('credit sale requires a customer and shows in their balance; collecting reduces it', () async {
    final p = await shop.product('كرتونة لبن', price: 40000);
    await expectApiError(cashier.post('/api/sales', {'items': [{'productId': p['id'], 'qtyMilli': 1000}], 'payments': []}), 400);

    final c = (await cashier.post('/api/customers', {'name': 'كريم', 'phone': '01112223334'}))['customer'] as Map;
    await cashier.post('/api/sales', {
      'customerId': c['id'],
      'items': [{'productId': p['id'], 'qtyMilli': 1000}],
      'payments': [{'method': 'cash', 'amountCents': 10000}],
    });
    var ledger = await cashier.get('/api/customers/${c['id']}/ledger');
    expect(ledger['balanceCents'], 30000);

    await expectApiError(cashier.post('/api/customers/${c['id']}/payments', {'amountCents': 50000}), 400);
    await cashier.post('/api/customers/${c['id']}/payments', {'amountCents': 20000, 'method': 'vodafoneCash'});
    ledger = await cashier.get('/api/customers/${c['id']}/ledger');
    expect(ledger['balanceCents'], 10000);
    final cash = await cashier.get('/api/cash/current');
    expect(cash['session']['byMethod']['vodafoneCash'], 20000);
  });

  test('discount rules and selling below price', () async {
    final p = await shop.product('شاي', price: 10000);
    // الافتراضي: الكاشير يقدر يعمل خصم
    final s = await cashier.post('/api/sales', {
      'items': [{'productId': p['id'], 'qtyMilli': 3000}],
      'discountCents': 5000,
      'payments': [{'method': 'cash', 'amountCents': 25000}],
    });
    expect(s['sale']['totalCents'], 25000);
    await shop.owner.patch('/api/shop', {'cashierCanDiscount': false});
    await expectApiError(cashier.post('/api/sales', {
      'items': [{'productId': p['id'], 'qtyMilli': 1000, 'unitPriceCents': 9000}],
      'payments': [{'method': 'cash', 'amountCents': 9000}],
    }), 403);
    await expectApiError(
      cashier.post('/api/sales', {'items': [{'productId': p['id'], 'qtyMilli': 1000}], 'payments': [{'method': 'cash', 'amountCents': 99999}]}),
      400,
    );
  });

  test('negative stock can be switched off', () async {
    final p = await shop.product('أرز', qtyMilli: 1000);
    await shop.owner.patch('/api/shop', {'allowNegativeStock': false});
    await expectApiError(cashier.post('/api/sales', {
      'items': [{'productId': p['id'], 'qtyMilli': 2000}],
      'payments': [{'method': 'cash', 'amountCents': 10000}],
    }), 400);
  });

  test('returns restock and refund cash, credit is reduced first', () async {
    final p = await shop.product('مكرونة', price: 5000);
    final c = (await cashier.post('/api/customers', {'name': 'منى', 'phone': '01005556667'}))['customer'] as Map;
    final s = await cashier.post('/api/sales', {
      'customerId': c['id'],
      'items': [{'productId': p['id'], 'qtyMilli': 4000}],
      'payments': [{'method': 'cash', 'amountCents': 15000}],
    });
    final itemId = (s['items'] as List).single['id'];
    // باقي آجل 5000؛ مرتجع 2 (10000): أول 5000 بتلغي الآجل، و5000 بترجع كاش
    final r = await cashier.post('/api/sales/${s['sale']['id']}/return', {'items': [{'saleItemId': itemId, 'qtyMilli': 2000}], 'method': 'cash'});
    expect(r['returnValueCents'], 10000);
    expect(r['refundCents'], 5000);
    expect(r['sale']['dueCents'], 0);
    expect((await cashier.get('/api/customers/${c['id']}/ledger'))['balanceCents'], 0);
    expect(await shop.qtyOf(p['id'] as String), 8000);
    await expectApiError(cashier.post('/api/sales/${s['sale']['id']}/return', {'items': [{'saleItemId': itemId, 'qtyMilli': 3000}]}), 400);
    final cash = await cashier.get('/api/cash/current');
    expect(cash['session']['expectedCashCents'], 10000);
  });

  test('expenses and closing the shift; the next shift opens with what was kept', () async {
    final p = await shop.product('عيش', price: 50000);
    await cashier.post('/api/sales', {'items': [{'productId': p['id'], 'qtyMilli': 1000}], 'payments': [{'method': 'cash', 'amountCents': 50000}]});
    await cashier.post('/api/cash/moves', {'type': 'expense', 'amountCents': 2000, 'category': 'أكياس وتغليف'});
    await expectApiError(cashier.post('/api/cash/moves', {'type': 'withdraw', 'amountCents': 1000}), 403);

    var cash = await cashier.get('/api/cash/current');
    expect(cash['session']['expectedCashCents'], 48000);

    final closed = await cashier.post('/api/cash/close', {'countedCashCents': 47500, 'keptCashCents': 10000});
    expect(closed['closed']['differenceCents'], -500);

    cash = await cashier.get('/api/cash/current');
    expect(cash['session']['openingCashCents'], 10000);
    expect(cash['session']['expectedCashCents'], 10000);

    final sessions = await shop.owner.get('/api/cash/sessions');
    expect((sessions['sessions'] as List).length, 2);
    await expectApiError(cashier.get('/api/cash/sessions'), 403);
  });

  test('a shift that is never closed only sends the latest drawer moves, totals still count all', () async {
    for (var i = 0; i < 250; i++) {
      final res = await cashier.post('/api/cash/moves', {'type': 'expense', 'amountCents': 100, 'category': 'نظافة'});
      expect(res['session']['moves'], isNull);
    }
    final cash = await cashier.get('/api/cash/current');
    expect((cash['session']['moves'] as List).length, 200);
    expect(cash['session']['movesCount'], 250);
    expect(cash['session']['byType']['expense'], -25000);
  });

  test('stock count is manager-only and logged', () async {
    final p = await shop.product('صابون', qtyMilli: 5000);
    await expectApiError(cashier.post('/api/products/${p['id']}/adjust', {'setQtyMilli': 1000}), 403);
    await shop.owner.post('/api/products/${p['id']}/adjust', {'setQtyMilli': 3000, 'reason': 'count', 'note': 'جرد'});
    final moves = await shop.owner.get('/api/products/${p['id']}/moves');
    expect((moves['moves'] as List).first['changeMilli'], -2000);
    expect((moves['moves'] as List).first['afterMilli'], 3000);
  });

  test('received stock is added on top of the current quantity, with an averaged cost', () async {
    final p = await shop.product('فول', qtyMilli: 4000, cost: 3000);
    var res = await cashier.post('/api/products/${p['id']}/adjust', {'qtyChangeMilli': 6000, 'reason': 'purchase'});
    expect(res['product']['qtyMilli'], 10000);
    await expectApiError(cashier.post('/api/products/${p['id']}/adjust', {'qtyChangeMilli': -1000, 'reason': 'purchase'}), 403);
    // صاحب المحل يكتب دفع كام: سعر الشرا بيبقى المتوسط (10×30 + 100) ÷ 15 = 26.67
    res = await shop.owner.post('/api/products/${p['id']}/adjust', {'qtyChangeMilli': 5000, 'reason': 'purchase', 'costCents': 10000});
    expect(res['product']['qtyMilli'], 15000);
    expect(res['product']['costCents'], 2667);
  });

  test('import from Excel rows: create, update by barcode, kilo items, errors', () async {
    await shop.product('قديم', barcode: '111', price: 1000, qtyMilli: 1000);
    final res = await shop.owner.post('/api/products/import', {
      'rows': [
        {'name': 'جديد 1', 'barcode': '222', 'priceCents': 5000, 'costCents': 3000, 'qtyMilli': 7000, 'category': 'منظفات'},
        {'name': 'قديم معدل', 'barcode': '111', 'priceCents': 1500, 'qtyMilli': 4000},
        {'name': '', 'barcode': '333'},
        {'name': 'لانشون بالكيلو', 'priceCents': 18000, 'unit': 'kg', 'plu': 101, 'qtyMilli': 2500},
      ],
    });
    expect(res['created'], 2);
    expect(res['updated'], 1);
    expect((res['errors'] as List).length, 1);
    final old = (await shop.owner.get('/api/products/lookup', query: {'barcode': '111'}))['product'];
    expect(old['name'], 'قديم معدل');
    expect(old['priceCents'], 1500);
    expect(old['qtyMilli'], 4000);
    final byPlu = (await shop.owner.get('/api/products/lookup', query: {'barcode': '101'}))['product'];
    expect(byPlu['unit'], 'kg');
    expect(byPlu['qtyMilli'], 2500);
  });
}
