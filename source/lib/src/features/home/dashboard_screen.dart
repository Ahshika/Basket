import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_config.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../delivery/delivery_screen.dart';
import '../inventory/expiry_screen.dart';
import '../inventory/products_screen.dart';
import '../pos/cash_screen.dart';
import '../settings/license_screen.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  void _open(BuildContext context, Widget screen) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value!;
    final user = session.user!;
    final info = session.info!;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final isServer = ref.read(appConfigProvider).mode == AppMode.server;
    final stats = ref.watch(dashboardProvider);
    final s = stats.value;
    final greeting = DateTime.now().hour < 12 ? 'صباح الخير' : 'مساء الخير';
    final driver = user.role == Role.driver;
    final openDeliveries = s == null ? null : s.deliveryNew + s.deliveryPreparing + s.deliveryOut;

    final cards = <Widget>[
      if (driver) ...[
        _StatCard(icon: Icons.delivery_dining_rounded, label: 'طلبات معايا', value: '${s?.myOpenDeliveries ?? '–'}', color: const Color(0xFF7C3AED), onTap: () => _open(context, const DeliveryScreen())),
        _StatCard(icon: Icons.account_balance_wallet_rounded, label: 'معايا فلوس لسه ماورّدتهاش', value: s == null ? '–' : money(s.myCashCents), color: brandOrange, onTap: () => _open(context, const DeliveryScreen())),
      ] else ...[
        _StatCard(icon: Icons.point_of_sale_rounded, label: 'مبيعات النهارده (${s?.salesTodayCount ?? 0} فاتورة)', value: s == null ? '–' : money(s.salesTodayCents), color: brandGreen),
        if (s?.profitTodayCents != null)
          _StatCard(icon: Icons.trending_up_rounded, label: 'ربح النهارده', value: money(s!.profitTodayCents!), color: const Color(0xFF16A34A))
        else
          _StatCard(icon: Icons.person_rounded, label: 'مبيعاتي النهارده', value: s == null ? '–' : money(s.mySalesTodayCents), color: const Color(0xFF16A34A)),
        _StatCard(
          icon: Icons.delivery_dining_rounded,
          label: s == null ? 'طلبات توصيل مفتوحة' : 'توصيل: ${s.deliveryNew} جديد • ${s.deliveryOut} في الطريق',
          value: '${openDeliveries ?? '–'}',
          color: const Color(0xFF7C3AED),
          onTap: () => _open(context, const DeliveryScreen()),
        ),
        _StatCard(
          icon: Icons.event_busy_rounded,
          label: 'صلاحيته قربت تخلص (${s?.expiryAlertDays ?? 30} يوم)${(s?.expiredCount ?? 0) > 0 ? ' • ${s!.expiredCount} خلص' : ''}',
          value: '${s == null ? '–' : s.expiringCount + s.expiredCount}',
          color: (s?.expiredCount ?? 0) > 0 ? scheme.error : brandOrange,
          onTap: () => _open(context, const ExpiryScreen()),
        ),
        _StatCard(icon: Icons.inventory_rounded, label: 'أصناف قرّبت تخلص من المخزون', value: '${s?.lowStockCount ?? '–'}', color: brandOrange, onTap: () => _open(context, const ProductsScreen())),
        if (s?.openDrawers != null)
          _StatCard(icon: Icons.point_of_sale_outlined, label: 'أدراج مفتوحة دلوقتي', value: '${s!.openDrawers}', color: brandGreen, onTap: () => _open(context, const DrawersScreen())),
        if ((s?.driversCashCents ?? 0) > 0)
          _StatCard(icon: Icons.two_wheeler_rounded, label: 'فلوس مع الطيارين', value: money(s!.driversCashCents!), color: const Color(0xFF7C3AED), onTap: () => _open(context, const DrawersScreen())),
      ],
    ];

    return Scaffold(
      appBar: AppBar(title: Text('$greeting، ${user.name.split(' ').first} 👋')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(dashboardProvider.future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            const LicenseBanner(),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: scheme.primaryContainer,
                      child: Icon(Icons.storefront_rounded, color: scheme.onPrimaryContainer, size: 30),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(info.shopName ?? '', style: text.titleLarge?.bold),
                          Text(info.branchName ?? '', style: TextStyle(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    _ConnectionChip(isServer: isServer),
                  ],
                ),
              ),
            ),
            if (stats.hasError) ...[const SizedBox(height: 12), ErrorBanner(errorText(stats.error!))],
            const SizedBox(height: 16),
            LayoutBuilder(builder: (context, c) {
              final columns = c.maxWidth >= 900 ? 3 : c.maxWidth >= 560 ? 2 : 1;
              return GridView.count(
                crossAxisCount: columns,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: c.maxWidth / columns / 88,
                children: cards,
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.isServer});
  final bool isServer;

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF16A34A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.circle, size: 10, color: green),
          const SizedBox(width: 6),
          Text(isServer ? 'السيرفر شغال' : 'متصل بالسيرفر', style: const TextStyle(color: green).semiBold),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.icon, required this.label, required this.value, required this.color, this.onTap});

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: text.headlineSmall?.bold, maxLines: 1),
                    Text(label, style: text.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

