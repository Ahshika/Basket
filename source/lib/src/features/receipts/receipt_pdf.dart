import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format.dart';
import '../../core/pos_models.dart';
import '../../core/pos_types.dart';
import '../../core/shop.dart';

pw.ThemeData? _theme;

Future<pw.ThemeData> _loadTheme() async {
  if (_theme != null) return _theme!;
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
  return _theme = pw.ThemeData.withFont(base: regular, bold: bold, fontFallback: [regular]);
}

PdfPageFormat paperFormat(String paper) => switch (paper) {
      '58mm' => const PdfPageFormat(58 * PdfPageFormat.mm, double.infinity, marginAll: 2 * PdfPageFormat.mm),
      'a5' => PdfPageFormat.a5.copyWith(marginLeft: 12 * PdfPageFormat.mm, marginRight: 12 * PdfPageFormat.mm, marginTop: 10 * PdfPageFormat.mm, marginBottom: 10 * PdfPageFormat.mm),
      'a4' => PdfPageFormat.a4.copyWith(marginLeft: 20 * PdfPageFormat.mm, marginRight: 20 * PdfPageFormat.mm, marginTop: 15 * PdfPageFormat.mm, marginBottom: 15 * PdfPageFormat.mm),
      _ => const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 3 * PdfPageFormat.mm),
    };

bool _isRoll(String paper) => paper == '80mm' || paper == '58mm';

/// أدوات الرسم المشتركة بين الفاتورة وورقة التوصيل على نفس مقاس الورق.
class _Slip {
  _Slip(String size) : scale = size == '58mm' ? 0.85 : _isRoll(size) ? 1.0 : 1.15;
  final double scale;

  pw.TextStyle st(double v, {bool bold = false}) =>
      pw.TextStyle(fontSize: v * scale, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal);

  pw.Widget divider() => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        child: pw.Divider(thickness: 0.6, borderStyle: pw.BorderStyle.dashed, color: PdfColors.grey700),
      );

  pw.Widget total(String label, String value, {bool bold = false}) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [pw.Text(label, style: st(bold ? 11 : 9, bold: bold)), pw.Text(value, style: st(bold ? 12 : 9, bold: bold))],
      );

  List<pw.Widget> header(ShopProfile shop) => [
        if (shop.logo != null) pw.Center(child: pw.Image(pw.MemoryImage(shop.logo!), height: 40 * scale, fit: pw.BoxFit.contain)),
        pw.Center(child: pw.Text(shop.name, style: st(14, bold: true), textAlign: pw.TextAlign.center)),
        if (shop.phone != null) pw.Center(child: pw.Text(shop.phone!, style: st(9), textDirection: pw.TextDirection.ltr)),
        if (shop.address != null) pw.Center(child: pw.Text(shop.address!, style: st(8), textAlign: pw.TextAlign.center)),
        divider(),
      ];

  /// سطر صنف: الاسم، وتحته "2 × 35" أو "1.25 كيلو × 320"، والإجمالي.
  List<pw.Widget> item(String name, SaleUnit unit, int qtyMilli, int unitPriceCents, int totalCents) => [
        pw.Text(name, style: st(9, bold: true)),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(
            unit == SaleUnit.kg ? '${formatQty(qtyMilli, unit)} كيلو × ${money(unitPriceCents)}' : '${formatQty(qtyMilli, unit)} × ${money(unitPriceCents)}',
            style: st(8),
          ),
          pw.Text(money(totalCents), style: st(9)),
        ]),
      ];

  pw.Widget footer() => pw.Center(child: pw.Text('Basket', style: st(6).copyWith(color: PdfColors.grey600)));
}

Future<Uint8List> _page(pw.ThemeData theme, String title, String author, String size, pw.Widget content) {
  final doc = pw.Document(theme: theme, title: title, author: author);
  doc.addPage(pw.Page(
    pageFormat: paperFormat(size),
    textDirection: pw.TextDirection.rtl,
    build: (_) => _isRoll(size) ? content : pw.Center(child: pw.SizedBox(width: 110 * PdfPageFormat.mm, child: content)),
  ));
  return doc.save();
}

/// فاتورة بيع (كاشير أو توصيل).
Future<Uint8List> buildSalePdf(SaleDetail detail, ShopProfile shop, {String? paper}) async {
  final theme = await _loadTheme();
  final s = detail.sale;
  final size = paper ?? shop.receiptPaper;
  final k = _Slip(size);

  final content = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      ...k.header(shop),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text(s.deliveryNumber != null ? 'فاتورة توصيل' : 'فاتورة بيع', style: k.st(11, bold: true)),
        pw.Text('#${s.number}', style: k.st(14, bold: true), textDirection: pw.TextDirection.ltr),
      ]),
      pw.Text(formatDateTime(s.createdAt), style: k.st(8)),
      if (s.customerName != null) pw.Text('العميل: ${s.customerName}', style: k.st(9)),
      if (s.deliveryNumber != null) pw.Text('طلب توصيل #${s.deliveryNumber}', style: k.st(8)),
      if (s.userName != null) pw.Text('${s.deliveryNumber != null ? 'سلّمه' : 'الكاشير'}: ${s.userName}', style: k.st(8)),
      k.divider(),
      for (final i in detail.items) ...[
        ...k.item(i.name, i.unit, i.qtyMilli, i.unitPriceCents, i.totalCents),
        if (i.returnedMilli > 0) pw.Text('مرتجع: ${qtyLabel(i.returnedMilli, i.unit)}', style: k.st(7)),
        pw.SizedBox(height: 3),
      ],
      k.divider(),
      pw.Text('عدد الأصناف: ${detail.items.length}', style: k.st(8)),
      if (s.discountCents > 0) ...[k.total('الإجمالي', money(s.subtotalCents)), k.total('خصم', '- ${money(s.discountCents)}')],
      k.total('المطلوب', money(s.totalCents), bold: true),
      for (final p in detail.payments.where((p) => p.type == 'sale')) k.total('مدفوع (${p.method.label})', money(p.amountCents)),
      if (s.returnedCents > 0) k.total('مرتجع', money(s.returnedCents)),
      if (s.dueCents > 0) k.total('الباقي (آجل)', money(s.dueCents), bold: true),
      pw.SizedBox(height: 8),
      pw.Center(child: pw.Text('شكراً لزيارتكم', style: k.st(9, bold: true))),
      if (shop.receiptTerms.trim().isNotEmpty) pw.Center(child: pw.Text(shop.receiptTerms.trim(), style: k.st(7), textAlign: pw.TextAlign.center)),
      pw.SizedBox(height: 4),
      k.footer(),
    ],
  );
  return _page(theme, 'فاتورة ${s.number}', shop.name, size, content);
}

/// ورقة طلب التوصيل: بتتطبع وتتحط مع الشنطة، فيها العنوان والأصناف والمطلوب تحصيله.
Future<Uint8List> buildDeliverySlipPdf(DeliveryOrder o, List<DeliveryItem> items, ShopProfile shop, {String? paper}) async {
  final theme = await _loadTheme();
  final size = paper ?? shop.receiptPaper;
  final k = _Slip(size);

  final content = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      ...k.header(shop),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('طلب توصيل', style: k.st(11, bold: true)),
        pw.Text('#${o.number}', style: k.st(16, bold: true), textDirection: pw.TextDirection.ltr),
      ]),
      pw.Text(formatDateTime(o.createdAt), style: k.st(8)),
      k.divider(),
      pw.Text(o.customerName, style: k.st(11, bold: true)),
      pw.Text(o.customerPhone, style: k.st(10, bold: true), textDirection: pw.TextDirection.ltr),
      pw.Text(o.address, style: k.st(10)),
      if (o.note != null) pw.Text('ملاحظة: ${o.note}', style: k.st(8)),
      if (o.driverName != null) pw.Text('الطيار: ${o.driverName}', style: k.st(8)),
      k.divider(),
      for (final i in items) ...[...k.item(i.name, i.unit, i.qtyMilli, i.unitPriceCents, i.totalCents), pw.SizedBox(height: 3)],
      k.divider(),
      k.total('الأصناف', money(o.subtotalCents)),
      if (o.deliveryFeeCents > 0) k.total('رسوم التوصيل', money(o.deliveryFeeCents)),
      k.total('المطلوب تحصيله', money(o.totalCents), bold: true),
      pw.SizedBox(height: 6),
      k.footer(),
    ],
  );
  return _page(theme, 'توصيل ${o.number}', shop.name, size, content);
}

/// ستيكرات باركود للأصناف: ستيكر 50×30 مم لكل صنف (طابعة ليبل) أو ورقة A4 عليها كذا ستيكر.
Future<Uint8List> buildBarcodeLabelsPdf(List<({Product product, int copies})> items, ShopProfile shop, {bool a4 = false}) async {
  final theme = await _loadTheme();
  final doc = pw.Document(theme: theme, title: 'باركود');
  pw.Widget label(Product p) {
    final code = p.barcode!;
    final ean = code.length == 13 && RegExp(r'^\d+$').hasMatch(code);
    return pw.Container(
      width: 48 * PdfPageFormat.mm,
      padding: const pw.EdgeInsets.all(3),
      child: pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Text(shop.name, style: const pw.TextStyle(fontSize: 6), maxLines: 1),
          pw.Text(p.name, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold), maxLines: 1),
          pw.SizedBox(height: 2),
          pw.BarcodeWidget(
            barcode: ean ? pw.Barcode.ean13() : pw.Barcode.code128(),
            data: code,
            height: 26,
            width: 120,
            textStyle: const pw.TextStyle(fontSize: 6),
          ),
          pw.Text(p.priceText, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ],
      ),
    );
  }

  final labels = [
    for (final i in items.where((i) => i.product.barcode != null))
      for (var k = 0; k < i.copies; k++) label(i.product),
  ];
  if (a4) {
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(marginLeft: 20, marginRight: 20, marginTop: 20, marginBottom: 20),
      textDirection: pw.TextDirection.rtl,
      build: (_) => [pw.Wrap(spacing: 6, runSpacing: 6, children: labels)],
    ));
  } else {
    for (final l in labels) {
      doc.addPage(pw.Page(
        pageFormat: const PdfPageFormat(50 * PdfPageFormat.mm, 30 * PdfPageFormat.mm, marginAll: 1 * PdfPageFormat.mm),
        textDirection: pw.TextDirection.rtl,
        build: (_) => pw.Center(child: l),
      ));
    }
  }
  return doc.save();
}
