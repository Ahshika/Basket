import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

final _auditProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final api = ref.watch(sessionProvider).value!.api!;
  final res = await api.get('/api/audit', query: {'limit': '200'});
  return (res['entries'] as List).cast<Map<String, dynamic>>();
});

const _actionLabels = {
  'shop.setup': 'تسجيل المحل',
  'auth.login': 'تسجيل دخول',
  'user.create': 'إضافة موظف',
  'user.update': 'تعديل موظف',
  'user.password': 'تغيير كلمة السر',
  'customer.update': 'تعديل عميل',
  'customer.payment': 'تحصيل من عميل',
  'sale.create': 'فاتورة بيع',
  'sale.return': 'مرتجع',
  'product.create': 'صنف جديد',
  'product.price': 'تغيير سعر',
  'product.adjust': 'جرد / حركة مخزون',
  'product.import': 'استيراد أصناف',
  'stock.waste': 'هالك',
  'purchase.create': 'فاتورة شرا',
  'supplier.payment': 'دفعة لمورد',
  'cash.open': 'فتح وردية',
  'cash.close': 'تقفيل وردية',
  'cash.expense': 'مصروف',
  'cash.deposit': 'إيداع في الدرج',
  'cash.withdraw': 'سحب من الدرج',
  'delivery.create': 'طلب توصيل',
  'delivery.update': 'تعديل طلب توصيل',
  'delivery.status': 'مرحلة طلب توصيل',
  'driver.create': 'طيار جديد',
  'driver.settle': 'توريد طيار',
};

const _actionIcons = {
  'shop.setup': Icons.storefront_rounded,
  'auth.login': Icons.login_rounded,
  'user.create': Icons.person_add_rounded,
  'user.update': Icons.manage_accounts_rounded,
  'user.password': Icons.password_rounded,
  'customer.update': Icons.person_rounded,
  'customer.payment': Icons.payments_rounded,
  'sale.create': Icons.point_of_sale_rounded,
  'sale.return': Icons.undo_rounded,
  'product.create': Icons.add_box_rounded,
  'product.price': Icons.sell_rounded,
  'product.adjust': Icons.inventory_rounded,
  'product.import': Icons.upload_file_rounded,
  'stock.waste': Icons.delete_sweep_rounded,
  'purchase.create': Icons.local_shipping_rounded,
  'supplier.payment': Icons.payments_rounded,
  'cash.open': Icons.lock_open_rounded,
  'cash.close': Icons.lock_clock_rounded,
  'cash.expense': Icons.money_off_rounded,
  'cash.deposit': Icons.savings_rounded,
  'cash.withdraw': Icons.outbox_rounded,
  'delivery.create': Icons.delivery_dining_rounded,
  'delivery.update': Icons.edit_rounded,
  'delivery.status': Icons.swap_vert_rounded,
  'driver.create': Icons.two_wheeler_rounded,
  'driver.settle': Icons.handshake_rounded,
};


class AuditScreen extends ConsumerWidget {
  const AuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(_auditProvider);
    final format = DateFormat('d MMM yyyy - h:mm a', 'ar');
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('سجل النشاط')),
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(20), child: ErrorBanner(errorText(e)))),
        data: (list) => list.isEmpty
            ? const Center(child: Text('مفيش نشاط لسه'))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final e = list[i];
                  final action = e['action'] as String;
                  final at = DateTime.tryParse(e['createdAt'] as String? ?? '')?.toLocal();
                  return ListTile(
                    leading: Icon(_actionIcons[action] ?? Icons.bolt_rounded),
                    title: Text.rich(TextSpan(children: [
                      TextSpan(text: e['userName'] as String? ?? 'النظام', style: const TextStyle().bold),
                      TextSpan(text: ' • ${_actionLabels[action] ?? action}'),
                    ])),
                    subtitle: e['details'] != null ? Text(e['details'] as String) : null,
                    trailing: at != null ? Text(format.format(at), style: text.bodySmall) : null,
                  );
                },
              ),
      ),
    );
  }
}
