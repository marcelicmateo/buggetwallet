// SHIM for the wallet_core budget API (feature E1). The core-builder's version has the same names and signatures; when
// core is merged, DELETE THIS FILE and every line marked `SHIM` (grep -rn SHIM app/lib): the imports in controller.dart,
// widgets/charts.dart, and the two reads below. Nothing else changes.
import 'dart:convert';

import 'package:wallet_core/wallet_core.dart';

class CategoryBudgetLine {
  final String category;
  final int? budget;
  final int actual;
  final int average6;
  final int? remaining;
  final double? pace;
  final bool over;
  const CategoryBudgetLine({
    required this.category,
    required this.budget,
    required this.actual,
    required this.average6,
    required this.remaining,
    required this.pace,
    required this.over,
  });
}

class BudgetVsActual {
  final String month;
  final List<CategoryBudgetLine> lines;
  final int budgetTotal, actualTotal;
  final int? remainingTotal;
  final int overCount, budgetedCount;
  const BudgetVsActual({
    required this.month,
    required this.lines,
    required this.budgetTotal,
    required this.actualTotal,
    required this.remainingTotal,
    required this.overCount,
    required this.budgetedCount,
  });
}

Map<String, int> _average6(List<CategorizedTx> txs, String month) {
  final prev = monthsEnding(month, 7).where((m) => m != month).toList();
  final sums = [for (final m in prev) monthSummary(txs, m)];
  final avg = <String, int>{};
  for (final s in sums) {
    s.byCategory.forEach((k, v) => avg[k] = (avg[k] ?? 0) + v);
  }
  return {for (final e in avg.entries) e.key: (e.value / sums.length).round()};
}

BudgetVsActual budgetVsActual(List<CategorizedTx> txs, String month, Map<String, int> budgets, {required String today}) {
  final actual = monthSummary(txs, month).byCategory;
  final avg = _average6(txs, month);
  final y = int.parse(month.substring(0, 4)), m = int.parse(month.substring(5, 7));
  final days = DateTime(y, m + 1, 0).day;
  final day = monthOf(today) == month ? int.parse(today.substring(8, 10)) : days;
  final cats = {...budgets.keys, ...actual.keys}.toList()..sort((a, b) => (actual[b] ?? 0).compareTo(actual[a] ?? 0));
  var bt = 0, at = 0, over = 0, n = 0;
  final lines = <CategoryBudgetLine>[];
  for (final k in cats) {
    final b = budgets[k], a = actual[k] ?? 0;
    if (b != null) {
      bt += b;
      at += a;
      n++;
      if (a > b) over++;
    }
    lines.add(CategoryBudgetLine(
      category: k,
      budget: b,
      actual: a,
      average6: avg[k] ?? 0,
      remaining: b == null ? null : b - a,
      pace: b == null || b == 0 ? null : a / (b * day / days),
      over: b != null && a > b,
    ));
  }
  return BudgetVsActual(
      month: month,
      lines: lines,
      budgetTotal: bt,
      actualTotal: at,
      remainingTotal: n == 0 ? null : bt - at,
      overCount: over,
      budgetedCount: n);
}

Map<String, int> suggestBudgets(List<CategorizedTx> txs, String month) => {
      for (final e in _average6(txs, month).entries)
        if (e.value > 0) e.key: (e.value / 1000).ceil() * 1000,
    };

/// The saved budgets (SHIM: read raw from the settings table; the real `WalletSettings.categoryBudgets` replaces this).
Map<String, int> shimBudgets(WalletRepo repo) {
  final rows = repo.db.select("SELECT value FROM settings WHERE id = 'categoryBudgets' AND deleted = 0");
  if (rows.isEmpty) return const {};
  try {
    final m = jsonDecode(rows.first['value'] as String);
    if (m is! Map) return const {};
    return {
      for (final e in m.entries)
        if (e.value is int && (e.value as int) > 0) e.key.toString(): e.value as int,
    };
  } on FormatException {
    return const {};
  }
}
