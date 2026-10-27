// ignore_for_file: avoid_dynamic_calls, inference_failure_on_untyped_parameter
// Stage Q8 spec tests (IOU list, schema 17): validation, outstanding, linked rows leave the period/month sums but still count
// in account balances, unlinked IOUs change nothing, a delete brings the money back, two-device sync.
// Written from docs/context/STAGE_Q_PLAN.md Q8 only. SYNTHETIC data.
// API: repo_iou.dart (addIou, addIouPart, closeIou, deleteIou/undeleteIou, deleteIouPart, ious() -> IouView).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _today = '2026-03-15';

String _add(WalletRepo r,
        {String person = 'Alex',
        IouDirection direction = IouDirection.lent,
        int amount = 5000,
        String currency = 'EUR',
        String date = '2026-03-05',
        String? tx}) =>
    r.addIou(person: person, direction: direction, amount: amount, currency: currency, date: date, note: '', tx: tx);
String _part(WalletRepo r, String iou, int amount, {String date = '2026-03-10', String? tx}) =>
    r.addIouPart(iou, amount: amount, date: date, tx: tx);

/// Money in (a repayment): hand-added entries are expenses only, so it comes in as an imported bank row.
String _inflow(WalletRepo r, String date, int cents) {
  r.importBatch(ImportBatch(source: 'pbz', transactions: [n(date, cents, 'Ostalo', 'Synth repayment $date', kind: TxKind.salary)]));
  return r.transactions().firstWhere((t) => t.description == 'Synth repayment $date').id;
}

IouView _iou(WalletRepo r, String id) => r.ious().firstWhere((i) => i.iou.id == id);
int _outstanding(WalletRepo r, String id) => _iou(r, id).outstanding;

void main() {
  late WalletRepo r;
  var now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
  setUp(() {
    now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
    r = WalletRepo.inMemory(now: () => now);
    r.updateSettings({'salary': 150000, 'paydayDay': 20, 'periodStart': '2026-02-20'});
  });
  tearDown(() => r.close());

  PeriodBudget period() {
    final cz = r.categorizer();
    return computePeriod([for (final t in r.transactions()) cz.categorize(t)], r.settings(), [], _today, table: r.categoryTable());
  }

  MonthSummary month() {
    final cz = r.categorizer();
    return monthSummary([for (final t in r.transactions()) cz.categorize(t)], '2026-03', currency: 'EUR');
  }

  group('validation (ArgumentError with a readable message; nothing written)', () {
    test('person: empty, blank and over-long are refused', () async {
      for (final p in ['', '   ', 'x' * 61]) {
        expect(() => _add(r, person: p), throwsA(isA<ArgumentError>().having((e) => e.message.toString(), 'message', isNotEmpty)),
            reason: p);
      }
      expect(r.ious(), isEmpty);
    });
    test('person of exactly 60 characters is accepted', () {
      expect(_add(r, person: 'x' * 60), isNotEmpty);
    });
    test('a repayment beyond what is outstanding is refused on a local write; exactly the outstanding is fine', () {
      final id = _add(r, amount: 5000);
      _part(r, id, 3000);
      expect(() => _part(r, id, 2001), throwsArgumentError);
      expect(_part(r, id, 2000), isNotEmpty);
      expect(_outstanding(r, id), 0);
    });
    test('a linked payment must have the same amount, the right sign, and be linked to one IOU only', () {
      final out = r.addTransaction(date: '2026-03-07', amount: 5000, category: 'Shopping');
      final other = r.addTransaction(date: '2026-03-07', amount: 4000, category: 'Shopping');
      final inflow = _inflow(r, '2026-03-08', 5000);
      expect(() => _add(r, tx: other), throwsArgumentError, reason: 'amount differs');
      expect(() => _add(r, tx: inflow), throwsArgumentError, reason: 'lent needs an outflow');
      expect(() => _add(r, direction: IouDirection.borrowed, tx: out), throwsArgumentError, reason: 'borrowed needs an inflow');
      _add(r, tx: out);
      expect(() => _add(r, tx: out), throwsArgumentError, reason: 'one IOU per payment');
      expect(r.iouLinkedTx(), {out});
    });
    test('amount must be positive and within the cap', () async {
      for (final a in [0, -1, -5000, WalletSettings.maxAmount + 1]) {
        expect(() => _add(r, amount: a), throwsArgumentError, reason: '$a');
      }
      expect(_add(r, amount: 1), isNotEmpty);
      expect(_add(r, amount: WalletSettings.maxAmount), isNotEmpty);
    });
    test('date must be a real date; currency three capitals', () async {
      expect(() => _add(r, date: '2026-02-30'), throwsArgumentError);
      expect(() => _add(r, date: 'yesterday'), throwsArgumentError);
      expect(() => _add(r, currency: 'eur'), throwsArgumentError);
      expect(() => _add(r, currency: 'EURO'), throwsArgumentError);
      expect(r.ious(), isEmpty);
    });
    test('a repayment part must be positive; an unknown IOU is refused', () async {
      final id = _add(r);
      expect(() => _part(r, id, 0), throwsArgumentError);
      expect(() => _part(r, id, -100), throwsArgumentError);
      expect(() => _part(r, 'nope', 100), throwsArgumentError);
      expect(_outstanding(r, id), 5000);
    });
    test('a linked payment must exist', () async {
      expect(() => _add(r, tx: 'no-such-row'), throwsArgumentError);
    });
  });

  group('outstanding = amount - sum of live parts', () {
    test('partial repayments reduce it; a deleted part gives it back; full repayment is zero', () async {
      final id = _add(r, amount: 5000);
      expect(_outstanding(r, id), 5000);
      final p1 = _part(r, id, 1200);
      _part(r, id, 800, date: '2026-03-12');
      expect(_outstanding(r, id), 3000);
      r.deleteIouPart(p1);
      expect(_outstanding(r, id), 4200);
      _part(r, id, 4200, date: '2026-03-14');
      expect(_outstanding(r, id), 0);
    });
    test('close and delete/undelete keep amounts exact; a deleted IOU is not listed, an undeleted one is back with its parts', () async {
      final id = _add(r, amount: 7000, direction: IouDirection.borrowed);
      _part(r, id, 1000);
      r.closeIou(id);
      expect(_iou(r, id).iou.closed, isTrue);
      r.deleteIou(id);
      expect(r.ious().where((i) => i.iou.id == id), isEmpty);
      r.undeleteIou(id);
      expect(_outstanding(r, id), 6000);
    });
    test('both directions are kept apart', () async {
      final a = _add(r, direction: IouDirection.lent, amount: 3000);
      final b = _add(r, direction: IouDirection.borrowed, amount: 2000, person: 'Sam');
      expect(_iou(r, a).iou.direction, IouDirection.lent);
      expect(_iou(r, b).iou.direction, IouDirection.borrowed);
    });
  });

  group('money: linked payments are neither spending nor income', () {
    test('an unlinked IOU changes no number', () async {
      r.addTransaction(date: '2026-03-06', amount: 5000, category: 'Groceries');
      final before = (period().spent, month().out, month().income);
      final id = _add(r, amount: 5000);
      _part(r, id, 2000);
      expect((period().spent, month().out, month().income), before);
    });
    test('a linked expense (lent) leaves computePeriod and monthSummary; deleting the IOU brings it back', () async {
      r.addTransaction(date: '2026-03-06', amount: 2000, category: 'Groceries');
      final lent = r.addTransaction(date: '2026-03-07', amount: 5000, category: 'Shopping');
      final withAll = (period().spent, month().out);
      expect(withAll.$1, 7000);
      final id = _add(r, amount: 5000, tx: lent);
      expect(period().spent, 2000);
      expect(month().out, 2000);
      r.deleteIou(id);
      expect((period().spent, month().out), withAll, reason: 'a delete brings the money back');
      r.undeleteIou(id);
      expect(period().spent, 2000);
    });
    test('a linked repayment (income) leaves the month income and the period received', () async {
      final back = _inflow(r, '2026-03-12', 3000);
      final id = _add(r, amount: 3000, tx: null);
      final incomeBefore = month().income;
      final receivedBefore = period().received + period().extras;
      expect(incomeBefore, greaterThan(0));
      _part(r, id, 3000, tx: back);
      expect(month().income, incomeBefore - 3000);
      expect(period().received + period().extras, receivedBefore - 3000);
    });
    test('removing just the part\'s link (delete the part) brings the row back too', () async {
      final back = _inflow(r, '2026-03-12', 3000);
      final id = _add(r, amount: 3000);
      final p = _part(r, id, 3000, tx: back);
      final without = month().income;
      r.deleteIouPart(p);
      expect(month().income, without + 3000);
    });
    test('linked bank rows still count in accountBalances', () async {
      await r.addAccount(name: 'Main', source: 'pbz', currency: 'EUR', opening: 100000, openingDate: '2026-03-01');
      final rows = [
        const Tx(id: 'b1', source: 'pbz', date: '2026-03-07', amount: -5000, description: 'Synth transfer to Alex'),
        const Tx(id: 'b2', source: 'pbz', date: '2026-03-12', amount: 2000, description: 'Synth repayment Alex'),
      ];
      final plain = accountBalances(r.accounts(), rows).single.balance;
      expect(plain, 97000);
      // Whatever IOUs say about these ids, the bank balance is arithmetic on the rows.
      final id = _add(r, amount: 5000);
      _part(r, id, 2000);
      expect(accountBalances(r.accounts(), rows).single.balance, 97000);
    });
  });

  group('two devices', () {
    test('an IOU with parts, a close and a delete reach the other device; both directions', () async {
      final net = Net();
      var t = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
      final key = VaultKey(List<int>.generate(32, (i) => i + 1));
      final a = Device('a', null, key, () => t, net: net, deviceId: 'f1d07e5700000001');
      final b = Device('b', null, key, () => t, net: net, deviceId: 'f1d07e5700000002');
      addTearDown(a.close);
      addTearDown(b.close);
      final lent = _add(a.repo, amount: 5000);
      final owed = _add(a.repo, amount: 2500, direction: IouDirection.borrowed, person: 'Sam');
      _part(a.repo, lent, 1500);
      await a.run();
      t += 60000;
      await b.run();
      expect(_outstanding(b.repo, lent), 3500);
      expect(_iou(b.repo, owed).iou.direction, IouDirection.borrowed);
      // b closes one and repays part of the other; a deletes the first meanwhile
      b.repo.closeIou(lent);
      _part(b.repo, owed, 500);
      t += 60000;
      await b.run();
      t += 60000;
      await a.run();
      expect(_iou(a.repo, lent).iou.closed, isTrue);
      expect(_outstanding(a.repo, owed), 2000);
      a.repo.deleteIou(owed);
      t += 60000;
      await a.run();
      t += 60000;
      await b.run();
      expect(b.repo.ious().map((i) => i.iou.id), [lent]);
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
    });
    test('a linked IOU leaves the numbers on the other device too', () async {
      final net = Net();
      var t = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
      final key = VaultKey(List<int>.generate(32, (i) => i + 1));
      final a = Device('a', null, key, () => t, net: net, deviceId: 'f1d07e5700000001');
      final b = Device('b', null, key, () => t, net: net, deviceId: 'f1d07e5700000002');
      addTearDown(a.close);
      addTearDown(b.close);
      final row = a.repo.addTransaction(date: '2026-03-07', amount: 5000, category: 'Shopping');
      _add(a.repo, amount: 5000, tx: row);
      await a.run();
      t += 60000;
      await b.run();
      final cz = b.repo.categorizer();
      final m = monthSummary([for (final x in b.repo.transactions()) cz.categorize(x)], '2026-03', currency: 'EUR');
      expect(m.out, 0);
    });
  });
}
