// STAND-IN: deleted when CX2 merges (the lead swaps these two for wallet_core's `DaySpend` / `periodDaySpend`; same signature).
import 'package:wallet_core/wallet_core.dart';

/// One day's net flexible spending: + = spent, − = a net refund.
class DaySpend {
  const DaySpend(this.date, this.spent);
  final String date;
  final int spent;
}

/// One entry per day of [start, end) (end excluded, like `PeriodReport.end`) with the flexible spending of that day, in the wallet
/// currency. Refunds lower a day, so it can be negative.
List<DaySpend> periodDaySpend(List<CategorizedTx> txs, WalletSettings st, String start, String end, {required CategoryTable table}) {
  final byDay = <String, int>{};
  for (final t in txs) {
    if (!t.tx.live || t.tx.currency != st.currency || t.kind != BudgetKind.flex) continue;
    byDay[t.date] = (byDay[t.date] ?? 0) - t.amount;
  }
  return [
    for (var d = start; d.compareTo(end) < 0; d = addDays(d, 1)) DaySpend(d, byDay[d] ?? 0),
  ];
}
