import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pos_types.dart';
import 'providers.dart';
import 'realtime.dart';

class ShopProfile {
  ShopProfile(Map<String, dynamic> j)
      : name = j['name'] as String? ?? '',
        phone = j['phone'] as String?,
        address = j['address'] as String?,
        branchName = j['branchName'] as String?,
        logo = j['logoBase64'] == null ? null : base64.decode(j['logoBase64'] as String),
        receiptTerms = j['receiptTerms'] as String? ?? '',
        receiptPaper = j['receiptPaper'] as String? ?? '80mm',
        cashierCanDiscount = j['cashierCanDiscount'] as bool? ?? true,
        allowNegativeStock = j['allowNegativeStock'] as bool? ?? true,
        scaleFormat = j['scaleFormat'] is Map ? ScaleFormat.fromJson((j['scaleFormat'] as Map).cast<String, Object?>()) : const ScaleFormat(),
        expiryAlertDays = j['expiryAlertDays'] as int? ?? 30,
        deliveryFeeCents = j['deliveryFeeCents'] as int? ?? 0;

  final String name;
  final String? phone;
  final String? address;
  final String? branchName;
  final Uint8List? logo;
  final String receiptTerms;
  final String receiptPaper;
  final bool cashierCanDiscount;
  final bool allowNegativeStock;

  /// شكل باركود الميزان.
  final ScaleFormat scaleFormat;

  /// تنبيه "صلاحيته قربت تخلص" قبل كام يوم.
  final int expiryAlertDays;

  /// رسوم التوصيل الافتراضية لطلبات التليفون.
  final int deliveryFeeCents;
}

final shopProvider = FutureProvider.autoDispose<ShopProfile>((ref) async {
  refreshOn(ref, 'shop');
  ref.keepAlive();
  return ShopProfile(await apiOf(ref).get('/api/shop'));
});
