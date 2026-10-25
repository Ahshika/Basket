/// أنواع مشتركة بين السيرفر والبرنامج. الملف ده من غير Flutter عشان الاتنين يستخدموه.
library;

enum PaymentMethod {
  cash('كاش'),
  vodafoneCash('فودافون كاش'),
  instapay('إنستاباي'),
  card('فيزا'),
  other('أخرى');

  const PaymentMethod(this.label);
  final String label;

  static PaymentMethod parse(String? v) => values.firstWhere((m) => m.name == v, orElse: () => cash);
}

/// الصنف بيتباع بالقطعة أو بالكيلو (بالميزان).
enum SaleUnit {
  piece('قطعة'),
  kg('كيلو');

  const SaleUnit(this.label);
  final String label;

  static SaleUnit parse(String? v) => v == 'kg' ? kg : piece;
}

/// الكميات بتتخزن بالألف: القطعة = 1000، والكيلو = 1000 جرام.
const milli = 1000;

/// إجمالي السطر = السعر (لكل قطعة أو كيلو) × الكمية، مقرّب لأقرب قرش.
int lineTotal(int unitPriceCents, int qtyMilli) => (unitPriceCents * qtyMilli / milli).round();

/// "3" للقطع، و"1.250" للكيلو. الأصفار اللي في الآخر بتتشال ("1.5").
String formatQty(int qtyMilli, SaleUnit unit) {
  if (unit == SaleUnit.piece && qtyMilli % milli == 0) return '${qtyMilli ~/ milli}';
  final negative = qtyMilli < 0;
  final v = qtyMilli.abs();
  var frac = (v % milli).toString().padLeft(3, '0').replaceAll(RegExp(r'0+$'), '');
  final s = frac.isEmpty ? '${v ~/ milli}' : '${v ~/ milli}.$frac';
  return negative ? '-$s' : s;
}

/// "2 قطعة" أو "1.25 كيلو"
String qtyLabel(int qtyMilli, SaleUnit unit) => '${formatQty(qtyMilli, unit)} ${unit.label}';

/// "1.25" أو "١٫٢٥" أو "1,25" ← 1250. بيرجع null لو المكتوب مش رقم.
int? parseQty(String input) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final ch in input.trim().split('')) {
    final i = arabic.indexOf(ch);
    b.write(i >= 0 ? '$i' : (ch == '٫' || ch == ',') ? '.' : ch);
  }
  final v = double.tryParse(b.toString());
  if (v == null || v < 0) return null;
  return (v * milli).round();
}

/// مراحل طلب التوصيل.
enum DeliveryStatus {
  newOrder('new', 'جديد'),
  preparing('preparing', 'بيتجهز'),
  out('out', 'خرج مع الطيار'),
  delivered('delivered', 'اتسلم'),
  cancelled('cancelled', 'اتلغى');

  const DeliveryStatus(this.code, this.label);
  final String code;
  final String label;

  static DeliveryStatus? tryParse(String? v) {
    for (final s in values) {
      if (s.code == v) return s;
    }
    return null;
  }

  static DeliveryStatus parse(String? v) => tryParse(v) ?? newOrder;

  bool get isOpen => this == newOrder || this == preparing || this == out;

  /// الطلب لسه ماخرجش، فممكن أصنافه وعنوانه يتعدلوا.
  bool get editable => this == newOrder || this == preparing;

  /// المرحلة اللي بعدها (لزرار "المرحلة التالية").
  DeliveryStatus? get next => switch (this) {
        newOrder => preparing,
        preparing => out,
        out => delivered,
        _ => null,
      };
}

const deliveryChannels = {'phone': 'تليفون', 'whatsapp': 'واتساب', 'other': 'أخرى'};

/// بيوحّد شكل رقم التليفون عشان البحث: أرقام إنجليزي بس، ومن غير كود مصر.
String normalizePhone(String input) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  final b = StringBuffer();
  for (final ch in input.split('')) {
    final a = arabic.indexOf(ch);
    final p = persian.indexOf(ch);
    if (a >= 0) {
      b.write(a);
    } else if (p >= 0) {
      b.write(p);
    } else if (RegExp(r'[0-9]').hasMatch(ch)) {
      b.write(ch);
    }
  }
  var digits = b.toString();
  if (digits.startsWith('0020')) digits = '0${digits.substring(4)}';
  if (digits.startsWith('20') && digits.length == 12) digits = '0${digits.substring(2)}';
  return digits;
}

// ---------------------------------------------------------------- باركود الميزان

/// شكل الباركود اللي الميزان بيطبعه (EAN-13 بيبدأ بـ 2):
///   [البادئة: رقمين] [PLU: رقم الصنف على الميزان] [... أرقام بيتجاهلها] [القيمة] [رقم التحقق]
/// القيمة إما الوزن بالجرام، أو السعر بالقرش، حسب إعداد الميزان.
class ScaleFormat {
  const ScaleFormat({
    this.enabled = true,
    this.prefixes = const ['21', '22', '23', '24', '25', '26', '27', '28', '29'],
    this.pluLength = 5,
    this.valueLength = 5,
    this.mode = 'weight',
  });

  factory ScaleFormat.fromJson(Map<String, Object?> j) => ScaleFormat(
        enabled: j['enabled'] != false,
        prefixes: (j['prefixes'] as List? ?? const []).whereType<String>().toList(),
        pluLength: j['pluLength'] as int? ?? 5,
        valueLength: j['valueLength'] as int? ?? 5,
        mode: j['mode'] == 'price' ? 'price' : 'weight',
      );

  final bool enabled;

  /// أول رقمين في الباركود. 20 مش في الافتراضي لأنه بادئة الباركود الداخلي اللي البرنامج بيعمله.
  final List<String> prefixes;
  final int pluLength;
  final int valueLength;

  /// 'weight' (القيمة جرامات) أو 'price' (القيمة قروش).
  final String mode;

  Map<String, Object?> toJson() => {'enabled': enabled, 'prefixes': prefixes, 'pluLength': pluLength, 'valueLength': valueLength, 'mode': mode};

  /// null لو الإعداد سليم، أو رسالة الغلط.
  String? validate() {
    if (prefixes.isEmpty) return 'اكتب بادئة واحدة على الأقل';
    if (prefixes.any((p) => !RegExp(r'^2\d$').hasMatch(p))) return 'البادئة لازم تكون رقمين وتبدأ بـ 2 (زي 21 أو 28)';
    if (pluLength < 3 || pluLength > 6) return 'طول رقم الصنف لازم يكون من 3 لـ 6 أرقام';
    if (valueLength < 4 || valueLength > 6) return 'طول الوزن أو السعر لازم يكون من 4 لـ 6 أرقام';
    if (pluLength + valueLength > 10) return 'رقم الصنف والقيمة مع بعض أطول من الباركود';
    return null;
  }
}

class ScaleRead {
  const ScaleRead({required this.plu, this.grams, this.priceCents});
  final int plu;

  /// الوزن بالجرام (= qty_milli للأصناف بالكيلو).
  final int? grams;

  /// السعر المطبوع بالقرش (لو الميزان بيطبع السعر مش الوزن).
  final int? priceCents;
}

bool ean13Valid(String code) {
  if (!RegExp(r'^\d{13}$').hasMatch(code)) return false;
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    sum += int.parse(code[i]) * (i.isEven ? 1 : 3);
  }
  return int.parse(code[12]) == (10 - sum % 10) % 10;
}

/// بيقرا باركود الميزان. null لو الكود مش باركود ميزان بالشكل ده.
ScaleRead? parseScaleBarcode(String code, ScaleFormat f) {
  if (!f.enabled || !ean13Valid(code) || !f.prefixes.contains(code.substring(0, 2))) return null;
  final plu = int.parse(code.substring(2, 2 + f.pluLength));
  final value = int.parse(code.substring(12 - f.valueLength, 12));
  if (value <= 0) return null;
  return f.mode == 'price' ? ScaleRead(plu: plu, priceCents: value) : ScaleRead(plu: plu, grams: value);
}

/// باركود ميزان كامل بالشكل ده (للاختبارات وطباعة الملصقات).
String buildScaleBarcode(ScaleFormat f, String prefix, int plu, int value) {
  final middle = 10 - f.pluLength - f.valueLength;
  final body = '$prefix${'$plu'.padLeft(f.pluLength, '0')}${'0' * middle}${'$value'.padLeft(f.valueLength, '0')}';
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    sum += int.parse(body[i]) * (i.isEven ? 1 : 3);
  }
  return '$body${(10 - sum % 10) % 10}';
}
