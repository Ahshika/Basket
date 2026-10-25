import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/pos_models.dart';
import '../../core/pos_types.dart';

class CartState {
  const CartState({this.lines = const [], this.customer, this.discountCents = 0, this.note});

  final List<CartLine> lines;
  final Customer? customer;
  final int discountCents;
  final String? note;

  int get subtotalCents => lines.fold(0, (s, l) => s + l.totalCents);
  int get totalCents => (subtotalCents - discountCents).clamp(0, 1 << 50);

  /// عدد السطور (الصنف بالكيلو سطر واحد مهما كان وزنه).
  int get itemsCount => lines.fold(0, (s, l) => s + (l.product.byWeight ? 1 : l.qtyMilli ~/ milli));
  bool get isEmpty => lines.isEmpty;

  CartState copyWith({List<CartLine>? lines, Customer? customer, bool clearCustomer = false, int? discountCents, String? note}) => CartState(
        lines: lines ?? this.lines,
        customer: clearCustomer ? null : customer ?? this.customer,
        discountCents: discountCents ?? this.discountCents,
        note: note ?? this.note,
      );

  /// شكل الأصناف اللي بيتبعت للسيرفر (للبيع ولطلبات التوصيل).
  List<Map<String, Object?>> get itemsJson => [
        for (final l in lines)
          l.fromScale
              ? {'productId': l.product.id, 'scaleBarcode': l.scaleBarcode}
              : {'productId': l.product.id, 'qtyMilli': l.qtyMilli, 'unitPriceCents': l.unitPriceCents},
      ];
}

/// السلة بتفضل موجودة لو الكاشير راح شاشة تانية ورجع.
final cartProvider = NotifierProvider<CartController, CartState>(CartController.new);

class CartController extends Notifier<CartState> {
  @override
  CartState build() => const CartState();

  /// [qtyMilli] بالألف. باركود الميزان سطر لوحده دايماً (كل كيس ليه وزنه).
  void add(Product p, {int qtyMilli = milli, String? scaleBarcode, int? fixedTotalCents}) {
    final lines = [...state.lines];
    if (scaleBarcode != null) {
      if (lines.any((l) => l.scaleBarcode == scaleBarcode)) return;
      state = state.copyWith(lines: [...lines, CartLine(p, qtyMilli: qtyMilli, scaleBarcode: scaleBarcode, fixedTotalCents: fixedTotalCents)]);
      return;
    }
    final i = lines.indexWhere((l) => l.product.id == p.id && !l.fromScale);
    if (i >= 0) {
      lines[i].qtyMilli += qtyMilli;
    } else {
      lines.add(CartLine(p, qtyMilli: qtyMilli));
    }
    state = state.copyWith(lines: lines);
  }

  void setQty(CartLine line, int qtyMilli) {
    if (qtyMilli <= 0) return remove(line);
    if (line.fromScale) return;
    line.qtyMilli = qtyMilli;
    state = state.copyWith(lines: [...state.lines]);
  }

  void setPrice(CartLine line, int cents) {
    if (line.fromScale) return;
    line.unitPriceCents = cents;
    state = state.copyWith(lines: [...state.lines]);
  }

  void remove(CartLine line) => state = state.copyWith(lines: state.lines.where((l) => l != line).toList());

  void setCustomer(Customer? c) => state = c == null ? state.copyWith(clearCustomer: true) : state.copyWith(customer: c);

  void setDiscount(int cents) => state = state.copyWith(discountCents: cents);

  void clear() => state = const CartState();
}
