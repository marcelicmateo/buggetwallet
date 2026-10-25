// Stage P1 review fixes (core builder): plan lines for custom fixed categories, custom income as salary, deleted
// custom categories falling back when read (bills, planned costs, recurring bills), CSV labels and duplicates,
// drill-down trees, the parent rule, half-arrived rows, search by label. All data is SYNTHETIC.
library;

import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch, NormalizedTransaction;

import 'support/sim.dart';
import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 30));

/// 2026-10-10 12:00 UTC.
const _noon = 1791633600000;

const _fixed = 'k00000000000a', _fixedChild = 'k00000000000b', _rentChild = 'k00000000000c', _flex = 'k00000000000d';
const _income = 'k00000000000e', _move = 'k00000000000f';

const _rows = [
  CategoryRow(id: _fixed, name: 'Kindergarten', kind: BudgetKind.fixed, position: 30),
  CategoryRow(id: _fixedChild, name: 'Lunches', kind: BudgetKind.fixed, parent: _fixed),
  CategoryRow(id: _rentChild, name: 'Parking', kind: BudgetKind.fixed, parent: 'Rent'),
  CategoryRow(id: _flex, name: 'Pets', kind: BudgetKind.flex, position: 31),
  CategoryRow(id: _income, name: 'Side job', kind: BudgetKind.income, position: 32),
  CategoryRow(id: _move, name: 'Savings move', kind: BudgetKind.transfer, position: 33),
];

final _table = CategoryTable.from(_rows);

/// The same rows with [_fixed] and its child deleted.
final _afterDelete = CategoryTable.from([
  for (final r in _rows)
    r.id == _fixed || r.id == _fixedChild
        ? CategoryRow(id: r.id, name: r.name, kind: r.kind, parent: r.parent, position: r.position, deleted: true)
        : r
]);

var _seq = 0;
CategorizedTx _c(String date, int cents, String category, CategoryTable t, {String desc = 'Synthetic', String? stored}) => CategorizedTx(
    Tx(id: 'r${_seq++}', source: 'pbz', date: date, amount: cents, description: desc, category: stored), category, t.kindOf(category));

RecurringBill _bill(String payee, String category, int cents) => RecurringBill(
    id: RecurringBill.idFor(payee),
    payee: payee,
    label: payee,
    category: category,
    expectedAmount: cents,
    nextDue: '2026-03-05',
    status: 'confirmed');

void main() {
  group('plan lines for custom fixed categories (owner decision 1)', () {
    const st = WalletSettings(salary: 200000, periodStart: '2026-02-15', paydayDay: 15, planLines: {_fixed: 30000});
    const today = '2026-02-25';

    test('computePeriod: the line is a fixed cost, children are covered, fixedPaid is per top-level', () {
      final bills = [_bill('a', _fixed, 4000), _bill('b', _fixedChild, 3000), _bill('c', _rentChild, 2000), _bill('d', _flex, 1000)];
      final txs = [
        _c('2026-02-16', -1000, _fixedChild, _table),
        _c('2026-02-17', -500, _fixed, _table),
        _c('2026-02-18', -700, _rentChild, _table),
      ];
      final p = computePeriod(txs, st, const [], today, bills: bills, table: _table);
      expect(p.fixedPlan, 30000);
      expect(p.reservedBills, 1000, reason: 'only the flex bill; the others are in the plan');
      expect(p.dueBills, hasLength(4));
      expect(p.fixedPaid, {_fixed: 1500, 'Rent': 700});
      expect(p.flexBudget, 200000 - 30000 - 1000);
      for (final c in [_fixed, _fixedChild, _rentChild, 'Rent', 'Bills & subscriptions']) {
        expect(_table.coveredByPlan(c), isTrue, reason: c);
      }
      expect(_table.coveredByPlan(_flex), isFalse);
      expect(computePeriod(txs, st, const [], today, bills: bills, table: CategoryTable.builtIn).fixedPlan, 0,
          reason: 'a table without the category has no line');
    });

    test('after the delete the line is gone and its bills are reserved: never both', () {
      final bills = [_bill('a', _fixed, 4000), _bill('b', _fixedChild, 3000)];
      final p = computePeriod(const [], st, const [], today, bills: bills, table: _afterDelete);
      expect(p.fixedPlan, 0);
      expect(p.reservedBills, 7000);
      const planned = PlannedCost(id: 'p', title: 'Synthetic', date: '2026-03-01', amount: 900, category: _fixedChild);
      expect(plannedReserves(planned, const [], const {}, table: _table), isFalse);
      expect(plannedReserves(planned, const [], const {}, table: _afterDelete), isTrue);
    });

    test('setPlanLine: only a live top-level custom fixed category; settings read it back; updateSettings refuses it', () async {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final k = await r.addCategory(name: 'Kindergarten', kind: BudgetKind.fixed);
      final child = await r.addCategory(name: 'Lunches', kind: BudgetKind.fixed, parent: k);
      final flex = await r.addCategory(name: 'Pets', kind: BudgetKind.flex);
      r.setPlanLine(k, 25000);
      expect(r.settings().planLines, {k: 25000});
      for (final bad in [child, flex, 'Rent', 'k000000000000']) {
        expect(() => r.setPlanLine(bad, 100), throwsArgumentError, reason: bad);
      }
      expect(() => r.setPlanLine(k, -1), throwsArgumentError);
      expect(() => r.updateSettings({'${WalletSettings.planPrefix}$k': 1}), throwsArgumentError);
      expect(() => r.updateSettings({'planLines': {}}), throwsArgumentError);
      final round = WalletSettings.fromMap(r.settings().toMap(), table: r.categoryTable());
      expect(round.planLines, {k: 25000}, reason: 'toMap/fromMap keep the lines');
      final m1 = r.settings().toMap(), m2 = r.settings().toMap();
      expect(m1['${WalletSettings.planPrefix}$k'], 25000);
      expect([
        for (final e in m1.entries)
          if (e.value is! Map && e.value is! List && m2[e.key] != e.value) e.key
      ], isEmpty, reason: 'two reads compare equal key by key (the app diffs toMap)');
      await r.deleteCategory(child);
      await r.deleteCategory(k);
      expect(r.settings().planLines, isEmpty);
      await r.undeleteCategory(k);
      expect(r.settings().planLines, {k: 25000}, reason: 'the stored row was kept');
      r.setPlanLine(k, null);
      expect(r.settings().planLines, isEmpty);
    }, timeout: _t);

    test('suggestPlan: children count in Rent and in the plan line; planProposals key plan:<id>', () {
      final txs = [
        for (final m in ['2026-07', '2026-08', '2026-09']) ...[
          _c('$m-03', -50000, 'Rent', _table),
          _c('$m-04', -4000, _rentChild, _table),
          _c('$m-05', -20000, _fixed, _table),
          _c('$m-06', -5000, _fixedChild, _table),
        ],
      ];
      final s = suggestPlan(txs, const WalletSettings(), '2026-10-10', table: _table);
      expect(s.rent?.value, 54000);
      expect(s.planLines.keys, [_fixed]);
      expect(s.planLines[_fixed]!.value, 25000);
      expect(suggestPlan(txs, const WalletSettings(), '2026-10-10').rent?.value, 50000, reason: 'built-ins only');
      final subs = suggestPlan(const [], const WalletSettings(), '2026-10-10',
          confirmed: [_bill('x', 'Bills & subscriptions', 1000), _bill('y', 'k0000000000aa', 7)], table: _table);
      expect(subs.subs?.value, 1000);
      final props = planProposals(s, const WalletSettings(planLines: {_fixed: 1}));
      expect(props.map((p) => (p.key, p.suggested)), contains(('plan:$_fixed', 25000)));
    });
  });

  test('custom income counts as salary (owner decision 2)', () {
    final st = WalletSettings.fromMap({'salary': 100000, 'periodStart': '2026-02-15', 'paydayDay': 15, 'incomeMode': 'received'});
    final p = computePeriod([_c('2026-02-15', 120000, _income, _table)], st, const [], '2026-02-25', table: _table);
    expect(p.received, 120000);
    expect(p.income, 120000);
    expect(salaryPaydays([_c('2026-02-15', 120000, _income, _table)], '2026-02-25', currency: 'EUR'), ['2026-02-15']);
  });

  group('a deleted custom category falls back when read (owner decision 3)', () {
    test('bills, planned costs and recurring bills read with the automatic category; nothing is written', () async {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final k = await r.addCategory(name: 'Streaming', kind: BudgetKind.fixed);
      r.addPlanned(title: 'Synthetic Netflix', date: '2026-12-01', amount: 1500, category: k);
      r.addPlanned(title: 'Synthetic thing', date: '2026-12-02', amount: 700, category: k);
      expect(r.plannedCosts().map((p) => p.category), [k, k]);
      final before = dump(r)['planned'];
      await r.deleteCategory(k);
      expect(r.plannedCosts().map((p) => p.category), ['Bills & subscriptions', null]);
      expect(dump(r)['planned'], before, reason: 'resolved when read, never written');
      await r.undeleteCategory(k);
      expect(r.plannedCosts().map((p) => p.category), [k, k]);
    }, timeout: _t);

    test('a confirmed recurring bill in a deleted fixed category: covered or reserved by the fallback, never both', () async {
      final r = WalletRepo.inMemory(now: () => _noon);
      addTearDown(r.close);
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in ['2026-07-06', '2026-08-05', '2026-09-04', '2026-10-04']) ...[
          n(d, -1500, 'POS plaćanje', 'POS SYNTHETIC NETFLIX'),
          n(d, -2500, 'POS plaćanje', 'POS SYNTHETIC CLUB'),
        ],
      ]));
      final k = await r.addCategory(name: 'Fixed stuff', kind: BudgetKind.fixed);
      for (final b in r.recurringBills()) {
        r.setMerchantRule(b.payee, k);
        r.confirmRecurring(b.id);
      }
      r.refreshRecurring('2026-10-10');
      r.setPlanLine(k, 4000);
      final st = WalletSettings.fromMap({...r.settings().toMap(), 'periodStart': '2026-10-15', 'paydayDay': 15}, table: r.categoryTable());
      PeriodBudget period() => computePeriod(const [], st, const [], '2026-10-20', bills: r.recurringBills(), table: r.categoryTable());
      expect(r.recurringBills().map((b) => b.category), [k, k]);
      expect((period().fixedPlan, period().reservedBills), (4000, 0));
      final stored = dump(r)['recurring'];
      await r.deleteCategory(k);
      r.refreshRecurring('2026-10-10');
      expect(dump(r)['recurring'], stored, reason: 'never rewritten');
      final cats = {for (final b in r.recurringBills()) b.label: b.category};
      expect(cats.values.toSet(), {'Bills & subscriptions', 'Shopping'});
      final p = period();
      expect(p.fixedPlan, 0, reason: 'the line went with the category');
      expect(p.reservedBills, 2500, reason: 'the Shopping bill is reserved; the subscription is in subs');
    }, timeout: _t);

    group('two devices whose tables differ', () {
      late VaultKey key;
      late Net net;
      var clock = _noon;
      setUp(() {
        key = VaultKey.generate();
        net = Net();
        clock = _noon;
      });

      Future<void> settle(List<Device> ds) async {
        for (var i = 0; i < 3; i++) {
          for (final d in ds) {
            clock += 1000;
            d.deliver(net, Random(1));
            await d.run();
          }
        }
      }

      test('refreshRecurring never writes a fallback: no write loop', () async {
        final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
        addTearDown(a.close);
        addTearDown(b.close);
        a.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
          for (final d in ['2026-07-06', '2026-08-05', '2026-09-04', '2026-10-04']) n(d, -2500, 'POS plaćanje', 'POS SYNTHETIC CLUB'),
        ]));
        final k = await a.repo.addCategory(name: 'Club', kind: BudgetKind.fixed);
        final bill = a.repo.recurringBills().single;
        final latest = a.repo.transactions().reduce((x, y) => x.date.compareTo(y.date) > 0 ? x : y);
        a.repo.setCategory(latest.id, k);
        a.repo.confirmRecurring(bill.id);
        a.repo.refreshRecurring('2026-10-10');
        expect(a.repo.recurringBills().single.category, k);
        await settle([a, b]);
        // A deletes the category offline; B still has it live. Both refresh, then they sync.
        await a.repo.deleteCategory(k);
        a.repo.refreshRecurring('2026-10-10');
        b.repo.refreshRecurring('2026-10-10');
        await settle([a, b]);
        final stable = dump(a.repo)['recurring'];
        for (var i = 0; i < 3; i++) {
          a.repo.refreshRecurring('2026-10-10');
          b.repo.refreshRecurring('2026-10-10');
          await settle([a, b]);
        }
        expect(dump(a.repo)['recurring'], stable, reason: 'no field or clock changed');
        expect(dump(b.repo)['recurring'], stable);
        expect(a.repo.db.select('SELECT category FROM recurring').single['category'], k, reason: 'the stored id stays');
        expect(a.repo.recurringBills().single.category, 'Shopping', reason: 'read with the fallback');
      }, timeout: _t);
    });
  });

  group('callers with a custom table', () {
    test('billHistory: a row in a custom transfer category is no payment', () {
      final payee = merchantKey(const Tx(id: 'x', source: 'pbz', date: '2026-09-01', amount: -1, description: 'POS SYNTHETIC CLUB'));
      const rows = [
        Tx(id: 'p1', source: 'pbz', date: '2026-09-04', amount: -2500, description: 'POS SYNTHETIC CLUB'),
        Tx(id: 'p2', source: 'pbz', date: '2026-10-04', amount: -2500, description: 'POS SYNTHETIC CLUB', category: _move),
      ];
      final b = _bill(payee, _flex, 2500);
      int paid(CategoryTable? t) =>
          billHistory(b, rows, const [], today: '2026-10-10', currency: 'EUR', table: t).fold<int>(0, (s, m) => s + m.payments.length);
      expect(paid(CategoryTable.builtIn), 2);
      expect(paid(_table), 1);
    });

    test('suggestBillCategory skips a recurring bill whose category is deleted', () {
      const slip = Bill(id: 'b1', payee: 'SYNTHETIC CLUB');
      final key = billPayeeKey(slip)!;
      final rec = [_bill(key, _fixed, 1000)];
      expect(suggestBillCategory(slip, recurring: rec, txs: const [], table: _table), _fixed);
      expect(suggestBillCategory(slip, recurring: rec, txs: const [], table: _afterDelete), isNull);
    });

    test('reviewState: a row set to a live custom category is reviewed, one set to a deleted one is not', () {
      final st = WalletSettings.fromMap({'reviewDay': 7});
      int automatic(CategoryTable t) =>
          reviewState([_c('2026-10-08', -100, _fixed, t, stored: _fixed)], st, const [], const {}, today: '2026-10-10', table: t)
              .steps
              .firstWhere((s) => s.id == 'categories')
              .count;
      expect(automatic(_table), 0);
      expect(automatic(_afterDelete), 1);
    });

    test('transactionsCsv writes labels with a table and stays identical without', () {
      final rows = [_c('2026-09-01', -100, _fixedChild, _table), _c('2026-09-02', -200, 'Groceries', _table)];
      final plain = transactionsCsv(rows);
      expect(transactionsCsv(rows, table: CategoryTable.builtIn), plain);
      expect(plain, contains(',$_fixedChild,'));
      final labelled = transactionsCsv(rows, table: _table);
      expect(labelled, contains(',Lunches,'));
      expect(labelled, contains(',Groceries,'));
    });

    test('monthly CSV: a sync duplicate counts in its original\'s column, no label twice', () {
      final t = CategoryTable.from(const [
        CategoryRow(id: 'k000000000001', name: 'Pets', kind: BudgetKind.flex),
        CategoryRow(id: 'k000000000002', name: 'pets', kind: BudgetKind.flex),
      ]);
      final csv = monthlySummaryCsv([_c('2026-09-01', -100, 'k000000000001', t), _c('2026-09-02', -250, 'k000000000002', t)],
          currency: 'EUR', table: t);
      final lines = csv.trim().split('\n');
      expect(lines.first, 'month,${spendingCategories.join(',')},Pets,total');
      expect(lines[1].split(',').reversed.take(2).toList(), ['3.50', '3.50']);
    });

    test('drill-down: a parent matches its whole tree and sums exactly; a child only itself', () {
      final r = DateRange(start: '2026-09-01', end: '2026-09-30');
      final rows = [
        _c('2026-09-03', -1000, _fixed, _table, desc: 'SYNTHETIC SCHOOL'),
        _c('2026-09-04', -333, _fixedChild, _table, desc: 'SYNTHETIC CANTEEN'),
        _c('2026-09-05', -1, _fixedChild, _table, desc: 'SYNTHETIC CANTEEN'),
      ];
      final share = categoryShare(rows, r, currency: 'EUR', rollUp: true, table: _table).slices.single.spent;
      expect(merchantsIn(_fixed, rows, r, currency: 'EUR', table: _table).fold<int>(0, (s, m) => s + m.spent), share);
      expect(rowsFor(_fixed, null, rows, r, currency: 'EUR', table: _table), hasLength(3));
      expect(rowsFor(_fixed, null, rows, r, currency: 'EUR'), hasLength(1), reason: 'without a table: the id only');
      expect(rowsFor(_fixedChild, null, rows, r, currency: 'EUR', table: _table), hasLength(2));
      final canteen = merchantKey(rows[1].tx);
      expect(merchantTrend(_fixed, canteen, rows, r, currency: 'EUR', today: '2026-10-10', table: _table).single.spent, 334);
      final cmp = compareCategory(_fixed, rows, '2026-09', currency: 'EUR', table: _table);
      expect(cmp.thisMonth, 1334);
    });

    test('searchAll matches a category by its label', () {
      final rows = [_c('2026-09-03', -1000, _fixedChild, _table, desc: 'SYNTHETIC CANTEEN')];
      SearchResult s(CategoryTable? t) => searchAll('lunch', txs: rows, goals: const [], wishlist: const [], bills: const [], table: t);
      expect(s(null).txs, isEmpty);
      expect(s(_table).txs, hasLength(1));
    });
  });

  group('round 2', () {
    test('a standing-order bill in a deleted fixed category reads Loan like its rows: flexBudget never drops twice', () async {
      final r = WalletRepo.inMemory(now: () => _noon);
      addTearDown(r.close);
      NormalizedTransaction rate(String d) => n(d, -30000, 'Trajni nalog', 'SYNTHETIC LENDER RATA');
      r.importBatch(ImportBatch(source: 'pbz', transactions: [rate('2026-07-06'), rate('2026-08-05'), rate('2026-09-04')]));
      final km = await r.addCategory(name: 'Mortgage', kind: BudgetKind.fixed);
      final bill = r.recurringBills().single;
      r.setMerchantRule(bill.payee, km);
      r.confirmRecurring(bill.id);
      r.importBatch(ImportBatch(source: 'pbz', transactions: [rate('2026-10-04')]));
      r.updateSettings({'salary': 200000, 'loan': 30000, 'periodStart': '2026-10-15', 'paydayDay': 15});
      expect(r.recurringBills().single.lastPaidTx, isNotNull);
      expect(r.recurringBills().single.category, km);
      PeriodBudget period() =>
          computePeriod(const [], r.settings(), const [], '2026-10-20', bills: r.recurringBills(), table: r.categoryTable());
      final before = period();
      expect((before.reservedBills, before.dueBills.length), (0, 1));
      await r.deleteCategory(km);
      final cz = r.categorizer();
      expect({for (final t in r.transactions()) cz.categoryOf(t)}, {'Loan'});
      expect(r.recurringBills().single.category, 'Loan', reason: 'the category of its own paying row');
      final after = period();
      expect(after.reservedBills, 0, reason: 'covered by the loan setting, not reserved on top of it');
      expect(after.flexBudget, before.flexBudget);
      expect(after.flexBudget, 200000 - 30000);
    }, timeout: _t);

    test('monthly CSV: a duplicate of a non-spending original keeps its own column and its spending', () async {
      final key = VaultKey.generate();
      final net = Net();
      var clock = _noon;
      final a = Device('A', null, key, () => clock, net: net), b = Device('B', null, key, () => clock, net: net);
      addTearDown(a.close);
      addTearDown(b.close);
      await a.repo.updateCategory('Extra income', name: 'Side');
      final side = await b.repo.addCategory(name: 'Side', kind: BudgetKind.flex);
      for (var i = 0; i < 3; i++) {
        for (final d in [a, b]) {
          clock += 1000;
          await d.run();
        }
      }
      final t = b.repo.categoryTable();
      expect(t.duplicateOf(side), 'Extra income');
      final csv = monthlySummaryCsv([_c('2026-09-01', -500, side, t), _c('2026-09-02', -100, 'Groceries', t)], currency: 'EUR', table: t);
      final lines = csv.trim().split('\n');
      expect(lines.first, 'month,${spendingCategories.join(',')},Side,total');
      final cells = lines[1].split(',');
      expect((cells[cells.length - 2], cells.last), ('5.00', '6.00'));
    }, timeout: _t);
  });

  group('table rules', () {
    test('a row whose kind has not arrived is not live', () {
      final t = CategoryTable.from([
        CategoryRow.fromRow({'id': 'k000000000009', 'name': 'Half', 'kind': '', 'deleted': 0})
      ]);
      expect(t.isLive('k000000000009'), isFalse);
      expect(t.isDeadCustom('k000000000009'), isTrue);
      expect(t.pickable(), isNot(contains('k000000000009')));
      expect(CategoryTable.from(const [CategoryRow(id: 'k000000000009', kind: null)]).isLive('k000000000009'), isFalse);
    });

    test('addCategory refuses a parent whose stored parent is live (the table would not attach the child)', () async {
      final key = VaultKey.generate();
      final net = Net();
      var clock = _noon;
      final a = Device('A', null, key, () => clock, net: net), b = Device('B', null, key, () => clock, net: net);
      addTearDown(a.close);
      addTearDown(b.close);
      Future<void> settle() async {
        for (var i = 0; i < 3; i++) {
          for (final d in [a, b]) {
            clock += 1000;
            await d.run();
          }
        }
      }

      final q = await a.repo.addCategory(name: 'Q', kind: BudgetKind.flex);
      final rr = await a.repo.addCategory(name: 'R', kind: BudgetKind.flex);
      await settle();
      final p = await b.repo.addCategory(name: 'P', kind: BudgetKind.flex, parent: q);
      await a.repo.updateCategory(q, parent: rr);
      await settle();
      final t = a.repo.categoryTable();
      expect(t.parentOf(q), rr);
      expect(t.parentOf(p), isNull, reason: 'its parent is a child now');
      expect(t.hasLiveStoredParent(p), isTrue);
      await expectLater(a.repo.addCategory(name: 'Child', kind: BudgetKind.flex, parent: p), throwsArgumentError);
    }, timeout: _t);
  });
}
