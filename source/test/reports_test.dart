import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  final shop = TestShop();

  setUp(() => shop.start('reports'));
  tearDown(() => shop.stop());

  test('a full day adds up correctly', () async {
    final cashier = await shop.staff('sara', 'cashier', name: 'سارة');
    final sugar = await shop.product('سكر', cost: 2500, price: 3500, qtyMilli: 50000, category: 'بقالة');
    final meat = await shop.product('لحمة مفرومة', cost: 30000, price: 42000, unit: 'kg', qtyMilli: 20000, category: 'لحوم');
    final supplier = (await shop.owner.post('/api/suppliers', {'name': 'مورد السكر'}))['supplier'] as Map;

    // مبيعات: 4 سكر (140) + 1.5 كيلو لحمة (630) بخصم 10
    await cashier.post('/api/sales', {
      'items': [
        {'productId': sugar['id'], 'qtyMilli': 4000},
        {'productId': meat['id'], 'qtyMilli': 1500},
      ],
      'discountCents': 1000,
      'payments': [{'method': 'cash', 'amountCents': 76000}],
    });
    // شرا آجل جزئي من المورد
    await shop.owner.post('/api/purchases', {
      'supplierId': supplier['id'],
      'items': [{'productId': sugar['id'], 'qtyMilli': 10000, 'unitCostCents': 2500}],
      'paidCents': 5000,
    });
    // مصروف
    await cashier.post('/api/cash/moves', {'type': 'expense', 'amountCents': 3000, 'category': 'بنزين التوصيل'});
    // آجل على عميل
    final c = (await cashier.post('/api/customers', {'name': 'عم سيد', 'phone': '01009998887'}))['customer'] as Map;
    await cashier.post('/api/sales', {
      'customerId': c['id'],
      'items': [{'productId': sugar['id'], 'qtyMilli': 2000}],
      'payments': [],
    });

    final r = await shop.owner.get('/api/reports/summary');
    final sales = r['sales'] as Map;
    expect(sales['count'], 2);
    expect(sales['revenueCents'], 76000 + 7000);
    expect(sales['discountCents'], 1000);
    // التكلفة: 6 سكر × 25 + 1.5 × 300
    expect(sales['costCents'], 15000 + 45000);
    expect(sales['profitCents'], 83000 - 60000);
    expect(r['expenses']['totalCents'], 3000);
    expect(r['netProfitCents'], 23000 - 3000);
    expect(r['receivables']['totalCents'], 7000);
    expect(r['payables']['totalCents'], 20000);
    final categories = (sales['byCategory'] as List).cast<Map>();
    expect(categories.firstWhere((x) => x['name'] == 'لحوم')['revenue'], 63000);
    final top = (sales['topProducts'] as List).cast<Map>();
    expect(top.first['name'], 'لحمة مفرومة');
    expect(top.first['qty'], 1500);
    expect((sales['byCashier'] as List).single['name'], 'سارة');
    expect((r['daily'] as List).single['sales'], 83000);
  });

  test('reports are owner-only', () async {
    final cashier = await shop.staff('sara', 'cashier');
    await expectApiError(cashier.get('/api/reports/summary'), 403);
  });
}
