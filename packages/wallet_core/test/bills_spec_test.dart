// Spec tests for the bills database in the repo (docs/context/BILLS_API.md §2, §3, §5; DESIGN_DECISIONS §4.2), written
// from the spec only. All data is SYNTHETIC. `// SPEC:` marks a reading of an ambiguous spec line (stricter one tested).
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/bill_helpers.dart';
import 'support/sim.dart';
import 'support/synthetic.dart';

// A Croatian IBAN with a valid checksum (computed by hand for the synthetic body 23600001101234565).
String _iban() {
  final n = BigInt.parse('23600001101234565172700');
  final c = 98 - (n % BigInt.from(97)).toInt();
  return 'HR${c.toString().padLeft(2, '0')}23600001101234565';
}

final theIban = _iban();
const ref = 'HR01 5555-1234'; // digits 0155551234
const payee = 'Test Elektra d.o.o.';
const total = 13579;

NormalizedBill nb({
  String? externalId = 'hub3:X:HR01 5555-1234:13579',
  String? date = '2026-02-25',
  String? dueDate = '2026-03-10',
  int? tot = total,
  String? payeeName = payee,
  String? reference = ref,
  String? description = 'Racun za struju 02/2026',
  List<BillItem> items = const [],
  BillSource source = BillSource.hub3,
}) =>
    NormalizedBill(
      source: source,
      externalId: externalId,
      date: date,
      dueDate: dueDate,
      payee: payeeName,
      iban: theIban,
      reference: reference,
      description: description,
      total: tot,
      items: items,
    );

/// Log lines written while [body] runs.
List<String> logsOf(void Function() body) {
  final sink = MemoryLogSink();
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((r) => sink.add(formatLogRecord(r)));
  try {
    body();
  } finally {
    sub.cancel();
    Logger.root.level = was;
  }
  return sink.lines;
}

var _seq = 0;
CategorizedTx row(String date, int cents, String desc, {String category = 'Shopping', bool deleted = false}) => CategorizedTx(
    Tx(id: 'syn-${_seq++}', source: 'pbz', date: date, amount: cents, bankType: 'POS plaćanje', description: desc, deleted: deleted),
    category,
    kindOf(category));

void main() {
  var now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch; // today = 2026-03-01
  late WalletRepo repo;
  final extra = <WalletRepo>[];
  WalletRepo mk() {
    final r = WalletRepo.inMemory(now: () => now);
    extra.add(r);
    return r;
  }

  setUp(() {
    now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
    repo = mk();
  });
  tearDown(() {
    for (final r in extra) {
      r.close();
    }
    extra.clear();
  });

  final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
  int reserved(WalletRepo r) => computePeriod(const [], st, const [], '2026-03-01', planned: r.plannedCosts()).reservedPlanned;
  List<PlannedCost> billRows(WalletRepo r, [String? billId]) => [
        for (final p in r.plannedCosts(includeClosed: true))
          if (p.source == PlannedSource.bill && (billId == null || p.sourceRef == billId)) p
      ];
  Bill only(WalletRepo r) => r.bills().single;

  String bankRow(WalletRepo r, String date, int cents, String desc, {int occ = 0}) {
    final t = n(date, cents, 'POS plaćanje', desc, occ: occ);
    r.importBatch(ImportBatch(source: 'pbz', transactions: [t]));
    return t.id;
  }

  group('importBill', () {
    test('a new bill is in review; the id is bill:<32 hex> from the externalId', () {
      final (id, isNew) = repo.importBill(nb());
      expect(isNew, isTrue);
      expect(id, matches(RegExp(r'^bill:[0-9a-f]{32}$')));
      final b = only(repo);
      expect(b.id, id);
      expect(b.status, BillStatus.review);
      expect(b.total, total);
      expect(b.payee, payee);
      expect(b.dueDate, '2026-03-10');
      expect(b.linkedTx, isNull);
      expect(b.paid, isFalse);
      expect(b.deleted, isFalse);
      expect(b.currency, 'EUR');
      // The same id on another wallet that never talked to this one (devices converge per bill).
      expect(mk().importBill(nb()).$1, id);
      expect(mk().importBill(nb(externalId: 'hub3:X:HR01 5555-1234:13580')).$1, isNot(id));
    });

    test('a bill without externalId gets a random id starting with b, different each time', () {
      final (a, _) = repo.importBill(nb(externalId: null));
      final (b, _) = repo.importBill(nb(externalId: null));
      expect(a, startsWith('b'));
      expect(a, isNot(b));
      expect(repo.bills(), hasLength(2));
    });

    test('items are kept in order', () {
      repo.importBill(nb(items: const [BillItem(name: 'Widget', quantity: '2', amount: 1000), BillItem(name: 'Gadget', amount: 235)]));
      expect(only(repo).items, const [BillItem(name: 'Widget', quantity: '2', amount: 1000), BillItem(name: 'Gadget', amount: 235)]);
    });

    test('same externalId again: same id, isNew false, still one bill', () {
      final (id, _) = repo.importBill(nb());
      final (id2, isNew) = repo.importBill(nb());
      expect(id2, id);
      expect(isNew, isFalse);
      expect(repo.bills(), hasLength(1));
    });

    test('re-import fills only empty fields, never overwrites a value', () {
      final (id, _) = repo.importBill(nb(date: null, dueDate: null, tot: null, description: null));
      repo.importBill(nb(payeeName: 'Other Payee', date: '2026-02-26', dueDate: '2026-03-12', tot: 999, description: 'Later'));
      final b = only(repo);
      expect(b.id, id);
      expect(b.payee, payee, reason: 'had a value');
      expect(b.date, '2026-02-26');
      expect(b.dueDate, '2026-03-12');
      expect(b.total, 999);
      expect(b.description, 'Later');
      repo.importBill(nb(date: '2026-01-01', tot: 1, dueDate: '2026-01-02'));
      expect((only(repo).date, only(repo).total, only(repo).dueDate), ('2026-02-26', 999, '2026-03-12'));
    });

    test('a confirmed bill is never overwritten by a re-import (also not its empty-looking fields)', () {
      final (id, _) = repo.importBill(nb());
      repo.confirmWithCategory(id);
      repo.importBill(nb(payeeName: 'Other Payee', tot: 1, date: '2026-01-01', dueDate: '2026-01-02', description: 'Else'));
      final b = only(repo);
      expect(b.status, BillStatus.confirmed);
      expect((b.payee, b.total, b.date, b.dueDate, b.description), (payee, total, '2026-02-25', '2026-03-10', 'Racun za struju 02/2026'));
    });

    test('a re-import never changes the status back or the link', () {
      final (id, _) = repo.importBill(nb());
      repo.confirmWithCategory(id);
      final tx = bankRow(repo, '2026-03-02', -total, 'SYNTHETIC SHOP');
      repo.linkBill(id, tx);
      repo.importBill(nb());
      expect(only(repo).status, BillStatus.confirmed);
      expect(only(repo).linkedTx, tx);
    });

    test('two devices import the same bill: one bill with the same id on both after sync', () async {
      final net = Net();
      final key = VaultKey.generate();
      final a = Device('A', null, key, () => now, net: net), b = Device('B', null, key, () => now, net: net);
      addTearDown(a.close);
      addTearDown(b.close);
      final (ia, _) = a.repo.importBill(nb());
      final (ib, _) = b.repo.importBill(nb(payeeName: null));
      expect(ia, ib);
      for (final d in [a, b, a, b]) {
        now += 1000;
        await d.run();
      }
      expect(a.repo.bills(), hasLength(1));
      expect(b.repo.bills(), hasLength(1));
      expect(a.repo.bills().single.payee, b.repo.bills().single.payee);
      expect(a.repo.bills().single.total, total);
      // A later edit on one device reaches the other.
      now += 1000;
      a.repo.updateBill(ia, note: 'synthetic note');
      await a.run();
      await b.run();
      expect(b.repo.bills().single.note, 'synthetic note');
    });
  });

  group('updateBill / confirmBill', () {
    test('confirmBill needs a date and a total above zero', () {
      final (noDate, _) = repo.importBill(nb(externalId: 'a', date: null));
      final (noTotal, _) = repo.importBill(nb(externalId: 'b', tot: null));
      final (zero, _) = repo.importBill(nb(externalId: 'c', tot: 0));
      for (final id in [noDate, noTotal, zero]) {
        expect(() => repo.confirmWithCategory(id), throwsArgumentError);
        expect(repo.bills().singleWhere((b) => b.id == id).status, BillStatus.review);
      }
      repo.updateBill(noDate, date: '2026-02-25');
      repo.updateBill(noTotal, total: 1);
      repo.updateBill(zero, total: 500);
      for (final id in [noDate, noTotal, zero]) {
        repo.confirmWithCategory(id);
        expect(repo.bills().singleWhere((b) => b.id == id).status, BillStatus.confirmed);
      }
    });

    test('a negative total cannot be confirmed', () {
      final (id, _) = repo.importBill(nb(tot: -100));
      expect(() => repo.confirmWithCategory(id), throwsArgumentError);
    });

    test('updateBill sets and clears fields', () {
      final (id, _) = repo.importBill(nb());
      repo.updateBill(id,
          payee: 'New Payee',
          note: 'n',
          category: 'Utilities',
          warrantyUntil: '2027-01-01',
          returnBy: '2026-03-20',
          items: const [BillItem(name: 'x', amount: 5)]);
      var b = only(repo);
      expect((b.payee, b.note, b.category, b.warrantyUntil, b.returnBy), ('New Payee', 'n', 'Utilities', '2027-01-01', '2026-03-20'));
      expect(b.items, const [BillItem(name: 'x', amount: 5)]);
      repo.updateBill(id, clearDueDate: true, clearWarranty: true, clearReturnBy: true, clearCategory: true);
      b = only(repo);
      expect((b.dueDate, b.warrantyUntil, b.returnBy, b.category), (null, null, null, null));
      expect(b.payee, 'New Payee', reason: 'untouched fields stay');
    });

    test('item validation: at most 500 items, names up to 200 characters', () {
      final (id, _) = repo.importBill(nb());
      // SPEC: "validated" is read as: a write that breaks the limits throws ArgumentError and changes nothing.
      expect(() => repo.updateBill(id, items: [for (var i = 0; i < 501; i++) BillItem(name: 'i$i', amount: 1)]), throwsArgumentError);
      expect(() => repo.updateBill(id, items: [BillItem(name: 'x' * 201, amount: 1)]), throwsArgumentError);
      expect(only(repo).items, isEmpty);
      repo.updateBill(id, items: [for (var i = 0; i < 500; i++) BillItem(name: 'x' * 200, amount: 1)]);
      expect(only(repo).items, hasLength(500));
    });

    test('a bad date is refused', () {
      final (id, _) = repo.importBill(nb());
      // SPEC: dates are YYYY-MM-DD strings; others throw ArgumentError.
      expect(() => repo.updateBill(id, date: 'tomorrow'), throwsArgumentError);
      expect(only(repo).date, '2026-02-25');
    });
  });

  group('planned row bill:<id>', () {
    test('confirm with a future due date: one planned row that reserves its total', () {
      final (id, _) = repo.importBill(nb());
      expect(billRows(repo), isEmpty, reason: 'review: nothing is planned');
      expect(reserved(repo), 0);
      repo.confirmWithCategory(id);
      final p = billRows(repo, id).single;
      expect((p.amount, p.date, p.title, p.status), (total, '2026-03-10', payee, PlannedStatus.open));
      expect(reserved(repo), total);
    });

    test('title is Bill without a payee; due today counts as not past', () {
      final (id, _) = repo.importBill(nb(payeeName: null, dueDate: '2026-03-01'));
      repo.confirmWithCategory(id);
      expect(billRows(repo, id).single.title, 'Bill');
    });

    test('past due date: no planned row, nothing reserved', () {
      final (id, _) = repo.importBill(nb(dueDate: '2026-02-28'));
      repo.confirmWithCategory(id);
      expect(billRows(repo), isEmpty);
      expect(reserved(repo), 0);
    });

    test('no due date: no planned row', () {
      final (id, _) = repo.importBill(nb(dueDate: null));
      repo.confirmWithCategory(id);
      expect(billRows(repo), isEmpty);
    });

    test('updates follow the bill: total, due date, cleared due date', () {
      final (id, _) = repo.importBill(nb());
      repo.confirmWithCategory(id);
      repo.updateBill(id, total: 20000);
      expect(billRows(repo, id).single.amount, 20000);
      expect(reserved(repo), 20000);
      repo.updateBill(id, dueDate: '2026-03-12');
      expect(billRows(repo, id).single.date, '2026-03-12');
      repo.updateBill(id, clearDueDate: true);
      expect(billRows(repo, id).where((p) => p.isOpen), isEmpty);
      expect(reserved(repo), 0);
      repo.updateBill(id, dueDate: '2026-03-11');
      expect(reserved(repo), 20000);
    });

    test('after the due date has passed nothing is reserved, and the bill stays unpaid', () {
      final (id, _) = repo.importBill(nb());
      repo.confirmWithCategory(id);
      now = DateTime.utc(2026, 3, 11, 12).millisecondsSinceEpoch;
      expect(computePeriod(const [], st, const [], '2026-03-11', planned: repo.plannedCosts()).reservedPlanned, 0);
      expect(only(repo).paid, isFalse);
    });

    test('link closes the row with the paying tx: reserved money is released', () {
      final (id, _) = repo.importBill(nb());
      repo.confirmWithCategory(id);
      final tx = bankRow(repo, '2026-03-01', -total, 'SYNTHETIC SHOP');
      repo.linkBill(id, tx);
      final p = billRows(repo, id).single;
      expect(p.status, PlannedStatus.paid);
      expect(p.paidTx, tx);
      expect(reserved(repo), 0);
      expect(only(repo).paid, isTrue);
    });

    test('delete: the planned row is gone and nothing is reserved', () {
      final (id, _) = repo.importBill(nb());
      repo.confirmWithCategory(id);
      repo.deleteBill(id);
      // Changed (B1b): rows are never removed from the database (deletes sync as `deleted: 1`, like deletePlanned), so
      // "gone" = no live row.
      expect(billRows(repo).where((p) => !p.deleted), isEmpty);
      expect(repo.plannedCosts().where((p) => p.sourceRef == id), isEmpty);
      expect(reserved(repo), 0);
      expect(repo.bills(), isEmpty);
      expect(repo.bills(includeDeleted: true).single.deleted, isTrue);
    });

    test('a bill still in review never reserves, even with a due date', () {
      repo.importBill(nb());
      expect(reserved(repo), 0);
    });

    test('the bill row never changes the bank row category', () {
      final (id, _) = repo.importBill(nb());
      repo.confirmWithCategory(id);
      final tx = bankRow(repo, '2026-03-01', -total, 'SYNTHETIC SHOP');
      final before = repo.categorizer().categoryOf(repo.transactions().singleWhere((t) => t.id == tx));
      repo.updateBill(id, category: 'Utilities');
      repo.linkBill(id, tx);
      expect(repo.categorizer().categoryOf(repo.transactions().singleWhere((t) => t.id == tx)), before);
    });
  });

  group('linkBill / unlinkBill', () {
    test('one bill per transaction', () {
      final (a, _) = repo.importBill(nb(externalId: 'a'));
      final (b, _) = repo.importBill(nb(externalId: 'b'));
      final tx = bankRow(repo, '2026-03-01', -total, 'SYNTHETIC SHOP');
      repo.linkBill(a, tx);
      expect(() => repo.linkBill(b, tx), throwsArgumentError);
      expect(repo.bills().singleWhere((x) => x.id == b).linkedTx, isNull);
      expect(repo.bills().singleWhere((x) => x.id == a).linkedTx, tx);
      repo.linkBill(a, tx); // the same pair again is not a conflict
    });

    test('unlink frees the transaction for another bill', () {
      final (a, _) = repo.importBill(nb(externalId: 'a'));
      final (b, _) = repo.importBill(nb(externalId: 'b'));
      final tx = bankRow(repo, '2026-03-01', -total, 'SYNTHETIC SHOP');
      repo.linkBill(a, tx);
      repo.unlinkBill(a);
      expect(repo.bills().singleWhere((x) => x.id == a).paid, isFalse);
      repo.linkBill(b, tx);
      expect(repo.bills().singleWhere((x) => x.id == b).linkedTx, tx);
    });

    test('a link reaches the other device', () async {
      final net = Net();
      final key = VaultKey.generate();
      final a = Device('A', null, key, () => now, net: net), b = Device('B', null, key, () => now, net: net);
      addTearDown(a.close);
      addTearDown(b.close);
      final (id, _) = a.repo.importBill(nb());
      a.repo.confirmWithCategory(id);
      final tx = bankRow(a.repo, '2026-03-01', -total, 'SYNTHETIC SHOP');
      a.repo.linkBill(id, tx);
      for (final d in [a, b]) {
        now += 1000;
        await d.run();
      }
      expect(b.repo.bills().single.linkedTx, tx);
      expect(b.repo.bills().single.status, BillStatus.confirmed);
    });
  });

  group('addExpenseFromBill', () {
    test('a hand-added expense of -total on the bill date, payee as description, linked', () {
      final (id, _) = repo.importBill(nb());
      repo.confirmWithCategory(id);
      final txId = repo.addExpenseFromBill(id, category: 'Groceries');
      final t = repo.transactions().singleWhere((x) => x.id == txId);
      expect((t.amount, t.date, t.manual, t.category, t.description), (-total, '2026-02-25', true, 'Groceries', payee));
      expect(only(repo).linkedTx, txId);
      expect(billRows(repo, id).single.status, PlannedStatus.paid, reason: 'the planned row is closed by the link');
    });

    test('tx and link are written together: both ops sit in the outbox, none without the other on failure', () {
      final (id, _) = repo.importBill(nb());
      repo.confirmWithCategory(id);
      final before = repo.db.select('SELECT COUNT(*) AS c FROM outbox').first['c'] as int;
      repo.addExpenseFromBill(id, category: 'Groceries');
      final ops = [for (final r in repo.db.select('SELECT op FROM outbox ORDER BY seq')) jsonDecode(r['op'] as String) as Map];
      final fresh = ops.skip(before).map((o) => o['entity'] ?? o['e']).toSet();
      expect(fresh, containsAll(['tx', 'bill']));

      final (bad, _) = repo.importBill(nb(externalId: 'bad', date: null));
      final txCount = repo.transactions(includeHidden: true).length;
      expect(() => repo.addExpenseFromBill(bad, category: 'Groceries'), throwsArgumentError);
      expect(() => repo.addExpenseFromBill('bill:nope', category: 'Groceries'), throwsA(anything));
      expect(repo.transactions(includeHidden: true), hasLength(txCount), reason: 'a failed call writes no expense');
    });

    test('it reaches a second device as one unit', () async {
      final net = Net();
      final key = VaultKey.generate();
      final a = Device('A', null, key, () => now, net: net), b = Device('B', null, key, () => now, net: net);
      addTearDown(a.close);
      addTearDown(b.close);
      final (id, _) = a.repo.importBill(nb());
      a.repo.confirmWithCategory(id);
      final txId = a.repo.addExpenseFromBill(id, category: 'Groceries');
      await a.run();
      await b.run();
      expect(b.repo.bills().single.linkedTx, txId);
      expect(b.repo.transactions().map((t) => t.id), contains(txId));
    });
  });

  group('auto link', () {
    // Bill: date 2026-02-25, due 2026-03-10, total 13579, reference HR01 5555-1234 -> window 2026-02-22 .. 2026-05-09.
    String confirmed(WalletRepo r, {NormalizedBill? bill}) {
      final (id, _) = r.importBill(bill ?? nb());
      r.confirmWithCategory(id);
      return id;
    }

    Bill bill(WalletRepo r, String id) => r.bills().singleWhere((b) => b.id == id);
    const withRef = 'PLACANJE RACUNA HR01 5555-1234 TEST ELEKTRA';

    test('reference in the bank description + equal amount + in the window: linked', () {
      final id = confirmed(repo);
      final tx = bankRow(repo, '2026-03-05', -total, withRef);
      expect(bill(repo, id).linkedTx, tx);
      expect(billRows(repo, id).single.status, PlannedStatus.paid);
      expect(billRows(repo, id).single.paidTx, tx);
    });

    test('the row is the same whether the bill or the row came first only when caught up (bill first is the rule)', () {
      final tx = bankRow(repo, '2026-03-05', -total, withRef);
      final id = confirmed(repo);
      // SPEC: matching runs in _reconcile (on import and runPendingMatch); a bill confirmed after the row waits for the next run.
      repo.runPendingMatch();
      expect(bill(repo, id).linkedTx, tx);
    });

    test('equal amount WITHOUT the reference is never linked (not by amount alone)', () {
      final id = confirmed(repo);
      bankRow(repo, '2026-03-05', -total, 'POS SYNTHETIC SHOP ZAGREB');
      repo.runPendingMatch();
      expect(bill(repo, id).linkedTx, isNull);
      expect(bill(repo, id).paid, isFalse);
    });

    test('the payee name in the description is not a reference either', () {
      final id = confirmed(repo);
      bankRow(repo, '2026-03-05', -total, 'TEST ELEKTRA D.O.O. ZAGREB');
      repo.runPendingMatch();
      expect(bill(repo, id).linkedTx, isNull);
    });

    test('reference but a different amount: not linked (also one cent off)', () {
      final id = confirmed(repo);
      bankRow(repo, '2026-03-05', -(total + 1), withRef);
      bankRow(repo, '2026-03-06', -(total - 1), withRef);
      repo.runPendingMatch();
      expect(bill(repo, id).linkedTx, isNull);
    });

    test('an income row with the reference is not a payment', () {
      final id = confirmed(repo);
      bankRow(repo, '2026-03-05', total, withRef);
      repo.runPendingMatch();
      expect(bill(repo, id).linkedTx, isNull);
    });

    test('window: bill date - 3 .. due + 60, both ends included', () {
      for (final (date, ok) in [
        ('2026-02-21', false),
        ('2026-02-22', true),
        ('2026-05-09', true),
        ('2026-05-10', false),
      ]) {
        final r = mk();
        final id = confirmed(r);
        bankRow(r, date, -total, withRef);
        expect(bill(r, id).paid, ok, reason: date);
      }
    });

    test('window without a due date: bill date + 60', () {
      for (final (date, ok) in [('2026-04-26', true), ('2026-04-27', false)]) {
        final r = mk();
        final id = confirmed(r, bill: nb(dueDate: null));
        bankRow(r, date, -total, withRef);
        expect(bill(r, id).paid, ok, reason: date);
      }
    });

    test('a reference with fewer than 6 digits never links', () {
      final id = confirmed(repo, bill: nb(reference: 'HR01 12'));
      bankRow(repo, '2026-03-05', -total, 'PLACANJE HR01 12 SYNTHETIC');
      repo.runPendingMatch();
      expect(bill(repo, id).paid, isFalse);
    });

    test('JIR in the description links (receipt bills)', () {
      const jir = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
      final id = confirmed(repo, bill: nb(externalId: 'jir:$jir', reference: null, dueDate: null, source: BillSource.receiptQr));
      final tx = bankRow(repo, '2026-02-26', -total, 'POS SYNTHETIC SHOP $jir');
      expect(bill(repo, id).linkedTx, tx);
    });

    test('invoice number (4+ chars) in the description links; 3 chars do not', () {
      final long = confirmed(repo, bill: nb(externalId: 'inv:$theIban:2026-0042', reference: null));
      final tx = bankRow(repo, '2026-03-05', -total, 'PLACANJE RACUN 2026-0042 TEST');
      expect(bill(repo, long).linkedTx, tx);
      final r = mk();
      final short = confirmed(r, bill: nb(externalId: 'inv:$theIban:042', reference: null));
      bankRow(r, '2026-03-05', -total, 'PLACANJE RACUN 042 TEST');
      r.runPendingMatch();
      expect(bill(r, short).paid, isFalse);
    });

    test('several candidates: none is linked', () {
      final id = confirmed(repo);
      // Changed (B1b): both rows in one import. Rows imported one by one link to the first (the only candidate then):
      // like matching and pairing, a link once made is never re-planned.
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-03-05', -total, 'POS plaćanje', withRef),
        n('2026-03-06', -total, 'POS plaćanje', withRef),
      ]));
      repo.runPendingMatch();
      expect(bill(repo, id).linkedTx, isNull);
    });

    test('a review bill is not linked', () {
      final (id, _) = repo.importBill(nb());
      bankRow(repo, '2026-03-05', -total, withRef);
      repo.runPendingMatch();
      expect(bill(repo, id).linkedTx, isNull);
    });

    test('an already linked bill is not relinked; a row used by another bill is not taken', () {
      final a = confirmed(repo);
      final tx = bankRow(repo, '2026-03-05', -total, withRef);
      expect(bill(repo, a).linkedTx, tx);
      final (b, _) = repo.importBill(nb(externalId: 'second'));
      repo.confirmWithCategory(b);
      repo.runPendingMatch();
      expect(bill(repo, a).linkedTx, tx);
      expect(bill(repo, b).linkedTx, isNull, reason: 'one bill per tx');
    });

    test('a deleted bank row is not a candidate', () {
      final id = confirmed(repo);
      final tx = bankRow(repo, '2026-03-05', -total, withRef);
      repo.unlinkBill(id);
      repo.deleteTransaction(tx);
      repo.runPendingMatch();
      expect(bill(repo, id).linkedTx, isNull);
    });

    test('not caught up: waits, and links on the next caught-up run', () {
      final id = confirmed(repo);
      repo.setLocalValue(WalletRepo.caughtUpKey, '0');
      expect(repo.syncCaughtUp, isFalse);
      final tx = bankRow(repo, '2026-03-05', -total, withRef);
      expect(bill(repo, id).linkedTx, isNull, reason: 'the row set may be incomplete');
      repo.setLocalValue(WalletRepo.caughtUpKey, '1');
      repo.runPendingMatch();
      expect(bill(repo, id).linkedTx, tx);
    });
  });

  group('billCandidates', () {
    Bill mkBill({String? due, String? payeeName = payee}) {
      final r = mk();
      r.importBill(nb(dueDate: due, payeeName: payeeName, tot: 5000, reference: null));
      return r.bills().single;
    }

    test('window date - 3 .. (due ?? date) + 30; expenses only; live only', () {
      final b = mkBill(); // 2026-02-25, no due date
      final txs = [
        row('2026-02-21', -5000, 'before'),
        row('2026-02-22', -5000, 'first day'),
        row('2026-03-27', -5000, 'last day'),
        row('2026-03-28', -5000, 'after'),
        row('2026-02-26', 5000, 'income'),
        row('2026-02-26', -5000, 'deleted', deleted: true),
      ];
      expect({
        for (final c in billCandidates(b, txs, [b])) c.tx.description
      }, {
        'first day',
        'last day'
      });
    });

    test('with a due date the window ends 30 days after it', () {
      final b = mkBill(due: '2026-03-10');
      final txs = [row('2026-04-09', -100, 'in'), row('2026-04-10', -100, 'out')];
      expect([
        for (final c in billCandidates(b, txs, [b])) c.tx.description
      ], [
        'in'
      ]);
    });

    test('never filtered by amount', () {
      final b = mkBill();
      final txs = [row('2026-02-26', -1, 'tiny'), row('2026-02-26', -999999, 'huge'), row('2026-02-26', -5000, 'same')];
      expect(billCandidates(b, txs, [b]), hasLength(3));
    });

    test('order: payee word first, then date distance, then amount closeness', () {
      final b = mkBill();
      final txs = [
        row('2026-02-26', -9000, 'A one day, far amount'),
        row('2026-02-25', -1000, 'B same day'),
        row('2026-03-10', -5000, 'C exact amount, far date'),
        row('2026-02-27', -4000, 'D ELEKTRA rata'),
        row('2026-02-26', -5100, 'E one day, close amount'),
      ];
      final order = [
        for (final c in billCandidates(b, txs, [b])) c.tx.description.split(' ').first
      ];
      expect(order.first, 'D', reason: 'payee word in the description comes first');
      expect(order.indexOf('B'), lessThan(order.indexOf('E')));
      expect(order.indexOf('E'), lessThan(order.indexOf('A')), reason: 'same date distance: closer amount first');
      expect(order.last, 'C');
    });

    test('the common company suffix alone is not a payee word', () {
      // SPEC: words like "d.o.o." in the payee must not rank unrelated rows first; only the name words count.
      final b = mkBill();
      final txs = [row('2026-02-25', -5000, 'RANDOM D.O.O. SHOP'), row('2026-02-27', -5000, 'TEST ELEKTRA')];
      expect(billCandidates(b, txs, [b]).first.tx.description, 'TEST ELEKTRA');
    });

    test('rows linked to another bill are left out; its own link stays', () {
      final r = mk();
      r.importBill(nb(externalId: 'a'));
      r.importBill(nb(externalId: 'b'));
      final all = r.bills();
      final a = all.firstWhere((x) => x.externalId == 'a');
      final b = all.firstWhere((x) => x.externalId == 'b');
      final t1 = bankRow(r, '2026-02-26', -5000, 'one'), t2 = bankRow(r, '2026-02-26', -5000, 'two');
      r.linkBill(a.id, t1);
      r.linkBill(b.id, t2);
      final fresh = r.bills();
      final txs = [for (final t in r.transactions()) CategorizedTx(t, 'Shopping', kindOf('Shopping'))];
      final forB = billCandidates(fresh.firstWhere((x) => x.id == b.id), txs, fresh).map((c) => c.tx.id).toSet();
      expect(forB, {t2});
    });

    test('no candidates: empty list', () {
      final b = mkBill();
      expect(billCandidates(b, const [], [b]), isEmpty);
    });
  });

  group('upcoming and reminders', () {
    late Bill warranty, returns, review, deleted;
    setUp(() {
      Bill mkOne(String ext, {String? payeeName, String? description, bool confirm = true, bool del = false}) {
        final (id, _) = repo.importBill(nb(externalId: ext, payeeName: payeeName, description: description, dueDate: null));
        repo.updateBill(id, warrantyUntil: '2026-03-20', returnBy: '2026-03-05');
        if (confirm) repo.confirmWithCategory(id);
        if (del) repo.deleteBill(id);
        return repo.bills(includeDeleted: true).singleWhere((b) => b.id == id);
      }

      warranty = mkOne('w', payeeName: 'Test Shop');
      returns = mkOne('r', payeeName: null, description: 'Synthetic vacuum');
      review = mkOne('rev', confirm: false);
      deleted = mkOne('del', del: true);
    });

    List<UpcomingItem> list(List<Bill> bills, {String from = '2026-03-01', String to = '2026-03-31'}) =>
        upcoming(planned: const [], bills: const [], events: const [], from: from, to: to, billsDb: bills);

    test('confirmed, live bills list warranty and return-by with keys, no amount, the bill attached', () {
      final items = list([warranty, returns, review, deleted]);
      expect(items.map((i) => i.key).toSet(), {'w:${warranty.id}', 'r:${warranty.id}', 'w:${returns.id}', 'r:${returns.id}'});
      for (final i in items) {
        expect(i.amount, isNull);
        expect(i.suggested, isNull);
        expect(i.billDb, isNotNull);
      }
      final w = items.singleWhere((i) => i.key == 'w:${warranty.id}');
      expect((w.kind, w.date, w.title, w.billDb!.id), (UpcomingKind.warranty, '2026-03-20', 'Test Shop', warranty.id));
      final r = items.singleWhere((i) => i.key == 'r:${warranty.id}');
      expect((r.kind, r.date), (UpcomingKind.returnBy, '2026-03-05'));
      expect(items.singleWhere((i) => i.key == 'w:${returns.id}').title, 'Synthetic vacuum', reason: 'description when there is no payee');
    });

    test('range is inclusive at both ends', () {
      expect(list([warranty], from: '2026-03-20', to: '2026-03-20').map((i) => i.key), ['w:${warranty.id}']);
      expect(list([warranty], from: '2026-03-05', to: '2026-03-05').map((i) => i.key), ['r:${warranty.id}']);
      expect(list([warranty], from: '2026-03-21', to: '2026-03-31'), isEmpty);
      expect(list([warranty], from: '2026-03-01', to: '2026-03-04'), isEmpty);
    });

    test('never counted: the budget does not move', () {
      final base = computePeriod(const [], st, const [], '2026-03-01');
      final p = computePeriod(const [], st, const [], '2026-03-01', planned: repo.plannedCosts());
      expect(p.reservedPlanned, base.reservedPlanned);
      expect(p.flexBudget, base.flexBudget);
    });

    test('reminder lead times: defaults come from settings (3 and 14)', () {
      const s = WalletSettings();
      expect((s.returnReminderDays, s.warrantyReminderDays), (3, 14));
    });
  });

  group('settings', () {
    test('defaults', () {
      final s = WalletSettings.fromMap(const {});
      expect((s.returnReminderDays, s.warrantyReminderDays), (3, 14));
    });

    test('valid range edges', () {
      final s = WalletSettings.fromMap(const {'returnReminderDays': 30, 'warrantyReminderDays': 90});
      expect((s.returnReminderDays, s.warrantyReminderDays), (30, 90));
      final z = WalletSettings.fromMap(const {'returnReminderDays': 0, 'warrantyReminderDays': 0});
      expect((z.returnReminderDays, z.warrantyReminderDays), (0, 0));
    });

    test('out of range or wrong type falls back to the default of that setting alone', () {
      resetInvalidSettingLog();
      for (final bad in <Object?>[31, -1, 3.5, 'x', null, true]) {
        final s = WalletSettings.fromMap({'returnReminderDays': bad, 'warrantyReminderDays': 20});
        expect(s.returnReminderDays, 3, reason: '$bad');
        expect(s.warrantyReminderDays, 20);
      }
      for (final bad in <Object?>[91, -1, 0.5, 'x', false]) {
        final s = WalletSettings.fromMap({'warrantyReminderDays': bad, 'returnReminderDays': 7});
        expect(s.warrantyReminderDays, 14, reason: '$bad');
        expect(s.returnReminderDays, 7);
      }
    });

    test('they sync as settings', () {
      repo.updateSettings({'returnReminderDays': 5, 'warrantyReminderDays': 30});
      expect((repo.settings().returnReminderDays, repo.settings().warrantyReminderDays), (5, 30));
    });
  });

  group('searchAll', () {
    test('billsDb: payee, description and item names folded; exact total only', () {
      repo.importBill(
          nb(payeeName: 'Čašić Elektra', description: 'Račun za struju', items: const [BillItem(name: 'Žarulja LED', amount: 500)]));
      repo.importBill(nb(externalId: 'other', payeeName: 'Unrelated', description: 'Nothing', tot: 99999, reference: null));
      final all = repo.bills();
      SearchResult q(String s) => searchAll(s, txs: const [], goals: const [], wishlist: const [], bills: const [], billsDb: all);
      expect(q('casic').billsDb.map((b) => b.payee), ['Čašić Elektra']);
      expect(q('RACUN ZA').billsDb.map((b) => b.payee), ['Čašić Elektra']);
      expect(q('zarulja').billsDb.map((b) => b.payee), ['Čašić Elektra']);
      expect(q('135,79').billsDb.map((b) => b.payee), ['Čašić Elektra'], reason: 'exact total');
      expect(q('135').billsDb, isEmpty, reason: 'a total matches only exactly');
      expect(q('1357,9').billsDb, isEmpty);
      expect(q('nonexistentword').billsDb, isEmpty);
      expect(q('').billsDb, isEmpty);
    });

    test('deleted bills are not found', () {
      final (id, _) = repo.importBill(nb());
      repo.deleteBill(id);
      final r = searchAll('elektra',
          txs: const [], goals: const [], wishlist: const [], bills: const [], billsDb: repo.bills(includeDeleted: true));
      // SPEC: deleted bills are hidden from search like deleted rows elsewhere.
      expect(r.billsDb, isEmpty);
    });
  });

  group('backup', () {
    test('bills round-trip; blob cache and queues are device-local and not in the backup', () async {
      final key = VaultKey.generate();
      final store = BlobStore(repo, key);
      // Changed (B1b): the local was `ref`, which hid the top-level reference string compared below.
      final file = await store.add(Uint8List.fromList(List.generate(2000, (i) => i & 0xff)), 'jpg');
      final (id, _) = repo.importBill(nb(items: const [BillItem(name: 'Widget', quantity: '2', amount: 1000)]), file: file);
      repo.confirmWithCategory(id);
      repo.updateBill(id, warrantyUntil: '2027-03-01', returnBy: '2026-03-15', note: 'synthetic');
      final bytes = await backupBytes(repo, key);

      final fresh = mk();
      await restoreBackupBytes(fresh, bytes, key);
      final b = fresh.bills().single;
      final o = only(repo);
      expect(b.id, o.id);
      expect((b.status, b.total, b.payee, b.dueDate, b.date, b.reference, b.iban),
          (BillStatus.confirmed, total, payee, '2026-03-10', '2026-02-25', ref, theIban));
      expect(b.items, o.items);
      expect((b.warrantyUntil, b.returnBy, b.note), ('2027-03-01', '2026-03-15', 'synthetic'));
      expect((b.blob, b.blobType, b.blobBytes), (file.hash, 'jpg', 2000));
      expect(billRows(fresh, id), hasLength(1), reason: 'the planned row comes along');

      for (final t in ['blob_cache', 'blob_outbox', 'blob_delete']) {
        expect(fresh.db.select('SELECT COUNT(*) AS c FROM $t').first['c'], 0, reason: t);
      }
      expect(await BlobStore(fresh, key).read(file.hash), isNull, reason: 'the file itself is not in the backup');
    });
  });

  group('logs', () {
    test('no payee, IBAN, reference, amount, ids or hashes in the log lines', () {
      const jir = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
      String id = '';
      final lines = logsOf(() {
        final (i, _) = repo.importBill(nb(items: const [BillItem(name: 'Secretwidget', amount: 4242)]));
        id = i;
        repo.importBill(nb());
        repo.updateBill(id, note: 'secretnote', category: 'Utilities');
        repo.confirmWithCategory(id);
        final tx = bankRow(repo, '2026-03-05', -total, 'PLACANJE RACUNA HR01 5555-1234 TEST ELEKTRA');
        repo.unlinkBill(id);
        repo.linkBill(id, tx);
        repo.importBill(nb(externalId: 'jir:$jir', source: BillSource.receiptQr));
        repo.runPendingMatch();
        billCandidates(repo.bills().first, const [], repo.bills());
        searchAll('elektra', txs: const [], goals: const [], wishlist: const [], bills: const [], billsDb: repo.bills());
        expect(() => repo.confirmWithCategory('bill:missing'), throwsA(anything));
        repo.deleteBill(id);
      });
      expect(lines, isNotEmpty, reason: 'bill actions are logged (counts, sources, enum words)');
      final all = lines.join('\n').toLowerCase();
      for (final secret in [
        'elektra',
        theIban.toLowerCase(),
        '5555-1234',
        '55551234',
        '$total',
        '4242',
        'secretwidget',
        'secretnote',
        jir,
        id.replaceFirst('bill:', ''),
        'porezna',
      ]) {
        expect(all, isNot(contains(secret)), reason: secret);
      }
    });
  });
}
