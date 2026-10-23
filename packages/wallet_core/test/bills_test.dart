// Bills database (stage B, docs/context/BILLS_API.md §2, §3, §5). SYNTHETIC data only: made-up payees, IBAN-free
// references, invented amounts.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/bill_helpers.dart';
import 'support/sim.dart';
import 'support/synthetic.dart';

const today = '2026-03-01';
final noon = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;

NormalizedBill slip({
  String? ext = 'hub3:HR00TEST:HR01 1234-5678:4599',
  String? date = '2026-02-27',
  String? due = '2026-03-10',
  int? total = 4599,
  String? payee = 'Synthetic Utility',
  String? reference = 'HR01 1234-5678',
  BillSource source = BillSource.hub3,
  List<BillItem> items = const [],
}) =>
    NormalizedBill(
        source: source, externalId: ext, date: date, dueDate: due, total: total, payee: payee, reference: reference, items: items);

ImportBatch rows(List<NormalizedTransaction> t) => ImportBatch(source: 'pbz', transactions: t);

void main() {
  late WalletRepo repo;
  var now = noon;
  setUp(() {
    now = noon;
    repo = WalletRepo.inMemory(now: () => now);
  });
  tearDown(() => repo.close());

  PlannedCost? plannedOf(String billId) {
    for (final p in repo.plannedCosts(includeClosed: true)) {
      if (p.id == WalletRepo.billPlannedId(billId)) return p;
    }
    return null;
  }

  group('importBill', () {
    test('a new bill: review, id from the external id, fields as read', () {
      final (id, isNew) = repo.importBill(slip(items: const [BillItem(name: 'Line', quantity: '2', amount: 4599)]));
      expect(isNew, isTrue);
      expect(id, Bill.idFor('hub3:HR00TEST:HR01 1234-5678:4599'));
      expect(id, matches(RegExp(r'^bill:[0-9a-f]{32}$')));
      final b = repo.bills().single;
      expect(b.status, BillStatus.review);
      expect((b.source, b.date, b.dueDate, b.total, b.payee, b.reference, b.currency, b.paid),
          (BillSource.hub3, '2026-02-27', '2026-03-10', 4599, 'Synthetic Utility', 'HR01 1234-5678', 'EUR', false));
      expect(b.items.single, const BillItem(name: 'Line', quantity: '2', amount: 4599));
      expect(plannedOf(id), isNull, reason: 'a bill in review reserves nothing');
    });

    test('the same code read again: one bill, only empty fields filled', () {
      final (id, _) = repo.importBill(slip(payee: null, due: null));
      repo.updateBill(id, note: 'kept');
      final (id2, isNew) = repo.importBill(slip(payee: 'Synthetic Utility', total: 9999, date: '2026-01-01'));
      expect((id2, isNew), (id, false));
      final b = repo.bill(id)!;
      expect((b.payee, b.dueDate, b.total, b.date, b.note), ('Synthetic Utility', '2026-03-10', 4599, '2026-02-27', 'kept'));
      expect(repo.bills(), hasLength(1));
    });

    test('a confirmed bill re-imported: money fields and dates never change; items and a file only when missing', () {
      final (id, _) = repo.importBill(slip(due: null, payee: null));
      repo.confirmWithCategory(id);
      repo.importBill(slip(due: '2026-03-20', payee: 'Other', items: const [BillItem(name: 'X', amount: 1)]),
          file: const BlobRef(hash: 'aa', type: 'pdf', bytes: 10));
      final b = repo.bill(id)!;
      expect((b.dueDate, b.payee, b.total, b.status), (null, null, 4599, BillStatus.confirmed));
      expect(b.items, hasLength(1));
      expect(b.file, const BlobRef(hash: 'aa', type: 'pdf', bytes: 10));
      expect(plannedOf(id), isNull);
    });

    test('without an external id every import is its own bill (random b… id)', () {
      final (a, _) = repo.importBill(slip(ext: null));
      final (b, _) = repo.importBill(slip(ext: null));
      expect(a, isNot(b));
      expect(a, startsWith('b'));
      expect(repo.bills(), hasLength(2));
    });

    test('reader mistakes are dropped, not thrown: bad dates, total ≤ 0, too many items, long names', () {
      final many = [for (var i = 0; i < 600; i++) BillItem(name: 'n' * 300, amount: i)];
      final (id, _) = repo.importBill(slip(date: '2026-02-30', due: 'soon', total: 0, items: many));
      final b = repo.bill(id)!;
      expect((b.date, b.dueDate, b.total), (null, null, null));
      expect(b.items, hasLength(maxBillItems));
      expect(b.items.first.name.length, maxBillItemName);
      expect(() => repo.importBill(slip(), file: const BlobRef(hash: 'aa', type: 'exe', bytes: 1)), throwsArgumentError);
    });

    test('a deleted bill read again comes back as a new review bill', () {
      final (id, _) = repo.importBill(slip());
      repo.confirmWithCategory(id);
      repo.deleteBill(id);
      expect(repo.bills(), isEmpty);
      final (id2, isNew) = repo.importBill(slip(payee: 'Back'));
      expect((id2, isNew), (id, true));
      final b = repo.bill(id)!;
      expect((b.deleted, b.status, b.payee), (false, BillStatus.review, 'Back'));
      expect(plannedOf(id)!.deleted, isTrue);
    });
  });

  group('updateBill / confirmBill', () {
    test('fields change, clear flags clear, bad input is an ArgumentError', () {
      final (id, _) = repo.importBill(slip());
      repo.updateBill(id,
          category: 'Groceries',
          warrantyUntil: '2028-02-27',
          returnBy: '2026-03-13',
          items: const [BillItem(name: 'A', amount: 4599)],
          description: 'Synthetic description');
      var b = repo.bill(id)!;
      expect((b.category, b.warrantyUntil, b.returnBy, b.items.length), ('Groceries', '2028-02-27', '2026-03-13', 1));
      repo.updateBill(id, clearDueDate: true, clearWarranty: true, clearReturnBy: true, clearCategory: true);
      b = repo.bill(id)!;
      expect((b.dueDate, b.warrantyUntil, b.returnBy, b.category), (null, null, null, null));
      expect(() => repo.updateBill(id, date: '2026-13-01'), throwsArgumentError);
      expect(() => repo.updateBill(id, total: 0), throwsArgumentError);
      expect(() => repo.updateBill(id, total: -5), throwsArgumentError);
      expect(() => repo.updateBill(id, items: [for (var i = 0; i < 501; i++) const BillItem(name: 'x', amount: 1)]), throwsArgumentError);
      expect(() => repo.updateBill(id, items: [BillItem(name: 'x' * 201, amount: 1)]), throwsArgumentError);
      expect(() => repo.updateBill('nope', note: 'x'), throwsArgumentError);
    });

    test('confirm needs a date and a total', () {
      final (a, _) = repo.importBill(slip(ext: 'jir:a', date: null));
      final (b, _) = repo.importBill(slip(ext: 'jir:b', total: null));
      expect(() => repo.confirmWithCategory(a), throwsArgumentError);
      expect(() => repo.confirmWithCategory(b), throwsArgumentError);
      expect(() => repo.confirmWithCategory('nope'), throwsArgumentError);
      repo.updateBill(b, total: 100);
      repo.confirmWithCategory(b);
      expect(repo.bill(b)!.confirmed, isTrue);
    });
  });

  group('the planned row bill:<id>', () {
    test('confirm creates it, edits follow, link closes it, unlink reopens it, delete removes it', () {
      final (id, _) = repo.importBill(slip());
      repo.updateBill(id, category: 'Groceries');
      repo.confirmWithCategory(id);
      var p = plannedOf(id)!;
      expect((p.source, p.sourceRef, p.title, p.amount, p.date, p.category, p.status),
          (PlannedSource.bill, id, 'Synthetic Utility', 4599, '2026-03-10', 'Groceries', PlannedStatus.open));
      repo.updateBill(id, total: 5000, dueDate: '2026-03-12');
      p = plannedOf(id)!;
      expect((p.amount, p.date), (5000, '2026-03-12'));
      final tx = repo.addTransaction(date: '2026-03-02', amount: 5000, category: 'Groceries');
      repo.linkBill(id, tx);
      p = plannedOf(id)!;
      expect((p.status, p.paidTx), (PlannedStatus.paid, tx));
      expect(repo.bill(id)!.paid, isTrue);
      repo.unlinkBill(id);
      expect(plannedOf(id)!.status, PlannedStatus.open);
      repo.deleteBill(id);
      expect(plannedOf(id)!.deleted, isTrue);
      expect(() => repo.deleteBill(id), throwsArgumentError);
    });

    test('no row for a due date already past, none without a due date; clearing the due date deletes it', () {
      final (past, _) = repo.importBill(slip(ext: 'jir:p', due: '2026-02-28'));
      repo.confirmWithCategory(past);
      expect(plannedOf(past), isNull);
      final (none, _) = repo.importBill(slip(ext: 'jir:n', due: null));
      repo.confirmWithCategory(none);
      expect(plannedOf(none), isNull);
      final (id, _) = repo.importBill(slip(ext: 'jir:c'));
      repo.confirmWithCategory(id);
      expect(plannedOf(id)!.isOpen, isTrue);
      repo.updateBill(id, clearDueDate: true);
      expect(plannedOf(id)!.deleted, isTrue);
      repo.updateBill(id, dueDate: '2026-03-20');
      expect(plannedOf(id)!.isOpen, isTrue, reason: 'a due date set again brings the row back');
    });

    test('computePeriod reserves an unpaid slip and releases it when linked', () {
      final st = WalletSettings.fromMap({'salary': 200000, 'rent': 50000, 'periodStart': '2026-02-15', 'paydayDay': 15});
      final base = computePeriod(const [], st, const [], today).flexBudget;
      final (id, _) = repo.importBill(slip());
      repo.updateBill(id, category: 'Bills & subscriptions');
      repo.updateBill(id, category: 'Groceries');
      repo.confirmWithCategory(id);
      var p = computePeriod(const [], st, const [], today, planned: repo.plannedCosts());
      expect(p.reservedPlanned, 4599);
      expect(p.flexBudget, base - 4599);
      repo.linkBill(id, repo.addTransaction(date: '2026-03-01', amount: 4599, category: 'Groceries'));
      p = computePeriod(const [], st, const [], today, planned: repo.plannedCosts());
      expect(p.reservedPlanned, 0);
    });
  });

  group('linkBill / addExpenseFromBill', () {
    test('one bill per transaction; unknown ids refused; the paying row keeps its category', () {
      final (a, _) = repo.importBill(slip(ext: 'jir:a'));
      final (b, _) = repo.importBill(slip(ext: 'jir:b'));
      repo.importBatch(rows([n('2026-03-01', -4599, 'POS plaćanje', 'SYNTHETIC SHOP')]));
      final tx = repo.transactions().single;
      repo.linkBill(a, tx.id);
      expect(() => repo.linkBill(b, tx.id), throwsArgumentError);
      expect(() => repo.linkBill(b, 'missing'), throwsArgumentError);
      expect(() => repo.linkBill('missing', tx.id), throwsArgumentError);
      expect(repo.transaction(tx.id)!.category, tx.category);
      repo.linkBill(a, tx.id); // the same link again is fine
      expect(repo.bill(a)!.linkedTx, tx.id);
    });

    test('a cash receipt becomes a hand-added expense, linked and confirmed, in one write', () {
      final (id, _) = repo.importBill(slip(source: BillSource.receiptQr, ext: 'jir:cash', due: null));
      final before = repo.pendingOps().length;
      final tx = repo.addExpenseFromBill(id, category: 'Eating out');
      expect(repo.pendingOps().length - before, 2, reason: 'the expense and the bill');
      final t = repo.transaction(tx)!;
      expect((t.manual, t.amount, t.date, t.description, t.category), (true, -4599, '2026-02-27', 'Synthetic Utility', 'Eating out'));
      final b = repo.bill(id)!;
      expect((b.linkedTx, b.status), (tx, BillStatus.confirmed));
      expect(() => repo.addExpenseFromBill(id, category: 'Eating out'), throwsArgumentError);
      final (noTotal, _) = repo.importBill(slip(ext: 'jir:none', total: null));
      expect(() => repo.addExpenseFromBill(noTotal, category: 'Eating out'), throwsArgumentError);
    });

    test('deleting the paying row makes the bill unpaid again at once', () {
      final (id, _) = repo.importBill(slip());
      repo.confirmWithCategory(id);
      final tx = repo.addTransaction(date: '2026-03-01', amount: 4599, category: 'Groceries');
      repo.linkBill(id, tx);
      repo.deleteTransaction(tx);
      expect(repo.bill(id)!.paid, isFalse);
      expect(plannedOf(id)!.status, PlannedStatus.open);
    });
  });

  group('auto link (deterministic, never by amount alone)', () {
    String confirmed(NormalizedBill b) {
      final (id, _) = repo.importBill(b);
      repo.confirmWithCategory(id);
      return id;
    }

    test('reference in the description + exact amount + in the window: linked, planned row closed', () {
      final id = confirmed(slip());
      repo.importBatch(rows([n('2026-03-05', -4599, 'Nalog', 'UPLATA HR01 1234-5678 SYNTHETIC UTILITY')]));
      final tx = repo.transactions().single;
      expect(repo.bill(id)!.linkedTx, tx.id);
      expect(plannedOf(id)!.status, PlannedStatus.paid);
      expect(repo.transaction(tx.id)!.category, isNull, reason: 'a bill never reclassifies its payment');
    });

    test('the bank row first, the confirm later: linked at the confirm', () {
      repo.importBatch(rows([n('2026-03-05', -4599, 'Nalog', 'POZIV NA BROJ 12345678')]));
      final id = confirmed(slip());
      expect(repo.bill(id)!.linkedTx, repo.transactions().single.id);
    });

    test('JIR and invoice numbers link too', () {
      final jir = confirmed(slip(ext: 'jir:0a1b2c3d-1111-2222-3333-444455556666', reference: null, total: 1250));
      final inv = confirmed(slip(ext: 'inv:12345678901:R-2026/0042', reference: null, total: 8000));
      repo.importBatch(rows([
        n('2026-03-02', -1250, 'POS', 'JIR 0A1B2C3D111122223333444455556666'),
        n('2026-03-03', -8000, 'Nalog', 'Racun R-2026/0042 synthetic'),
      ]));
      final byAmount = {for (final t in repo.transactions()) t.amount: t.id};
      expect(repo.bill(jir)!.linkedTx, byAmount[-1250]);
      expect(repo.bill(inv)!.linkedTx, byAmount[-8000]);
    });

    test('an equal amount without the reference never links', () {
      final id = confirmed(slip());
      repo.importBatch(rows([n('2026-03-05', -4599, 'POS', 'SYNTHETIC UTILITY')]));
      expect(repo.bill(id)!.paid, isFalse);
    });

    test('the reference with another amount, outside the window, in a longer number, or too short: no link', () {
      final a = confirmed(slip(ext: 'jir:x1', reference: 'HR01 1111-2222'));
      final b = confirmed(slip(ext: 'jir:x2', reference: 'HR01 3333-4444', total: 700));
      final c = confirmed(slip(ext: 'jir:x3', reference: 'HR01 5555-6666', total: 800));
      final d = confirmed(slip(ext: 'jir:x4', reference: 'HR00 12345', total: 900));
      repo.importBatch(rows([
        n('2026-03-05', -4600, 'Nalog', 'HR01 1111-2222'), // one cent off
        n('2026-05-20', -700, 'Nalog', 'HR01 3333-4444'), // due 10 March + 60 = 9 May
        n('2026-03-05', -800, 'Nalog', 'REF 9555566669'), // digits run on
        n('2026-03-05', -900, 'Nalog', 'REF 12345'), // 5 digits
      ]));
      for (final id in [a, b, c, d]) {
        expect(repo.bill(id)!.paid, isFalse, reason: id);
      }
    });

    test('window edges: date − 3 and due + 60 link, one day beyond does not', () {
      final early = confirmed(slip(ext: 'jir:e', reference: 'HR01 7777-0001', total: 101));
      final late = confirmed(slip(ext: 'jir:l', reference: 'HR01 7777-0002', total: 102));
      final tooEarly = confirmed(slip(ext: 'jir:te', reference: 'HR01 7777-0003', total: 103));
      repo.importBatch(rows([
        n('2026-02-24', -101, 'Nalog', 'HR01 7777-0001'),
        n('2026-05-09', -102, 'Nalog', 'HR01 7777-0002'),
        n('2026-02-23', -103, 'Nalog', 'HR01 7777-0003'),
      ]));
      expect(repo.bill(early)!.paid, isTrue);
      expect(repo.bill(late)!.paid, isTrue);
      expect(repo.bill(tooEarly)!.paid, isFalse);
    });

    test('ambiguous: two rows for one bill, or one row for two bills, links nothing', () {
      final one = confirmed(slip(ext: 'jir:1', reference: 'HR01 8888-0001', total: 300));
      repo.importBatch(rows([
        n('2026-03-02', -300, 'Nalog', 'HR01 8888-0001'),
        n('2026-03-03', -300, 'Nalog', 'HR01 8888-0001 again'),
      ]));
      expect(repo.bill(one)!.paid, isFalse);
      final x = confirmed(slip(ext: 'jir:2', reference: 'HR01 9999-0001', total: 400));
      final y = confirmed(slip(ext: 'jir:3', reference: 'HR01 9999-0001', total: 400));
      repo.importBatch(rows([n('2026-03-04', -400, 'Nalog', 'HR01 9999-0001')]));
      expect(repo.bill(x)!.paid || repo.bill(y)!.paid, isFalse);
    });

    test('a bill in review, a hand-added entry or an own transfer never links', () {
      final (review, _) = repo.importBill(slip(ext: 'jir:r', reference: 'HR01 4444-0001', total: 500));
      repo.importBatch(rows([n('2026-03-04', -500, 'Nalog', 'HR01 4444-0001')]));
      expect(repo.bill(review)!.paid, isFalse);
      final id = confirmed(slip(ext: 'jir:m', reference: 'HR01 4444-0002', total: 600));
      repo.addTransaction(date: '2026-03-04', amount: 600, category: 'Groceries');
      repo.runPendingMatch();
      expect(repo.bill(id)!.paid, isFalse);
    });

    test('caught-up gate: no link while the last sync was not caught up; the next caught-up run links', () {
      final id = confirmed(slip());
      repo.setLocalValue(WalletRepo.caughtUpKey, '0');
      repo.importBatch(rows([n('2026-03-05', -4599, 'Nalog', 'HR01 1234-5678')]));
      expect(repo.bill(id)!.paid, isFalse);
      repo.setLocalValue(WalletRepo.caughtUpKey, '1');
      repo.runPendingMatch();
      expect(repo.bill(id)!.paid, isTrue);
    });

    test('pure helpers: tokens and boundaries', () {
      const b = Bill(id: 'x', reference: 'HR01 1234-5678', externalId: 'inv:123:AB-12');
      expect(billLinkTokens(b), ['HR0112345678', '12345678', 'AB12']);
      expect(descriptionHasToken('ref hr01 1234-5678.', 'HR0112345678'), isTrue);
      expect(descriptionHasToken('ref 912345678', '12345678'), isFalse);
      expect(descriptionHasToken('ref 12345678x', '12345678'), isTrue);
      expect(billLinkTokens(const Bill(id: 'y', externalId: 'inv:1:ABC')), isEmpty);
      expect(planBillLinks(const [Bill(id: 'z', status: BillStatus.confirmed, total: 5, date: today)], const []), isEmpty);
    });
  });

  group('billCandidates', () {
    test('payee words first, then date distance, then amount closeness; never filtered by amount; taken rows out', () {
      const b = Bill(id: 'b1', date: '2026-03-01', dueDate: '2026-03-10', total: 1000, payee: 'Synthetic Utility');
      CategorizedTx row(String id, String date, int cents, String desc) =>
          CategorizedTx(Tx(id: id, source: 'pbz', date: date, amount: cents, description: desc), 'Groceries', BudgetKind.flex);
      final txs = [
        row('far', '2026-03-20', -1000, 'OTHER'),
        row('near', '2026-03-02', -5, 'OTHER'),
        row('named', '2026-04-05', -77, 'SYNTHETIC UTILITY d.o.o.'),
        row('income', '2026-03-02', 1000, 'SYNTHETIC UTILITY'),
        row('before', '2026-02-25', -1000, 'OTHER'),
        row('taken', '2026-03-01', -1000, 'OTHER'),
        row('late', '2026-04-10', -1000, 'SYNTHETIC UTILITY'),
      ];
      const other = Bill(id: 'b2', linkedTx: 'taken');
      expect([
        for (final t in billCandidates(b, txs, const [b, other])) t.tx.id
      ], [
        'named',
        'near',
        'far'
      ]);
      expect(billCandidates(const Bill(id: 'n'), txs, const []), isEmpty);
    });
  });

  group('Upcoming, reminders, settings', () {
    const b = Bill(
        id: 'b1', status: BillStatus.confirmed, payee: 'Synthetic Shop', warrantyUntil: '2026-03-20', returnBy: '2026-03-04', total: 100);
    test('warranty and return-by in range of confirmed live bills; never counted', () {
      final items = upcoming(
          planned: const [],
          bills: const [],
          events: const [],
          from: today,
          to: '2026-03-31',
          billsDb: const [
            b,
            Bill(id: 'r', warrantyUntil: '2026-03-05'),
            Bill(id: 'd', status: BillStatus.confirmed, returnBy: '2026-03-05', deleted: true)
          ]);
      expect([
        for (final i in items) (i.kind, i.key, i.date, i.title, i.amount)
      ], [
        (UpcomingKind.returnBy, 'r:b1', '2026-03-04', 'Synthetic Shop', null),
        (UpcomingKind.warranty, 'w:b1', '2026-03-20', 'Synthetic Shop', null),
      ]);
      expect(items.first.billDb, b);
      expect(headsUps(items, today, thresholdCents: 0, days: 30), isEmpty);
      expect(upcoming(planned: const [], bills: const [], events: const [], from: today, to: '2026-03-10'), isEmpty,
          reason: 'existing callers are unchanged');
    });

    test('settings returnReminderDays (3, 0..30) and warrantyReminderDays (14, 0..90)', () {
      const d = WalletSettings();
      expect((d.returnReminderDays, d.warrantyReminderDays), (3, 14));
      final s = WalletSettings.fromMap({'returnReminderDays': 30, 'warrantyReminderDays': 0});
      expect((s.returnReminderDays, s.warrantyReminderDays), (30, 0));
      final bad = WalletSettings.fromMap({'returnReminderDays': 31, 'warrantyReminderDays': -1});
      expect((bad.returnReminderDays, bad.warrantyReminderDays), (3, 14));
      repo.updateSettings({'returnReminderDays': 7});
      expect(repo.settings().returnReminderDays, 7);
      expect(repo.settings().toMap()['warrantyReminderDays'], 14);
    });
  });

  group('searchAll billsDb', () {
    test('payee, description, item names folded; exact total; deleted never', () {
      const a = Bill(id: 'a', payee: 'Pekara Đurđa', total: 1234, items: [BillItem(name: 'Kruh', amount: 1234)]);
      const del = Bill(id: 'd', payee: 'Pekara', deleted: true);
      SearchResult s(String q) =>
          searchAll(q, txs: const [], goals: const [], wishlist: const [], bills: const [], billsDb: const [a, del]);
      expect(s('durda').billsDb, [a]);
      expect(s('kruh').billsDb, [a]);
      expect(s('12,34').billsDb, [a]);
      expect(s('12,35').billsDb, isEmpty);
      expect(s('pekara').billsDb, [a]);
      expect(s('pekara').isEmpty, isFalse);
    });
  });

  group('storage', () {
    test('a schema-6 database opens with the bills table and replays the relay once', () {
      final tmp = Directory.systemTemp.createTempSync('bw-bills-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/w.db';
      final old = WalletRepo.open(path);
      old.setSyncCursor('dev', 3);
      old.db.execute("UPDATE meta SET value = '6' WHERE key = 'schema'");
      for (final t in ['bills', 'blob_cache', 'blob_outbox', 'blob_delete']) {
        old.db.execute('DROP TABLE $t');
      }
      old.close();
      final up = WalletRepo.open(path);
      expect(up.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
      expect(up.syncCursors(), isEmpty);
      expect(up.bills(), isEmpty);
      up.importBill(slip());
      expect(up.bills(), hasLength(1));
      up.close();
    });

    test('a backup carries bills (deleted ones too) but never the files or their queues', () async {
      final key = VaultKey.generate();
      final (id, _) = repo.importBill(slip(), file: const BlobRef(hash: 'ab', type: 'jpg', bytes: 3));
      repo.putCachedBlob('ab', [1, 2, 3], queue: true);
      repo.confirmWithCategory(id);
      final (gone, _) = repo.importBill(slip(ext: 'jir:gone'));
      repo.deleteBill(gone);
      expect(repo.isEmpty, isFalse);
      final bytes = await backupBytes(repo, key);
      final into = WalletRepo.inMemory(now: () => now);
      addTearDown(into.close);
      await restoreBackupBytes(into, bytes, key);
      expect(dump(into, clocks: false)['bills'], dump(repo, clocks: false)['bills']);
      expect(into.bill(id)!.file!.hash, 'ab');
      expect(into.queuedBlobs(), isEmpty);
      expect(into.cachedBlob('ab'), isNull);
      expect(plannedOf(id), isNotNull);
    });

    test('a wallet holding only a bill is not empty', () {
      repo.importBill(slip());
      expect(repo.isEmpty, isFalse);
    });

    test('logs carry no payee, reference, external id or amount', () {
      final lines = <String>[];
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      addTearDown(sub.cancel);
      Logger.root.level = Level.ALL;
      final (id, _) = repo.importBill(slip());
      repo.confirmWithCategory(id);
      repo.importBatch(rows([n('2026-03-05', -4599, 'Nalog', 'HR01 1234-5678')]));
      repo.updateBill(id, note: 'secret note');
      repo.deleteBill(id);
      final all = lines.join('\n');
      for (final bad in ['Synthetic Utility', '1234', '4599', '45.99', 'HR00TEST', 'secret', id.substring(5)]) {
        expect(all, isNot(contains(bad)), reason: bad);
      }
      expect(all, contains('bills.import'));
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
      tmp = Directory.systemTemp.createTempSync('bw-bills2-');
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

    test('the same slip scanned on both: one bill id; a confirm on one and a link on the other converge', () async {
      final a = device('a'), b = device('b');
      final (idA, _) = a.repo.importBill(slip());
      now += 1000;
      final (idB, _) = b.repo.importBill(slip());
      expect(idA, idB);
      await round();
      await round();
      expect(a.repo.bills(), hasLength(1));
      a.repo.confirmWithCategory(idA);
      await round();
      await round();
      expect(b.repo.bill(idA)!.confirmed, isTrue, reason: "b's later import never undid the confirm");
      final tx = b.repo.addTransaction(date: '2026-03-01', amount: 4599, category: 'Groceries');
      b.repo.linkBill(idA, tx);
      await round();
      await round();
      expect(a.repo.bill(idA)!.linkedTx, tx);
      expect(dump(a.repo, clocks: false)['bills'], dump(b.repo, clocks: false)['bills']);
      expect(dump(a.repo, clocks: false)['planned'], dump(b.repo, clocks: false)['planned']);
      final p = a.repo.plannedCosts(includeClosed: true).single;
      expect((p.status, p.paidTx), (PlannedStatus.paid, tx));
    });

    test('auto link after sync: the bill from one device, the bank row from the other, linked once on both', () async {
      final a = device('a'), b = device('b');
      final (id, _) = a.repo.importBill(slip());
      a.repo.confirmWithCategory(id);
      b.repo.importBatch(rows([n('2026-03-05', -4599, 'Nalog', 'HR01 1234-5678')]));
      for (var i = 0; i < 3; i++) {
        await round();
      }
      final txId = a.repo.transactions().single.id;
      expect(a.repo.bill(id)!.linkedTx, txId);
      expect(b.repo.bill(id)!.linkedTx, txId);
      expect(dump(a.repo, clocks: false)['bills'], dump(b.repo, clocks: false)['bills']);
    });
  });
}
