// Stage P6 spec tests, pure half: Categorizer.expand without splits, CategorizedTx part fields, and the money functions
// fed with expanded parts (totals follow the parts, never the payment as well). Written from docs/context/P6_SPEC.md
// only. SYNTHETIC data.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

Tx _tx(String id, String date, int cents, {String desc = 'SYNTH SHOP', String currency = 'EUR'}) =>
    Tx(id: id, source: 'pbz', date: date, amount: cents, currency: currency, description: desc);

/// The rows of payment [t] as the read model yields them for a valid split: (amount, category, tags) per part.
List<CategorizedTx> _parts(Tx t, List<(int, String, List<String>)> parts, {String? note}) => [
      for (final (i, p) in parts.indexed)
        CategorizedTx(t, p.$2, kindOf(p.$2), tags: p.$3, amount: p.$1, part: i, parts: parts.length, partNote: i == 0 ? note : null),
    ];

CategorizedTx _whole(Tx t, String c, {List<String> tags = const []}) => CategorizedTx(t, c, kindOf(c), tags: tags);

void main() {
  group('SplitPart', () {
    test('holds amount, category, tags and note', () {
      const p = SplitPart(amount: -600, category: 'Groceries', tags: ['ta'], note: 'milk');
      expect((p.amount, p.category, p.note), (-600, 'Groceries', 'milk'));
      expect(p.tags, ['ta']);
      const q = SplitPart(amount: -1, category: 'Shopping');
      expect(q.tags, isEmpty);
      expect(q.note, isNull);
    });
  });

  group('expand without splits', () {
    final c = Categorizer();
    test('an unsplit payment expands to exactly its own categorize result', () {
      final t = _tx('a1', '2026-03-12', -2340, desc: 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB');
      final out = c.expand(t);
      expect(out, hasLength(1));
      final w = c.categorize(t);
      expect((out.single.category, out.single.kind, out.single.amount), (w.category, w.kind, -2340));
      expect(out.single.tags, w.tags);
      expect(out.single.tx.id, 'a1');
      expect((out.single.part, out.single.parts, out.single.partNote, out.single.splitBroken), (null, 0, null, false));
    });

    test('a CategorizedTx built the old way has amount = payment amount and no part', () {
      final x = _whole(_tx('a2', '2026-03-12', -777), 'Shopping');
      expect((x.amount, x.part, x.parts, x.partNote, x.splitBroken), (-777, null, 0, null, false));
    });

    test('income, a foreign-currency row and a deleted row also expand to one row each', () {
      for (final t in [
        _tx('i1', '2026-03-10', 150000, desc: 'Neto plaća'),
        _tx('f1', '2026-03-10', -500, currency: 'USD'),
        const Tx(id: 'd1', source: 'pbz', date: '2026-03-10', amount: -500, description: 'SYNTH', deleted: true),
      ]) {
        expect(c.expand(t), hasLength(1), reason: t.id);
        expect(c.expand(t).single.amount, t.amount, reason: t.id);
      }
    });
  });

  group('totals follow the parts', () {
    final pay = _tx('p1', '2026-03-12', -10000, desc: 'ZORBLEX MARKET');
    final split = _parts(
        pay,
        [
          (-6000, 'Groceries', ['ta']),
          (-4000, 'Shopping', const <String>[]),
        ],
        note: 'bread');

    test('monthSummary: out is the payment amount once, per category the parts', () {
      final s = monthSummary(split, '2026-03', currency: 'EUR');
      expect(s.out, 10000, reason: 'not 20000: the payment is never counted with its parts');
      expect(s.byCategory, {'Groceries': 6000, 'Shopping': 4000});
      expect(s.income, 0);
    });

    test('a payment split into two parts of one category equals the unsplit payment', () {
      final a = monthSummary(_parts(pay, [(-6000, 'Groceries', const []), (-4000, 'Groceries', const [])]), '2026-03', currency: 'EUR');
      final b = monthSummary([_whole(pay, 'Groceries')], '2026-03', currency: 'EUR');
      expect((a.out, a.income), (b.out, b.income));
      expect(a.byCategory, b.byCategory);
    });

    test('income parts count as income; a refund row next to a split reduces its category', () {
      final inc = _tx('in', '2026-03-10', 20000, desc: 'SYNTH INCOME');
      final s = monthSummary(_parts(inc, [(15000, 'Salary', const []), (5000, 'Extra income', const [])]), '2026-03', currency: 'EUR');
      expect((s.income, s.out), (20000, 0));
      final rows = [
        ..._parts(pay, [(-6000, 'Groceries', const []), (-4000, 'Groceries', const [])]),
        _whole(_tx('r', '2026-03-13', 1500), 'Groceries'),
      ];
      expect(monthSummary(rows, '2026-03', currency: 'EUR').byCategory, {'Groceries': 8500});
    });

    test('categoryShare totals equal the parts', () {
      final r = DateRange(start: '2026-03-01', end: '2026-03-31');
      final s = categoryShare(split, r, currency: 'EUR');
      expect(s.total, 10000);
      expect({for (final x in s.slices) x.category: x.spent}, {'Groceries': 6000, 'Shopping': 4000});
    });

    test('tagShare: the tag owns only the part that carries it; untagged is the other part', () {
      final r = DateRange(start: '2026-03-01', end: '2026-03-31');
      final s = tagShare(split, r, currency: 'EUR');
      expect(s.slices.map((x) => (x.tag, x.spent, x.count)), [('ta', 6000, 1)]);
      expect(s.untaggedSpent, 4000);
    });

    test('monthlySummaryCsv has the part sums per column and the payment once in the total', () {
      final lines = monthlySummaryCsv(split, currency: 'EUR').trim().split('\n');
      final head = lines.first.split(',');
      final row = lines[1].split(',');
      expect(row.first, '2026-03');
      expect(row[head.indexOf('Groceries')], '60.00');
      expect(row[head.indexOf('Shopping')], '40.00');
      expect(row.last, '100.00');
    });

    test('transactionsCsv: one line per part with the part amount, main tag and note; unsplit rows as before', () {
      final other = _whole(_tx('u', '2026-03-13', -1250, desc: 'SYNTH OTHER'), 'Shopping');
      final lines = transactionsCsv([...split, other]).trim().split('\n');
      expect(lines, hasLength(4), reason: 'header + 2 parts + 1 unsplit');
      expect(lines[1], startsWith('2026-03-12,-60.00,Groceries,'));
      expect(lines[2], startsWith('2026-03-12,-40.00,Shopping,'));
      expect(lines[1], endsWith(',bread'), reason: 'the part note fills the note column');
      expect(lines[3], startsWith('2026-03-13,-12.50,Shopping,'));
      final tbl = TagTable.from(const [TagRow(id: 'ta', name: 'Trip', position: 0)]);
      final withTags = transactionsCsv(split, tags: tbl).trim().split('\n');
      expect(withTags[1], startsWith('2026-03-12,-60.00,Groceries,Trip,'));
      expect(withTags[2], startsWith('2026-03-12,-40.00,Shopping,,'));
    });

    test('a deleted payment gives no lines and no money whatever its parts', () {
      const dead = Tx(id: 'x', source: 'pbz', date: '2026-03-12', amount: -10000, description: 'SYNTH', deleted: true);
      final rows = _parts(dead, [(-6000, 'Groceries', const []), (-4000, 'Shopping', const [])]);
      expect(monthSummary(rows, '2026-03', currency: 'EUR').out, 0);
      expect(transactionsCsv(rows).trim().split('\n'), hasLength(1));
    });
  });

  group('identity without splits', () {
    final rows = [
      _whole(_tx('a', '2026-03-02', -2340, desc: 'LIDL'), 'Groceries'),
      _whole(_tx('b', '2026-03-05', -25000, desc: 'Naplata kredita'), 'Rent'),
      _whole(_tx('c', '2026-03-10', 150000, desc: 'Neto plaća'), 'Salary'),
      _whole(_tx('d', '2026-03-11', -5000, desc: 'SYNTH'), 'Internal transfer'),
      _whole(_tx('e', '2026-03-12', -1999, desc: 'SYNTH'), 'Shopping', tags: ['ta']),
    ];
    // The same rows with the part fields stated as "not split" explicitly.
    final same = [for (final x in rows) CategorizedTx(x.tx, x.category, x.kind, tags: x.tags, amount: x.tx.amount, part: null, parts: 0)];
    const st = WalletSettings(salary: 150000, paydayDay: 10, periodStart: '2026-03-10', rent: 25000);

    test('every aggregate is identical', () {
      final ma = monthSummary(same, '2026-03', currency: 'EUR'), mb = monthSummary(rows, '2026-03', currency: 'EUR');
      expect((ma.out, ma.income), (mb.out, mb.income));
      expect(ma.byCategory, mb.byCategory);
      expect(ma.foreignByCurrency, mb.foreignByCurrency);
      expect(monthlySummaryCsv(same, currency: 'EUR'), monthlySummaryCsv(rows, currency: 'EUR'));
      expect(transactionsCsv(same), transactionsCsv(rows));
      final a = computePeriod(same, st, const [], '2026-03-14', table: CategoryTable.builtIn);
      final b = computePeriod(rows, st, const [], '2026-03-14', table: CategoryTable.builtIn);
      expect((a.spent, a.remaining, a.flexBudget, a.allowanceToday), (b.spent, b.remaining, b.flexBudget, b.allowanceToday));
      expect(a.fixedPaid, b.fixedPaid);
      final r = DateRange(start: '2026-03-01', end: '2026-03-31');
      expect(categoryShare(same, r, currency: 'EUR').total, categoryShare(rows, r, currency: 'EUR').total);
    });
  });

  group('safe to spend uses the parts', () {
    const st = WalletSettings(salary: 200000, paydayDay: 10, periodStart: '2026-03-10');
    final pay = _tx('p', '2026-03-12', -10000, desc: 'ZORBLEX MARKET');
    final table = CategoryTable.builtIn;

    test('a Rent part counts as fixed, a Groceries part as flex', () {
      final p =
          computePeriod(_parts(pay, [(-4000, 'Rent', const []), (-6000, 'Groceries', const [])]), st, const [], '2026-03-15', table: table);
      expect(p.spent, 6000, reason: 'only the flex part');
      expect(p.fixedPaid['Rent'], 4000);
    });

    test('the whole payment as Groceries would be 10000 flex: the split makes the difference', () {
      final p = computePeriod([_whole(pay, 'Groceries')], st, const [], '2026-03-15', table: table);
      expect(p.spent, 10000);
      expect(p.fixedPaid, isEmpty);
    });

    test('spentToday counts only the flex part dated today', () {
      final today = _tx('t', '2026-03-15', -3000);
      final p = computePeriod(_parts(today, [(-1000, 'Groceries', const []), (-2000, 'Rent', const [])]), st, const [], '2026-03-15',
          table: table);
      expect(p.spentToday, 1000);
    });
  });

  group('broken marker on a row', () {
    test('a broken row carries splitBroken, no part, and counts whole', () {
      final t = _tx('b', '2026-03-12', -12000);
      final x = CategorizedTx(t, 'Groceries', BudgetKind.flex, amount: -12000, splitBroken: true);
      expect((x.splitBroken, x.part, x.parts), (true, null, 0));
      expect(monthSummary([x], '2026-03', currency: 'EUR').out, 12000);
    });
  });
}
