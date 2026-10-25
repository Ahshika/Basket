part of 'api_server.dart';

/// تقارير صاحب المحل: المبيعات، والكاشيرية، والتوصيل، والهالك، والمصروفات، والمخزون، والديون.
extension _ReportRoutes on BasketServer {
  void _registerReportRoutes(Router r) {
    r.get('/api/reports/summary', _authed(_reportSummary, only: {'owner'}));
    r.get('/api/reports/expiry', _authed(_expiryReport, only: {'owner', 'supervisor'}));
  }

  Object? _reportSummary(Request req, AuthUser u) {
    final qp = req.url.queryParameters;
    final from = _validDate(qp['from']) ?? _localDayStartUtc();
    final to = _validDate(qp['to']) ?? _localDayStartUtc(1);
    return {'from': from, 'to': to, ...buildReport(from, to)};
  }

  /// الهالك في فترة: الحركات اللي سببها "منتهي الصلاحية" أو "تالف"، بقيمتها بسعر الشرا.
  ({int totalCents, List<Map<String, Object?>> items}) _waste(String from, String to) {
    final rows = db.select(
      'SELECT p.name, p.unit, m.reason, -SUM(m.qty_change_milli) AS qty, -SUM(m.qty_change_milli * m.cost_cents) / 1000 AS value '
      "FROM stock_moves m JOIN products p ON p.id = m.product_id WHERE m.reason IN ('expired', 'damaged') AND m.created_at >= ? AND m.created_at < ? "
      'GROUP BY m.product_id, m.reason ORDER BY value DESC',
      [from, to],
    );
    return (
      totalCents: rows.fold<int>(0, (s, r) => s + ((r['value'] as int?) ?? 0)),
      items: rows.map((r) => {'name': r['name'], 'unit': r['unit'], 'reason': r['reason'], 'qtyMilli': r['qty'], 'valueCents': r['value']}).toList(),
    );
  }

  /// تقرير الصلاحية: اللي قرب يخلص، واللي خلص ولسه على الرف، والهالك في الفترة.
  Object? _expiryReport(Request req, AuthUser u) {
    final qp = req.url.queryParameters;
    final from = _validDate(qp['from']) ?? DateTime.now().toUtc().subtract(const Duration(days: 30)).toIso8601String();
    final to = _validDate(qp['to']) ?? _localDayStartUtc(1);
    final days = int.tryParse(qp['days'] ?? '') ?? _expiryAlertDays;
    final today = _localToday();
    final open = db.select(
      '${_StockRoutes._batchSelect} WHERE p.active = 1 AND b.qty_milli > 0 AND b.expires_on IS NOT NULL AND b.expires_on <= ? ORDER BY b.expires_on, p.name',
      [_localToday(days)],
    );
    final batches = open.map((b) => _batchJson(b, showCost: true)).toList();
    final expired = batches.where((b) => (b['expiresOn'] as String).compareTo(today) < 0).toList();
    final expiring = batches.where((b) => (b['expiresOn'] as String).compareTo(today) >= 0).toList();
    int value(List<Map<String, Object?>> l) => l.fold<int>(0, (s, b) => s + (b['valueCents'] as int));
    final waste = _waste(from, to);
    return {
      'from': from,
      'to': to,
      'days': days,
      'expired': expired,
      'expiredValueCents': value(expired),
      'expiring': expiring,
      'expiringValueCents': value(expiring),
      'waste': waste.items,
      'wasteValueCents': waste.totalCents,
    };
  }

  /// بيحسب التقرير لفترة (UTC ISO). بيستخدمه كمان ملخص الفروع.
  Map<String, Object?> buildReport(String from, String to) {
    int sum(String sql, [List<Object?> params = const []]) => (db.selectOne(sql, params)!.values.first as int?) ?? 0;
    final range = [from, to];

    // ---------------- المبيعات (بما فيها فواتير التوصيل)
    final salesRow = db.selectOne(
      'SELECT COUNT(*) AS c, COALESCE(SUM(total_cents - returned_cents), 0) AS revenue, COALESCE(SUM(discount_cents), 0) AS discount, '
      'COALESCE(SUM(returned_cents), 0) AS returned FROM sales WHERE created_at >= ? AND created_at < ?',
      range,
    )!;
    final salesCost = sum(
      'SELECT COALESCE(SUM(i.cost_cents * (i.qty_milli - i.returned_milli) / 1000), 0) FROM sale_items i JOIN sales s ON s.id = i.sale_id '
      'WHERE s.created_at >= ? AND s.created_at < ?',
      range,
    );
    final salesRevenue = salesRow['revenue'] as int;
    final topProducts = db.select(
      'SELECT i.name, i.unit, SUM(i.qty_milli - i.returned_milli) AS qty, SUM(i.total_cents - i.returned_cents) AS revenue, '
      'SUM(i.total_cents - i.returned_cents - i.cost_cents * (i.qty_milli - i.returned_milli) / 1000) AS profit '
      'FROM sale_items i JOIN sales s ON s.id = i.sale_id '
      'WHERE s.created_at >= ? AND s.created_at < ? AND i.product_id IS NOT NULL GROUP BY i.product_id, i.name HAVING qty > 0 ORDER BY revenue DESC LIMIT 15',
      range,
    );
    final byCashier = db.select(
      'SELECT u.name, COUNT(*) AS count, SUM(s.total_cents - s.returned_cents) AS revenue FROM sales s LEFT JOIN users u ON u.id = s.user_id '
      'WHERE s.created_at >= ? AND s.created_at < ? AND s.session_id IS NOT NULL GROUP BY s.user_id ORDER BY revenue DESC',
      range,
    );
    final byCategory = db.select(
      "SELECT COALESCE(p.category, 'من غير قسم') AS name, SUM(i.total_cents - i.returned_cents) AS revenue FROM sale_items i "
      'JOIN sales s ON s.id = i.sale_id JOIN products p ON p.id = i.product_id WHERE s.created_at >= ? AND s.created_at < ? '
      'GROUP BY p.category ORDER BY revenue DESC LIMIT 20',
      range,
    );

    // ---------------- التوصيل
    final deliveryRow = db.selectOne(
      'SELECT COUNT(*) AS c, COALESCE(SUM(total_cents), 0) AS total, COALESCE(SUM(delivery_fee_cents), 0) AS fees '
      "FROM delivery_orders WHERE status = 'delivered' AND delivered_at >= ? AND delivered_at < ?",
      range,
    )!;
    final cancelled = sum("SELECT COUNT(*) FROM delivery_orders WHERE status = 'cancelled' AND cancelled_at >= ? AND cancelled_at < ?", range);
    final byDriver = db.select(
      "SELECT d.name, COUNT(*) AS count, SUM(o.total_cents) AS total FROM delivery_orders o JOIN drivers d ON d.id = o.driver_id "
      "WHERE o.status = 'delivered' AND o.delivered_at >= ? AND o.delivered_at < ? GROUP BY o.driver_id ORDER BY count DESC",
      range,
    );
    final driverShortage = sum('SELECT COALESCE(SUM(counted_cents - expected_cents), 0) FROM driver_settlements WHERE created_at >= ? AND created_at < ?', range);

    // ---------------- الهالك
    final waste = _waste(from, to);

    // ---------------- المصروفات
    final expenses = -sum("SELECT COALESCE(SUM(amount_cents), 0) FROM cash_moves WHERE type = 'expense' AND created_at >= ? AND created_at < ?", range);
    final expensesByCategory = db.select(
      "SELECT COALESCE(category, note, 'أخرى') AS name, -SUM(amount_cents) AS total FROM cash_moves WHERE type = 'expense' AND created_at >= ? AND created_at < ? "
      'GROUP BY COALESCE(category, note) ORDER BY total DESC',
      range,
    );
    final cashDiff = sum(
      'SELECT COALESCE(SUM(counted_cash_cents - expected_cash_cents), 0) FROM register_sessions WHERE closed_at >= ? AND closed_at < ? AND counted_cash_cents IS NOT NULL',
      range,
    );

    // ---------------- يوم بيوم (للرسم)
    final daily = <String, Map<String, int>>{};
    void addDaily(String sql, String key) {
      for (final r in db.select(sql, range)) {
        daily.putIfAbsent(r['d'] as String, () => {'sales': 0, 'expenses': 0, 'waste': 0})[key] = (r['v'] as int?) ?? 0;
      }
    }

    addDaily("SELECT date(created_at, 'localtime') AS d, SUM(total_cents - returned_cents) AS v FROM sales WHERE created_at >= ? AND created_at < ? GROUP BY d", 'sales');
    addDaily("SELECT date(created_at, 'localtime') AS d, -SUM(amount_cents) AS v FROM cash_moves WHERE type = 'expense' AND created_at >= ? AND created_at < ? GROUP BY d", 'expenses');
    addDaily(
      "SELECT date(created_at, 'localtime') AS d, -SUM(qty_change_milli * cost_cents) / 1000 AS v FROM stock_moves "
      "WHERE reason IN ('expired', 'damaged') AND created_at >= ? AND created_at < ? GROUP BY d",
      'waste',
    );

    // ---------------- المخزون والديون (دلوقتي، مش حسب الفترة)
    final stockValue = sum('SELECT COALESCE(SUM(qty_milli * cost_cents / 1000), 0) FROM products WHERE active = 1 AND track_stock = 1 AND qty_milli > 0');
    final since = DateTime.now().toUtc().subtract(const Duration(days: 60)).toIso8601String();
    final deadStock = db.select(
      'SELECT p.name, p.unit, p.qty_milli AS qty, p.qty_milli * p.cost_cents / 1000 AS value FROM products p WHERE p.active = 1 AND p.track_stock = 1 AND p.qty_milli > 0 '
      'AND NOT EXISTS (SELECT 1 FROM sale_items i JOIN sales s ON s.id = i.sale_id WHERE i.product_id = p.id AND s.created_at >= ?) '
      'AND p.created_at < ? ORDER BY value DESC LIMIT 20',
      [since, since],
    );
    final lowStock = db.select(
      'SELECT name, unit, qty_milli AS qty, low_stock_milli AS low FROM products WHERE active = 1 AND track_stock = 1 AND qty_milli <= low_stock_milli ORDER BY qty_milli LIMIT 30',
    );
    final expiringValue = sum(
      'SELECT COALESCE(SUM(b.qty_milli * b.cost_cents / 1000), 0) FROM batches b JOIN products p ON p.id = b.product_id '
      'WHERE p.active = 1 AND b.qty_milli > 0 AND b.expires_on IS NOT NULL AND b.expires_on <= ?',
      [_localToday(_expiryAlertDays)],
    );
    final debtors = <Map<String, Object?>>[];
    for (final c in db.select('SELECT id, name, phone FROM customers')) {
      final b = _customerBalance(c['id'] as String);
      if (b > 0) debtors.add({'name': c['name'], 'phone': c['phone'], 'balanceCents': b});
    }
    debtors.sort((a, b) => (b['balanceCents'] as int).compareTo(a['balanceCents'] as int));
    final suppliers = <Map<String, Object?>>[];
    for (final s in db.select('SELECT id, name FROM suppliers WHERE active = 1')) {
      final b = _supplierBalance(s['id'] as String);
      if (b > 0) suppliers.add({'name': s['name'], 'balanceCents': b});
    }
    final driversCash = sum("SELECT COALESCE(SUM(collected_cents), 0) FROM delivery_orders WHERE status = 'delivered' AND settlement_id IS NULL");

    final salesProfit = salesRevenue - salesCost;
    return {
      'sales': {
        'count': salesRow['c'],
        'revenueCents': salesRevenue,
        'costCents': salesCost,
        'profitCents': salesProfit,
        'discountCents': salesRow['discount'],
        'returnsCents': salesRow['returned'],
        'topProducts': topProducts,
        'byCashier': byCashier,
        'byCategory': byCategory,
      },
      'delivery': {
        'delivered': deliveryRow['c'],
        'totalCents': deliveryRow['total'],
        'feesCents': deliveryRow['fees'],
        'cancelled': cancelled,
        'byDriver': byDriver,
        'shortageCents': driverShortage,
        'withDriversCents': driversCash,
      },
      'waste': {'totalCents': waste.totalCents, 'items': waste.items},
      'expenses': {'totalCents': expenses, 'byCategory': expensesByCategory},
      'cashDifferenceCents': cashDiff,
      'netProfitCents': salesProfit - expenses - waste.totalCents,
      'daily': (daily.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => {'date': e.key, ...e.value}).toList(),
      'stock': {'valueCents': stockValue, 'deadStock': deadStock, 'lowStock': lowStock, 'expiringValueCents': expiringValue},
      'receivables': {'totalCents': debtors.fold<int>(0, (s, d) => s + (d['balanceCents'] as int)), 'customers': debtors.take(30).toList()},
      'payables': {'totalCents': suppliers.fold<int>(0, (s, d) => s + (d['balanceCents'] as int)), 'suppliers': suppliers},
    };
  }
}
