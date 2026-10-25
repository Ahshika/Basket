import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'models.dart';
import 'pos_models.dart';
import 'realtime.dart';
import 'session.dart';

ApiClient apiOf(Ref ref) => ref.watch(sessionProvider).value!.api!;

final dashboardProvider = FutureProvider.autoDispose<DashboardStats>((ref) async {
  refreshOn(ref, 'sales');
  refreshOn(ref, 'products');
  refreshOn(ref, 'delivery');
  refreshOn(ref, 'cash');
  return DashboardStats(await apiOf(ref).get('/api/dashboard'));
});

final staffProvider = FutureProvider.autoDispose<List<StaffMember>>((ref) async {
  refreshOn(ref, 'users');
  final res = await apiOf(ref).get('/api/staff');
  return (res['staff'] as List).map((j) => StaffMember(j as Map<String, dynamic>)).toList();
});

final customersProvider = FutureProvider.autoDispose.family<List<Customer>, String>((ref, q) async {
  refreshOn(ref, 'customers');
  final res = await apiOf(ref).get('/api/customers', query: {if (q.isNotEmpty) 'q': q, 'limit': '200'});
  return (res['customers'] as List).map((j) => Customer.fromJson(j as Map<String, dynamic>)).toList();
});

final customerDetailProvider =
    FutureProvider.autoDispose.family<({Customer customer, List<SaleSummary> sales, List<DeliveryOrder> deliveries}), String>((ref, id) async {
  refreshOn(ref, 'customers');
  refreshOn(ref, 'sales');
  refreshOn(ref, 'delivery');
  final res = await apiOf(ref).get('/api/customers/$id');
  return (
    customer: Customer.fromJson(res['customer'] as Map<String, dynamic>),
    sales: (res['sales'] as List).map((j) => SaleSummary(j as Map<String, dynamic>)).toList(),
    deliveries: (res['deliveries'] as List).map((j) => DeliveryOrder(j as Map<String, dynamic>)).toList(),
  );
});

final licenseProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  refreshOn(ref, 'license');
  ref.keepAlive();
  return apiOf(ref).get('/api/license');
});
