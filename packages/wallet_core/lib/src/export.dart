/// CSV exports. Pure: the caller saves the text. UTF-8 without BOM, LF line ends, RFC 4180 quoting; amounts as
/// exact decimals from the cents (never through a double).
library;

import 'categories.dart';
import 'dates.dart';
import 'models.dart';
import 'tags.dart' show TagTable;

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

/// Header of [transactionsCsv] with its `tags` argument (T1): a `tags` column after `category`.
const transactionsCsvTagsHeader = 'date,amount,category,tags,description,source,note';

/// The live rows of [txs] (deleted ones and hand-added entries replaced by a bank row are left out), one record each,
/// sorted by date then id: `date,amount,category,description,source,note`. `amount` is the stored signed amount
/// (outflows negative) as an exact decimal, `category` the resolved one (its label in [table] when given, so a
/// custom category reads as its name; built-ins keep their names unless relabelled), `note` empty when there is none.
/// With [tags], a `tags` column follows `category` ([transactionsCsvTagsHeader]): the labels of the row's extra tags
/// ([CategorizedTx.tags], in their order) joined with `; `, empty when it has none. `category` stays the main tag.
///
/// P6: [txs] is the expanded list (`Categorizer.expand`). A split payment gives one record per part, in part order:
/// the part's amount, main tag and tags, the payment's description with ` #<n>` (n from 1; the CSV has no id column),
/// and the part's note (the payment's when the part has none). An unsplit payment is one record as before.
String transactionsCsv(List<CategorizedTx> txs, {CategoryTable? table, TagTable? tags}) {
  final rows = [
    for (final t in txs)
      if (t.tx.live) t
  ]..sort((a, b) {
      var c = a.date.compareTo(b.date);
      if (c == 0) c = a.tx.id.compareTo(b.tx.id);
      return c != 0 ? c : comparePart(a, b);
    });
  final sb = StringBuffer('${tags == null ? transactionsCsvHeader : transactionsCsvTagsHeader}\n');
  for (final t in rows) {
    final c = table == null ? t.category : table.label(t.category);
    sb.write(_record([
      t.date,
      centsToDecimal(t.amount),
      c,
      if (tags != null) t.tags.map(tags.label).join('; '),
      if (t.part case final p?) (t.tx.description.isEmpty ? '#${p + 1}' : '${t.tx.description} #${p + 1}') else t.tx.description,
      t.tx.source,
      t.partNote ?? t.tx.note ?? '',
    ]));
  }
  return sb.toString();
}

/// The column a sync duplicate's rows go into: its original ([CategoryTable.duplicateOf]) when that is a spending
/// category too, else null (the duplicate keeps its own column, so its spending stays in the total).
String? _csvOriginal(CategoryTable t, String c) {
  final d = t.duplicateOf(c);
  return d != null && t.isSpending(d) ? d : null;
}

/// The monthly CSV's columns for [t]: its [CategoryTable.spending] without the sync duplicates that fold into their
/// original's column ([_csvOriginal]), so no spending label appears twice.
List<String> _csvColumns(CategoryTable t) => [
      for (final c in t.spending)
        if (_csvOriginal(t, c) == null) c
    ];

/// Header of [monthlySummaryCsv] over the built-in categories: `month,<each spending category>,total`.
String get monthlySummaryCsvHeader => monthlySummaryCsvHeaderFor(CategoryTable.builtIn);

/// Header of [monthlySummaryCsv] for [t]: `month,<each label of [CategoryTable.spending]>,total` (fields quoted as
/// needed, so a label with a comma stays one column).
String monthlySummaryCsvHeaderFor(CategoryTable t) =>
    ['month', for (final c in _csvColumns(t)) t.label(c), 'total'].map(csvField).join(',');

/// Spending per calendar month and category: `month,<each category in [spendingCategories] order>,total`, one record
/// per month with a live row in a spending category, ascending. A cell is that category's outflow as a positive
/// decimal (refunds, positive rows in the category, reduce it; `0.00` without spending), `total` the sum of the cells.
/// Income, transfers (payments linked to an IOU too), deleted rows and replaced entries are not spending and never appear; neither do rows in another
/// currency than [currency] (`WalletSettings.currency`): the cells are sums in one currency. With [table], the
/// columns are its [CategoryTable.spending] (labels in the header, [monthlySummaryCsvHeaderFor]); a duplicate's rows
/// count in its original's column.
String monthlySummaryCsv(List<CategorizedTx> txs, {required String currency, CategoryTable? table}) {
  final t0 = table ?? CategoryTable.builtIn;
  final cats = _csvColumns(t0);
  final byMonth = <String, Map<String, int>>{};
  for (final t in txs) {
    // The row's own kind too: a payment linked to an IOU (Q8, `Categorizer.iouTx`) keeps a spending main tag but
    // counts as a transfer.
    if (!t.tx.live || t.tx.currency != currency || !t0.isSpending(t.category) || t.kind == BudgetKind.transfer || t.date.length < 7) {
      continue;
    }

    final m = byMonth[monthOf(t.date)] ??= {};
    final top = t0.topLevel(t.category);
    final c = _csvOriginal(t0, top) ?? top; // a sync duplicate counts in its original's column
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
