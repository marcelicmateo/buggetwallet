// Stage B review fixes, core half (B5a, docs/context/BILLS_API.md "Decisions B5a"): one reproducing test per bug.
// SYNTHETIC data only: made-up payees, references and amounts.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const today = '2026-03-01';
final noon = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;

NormalizedBill slip({
  String? ext = 'hub3:HR00TEST:HR01 1234-5678:4599:SYNTH 02/2026',
  String? date = '2026-02-27',
  String? due = '2026-03-10',
  int? total = 4599,
  String? payee = 'Synth Energy',
  String? reference = 'HR01 1234-5678',
}) =>
    NormalizedBill(source: BillSource.hub3, externalId: ext, date: date, dueDate: due, total: total, payee: payee, reference: reference);

ImportBatch rows(List<NormalizedTransaction> t) => ImportBatch(source: 'pbz', transactions: t);

/// Three monthly payments to SYNTH ENERGY: a recurring candidate `rec:synth_energy`, next due 2026-03-05.
final energyHistory = [
  n('2025-12-05', -4500, 'Nalog', 'SYNTH ENERGY'),
  n('2026-01-04', -4600, 'Nalog', 'SYNTH ENERGY'),
  n('2026-02-03', -4550, 'Nalog', 'SYNTH ENERGY'),
];

Uint8List bytes(int n, [int seed = 7]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late WalletRepo repo;
  var now = noon;
  setUp(() {
    now = noon;
    repo = WalletRepo.inMemory(now: () => now);
  });
  tearDown(() => repo.close());

  PlannedCost? plannedOf(WalletRepo r, String billId) {
    for (final p in r.plannedCosts(includeClosed: true)) {
      if (p.id == WalletRepo.billPlannedId(billId)) return p;
    }
    return null;
  }

  PeriodBudget period(WalletRepo r) => computePeriod([for (final t in r.transactions()) r.categorizer().categorize(t)],
      const WalletSettings(salary: 100000, paydayDay: 15, periodStart: '2026-02-15'), const [], today,
      bills: r.recurringBills(), planned: r.plannedCosts(), table: CategoryTable.builtIn);

  group('1. double reserve: a bill that reserves needs a category', () {
    test('B5a bug: confirmBill without a category on an unpaid bill due from today on is refused', () {
      final (id, _) = repo.importBill(slip());
      expect(() => repo.confirmBill(id), throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('category'))));
      expect(repo.bill(id)!.confirmed, isFalse);
      expect(plannedOf(repo, id), isNull);
    });

    test('a slip in a fixed category is in the payday plan already: planned row listed, never reserved twice', () {
      final (id, _) = repo.importBill(slip());
      repo.updateBill(id, category: 'Bills & subscriptions');
      repo.confirmBill(id);
      final p = plannedOf(repo, id)!;
      expect((p.category, p.coveredByPlan, p.isOpen), ('Bills & subscriptions', true, true));
      final b = period(repo);
      expect(b.reservedPlanned, 0);
      expect(b.duePlanned.map((p) => p.id), [WalletRepo.billPlannedId(id)]);
    });

    test('a slip in a flex category reserves its total', () {
      final (id, _) = repo.importBill(slip());
      repo.updateBill(id, category: 'Bills & one-offs');
      repo.confirmBill(id);
      expect(period(repo).reservedPlanned, 4599);
    });

    test('no category needed when nothing would be reserved: due date past or none, or already paid', () {
      final (past, _) = repo.importBill(slip(ext: 'jir:past', due: '2026-02-28'));
      repo.confirmBill(past);
      final (none, _) = repo.importBill(slip(ext: 'jir:none', due: null));
      repo.confirmBill(none);
      final (paid, _) = repo.importBill(slip(ext: 'jir:paid'));
      repo.addExpenseFromBill(paid, category: 'Groceries');
      repo.confirmBill(paid);
      expect([
        for (final id in [past, none, paid]) repo.bill(id)!.confirmed
      ], [
        true,
        true,
        true
      ]);
    });

    test('updates that leave a reserving bill without a category are refused; others pass', () {
      final (id, _) = repo.importBill(slip(due: null));
      repo.confirmBill(id);
      // Giving a due date from today on makes it reserve: needs a category.
      expect(() => repo.updateBill(id, dueDate: '2026-03-10'), throwsArgumentError);
      repo.updateBill(id, dueDate: '2026-03-10', category: 'Bills & one-offs');
      expect(() => repo.updateBill(id, clearCategory: true), throwsArgumentError);
      expect(repo.bill(id)!.category, 'Bills & one-offs');
      repo.updateBill(id, note: 'synthetic note');
      // A bill in review never needs one yet.
      final (r, _) = repo.importBill(slip(ext: 'jir:review'));
      repo.updateBill(r, note: 'x');
      expect(repo.bill(r)!.category, isNull);
    });
  });

  group('1. suggestBillCategory', () {
    CategorizedTx ct(String id, String date, int amount, String desc, String category,
            {BudgetKind kind = BudgetKind.flex, bool manual = false, String? transferTo}) =>
        CategorizedTx(
            Tx(
                id: id,
                source: manual ? 'manual' : 'pbz',
                date: date,
                amount: amount,
                description: desc,
                manual: manual,
                transferTo: transferTo),
            category,
            kind);
    const rec = RecurringBill(
        id: 'rec:synth_energy',
        payee: 'synth_energy',
        label: 'SYNTH ENERGY',
        category: 'Bills & subscriptions',
        expectedAmount: 4599,
        nextDue: '2026-03-05',
        status: 'confirmed');
    const bill = Bill(id: 'b1', payee: 'Synth Energy', total: 4599, date: '2026-02-27', dueDate: '2026-03-10');

    test('a confirmed recurring bill with the same payee key gives its category', () {
      expect(billPayeeKey(bill), 'synth_energy');
      expect(suggestBillCategory(bill, recurring: const [rec], txs: const []), 'Bills & subscriptions');
      // A candidate (not confirmed) is not used.
      final cand = RecurringBill(
          id: rec.id,
          payee: rec.payee,
          label: rec.label,
          category: 'Shopping',
          expectedAmount: 1,
          nextDue: rec.nextDue,
          status: 'candidate');
      expect(suggestBillCategory(bill, recurring: [cand], txs: const []), isNull);
    });

    test('else the latest live bank expense naming the payee; never hand-added, transfers or income', () {
      final txs = [
        ct('t1', '2026-01-10', -4000, 'SYNTH ENERGY ZAGREB', 'Home & tools'),
        ct('t2', '2026-02-10', -4100, 'NALOG SYNTH ENERGY', 'Bills & one-offs'),
        ct('t3', '2026-02-20', -4599, 'Synth energy cash', 'Shopping', manual: true),
        ct('t4', '2026-02-21', -4599, 'SYNTH ENERGY', 'Internal transfer', kind: BudgetKind.transfer, transferTo: 'x'),
        ct('t5', '2026-02-22', 4599, 'SYNTH ENERGY REFUND', 'Extra income', kind: BudgetKind.extra),
      ];
      expect(suggestBillCategory(bill, recurring: const [], txs: txs), 'Bills & one-offs');
    });

    test('never by amount: an equal amount at another payee suggests nothing', () {
      final txs = [ct('t1', '2026-02-10', -4599, 'OTHER SHOP', 'Shopping')];
      expect(suggestBillCategory(bill, recurring: const [], txs: txs), isNull);
      expect(suggestBillCategory(const Bill(id: 'np', total: 4599), recurring: const [rec], txs: txs), isNull);
    });
  });

  group('1. a slip a confirmed recurring bill already plans is not reserved twice', () {
    test('billCoveredBy: same payee key, due within ± 3 days of a cycle (the one before nextDue too); never by amount', () {
      const rec = RecurringBill(
          id: 'rec:synth_energy',
          payee: 'synth_energy',
          label: 'SYNTH ENERGY',
          category: 'Bills & one-offs',
          expectedAmount: 4599,
          nextDue: '2026-03-05',
          status: 'confirmed');
      Bill due(String d, {String payee = 'Synth Energy'}) => Bill(id: 'b', payee: payee, total: 1, dueDate: d);
      for (final d in ['2026-03-02', '2026-03-05', '2026-03-08', '2026-04-04', '2026-02-03', '2026-02-01']) {
        expect(billCoveredBy(due(d), const [rec]), rec, reason: d);
      }
      for (final d in ['2026-03-09', '2026-03-01', '2026-01-04', '2026-02-07']) {
        expect(billCoveredBy(due(d), const [rec]), isNull, reason: d);
      }
      expect(billCoveredBy(due('2026-03-05', payee: 'Synth Energy Zagreb'), const [rec]), isNull);
      // A bill's planned row: payee = its title, due = its date; other planned costs never.
      const row = PlannedCost(id: 'bill:b', title: 'Synth Energy', date: '2026-03-06', amount: 1, source: PlannedSource.bill);
      expect(plannedCoveredBy(row, const [rec]), rec);
      const manual = PlannedCost(id: 'p1', title: 'Synth Energy', date: '2026-03-06', amount: 1);
      expect(plannedCoveredBy(manual, const [rec]), isNull);
      const untitled = PlannedCost(id: 'bill:c', title: 'Bill', date: '2026-03-06', amount: 1, source: PlannedSource.bill);
      expect(plannedCoveredBy(untitled, const [rec]), isNull);
      final candidate =
          RecurringBill(id: rec.id, payee: rec.payee, label: rec.label, category: rec.category, expectedAmount: 4599, nextDue: rec.nextDue);
      expect(billCoveredBy(due('2026-03-05'), [candidate]), isNull);
    });

    test('recurring bill confirmed first, then the slip: reserved once, listed once', () {
      repo.importBatch(rows(energyHistory));
      final rec = repo.recurringBills().single;
      expect((rec.payee, rec.nextDue), ('synth_energy', '2026-03-05'));
      repo.confirmRecurring(rec.id);
      final reservedByRecurring = period(repo);
      final (id, _) = repo.importBill(slip(due: '2026-03-06'));
      repo.updateBill(id, category: 'Bills & one-offs');
      repo.confirmBill(id);
      final p = plannedOf(repo, id)!;
      expect(p.isOpen, isTrue, reason: 'the row is kept; it is only not reserved');
      final after = period(repo);
      expect(after.reservedPlanned, 0);
      expect(after.reservedBills, reservedByRecurring.reservedBills);
      expect(billCoveredBy(repo.bill(id)!, repo.recurringBills())?.id, rec.id);
      expect(plannedCoveredBy(p, repo.recurringBills())?.id, rec.id);
      // Upcoming and the calendar export show the payment once: the recurring bill's occurrence.
      final up = upcoming(planned: repo.plannedCosts(), bills: repo.recurringBills(), events: const [], from: today, to: '2026-03-31');
      expect(up.map((u) => u.kind), [UpcomingKind.bill]);
      final ics = plannedIcs(repo.plannedCosts(), repo.recurringBills(), from: today, to: '2026-03-31');
      expect('BEGIN:VEVENT'.allMatches(ics), hasLength(1));
    });

    test('the slip first, then the recurring bill confirmed: no longer reserved; dismissed: reserved again', () {
      repo.importBatch(rows(energyHistory));
      final rec = repo.recurringBills().single;
      final (id, _) = repo.importBill(slip(due: '2026-03-06'));
      repo.updateBill(id, category: 'Bills & one-offs');
      repo.confirmBill(id);
      expect(plannedOf(repo, id)!.isOpen, isTrue);
      repo.confirmRecurring(rec.id);
      expect(period(repo).reservedPlanned, 0);
      repo.dismissRecurring(rec.id);
      expect(plannedOf(repo, id)!.isOpen, isTrue);
      expect(period(repo).reservedPlanned, 4599);
    });

    test('the recurring cycle paid by its bank row: the slip for that cycle stays unreserved', () {
      repo.importBatch(rows(energyHistory));
      final rec = repo.recurringBills().single;
      repo.confirmRecurring(rec.id);
      final (id, _) = repo.importBill(slip(due: '2026-03-05'));
      repo.updateBill(id, category: 'Bills & one-offs');
      repo.confirmBill(id);
      // The bank pays the cycle on 03-02 without the slip's reference: the recurring bill moves on to 04-01.
      repo.importBatch(rows([n('2026-03-02', -4599, 'Nalog', 'SYNTH ENERGY')]));
      expect(repo.recurringBills().single.nextDue, '2026-04-01');
      expect(period(repo).reservedPlanned, 0);
    });
  });

  group('2. asNew: a slip that reads like a stored one is kept as a new bill on request', () {
    test('B5a bug: the same external id again is one bill, unless asNew', () {
      final (a, newA) = repo.importBill(slip());
      final (b, newB) = repo.importBill(slip());
      expect((b, newB), (a, false));
      final (c, newC) = repo.importBill(slip(date: '2026-03-27', due: '2026-04-10'), asNew: true);
      expect(newC, isTrue);
      expect(c, Bill.idFor('${slip().externalId}#1'));
      expect(repo.bill(c)!.dueDate, '2026-04-10');
      expect(repo.bill(a)!.dueDate, '2026-03-10', reason: 'the first bill is untouched');
      final (d, _) = repo.importBill(slip(), asNew: true);
      expect(d, Bill.idFor('${slip().externalId}#2'));
      expect(repo.bills(), hasLength(3));
      expect(newA, isTrue);
      // A deleted copy is the first free number again (revived as a new review bill).
      repo.deleteBill(c);
      final (e, newE) = repo.importBill(slip(), asNew: true);
      expect((e, newE), (c, true));
      expect(repo.bill(e)!.deleted, isFalse);
    });

    test('asNew with nothing stored under that id is a plain import', () {
      final (a, isNew) = repo.importBill(slip(), asNew: true);
      expect((a, isNew), (Bill.idFor(slip().externalId!), true));
      final (m, _) = repo.importBill(slip(ext: null), asNew: true);
      expect(m, isNot(startsWith('bill:')));
    });
  });

  group('4. short invoice tokens', () {
    test('B5a bug: digits-only invoice numbers need 6 digits (no card mask or year matches)', () {
      expect(billLinkTokens(const Bill(id: 'a', externalId: 'inv:SUP:1234')), isEmpty);
      expect(billLinkTokens(const Bill(id: 'a', externalId: 'inv:SUP:2026')), isEmpty);
      expect(billLinkTokens(const Bill(id: 'a', externalId: 'inv:SUP:12345')), isEmpty);
      expect(billLinkTokens(const Bill(id: 'a', externalId: 'inv:SUP:123456')), ['123456']);
      const card = Bill(id: 'c', status: BillStatus.confirmed, externalId: 'inv:SUP:1234', date: '2026-02-27', total: 4599);
      const year = Bill(id: 'y', status: BillStatus.confirmed, externalId: 'inv:SUP:2026', date: '2026-02-27', total: 1200);
      const txs = [
        Tx(id: 't1', source: 'pbz', date: '2026-03-01', amount: -4599, description: 'KARTICA ****1234 SYNTH SHOP'),
        Tx(id: 't2', source: 'pbz', date: '2026-03-01', amount: -1200, description: 'PRETPLATA 2026'),
      ];
      expect(planBillLinks([card, year], txs), isEmpty);
    });

    test('mixed invoice numbers: 4+ characters with a letter and a digit; letters alone never', () {
      expect(billLinkTokens(const Bill(id: 'a', externalId: 'inv:SUP:R-12')), isEmpty);
      expect(billLinkTokens(const Bill(id: 'a', externalId: 'inv:SUP:R-123')), ['R123']);
      expect(billLinkTokens(const Bill(id: 'a', externalId: 'inv:SUP:RACUN')), isEmpty);
      const b = Bill(id: 'm', status: BillStatus.confirmed, externalId: 'inv:SUP:R-123', date: '2026-02-27', total: 900);
      const t = Tx(id: 't', source: 'pbz', date: '2026-03-01', amount: -900, description: 'PLACANJE R123');
      expect(planBillLinks([b], [t]), {'m': 't'});
    });
  });

  group('6. billCandidates', () {
    test('B5a bug: own transfers are never "Paid by this?" candidates', () {
      const b = Bill(id: 'b', payee: 'Synth Energy', date: '2026-02-27', total: 4599);
      const txs = [
        CategorizedTx(Tx(id: 'pay', source: 'pbz', date: '2026-03-01', amount: -4599, description: 'SYNTH ENERGY'), 'Bills & one-offs',
            BudgetKind.flex),
        CategorizedTx(Tx(id: 'tr', source: 'pbz', date: '2026-03-01', amount: -4599, description: 'SYNTH ENERGY', transferTo: 'r'),
            'Internal transfer', BudgetKind.transfer),
        CategorizedTx(Tx(id: 'cat', source: 'pbz', date: '2026-03-01', amount: -4599, description: 'TOP-UP', category: 'Internal transfer'),
            'Internal transfer', BudgetKind.transfer),
      ];
      expect(billCandidates(b, txs, const []).map((t) => t.tx.id), ['pay']);
    });
  });

  group('SyncReport.blobsUnsupported', () {
    late VaultKey key;
    late MemoryTransport relay;
    setUp(() {
      key = VaultKey.generate();
      relay = MemoryTransport();
    });
    Future<SyncReport> run() => SyncEngine(relay, key).run(repo);

    test('a new wallet on a relay with blob storage: the first 404 is expected, the retry stores it', () async {
      final ref = await BlobStore(repo, key).add(bytes(1000, 11), 'jpg');
      repo.importBill(slip(), file: ref);
      final r = await run();
      expect((r.blobsSent, r.blobsUnsupported), (1, false));
      expect(relay.blobs.keys, [ref.hash]);
    });

    test('an older relay (no blob routes): true on the first run (retry refused too) and on later runs', () async {
      relay.blobRoutes = false;
      final ref = await BlobStore(repo, key).add(bytes(1000, 12), 'jpg');
      repo.importBill(slip(), file: ref);
      final first = await run();
      expect((first.blobsSent, first.blobsWaiting, first.blobsUnsupported), (0, 1, true));
      now += 1000;
      final later = await run();
      expect(later.blobsUnsupported, isTrue);
      // The relay is updated: the file goes, the flag clears.
      relay.blobRoutes = true;
      now += 1000;
      final updated = await run();
      expect((updated.blobsSent, updated.blobsWaiting, updated.blobsUnsupported), (1, 0, false));
    });

    test('nothing queued: never true, whatever the relay', () async {
      relay.blobRoutes = false;
      repo.addTransaction(date: today, amount: 100, category: 'Groceries');
      expect((await run()).blobsUnsupported, isFalse);
      now += 1000;
      expect((await run()).blobsUnsupported, isFalse);
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    final devices = <Device>[];
    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> round() async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-b5a-');
      key = VaultKey.generate();
      net = Net();
      devices.clear();
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    test('3. B5a bug: a payment deleted on one device while the other linked it: unpaid on both', () async {
      final a = device('a'), b = device('b');
      final (id, _) = a.repo.importBill(slip(reference: null));
      a.repo.updateBill(id, category: 'Bills & one-offs');
      a.repo.confirmBill(id);
      a.repo.importBatch(rows([n('2026-03-02', -4599, 'Nalog', 'SYNTH ENERGY')]));
      await round();
      await round();
      final txId = b.repo.transactions().single.id;
      // At the same time: a links the payment, b deletes that row (b does not know the link yet).
      a.repo.linkBill(id, txId);
      b.repo.deleteTransaction(txId);
      expect(b.repo.bill(id)!.paid, isFalse);
      for (var i = 0; i < 3; i++) {
        await round();
      }
      for (final d in [a, b]) {
        expect(d.repo.bill(id)!.paid, isFalse, reason: d.name);
        expect(plannedOf(d.repo, id)!.isOpen, isTrue, reason: '${d.name}: reserved again');
      }
      expect(dump(a.repo, clocks: false)['bills'], dump(b.repo, clocks: false)['bills']);
      expect(dump(a.repo, clocks: false)['planned'], dump(b.repo, clocks: false)['planned']);
    });

    test('5. B5a bug: the same bill with a file on both devices: the losing file is deleted on the relay', () async {
      final a = device('a'), b = device('b');
      final fa = await BlobStore(a.repo, key).add(bytes(3000, 1), 'jpg');
      final (id, _) = a.repo.importBill(slip(), file: fa);
      now += 1000;
      final fb = await BlobStore(b.repo, key).add(bytes(3000, 2), 'jpg');
      b.repo.importBill(slip(), file: fb);
      for (var i = 0; i < 4; i++) {
        await round();
      }
      final winner = a.repo.bill(id)!.blob;
      expect(b.repo.bill(id)!.blob, winner);
      expect(net.relay.blobs.keys, [winner], reason: 'the other file is not left on the relay');
      for (final d in [a, b]) {
        expect(d.repo.queuedBlobs(), isEmpty);
        expect(d.repo.blobDeletes(), isEmpty);
      }
    });

    test('5. B5a bug: a bill deleted elsewhere before it knew the file: the file goes from the relay', () async {
      final a = device('a'), b = device('b');
      b.repo.importBill(slip());
      await round();
      final ref = await BlobStore(a.repo, key).add(bytes(3000, 3), 'pdf');
      final (id, _) = a.repo.importBill(slip(), file: ref);
      expect(a.repo.bill(id)!.blob, ref.hash);
      b.repo.deleteBill(id); // b never saw the file
      for (var i = 0; i < 4; i++) {
        await round();
      }
      expect(a.repo.bill(id)!.deleted, isTrue);
      expect(net.relay.blobs, isEmpty);
      expect(a.repo.queuedBlobs(), isEmpty);
      expect(a.repo.cachedBlob(ref.hash), isNull);
    });

    test('5. a queued upload whose bill was deleted elsewhere is never sent', () async {
      final a = device('a'), b = device('b');
      b.repo.importBill(slip());
      await round();
      net.relay.blobRoutes = false; // a's upload is refused, so it stays queued
      final ref = await BlobStore(a.repo, key).add(bytes(3000, 4), 'pdf');
      final (id, _) = a.repo.importBill(slip(), file: ref);
      b.repo.deleteBill(id);
      await round();
      await round();
      net.relay.blobRoutes = true;
      expect(a.repo.queuedBlobs(), isEmpty, reason: 'dropped once the delete arrived');
      await round();
      expect(net.relay.blobs, isEmpty);
      expect(a.repo.blobDeletes(), isEmpty);
    });

    test('5. a file added but not yet attached to a bill is never dropped', () async {
      final a = device('a');
      a.repo.addTransaction(date: today, amount: 100, category: 'Groceries'); // the relay keeps files of a known wallet only
      final ref = await BlobStore(a.repo, key).add(bytes(2000, 5), 'jpg');
      expect(a.repo.dropOrphanBlobs(), 0);
      expect(a.repo.queuedBlobs(), [ref.hash]);
      await round();
      expect(net.relay.blobs.keys, [ref.hash]);
      expect(a.repo.dropOrphanBlobs(), 0);
      expect(a.repo.blobDeletes(), isEmpty);
    });
  });
}
