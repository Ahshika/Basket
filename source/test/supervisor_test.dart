import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  final shop = TestShop();

  setUp(() => shop.start('supervisor'));
  tearDown(() => shop.stop());

  test('supervisor: counts stock and sees every drawer, but no reports, users or withdrawals', () async {
    final sup = await shop.staff('mona', 'supervisor');
    final cashier = await shop.staff('sara', 'cashier');
    final product = await shop.product('شاي العروسة', qtyMilli: 10000);

    await expectApiError(cashier.post('/api/products/${product['id']}/adjust', {'setQtyMilli': 8000, 'reason': 'count'}), 403);
    await sup.post('/api/products/${product['id']}/adjust', {'setQtyMilli': 8000, 'reason': 'count'});
    expect(await shop.qtyOf(product['id'] as String), 8000);

    await sup.get('/api/cash/sessions');
    await sup.get('/api/cash/drawers');
    await sup.get('/api/reports/expiry');
    await expectApiError(cashier.get('/api/cash/sessions'), 403);
    await expectApiError(cashier.get('/api/reports/expiry'), 403);
    await expectApiError(sup.post('/api/cash/moves', {'type': 'withdraw', 'amountCents': 100, 'method': 'cash'}), 403);
    await expectApiError(sup.get('/api/reports/summary'), 403);
    await expectApiError(sup.get('/api/users'), 403);
    await expectApiError(sup.patch('/api/shop', {'name': 'x'}), 403);
  });

  test('a fresh database is at the first migration and every role can be created', () async {
    for (final role in ['supervisor', 'cashier', 'driver']) {
      final c = await shop.staff('user_$role', role);
      expect((await c.get('/api/auth/me'))['user']['role'], role);
    }
    await expectApiError(shop.owner.post('/api/users', {'name': 'x', 'username': 'tech', 'password': 'tech1234', 'role': 'technician'}), 400);
    expect(shop.server.db.raw.userVersion, 1);
  });
}
