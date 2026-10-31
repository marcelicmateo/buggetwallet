// STAND-IN: deleted when core compareTag merges (RX8). Same signature and meaning as core's `compareTag`: [tag] in calendar [month]
// against the month before and the 6-month average, summed over the rows that carry the tag (counted like "Where it goes").
import 'package:wallet_core/wallet_core.dart';

CategoryCompare compareTag(String tag, List<CategorizedTx> txs, String month, {required String today, required String currency}) {
  final rows = [
    for (final t in txs)
      if (t.tags.contains(tag)) t
  ];
  return CategoryCompare(
    thisMonth: monthSummary(rows, month, currency: currency).out,
    lastMonth: monthSummary(rows, monthsEnding(month, 2).first, currency: currency).out,
    average6: averageOut(rows, month, currency: currency),
  );
}
