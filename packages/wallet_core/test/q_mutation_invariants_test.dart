// Stage Q wave 3: tests added for mutants that survived `make mutate ARGS="core …"` on forecast.dart, accounts.dart,
// recurring.dart (recurringCost), repo_iou.dart and categories.dart (kindFor). All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch, bankProfiles;

import 'support/synthetic.dart';

const _today = '2026-01-20', _payday = '2026-02-15';

RecurringBill _bill(String id, {String? label, bool income = false}) => RecurringBill(
      id: id,
      payee: 'synthetic_$id',
      label: label ?? id,
      category: income ? 'Extra income' : 'Shopping',
      expectedAmount: 1000,
      nextDue: '2026-01-25',
      status: 'confirmed',
      direction: income ? RecurringBill.directionIn : null,
    );

DueCycle _cycle(String id, String due, int reserve, {String? label}) =>
    DueCycle(bill: _bill(id, label: label), due: due, reserve: reserve, paid: 0);

IncomeCycle _income(String id, String due, int cents, {String? label}) =>
    IncomeCycle(bill: _bill(id, label: label, income: true), due: due, amount: cents);

PlannedCost _planned(String id, String date, int? cents) =>
    PlannedCost(id: id, title: id, date: date, amount: cents, status: PlannedStatus.open, source: PlannedSource.manual);

List<ForecastPoint> _f({List<DueCycle> cycles = const [], List<PlannedCost> planned = const [], List<IncomeCycle> incomes = const []}) =>
    forecastToPayday(
        startCents: 100000, today: _today, payday: _payday, cycles: cycles, planned: planned, incomes: incomes, bills: const []);

void main() {
  group('forecast boundaries', () {
    test('a 1-cent bill reserve is a forecast event (reserve > 0, not > 1)', () {
      final f = _f(cycles: [_cycle('tiny', '2026-01-25', 1)]);
      expect([for (final p in f) p.cents], [100000, 99999]);
    });

    test('a 1-cent planned cost counts; a zero-amount one adds no point', () {
      final f = _f(planned: [_planned('one', '2026-01-25', 1), _planned('zero', '2026-01-26', 0)]);
      expect([for (final p in f) p.cents], [100000, 99999]);
    });

    test('a planned cost dated today counts; one on payday does not', () {
      final f = _f(planned: [_planned('now', _today, 700), _planned('pd', _payday, 900)]);
      expect([for (final p in f) (p.date, p.cents)], [(_today, 100000), (_today, 99300)]);
    });

    test('a planned cost the day before payday counts', () {
      final f = _f(planned: [_planned('last', '2026-02-14', 700)]);
      expect(f.last.cents, 99300);
    });

    test('a 1-cent income counts; a zero one does not', () {
      final f = _f(incomes: [_income('tip', '2026-01-25', 1), _income('none', '2026-01-26', 0)]);
      expect([for (final p in f) p.cents], [100000, 100001]);
    });

    test('an income dated today counts; one on payday does not; one the day before payday does', () {
      final f = _f(incomes: [
        _income('now', _today, 500),
        _income('pd', _payday, 900),
        _income('last', '2026-02-14', 300),
      ]);
      expect([for (final p in f) (p.date, p.cents)], [(_today, 100000), (_today, 100500), ('2026-02-14', 100800)]);
    });

    test('same date: money out comes before money in even when the income label sorts first', () {
      final f = _f(
        cycles: [_cycle('b1', '2026-01-25', 400, label: 'zzz bill')],
        incomes: [_income('i1', '2026-01-25', 900, label: 'aaa pay')],
      );
      expect([for (final p in f) p.delta], [0, -400, 900]);
      expect(f[1].cause, 'zzz bill');
    });

    test('same date, two incomes: ordered by label whatever the input order', () {
      final f = _f(incomes: [
        _income('i1', '2026-01-25', 100, label: 'bbb'),
        _income('i2', '2026-01-25', 200, label: 'aaa'),
      ]);
      expect([for (final p in f.skip(1)) p.cause], ['aaa', 'bbb']);
    });

    test('same date, three incomes and three bills: label order for every input permutation', () {
      const labels = ['aaa', 'bbb', 'ccc'];
      final perms = [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0]
      ];
      for (final p in perms) {
        final f = _f(incomes: [for (final i in p) _income('i$i', '2026-01-25', 100 + i, label: labels[i])]);
        expect([for (final x in f.skip(1)) x.cause], labels, reason: '$p incomes');
        final g = _f(cycles: [for (final i in p) _cycle('c$i', '2026-01-25', 100 + i, label: labels[i])]);
        expect([for (final x in g.skip(1)) x.cause], labels, reason: '$p bills');
      }
    });

    test('same date, two bills: ordered by label whatever the input order', () {
      final f = _f(cycles: [
        _cycle('c1', '2026-01-25', 100, label: 'bbb'),
        _cycle('c2', '2026-01-25', 200, label: 'aaa'),
      ]);
      expect([for (final p in f.skip(1)) p.cause], ['aaa', 'bbb']);
    });
  });

  group('accountSourceLabel', () {
    test('every bank profile id gives its own label (not the first profile\'s)', () {
      for (final p in bankProfiles) {
        expect(accountSourceLabel(p.id), p.label, reason: p.id);
      }
    });
    test('an unknown source is shown as it is; cash and a removed CSV layout have fixed names', () {
      expect(accountSourceLabel('synthetic_bank_xyz'), 'synthetic_bank_xyz');
      expect(accountSourceLabel(null), 'Cash');
      expect(accountSourceLabel('csv:gone'), 'CSV file');
    });
  });

  group('bank checks', () {
    test('BankCheck: diff is bank minus app, both signs', () {
      expect(const BankCheck(date: '2026-01-10', bankCents: 5000, appCents: 3000).diff, 2000);
      expect(const BankCheck(date: '2026-01-10', bankCents: 3000, appCents: 5000).diff, -2000);
    });

    test('BankCheck.fromJson: each damaged field alone gives null; a good one reads back', () {
      const good = {'date': '2026-01-10', 'bank': 5000, 'app': 3000};
      expect(BankCheck.fromJson(good)?.bankCents, 5000);
      expect(BankCheck.fromJson({...good, 'date': 20260110}), isNull);
      expect(BankCheck.fromJson({...good, 'date': 'not-a-date'}), isNull);
      expect(BankCheck.fromJson({...good, 'bank': '5000'}), isNull);
      expect(BankCheck.fromJson({...good, 'app': 30.5}), isNull);
      expect(BankCheck.fromJson('x'), isNull);
    });
  });

  group('recurringCost guards', () {
    var seq = 0;
    RecurringBill bill(int cents, int days) => RecurringBill(
        id: 'rec:qm-${seq++}',
        payee: 'synthetic',
        label: 'Synthetic bill',
        category: 'Bills & subscriptions',
        expectedAmount: cents,
        intervalDays: days,
        nextDue: '2026-02-01',
        status: 'confirmed');
    ({int monthly, int yearly, bool approximate}) cost(List<RecurringBill> b) => recurringCost(b, currency: 'EUR');

    test('a daily (1-day) bill counts: amount * 365 a year', () {
      expect(cost([bill(100, 1)]), (monthly: 36500 ~/ 12, yearly: 36500, approximate: false));
    });

    test('a 1-cent monthly bill counts', () {
      expect(cost([bill(1, 30)]), (monthly: 1, yearly: 12, approximate: false));
    });

    test('a bill with a zero-day interval is left out (no division by zero)', () {
      expect(cost([bill(1000, 30), bill(500, 0)]), (monthly: 1000, yearly: 12000, approximate: false));
    });

    test('zero-amount and negative-amount bills are left out', () {
      expect(cost([bill(1000, 30), bill(0, 30), bill(-700, 30), bill(0, 7)]), (monthly: 1000, yearly: 12000, approximate: false));
    });
  });

  group('IOU limits and exclusion', () {
    final lend = n('2026-03-16', -4000, 'POS plaćanje', 'PBZ POS PBZ7KONZUM ZAGREB');
    final back = n('2026-03-20', 1500, 'Ostalo', 'UPLATA SYNTH OSOBA');
    final shop = n('2026-03-17', -2500, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB');
    WalletRepo wallet() {
      final r = WalletRepo.inMemory(now: () => DateTime.utc(2026, 3, 25, 9).millisecondsSinceEpoch);
      addTearDown(r.close);
      r.importBatch(ImportBatch(source: 'pbz', transactions: [lend, shop, back]));
      return r;
    }

    String add(WalletRepo r, {int amount = 4000, String? note, String? tx}) => r.addIou(
        person: 'Synthetic Person', direction: IouDirection.lent, amount: amount, currency: 'EUR', date: '2026-03-16', note: note, tx: tx);

    test('a note of exactly the maximum length is accepted, one more rune is refused', () {
      final r = wallet();
      expect(() => add(r, note: 'x' * Iou.maxNote), returnsNormally);
      expect(() => add(r, note: 'x' * (Iou.maxNote + 1)), throwsArgumentError);
    });

    test('the amount can be lowered to exactly what was paid back, not below', () {
      final r = wallet();
      final id = add(r, amount: 4000);
      r.addIouPart(id, amount: 1500, date: '2026-03-20');
      r.updateIou(id, amount: 1500);
      expect(r.ious().single.iou.amount, 1500);
      expect(() => r.updateIou(id, amount: 1499), throwsArgumentError);
    });

    test('a linked payment is a transfer for kindFor; an unlinked one keeps its kind', () {
      final r = wallet();
      add(r, tx: lend.id);
      final cz = r.categorizer();
      final byId = {for (final t in r.transactions()) t.id: t};
      expect(cz.kindFor(byId[lend.id]!, 'Shopping'), BudgetKind.transfer);
      expect(cz.kindFor(byId[shop.id]!, 'Shopping'), isNot(BudgetKind.transfer));
      expect(cz.categorize(byId[lend.id]!).kind, BudgetKind.transfer);
      expect(cz.categorize(byId[shop.id]!).kind, isNot(BudgetKind.transfer));
    });

    test('editing the amount of a linked IOU re-checks the payment (exact amount)', () {
      final r = wallet();
      final id = add(r, tx: lend.id);
      expect(() => r.updateIou(id, amount: 3000), throwsArgumentError);
      expect(r.ious().single.iou.amount, 4000);
    });

    test('changing only the direction or only the currency of a linked IOU re-checks its payment', () {
      final r = wallet();
      final id = add(r, tx: lend.id);
      expect(() => r.updateIou(id, direction: IouDirection.borrowed), throwsArgumentError);
      expect(() => r.updateIou(id, currency: 'USD'), throwsArgumentError);
      expect(r.ious().single.iou.direction, IouDirection.lent);
      expect(r.ious().single.iou.currency, 'EUR');
    });

    test('changing only the currency re-checks linked repayments', () {
      final r = wallet();
      final id = add(r);
      r.addIouPart(id, amount: 1500, date: '2026-03-20', tx: back.id);
      expect(() => r.updateIou(id, currency: 'USD'), throwsArgumentError);
      expect(r.ious().single.iou.currency, 'EUR');
    });

    test('flipping the direction re-checks linked repayments (an incoming payment cannot repay a borrowed IOU)', () {
      final r = wallet();
      final id = add(r);
      r.addIouPart(id, amount: 1500, date: '2026-03-20', tx: back.id);
      expect(() => r.updateIou(id, direction: IouDirection.borrowed), throwsArgumentError);
      expect(r.ious().single.iou.direction, IouDirection.lent);
    });

    test('undoing a deleted repayment: allowed when it equals what is still owed, refused above', () {
      final r = wallet();
      final id = add(r, amount: 4000);
      final a = r.addIouPart(id, amount: 1500, date: '2026-03-20');
      r.deleteIouPart(a);
      final b = r.addIouPart(id, amount: 2500, date: '2026-03-21');
      r.undeleteIouPart(a); // owed is exactly 1500
      expect(r.ious().single.outstanding, 0);
      r.deleteIouPart(a);
      r.deleteIouPart(b);
      r.addIouPart(id, amount: 2600, date: '2026-03-22');
      expect(() => r.undeleteIouPart(a), throwsArgumentError); // only 1400 owed
    });
  });
}
