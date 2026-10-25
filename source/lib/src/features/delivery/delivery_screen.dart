import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/pos_models.dart';
import '../../core/pos_types.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/shop.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';
import '../pos/cart.dart';
import '../pos/pos_screen.dart';
import '../pos/providers.dart';
import '../receipts/print_service.dart';

/// طلبات التوصيل: الطلبات المفتوحة بمراحلها، والطيارين وتوريد فلوسهم، وكل الطلبات القديمة.
/// الطيار نفسه بيشوف الطلبات اللي معاه بس، ويقول اتسلمت أو العميل رفض.
class DeliveryScreen extends ConsumerWidget {
  const DeliveryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider).value!.user!;
    if (user.role == Role.driver) return const _DriverView();
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('التوصيل'),
          bottom: const TabBar(tabs: [Tab(text: 'الطلبات المفتوحة'), Tab(text: 'الطيارين'), Tab(text: 'كل الطلبات')]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => showDialog<bool>(context: context, builder: (_) => const NewDeliveryDialog(cart: CartState())),
          icon: const Icon(Icons.add_rounded),
          label: const Text('طلب جديد'),
        ),
        body: TabBarView(children: [
          const _OrdersList(status: 'open'),
          _DriversTab(canManage: user.isManager),
          const _OrdersList(status: 'all', searchable: true),
        ]),
      ),
    );
  }
}

Color statusColor(BuildContext context, DeliveryStatus s) => switch (s) {
      DeliveryStatus.newOrder => brandOrange,
      DeliveryStatus.preparing => const Color(0xFF2563EB),
      DeliveryStatus.out => const Color(0xFF7C3AED),
      DeliveryStatus.delivered => const Color(0xFF16A34A),
      DeliveryStatus.cancelled => Theme.of(context).colorScheme.outline,
    };

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.status);
  final DeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    final c = statusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(status.label, style: TextStyle(color: c, fontSize: 12).semiBold),
    );
  }
}

/// واتساب برقم مصري: 01001234567 ← 201001234567.
Future<void> openWhatsApp(String phone, {String? text}) async {
  var digits = normalizePhone(phone);
  if (digits.startsWith('0')) digits = '2$digits';
  await launchUrl(Uri.https('wa.me', '/$digits', {'text': ?text}), mode: LaunchMode.externalApplication);
}

Future<void> callPhone(String phone) => launchUrl(Uri(scheme: 'tel', path: normalizePhone(phone)));

class _OrdersList extends ConsumerStatefulWidget {
  const _OrdersList({required this.status, this.searchable = false});
  final String status;
  final bool searchable;

  @override
  ConsumerState<_OrdersList> createState() => _OrdersListState();
}

class _OrdersListState extends ConsumerState<_OrdersList> {
  String _q = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orders = ref.watch(deliveryOrdersProvider((status: widget.status, q: _q)));
    return Column(children: [
      if (widget.searchable)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            decoration: const InputDecoration(hintText: 'رقم الطلب أو اسم العميل أو تليفونه أو العنوان', prefixIcon: Icon(Icons.search_rounded)),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _q = v.trim()));
            },
          ),
        ),
      Expanded(
        child: orders.when(
          skipLoadingOnRefresh: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(20), child: ErrorBanner(errorText(e)))),
          data: (list) => list.isEmpty
              ? Center(
                  child: Text(widget.status == 'open' ? 'مفيش طلبات توصيل مفتوحة دلوقتي' : 'مفيش طلبات',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  itemCount: list.length,
                  itemBuilder: (context, i) => OrderCard(order: list[i]),
                ),
        ),
      ),
    ]);
  }
}

/// كارت الطلب بأزرار المرحلة الجاية.
class OrderCard extends ConsumerWidget {
  const OrderCard({super.key, required this.order, this.driverMode = false});
  final DeliveryOrder order;
  final bool driverMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final o = order;
    final scheme = Theme.of(context).colorScheme;
    final next = o.status.next;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showDialog<void>(context: context, builder: (_) => _OrderDetailDialog(orderId: o.id, driverMode: driverMode)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('#${o.number}', style: Theme.of(context).textTheme.titleMedium?.bold),
              const SizedBox(width: 10),
              Expanded(child: Text(o.customerName, style: const TextStyle().semiBold, maxLines: 1, overflow: TextOverflow.ellipsis)),
              _StatusChip(o.status),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.location_on_outlined, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Expanded(child: Text(o.address, maxLines: 2, overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 2),
            Wrap(spacing: 12, runSpacing: 2, children: [
              Text(o.customerPhone, textDirection: TextDirection.ltr, style: TextStyle(color: scheme.onSurfaceVariant)),
              Text(money(o.totalCents), style: TextStyle(color: scheme.primary).bold),
              Text('${o.itemsCount} صنف', style: TextStyle(color: scheme.onSurfaceVariant)),
              if (o.driverName != null) Text('الطيار: ${o.driverName}', style: TextStyle(color: scheme.onSurfaceVariant)),
              Text(timeAgo(o.createdAt), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              if (o.status == DeliveryStatus.delivered && !o.settled) Text('لسه ماتوردش', style: const TextStyle(color: brandOrange, fontSize: 12).semiBold),
              if (o.cancelReason != null) Text('السبب: ${o.cancelReason}', style: TextStyle(color: scheme.error, fontSize: 12)),
            ]),
            if (o.status.isOpen)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (next != null && (!driverMode || next == DeliveryStatus.delivered))
                    FilledButton.tonalIcon(
                      onPressed: () => advanceOrder(context, ref, o),
                      icon: Icon(switch (next) {
                        DeliveryStatus.preparing => Icons.shopping_basket_rounded,
                        DeliveryStatus.out => Icons.delivery_dining_rounded,
                        _ => Icons.check_circle_rounded,
                      }),
                      label: Text(switch (next) {
                        DeliveryStatus.preparing => 'ابدأ التجهيز',
                        DeliveryStatus.out => 'خرج مع طيار',
                        _ => 'اتسلم (${money(o.totalCents)})',
                      }),
                    ),
                  if (!driverMode || o.status == DeliveryStatus.out)
                    TextButton(onPressed: () => cancelOrder(context, ref, o), child: Text(driverMode ? 'العميل رفض' : 'إلغاء')),
                  IconButton(tooltip: 'واتساب للعميل', icon: const Icon(Icons.chat_rounded), onPressed: () => openWhatsApp(o.customerWhatsapp ?? o.customerPhone)),
                  IconButton(tooltip: 'اتصال', icon: const Icon(Icons.call_rounded), onPressed: () => callPhone(o.customerPhone)),
                  if (!driverMode) IconButton(tooltip: 'طباعة ورقة الطلب', icon: const Icon(Icons.print_rounded), onPressed: () => printDeliverySlip(context, ref, o.id)),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

Future<void> _postStatus(BuildContext context, WidgetRef ref, DeliveryOrder o, Map<String, Object?> body) async {
  try {
    await ref.read(sessionProvider).value!.api!.post('/api/delivery/${o.id}/status', body);
  } catch (e) {
    if (context.mounted) showMessage(context, errorText(e), error: true);
  }
}

/// المرحلة الجاية: التجهيز، أو الخروج مع طيار (بيختاره)، أو التسليم.
Future<void> advanceOrder(BuildContext context, WidgetRef ref, DeliveryOrder o) async {
  final next = o.status.next;
  if (next == null) return;
  if (next == DeliveryStatus.out) {
    final driver = await showDialog<Driver>(context: context, builder: (_) => _PickDriverDialog(current: o.driverId));
    if (driver == null || !context.mounted) return;
    await _postStatus(context, ref, o, {'status': 'out', 'driverId': driver.id});
    return;
  }
  if (next == DeliveryStatus.delivered) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('طلب #${o.number} اتسلم؟'),
        content: Text('الطيار حصّل ${money(o.totalCents)} من ${o.customerName}.\nالمخزون هيتخصم، والفلوس هتفضل مع الطيار لحد ما يورّدها.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('رجوع')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('أيوه اتسلم')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  await _postStatus(context, ref, o, {'status': next.code});
}

Future<void> cancelOrder(BuildContext context, WidgetRef ref, DeliveryOrder o) async {
  final c = TextEditingController();
  final reason = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('إلغاء طلب #${o.number}'),
      content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'السبب', hintText: 'مثلاً: العميل مارد، العنوان غلط')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('رجوع')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('إلغاء الطلب')),
      ],
    ),
  );
  c.dispose();
  if (reason == null || reason.isEmpty || !context.mounted) return;
  await _postStatus(context, ref, o, {'status': 'cancelled', 'reason': reason});
}

class _PickDriverDialog extends ConsumerWidget {
  const _PickDriverDialog({this.current});
  final String? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(driversProvider);
    return AlertDialog(
      title: const Text('مين الطيار؟'),
      content: SizedBox(
        width: 360,
        child: drivers.when(
          loading: () => const SizedBox(height: 80, child: Center(child: CircularProgressIndicator())),
          error: (e, _) => ErrorBanner(errorText(e)),
          data: (list) => list.isEmpty
              ? const Text('لسه مفيش طيارين. ضيفهم من تبويب "الطيارين"، أو اعمل لهم حساب بصلاحية "طيار توصيل".')
              : ListView(shrinkWrap: true, children: [
                  for (final d in list)
                    ListTile(
                      leading: const Icon(Icons.delivery_dining_rounded),
                      title: Text(d.name),
                      subtitle: Text(d.openOrders > 0 ? 'معاه ${d.openOrders} طلب دلوقتي' : 'فاضي'),
                      selected: d.id == current,
                      onTap: () => Navigator.pop(context, d),
                    ),
                ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء'))],
    );
  }
}

class _OrderDetailDialog extends ConsumerWidget {
  const _OrderDetailDialog({required this.orderId, this.driverMode = false});
  final String orderId;
  final bool driverMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(deliveryDetailProvider(orderId));
    return AlertDialog(
      title: detail.whenOrNull(data: (d) => Text('طلب #${d.order.number}')) ?? const Text('الطلب'),
      content: SizedBox(
        width: 460,
        child: detail.when(
          loading: () => const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
          error: (e, _) => ErrorBanner(errorText(e)),
          data: (d) {
            final o = d.order;
            return SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Align(alignment: AlignmentDirectional.centerStart, child: _StatusChip(o.status)),
                const SizedBox(height: 8),
                Text(o.customerName, style: Theme.of(context).textTheme.titleMedium?.bold),
                Text(o.customerPhone, textDirection: TextDirection.ltr, textAlign: TextAlign.end),
                Text(o.address),
                Text('${deliveryChannels[o.channel] ?? ''} • ${formatDateTime(o.createdAt)}${o.createdBy != null ? ' • ${o.createdBy}' : ''}',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
                if (o.note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('ملاحظة: ${o.note}')),
                const Divider(height: 20),
                for (final i in d.items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(child: Text(i.name)),
                      Text(i.qtyText, style: const TextStyle().semiBold),
                      const SizedBox(width: 12),
                      SizedBox(width: 80, child: Text(money(i.totalCents), textAlign: TextAlign.end)),
                    ]),
                  ),
                const Divider(height: 20),
                if (o.deliveryFeeCents > 0) Row(children: [const Expanded(child: Text('رسوم التوصيل')), Text(money(o.deliveryFeeCents))]),
                Row(children: [
                  const Expanded(child: Text('المطلوب تحصيله')),
                  Text(money(o.totalCents), style: Theme.of(context).textTheme.titleMedium?.bold),
                ]),
                if (o.driverName != null) Text('الطيار: ${o.driverName}'),
                if (o.deliveredAt != null) Text('اتسلم ${formatDateTime(o.deliveredAt!)}${o.settled ? ' • اتورّد' : ' • لسه ماتوردش'}'),
                if (o.cancelReason != null) Text('اتلغى: ${o.cancelReason}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ]),
            );
          },
        ),
      ),
      actions: [
        if (!driverMode && detail.value?.order.saleId != null)
          TextButton.icon(
            onPressed: () => printSale(context, ref, detail.value!.order.saleId!),
            icon: const Icon(Icons.receipt_long_rounded),
            label: const Text('الفاتورة'),
          ),
        if (!driverMode && (detail.value?.order.status.editable ?? false))
          TextButton.icon(
            onPressed: () async {
              final d = detail.value!;
              Navigator.pop(context);
              await showDialog<bool>(context: context, builder: (_) => NewDeliveryDialog(cart: const CartState(), editing: d));
            },
            icon: const Icon(Icons.edit_rounded),
            label: const Text('تعديل'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('قفل')),
      ],
    );
  }
}

// ---------------------------------------------------------------- الطيارين

class _DriversTab extends ConsumerWidget {
  const _DriversTab({required this.canManage});
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(driversProvider);
    return drivers.when(
      skipLoadingOnRefresh: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: ErrorBanner(errorText(e))),
      data: (list) => ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
        if (canManage)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: () => showDialog<void>(context: context, builder: (_) => const _DriverDialog()),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('طيار جديد (من غير حساب)'),
            ),
          ),
        const SizedBox(height: 8),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('لسه مفيش طيارين. الطيار ممكن يكون اسم بس، أو موظف بصلاحية "طيار توصيل" بيستخدم البرنامج من موبايله.', textAlign: TextAlign.center),
          ),
        for (final d in list)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Icon(d.userId != null ? Icons.phone_android_rounded : Icons.delivery_dining_rounded)),
              title: Text(d.name, style: const TextStyle().semiBold),
              subtitle: Text([
                if (d.phone != null) d.phone!,
                if (d.openOrders > 0) 'معاه ${d.openOrders} طلب في الطريق',
                d.outstandingCents > 0 ? 'معاه ${money(d.outstandingCents)} لسه ماورّدهاش' : 'مفيش فلوس معاه',
              ].join(' • ')),
              trailing: Wrap(spacing: 4, children: [
                if (d.outstandingCents > 0)
                  FilledButton(
                    onPressed: () => showDialog<void>(context: context, builder: (_) => SettleDriverDialog(driver: d)),
                    child: const Text('توريد'),
                  ),
                if (canManage)
                  IconButton(
                    tooltip: 'تعديل',
                    icon: const Icon(Icons.edit_rounded),
                    onPressed: () => showDialog<void>(context: context, builder: (_) => _DriverDialog(driver: d)),
                  ),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _DriverDialog extends ConsumerStatefulWidget {
  const _DriverDialog({this.driver});
  final Driver? driver;

  @override
  ConsumerState<_DriverDialog> createState() => _DriverDialogState();
}

class _DriverDialogState extends ConsumerState<_DriverDialog> {
  late final _name = TextEditingController(text: widget.driver?.name);
  late final _phone = TextEditingController(text: widget.driver?.phone);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save({bool? active}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(sessionProvider).value!.api!;
      final body = {'name': _name.text, 'phone': _phone.text.trim().isEmpty ? null : _phone.text, 'active': ?active};
      if (widget.driver == null) {
        await api.post('/api/drivers', body);
      } else {
        await api.patch('/api/drivers/${widget.driver!.id}', body);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.driver == null ? 'طيار جديد' : 'تعديل ${widget.driver!.name}'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'الاسم')),
          const SizedBox(height: 10),
          TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'التليفون (اختياري)')),
          if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
        ]),
      ),
      actions: [
        if (widget.driver != null && widget.driver!.userId == null)
          TextButton(onPressed: _busy ? null : () => _save(active: false), child: const Text('إيقاف الطيار')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        SizedBox(width: 110, child: BusyButton(label: 'حفظ', busy: _busy, onPressed: _save)),
      ],
    );
  }
}

/// توريد الطيار: بيشوف الطلبات اللي سلّمها والمفروض يورّد كام، ويكتب اللي استلمه فعلاً.
class SettleDriverDialog extends ConsumerStatefulWidget {
  const SettleDriverDialog({super.key, required this.driver});
  final Driver driver;

  @override
  ConsumerState<SettleDriverDialog> createState() => _SettleDriverDialogState();
}

class _SettleDriverDialogState extends ConsumerState<SettleDriverDialog> {
  final _counted = TextEditingController();
  Map<String, dynamic>? _pending;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _counted.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(sessionProvider).value!.api!.get('/api/drivers/${widget.driver.id}/pending');
      if (!mounted) return;
      setState(() => _pending = res);
      _counted.text = moneyInput(res['expectedCents'] as int);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _settle() async {
    final counted = parseMoney(_counted.text);
    if (counted == null) return setState(() => _error = 'اكتب المبلغ اللي استلمته');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ref.read(sessionProvider).value!.api!.post('/api/drivers/${widget.driver.id}/settle', {'countedCents': counted});
      if (!mounted) return;
      Navigator.pop(context);
      final diff = res['differenceCents'] as int;
      showMessage(context, 'اتورّد ${money(counted)} في درجك${diff != 0 ? ' • ${diff < 0 ? 'عجز' : 'زيادة'} ${money(diff.abs())}' : ''}');
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = (_pending?['orders'] as List? ?? const []).map((j) => DeliveryOrder(j as Map<String, dynamic>)).toList();
    final expected = _pending?['expectedCents'] as int? ?? 0;
    final counted = parseMoney(_counted.text) ?? 0;
    return AlertDialog(
      title: Text('توريد ${widget.driver.name}'),
      content: SizedBox(
        width: 420,
        child: _pending == null && _error == null
            ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final o in orders)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('#${o.number} • ${o.customerName}'),
                      subtitle: o.deliveredAt == null ? null : Text(formatDateTime(o.deliveredAt!)),
                      trailing: Text(money(o.collectedCents ?? 0)),
                    ),
                  const Divider(),
                  Text('المفروض يورّد: ${money(expected)} (${orders.length} طلب)', style: Theme.of(context).textTheme.titleMedium?.bold),
                  const SizedBox(height: 12),
                  MoneyField(controller: _counted, label: 'استلمت منه كام؟', onChanged: (_) => setState(() {})),
                  if (counted != expected)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        counted < expected ? 'عجز ${money(expected - counted)} هيتسجل على التوريد' : 'زيادة ${money(counted - expected)}',
                        style: TextStyle(color: counted < expected ? Theme.of(context).colorScheme.error : const Color(0xFF16A34A)).semiBold,
                      ),
                    ),
                  if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
                ]),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('رجوع')),
        SizedBox(width: 140, child: BusyButton(label: 'تأكيد التوريد', busy: _busy, onPressed: orders.isEmpty ? null : _settle)),
      ],
    );
  }
}

// ---------------------------------------------------------------- طلب جديد

/// طلب توصيل جديد (أو تعديل طلب لسه ماخرجش): العميل بالتليفون، والعنوان، والأصناف.
/// لو جاي من الكاشير، الأصناف اللي في الفاتورة بتتنقل هنا على طول.
class NewDeliveryDialog extends ConsumerStatefulWidget {
  const NewDeliveryDialog({super.key, required this.cart, this.editing});
  final CartState cart;
  final ({DeliveryOrder order, List<DeliveryItem> items})? editing;

  @override
  ConsumerState<NewDeliveryDialog> createState() => _NewDeliveryDialogState();
}

class _NewDeliveryDialogState extends ConsumerState<NewDeliveryDialog> {
  late final _phone = TextEditingController(text: widget.editing?.order.customerPhone ?? widget.cart.customer?.phone);
  late final _name = TextEditingController(text: widget.editing?.order.customerName ?? widget.cart.customer?.name);
  late final _address = TextEditingController(text: widget.editing?.order.address ?? widget.cart.customer?.address);
  late final _note = TextEditingController(text: widget.editing?.order.note);
  final _fee = TextEditingController();
  final _search = TextEditingController();
  late String _channel = widget.editing?.order.channel ?? 'phone';
  late String? _customerId = widget.editing?.order.customerId ?? widget.cart.customer?.id;
  // نسخة من سطور الكاشير، عشان التعديل هنا مايغيّرش الفاتورة اللي هناك لو الطلب اتلغى
  late final List<CartLine> _lines = [
    for (final l in widget.cart.lines)
      CartLine(l.product, qtyMilli: l.qtyMilli, unitPriceCents: l.unitPriceCents, scaleBarcode: l.scaleBarcode, fixedTotalCents: l.fixedTotalCents),
    for (final i in widget.editing?.items ?? const <DeliveryItem>[])
      CartLine(
        Product({'id': i.productId, 'name': i.name, 'unit': i.unit.name, 'priceCents': i.unitPriceCents}),
        qtyMilli: i.qtyMilli,
        unitPriceCents: i.unitPriceCents,
      ),
  ];
  List<Product> _results = [];
  Timer? _debounce;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final fee = widget.editing?.order.deliveryFeeCents;
    if (fee != null) {
      _fee.text = moneyInput(fee);
    } else {
      ref.read(shopProvider.future).then((s) {
        if (mounted && _fee.text.isEmpty) _fee.text = moneyInput(s.deliveryFeeCents);
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_phone, _name, _address, _note, _fee, _search]) {
      c.dispose();
    }
    super.dispose();
  }

  /// العميل القديم بيتعرف من رقمه، واسمه وآخر عنوان بيتكتبوا لوحدهم.
  Future<void> _lookupPhone(String v) async {
    if (normalizePhone(v).length < 10) return;
    final res = await ref.read(sessionProvider).value!.api!.get('/api/customers/lookup', query: {'phone': v});
    final c = res['customer'] == null ? null : Customer.fromJson(res['customer'] as Map<String, dynamic>);
    if (!mounted) return;
    setState(() {
      _customerId = c?.id;
      if (c != null) {
        _name.text = c.name;
        if (_address.text.trim().isEmpty && c.address != null) _address.text = c.address!;
      }
    });
  }

  Future<void> _searchProducts(String v) async {
    final api = ref.read(sessionProvider).value!.api!;
    if (v.trim().isEmpty) return setState(() => _results = []);
    final res = await api.get('/api/products', query: {'q': v.trim(), 'limit': '8'});
    if (mounted) setState(() => _results = (res['products'] as List).map((j) => Product(j as Map<String, dynamic>)).toList());
  }

  Future<void> _submitSearch(String v) async {
    final code = latinDigits(v.trim());
    if (code.isEmpty) return;
    final res = await ref.read(sessionProvider).value!.api!.get('/api/products/lookup', query: {'barcode': code});
    if (res['product'] == null) return _searchProducts(code);
    final p = Product(res['product'] as Map<String, dynamic>);
    final scale = res['scale'] as Map?;
    if (scale != null) {
      setState(() => _lines.add(CartLine(p, qtyMilli: scale['qtyMilli'] as int, scaleBarcode: scale['barcode'] as String, fixedTotalCents: scale['totalCents'] as int)));
    } else {
      await _add(p);
    }
    _search.clear();
  }

  Future<void> _add(Product p) async {
    var qty = milli;
    if (p.byWeight) {
      final w = await askQty(context, 'وزن "${p.name}" بالكيلو', null, unit: SaleUnit.kg);
      if (w == null || w <= 0) return;
      qty = w;
    }
    setState(() {
      final i = _lines.indexWhere((l) => l.product.id == p.id && !l.fromScale);
      if (i >= 0) {
        _lines[i].qtyMilli += qty;
      } else {
        _lines.add(CartLine(p, qtyMilli: qty));
      }
      _results = [];
      _search.clear();
    });
  }

  Future<void> _save() async {
    final fee = parseMoney(_fee.text);
    if (_lines.isEmpty) return setState(() => _error = 'ضيف الأصناف الأول');
    if (fee == null) return setState(() => _error = 'رسوم التوصيل مش صحيحة');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ref.read(sessionProvider).value!.api!;
      final items = CartState(lines: _lines).itemsJson;
      final note = _note.text.trim().isEmpty ? null : _note.text.trim();
      if (widget.editing != null) {
        await api.patch('/api/delivery/${widget.editing!.order.id}', {
          'items': items, 'address': _address.text, 'channel': _channel, 'deliveryFeeCents': fee, 'note': note,
        });
      } else {
        await api.post('/api/delivery', {
          if (_customerId != null) 'customerId': _customerId else ...{'customerName': _name.text, 'phone': _phone.text},
          'address': _address.text,
          'channel': _channel,
          'items': items,
          'deliveryFeeCents': fee,
          'note': note,
        });
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtotal = _lines.fold<int>(0, (s, l) => s + l.totalCents);
    final fee = parseMoney(_fee.text) ?? 0;
    final editing = widget.editing != null;
    return AlertDialog(
      title: Text(editing ? 'تعديل طلب #${widget.editing!.order.number}' : 'طلب توصيل جديد'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 8, children: [
              for (final e in deliveryChannels.entries)
                ChoiceChip(label: Text(e.value), selected: _channel == e.key, onSelected: (_) => setState(() => _channel = e.key)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _phone,
                  enabled: !editing,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: 'تليفون العميل', suffixIcon: _customerId != null ? const Icon(Icons.verified_rounded, color: Color(0xFF16A34A)) : null),
                  onChanged: (v) {
                    _customerId = null;
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 400), () => _lookupPhone(v));
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _name, enabled: !editing && _customerId == null, decoration: const InputDecoration(labelText: 'اسم العميل'))),
            ]),
            const SizedBox(height: 10),
            TextField(controller: _address, minLines: 2, maxLines: 3, decoration: const InputDecoration(labelText: 'العنوان بالتفصيل', hintText: 'الشارع، رقم العمارة، الدور، الشقة، علامة مميزة')),
            const SizedBox(height: 14),
            Text('الأصناف', style: Theme.of(context).textTheme.titleSmall?.bold),
            const SizedBox(height: 6),
            TextField(
              controller: _search,
              decoration: const InputDecoration(hintText: 'امسح الباركود أو اكتب اسم الصنف', prefixIcon: Icon(Icons.qr_code_scanner_rounded), isDense: true),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () => _searchProducts(v));
              },
              onSubmitted: _submitSearch,
            ),
            for (final p in _results)
              ListTile(dense: true, title: Text(p.name), subtitle: Text(p.priceText), trailing: const Icon(Icons.add_rounded), onTap: () => _add(p)),
            for (final l in _lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(child: Text(l.product.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  TextButton(
                    onPressed: l.fromScale
                        ? null
                        : () async {
                            final q = await askQty(context, 'كمية "${l.product.name}"', l.qtyMilli, unit: l.product.unit);
                            if (q != null && q > 0) setState(() => l.qtyMilli = q);
                          },
                    child: Text(qtyLabel(l.qtyMilli, l.product.unit)),
                  ),
                  SizedBox(width: 80, child: Text(money(l.totalCents), textAlign: TextAlign.end)),
                  IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => _lines.remove(l))),
                ]),
              ),
            if (_lines.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text('لسه مفيش أصناف', style: TextStyle(color: scheme.onSurfaceVariant))),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: MoneyField(controller: _fee, label: 'رسوم التوصيل', onChanged: (_) => setState(() {}))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)'))),
            ]),
            const SizedBox(height: 12),
            Text('المطلوب تحصيله: ${money(subtotal + fee)}', style: Theme.of(context).textTheme.titleLarge?.bold.copyWith(color: scheme.primary)),
            if (_error != null) ...[const SizedBox(height: 10), ErrorBanner(_error!)],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        SizedBox(width: 140, child: BusyButton(label: editing ? 'حفظ' : 'تسجيل الطلب', busy: _busy, onPressed: _save)),
      ],
    );
  }
}

// ---------------------------------------------------------------- شاشة الطيار

/// الطيار من موبايله: الطلبات اللي معاه، والفلوس اللي حصّلها ولسه ماورّدهاش.
class _DriverView extends ConsumerWidget {
  const _DriverView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(deliveryOrdersProvider((status: 'out', q: '')));
    final stats = ref.watch(dashboardProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('طلباتي')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(deliveryOrdersProvider((status: 'out', q: '')).future),
        child: ListView(padding: const EdgeInsets.all(12), children: [
          if (stats != null)
            Card(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                leading: const Icon(Icons.account_balance_wallet_rounded),
                title: Text('معاك ${money(stats.myCashCents)}'),
                subtitle: const Text('فلوس طلبات سلّمتها ولسه ماورّدتهاش للكاشير'),
              ),
            ),
          ...orders.when(
            loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
            error: (e, _) => [ErrorBanner(errorText(e))],
            data: (list) => list.isEmpty
                ? [const Padding(padding: EdgeInsets.all(40), child: Center(child: Text('مفيش طلبات معاك دلوقتي')))]
                : [for (final o in list) OrderCard(order: o, driverMode: true)],
          ),
        ]),
      ),
    );
  }
}
