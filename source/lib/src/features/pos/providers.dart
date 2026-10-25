import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pos_models.dart';
import '../../core/providers.dart';
import '../../core/realtime.dart';

typedef ProductQuery = ({String q, String? category, bool low});

final productsProvider = FutureProvider.autoDispose.family<({List<Product> items, int count, int lowCount, int? stockValueCents}), ProductQuery>(
  (ref, query) async {
    refreshOn(ref, 'products');
    final res = await apiOf(ref).get('/api/products', query: {
      if (query.q.isNotEmpty) 'q': query.q,
      'category': ?query.category,
      if (query.low) 'low': '1',
      'limit': '500',
    });
    return (
      items: (res['products'] as List).map((j) => Product(j as Map<String, dynamic>)).toList(),
      count: res['count'] as int? ?? 0,
      lowCount: res['lowCount'] as int? ?? 0,
      stockValueCents: res['stockValueCents'] as int?,
    );
  },
);

final categoriesProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  refreshOn(ref, 'products');
  final res = await apiOf(ref).get('/api/products/categories');
  return (res['categories'] as List).cast<String>();
});

final productBatchesProvider = FutureProvider.autoDispose.family<List<Batch>, String>((ref, productId) async {
  refreshOn(ref, 'products');
  final res = await apiOf(ref).get('/api/products/$productId/batches');
  return (res['batches'] as List).map((j) => Batch(j as Map<String, dynamic>)).toList();
});

/// الدفعات اللي صلاحيتها قربت تخلص أو خلصت، خلال [days] يوم.
final expiringProvider = FutureProvider.autoDispose.family<List<Batch>, int>((ref, days) async {
  refreshOn(ref, 'products');
  final res = await apiOf(ref).get('/api/batches/expiring', query: {'days': '$days'});
  return (res['batches'] as List).map((j) => Batch(j as Map<String, dynamic>)).toList();
});

typedef SalesQuery = ({String q, bool dueOnly});

final salesProvider = FutureProvider.autoDispose.family<List<SaleSummary>, SalesQuery>((ref, query) async {
  refreshOn(ref, 'sales');
  final res = await apiOf(ref).get('/api/sales', query: {
    if (query.q.isNotEmpty) 'q': query.q,
    if (query.dueOnly) 'due': '1',
    'limit': '300',
  });
  return (res['sales'] as List).map((j) => SaleSummary(j as Map<String, dynamic>)).toList();
});

final saleDetailProvider = FutureProvider.autoDispose.family<SaleDetail, String>((ref, id) async {
  refreshOn(ref, 'sales');
  return SaleDetail(await apiOf(ref).get('/api/sales/$id'));
});

final cashCurrentProvider = FutureProvider.autoDispose<({CashSession session, List<String> categories})>((ref) async {
  refreshOn(ref, 'cash');
  final res = await apiOf(ref).get('/api/cash/current');
  return (
    session: CashSession(res['session'] as Map<String, dynamic>),
    categories: (res['expenseCategories'] as List).cast<String>(),
  );
});

/// كل الأدراج المفتوحة دلوقتي (للمالك ومسؤول الشفت)، والفلوس اللي مع الطيارين.
final openDrawersProvider = FutureProvider.autoDispose<({List<CashSession> drawers, int totalCents, List<Map<String, dynamic>> drivers})>((ref) async {
  refreshOn(ref, 'cash');
  refreshOn(ref, 'drivers');
  final res = await apiOf(ref).get('/api/cash/drawers');
  return (
    drawers: (res['drawers'] as List).map((j) => CashSession(j as Map<String, dynamic>)).toList(),
    totalCents: res['totalExpectedCashCents'] as int? ?? 0,
    drivers: (res['drivers'] as List).cast<Map<String, dynamic>>(),
  );
});

final cashSessionsProvider = FutureProvider.autoDispose<List<CashSession>>((ref) async {
  refreshOn(ref, 'cash');
  final res = await apiOf(ref).get('/api/cash/sessions');
  return (res['sessions'] as List).map((j) => CashSession(j as Map<String, dynamic>)).toList();
});

final cashSessionProvider = FutureProvider.autoDispose.family<CashSession, String>((ref, id) async {
  refreshOn(ref, 'cash');
  final res = await apiOf(ref).get('/api/cash/sessions/$id');
  return CashSession(res['session'] as Map<String, dynamic>);
});

final customerLedgerProvider = FutureProvider.autoDispose.family<({int balanceCents, List<Map<String, dynamic>> entries}), String>((ref, id) async {
  refreshOn(ref, 'customers');
  refreshOn(ref, 'sales');
  final res = await apiOf(ref).get('/api/customers/$id/ledger');
  return (balanceCents: res['balanceCents'] as int, entries: (res['entries'] as List).cast<Map<String, dynamic>>());
});

final suppliersProvider = FutureProvider.autoDispose<List<Supplier>>((ref) async {
  refreshOn(ref, 'suppliers');
  final res = await apiOf(ref).get('/api/suppliers');
  return (res['suppliers'] as List).map((j) => Supplier(j as Map<String, dynamic>)).toList();
});

final purchasesProvider = FutureProvider.autoDispose<List<PurchaseSummary>>((ref) async {
  refreshOn(ref, 'suppliers');
  final res = await apiOf(ref).get('/api/purchases');
  return (res['purchases'] as List).map((j) => PurchaseSummary(j as Map<String, dynamic>)).toList();
});

// ---------------------------------------------------------------- التوصيل

final driversProvider = FutureProvider.autoDispose<List<Driver>>((ref) async {
  refreshOn(ref, 'drivers');
  refreshOn(ref, 'delivery');
  final res = await apiOf(ref).get('/api/drivers');
  return (res['drivers'] as List).map((j) => Driver(j as Map<String, dynamic>)).toList();
});

typedef DeliveryQuery = ({String status, String q});

final deliveryOrdersProvider = FutureProvider.autoDispose.family<List<DeliveryOrder>, DeliveryQuery>((ref, query) async {
  refreshOn(ref, 'delivery');
  final res = await apiOf(ref).get('/api/delivery', query: {'status': query.status, if (query.q.isNotEmpty) 'q': query.q});
  return (res['orders'] as List).map((j) => DeliveryOrder(j as Map<String, dynamic>)).toList();
});

final deliveryDetailProvider = FutureProvider.autoDispose.family<({DeliveryOrder order, List<DeliveryItem> items}), String>((ref, id) async {
  refreshOn(ref, 'delivery');
  final res = await apiOf(ref).get('/api/delivery/$id');
  return (
    order: DeliveryOrder(res['order'] as Map<String, dynamic>),
    items: (res['items'] as List).map((j) => DeliveryItem(j as Map<String, dynamic>)).toList(),
  );
});
