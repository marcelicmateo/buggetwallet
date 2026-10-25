/// CSV exports. Pure: the caller saves the text. UTF-8 without BOM, LF line ends, RFC 4180 quoting; amounts as
/// exact decimals from the cents (never through a double).
library;

import 'categories.dart';
import 'dates.dart';
import 'models.dart';

/// [cents] as a decimal with a dot and two fractional digits: `-1234.56`, `0.01`, `1000000.00`. Exact for every int;
/// zero is `0.00` (never `-0.00`).
String centsToDecimal(int cents) {
  final abs = cents.abs();
  final whole = abs ~/ 100, frac = abs % 100;
  return '${cents < 0 ? '-' : ''}$whole.${frac.toString().padLeft(2, '0')}';
}

/// [s] as one CSV field: quoted (quotes doubled) when it holds a quote, a comma, a newline or a carriage return.
String csvField(String s) {
  if (!s.contains('"') && !s.contains(',') && !s.contains('\n') && !s.contains('\r')) return s;
  return '"${s.replaceAll('"', '""')}"';
}

String _record(Iterable<String> fields) => '${fields.map(csvField).join(',')}\n';

/// Header of [transactionsCsv].
const transactionsCsvHeader = 'date,amount,category,description,source,note';

/// The live rows of [txs] (deleted ones and hand-added entries replaced by a bank row are left out), one record each,
/// sorted by date then id: `date,amount,category,description,source,note`. `amount` is the stored signed amount
/// (outflows negative) as an exact decimal, `category` the resolved one, `note` empty when there is none.
String transactionsCsv(List<CategorizedTx> txs) {
  final rows = [
    for (final t in txs)
      if (t.tx.live) t
  ]..sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : a.tx.id.compareTo(b.tx.id);
    });
  final sb = StringBuffer('$transactionsCsvHeader\n');
  for (final t in rows) {
    sb.write(_record([t.date, centsToDecimal(t.amount), t.category, t.tx.description, t.tx.source, t.tx.note ?? '']));
  }
  return sb.toString();
}

/// Header of [monthlySummaryCsv] over the built-in categories: `month,<each spending category>,total`.
String get monthlySummaryCsvHeader => monthlySummaryCsvHeaderFor(CategoryTable.builtIn);

/// Header of [monthlySummaryCsv] for [t]: `month,<each label of [CategoryTable.spending]>,total` (fields quoted as
/// needed, so a label with a comma stays one column).
String monthlySummaryCsvHeaderFor(CategoryTable t) => ['month', for (final c in t.spending) t.label(c), 'total'].map(csvField).join(',');

/// Spending per calendar month and category: `month,<each category in [spendingCategories] order>,total`, one record
/// per month with a live row in a spending category, ascending. A cell is that category's outflow as a positive
/// decimal (refunds, positive rows in the category, reduce it; `0.00` without spending), `total` the sum of the cells.
/// Income, transfers, deleted rows and replaced entries are not spending and never appear; neither do rows in another
/// currency than [currency] (`WalletSettings.currency`): the cells are sums in one currency. With [table], the
/// columns are its [CategoryTable.spending] (labels in the header, [monthlySummaryCsvHeaderFor]) and each child's
/// rows count in its parent's column ([rollUp]).
String monthlySummaryCsv(List<CategorizedTx> txs, {required String currency, CategoryTable? table}) {
  final t0 = table ?? CategoryTable.builtIn;
  final cats = t0.spending;
  final byMonth = <String, Map<String, int>>{};
  for (final t in txs) {
    if (!t.tx.live || t.tx.currency != currency || !t0.isSpending(t.category) || t.date.length < 7) continue;

    final m = byMonth[monthOf(t.date)] ??= {};
    final c = t0.topLevel(t.category);
    m[c] = (m[c] ?? 0) - t.amount;
  }
  final months = byMonth.keys.toList()..sort();
  final sb = StringBuffer('${monthlySummaryCsvHeaderFor(t0)}\n');
  for (final month in months) {
    final sums = byMonth[month]!;
    var total = 0;
    final cells = <String>[];
    for (final c in cats) {
      final v = sums[c] ?? 0;
      total += v;
      cells.add(centsToDecimal(v));
    }
    sb.write(_record([month, ...cells, centsToDecimal(total)]));
  }
  return sb.toString();
}
