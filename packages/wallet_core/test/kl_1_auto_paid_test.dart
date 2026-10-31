// KL-A item 1: a planned cost closes itself only when exactly one bank row has its category, its exact amount and a
// date within ±3 days (`planAutoPaid`), with the device-local toast list and the Undo marker `auto_off` (schema 19).
// Synthetic data only.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

PlannedCost pc(String id, String date, int? amount,
        {String? category = 'Groceries', PlannedSource source = PlannedSource.manual, Set<String> autoOff = const {}, String? paidTx}) =>
    PlannedCost(
        id: id,
        title: 'Synthetic $id',
        date: date,
        amount: amount,
        category: category,
        source: source,
        sourceRef: source == PlannedSource.bill ? 'b1' : null,
        autoOff: autoOff,
        paidTx: paidTx,
        status: paidTx != null ? PlannedStatus.paid : PlannedStatus.open);

CategorizedTx row(String id, String date, int cents,
        {String category = 'Groceries', bool manual = false, String? transferTo, bool deleted = false, String currency = 'EUR'}) =>
    CategorizedTx(
        Tx(
            id: id,
            source: manual ? 'manual' : 'pbz',
            date: date,
            amount: cents,
            currency: currency,
            description: 'Synthetic shop',
            manual: manual,
            transferTo: transferTo,
            deleted: deleted),
        category,
        kindOf(category));

final _t = CategoryTable.builtIn;

/// A Lidl card payment: the built-in rules make it Groceries.
NormalizedTransaction lidl(String date, int cents, {int occ = 0}) =>
    n(date, cents, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', occ: occ);

void main() {
  group('planAutoPaid (pure)', () {
    test('exactly one fitting row closes the cost', () {
      expect(planAutoPaid([pc('p1', '2026-03-10', 4500)], [row('t1', '2026-03-12', -4500)], table: _t), [('p1', 't1')]);
    });

    test('the date window is ±3 days inclusive', () {
      for (final (d, ok) in [('2026-03-07', true), ('2026-03-13', true), ('2026-03-06', false), ('2026-03-14', false)]) {
        expect(planAutoPaid([pc('p1', '2026-03-10', 4500)], [row('t1', d, -4500)], table: _t), ok ? [('p1', 't1')] : isEmpty, reason: d);
      }
    });

    test('two fitting rows: ambiguous, nothing closes', () {
      expect(planAutoPaid([pc('p1', '2026-03-10', 4500)], [row('t1', '2026-03-09', -4500), row('t2', '2026-03-11', -4500)], table: _t),
          isEmpty);
    });

    test('never by amount alone: another category, another amount, an income, or no category', () {
      expect(planAutoPaid([pc('p1', '2026-03-10', 4500)], [row('t1', '2026-03-10', -4500, category: 'Shopping')], table: _t), isEmpty);
      expect(planAutoPaid([pc('p1', '2026-03-10', 4500)], [row('t1', '2026-03-10', -4501)], table: _t), isEmpty);
      expect(planAutoPaid([pc('p1', '2026-03-10', 4500)], [row('t1', '2026-03-10', 4500)], table: _t), isEmpty);
      expect(planAutoPaid([pc('p1', '2026-03-10', 4500, category: null)], [row('t1', '2026-03-10', -4500)], table: _t), isEmpty);
      expect(planAutoPaid([pc('p1', '2026-03-10', null)], [row('t1', '2026-03-10', -4500)], table: _t), isEmpty);
    });

    test('hand-added, own transfer and deleted rows never count, and do not make it ambiguous', () {
      final others = [
        row('m1', '2026-03-10', -4500, manual: true),
        row('x1', '2026-03-10', -4500, transferTo: 'x2'),
        row('d1', '2026-03-10', -4500, deleted: true),
      ];
      expect(planAutoPaid([pc('p1', '2026-03-10', 4500)], others, table: _t), isEmpty);
      expect(planAutoPaid([pc('p1', '2026-03-10', 4500)], [...others, row('t1', '2026-03-10', -4500)], table: _t), [('p1', 't1')]);
    });

    test("a row already another planned cost's paid row is not used", () {
      final paid = pc('p0', '2026-03-09', 4500, paidTx: 't1');
      expect(planAutoPaid([paid, pc('p1', '2026-03-10', 4500)], [row('t1', '2026-03-10', -4500)], table: _t), isEmpty);
    });

    test('a row in auto_off (the owner reopened it from that row) is never picked again', () {
      final p = pc('p1', '2026-03-10', 4500, autoOff: {'t1'});
      expect(planAutoPaid([p], [row('t1', '2026-03-10', -4500)], table: _t), isEmpty);
      expect(planAutoPaid([p], [row('t1', '2026-03-10', -4500), row('t2', '2026-03-11', -4500)], table: _t), [('p1', 't2')]);
    });

    test('one row fitting two costs closes neither', () {
      expect(
          planAutoPaid([pc('p1', '2026-03-10', 4500), pc('p2', '2026-03-11', 4500)], [row('t1', '2026-03-10', -4500)], table: _t), isEmpty);
    });

    test('closed, deleted and bill rows are left alone', () {
      const skipped =
          PlannedCost(id: 'p1', title: 's', date: '2026-03-10', amount: 4500, category: 'Groceries', status: PlannedStatus.skipped);
      const deleted = PlannedCost(id: 'p2', title: 'd', date: '2026-03-10', amount: 4500, category: 'Groceries', deleted: true);
      final bill = pc('p3', '2026-03-10', 4500, source: PlannedSource.bill);
      expect(planAutoPaid([skipped, deleted, bill], [row('t1', '2026-03-10', -4500)], table: _t), isEmpty);
    });

    test('a split part is never a payment for it', () {
      final whole = row('t1', '2026-03-10', -4500);
      final part = CategorizedTx(whole.tx, 'Groceries', BudgetKind.flex, amount: -4500, part: 0, parts: 2);
      expect(planAutoPaid([pc('p1', '2026-03-10', 4500)], [part], table: _t), isEmpty);
    });
  });

  group('WalletRepo auto-Paid', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory(now: () => DateTime.utc(2026, 3, 12, 10).millisecondsSinceEpoch));
    tearDown(() => r.close());

    String txOf(NormalizedTransaction t) => t.id;

    test('an import closes the cost, lists it for the toast, and the Undo reopens it for good', () {
      final p = r.addPlanned(title: 'Synthetic party food', date: '2026-03-10', amount: 4500, category: 'Groceries');
      final bank = lidl('2026-03-11', -4500);
      r.importBatch(ImportBatch(source: 'pbz', transactions: [bank]));
      final row = r.plannedCosts(includeClosed: true).single;
      expect((row.status, row.paidTx), (PlannedStatus.paid, txOf(bank)));
      expect(r.autoPaidPlanned(), [AutoPaid(plannedId: p, txId: txOf(bank), title: 'Synthetic party food')]);

      r.reopenPlanned(p);
      final open = r.plannedCosts(includeClosed: true).single;
      expect((open.status, open.paidTx), (PlannedStatus.open, null));
      expect(open.autoOff, {txOf(bank)});
      expect(r.autoPaidPlanned(), isEmpty, reason: 'the Undo acknowledges it');
      // Another import (any reconcile) never closes it with the same row again.
      r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-03-12', -100, 'POS plaćanje', 'Synthetic kiosk')]));
      expect(r.plannedCosts(includeClosed: true).single.status, PlannedStatus.open);
      // The owner can still pick it by hand.
      r.markPlannedPaid(p, txOf(bank));
      expect(r.plannedCosts(includeClosed: true).single.paidTx, txOf(bank));
    });

    test('two fitting rows: nothing closes (the owner gets "Paid by this?")', () {
      r.addPlanned(title: 'Synthetic food', date: '2026-03-10', amount: 4500, category: 'Groceries');
      r.importBatch(ImportBatch(source: 'pbz', transactions: [lidl('2026-03-09', -4500), lidl('2026-03-11', -4500)]));
      expect(r.plannedCosts(includeClosed: true).single.status, PlannedStatus.open);
      expect(r.autoPaidPlanned(), isEmpty);
    });

    test('a row in another currency, a hand-added row or a bill payment never closes it', () {
      r.addPlanned(title: 'Synthetic food', date: '2026-03-10', amount: 4500, category: 'Groceries');
      r.addTransaction(date: '2026-03-10', amount: -4500, category: 'Groceries', note: 'cash');
      final usd = NormalizedTransaction(
          id: transactionId('2026-03-10', -4500, 'Synthetic usd shop LIDL', 0),
          source: 'revolut',
          date: '2026-03-10',
          amountMinor: -4500,
          currency: 'USD',
          bankType: 'CARD_PAYMENT',
          description: 'LIDL Synthetic');
      r.importBatch(ImportBatch(source: 'revolut', transactions: [usd]));
      expect(r.plannedCosts(includeClosed: true).single.status, PlannedStatus.open);
    });

    test('while not caught up nothing closes; the next caught-up run does it', () {
      r.addPlanned(title: 'Synthetic food', date: '2026-03-10', amount: 4500, category: 'Groceries');
      r.setLocalValue(WalletRepo.caughtUpKey, '0');
      r.importBatch(ImportBatch(source: 'pbz', transactions: [lidl('2026-03-10', -4500)]));
      expect(r.plannedCosts(includeClosed: true).single.status, PlannedStatus.open);
      r.setLocalValue(WalletRepo.caughtUpKey, '1');
      r.runPendingMatch();
      expect(r.plannedCosts(includeClosed: true).single.status, PlannedStatus.paid);
    });

    test('ack removes entries; the list keeps the newest 50', () {
      for (var i = 0; i < 52; i++) {
        final d = '2026-0${3 + i ~/ 28}-${(1 + i % 28).toString().padLeft(2, '0')}';
        r.addPlanned(title: 'Synthetic $i', date: d, amount: 1000 + i, category: 'Groceries');
        r.importBatch(ImportBatch(source: 'pbz', transactions: [lidl(d, -(1000 + i))]));
      }
      final l = r.autoPaidPlanned();
      expect(l, hasLength(50));
      expect(l.first.title, 'Synthetic 2');
      r.ackAutoPaidPlanned([l.first.plannedId, 'unknown']);
      expect(r.autoPaidPlanned(), hasLength(49));
      r.ackAutoPaidPlanned(const []);
      expect(r.autoPaidPlanned(), hasLength(49));
    });

    test('logs carry counts only', () {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
      addTearDown(() {
        sub.cancel();
        Logger.root.level = was;
      });
      r.addPlanned(title: 'Synthetic secret title', date: '2026-03-10', amount: 4500, category: 'Groceries');
      r.importBatch(ImportBatch(source: 'pbz', transactions: [lidl('2026-03-10', -4500)]));
      final text = lines.join('\n');
      expect(text, contains('planned.autoPaid'));
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('4500')));
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    var now = 0;
    final devices = <Device>[];

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> round(Net net) async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-kl1-');
      key = VaultKey.generate();
      devices.clear();
      now = DateTime.utc(2026, 3, 12, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    test('A closes it on import; B sees it paid, no toast on B; an Undo on B holds on A', () async {
      final net = Net();
      final a = device('a'), b = device('b');
      final p = b.repo.addPlanned(title: 'Synthetic food', date: '2026-03-10', amount: 4500, category: 'Groceries');
      await round(net);
      await round(net);
      final bank = lidl('2026-03-10', -4500);
      a.repo.importBatch(ImportBatch(source: 'pbz', transactions: [bank]));
      expect(a.repo.autoPaidPlanned().map((x) => x.plannedId), [p]);
      await round(net);
      await round(net);
      for (final d in [a, b]) {
        expect(d.repo.plannedCosts(includeClosed: true).single.paidTx, bank.id, reason: d.name);
      }
      expect(b.repo.autoPaidPlanned(), isEmpty, reason: 'the toast belongs to the device that closed it');
      b.repo.reopenPlanned(p);
      await round(net);
      await round(net);
      for (final d in [a, b]) {
        final row = d.repo.plannedCosts(includeClosed: true).single;
        expect(row.status, PlannedStatus.open, reason: d.name);
        expect(row.autoOff, {bank.id}, reason: d.name);
      }
      expect(a.repo.autoPaidPlanned(), isEmpty, reason: 'no longer paid by that row');
    });
  });
}
