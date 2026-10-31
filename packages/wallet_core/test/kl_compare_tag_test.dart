// RX8: `compareTag` is `compareCategory` for an extra tag: this month, last month and the mean of the 6 months before
// (always ÷ 6), summed with `rowsForTag`'s rule (every live row in the wallet currency carrying the tag counts as
// spending; tags overlap). Synthetic data only.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

CategorizedTx row(String date, int cents, List<String> tags,
    {String category = 'Shopping', String currency = 'EUR', bool deleted = false}) {
  final tx = Tx(id: 'syn-${_seq++}', source: 'pbz', date: date, amount: cents, currency: currency, description: 'Synth', deleted: deleted);
  return CategorizedTx(tx, category, kindOf(category), tags: tags);
}

/// −Σ of [rowsForTag] over calendar month [m] (`YYYY-MM`).
int viaRows(String tag, List<CategorizedTx> txs, String m) {
  final r = DateRange(start: '$m-01', end: monthEnd(m));
  return -rowsForTag(tag, txs, r, currency: 'EUR').fold<int>(0, (s, t) => s + t.amount);
}

String monthEnd(String m) {
  final y = int.parse(m.substring(0, 4)), mo = int.parse(m.substring(5));
  final d = DateTime.utc(y, mo + 1, 0).day;
  return '$m-${d.toString().padLeft(2, '0')}';
}

void main() {
  const tag = 't000000000001', other = 't000000000002';
  final whole = row('2026-06-12', -9000, const [], category: 'Groceries');
  final txs = [
    row('2026-06-03', -2500, const [tag]),
    row('2026-06-05', -1000, const [tag, other]), // overlaps: counts for both tags
    row('2026-06-07', 400, const [tag]), // a refund is subtracted
    row('2026-06-08', -7000, const [tag], currency: 'USD'), // foreign currency: never counts
    row('2026-06-09', -6000, const [tag], deleted: true), // deleted: never counts
    row('2026-06-10', -3000, const [other]),
    // A split part carrying the tag counts its own amount; the other part (no tag) does not.
    CategorizedTx(whole.tx, 'Groceries', BudgetKind.flex, tags: const [tag], amount: -3000, part: 0, parts: 2),
    CategorizedTx(whole.tx, 'Shopping', BudgetKind.flex, amount: -6000, part: 1, parts: 2),
    row('2026-06-11', -1500, const [tag], category: 'Salary'), // income kind: not spending
    row('2026-05-20', -1200, const [tag]),
    for (final m in ['2025-12', '2026-01', '2026-02', '2026-03', '2026-04', '2026-05']) row('$m-15', -1001, const [tag]),
    row('2025-11-15', -99999, const [tag]), // the 7th month before: outside the average
    row('2026-07-01', -55555, const [tag]), // after the month
  ];

  test('thisMonth and lastMonth equal the rowsForTag sums', () {
    final c = compareTag(tag, txs, '2026-06', today: '2026-06-20', currency: 'EUR');
    expect(c.thisMonth, viaRows(tag, txs, '2026-06'));
    expect(c.thisMonth, 2500 + 1000 - 400 + 3000);
    expect(c.lastMonth, viaRows(tag, txs, '2026-05'));
    expect(c.lastMonth, 1200 + 1001);
  });

  test('average6 = the 6 months before, ÷ 6 always, rounded like compareCategory', () {
    final c = compareTag(tag, txs, '2026-06', today: '2026-06-20', currency: 'EUR');
    final months = ['2025-12', '2026-01', '2026-02', '2026-03', '2026-04', '2026-05'];
    final sum = months.fold<int>(0, (s, m) => s + viaRows(tag, txs, m));
    expect(sum, 6 * 1001 + 1200);
    expect(c.average6, (sum / 6).round());
    final cat = compareCategory('Shopping', [for (final m in months) row('$m-15', -1001, const [])], '2026-06', currency: 'EUR');
    expect(
        compareTag(
                tag,
                [
                  for (final m in months) row('$m-15', -1001, const [tag])
                ],
                '2026-06',
                today: '2026-06-20',
                currency: 'EUR')
            .average6,
        cat.average6,
        reason: 'the same rounding as compareCategory');
  });

  test('tags overlap: the other tag counts the shared row too', () {
    final c = compareTag(other, txs, '2026-06', today: '2026-06-20', currency: 'EUR');
    expect(c.thisMonth, 1000 + 3000);
    expect(c.thisMonth, viaRows(other, txs, '2026-06'));
  });

  test('an unknown tag or no rows: zeros', () {
    final c = compareTag('t00000000000f', txs, '2026-06', today: '2026-06-20', currency: 'EUR');
    expect((c.thisMonth, c.lastMonth, c.average6), (0, 0, 0));
    final e = compareTag(tag, const [], '2026-06', today: '2026-06-20', currency: 'EUR');
    expect((e.thisMonth, e.lastMonth, e.average6), (0, 0, 0));
  });

  test('the home currency decides: in USD only the USD row counts', () {
    final c = compareTag(tag, txs, '2026-06', today: '2026-06-20', currency: 'USD');
    expect(c.thisMonth, 7000);
  });
}
