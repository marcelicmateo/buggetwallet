// D2 Unlink: the owner undoes a wrong automatic cash match (`unlinkMatch`, schema 19 `tx.match_off`) and its Undo
// (`relinkMatch`). The entry counts again, the bank row stays, and matching never pairs the two again on any device.
// All data is SYNTHETIC.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _st = WalletSettings(salary: 100000, paydayDay: 15, periodStart: '2026-01-15');
const _today = '2026-01-25';

ImportBatch _pos(List<(String, int, String)> rows) =>
    ImportBatch(source: 'pbz', transactions: [for (final (d, a, m) in rows) n(d, a, 'POS plaćanje', m, kind: TxKind.card)]);

String _bankId(String date, int cents, String desc) => transactionId(date, cents, desc, 0);

int _spent(WalletRepo r) {
  final cz = r.categorizer();
  return computePeriod([for (final t in r.transactions()) ...cz.expand(t)], _st, const [], _today, table: CategoryTable.builtIn).spent;
}

Map<String, Object?> _row(WalletRepo r, String id) => Map<String, Object?>.from(r.db.select('SELECT * FROM tx WHERE id = ?', [id]).first);

String? _off(WalletRepo r, String id) => r.db.select('SELECT match_off FROM tx WHERE id = ?', [id]).first['match_off'] as String?;

void main() {
  var t = 1768989600000; // 2026-01-21
  int now() => t += 1000;

  /// A wallet holding cash entry `entry` (-2.40, 19 Jan, Eating out) replaced by card row `bank` (20 Jan).
  (WalletRepo, String, String) matched() {
    final r = WalletRepo.inMemory(now: now);
    addTearDown(r.close);
    final entry = r.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out', note: 'synthetic coffee');
    r.importBatch(_pos([('2026-01-20', -240, 'POS SYNTH CAFE')]));
    final bank = _bankId('2026-01-20', -240, 'POS SYNTH CAFE');
    expect(r.transaction(entry)!.matchedTo, bank, reason: 'precondition: matched');
    return (r, entry, bank);
  }

  group('unlinkMatch', () {
    test('the entry counts again (spent grows by exactly its amount), the bank row is unchanged, matching does not re-pair', () {
      final (r, entry, bank) = matched();
      final spentBefore = _spent(r), bankBefore = _row(r, bank);
      r.unlinkMatch(entry);
      expect(r.transaction(entry)!.matchedTo, isNull);
      expect(r.transaction(entry)!.live, isTrue);
      expect(_spent(r) - spentBefore, 240, reason: 'exactly the entry amount counts again');
      expect(_row(r, bank), bankBefore, reason: 'the bank row stays as it was');
      expect(matchOffIds(_off(r, entry)), {bank});
      // Matching runs again after any import (an overlapping export with the same row, plus a new unrelated one).
      final again = r.importBatch(_pos([('2026-01-20', -240, 'POS SYNTH CAFE'), ('2026-01-22', -9900, 'POS SYNTH SHOP')]));
      expect(again.matched, 0);
      expect(r.transaction(entry)!.matchedTo, isNull);
      expect(r.transactions().where((x) => x.amount == -240).length, 2, reason: 'two coffees now, both count');
    });

    test('the unlink is one synced owner write on the entry only', () {
      final (r, entry, bank) = matched();
      final before = r.pendingOps().length;
      r.unlinkMatch(entry);
      final ops = [for (final (_, op) in r.pendingOps().skip(before)) op];
      expect(ops.map((o) => o.id).toSet(), {entry});
      final fields = {for (final o in ops) ...o.fields};
      expect(fields['matched_to'], isNull);
      expect(fields.containsKey('matched_to'), isTrue);
      expect(matchOffIds(fields['match_off'] as String?), {bank});
    });

    test('a match onto an unlinked row made by an older build (it ignores match_off) is reopened', () {
      final (r, entry, bank) = matched();
      r.unlinkMatch(entry);
      t += 60000;
      r.applyRemote([
        Op('tx', entry, {'matched_to': bank}, Hlc(t, 0, 'old-build').toString())
      ]);
      expect(r.transaction(entry)!.matchedTo, isNull, reason: 'reopened again by planMatches');
      expect(matchOffIds(_off(r, entry)), {bank});
    });

    test('the entry may still match another bank row', () {
      final (r, entry, bank) = matched();
      r.unlinkMatch(entry);
      final other = r.importBatch(_pos([('2026-01-21', -240, 'POS SYNTH BAKERY')]));
      expect(other.matched, 1);
      expect(r.transaction(entry)!.matchedTo, _bankId('2026-01-21', -240, 'POS SYNTH BAKERY'));
      expect(matchOffIds(_off(r, entry)), {bank}, reason: 'only that pair is excluded');
      // Unlinking the second one keeps both exclusions, so it does not jump back to the first row.
      r.unlinkMatch(entry);
      expect(r.transaction(entry)!.matchedTo, isNull);
      expect(matchOffIds(_off(r, entry)), {bank, _bankId('2026-01-21', -240, 'POS SYNTH BAKERY')});
    });

    test('a candidate already in the wallet takes the entry at once (the state shown is the final one)', () {
      final r = WalletRepo.inMemory(now: now);
      addTearDown(r.close);
      final entry = r.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
      r.importBatch(_pos([('2026-01-19', -240, 'POS SYNTH CAFE'), ('2026-01-21', -240, 'POS SYNTH KIOSK')]));
      expect(r.transaction(entry)!.matchedTo, _bankId('2026-01-19', -240, 'POS SYNTH CAFE'), reason: 'the closest row');
      r.unlinkMatch(entry);
      expect(r.transaction(entry)!.matchedTo, _bankId('2026-01-21', -240, 'POS SYNTH KIOSK'));
    });

    test('another entry may take the freed bank row, and the Undo then refuses it', () {
      final r = WalletRepo.inMemory(now: now);
      addTearDown(r.close);
      final a = r.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
      final b = r.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
      r.importBatch(_pos([('2026-01-19', -240, 'POS SYNTH CAFE'), ('2026-01-20', -240, 'POS SYNTH KIOSK')]));
      final ra = r.transaction(a)!.matchedTo!, rb = r.transaction(b)!.matchedTo!;
      expect(ra, isNot(rb));
      r.unlinkMatch(a);
      expect(r.transaction(a)!.matchedTo, isNull, reason: 'ra is excluded and rb is taken by b');
      r.unlinkMatch(b);
      // b takes ra (not excluded for b); a takes rb (excluded only for b).
      expect(r.transaction(b)!.matchedTo, ra);
      expect(r.transaction(a)!.matchedTo, rb);
      expect(() => r.relinkMatch(a, ra), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('another expense'))));
    });
  });

  group('matchedBankIds', () {
    test('lists live bank rows that replaced a live entry; not an unlinked pair, a deleted entry or a missing row', () {
      final (r, entry, bank) = matched();
      expect(r.matchedBankIds(), {bank});
      r.unlinkMatch(entry);
      expect(r.matchedBankIds(), isEmpty, reason: 'unlinked');
      r.relinkMatch(entry, bank);
      expect(r.matchedBankIds(), {bank});
      r.deleteTransaction(entry);
      expect(r.matchedBankIds(), isEmpty, reason: 'the entry is deleted');
      // An entry whose bank row has not arrived (pending) marks nothing.
      t += 60000;
      r.applyRemote([
        Op(
            'tx',
            'm-remote',
            {'source': 'manual', 'date': '2026-01-19', 'amount': -500, 'manual': 1, 'deleted': 0, 'matched_to': 'x-not-here'},
            Hlc(t, 0, 'other').toString()),
      ]);
      expect(r.matchedBankIds(), isEmpty);
    });
  });

  group('split and tags after unlink', () {
    test('the bank row stops reading the entry split; tags matching copied stay on the bank row', () async {
      final r = WalletRepo.inMemory(now: now);
      addTearDown(r.close);
      final entry = r.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
      final tag = await r.addTag('Synth trip');
      await r.setTxTag(entry, tag, true);
      r.setSplit(entry, const [SplitPart(amount: -100, category: 'Eating out'), SplitPart(amount: -140, category: 'Groceries')]);
      r.importBatch(_pos([('2026-01-20', -240, 'POS SYNTH CAFE')]));
      final bank = _bankId('2026-01-20', -240, 'POS SYNTH CAFE');
      expect(r.transaction(entry)!.matchedTo, bank);
      expect(r.splitOf(bank), hasLength(2), reason: 'read through the match');
      bool tagged(String id) => r.db.select("SELECT 1 FROM tx_tags WHERE tx = ? AND tag = ? AND state = 'on'", [id, tag]).isNotEmpty;
      expect(tagged(bank), isTrue, reason: 'matching copied the tag');

      r.unlinkMatch(entry);
      expect(r.splitOf(bank), isNull, reason: 'the split is read through matched_to only');
      expect(r.splitOf(entry), hasLength(2), reason: 'the entry keeps its own split');
      expect(tagged(bank), isTrue, reason: 'what matching copied stays, as when any match reopens');
      expect(tagged(entry), isTrue);
      final cz = r.categorizer();
      expect([for (final x in cz.expand(r.transaction(bank)!)) x.amount], [-240], reason: 'the bank row counts whole');

      r.relinkMatch(entry, bank);
      expect(r.splitOf(bank), hasLength(2), reason: 'the Undo reads the split again');
    });
  });

  group('attachments', () {
    test('attachments moved to the bank row stay there', () async {
      final r = WalletRepo.inMemory(now: now);
      addTearDown(r.close);
      final key = VaultKey.generate();
      final entry = r.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
      final f = await BlobStore(r, key).add(Uint8List.fromList(List.generate(300, (i) => i % 251)), 'jpg');
      r.addAttachment(entry, f);
      r.importBatch(_pos([('2026-01-20', -240, 'POS SYNTH CAFE')]));
      final bank = _bankId('2026-01-20', -240, 'POS SYNTH CAFE');
      expect(r.attachments(bank), hasLength(1), reason: 'moved by the match');
      r.unlinkMatch(entry);
      expect(r.attachments(bank), hasLength(1));
      expect(r.attachments(entry), isEmpty);
    });
  });

  group('relinkMatch (Undo)', () {
    test('round trip: the state, the totals and the stored fields come back', () {
      final (r, entry, bank) = matched();
      final spent = _spent(r), entryRow = _row(r, entry), bankRow = _row(r, bank);
      r.unlinkMatch(entry);
      r.relinkMatch(entry, bank);
      expect(_spent(r), spent);
      expect(_row(r, entry), entryRow, reason: 'matched_to back, match_off cleared (null)');
      expect(_row(r, bank), bankRow);
      r.importBatch(_pos([('2026-01-22', -9900, 'POS SYNTH SHOP')]));
      expect(r.transaction(entry)!.matchedTo, bank, reason: 'matching keeps the restored match');
    });

    test('the Undo frees a row matching gave the entry after the unlink', () {
      final r = WalletRepo.inMemory(now: now);
      addTearDown(r.close);
      final entry = r.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
      r.importBatch(_pos([('2026-01-19', -240, 'POS SYNTH CAFE'), ('2026-01-21', -240, 'POS SYNTH KIOSK')]));
      final first = _bankId('2026-01-19', -240, 'POS SYNTH CAFE'), second = _bankId('2026-01-21', -240, 'POS SYNTH KIOSK');
      r.unlinkMatch(entry);
      expect(r.transaction(entry)!.matchedTo, second);
      r.relinkMatch(entry, first);
      expect(r.transaction(entry)!.matchedTo, first);
      expect(r.transactions().where((x) => x.amount == -240).map((x) => x.id).toSet(), {first, second});
    });

    test('errors: unknown entry, not unlinked from that row, bank row gone; nothing written', () {
      final (r, entry, bank) = matched();
      expect(() => r.relinkMatch('nope', bank), throwsArgumentError);
      expect(() => r.relinkMatch(entry, bank), throwsArgumentError, reason: 'never unlinked');
      expect(() => r.relinkMatch(bank, bank), throwsArgumentError, reason: 'not a hand-added expense');
      r.unlinkMatch(entry);
      r.deleteTransaction(bank);
      final before = r.pendingOps().length;
      expect(() => r.relinkMatch(entry, bank), throwsA(isA<StateError>()));
      expect(() => r.relinkMatch(entry, 'x-other'), throwsArgumentError);
      expect(r.pendingOps().length, before);
      expect(r.transaction(entry)!.matchedTo, isNull);
    });
  });

  group('errors', () {
    test('unknown, deleted, bank row, or not matched: ArgumentError with a readable message, nothing written', () {
      final (r, entry, bank) = matched();
      final plain = r.addTransaction(date: '2026-01-10', amount: 990, category: 'Groceries');
      final gone = r.addTransaction(date: '2026-01-11', amount: 991, category: 'Groceries');
      r.deleteTransaction(gone);
      final before = r.pendingOps().length;
      Matcher arg(String text) => throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains(text)));
      expect(() => r.unlinkMatch('nope'), arg('No such transaction'));
      expect(() => r.unlinkMatch(gone), arg('No such transaction'));
      expect(() => r.unlinkMatch(bank), arg('added yourself'));
      expect(() => r.unlinkMatch(plain), arg('not matched'));
      expect(r.pendingOps().length, before);
      expect(r.transaction(entry)!.matchedTo, bank);
    });

    test('a damaged match_off value reads as no exclusion', () {
      expect(matchOffIds('not json'), isEmpty);
      expect(matchOffIds('{"a":1}'), isEmpty);
      expect(matchOffIds(null), isEmpty);
      expect(encodeMatchOff(const []), isNull);
      final many = [for (var i = 0; i < maxMatchOff + 5; i++) 'b$i'];
      expect(matchOffIds(encodeMatchOff(many)), many.skip(5).toSet(), reason: 'the newest are kept');
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    final devices = <Device>[];
    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, now);
      devices.add(d);
      return d;
    }

    Future<SyncReport> run(Device d) {
      d.deliver(net, Random(1));
      return d.run();
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-d2-unlink-');
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

    final cafe = _pos([('2026-01-20', -240, 'POS SYNTH CAFE')]);
    final bank = _bankId('2026-01-20', -240, 'POS SYNTH CAFE');

    test('B held the match: after sync it never re-pairs, also after its own overlapping import', () async {
      final a = device('a'), b = device('b');
      final entry = a.repo.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
      a.repo.importBatch(cafe);
      await run(a);
      await run(b);
      expect(b.repo.transaction(entry)!.matchedTo, bank, reason: 'precondition: B holds the match');
      a.repo.unlinkMatch(entry);
      await run(a);
      await run(b);
      expect(b.repo.transaction(entry)!.matchedTo, isNull);
      b.repo.importBatch(_pos([('2026-01-20', -240, 'POS SYNTH CAFE'), ('2026-01-22', -9900, 'POS SYNTH SHOP')]));
      await run(b);
      await run(a);
      for (final d in [a, b]) {
        expect(d.repo.transaction(entry)!.matchedTo, isNull, reason: d.name);
        expect(matchOffIds(_off(d.repo, entry)), {bank}, reason: d.name);
        expect(_spent(d.repo), 240 + 240 + 9900, reason: '${d.name}: the entry, the bank row and the shop row count');
      }
    });

    test('B imports the bank row only after the unlink: no pair on either device', () async {
      final a = device('a'), b = device('b');
      final entry = a.repo.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
      a.repo.importBatch(cafe);
      a.repo.unlinkMatch(entry);
      await run(a);
      b.repo.importBatch(cafe); // B's own import of the same row, after the unlink, before B saw anything
      await run(b);
      await run(a);
      for (final d in [a, b]) {
        expect(d.repo.transaction(entry)!.matchedTo, isNull, reason: d.name);
        expect(_spent(d.repo), 480, reason: d.name);
      }
    });

    test('the Undo on B syncs back to A', () async {
      final a = device('a'), b = device('b');
      final entry = a.repo.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
      a.repo.importBatch(cafe);
      a.repo.unlinkMatch(entry);
      await run(a);
      await run(b);
      b.repo.relinkMatch(entry, bank);
      await run(b);
      await run(a);
      for (final d in [a, b]) {
        expect(d.repo.transaction(entry)!.matchedTo, bank, reason: d.name);
        expect(_off(d.repo, entry), isNull, reason: d.name);
        expect(_spent(d.repo), 240, reason: d.name);
      }
    });
  });

  group('backup and schema 19', () {
    test('backup/restore keeps match_off: the restored wallet does not re-pair', () async {
      final (r, entry, bank) = matched();
      r.unlinkMatch(entry);
      final key = VaultKey.generate();
      final bytes = await backupBytes(r, key);
      final fresh = WalletRepo.inMemory(now: now);
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, bytes, key);
      expect(_off(fresh, entry), _off(r, entry));
      expect(fresh.transaction(entry)!.matchedTo, isNull);
      fresh.importBatch(_pos([('2026-01-22', -9900, 'POS SYNTH SHOP')]));
      expect(fresh.transaction(entry)!.matchedTo, isNull);
      expect(_spent(fresh), 240 + 240 + 9900);
    });

    for (final keyed in [false, true]) {
      test('a schema-18 ${keyed ? 'encrypted' : 'plain'} database opens, gains match_off, keeps its match and can unlink', () async {
        final dir = Directory.systemTemp.createTempSync('bw-d2-upg-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/w.db';
        final dbKey = keyed ? await localDbKey(VaultKey(List<int>.generate(32, (i) => i + 3))) : null;
        var r = WalletRepo.open(path, dbKey: dbKey, now: now);
        final entry = r.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out');
        r.importBatch(_pos([('2026-01-20', -240, 'POS SYNTH CAFE')]));
        final bank = _bankId('2026-01-20', -240, 'POS SYNTH CAFE');
        // What a schema-18 build left: no match_off column, version 18.
        r.db.execute('ALTER TABLE tx DROP COLUMN match_off');
        r.db.execute("UPDATE meta SET value = '18' WHERE key = 'schema'");
        r.close();

        r = WalletRepo.open(path, dbKey: dbKey, now: now);
        expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '19');
        expect(_off(r, entry), isNull);
        expect(r.transaction(entry)!.matchedTo, bank, reason: 'the match is kept');
        r.unlinkMatch(entry);
        r.close();
        r = WalletRepo.open(path, dbKey: dbKey, now: now);
        addTearDown(r.close);
        expect(matchOffIds(_off(r, entry)), {bank});
        expect(r.transaction(entry)!.matchedTo, isNull);
      });
    }
  });
}
