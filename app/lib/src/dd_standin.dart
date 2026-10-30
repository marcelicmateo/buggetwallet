// DD stand-in: delete when wallet_core exports periodDays
import 'package:wallet_core/wallet_core.dart';

/// What one day of the pay period looked like (DD_SPEC). Same names as the core API.
enum DayMark { within, over, today, toCome }

class PeriodDay {
  final String date;
  final DayMark mark;
  final int spent, allowance; // cents; 0/0 for today and to come
  const PeriodDay(this.date, this.mark, this.spent, this.allowance);
}

/// One entry per day of the period, ascending. Stand-in: one `computePeriod` per past day.
List<PeriodDay> periodDays(List<CategorizedTx> txs, WalletSettings st, List<Goal> goals, String today,
    {List<RecurringBill> bills = const [],
    List<PlannedCost> planned = const [],
    required CategoryTable table,
    List<CategorizedTx>? matchRows}) {
  PeriodBudget at(String d) => computePeriod(txs, st, goals, d, bills: bills, planned: planned, table: table, matchRows: matchRows);
  final p = at(today);
  final out = <PeriodDay>[];
  for (var d = p.start; d.compareTo(p.end) < 0; d = addDays(d, 1)) {
    if (!p.paydayPassed && d == today) {
      out.add(PeriodDay(d, DayMark.today, 0, 0));
    } else if (!p.paydayPassed && d.compareTo(today) > 0) {
      out.add(PeriodDay(d, DayMark.toCome, 0, 0));
    } else {
      final q = at(d);
      out.add(PeriodDay(d, q.spentToday > q.allowanceToday ? DayMark.over : DayMark.within, q.spentToday, q.allowanceToday));
    }
  }
  return out;
}
