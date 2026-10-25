import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../core/app_config.dart';
import '../../core/pos_models.dart';
import '../../core/session.dart';
import '../../core/shop.dart';
import '../../widgets/common.dart';
import 'receipt_pdf.dart';

/// طباعة فاتورة بيع على طابعة الوصولات.
Future<void> printSale(BuildContext context, WidgetRef ref, String saleId) async {
  try {
    final api = ref.read(sessionProvider).value!.api!;
    final detail = SaleDetail(await api.get('/api/sales/$saleId'));
    final shop = await ref.read(shopProvider.future);
    final bytes = await buildSalePdf(detail, shop);
    if (!context.mounted) return;
    await _printBytes(context, ref, bytes, 'فاتورة-${detail.sale.number}', paperFormat(shop.receiptPaper));
  } catch (e) {
    if (context.mounted) showMessage(context, 'مشكلة في الطباعة: ${errorText(e)}', error: true);
  }
}

/// ورقة طلب التوصيل اللي بتتحط مع الشنطة.
Future<void> printDeliverySlip(BuildContext context, WidgetRef ref, String orderId) async {
  try {
    final api = ref.read(sessionProvider).value!.api!;
    final res = await api.get('/api/delivery/$orderId');
    final order = DeliveryOrder(res['order'] as Map<String, dynamic>);
    final items = (res['items'] as List).map((j) => DeliveryItem(j as Map<String, dynamic>)).toList();
    final shop = await ref.read(shopProvider.future);
    final bytes = await buildDeliverySlipPdf(order, items, shop);
    if (!context.mounted) return;
    await _printBytes(context, ref, bytes, 'توصيل-${order.number}', paperFormat(shop.receiptPaper));
  } catch (e) {
    if (context.mounted) showMessage(context, 'مشكلة في الطباعة: ${errorText(e)}', error: true);
  }
}

Future<void> printBarcodeLabels(BuildContext context, WidgetRef ref, List<({Product product, int copies})> items, {bool a4 = false}) async {
  try {
    final shop = await ref.read(shopProvider.future);
    final bytes = await buildBarcodeLabelsPdf(items, shop, a4: a4);
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'باركود');
  } catch (e) {
    if (context.mounted) showMessage(context, 'مشكلة في الطباعة: ${errorText(e)}', error: true);
  }
}

Future<void> _printBytes(BuildContext context, WidgetRef ref, Uint8List bytes, String name, PdfPageFormat format) async {
  final config = ref.read(appConfigProvider);
  final url = config.receiptPrinterUrl;
  if (url != null) {
    final ok = await Printing.directPrintPdf(
      printer: Printer(url: url, name: config.receiptPrinterName),
      onLayout: (_) async => bytes,
      name: name,
      format: format,
    );
    if (!ok && context.mounted) showMessage(context, 'الطباعة ما تمتش، اتأكد إن الطابعة شغالة', error: true);
    return;
  }
  await Printing.layoutPdf(onLayout: (_) async => bytes, name: name, format: format);
}

/// اختيار طابعة الوصولات الافتراضية للجهاز ده.
Future<void> pickReceiptPrinter(BuildContext context, WidgetRef ref) async {
  final config = ref.read(appConfigProvider);
  final printer = await Printing.pickPrinter(context: context, title: 'اختار طابعة الوصولات');
  if (printer == null) return;
  await config.setReceiptPrinter(printer.url, printer.name);
  if (context.mounted) showMessage(context, 'الوصولات هتتطبع على ${printer.name}');
}
