import 'package:basket/src/core/api_client.dart';
import 'package:basket/src/core/pos_types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('scale barcode parsing', () {
    const f = ScaleFormat();

    test('weight label: prefix + PLU + grams + check digit', () {
      final code = buildScaleBarcode(f, '21', 123, 1250);
      expect(code.substring(0, 12), '210012301250');
      expect(ean13Valid(code), true);
      final r = parseScaleBarcode(code, f)!;
      expect(r.plu, 123);
      expect(r.grams, 1250);
      expect(r.priceCents, isNull);
    });

    test('price label, other lengths, and rejected codes', () {
      const priced = ScaleFormat(prefixes: ['28'], pluLength: 4, valueLength: 5, mode: 'price');
      final code = buildScaleBarcode(priced, '28', 42, 8750);
      final r = parseScaleBarcode(code, priced)!;
      expect(r.plu, 42);
      expect(r.priceCents, 8750);
      // رقم تحقق غلط، أو بادئة مش متسجلة، أو الميزان مقفول
      expect(parseScaleBarcode('${code.substring(0, 12)}${(int.parse(code[12]) + 1) % 10}', priced), isNull);
      expect(parseScaleBarcode(buildScaleBarcode(f, '20', 42, 100), f), isNull);
      expect(parseScaleBarcode(code, const ScaleFormat(enabled: false, prefixes: ['28'], pluLength: 4, mode: 'price')), isNull);
      expect(const ScaleFormat(pluLength: 6, valueLength: 6).validate(), isNotNull);
      expect(const ScaleFormat(prefixes: ['31']).validate(), isNotNull);
    });

    test('quantities in thousandths', () {
      expect(formatQty(1250, SaleUnit.kg), '1.25');
      expect(formatQty(3000, SaleUnit.piece), '3');
      expect(formatQty(500, SaleUnit.kg), '0.5');
      expect(parseQty('١٫٢٥'), 1250);
      expect(parseQty('0,75'), 750);
      expect(parseQty('x'), isNull);
      expect(lineTotal(32000, 333), 10656);
    });
  });

  group('selling by weight', () {
    final shop = TestShop();
    late ApiClient cashier;

    setUp(() async {
      await shop.start('scale');
      cashier = await shop.staff('sara', 'cashier');
    });

    tearDown(() => shop.stop());

    test('a weighted sale from a scale barcode: lookup, exact total, stock in grams, return part of it', () async {
      // جبنة رومي: 320 جنيه للكيلو، رقمها على الميزان 123، والمخزون 5 كيلو
      final cheese = await shop.product('جبنة رومي', unit: 'kg', plu: 123, price: 32000, cost: 25000, qtyMilli: 5000);
      final code = buildScaleBarcode(const ScaleFormat(), '21', 123, 1250);

      final found = await cashier.get('/api/products/lookup', query: {'barcode': code});
      expect(found['product']['id'], cheese['id']);
      expect(found['scale']['qtyMilli'], 1250);
      expect(found['scale']['totalCents'], 40000);

      // السيرفر بيقرا الوزن من الباركود بنفسه، حتى لو البرنامج بعت كمية تانية
      final sale = await cashier.post('/api/sales', {
        'items': [{'productId': cheese['id'], 'scaleBarcode': code, 'qtyMilli': 99000}],
        'payments': [{'method': 'cash', 'amountCents': 40000}],
      });
      final item = (sale['items'] as List).single;
      expect(item['qtyMilli'], 1250);
      expect(item['totalCents'], 40000);
      expect(sale['sale']['totalCents'], 40000);
      expect(await shop.qtyOf(cheese['id'] as String), 3750);

      // مرتجع نص كيلو = 160 جنيه
      final r = await cashier.post('/api/sales/${sale['sale']['id']}/return', {
        'items': [{'saleItemId': item['id'], 'qtyMilli': 500}],
        'method': 'cash',
      });
      expect(r['refundCents'], 16000);
      expect(await shop.qtyOf(cheese['id'] as String), 4250);

      // الربح بيتحسب بالجرامات: (1250 − 500) جرام × (320 − 250) = 52.5 جنيه
      final report = await shop.owner.get('/api/reports/summary');
      expect(report['sales']['revenueCents'], 24000);
      expect(report['sales']['profitCents'], 5250);
    });

    test('price-embedded labels keep the printed total; a PLU typed by hand finds the item', () async {
      await shop.owner.patch('/api/shop', {
        'scaleFormat': {'enabled': true, 'prefixes': ['28'], 'pluLength': 4, 'valueLength': 5, 'mode': 'price'},
      });
      final halawa = await shop.product('حلاوة طحينية', unit: 'kg', plu: 7, price: 12000, qtyMilli: 3000);
      final code = buildScaleBarcode(const ScaleFormat(pluLength: 4, mode: 'price'), '28', 7, 4130);
      final sale = await cashier.post('/api/sales', {
        'items': [{'productId': halawa['id'], 'scaleBarcode': code}],
        'payments': [{'method': 'cash', 'amountCents': 4130}],
      });
      final item = (sale['items'] as List).single;
      expect(item['totalCents'], 4130);
      expect(item['qtyMilli'], 344); // 41.30 ÷ 120 = 0.344 كيلو
      expect((await cashier.get('/api/products/lookup', query: {'barcode': '7'}))['product']['id'], halawa['id']);
    });

    test('bad scale settings, duplicate PLU and labels for the wrong item are rejected', () async {
      await expectApiError(shop.owner.patch('/api/shop', {'scaleFormat': {'prefixes': ['21'], 'pluLength': 6, 'valueLength': 6}}), 400);
      await expectApiError(cashier.patch('/api/shop', {'expiryAlertDays': 10}), 403);
      final a = await shop.product('بسطرمة', unit: 'kg', plu: 55, price: 50000);
      await expectApiError(shop.product('لانشون', unit: 'kg', plu: 55), 409);
      final b = await shop.product('علبة جبنة', price: 2000);
      final code = buildScaleBarcode(const ScaleFormat(), '22', 55, 200);
      await expectApiError(cashier.post('/api/sales', {
        'items': [{'productId': b['id'], 'scaleBarcode': code}],
        'payments': [],
      }), 400);
      final unknown = await cashier.get('/api/products/lookup', query: {'barcode': buildScaleBarcode(const ScaleFormat(), '22', 999, 200)});
      expect(unknown['product'], isNull);
      expect(unknown['error'], isNotNull);
      expect(a['plu'], 55);
    });
  });
}
