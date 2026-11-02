// ENG §5.4 / §6.4 project stats. SYNTHETIC rows only (made-up amounts, well-known chains).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n3.dart' show bigWalletRows;
import 'support/t1.dart' show plain, tagged;

const today = '2026-06-30';
final table = CategoryTable.builtIn;
final tagTable = TagTable.from(const [TagRow(id: 'tA', name: 'Trip'), TagRow(id: 'tB', name: 'Car'), TagRow(id: 'tC', name: 'Home')]);
final ctx = TagContext(tags: tagTable);

ProjectStats stats(List<CategorizedTx> rows, {TagContext? tags, String day = today, WalletSettings? st}) =>
    projectStats('tA', rows, tags: tags ?? ctx, table: table, currency: 'EUR', today: day, st: st);

int sum(Iterable<int> xs) => xs.fold(0, (a, b) => a + b);

void main() {
  test('identities on the big wallet: total = Σ byMainTag = Σ byYear = last running = tagShare = rowsForTag', () {
    final big = bigWalletRows(today, days: 2000);
    final rows = [
      for (final t in big)
        if (t.tx.description.contains('LIDL') && t.date.compareTo('2023-01-01') >= 0)
          CategorizedTx(t.tx, t.category, t.kind, tags: const ['tA'])
        else if (t.tx.description.contains('IKEA') && t.date.compareTo('2024-03-01') < 0)
          CategorizedTx(t.tx, 'Shopping', BudgetKind.flex, tags: const ['tA', 'tB'])
        else
          t,
      tagged(plain('ref', '2024-05-02', 2500, 'POS LIDL HRVATSKA ZAGREB'), 'Groceries', ['tA']), // refund
    ];
    stats(rows); // warm up (JIT)
    final sw = Stopwatch()..start();
    final s = stats(rows);
    sw.stop();
    printOnFailure('projectStats on ${rows.length} rows: ${sw.elapsedMilliseconds} ms');
    expect(s.total, greaterThan(0));
    expect(sum(s.byMainTag.map((e) => e.$2)), s.total);
    expect(sum(s.byYear.map((e) => e.$2)), s.total);
    expect(s.running.last.$2, s.total);
    final span = DateRange(start: s.first, end: s.last.compareTo(today) > 0 ? s.last : today);
    final share = tagShare(rows, span, currency: 'EUR');
    expect(share.slices.firstWhere((x) => x.tag == 'tA').spent, s.total);
    expect(share.slices.firstWhere((x) => x.tag == 'tA').count, s.count);
    expect(-sum(rowsForTag('tA', rows, span, currency: 'EUR').map((t) => t.amount)), s.total);
    expect(s.months, s.running.length);
    expect(s.running.first.$1, s.first.substring(0, 7));
    expect(s.running.last.$1, '2026-06');
    expect(s.byYear.map((e) => e.$1), [for (var y = int.parse(s.first.substring(0, 4)); y <= 2026; y++) y]);
    expect(s.ended, isFalse);
    expect(s.overlaps.single.$1, 'tB');
    // Share: total ÷ all spending over the span, rounded once.
    var all = 0;
    for (final t in rows) {
      if (t.date.compareTo(s.first) >= 0 && t.date.compareTo(today) <= 0 && countsAsSpending(t, 'EUR')) all -= t.amount;
    }
    expect(s.sharePermille, ((s.total * 1000) / all).round());
    // regression catcher only, about 5x the warm time under a loaded shared laptop; `make perf` holds the real frame budget.
    expect(sw.elapsedMilliseconds, lessThan(1100)); // about 36 ms here, 213 ms under load
  });

  test('split parts count by their own tags; the payment is never a candidate', () {
    final pay = plain('p1', '2026-03-10', -10000, 'POS IKEA ZAGREB');
    final rows = [
      CategorizedTx(pay, 'Groceries', BudgetKind.flex, tags: const ['tA'], amount: -6000, part: 0, parts: 2),
      CategorizedTx(pay, 'Shopping', BudgetKind.flex, amount: -4000, part: 1, parts: 2),
      tagged(plain('p2', '2026-03-12', -3000, 'POS IKEA ZAGREB'), 'Shopping'),
    ];
    final s = stats(rows);
    expect(s.total, 6000);
    expect(s.count, 1);
    expect(s.byMainTag, [('Groceries', 6000)]);
    expect(s.candidates.map((t) => t.id), ['p2']);
  });

  test('overlap counts: payments shared with other tags, count desc', () {
    final rows = [
      tagged(plain('a', '2026-05-01', -100, 'POS LIDL'), 'Groceries', ['tA', 'tB']),
      tagged(plain('b', '2026-05-02', -100, 'POS LIDL'), 'Groceries', ['tA', 'tB', 'tC']),
      tagged(plain('c', '2026-05-03', -100, 'POS LIDL'), 'Groceries', ['tA']),
      tagged(plain('d', '2026-05-04', -100, 'POS LIDL'), 'Groceries', ['tB', 'tC']), // not the project's
    ];
    expect(stats(rows).overlaps, [('tB', 2), ('tC', 1)]);
  });

  test('candidates: same payee, live home outflows in [first, last + 30]; never transfers, tagged, off or by amount', () {
    final rows = [
      tagged(plain('t1', '2026-01-10', -5000, 'POS DECATHLON ZAGREB'), 'Shopping', ['tA']),
      tagged(plain('t2', '2026-02-10', -5000, 'POS DECATHLON ZAGREB'), 'Shopping', ['tA']),
      tagged(plain('ok', '2026-01-20', -700, 'POS DECATHLON ZAGREB'), 'Shopping'),
      tagged(plain('edge', '2026-03-12', -700, 'POS DECATHLON ZAGREB'), 'Shopping'), // last + 30
      tagged(plain('late', '2026-03-13', -700, 'POS DECATHLON ZAGREB'), 'Shopping'), // last + 31
      tagged(plain('early', '2026-01-09', -700, 'POS DECATHLON ZAGREB'), 'Shopping'),
      tagged(plain('xfer', '2026-01-21', -700, 'POS DECATHLON ZAGREB'), 'Internal transfer'),
      CategorizedTx(plain('iou', '2026-01-22', -700, 'POS DECATHLON ZAGREB'), 'Shopping', BudgetKind.transfer, iou: true),
      tagged(plain('off', '2026-01-23', -700, 'POS DECATHLON ZAGREB'), 'Shopping'),
      tagged(plain('usd', '2026-01-24', -700, 'POS DECATHLON ZAGREB', currency: 'USD'), 'Shopping'),
      tagged(plain('in', '2026-01-25', 700, 'POS DECATHLON ZAGREB'), 'Shopping'),
      tagged(plain('gone', '2026-01-26', -700, 'POS DECATHLON ZAGREB', deleted: true), 'Shopping'),
      tagged(plain('other', '2026-01-27', -5000, 'POS ZARA ZAGREB'), 'Shopping'), // same amount, other payee
      tagged(plain('dup', '2026-01-28', -700, 'POS DECATHLON ZAGREB'), 'Shopping', ['tA', 'tB']), // already tagged
      tagged(plain('xin', '2026-01-29', -700, 'POS DECATHLON ZAGREB'), 'Extra income'), // not fixed or flex
    ];
    final tags = TagContext(tags: tagTable, links: const {
      'off': {'tA': false},
    });
    final s = stats(rows, tags: tags);
    expect(s.candidates.map((t) => t.id), ['edge', 'ok']);
    expect(s.total, 10700);
  });

  test('ended: last payment 90 days ago runs to today, 91 days ago ends at its month', () {
    final rows = [
      tagged(plain('a', '2026-01-15', -1000, 'POS LIDL'), 'Groceries', ['tA'])
    ];
    final at90 = stats(rows, day: addDays('2026-01-15', 90));
    expect(at90.ended, isFalse);
    expect(at90.running.last.$1, '2026-04');
    final at91 = stats(rows, day: addDays('2026-01-15', 91));
    expect(at91.ended, isTrue);
    expect(at91.running, [('2026-01', 1000)]);
    expect(at91.months, 1);
  });

  test('other currencies, transfers and deleted rows never count; running fills empty months', () {
    final rows = [
      tagged(plain('a', '2026-01-15', -1000, 'POS LIDL'), 'Groceries', ['tA']),
      tagged(plain('b', '2026-01-16', -9000, 'POS LIDL', currency: 'USD'), 'Groceries', ['tA']),
      tagged(plain('c', '2026-03-16', -9000, 'POS LIDL'), 'Internal transfer', ['tA']),
      tagged(plain('d', '2026-03-17', -9000, 'POS LIDL', deleted: true), 'Groceries', ['tA']),
      tagged(plain('e', '2026-03-18', -500, 'POS LIDL'), 'Groceries', ['tA']),
      tagged(plain('f', '2026-02-01', -3000, 'POS ZARA'), 'Shopping'),
    ];
    final s = stats(rows, day: '2026-03-31', st: const WalletSettings(salary: 100000, workHoursPerWeek: 40));
    expect(s.total, 1500);
    expect(s.count, 2);
    expect((s.first, s.last), ('2026-01-15', '2026-03-18'));
    expect(s.running, [('2026-01', 1000), ('2026-02', 1000), ('2026-03', 1500)]);
    expect(s.byYear, [(2026, 1500)]);
    expect(s.sharePermille, 333); // 1500 of 4500
    expect(s.hoursTenths, hoursTenths(1500, const WalletSettings(salary: 100000, workHoursPerWeek: 40)));
  });

  test('no tagged rows: empty stats dated today', () {
    final s = stats([tagged(plain('a', '2026-01-15', -1000, 'POS LIDL'), 'Groceries')]);
    expect(s.isEmpty, isTrue);
    expect((s.first, s.last, s.count, s.total, s.ended), (today, today, 0, 0, false));
    expect(s.candidates, isEmpty);
  });

  test('perf: 20k rows with unique descriptions (merchantKey per row)', () {
    var i = 0;
    final rows = [
      for (final t in bigWalletRows(today, days: 2000))
        CategorizedTx(plain(t.tx.id, t.date, t.tx.amount, '${t.tx.description} ${i++}'), t.category, t.kind,
            tags: t.tx.description.contains('LIDL') ? const ['tA'] : const [])
    ];
    stats(rows); // warm up (JIT)
    final sw = Stopwatch()..start();
    final s = stats(rows);
    sw.stop();
    expect(s.count, greaterThan(0));
    // regression catcher only, about 5x the warm time under a loaded shared laptop; `make perf` holds the real frame budget.
    expect(sw.elapsedMilliseconds, lessThan(1700),
        reason: '${rows.length} rows: ${sw.elapsedMilliseconds} ms (76 ms here, 334 under load)');
  });

  test('refunds above spending: negative total, share and hours clamped to 0, two refunds foot', () {
    final rows = [
      tagged(plain('a', '2026-05-01', -1000, 'POS DECATHLON'), 'Shopping', ['tA']),
      tagged(plain('r1', '2026-05-10', 800, 'POS DECATHLON'), 'Shopping', ['tA']),
      tagged(plain('r2', '2026-06-10', 700, 'POS DECATHLON'), 'Shopping', ['tA']),
      tagged(plain('x', '2026-05-12', -4000, 'POS ZARA'), 'Shopping'),
    ];
    const st = WalletSettings(salary: 100000, workHoursPerWeek: 40);
    final s = stats(rows, st: st);
    expect(s.total, -500);
    expect(s.count, 3);
    expect(s.byMainTag, [('Shopping', -500)]);
    expect(s.running, [('2026-05', 200), ('2026-06', -500)]);
    expect(s.sharePermille, 0);
    expect(s.hoursTenths, 0);
    expect(s.candidates, isEmpty); // refunds are no outflows, ZARA is another payee
  });

  test('sharePermille on an ended project counts spending up to the last payment only', () {
    final rows = [
      tagged(plain('a', '2025-01-10', -1000, 'POS IKEA'), 'Shopping', ['tA']),
      tagged(plain('b', '2025-02-10', -3000, 'POS ZARA'), 'Shopping'),
      tagged(plain('c', '2025-03-10', -1000, 'POS IKEA'), 'Shopping', ['tA']),
      tagged(plain('d', '2025-03-11', -50000, 'POS ZARA'), 'Shopping'), // after the last payment
    ];
    final s = stats(rows);
    expect(s.ended, isTrue);
    expect(s.sharePermille, 400); // 2000 of 5000
    expect(s.running.last, ('2025-03', 2000));
  });

  test('a manual row with a note is a payee; one without a note never is', () {
    Tx manual(String id, String date, String? note) =>
        Tx(id: id, source: 'manual', manual: true, date: date, amount: -900, description: '', note: note);
    final rows = [
      tagged(manual('m1', '2026-04-01', 'Corner bakery'), 'Eating out', ['tA']),
      tagged(manual('m2', '2026-04-05', 'Corner bakery'), 'Eating out'),
      tagged(manual('m3', '2026-04-06', null), 'Eating out'),
      tagged(manual('m4', '2026-04-07', null), 'Eating out', ['tA']),
    ];
    final s = stats(rows);
    expect(s.total, 1800);
    expect(s.candidates.map((t) => t.id), ['m2']);
  });

  test('a split whose whole payment is a transfer is never a candidate', () {
    final pay = plain('s1', '2026-04-03', -1000, 'POS IKEA ZAGREB');
    final whole = CategorizedTx(pay, 'Internal transfer', BudgetKind.transfer);
    final rows = [
      tagged(plain('t', '2026-04-01', -500, 'POS IKEA ZAGREB'), 'Shopping', ['tA']),
      CategorizedTx(pay, 'Shopping', BudgetKind.flex, amount: -600, part: 0, parts: 2, whole: whole),
      CategorizedTx(pay, 'Groceries', BudgetKind.flex, amount: -400, part: 1, parts: 2, whole: whole),
    ];
    expect(stats(rows).candidates, isEmpty);
  });

  test('rows dated after today count; the span runs to the last one', () {
    final rows = [
      tagged(plain('a', '2026-06-01', -1000, 'POS IKEA'), 'Shopping', ['tA']),
      tagged(plain('b', '2026-08-15', -2000, 'POS IKEA'), 'Shopping', ['tA']),
    ];
    final s = stats(rows);
    expect(s.ended, isFalse);
    expect(s.total, 3000);
    expect(s.running, [('2026-06', 1000), ('2026-07', 1000), ('2026-08', 3000)]);
    final span = DateRange(start: s.first, end: s.last);
    expect(tagShare(rows, span, currency: 'EUR').slices.single.spent, s.total);
  });
}
