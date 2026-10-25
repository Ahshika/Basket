import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../core/diagnostics.dart';
import '../../core/format.dart';
import '../../core/pos_types.dart';
import '../../core/session.dart';
import '../../core/shop.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/form_fields.dart';

const paperLabels = {
  '80mm': 'طابعة حرارية 80 مم',
  '58mm': 'طابعة حرارية 58 مم (صغيرة)',
  'a5': 'ورق A5',
  'a4': 'ورق A4',
};

/// بيانات المحل والوصل، والبيع، والميزان، والصلاحية، والتوصيل (لصاحب المحل بس).
class ShopSettingsScreen extends ConsumerWidget {
  const ShopSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shop = ref.watch(shopProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('بيانات المحل والإعدادات')),
      body: shop.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(20), child: ErrorBanner(errorText(e)))),
        data: (s) => _ShopForm(shop: s),
      ),
    );
  }
}

class _ShopForm extends ConsumerStatefulWidget {
  const _ShopForm({required this.shop});
  final ShopProfile shop;

  @override
  ConsumerState<_ShopForm> createState() => _ShopFormState();
}

class _ShopFormState extends ConsumerState<_ShopForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.shop.name);
  late final _phone = TextEditingController(text: widget.shop.phone);
  late final _address = TextEditingController(text: widget.shop.address);
  late final _branch = TextEditingController(text: widget.shop.branchName);
  late final _terms = TextEditingController(text: widget.shop.receiptTerms);
  late String _paper = widget.shop.receiptPaper;
  late bool _cashierDiscount = widget.shop.cashierCanDiscount;
  late bool _negativeStock = widget.shop.allowNegativeStock;
  late bool _scaleEnabled = widget.shop.scaleFormat.enabled;
  late final _prefixes = TextEditingController(text: widget.shop.scaleFormat.prefixes.join('، '));
  late int _pluLength = widget.shop.scaleFormat.pluLength;
  late int _valueLength = widget.shop.scaleFormat.valueLength;
  late String _scaleMode = widget.shop.scaleFormat.mode;
  late final _expiryDays = TextEditingController(text: '${widget.shop.expiryAlertDays}');
  late final _deliveryFee = TextEditingController(text: moneyInput(widget.shop.deliveryFeeCents));
  bool _busy = false;
  bool _logoBusy = false;
  String? _error;

  ScaleFormat get _scale => ScaleFormat(
        enabled: _scaleEnabled,
        prefixes: latinDigits(_prefixes.text).split(RegExp(r'[,،\s]+')).where((p) => p.isNotEmpty).toList(),
        pluLength: _pluLength,
        valueLength: _valueLength,
        mode: _scaleMode,
      );

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _branch, _terms, _prefixes, _expiryDays, _deliveryFee]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final scaleError = _scale.validate();
    if (scaleError != null) return setState(() => _error = 'الميزان: $scaleError');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider).value!.api!.patch('/api/shop', {
        'name': _name.text,
        'phone': _phone.text,
        'address': _address.text,
        'branchName': _branch.text,
        'receiptTerms': _terms.text,
        'receiptPaper': _paper,
        'cashierCanDiscount': _cashierDiscount,
        'allowNegativeStock': _negativeStock,
        'scaleFormat': _scale.toJson(),
        'expiryAlertDays': int.tryParse(latinDigits(_expiryDays.text)) ?? 30,
        'deliveryFeeCents': parseMoney(_deliveryFee.text) ?? 0,
      });
      ref.invalidate(shopProvider);
      if (mounted) showMessage(context, 'تم حفظ بيانات المحل');
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickLogo() async {
    // بنفتح على فولدر الصور اللي على الجهاز، مش آخر فولدر (لو كان موبايل متوصل أو فولدر شبكة، ويندوز ممكن يعلّق فيه)
    final pictures = '${Platform.environment['USERPROFILE'] ?? ''}\\Pictures';
    FreezeWatchdog.action('نافذة اختيار اللوجو من ويندوز');
    DiagLog.app?.write('INFO', 'فتح نافذة اختيار اللوجو');
    final file = await openFile(
      initialDirectory: Platform.isWindows && Directory(pictures).existsSync() ? pictures : null,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'صور', extensions: ['png', 'jpg', 'jpeg', 'webp'], mimeTypes: ['image/*']),
      ],
    );
    DiagLog.app?.write('INFO', file == null ? 'نافذة اختيار اللوجو اتقفلت من غير اختيار' : 'اتختار لوجو');
    if (file == null) return;
    setState(() => _logoBusy = true);
    try {
      final raw = await file.readAsBytes();
      // بنصغّر اللوجو (في Isolate لوحده) عشان الوصل يطبع بسرعة والصورة ماتتقلش على الشبكة
      final png = await Isolate.run(() {
        final decoded = img.decodeImage(raw);
        if (decoded == null) return null;
        final resized = decoded.width > 400 || decoded.height > 400
            ? img.copyResize(decoded, width: decoded.width >= decoded.height ? 400 : null, height: decoded.height > decoded.width ? 400 : null)
            : decoded;
        return img.encodePng(resized);
      });
      if (png == null) throw Exception('الملف ده مش صورة');
      await ref.read(sessionProvider).value!.api!.put('/api/shop/logo', {'png': base64.encode(png)});
      ref.invalidate(shopProvider);
      if (mounted) showMessage(context, 'اتحفظ اللوجو');
    } catch (e) {
      if (mounted) showMessage(context, e is Exception ? e.toString().replaceFirst('Exception: ', '') : errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _removeLogo() async {
    await ref.read(sessionProvider).value!.api!.delete('/api/shop/logo');
    ref.invalidate(shopProvider);
  }

  @override
  Widget build(BuildContext context) {
    final logo = widget.shop.logo;
    final scheme = Theme.of(context).colorScheme;
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionCard(
                    title: 'اللوجو',
                    icon: Icons.image_rounded,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: logo == null
                                ? Icon(Icons.add_photo_alternate_rounded, size: 36, color: scheme.outline)
                                : Image.memory(logo, fit: BoxFit.contain),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('بيظهر فوق في الوصل. الأحسن صورة بخلفية بيضا أو شفافة.'),
                                const SizedBox(height: 8),
                                Wrap(spacing: 8, children: [
                                  FilledButton.tonalIcon(
                                    onPressed: _logoBusy ? null : _pickLogo,
                                    icon: _logoBusy
                                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                        : const Icon(Icons.upload_rounded),
                                    label: Text(logo == null ? 'اختار صورة' : 'تغيير'),
                                  ),
                                  if (logo != null) TextButton(onPressed: _removeLogo, child: const Text('مسح')),
                                ]),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'بيانات المحل',
                    icon: Icons.storefront_rounded,
                    children: [
                      TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: 'اسم المحل'),
                        validator: (v) => (v ?? '').trim().isEmpty ? 'لازم تكتب اسم المحل' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _branch,
                        decoration: const InputDecoration(labelText: 'اسم الفرع'),
                        validator: (v) => (v ?? '').trim().isEmpty ? 'لازم تكتب اسم الفرع' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'تليفون المحل')),
                      const SizedBox(height: 12),
                      TextFormField(controller: _address, decoration: const InputDecoration(labelText: 'العنوان')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'الوصل',
                    icon: Icons.receipt_long_rounded,
                    children: [
                      Text('مقاس الورق', style: const TextStyle().semiBold),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final e in paperLabels.entries)
                          ChoiceChip(label: Text(e.value), selected: _paper == e.key, onSelected: (_) => setState(() => _paper = e.key)),
                      ]),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _terms,
                        minLines: 3,
                        maxLines: 8,
                        decoration: const InputDecoration(labelText: 'الشروط اللي بتتطبع تحت الوصل', alignLabelWithHint: true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'البيع',
                    icon: Icons.point_of_sale_rounded,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('الكاشير يقدر يعمل خصم ويغيّر السعر'),
                        subtitle: const Text('لو اتقفلت، الخصم لصاحب المحل بس'),
                        value: _cashierDiscount,
                        onChanged: (v) => setState(() => _cashierDiscount = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('السماح بالبيع لو الكمية في البرنامج خلصت'),
                        subtitle: const Text('مفيد لو فيه بضاعة لسه ما اتسجلتش'),
                        value: _negativeStock,
                        onChanged: (v) => setState(() => _negativeStock = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _scaleSection(),
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'الصلاحية والتوصيل',
                    icon: Icons.event_busy_rounded,
                    children: [
                      TextFormField(
                        controller: _expiryDays,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'نبّهني قبل ما الصلاحية تخلص بكام يوم',
                          suffixText: 'يوم',
                          prefixIcon: Icon(Icons.notifications_active_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      MoneyField(controller: _deliveryFee, label: 'رسوم التوصيل الافتراضية'),
                    ],
                  ),
                  if (_error != null) ...[const SizedBox(height: 12), ErrorBanner(_error!)],
                  const SizedBox(height: 16),
                  BusyButton(label: 'حفظ', icon: Icons.check_rounded, busy: _busy, onPressed: _save),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

extension on _ShopFormState {
  /// شكل باركود الميزان: نفس اللي متظبط على الميزان نفسه، ومعاه مثال بيتحدّث وإنت بتغيّر.
  Widget _scaleSection() {
    final f = _scale;
    final error = f.validate();
    final prefix = f.prefixes.isEmpty ? '21' : f.prefixes.first;
    final sample = error == null ? buildScaleBarcode(f, prefix, 123, f.mode == 'weight' ? 1250 : 4750) : null;
    final mono = Theme.of(context).textTheme.titleMedium?.copyWith(fontFamily: 'monospace', letterSpacing: 2);
    // ignore: invalid_use_of_protected_member
    void update(VoidCallback fn) => setState(fn);

    return SectionCard(
      title: 'الميزان (باركود الوزن)',
      icon: Icons.scale_rounded,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('قراية الباركود اللي الميزان بيطبعه'),
          subtitle: const Text('الصنف بيتضاف في الكاشير بالوزن (أو السعر) اللي جوه الباركود'),
          value: _scaleEnabled,
          onChanged: (v) => update(() => _scaleEnabled = v),
        ),
        if (_scaleEnabled) ...[
          TextFormField(
            controller: _prefixes,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(labelText: 'أول رقمين في باركود الميزان', helperText: 'لو أكتر من بادئة افصل بينهم بفاصلة، زي: 21، 22'),
            onChanged: (_) => update(() {}),
          ),
          const SizedBox(height: 12),
          const Text('الميزان بيطبع إيه جوه الباركود؟'),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'weight', label: Text('الوزن بالجرام')),
              ButtonSegment(value: 'price', label: Text('السعر بالقرش')),
            ],
            selected: {_scaleMode},
            onSelectionChanged: (s) => update(() => _scaleMode = s.first),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _pluLength,
                decoration: const InputDecoration(labelText: 'عدد أرقام رقم الصنف'),
                items: [for (final n in [3, 4, 5, 6]) DropdownMenuItem(value: n, child: Text('$n'))],
                onChanged: (v) => update(() => _pluLength = v!),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _valueLength,
                decoration: InputDecoration(labelText: _scaleMode == 'weight' ? 'عدد أرقام الوزن' : 'عدد أرقام السعر'),
                items: [for (final n in [4, 5, 6]) DropdownMenuItem(value: n, child: Text('$n'))],
                onChanged: (v) => update(() => _valueLength = v!),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          if (error != null)
            ErrorBanner(error)
          else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: brandGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('مثال:'),
                Directionality(textDirection: TextDirection.ltr, child: Text(sample!, style: mono)),
                Text(
                  f.mode == 'weight'
                      ? 'يعني: الصنف رقم 123 على الميزان، ووزنه 1.250 كيلو'
                      : 'يعني: الصنف رقم 123 على الميزان، وسعره 47.50 ج.م',
                ),
              ]),
            ),
        ],
      ],
    );
  }
}

