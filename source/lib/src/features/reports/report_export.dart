import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/file_save.dart';
import '../../core/format.dart';
import '../../core/pos_types.dart';
import '../../core/shop.dart';
import '../../core/spreadsheet.dart';
import '../../widgets/common.dart';

double _p(Object? cents) => ((cents as int?) ?? 0) / 100;

/// الكمية كرقم في Excel (1.25 للكيلو، 3 للقطع).
double _q(Object? milliQty) => ((milliQty as int?) ?? 0) / milli;

String _qty(Map<String, dynamic> m, [String key = 'qty']) => qtyLabel(m[key] as int? ?? 0, SaleUnit.parse(m['unit'] as String?));

String _unit(Map<String, dynamic> m) => SaleUnit.parse(m['unit'] as String?).label;

/// التقرير كملف Excel: شيت لكل قسم عشان المحاسب يقدر يشتغل عليه.
Future<void> exportReportExcel(BuildContext context, Map<String, dynamic> r, String label) async {
  try {
    final sales = r['sales'] as Map<String, dynamic>;
    final delivery = r['delivery'] as Map<String, dynamic>;
    final waste = r['waste'] as Map<String, dynamic>;
    final expenses = r['expenses'] as Map<String, dynamic>;
    final w = XlsxWriter()
      ..addSheet('الملخص', [
        ['البند', 'القيمة (ج.م)'],
        ['الفترة', label],
        ['صافي الربح', _p(r['netProfitCents'])],
        ['المبيعات', _p(sales['revenueCents'])],
        ['تكلفة المبيعات', _p(sales['costCents'])],
        ['ربح المبيعات', _p(sales['profitCents'])],
        ['الخصومات', _p(sales['discountCents'])],
        ['المرتجعات', _p(sales['returnsCents'])],
        ['طلبات توصيل اتسلمت', delivery['delivered']],
        ['إجمالي التوصيل', _p(delivery['totalCents'])],
        ['رسوم التوصيل', _p(delivery['feesCents'])],
        ['فرق توريد الطيارين', _p(delivery['shortageCents'])],
        ['الهالك', _p(waste['totalCents'])],
        ['المصروفات', _p(expenses['totalCents'])],
        ['فرق الأدراج', _p(r['cashDifferenceCents'])],
      ])
      ..addSheet('يوم بيوم', [
        ['التاريخ', 'المبيعات', 'المصروفات', 'الهالك'],
        for (final d in (r['daily'] as List).cast<Map<String, dynamic>>()) [d['date'], _p(d['sales']), _p(d['expenses']), _p(d['waste'])],
      ])
      ..addSheet('الأصناف', [
        ['الصنف', 'الكمية', 'الوحدة', 'المبيعات', 'الربح'],
        for (final p in (sales['topProducts'] as List).cast<Map<String, dynamic>>()) [p['name'], _q(p['qty']), _unit(p), _p(p['revenue']), _p(p['profit'])],
      ])
      ..addSheet('الأقسام', [
        ['القسم', 'المبيعات'],
        for (final c in (sales['byCategory'] as List).cast<Map<String, dynamic>>()) [c['name'], _p(c['revenue'])],
      ])
      ..addSheet('الكاشيرية', [
        ['الكاشير', 'فواتير', 'المبيعات'],
        for (final c in (sales['byCashier'] as List).cast<Map<String, dynamic>>()) [c['name'], c['count'], _p(c['revenue'])],
      ])
      ..addSheet('التوصيل', [
        ['الطيار', 'طلبات', 'الإجمالي'],
        for (final d in (delivery['byDriver'] as List).cast<Map<String, dynamic>>()) [d['name'], d['count'], _p(d['total'])],
      ])
      ..addSheet('الهالك', [
        ['الصنف', 'السبب', 'الكمية', 'الوحدة', 'القيمة'],
        for (final x in (waste['items'] as List).cast<Map<String, dynamic>>())
          [x['name'], x['reason'] == 'expired' ? 'صلاحيته خلصت' : 'تالف', _q(x['qtyMilli']), _unit(x), _p(x['valueCents'])],
      ])
      ..addSheet('المصروفات', [
        ['البند', 'المبلغ'],
        for (final e in (expenses['byCategory'] as List).cast<Map<String, dynamic>>()) [e['name'], _p(e['total'])],
      ])
      ..addSheet('ديون العملاء', [
        ['العميل', 'التليفون', 'عليه'],
        for (final c in ((r['receivables'] as Map)['customers'] as List).cast<Map<String, dynamic>>()) [c['name'], c['phone'], _p(c['balanceCents'])],
      ]);
    final path = await saveOrShareFile(w.build(), 'تقرير Basket - ${latinDigits(label).replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')}.xlsx',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    if (path != null && context.mounted) showMessage(context, 'اتحفظ: $path');
  } catch (e) {
    if (context.mounted) showMessage(context, 'مشكلة في التصدير: $e', error: true);
  }
}

/// التقرير كملف PDF للطباعة أو الإرسال.
Future<void> exportReportPdf(BuildContext context, WidgetRef ref, Map<String, dynamic> r, String label) async {
  try {
    final shop = await ref.read(shopProvider.future);
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold), title: 'تقرير $label');
    final sales = r['sales'] as Map<String, dynamic>;
    final delivery = r['delivery'] as Map<String, dynamic>;
    final waste = r['waste'] as Map<String, dynamic>;
    final expenses = r['expenses'] as Map<String, dynamic>;

    pw.Widget table(String title, List<String> headers, List<List<String>> rows) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.SizedBox(height: 12),
          pw.Text(title, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          if (rows.isEmpty)
            pw.Text('—')
          else
            pw.TableHelper.fromTextArray(
              headers: headers,
              data: rows,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
              cellStyle: const pw.TextStyle(fontSize: 9),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
              cellAlignment: pw.Alignment.centerRight,
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
            ),
        ]);

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      margin: const pw.EdgeInsets.all(28),
      header: (_) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text(shop.name, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text('تقرير: $label', style: const pw.TextStyle(fontSize: 11)),
      ]),
      footer: (c) => pw.Center(child: pw.Text('Basket • ${formatDateTime(DateTime.now())} • صفحة ${c.pageNumber}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600))),
      build: (_) => [
        pw.SizedBox(height: 8),
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('صافي الربح', style: const pw.TextStyle(fontSize: 10)),
            pw.Text(money(r['netProfitCents'] as int), style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          ]),
        ),
        table('الملخص', ['البند', 'القيمة'], [
          ['المبيعات (${sales['count']} فاتورة)', money(sales['revenueCents'] as int)],
          ['ربح المبيعات', money(sales['profitCents'] as int)],
          ['التوصيل (${delivery['delivered']} طلب)', money(delivery['totalCents'] as int)],
          ['رسوم التوصيل', money(delivery['feesCents'] as int)],
          ['الهالك', money(waste['totalCents'] as int)],
          ['المصروفات', money(expenses['totalCents'] as int)],
          ['فرق الأدراج', money(r['cashDifferenceCents'] as int)],
        ]),
        table('أكتر الأصناف مبيعاً', ['الصنف', 'الكمية', 'المبيعات', 'الربح'], [
          for (final p in (sales['topProducts'] as List).cast<Map<String, dynamic>>())
            [p['name'] as String, _qty(p), money(p['revenue'] as int), money(p['profit'] as int)],
        ]),
        table('الكاشيرية', ['الكاشير', 'فواتير', 'المبيعات'], [
          for (final c in (sales['byCashier'] as List).cast<Map<String, dynamic>>())
            [c['name'] as String? ?? '—', '${c['count']}', money(c['revenue'] as int? ?? 0)],
        ]),
        table('الهالك', ['الصنف', 'السبب', 'الكمية', 'القيمة'], [
          for (final x in (waste['items'] as List).cast<Map<String, dynamic>>())
            [x['name'] as String, x['reason'] == 'expired' ? 'صلاحيته خلصت' : 'تالف', _qty(x, 'qtyMilli'), money(x['valueCents'] as int? ?? 0)],
        ]),
        table('المصروفات', ['البند', 'المبلغ'], [
          for (final e in (expenses['byCategory'] as List).cast<Map<String, dynamic>>()) [e['name'] as String, money(e['total'] as int)],
        ]),
        table('ديون العملاء', ['العميل', 'التليفون', 'عليه'], [
          for (final c in ((r['receivables'] as Map)['customers'] as List).cast<Map<String, dynamic>>())
            [c['name'] as String, c['phone'] as String? ?? '', money(c['balanceCents'] as int)],
        ]),
      ],
    ));
    await Printing.layoutPdf(onLayout: (_) async => doc.save(), name: 'تقرير $label');
  } catch (e) {
    if (context.mounted) showMessage(context, 'مشكلة في التصدير: $e', error: true);
  }
}
