import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/pos_models.dart';
import '../../core/pos_types.dart';
import '../../core/providers.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../core/shop.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../pos/pos_screen.dart';
import '../pos/providers.dart';

/// تقرير الصلاحية والهالك (آخر 30 يوم) للمالك ومسؤول الشفت.
final expiryReportProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  refreshOn(ref, 'products');
  return apiOf(ref).get('/api/reports/expiry');
});

/// الصلاحية: البضاعة اللي صلاحيتها قربت تخلص (عشان تتعرض قدام أو يتعمل عليها عرض)،
/// واللي خلصت (تتشال من الرف وتتسجل هالك)، وقيمة الهالك.
class ExpiryScreen extends ConsumerStatefulWidget {
  const ExpiryScreen({super.key});

  @override
  ConsumerState<ExpiryScreen> createState() => _ExpiryScreenState();
}

class _ExpiryScreenState extends ConsumerState<ExpiryScreen> {
  int? _days;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider).value!.user!;
    final alertDays = ref.watch(shopProvider).value?.expiryAlertDays ?? 30;
    final days = _days ?? alertDays;
    final batches = ref.watch(expiringProvider(days));
    final report = user.isManager ? ref.watch(expiryReportProvider).value : null;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('الصلاحية والهالك')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('اللي صلاحيته بتخلص خلال:'),
          for (final d in {7, alertDays, 30, 60, 90}.toList()..sort())
            ChoiceChip(label: Text('$d يوم'), selected: days == d, onSelected: (_) => setState(() => _days = d)),
        ]),
        if (report != null) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _Stat('خلصت ولسه في المخزون', money(report['expiredValueCents'] as int), scheme.error),
            _Stat('قربت تخلص ($alertDays يوم)', money(report['expiringValueCents'] as int), brandOrange),
            _Stat('هالك آخر 30 يوم', money(report['wasteValueCents'] as int), scheme.onSurfaceVariant),
          ]),
        ],
        const SizedBox(height: 12),
        ...batches.when(
          skipLoadingOnRefresh: true,
          loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
          error: (e, _) => [ErrorBanner(errorText(e))],
          data: (list) {
            if (list.isEmpty) {
              return [
                Padding(
                  padding: const EdgeInsets.all(40),
                  child: Center(child: Text('مفيش بضاعة صلاحيتها بتخلص خلال $days يوم 👍', style: TextStyle(color: scheme.onSurfaceVariant))),
                ),
              ];
            }
            final expired = list.where((b) => b.expired).toList();
            final soon = list.where((b) => !b.expired).toList();
            return [
              if (expired.isNotEmpty) ...[
                SectionTitle('صلاحيتها خلصت (${expired.length}) — شيلها من الرف'),
                for (final b in expired) _BatchTile(batch: b, canWaste: user.isManager),
              ],
              if (soon.isNotEmpty) ...[
                SectionTitle('قربت تخلص (${soon.length}) — اعرضها قدام أو اعمل عليها عرض'),
                for (final b in soon) _BatchTile(batch: b, canWaste: user.isManager),
              ],
            ];
          },
        ),
        if (report != null && (report['waste'] as List).isNotEmpty) ...[
          const SizedBox(height: 12),
          const SectionTitle('الهالك آخر 30 يوم'),
          for (final w in (report['waste'] as List).cast<Map<String, dynamic>>())
            ListTile(
              dense: true,
              title: Text(w['name'] as String),
              subtitle: Text('${w['reason'] == 'expired' ? 'صلاحيته خلصت' : 'تالف'} • ${qtyLabel(w['qtyMilli'] as int, SaleUnit.parse(w['unit'] as String?))}'),
              trailing: Text(money(w['valueCents'] as int? ?? 0), style: TextStyle(color: scheme.error).semiBold),
            ),
        ],
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.color);
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 200,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleLarge?.bold.copyWith(color: color)),
        ]),
      );
}

class _BatchTile extends ConsumerWidget {
  const _BatchTile({required this.batch, required this.canWaste});
  final Batch batch;
  final bool canWaste;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = batch;
    final scheme = Theme.of(context).colorScheme;
    final color = b.expired ? scheme.error : (b.daysLeft ?? 99) <= 3 ? brandOrange : scheme.onSurfaceVariant;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Text(b.daysLeft == null ? '؟' : '${b.daysLeft}', style: TextStyle(color: color, fontSize: 13).bold),
        ),
        title: Text(b.productName ?? '', style: const TextStyle().semiBold),
        subtitle: Text([
          if (b.expiryDate != null) 'الصلاحية ${formatDate(b.expiryDate!)}',
          b.expiryText,
          'الكمية ${qtyLabel(b.qtyMilli, b.unit)}',
          if (b.valueCents != null) 'بتكلفة ${money(b.valueCents!)}',
        ].join(' • ')),
        trailing: canWaste
            ? TextButton.icon(
                onPressed: () => wasteBatch(context, ref, b),
                icon: const Icon(Icons.delete_sweep_rounded),
                label: const Text('هالك'),
              )
            : null,
      ),
    );
  }
}

/// تسجيل دفعة (أو جزء منها) هالك: صلاحيتها خلصت أو باظت.
Future<void> wasteBatch(BuildContext context, WidgetRef ref, Batch b) async {
  var reason = b.expired ? 'expired' : 'damaged';
  int? qty = b.qtyMilli;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('هالك: ${b.productName ?? ''}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, children: [
            ChoiceChip(label: const Text('صلاحيته خلصت'), selected: reason == 'expired', onSelected: (_) => setState(() => reason = 'expired')),
            ChoiceChip(label: const Text('تالف'), selected: reason == 'damaged', onSelected: (_) => setState(() => reason = 'damaged')),
          ]),
          const SizedBox(height: 12),
          Text('الكمية: ${qtyLabel(qty ?? 0, b.unit)} من ${qtyLabel(b.qtyMilli, b.unit)}'),
          TextButton(
            onPressed: () async {
              final q = await askQty(context, 'كمية الهالك', qty, unit: b.unit);
              if (q != null && q > 0 && q <= b.qtyMilli) setState(() => qty = q);
            },
            child: const Text('تغيير الكمية'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('رجوع')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('شيلها من المخزون')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final res = await ref.read(sessionProvider).value!.api!.post('/api/batches/${b.id}/waste', {'reason': reason, 'qtyMilli': qty});
    if (context.mounted) showMessage(context, 'اتسجلت هالك بقيمة ${money(res['wasteValueCents'] as int)}');
  } catch (e) {
    if (context.mounted) showMessage(context, errorText(e), error: true);
  }
}
