import 'format.dart';

enum Role {
  owner('المالك'),
  supervisor('مسؤول شفت'),
  cashier('كاشير'),
  driver('طيار توصيل');

  const Role(this.label);
  final String label;

  static Role parse(String? v) => Role.values.firstWhere((r) => r.name == v, orElse: () => Role.cashier);
}

class AppUser {
  AppUser({
    required this.id,
    required this.name,
    required this.username,
    required this.role,
    required this.active,
    this.createdAt,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as String,
        name: j['name'] as String,
        username: j['username'] as String,
        role: Role.parse(j['role'] as String?),
        active: j['active'] as bool? ?? true,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal(),
      );

  final String id;
  final String name;
  final String username;
  final Role role;
  final bool active;
  final DateTime? createdAt;

  bool get isOwner => role == Role.owner;

  /// المالك أو مسؤول الشفت: يوافق على الخصم والجرد والهالك، ويشوف كل الأدراج.
  bool get isManager => role == Role.owner || role == Role.supervisor;

  /// اللي بيبيع ويتعامل مع الدرج (مش طيار التوصيل).
  bool get isCashStaff => role != Role.driver;
}

class ServerInfo {
  ServerInfo({
    required this.serverId,
    required this.setupDone,
    required this.version,
    required this.api,
    this.shopName,
    this.branchName,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> j) {
    if (j['app'] != 'basket') throw const FormatException('not a Basket server');
    return ServerInfo(
      serverId: j['serverId'] as String? ?? '',
      setupDone: j['setupDone'] as bool? ?? false,
      version: j['version'] as String? ?? '',
      api: j['api'] as int? ?? 0,
      shopName: j['shopName'] as String?,
      branchName: j['branchName'] as String?,
    );
  }

  final String serverId;
  final bool setupDone;
  final String version;
  final int api;
  final String? shopName;
  final String? branchName;
}

class Customer {
  Customer({
    required this.id,
    required this.name,
    required this.phone,
    this.whatsapp,
    this.address,
    this.notes,
    this.lastVisit,
    this.balanceCents = 0,
  });

  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: j['id'] as String,
        name: j['name'] as String,
        phone: j['phone'] as String,
        whatsapp: j['whatsapp'] as String?,
        address: j['address'] as String?,
        notes: j['notes'] as String?,
        lastVisit: parseDate(j['lastVisit']),
        balanceCents: j['balanceCents'] as int? ?? 0,
      );

  final String id;
  final String name;
  final String phone;
  final String? whatsapp;
  final String? address;
  final String? notes;
  final DateTime? lastVisit;
  final int balanceCents;
}

class StaffMember {
  StaffMember(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        role = Role.parse(j['role'] as String?);

  final String id;
  final String name;
  final Role role;
}

class DashboardStats {
  DashboardStats(Map<String, dynamic> j)
      : salesTodayCount = j['salesTodayCount'] as int? ?? 0,
        salesTodayCents = j['salesTodayCents'] as int? ?? 0,
        mySalesTodayCents = j['mySalesTodayCents'] as int? ?? 0,
        profitTodayCents = j['profitTodayCents'] as int?,
        lowStockCount = j['lowStockCount'] as int? ?? 0,
        expiringCount = j['expiringCount'] as int? ?? 0,
        expiredCount = j['expiredCount'] as int? ?? 0,
        expiryAlertDays = j['expiryAlertDays'] as int? ?? 30,
        deliveryNew = j['delivery_new'] as int? ?? 0,
        deliveryPreparing = j['delivery_preparing'] as int? ?? 0,
        deliveryOut = j['delivery_out'] as int? ?? 0,
        openDrawers = j['openDrawers'] as int?,
        driversCashCents = j['driversCashCents'] as int?,
        myOpenDeliveries = j['myOpenDeliveries'] as int? ?? 0,
        myCashCents = j['myCashCents'] as int? ?? 0;

  final int salesTodayCount;
  final int salesTodayCents;
  final int mySalesTodayCents;
  final int? profitTodayCents;
  final int lowStockCount;
  final int expiringCount;
  final int expiredCount;
  final int expiryAlertDays;
  final int deliveryNew;
  final int deliveryPreparing;
  final int deliveryOut;
  final int? openDrawers;
  final int? driversCashCents;

  /// للطيار: الطلبات اللي معاه، والفلوس اللي حصّلها ولسه ماورّدهاش.
  final int myOpenDeliveries;
  final int myCashCents;
}
