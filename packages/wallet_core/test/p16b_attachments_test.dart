// P16b (docs/context/P16_SPEC.md "P16b: attachments"): a photo or PDF attached to a payment is a bill row with source
// attachment, linked to the payment, confirmed and paid. It is listed only on its payment (never in the bill lists,
// matching, candidates, planned rows, search or reminders), at most 5 live per payment, and rides on P14's blob rules
// (uploaded before its op, declared by snapshots, carried by backups). All data is SYNTHETIC.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/bill_helpers.dart';
import 'support/synthetic.dart';

Uint8List bytesOf(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

ImportBatch rows(List<NormalizedTransaction> t) => ImportBatch(source: 'pbz', transactions: t);

/// A synthetic payment slip whose reference a bank row can carry (auto link).
NormalizedBill slip({int total = 4599}) => NormalizedBill(
    source: BillSource.hub3,
    externalId: 'hub3:HR00TEST:HR01 1234-5678:$total',
    date: '2026-02-27',
    dueDate: '2026-03-10',
    total: total,
    payee: 'Synthetic Utility',
    reference: 'HR01 1234-5678');

final payRow = n('2026-03-05', -4599, 'Nalog', 'UPLATA HR01 1234-5678 SYNTHETIC UTILITY');

void main() {
  late VaultKey key;
  late MemoryTransport relay;
  var now = DateTime.utc(2026, 3, 1, 12);
  final repos = <WalletRepo>[];
  WalletRepo mk() {
    final r = WalletRepo.inMemory(now: () => now.millisecondsSinceEpoch);
    repos.add(r);
    return r;
  }

  Future<SyncReport> run(WalletRepo r) => SyncEngine(relay, key, now: () => now).run(r);
  var seed = 100;
  Future<BlobRef> file(WalletRepo r, [String type = 'jpg']) => BlobStore(r, key).add(bytesOf(300, seed++), type);

  setUp(() {
    key = VaultKey.generate();
    now = DateTime.utc(2026, 3, 1, 12);
    relay = MemoryTransport(now: () => now);
  });
  tearDown(() {
    for (final r in repos) {
      r.close();
    }
    repos.clear();
  });

  /// A wallet with one bank payment; returns (repo, its tx id).
  (WalletRepo, String) withPayment() {
    final r = mk();
    r.importBatch(rows([payRow]));
    return (r, r.transactions().single.id);
  }

  group('addAttachment', () {
    test('stores a confirmed, paid bill row of source attachment with the payment\'s date, |amount| and currency', () async {
      final (r, tx) = withPayment();
      final f = await file(r, 'pdf');
      final id = r.addAttachment(tx, f);
      final a = r.bill(id)!;
      expect((a.source, a.status, a.linkedTx, a.paid, a.date, a.total, a.currency, a.deleted),
          (BillSource.attachment, BillStatus.confirmed, tx, true, '2026-03-05', 4599, 'EUR', false));
      expect(a.isAttachment, isTrue);
      expect(a.file, f);
      expect((a.dueDate, a.payee, a.category, a.warrantyUntil, a.returnBy), (null, null, null, null, null));
      expect(r.attachments(tx).map((b) => b.id), [id]);
      expect(r.pendingBlobRefs(), {f.hash}, reason: 'its op references the file, so the file goes up first');
    });

    test('an income keeps a positive total; a hand-added expense takes attachments too', () async {
      final r = mk();
      r.importBatch(rows([n('2026-03-02', 120000, 'Uplata', 'SYNTHETIC EMPLOYER SALARY')]));
      final income = r.transactions().single.id;
      final cash = r.addTransaction(date: '2026-03-03', amount: -1250, category: 'Groceries');
      expect(r.bill(r.addAttachment(income, await file(r)))!.total, 120000);
      expect(r.bill(r.addAttachment(cash, await file(r, 'png')))!.total, 1250);
    });

    test('an unknown or deleted payment and a file type bills do not take: ArgumentError, nothing written', () async {
      final (r, tx) = withPayment();
      final f = await file(r);
      expect(() => r.addAttachment('no-such-tx', f), throwsArgumentError);
      expect(() => r.addAttachment(tx, BlobRef(hash: f.hash, type: 'gif', bytes: f.bytes)), throwsArgumentError);
      final xml = await file(r, 'xml'); // a bill may keep an e-invoice; an attachment is a photo or PDF only
      expect(() => r.addAttachment(tx, xml), throwsArgumentError);
      expect(attachmentTypes, {'jpg', 'png', 'pdf'});
      expect(() => r.addAttachment(tx, const BlobRef(hash: 'not-a-hash', type: 'jpg', bytes: 1)), throwsArgumentError);
      r.deleteTransaction(tx);
      expect(() => r.addAttachment(tx, f), throwsArgumentError);
      expect(r.bills(includeDeleted: true, includeAttachments: true), isEmpty);
    });

    test('at most 5 live per payment: the 6th is a StateError; a removed one frees a place; another payment is apart', () async {
      final r = mk();
      r.importBatch(rows([payRow, n('2026-03-06', -900, 'POS', 'SYNTHETIC SHOP')]));
      final tx = r.transactions().firstWhere((t) => t.amount == -4599).id;
      final other = r.transactions().firstWhere((t) => t.amount == -900).id;
      final ids = [for (var i = 0; i < maxAttachmentsPerTx; i++) r.addAttachment(tx, await file(r))];
      expect(maxAttachmentsPerTx, 5);
      final sixth = await file(r);
      expect(() => r.addAttachment(tx, sixth), throwsStateError);
      expect(r.attachments(tx), hasLength(5));
      expect(r.addAttachment(other, sixth), isNotNull, reason: 'the cap is per payment');
      r.removeAttachment(ids[2]);
      final again = r.addAttachment(tx, sixth);
      expect(r.attachments(tx).map((b) => b.id), [...ids.take(2), ...ids.skip(3), again]);
    });

    test('oldest first; removed ones and other payments\' are not listed', () async {
      final r = mk();
      r.importBatch(rows([payRow, n('2026-03-06', -900, 'POS', 'SYNTHETIC SHOP')]));
      final tx = r.transactions().firstWhere((t) => t.amount == -4599).id;
      final other = r.transactions().firstWhere((t) => t.amount == -900).id;
      final a1 = r.addAttachment(tx, await file(r));
      now = now.add(const Duration(minutes: 1));
      final a2 = r.addAttachment(tx, await file(r));
      r.addAttachment(other, await file(r));
      now = now.add(const Duration(minutes: 1));
      final a3 = r.addAttachment(tx, await file(r));
      expect(r.attachments(tx).map((b) => b.id), [a1, a2, a3]);
      r.removeAttachment(a2);
      expect(r.attachments(tx).map((b) => b.id), [a1, a3]);
      r.restoreAttachment(a2);
      expect(r.attachments(tx).map((b) => b.id), [a1, a2, a3], reason: 'a restore keeps its place');
      expect(r.attachments('no-such-tx'), isEmpty);
    });
  });

  group('remove and restore', () {
    test('remove is a soft delete; restore (Undo) brings it back with its file; twice is a no-op', () async {
      final (r, tx) = withPayment();
      final f = await file(r);
      final id = r.addAttachment(tx, f);
      r.removeAttachment(id);
      expect(r.bill(id)!.deleted, isTrue);
      expect(r.attachments(tx), isEmpty);
      expect(r.hasCachedBlob(f.hash), isTrue, reason: 'clients never delete files (P14)');
      final ops = r.pendingOps().length;
      r.removeAttachment(id);
      expect(r.pendingOps().length, ops, reason: 'already removed: nothing written');
      r.restoreAttachment(id);
      expect(r.attachments(tx).single.file, f);
      r.restoreAttachment(id);
      expect(r.pendingOps().length, ops + 1, reason: 'live already: nothing written');
    });

    test('restore over the cap is a StateError and writes nothing', () async {
      final (r, tx) = withPayment();
      final first = r.addAttachment(tx, await file(r));
      r.removeAttachment(first);
      for (var i = 0; i < 5; i++) {
        r.addAttachment(tx, await file(r));
      }
      final ops = r.pendingOps().length;
      expect(() => r.restoreAttachment(first), throwsStateError);
      expect((r.bill(first)!.deleted, r.pendingOps().length), (true, ops));
    });

    test('unknown ids and real bills: ArgumentError (and the bill calls refuse attachments)', () async {
      final (r, tx) = withPayment();
      final (billId, _) = r.importBill(slip());
      final att = r.addAttachment(tx, await file(r));
      for (final call in [r.removeAttachment, r.restoreAttachment]) {
        expect(() => call('no-such-id'), throwsArgumentError);
        expect(() => call(billId), throwsArgumentError);
      }
      expect(() => r.updateBill(att, note: 'x'), throwsArgumentError);
      expect(() => r.confirmBill(att), throwsArgumentError);
      expect(() => r.unlinkBill(att), throwsArgumentError);
      expect(() => r.deleteBill(att), throwsArgumentError);
      expect(() => r.linkBill(att, tx), throwsArgumentError);
      expect(() => r.addExpenseFromBill(att, category: 'Groceries'), throwsArgumentError);
      expect(r.bill(att)!.linkedTx, tx);
    });
  });

  group('invisible outside its payment', () {
    test('never in bills() (deleted ones included) unless asked; never a planned row, so never reserved', () async {
      final (r, tx) = withPayment();
      final att = r.addAttachment(tx, await file(r));
      expect(r.bills(), isEmpty);
      expect(r.bills(includeDeleted: true), isEmpty);
      expect(r.bills(includeAttachments: true).map((b) => b.id), [att]);
      r.importBatch(rows([n('2026-03-07', -100, 'POS', 'SYNTHETIC KIOSK')])); // reconcile + repairs run
      expect(r.plannedCosts(includeClosed: true), isEmpty);
      r.removeAttachment(att);
      expect(r.bills(includeDeleted: true), isEmpty);
      expect(r.bills(includeDeleted: true, includeAttachments: true).single.deleted, isTrue);
    });

    test('a real bill auto-links to a payment that holds an attachment, and keeps its link when one is added later', () async {
      final (r, tx) = withPayment();
      final att = r.addAttachment(tx, await file(r));
      final (billId, _) = r.importBill(slip());
      r.confirmWithCategory(billId);
      expect(r.bill(billId)!.linkedTx, tx, reason: 'the attachment does not take the row');
      final att2 = r.addAttachment(tx, await file(r));
      r.importBatch(rows([n('2026-03-07', -100, 'POS', 'SYNTHETIC KIOSK')])); // reconcile: field-pair repair
      expect(r.bill(billId)!.linkedTx, tx);
      expect(r.attachments(tx).map((b) => b.id), [att, att2]);
      expect(r.plannedCosts(includeClosed: true).single.status, PlannedStatus.paid);
    });

    test('a hand link: linkBill takes a payment with attachments; unlinking the bill leaves them', () async {
      final r = mk();
      r.importBatch(rows([n('2026-03-05', -4599, 'Nalog', 'SYNTHETIC TRANSFER NO TOKEN')]));
      final tx = r.transactions().single.id;
      final att = r.addAttachment(tx, await file(r));
      final (billId, _) = r.importBill(slip());
      r.confirmWithCategory(billId);
      expect(r.bill(billId)!.linkedTx, isNull);
      r.linkBill(billId, tx);
      expect(r.bill(billId)!.linkedTx, tx);
      r.unlinkBill(billId);
      expect(r.attachments(tx).single.id, att);
    });

    test('a deleted payment unlinks its bill but keeps its attachments; undelete brings both back', () async {
      final (r, tx) = withPayment();
      final (billId, _) = r.importBill(slip());
      r.confirmWithCategory(billId);
      final att = r.addAttachment(tx, await file(r));
      r.deleteTransaction(tx);
      expect(r.bill(billId)!.linkedTx, isNull);
      expect(r.bill(att)!.linkedTx, tx, reason: 'an attachment stays on its payment');
      r.importBatch(rows([n('2026-03-07', -100, 'POS', 'SYNTHETIC KIOSK')])); // _autoLinkBills' unlink of deleted rows
      expect(r.bill(att)!.linkedTx, tx);
      r.undeleteTransaction(tx);
      expect(r.bill(billId)!.linkedTx, tx);
      expect(r.attachments(tx).single.id, att);
    });

    test('pure rules: planBillLinks and billCandidates neither use nor count attachments', () async {
      final (r, tx) = withPayment();
      final att = r.bill(r.addAttachment(tx, await file(r)))!;
      final (billId, _) = r.importBill(slip());
      r.updateBill(billId, category: testBillCategory);
      final real = Bill.fromRow({
        ...r.db.select('SELECT * FROM bills WHERE id = ?', [billId]).first,
        'status': 'confirmed'
      });
      final txs = r.transactions();
      expect(planBillLinks([att, real], txs), {billId: tx});
      final cz = r.categorizer();
      final cats = [for (final t in txs) cz.categorize(t)];
      expect(billCandidates(real, cats, [att, real]).map((c) => c.tx.id), [tx]);
      expect(billCandidates(att, cats, [att, real]), isEmpty);
    });

    test('search never finds one (stored bills or raw rows); no warranty or return reminder', () async {
      final (r, tx) = withPayment();
      final att = r.bill(r.addAttachment(tx, await file(r)))!;
      final res = searchAll('45.99',
          txs: const [],
          goals: const [],
          wishlist: const [],
          bills: const [],
          billsDb: r.bills(includeAttachments: true),
          rows: {'bill': r.db.select('SELECT * FROM bills')});
      expect(res.billsDb, isEmpty);
      expect(res.rows['bill'], isEmpty);
      final dated = Bill(
          id: att.id,
          source: BillSource.attachment,
          status: BillStatus.confirmed,
          linkedTx: tx,
          total: 4599,
          warrantyUntil: '2026-03-20',
          returnBy: '2026-03-10');
      expect(
          upcoming(planned: const [], bills: const [], events: const [], from: '2026-03-01', to: '2026-04-30', billsDb: [dated]), isEmpty);
    });
  });

  group('files (P14 invariants)', () {
    test('in the declared set and the backup candidates while live; out after remove, back after restore', () async {
      final (r, tx) = withPayment();
      final f = await file(r, 'pdf');
      final id = r.addAttachment(tx, f);
      expect(r.liveBlobHashes(), [f.hash]);
      expect(r.backupBlobCandidates().map((e) => e.$1), [f.hash]);
      r.removeAttachment(id);
      expect(r.liveBlobHashes(), isEmpty);
      expect(r.backupBlobCandidates(), isEmpty);
      r.restoreAttachment(id);
      expect(r.liveBlobHashes(), [f.hash]);
      expect(r.pendingBlobRefs(), {f.hash}, reason: 'the undelete op references the file again');
    });

    test('goes into a backup and comes back on restore with its file', () async {
      final (r, tx) = withPayment();
      final f = await file(r);
      final id = r.addAttachment(tx, f);
      final info = await backupBytesWithInfo(r, key);
      expect(info.blobs, 1);
      final payload = jsonDecode(utf8.decode(await unseal(info.bytes, key, aad: aadBackup))) as Map;
      expect((payload['blobs'] as Map).keys, [f.hash]);
      final fresh = mk();
      await restoreBackupBytes(fresh, info.bytes, key);
      expect(fresh.attachments(tx).single.id, id);
      expect(fresh.attachments(tx).single.file, f);
      expect(fresh.hasCachedBlob(f.hash), isTrue);
      expect(fresh.bills(), isEmpty);
    });

    test('the file is uploaded before its op; a snapshot declares it', () async {
      final (r, tx) = withPayment();
      final f = await file(r);
      r.addAttachment(tx, f);
      await run(r);
      expect(relay.blobs.keys, contains(f.hash));
      now = now.add(const Duration(days: 8));
      r.updateSettings({'returnReminderDays': 5});
      await run(r);
      expect(relay.declared.values.last, [f.hash]);
    });
  });

  group('a hand-added entry replaced by its bank row', () {
    final card = n('2026-03-06', -1250, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB');

    /// A cash expense with [k] attachments, then its card row imported (matching replaces the entry).
    Future<(WalletRepo, String, List<String>)> entryWith(int k) async {
      final r = mk();
      final cash = r.addTransaction(date: '2026-03-05', amount: 1250, category: 'Groceries');
      final ids = [for (var i = 0; i < k; i++) r.addAttachment(cash, await file(r))];
      return (r, cash, ids);
    }

    String bankOf(WalletRepo r) => r.transactions().firstWhere((t) => !t.manual).id;

    test('BUG repro: its attachments move to the bank row', () async {
      final (r, cash, ids) = await entryWith(2);
      expect(r.importBatch(rows([card])).matched, 1);
      final bank = bankOf(r);
      expect(r.transaction(cash)!.matchedTo, bank);
      expect(r.attachments(bank).map((b) => b.id), ids);
      expect(r.attachments(cash), isEmpty);
      expect(r.bills(), isEmpty);
    });

    test('the cap is not enforced on a move: 3 + 3 = 6 on the bank row, nothing removed', () async {
      final r = mk();
      r.importBatch(rows([n('2026-03-01', -900, 'POS', 'SYNTHETIC SHOP')]));
      final cash = r.addTransaction(date: '2026-03-05', amount: 1250, category: 'Groceries');
      final onCash = [for (var i = 0; i < 3; i++) r.addAttachment(cash, await file(r))];
      // The bank row arrives while not caught up (no match yet); the owner attaches 3 to it.
      r.setLocalValue(WalletRepo.caughtUpKey, '0');
      r.importBatch(rows([card]));
      final bankRow = r.transactions().firstWhere((t) => t.amount == -1250 && !t.manual).id;
      expect(r.transaction(cash)!.matchedTo, isNull);
      final onBank = [for (var i = 0; i < 3; i++) r.addAttachment(bankRow, await file(r))];
      r.setLocalValue(WalletRepo.caughtUpKey, '1');
      r.runPendingMatch();
      expect(r.transaction(cash)!.matchedTo, bankRow);
      expect(r.attachments(bankRow).map((b) => b.id).toSet(), {...onCash, ...onBank});
      expect(r.bills(includeDeleted: true, includeAttachments: true).where((b) => b.deleted), isEmpty);
    });

    test('a deleted bank row: the entry counts again, the attachments stay on the bank row; Undo shows them again', () async {
      final (r, cash, ids) = await entryWith(1);
      r.importBatch(rows([card]));
      final bank = bankOf(r);
      r.deleteTransaction(bank);
      expect(r.transaction(cash)!.matchedTo, isNull);
      expect(r.bill(ids.single)!.linkedTx, bank, reason: 'rule: once moved, an attachment stays on the bank row');
      expect(r.bill(ids.single)!.deleted, isFalse, reason: 'never deleted');
      r.undeleteTransaction(bank);
      expect(r.transaction(cash)!.matchedTo, bank);
      expect(r.attachments(bank).single.id, ids.single);
    });

    test('two devices converge: the entry\'s device and the importing device both move it to the bank row', () async {
      final a = mk(), b = mk();
      final cash = a.addTransaction(date: '2026-03-05', amount: 1250, category: 'Groceries');
      final id = a.addAttachment(cash, await file(a));
      await run(a);
      await run(b);
      b.importBatch(rows([card]));
      final bank = bankOf(b);
      expect(b.attachments(bank).single.id, id);
      await run(b);
      await run(a);
      await run(b);
      for (final r in [a, b]) {
        expect(r.transaction(cash)!.matchedTo, bank);
        expect(r.bill(id)!.linkedTx, bank);
        expect(r.attachments(cash), isEmpty);
      }
      expect(a.pendingOps(), isEmpty, reason: 'a wrote the same value, or nothing');
    });
  });

  group('two devices', () {
    test('both attach to the same payment: all survive the merge; 6 live after it are kept (cap only on new adds)', () async {
      final a = mk(), b = mk();
      a.importBatch(rows([payRow]));
      final (billId, _) = a.importBill(slip());
      a.confirmWithCategory(billId);
      await run(a);
      await run(b);
      final tx = b.transactions().single.id;
      expect(b.bill(billId)!.linkedTx, tx);
      final fromA = [for (var i = 0; i < 3; i++) a.addAttachment(tx, await file(a))];
      final fromB = [for (var i = 0; i < 3; i++) b.addAttachment(tx, await file(b))];
      await run(a);
      await run(b);
      await run(a);
      for (final r in [a, b]) {
        final list = r.attachments(tx).map((x) => x.id).toList();
        expect(list.toSet(), {...fromA, ...fromB}, reason: 'never delete data: six live after the merge');
        expect(r.bill(billId)!.linkedTx, tx, reason: 'the real bill keeps its payment');
        expect(r.bills().map((x) => x.id), [billId]);
        expect(r.liveBlobHashes(), hasLength(6));
        expect(() => r.addAttachment(tx, BlobRef(hash: r.attachments(tx).first.blob!, type: 'jpg', bytes: 1)), throwsStateError);
      }
      expect(a.attachments(tx).map((x) => x.id), b.attachments(tx).map((x) => x.id), reason: 'same order on both');
      // Over the cap: a removed one comes back only once the payment is below 5 again.
      a.removeAttachment(fromA[0]);
      expect(() => a.restoreAttachment(fromA[0]), throwsStateError, reason: '5 live');
      a.removeAttachment(fromB[0]);
      a.restoreAttachment(fromA[0]);
      expect(a.attachments(tx), hasLength(5));
      await run(a);
      await run(b);
      expect(b.attachments(tx).map((x) => x.id).toSet(), {...fromA, ...fromB.skip(1)});
      expect(
          relay.blobs.keys.toSet(),
          containsAll({
            for (final r in [a, b]) ...r.liveBlobHashes()
          }));
    });

    test('a remove on one device and a restore on the other: the later write wins', () async {
      final a = mk(), b = mk();
      a.importBatch(rows([payRow]));
      final tx = a.transactions().single.id;
      final id = a.addAttachment(tx, await file(a));
      await run(a);
      await run(b);
      b.removeAttachment(id);
      await run(b);
      await run(a);
      expect(a.attachments(tx), isEmpty);
      now = now.add(const Duration(seconds: 5));
      a.restoreAttachment(id);
      await run(a);
      await run(b);
      expect(b.attachments(tx).single.id, id);
    });
  });
}
