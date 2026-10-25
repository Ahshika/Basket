import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/pos_models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/pos_types.dart';
import '../../widgets/barcode_scan.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';
import '../inventory/products_screen.dart';
import '../pos/providers.dart';

/// المشتريات والموردين.
class PurchasesScreen extends ConsumerWidget {
  const PurchasesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المشتريات'),
          bottom: const TabBar(tabs: [Tab(text: 'فواتير الشرا'), Tab(text: 'الموردين')]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const NewPurchaseScreen())),
          icon: const Icon(Icons.add_rounded),
          label: const Text('فاتورة شرا'),
        ),
        body: const TabBarView(children: [_PurchasesList(), _SuppliersList()]),
      ),
    );
  }
}

class _PurchasesList extends ConsumerWidget {
  const _PurchasesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(purchasesProvider);
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: ErrorBanner(errorText(e))),
      data: (list) => list.isEmpty
          ? const EmptyState(icon: Icons.local_shipping_outlined, message: 'لسه مفيش فواتير شرا.\nلما البضاعة توصل من المورد سجّلها هنا، والكميات هتزيد في المخزون لوحدها.')
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                final p = list[i];
                return Card(
                  child: ListTile(
                    title: Text('#${p.number} • ${p.supplierName ?? 'من غير مورد'}'),
                    subtitle: Text('${formatDateTime(p.createdAt)} • ${p.itemsCount} قطعة${p.userName != null ? ' • ${p.userName}' : ''}'),
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(money(p.totalCents), style: const TextStyle().bold),
                      if (p.dueCents > 0) Text('باقي ${money(p.dueCents)}', style: const TextStyle(fontSize: 12, color: brandOrange)),
                    ]),
                  ),
                );
              },
            ),
    );
  }
}

class _SuppliersList extends ConsumerWidget {
  const _SuppliersList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(suppliersProvider);
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: ErrorBanner(errorText(e))),
      data: (list) => ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 96), children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const SupplierDialog()),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('مورد جديد'),
          ),
        ),
        const SizedBox(height: 8),
        for (final s in list)
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.local_shipping_rounded)),
              title: Text(s.name),
              subtitle: s.phone != null ? Text(s.phone!) : null,
              trailing: s.balanceCents > 0
                  ? Text('ليه ${money(s.balanceCents)}', style: const TextStyle(color: brandOrange).bold)
                  : const Text('خالص'),
              onTap: () => showDialog<void>(context: context, builder: (_) => _SupplierPayDialog(supplier: s)),
            ),
          ),
      ]),
    );
  }
}

class SupplierDialog extends ConsumerStatefulWidget {
  const SupplierDialog({super.key});

  @override
  ConsumerState<SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends ConsumerState<SupplierDialog> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      final res = await ref.read(sessionProvider).value!.api!.post('/api/suppliers', {'name': _name.text, 'phone': _phone.text});
      ref.invalidate(suppliersProvider);
      if (mounted) Navigator.pop(context, Supplier(res['supplier'] as Map<String, dynamic>));
    } catch (e) {
      setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('مورد جديد'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'اسم المورد')),
          const SizedBox(height: 12),
          TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'التليفون')),
          if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}

class _SupplierPayDialog extends ConsumerStatefulWidget {
  const _SupplierPayDialog({required this.supplier});
  final Supplier supplier;

  @override
  ConsumerState<_SupplierPayDialog> createState() => _SupplierPayDialogState();
}

class _SupplierPayDialogState extends ConsumerState<_SupplierPayDialog> {
  late final _amount = TextEditingController(text: widget.supplier.balanceCents > 0 ? moneyInput(widget.supplier.balanceCents) : '');
  PaymentMethod _method = PaymentMethod.cash;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider).value!.api!.post('/api/suppliers/${widget.supplier.id}/payments', {
        'amountCents': parseMoney(_amount.text),
        'method': _method.name,
      });
      ref.invalidate(suppliersProvider);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.supplier;
    return AlertDialog(
      title: Text(s.name),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.balanceCents > 0 ? 'ليه عندك: ${money(s.balanceCents)}' : 'الحساب خالص'),
          const SizedBox(height: 12),
          MoneyField(controller: _amount, label: 'دفعة للمورد', autofocus: true),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final m in PaymentMethod.values.where((m) => m != PaymentMethod.other))
              ChoiceChip(label: Text(m.label), selected: _method == m, onSelected: (_) => setState(() => _method = m)),
          ]),
          if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('قفل')),
        SizedBox(width: 120, child: BusyButton(label: 'دفع', busy: _busy, onPressed: _save)),
      ],
    );
  }
}

class _PurchaseLine {
  _PurchaseLine(this.product) : cost = product.costCents;
  final Product product;

  /// بالألف (القطعة = 1000، الكيلو = 1000 جرام).
  int qtyMilli = milli;

  /// للقطعة أو للكيلو.
  int cost;
  DateTime? expiresOn;

  int get totalCents => lineTotal(cost, qtyMilli);
}

/// فاتورة شرا جديدة: المورد، والأصناف بالكمية وسعر الشرا، وتاريخ الصلاحية للأصناف اللي بتتتبع صلاحيتها.
class NewPurchaseScreen extends ConsumerStatefulWidget {
  const NewPurchaseScreen({super.key});

  @override
  ConsumerState<NewPurchaseScreen> createState() => _NewPurchaseScreenState();
}

class _NewPurchaseScreenState extends ConsumerState<NewPurchaseScreen> {
  Supplier? _supplier;
  final _lines = <_PurchaseLine>[];
  final _search = TextEditingController();
  final _paid = TextEditingController();
  bool _paidEdited = false;
  PaymentMethod _method = PaymentMethod.cash;
  List<Product> _results = [];
  Timer? _debounce;
  bool _busy = false;
  String? _error;

  int get _total => _lines.fold(0, (s, l) => s + l.totalCents);

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _paid.dispose();
    super.dispose();
  }

  Future<void> _find(String v) async {
    if (v.trim().isEmpty) return setState(() => _results = []);
    final res = await ref.read(sessionProvider).value!.api!.get('/api/products', query: {'q': v.trim(), 'limit': '8'});
    if (mounted) setState(() => _results = (res['products'] as List).map((j) => Product(j as Map<String, dynamic>)).toList());
  }

  void _add(Product p) {
    setState(() {
      if (!_lines.any((l) => l.product.id == p.id)) _lines.add(_PurchaseLine(p));
      _results = [];
      _search.clear();
      if (!_paidEdited) _paid.text = moneyInput(_total);
    });
  }

  Future<void> _save() async {
    if (_lines.isEmpty) return;
    final missing = _lines.where((l) => l.product.trackExpiry && l.expiresOn == null).firstOrNull;
    if (missing != null) return setState(() => _error = 'اختار تاريخ صلاحية "${missing.product.name}"');
    final paid = _paidEdited ? (parseMoney(_paid.text) ?? 0) : _total;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider).value!.api!.post('/api/purchases', {
        'supplierId': _supplier?.id,
        'items': [
          for (final l in _lines)
            {
              'productId': l.product.id,
              'qtyMilli': l.qtyMilli,
              'unitCostCents': l.cost,
              if (l.expiresOn != null) 'expiresOn': dayKey(l.expiresOn!),
            },
        ],
        'paidCents': paid,
        'method': _method.name,
      });
      ref.invalidate(purchasesProvider);
      ref.invalidate(productsProvider);
      if (!mounted) return;
      Navigator.pop(context);
      showMessage(context, 'اتسجلت فاتورة الشرا، والبضاعة دخلت المخزون');
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = ref.watch(suppliersProvider).value ?? const <Supplier>[];
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('فاتورة شرا جديدة')),
      body: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
        SectionCard(title: 'المورد', icon: Icons.local_shipping_rounded, children: [
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String?>(
                initialValue: _supplier?.id,
                decoration: const InputDecoration(labelText: 'اختار المورد'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('من غير مورد (شرا كاش)')),
                  for (final s in suppliers) DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _supplier = suppliers.where((s) => s.id == v).firstOrNull),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'مورد جديد',
              icon: const Icon(Icons.add_rounded),
              onPressed: () async {
                final s = await showDialog<Supplier>(context: context, builder: (_) => const SupplierDialog());
                if (s != null) setState(() => _supplier = s);
              },
            ),
          ]),
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'الأصناف', icon: Icons.inventory_2_rounded, children: [
          TextField(
            controller: _search,
            decoration: InputDecoration(
              hintText: 'امسح الباركود أو اكتب اسم الصنف',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: cameraScanSupported
                  ? IconButton(
                      icon: const Icon(Icons.photo_camera_rounded),
                      onPressed: () async {
                        final c = await scanBarcode(context);
                        if (c != null) {
                          _search.text = c;
                          await _find(c);
                          if (_results.length == 1) _add(_results.first);
                        }
                      },
                    )
                  : null,
            ),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () => _find(v));
            },
            onSubmitted: (v) async {
              await _find(v);
              if (_results.length == 1) _add(_results.first);
            },
          ),
          for (final p in _results)
            ListTile(dense: true, title: Text(p.name), subtitle: Text(p.barcode ?? ''), trailing: const Icon(Icons.add_rounded), onTap: () => _add(p)),
          if (_results.isEmpty && _search.text.trim().isNotEmpty)
            const Padding(padding: EdgeInsets.all(8), child: Text('الصنف مش موجود؟ ضيفه الأول من شاشة المخزون.')),
          const SizedBox(height: 8),
          for (final l in _lines) _LineEditor(line: l, onChanged: () => setState(() {
            if (!_paidEdited) _paid.text = moneyInput(_total);
          }), onRemove: () => setState(() => _lines.remove(l))),
        ]),
        const SizedBox(height: 12),
        SectionCard(title: 'الحساب', icon: Icons.payments_rounded, children: [
          Row(children: [Expanded(child: Text('الإجمالي', style: text.titleMedium)), Text(money(_total), style: text.titleLarge?.bold)]),
          const SizedBox(height: 12),
          MoneyField(controller: _paid, label: 'المدفوع للمورد دلوقتي', onChanged: (_) => setState(() => _paidEdited = true)),
          if (_paidEdited && (parseMoney(_paid.text) ?? 0) < _total)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('هيفضل للمورد: ${money(_total - (parseMoney(_paid.text) ?? 0))}', style: const TextStyle(color: brandOrange).semiBold),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final m in PaymentMethod.values.where((m) => m != PaymentMethod.other))
              ChoiceChip(label: Text(m.label), selected: _method == m, onSelected: (_) => setState(() => _method = m)),
          ]),
        ]),
        if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
        const SizedBox(height: 16),
        BusyButton(label: 'حفظ فاتورة الشرا', icon: Icons.check_rounded, busy: _busy, onPressed: _lines.isEmpty ? null : _save),
      ]),
    );
  }
}

class _LineEditor extends StatefulWidget {
  const _LineEditor({required this.line, required this.onChanged, required this.onRemove});
  final _PurchaseLine line;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_LineEditor> createState() => _LineEditorState();
}

class _LineEditorState extends State<_LineEditor> {
  late final _cost = TextEditingController(text: moneyInput(widget.line.cost));
  late final _qty = TextEditingController(text: formatQty(widget.line.qtyMilli, widget.line.product.unit));

  @override
  void dispose() {
    _cost.dispose();
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(l.product.name, style: const TextStyle().semiBold)),
            IconButton(icon: const Icon(Icons.close_rounded), onPressed: widget.onRemove),
          ]),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 120,
              child: TextField(
                controller: _qty,
                keyboardType: TextInputType.numberWithOptions(decimal: l.product.byWeight),
                decoration: InputDecoration(labelText: 'الكمية', suffixText: l.product.unit.label),
                onChanged: (v) {
                  l.qtyMilli = parseQty(v) ?? 0;
                  widget.onChanged();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MoneyField(
                controller: _cost,
                label: l.product.byWeight ? 'سعر الشرا للكيلو' : 'سعر الشرا للقطعة',
                onChanged: (v) {
                  l.cost = parseMoney(v) ?? 0;
                  widget.onChanged();
                },
              ),
            ),
          ]),
          if (l.product.trackExpiry) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ExpiryPickerTile(
                value: l.expiresOn,
                onChanged: (d) => setState(() {
                  l.expiresOn = d;
                  widget.onChanged();
                }),
              ),
            ),
          ],
          Align(alignment: AlignmentDirectional.centerEnd, child: Text('الإجمالي: ${money(l.totalCents)}')),

        ]),
      ),
    );
  }
}
