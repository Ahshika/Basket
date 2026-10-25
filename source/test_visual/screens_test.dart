// ignore_for_file: invalid_use_of_visible_for_testing_member
// بيرسم الشاشات الأساسية ببيانات تجريبية ويحفظها كصور PNG للمراجعة (وبيفشل لو فيه شاشة طالعة برا حدودها).
// التشغيل:  flutter test test_visual --update-goldens
import 'dart:io';

import 'package:basket/src/core/api_client.dart';
import 'package:basket/src/core/app_config.dart';
import 'package:basket/src/core/models.dart';
import 'package:basket/src/core/pos_models.dart';
import 'package:basket/src/core/pos_types.dart';
import 'package:basket/src/core/providers.dart';
import 'package:basket/src/core/session.dart';
import 'package:basket/src/core/shop.dart';
import 'package:basket/src/core/theme.dart';
import 'package:basket/src/features/delivery/delivery_screen.dart';
import 'package:basket/src/features/home/home_shell.dart';
import 'package:basket/src/features/inventory/expiry_screen.dart';
import 'package:basket/src/features/inventory/products_screen.dart';
import 'package:basket/src/features/pos/cart.dart';
import 'package:basket/src/features/pos/cash_screen.dart';
import 'package:basket/src/features/pos/pos_screen.dart';
import 'package:basket/src/features/pos/providers.dart';
import 'package:basket/src/features/reports/reports_screen.dart';
import 'package:basket/src/features/settings/shop_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSession extends SessionController {
  _FakeSession(this.role);
  final Role role;

  @override
  Future<Session> build() async => Session(
        SessionStatus.ready,
        api: ApiClient('http://fake'),
        info: ServerInfo(serverId: 'x', setupDone: true, version: '1.0.0', api: 1, shopName: 'سوبر ماركت النور', branchName: 'فرع المعادي'),
        user: AppUser(id: 'u1', name: role == Role.driver ? 'حمادة سيد' : 'أحمد حسن', username: 'ahmed', role: role, active: true),
      );
}

String _iso(Duration d) => DateTime.now().add(d).toUtc().toIso8601String();
String _day(int days) {
  final n = DateTime.now();
  final d = DateTime(n.year, n.month, n.day + days);
  return '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';
}

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    await loader.load();
  }

  await load('Cairo', 'assets/fonts/Cairo-Variable.ttf');
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? 'C:/src/flutter';
  await load('MaterialIcons', '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
}

Future<void> _shot(WidgetTester tester, String name, Widget home, Size size, {Brightness brightness = Brightness.light, Role role = Role.owner}) async {
  SharedPreferences.setMockInitialValues({'flutter.mode': 'server', 'mode': 'server'});
  final config = await AppConfig.load();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: [
      appConfigProvider.overrideWithValue(config),
      sessionProvider.overrideWith(() => _FakeSession(role)),
      shopProvider.overrideWith((ref) async => ShopProfile({
            'name': 'سوبر ماركت النور', 'phone': '0100 555 6677', 'receiptPaper': '80mm', 'expiryAlertDays': 7, 'deliveryFeeCents': 1500,
            'scaleFormat': const ScaleFormat().toJson(),
          })),
      dashboardProvider.overrideWith((ref) async => DashboardStats(role == Role.driver
          ? {'myOpenDeliveries': 2, 'myCashCents': 84500}
          : {
              'salesTodayCount': 186, 'salesTodayCents': 2148350, 'mySalesTodayCents': 912000, 'profitTodayCents': 301200,
              'lowStockCount': 7, 'expiringCount': 4, 'expiredCount': 1, 'expiryAlertDays': 7,
              'delivery_new': 2, 'delivery_preparing': 1, 'delivery_out': 2, 'openDrawers': 3, 'driversCashCents': 84500,
            })),
      productsProvider.overrideWith((ref, q) async => (items: _products, count: _products.length, lowCount: 1, stockValueCents: 18450000)),
      categoriesProvider.overrideWith((ref) async => ['ألبان', 'بقالة', 'جبن ولحوم', 'منظفات', 'حلويات']),
      cartProvider.overrideWith(_FakeCart.new),
      cashCurrentProvider.overrideWith((ref) async => (session: _session, categories: ['إيجار', 'كهرباء', 'أكياس وتغليف', 'أخرى'])),
      openDrawersProvider.overrideWith((ref) async => (
            drawers: _drawers,
            totalCents: _drawers.fold<int>(0, (s, d) => s + d.expectedCashCents),
            drivers: [{'id': 'd1', 'name': 'حمادة سيد', 'outstandingCents': 84500}],
          )),
      deliveryOrdersProvider.overrideWith((ref, q) async => q.status == 'out' ? _orders.where((o) => o.status == DeliveryStatus.out).toList() : _orders),
      driversProvider.overrideWith((ref) async => _drivers),
      expiringProvider.overrideWith((ref, days) async => _batches),
      expiryReportProvider.overrideWith((ref) async => {'expiredValueCents': 4320, 'expiringValueCents': 61250, 'wasteValueCents': 18900, 'waste': [
            {'name': 'زبادي جهينة', 'unit': 'piece', 'reason': 'expired', 'qtyMilli': 12000, 'valueCents': 7200},
            {'name': 'طماطم', 'unit': 'kg', 'reason': 'damaged', 'qtyMilli': 3500, 'valueCents': 11700},
          ]}),
      reportProvider.overrideWith((ref, k) async => _report()),
      licenseProvider.overrideWith((ref) async => {'state': 'trial', 'daysLeft': 9, 'plan': 'trial', 'deviceCode': 'ABCDE-FGH23', 'devices': 5}),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar', 'EG'),
      supportedLocales: const [Locale('ar', 'EG')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(brightness),
      home: Consumer(builder: (context, ref, _) => ref.watch(sessionProvider).hasValue ? home : const SizedBox()),
    ),
  ));
  await tester.pumpAndSettle();
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ar');
    await _loadFonts();
  });
  const desktop = Size(1280, 800);
  const phone = Size(400, 860);

  testWidgets('dashboard desktop', (t) => _shot(t, 'dashboard_desktop', const HomeShell(), desktop));
  testWidgets('dashboard phone', (t) => _shot(t, 'dashboard_phone', const HomeShell(), phone));
  testWidgets('pos desktop', (t) => _shot(t, 'pos_desktop', const PosScreen(), desktop));
  testWidgets('pos phone', (t) => _shot(t, 'pos_phone', const PosScreen(), phone));
  testWidgets('products desktop', (t) => _shot(t, 'products_desktop', const ProductsScreen(), desktop));
  testWidgets('expiry desktop', (t) => _shot(t, 'expiry_desktop', const ExpiryScreen(), const Size(1280, 900)));
  testWidgets('delivery desktop', (t) => _shot(t, 'delivery_desktop', const DeliveryScreen(), const Size(1280, 900)));
  testWidgets('delivery driver phone', (t) => _shot(t, 'delivery_driver_phone', const HomeShell(), phone, role: Role.driver));
  testWidgets('cash desktop', (t) => _shot(t, 'cash_desktop', const CashScreen(), const Size(1280, 1000)));
  testWidgets('drawers desktop', (t) => _shot(t, 'drawers_desktop', const DrawersScreen(), desktop));
  testWidgets('reports desktop', (t) => _shot(t, 'reports_desktop', const ReportsScreen(), const Size(1280, 1800)));
  testWidgets('settings phone dark', (t) => _shot(t, 'shop_settings_phone_dark', const ShopSettingsScreen(), const Size(400, 2400), brightness: Brightness.dark));
  testWidgets('shell small laptop', (t) => _shot(t, 'shell_small_laptop', const HomeShell(), const Size(1366, 640)));
}

final _products = [
  Product({'id': 'p1', 'name': 'لبن جهينة كامل الدسم 1 لتر', 'barcode': '6223000120015', 'category': 'ألبان', 'costCents': 3400, 'priceCents': 4000, 'qtyMilli': 46000, 'lowStockMilli': 12000, 'trackStock': true, 'trackExpiry': true, 'nextExpiry': _day(3)}),
  Product({'id': 'p2', 'name': 'جبنة رومي قديمة', 'plu': 123, 'unit': 'kg', 'category': 'جبن ولحوم', 'costCents': 26000, 'priceCents': 32000, 'qtyMilli': 7350, 'lowStockMilli': 2000, 'trackStock': true, 'trackExpiry': true, 'nextExpiry': _day(21)}),
  Product({'id': 'p3', 'name': 'أرز الضحى 1 كيلو', 'barcode': '6224000510051', 'category': 'بقالة', 'costCents': 3000, 'priceCents': 3600, 'qtyMilli': 120000, 'lowStockMilli': 20000, 'trackStock': true}),
  Product({'id': 'p4', 'name': 'زيت كريستال 800 مل', 'barcode': '6221031490124', 'category': 'بقالة', 'costCents': 7800, 'priceCents': 8900, 'qtyMilli': 4000, 'lowStockMilli': 6000, 'trackStock': true}),
  Product({'id': 'p5', 'name': 'طماطم', 'plu': 7, 'unit': 'kg', 'category': 'خضار وفاكهة', 'costCents': 1200, 'priceCents': 1800, 'qtyMilli': 38500, 'lowStockMilli': 10000, 'trackStock': true}),
  Product({'id': 'p6', 'name': 'بريل سائل أطباق 650 مل', 'barcode': '6221155021243', 'category': 'منظفات', 'costCents': 2900, 'priceCents': 3500, 'qtyMilli': 0, 'lowStockMilli': 5000, 'trackStock': true}),
  Product({'id': 'p7', 'name': 'حلاوة طحينية بالكيلو', 'plu': 42, 'unit': 'kg', 'category': 'حلويات', 'costCents': 9000, 'priceCents': 12000, 'qtyMilli': 15250, 'lowStockMilli': 3000, 'trackStock': true}),
];

class _FakeCart extends CartController {
  @override
  CartState build() => CartState(lines: [
        CartLine(_products[0], qtyMilli: 3000),
        CartLine(_products[1], qtyMilli: 1250, scaleBarcode: buildScaleBarcode(const ScaleFormat(), '21', 123, 1250), fixedTotalCents: 40000),
        CartLine(_products[4], qtyMilli: 2150),
        CartLine(_products[2], qtyMilli: 2000, unitPriceCents: 3400),
      ], discountCents: 500);
}

CashSession _drawer(String id, String user, String device, int sales, int count, int expected, {int settlements = 0}) => CashSession({
      'id': id,
      'userId': 'u-$id',
      'userName': user,
      'deviceName': device,
      'openedAt': _iso(const Duration(hours: -7)),
      'openingCashCents': 50000,
      'byMethod': {'cash': expected - 50000, 'vodafoneCash': 45000, 'instapay': 12000, 'card': 0, 'other': 0},
      'byType': {'sale': sales, 'expense': -3000, 'driver_settlement': settlements},
      'salesCount': count,
      'salesCents': sales,
      'expectedCashCents': expected,
      'moves': [
        {'id': 'm1', 'type': 'sale', 'amountCents': 23450, 'method': 'cash', 'note': 'فاتورة #418', 'userName': user, 'createdAt': _iso(const Duration(minutes: -4))},
        {'id': 'm2', 'type': 'driver_settlement', 'amountCents': 61000, 'method': 'cash', 'note': 'توريد حمادة سيد (3 طلب)', 'userName': user, 'createdAt': _iso(const Duration(minutes: -40))},
        {'id': 'm3', 'type': 'expense', 'amountCents': -3000, 'method': 'cash', 'category': 'أكياس وتغليف', 'userName': user, 'createdAt': _iso(const Duration(hours: -2))},
        {'id': 'm4', 'type': 'sale', 'amountCents': 45000, 'method': 'vodafoneCash', 'note': 'فاتورة #391', 'userName': user, 'createdAt': _iso(const Duration(hours: -3))},
      ],
    });

final _session = _drawer('s1', 'سارة', 'كاشير 1', 912000, 74, 1018000, settlements: 61000);
final _drawers = [
  _session,
  _drawer('s2', 'عمر', 'كاشير 2', 784350, 69, 803000),
  _drawer('s3', 'منى (مسؤول شفت)', 'الكمبيوتر الرئيسي', 452000, 43, 471500),
];

DeliveryOrder _order(int n, String status, String customer, String address, int total, {String? driver, Duration ago = const Duration(minutes: -20)}) => DeliveryOrder({
      'id': 'o$n', 'number': n, 'status': status, 'customerId': 'c$n', 'customerName': customer, 'customerPhone': '0100 123 45$n',
      'address': address, 'channel': n.isEven ? 'whatsapp' : 'phone', 'subtotalCents': total - 1500, 'deliveryFeeCents': 1500, 'totalCents': total,
      'driverId': driver == null ? null : 'd1', 'driverName': driver, 'itemsCount': 3 + n % 5, 'createdAt': _iso(ago),
      'collectedCents': status == 'delivered' ? total : null, 'settled': false,
    });

final _orders = [
  _order(57, 'new', 'أم كريم', 'شارع التحرير، عمارة 5، الدور 3، شقة 9', 31500, ago: const Duration(minutes: -3)),
  _order(56, 'new', 'مدام نادية', 'المعادي، شارع 9، فيلا 12', 74200, ago: const Duration(minutes: -11)),
  _order(55, 'preparing', 'أستاذ سامح', 'زهراء المعادي، عمارة 30 بجوار المسجد', 18750),
  _order(54, 'out', 'دكتورة هالة', 'دجلة، شارع 213، عمارة 4', 52400, driver: 'حمادة سيد', ago: const Duration(minutes: -35)),
  _order(53, 'out', 'كريم سامي', 'المعادي الجديدة، شارع النصر', 26900, driver: 'حمادة سيد', ago: const Duration(minutes: -50)),
];

final _drivers = [
  Driver({'id': 'd1', 'name': 'حمادة سيد', 'phone': '01112223334', 'userId': 'u9', 'outstandingCents': 84500, 'openOrders': 2}),
  Driver({'id': 'd2', 'name': 'محمود (موتوسيكل)', 'phone': '01223334445', 'outstandingCents': 0, 'openOrders': 0}),
];

final _batches = [
  Batch({'id': 'b1', 'productId': 'p8', 'productName': 'زبادي جهينة', 'unit': 'piece', 'expiresOn': _day(-1), 'daysLeft': -1, 'qtyMilli': 7000, 'valueCents': 4320}),
  Batch({'id': 'b2', 'productId': 'p1', 'productName': 'لبن جهينة كامل الدسم 1 لتر', 'unit': 'piece', 'expiresOn': _day(3), 'daysLeft': 3, 'qtyMilli': 12000, 'valueCents': 40800}),
  Batch({'id': 'b3', 'productId': 'p9', 'productName': 'جبنة بيضا اسطنبولي', 'unit': 'kg', 'expiresOn': _day(5), 'daysLeft': 5, 'qtyMilli': 4250, 'valueCents': 20450}),
];

Map<String, dynamic> _report() {
  final days = [
    for (var i = 0; i < 26; i++)
      {'date': DateTime.now().subtract(Duration(days: 25 - i)).toIso8601String().substring(0, 10), 'sales': 1400000 + (i * 37 % 11) * 90000, 'expenses': 20000, 'waste': i % 6 == 0 ? 15000 : 0},
  ];
  return {
    'netProfitCents': 6825000,
    'sales': {
      'count': 4214, 'revenueCents': 41230000, 'costCents': 33100000, 'profitCents': 8130000, 'discountCents': 42000, 'returnsCents': 18000,
      'topProducts': [
        {'name': 'أرز الضحى 1 كيلو', 'unit': 'piece', 'qty': 640000, 'revenue': 2304000, 'profit': 384000},
        {'name': 'جبنة رومي قديمة', 'unit': 'kg', 'qty': 84350, 'revenue': 2699200, 'profit': 506100},
        {'name': 'طماطم', 'unit': 'kg', 'qty': 410750, 'revenue': 739350, 'profit': 246450},
      ],
      'byCashier': [{'name': 'سارة', 'count': 1840, 'revenue': 17840000}, {'name': 'عمر', 'count': 1602, 'revenue': 15210000}, {'name': 'منى', 'count': 600, 'revenue': 6380000}],
      'byCategory': [{'name': 'بقالة', 'revenue': 14200000}, {'name': 'ألبان', 'revenue': 9800000}, {'name': 'جبن ولحوم', 'revenue': 7400000}],
    },
    'delivery': {
      'delivered': 172, 'totalCents': 6150000, 'feesCents': 258000, 'cancelled': 6, 'shortageCents': -1500, 'withDriversCents': 84500,
      'byDriver': [{'name': 'حمادة سيد', 'count': 104, 'total': 3720000}, {'name': 'محمود (موتوسيكل)', 'count': 68, 'total': 2430000}],
    },
    'waste': {'totalCents': 189000, 'items': [
      {'name': 'زبادي جهينة', 'unit': 'piece', 'reason': 'expired', 'qtyMilli': 48000, 'valueCents': 28800},
      {'name': 'طماطم', 'unit': 'kg', 'reason': 'damaged', 'qtyMilli': 35500, 'valueCents': 42600},
    ]},
    'expenses': {'totalCents': 1116000, 'byCategory': [{'name': 'إيجار', 'total': 800000}, {'name': 'كهرباء', 'total': 260000}, {'name': 'بنزين التوصيل', 'total': 56000}]},
    'cashDifferenceCents': -500,
    'daily': days,
    'stock': {'valueCents': 48450000, 'expiringValueCents': 61250, 'deadStock': [{'name': 'صلصة طماطم برطمان', 'unit': 'piece', 'qty': 14000, 'value': 42000}], 'lowStock': []},
    'receivables': {'totalCents': 340000, 'customers': [{'name': 'عم سيد البقال', 'phone': '01112223334', 'balanceCents': 250000}]},
    'payables': {'totalCents': 1200000, 'suppliers': [{'name': 'جهينة', 'balanceCents': 1200000}]},
  };
}
