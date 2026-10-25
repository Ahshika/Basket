import 'format.dart';
import 'pos_types.dart';

class Product {
  Product(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        barcode = j['barcode'] as String?,
        plu = j['plu'] as int?,
        category = j['category'] as String?,
        unit = SaleUnit.parse(j['unit'] as String?),
        costCents = j['costCents'] as int? ?? 0,
        priceCents = j['priceCents'] as int? ?? 0,
        qtyMilli = j['qtyMilli'] as int? ?? 0,
        lowStockMilli = j['lowStockMilli'] as int? ?? 0,
        trackStock = j['trackStock'] as bool? ?? true,
        trackExpiry = j['trackExpiry'] as bool? ?? false,
        nextExpiry = j['nextExpiry'] as String?,
        notes = j['notes'] as String?;

  final String id;
  final String name;
  final String? barcode;

  /// رقم الصنف على الميزان.
  final int? plu;
  final String? category;
  final SaleUnit unit;

  /// لكل قطعة أو لكل كيلو.
  final int costCents;
  final int priceCents;

  /// الكمية بالألف (القطعة = 1000، الكيلو = 1000 جرام).
  final int qtyMilli;
  final int lowStockMilli;
  final bool trackStock;
  final bool trackExpiry;

  /// أقرب تاريخ صلاحية في المخزون (YYYY-MM-DD).
  final String? nextExpiry;
  final String? notes;

  bool get byWeight => unit == SaleUnit.kg;
  bool get isLow => trackStock && qtyMilli <= lowStockMilli;
  bool get outOfStock => trackStock && qtyMilli <= 0;
  String get qtyText => qtyLabel(qtyMilli, unit);
  String get priceText => byWeight ? '${money(priceCents)}/كيلو' : money(priceCents);
}

class CartLine {
  CartLine(this.product, {this.qtyMilli = milli, int? unitPriceCents, this.scaleBarcode, this.fixedTotalCents})
      : unitPriceCents = unitPriceCents ?? product.priceCents;

  final Product product;
  int qtyMilli;
  int unitPriceCents;

  /// السطر جاي من باركود ميزان: الكمية (والإجمالي لو الميزان بيطبع السعر) من الباركود، والسيرفر بيقراه تاني بنفسه.
  final String? scaleBarcode;
  final int? fixedTotalCents;

  bool get fromScale => scaleBarcode != null;
  int get totalCents => fixedTotalCents ?? lineTotal(unitPriceCents, qtyMilli);
  String get qtyText => formatQty(qtyMilli, product.unit);
}

class SaleSummary {
  SaleSummary(Map<String, dynamic> j)
      : id = j['id'] as String,
        number = j['number'] as int,
        customerId = j['customerId'] as String?,
        customerName = j['customerName'] as String?,
        subtotalCents = j['subtotalCents'] as int,
        discountCents = j['discountCents'] as int? ?? 0,
        totalCents = j['totalCents'] as int,
        paidCents = j['paidCents'] as int,
        returnedCents = j['returnedCents'] as int? ?? 0,
        dueCents = j['dueCents'] as int? ?? 0,
        itemsCount = j['itemsCount'] as int? ?? 0,
        userName = j['userName'] as String?,
        deliveryNumber = j['deliveryNumber'] as int?,
        note = j['note'] as String?,
        createdAt = parseDate(j['createdAt'])!;

  final String id;
  final int number;
  final String? customerId;
  final String? customerName;
  final int subtotalCents;
  final int discountCents;
  final int totalCents;
  final int paidCents;
  final int returnedCents;
  final int dueCents;
  final int itemsCount;
  final String? userName;

  /// رقم طلب التوصيل لو الفاتورة دي اتعملت وقت تسليم طلب.
  final int? deliveryNumber;
  final String? note;
  final DateTime createdAt;
}

class SaleItem {
  SaleItem(Map<String, dynamic> j)
      : id = j['id'] as String,
        productId = j['productId'] as String?,
        name = j['name'] as String,
        unit = SaleUnit.parse(j['unit'] as String?),
        qtyMilli = j['qtyMilli'] as int,
        unitPriceCents = j['unitPriceCents'] as int,
        totalCents = j['totalCents'] as int,
        returnedMilli = j['returnedMilli'] as int? ?? 0,
        returnedCents = j['returnedCents'] as int? ?? 0,
        costCents = j['costCents'] as int?;

  final String id;
  final String? productId;
  final String name;
  final SaleUnit unit;
  final int qtyMilli;
  final int unitPriceCents;
  final int totalCents;
  final int returnedMilli;
  final int returnedCents;
  final int? costCents;

  int get returnableMilli => productId == null ? 0 : qtyMilli - returnedMilli;
  String get qtyText => formatQty(qtyMilli, unit);
}

class SaleDetail {
  SaleDetail(Map<String, dynamic> j)
      : sale = SaleSummary(j['sale'] as Map<String, dynamic>),
        items = (j['items'] as List).map((i) => SaleItem(i as Map<String, dynamic>)).toList(),
        payments = (j['payments'] as List)
            .map((p) => (
                  type: p['type'] as String,
                  amountCents: p['amountCents'] as int,
                  method: PaymentMethod.parse(p['method'] as String?),
                ))
            .toList();

  final SaleSummary sale;
  final List<SaleItem> items;
  final List<({String type, int amountCents, PaymentMethod method})> payments;
}

class CashMove {
  CashMove(Map<String, dynamic> j)
      : id = j['id'] as String,
        type = j['type'] as String,
        amountCents = j['amountCents'] as int,
        method = PaymentMethod.parse(j['method'] as String?),
        category = j['category'] as String?,
        refType = j['refType'] as String?,
        refId = j['refId'] as String?,
        note = j['note'] as String?,
        userName = j['userName'] as String?,
        createdAt = parseDate(j['createdAt'])!;

  final String id;
  final String type;
  final int amountCents;
  final PaymentMethod method;
  final String? category;
  final String? refType;
  final String? refId;
  final String? note;
  final String? userName;
  final DateTime createdAt;
}

const cashMoveLabels = {
  'sale': 'بيع',
  'sale_refund': 'مرتجع بيع',
  'customer_payment': 'تحصيل من عميل',
  'driver_settlement': 'توريد طيار',
  'expense': 'مصروف',
  'deposit': 'إيداع',
  'withdraw': 'سحب',
  'supplier_payment': 'دفعة لمورد',
  'purchase_payment': 'فاتورة شرا',
};

/// وردية ودرج كاشير واحد.
class CashSession {
  CashSession(Map<String, dynamic> j)
      : id = j['id'] as String,
        userId = j['userId'] as String?,
        userName = j['userName'] as String?,
        deviceName = j['deviceName'] as String?,
        openedAt = parseDate(j['openedAt'])!,
        closedAt = parseDate(j['closedAt']),
        closedBy = j['closedBy'] as String?,
        openingCashCents = j['openingCashCents'] as int? ?? 0,
        byMethod = {for (final e in (j['byMethod'] as Map).entries) PaymentMethod.parse(e.key as String): e.value as int},
        byType = Map<String, int>.from(j['byType'] as Map),
        salesCount = j['salesCount'] as int? ?? 0,
        salesCents = j['salesCents'] as int? ?? 0,
        expectedCashCents = j['expectedCashCents'] as int? ?? 0,
        countedCashCents = j['countedCashCents'] as int?,
        keptCashCents = j['keptCashCents'] as int?,
        differenceCents = j['differenceCents'] as int?,
        note = j['note'] as String?,
        moves = (j['moves'] as List? ?? const []).map((m) => CashMove(m as Map<String, dynamic>)).toList(),
        movesCount = j['movesCount'] as int? ?? (j['moves'] as List? ?? const []).length;

  final String id;
  final String? userId;

  /// الكاشير صاحب الدرج.
  final String? userName;
  final String? deviceName;
  final DateTime openedAt;
  final DateTime? closedAt;
  final String? closedBy;
  final int openingCashCents;
  final Map<PaymentMethod, int> byMethod;
  final Map<String, int> byType;
  final int salesCount;
  final int salesCents;
  final int expectedCashCents;
  final int? countedCashCents;
  final int? keptCashCents;
  final int? differenceCents;
  final String? note;
  final List<CashMove> moves;

  /// عدد كل حركات الوردية (السيرفر بيبعت آخرها بس).
  final int movesCount;

  bool get isOpen => closedAt == null;
  int get expensesCents => -(byType['expense'] ?? 0);
  int get settlementsCents => byType['driver_settlement'] ?? 0;
}

class Supplier {
  Supplier(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        phone = j['phone'] as String?,
        notes = j['notes'] as String?,
        balanceCents = j['balanceCents'] as int? ?? 0;

  final String id;
  final String name;
  final String? phone;
  final String? notes;
  final int balanceCents;
}

class PurchaseSummary {
  PurchaseSummary(Map<String, dynamic> j)
      : id = j['id'] as String,
        number = j['number'] as int,
        supplierName = j['supplierName'] as String?,
        totalCents = j['totalCents'] as int,
        paidCents = j['paidCents'] as int,
        dueCents = j['dueCents'] as int? ?? 0,
        itemsCount = j['itemsCount'] as int? ?? 0,
        userName = j['userName'] as String?,
        createdAt = parseDate(j['createdAt'])!;

  final String id;
  final int number;
  final String? supplierName;
  final int totalCents;
  final int paidCents;
  final int dueCents;
  final int itemsCount;
  final String? userName;
  final DateTime createdAt;
}

/// دفعة بضاعة بتاريخ صلاحية.
class Batch {
  Batch(Map<String, dynamic> j)
      : id = j['id'] as String,
        productId = j['productId'] as String,
        productName = j['productName'] as String?,
        unit = SaleUnit.parse(j['unit'] as String?),
        expiresOn = j['expiresOn'] as String?,
        daysLeft = j['daysLeft'] as int?,
        qtyMilli = j['qtyMilli'] as int? ?? 0,
        valueCents = j['valueCents'] as int?,
        createdAt = parseDate(j['createdAt']);

  final String id;
  final String productId;
  final String? productName;
  final SaleUnit unit;
  final String? expiresOn;

  /// بالسالب لو الصلاحية خلصت.
  final int? daysLeft;
  final int qtyMilli;
  final int? valueCents;
  final DateTime? createdAt;

  bool get expired => daysLeft != null && daysLeft! < 0;
  DateTime? get expiryDate => expiresOn == null ? null : DateTime.tryParse(expiresOn!);

  String get expiryText {
    final d = daysLeft;
    if (d == null) return 'من غير تاريخ';
    if (d < 0) return 'خلصت من ${-d} يوم';
    if (d == 0) return 'بتخلص النهارده';
    return 'باقي $d يوم';
  }
}

class Driver {
  Driver(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        phone = j['phone'] as String?,
        userId = j['userId'] as String?,
        active = j['active'] as bool? ?? true,
        outstandingCents = j['outstandingCents'] as int? ?? 0,
        openOrders = j['openOrders'] as int? ?? 0;

  final String id;
  final String name;
  final String? phone;

  /// لو الطيار ليه حساب على البرنامج.
  final String? userId;
  final bool active;

  /// فلوس طلبات اتسلمت ولسه ماتوردتش.
  final int outstandingCents;
  final int openOrders;
}

class DeliveryOrder {
  DeliveryOrder(Map<String, dynamic> j)
      : id = j['id'] as String,
        number = j['number'] as int,
        status = DeliveryStatus.parse(j['status'] as String?),
        customerId = j['customerId'] as String,
        customerName = j['customerName'] as String? ?? '',
        customerPhone = j['customerPhone'] as String? ?? '',
        customerWhatsapp = j['customerWhatsapp'] as String?,
        address = j['address'] as String? ?? '',
        channel = j['channel'] as String? ?? 'phone',
        subtotalCents = j['subtotalCents'] as int? ?? 0,
        deliveryFeeCents = j['deliveryFeeCents'] as int? ?? 0,
        totalCents = j['totalCents'] as int? ?? 0,
        driverId = j['driverId'] as String?,
        driverName = j['driverName'] as String?,
        driverPhone = j['driverPhone'] as String?,
        saleId = j['saleId'] as String?,
        collectedCents = j['collectedCents'] as int?,
        settled = j['settled'] as bool? ?? false,
        note = j['note'] as String?,
        cancelReason = j['cancelReason'] as String?,
        itemsCount = j['itemsCount'] as int? ?? 0,
        createdBy = j['createdBy'] as String?,
        createdAt = parseDate(j['createdAt'])!,
        outAt = parseDate(j['outAt']),
        deliveredAt = parseDate(j['deliveredAt']);

  final String id;
  final int number;
  final DeliveryStatus status;
  final String customerId;
  final String customerName;
  final String customerPhone;
  final String? customerWhatsapp;
  final String address;
  final String channel;
  final int subtotalCents;
  final int deliveryFeeCents;
  final int totalCents;
  final String? driverId;
  final String? driverName;
  final String? driverPhone;
  final String? saleId;
  final int? collectedCents;
  final bool settled;
  final String? note;
  final String? cancelReason;
  final int itemsCount;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime? outAt;
  final DateTime? deliveredAt;
}

class DeliveryItem {
  DeliveryItem(Map<String, dynamic> j)
      : id = j['id'] as String,
        productId = j['productId'] as String,
        name = j['name'] as String,
        unit = SaleUnit.parse(j['unit'] as String?),
        qtyMilli = j['qtyMilli'] as int,
        unitPriceCents = j['unitPriceCents'] as int,
        totalCents = j['totalCents'] as int;

  final String id;
  final String productId;
  final String name;
  final SaleUnit unit;
  final int qtyMilli;
  final int unitPriceCents;
  final int totalCents;

  String get qtyText => qtyLabel(qtyMilli, unit);
}
