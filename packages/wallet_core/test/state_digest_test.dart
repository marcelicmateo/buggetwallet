// V2 (Stage V): the synced-state digest, the repair resend queue and the equal-clock tie-break; V1 key id through
// backups. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

String _hlc(int ms, [String node = 'n1']) => Hlc(1767225600000 + ms, 0, node).toString();

Op _setting(String id, Object? value, int ms, [String node = 'n1']) => Op('setting', id, {'value': value, 'deleted': 0}, _hlc(ms, node));

void main() {
  final repos = <WalletRepo>[];
  WalletRepo repo() => WalletRepo.inMemory(now: () => 1767225600000 + 100000)..also(repos.add);
  tearDown(() {
    for (final r in repos) {
      r.close();
    }
    repos.clear();
  });

  final ops = [
    _setting('salary', '150000', 1),
    _setting('rent', '50000', 2),
    Op('tx', 'tx-a', {'date': '2026-01-03', 'amount': -1200, 'description': 'SYNTHETIC SHOP', 'deleted': 0}, _hlc(3)),
    Op('tx', 'tx-b', {'date': '2026-01-04', 'amount': -800, 'description': 'SYNTHETIC CAFE', 'deleted': 1}, _hlc(4)),
    Op('tx', 'tx-a', {'category': 'Groceries'}, _hlc(5, 'n2')),
  ];

  group('stateDigest', () {
    test('lowercase hex SHA-256; the same ops in any order and split give the same digest', () {
      final a = repo()..applyRemote(ops, match: false);
      final b = repo()..applyRemote(ops.reversed.toList(), match: false);
      final c = repo();
      for (final op in ops) {
        c.applyRemote([op], match: false);
      }
      expect(a.stateDigest(), matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(b.stateDigest(), a.stateDigest());
      expect(c.stateDigest(), a.stateDigest());
      expect(a.stateDigest(), a.stateDigest(), reason: 'pure: reading changes nothing');
    });

    test('an empty wallet has a fixed digest; any synced row changes it, deleted rows included', () {
      final empty = repo().stateDigest();
      expect(repo().stateDigest(), empty);
      final r = repo()..applyRemote([ops[3]], match: false); // only a deleted row
      expect(r.stateDigest(), isNot(empty));
    });

    test('a different value, or the same value under another clock, changes it', () {
      final a = repo()..applyRemote(ops, match: false);
      final value = repo()..applyRemote([...ops, _setting('salary', '150001', 9)], match: false);
      final clock = repo()
        ..applyRemote([...ops.take(1).map((o) => Op(o.entity, o.id, o.fields, _hlc(1, 'n9'))), ...ops.skip(1)], match: false);
      expect(value.stateDigest(), isNot(a.stateDigest()));
      expect(clock.stateDigest(), isNot(a.stateDigest()));
    });

    test('device-local data is left out: local values, the outbox, sync cursors, recorded files', () {
      final a = repo()..applyRemote(ops, match: false);
      final before = a.stateDigest();
      a.setLocalValue('syncSomething', 'x');
      a.setSyncCursor('peer', 4);
      a.recordSyncFile('peer', 4, 10);
      a.queueStateResend();
      expect(a.pendingOps(), isNotEmpty);
      expect(a.stateDigest(), before);
    });

    test('a field changed behind the change log changes it once data changes again (cached per dataVersion)', () {
      final a = repo()..applyRemote(ops, match: false);
      final before = a.stateDigest();
      final runs = a.stateDigestComputations;
      expect(a.stateDigest(), before);
      expect(a.stateDigestComputations, runs, reason: 'the same dataVersion: served from the cache');
      a.db.execute("UPDATE settings SET value = '1' WHERE id = 'salary'");
      expect(a.stateDigest(), before, reason: 'raw SQL does not move dataVersion: still the cached text');
      a.applyRemote([_setting('loan', '1', 30)], match: false);
      final after = a.stateDigest();
      expect(a.stateDigestComputations, runs + 1);
      final fresh = repo()..applyRemote([...ops, _setting('loan', '1', 30)], match: false);
      expect(after, isNot(fresh.stateDigest()), reason: 'the changed salary is in it');
      a.applyRemote([_setting('loan', '1', 30)], match: false); // changes nothing: no new data version
      a.stateDigest();
      expect(a.stateDigestComputations, runs + 1);
    });

    test('20k-row wallet: digest time and a whole-state tie-break apply (numbers in the output, no limit)', () {
      final big = repo();
      final start = DateTime.utc(2021, 1, 1);
      big.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (var i = 0; i < 20000; i++)
          n(start.add(Duration(days: i ~/ 11)).toIso8601String().substring(0, 10), -(100 + i % 9000), 'POS', 'SHOP ${i % 400} ZAGREB',
              occ: i),
      ]));
      var sw = Stopwatch()..start();
      final d = big.stateDigest();
      final digestMs = sw.elapsedMilliseconds;
      sw = Stopwatch()..start();
      expect(big.stateDigest(), d);
      final cachedMs = sw.elapsedMilliseconds;
      big.applyRemote([_setting('loan', '1', 30)], match: false);
      sw = Stopwatch()..start();
      big.stateDigest();
      final warmMs = sw.elapsedMilliseconds;
      final copy = repo()..applyRemote(big.snapshotOps(), match: false);
      final snap = big.snapshotOps();
      sw = Stopwatch()..start();
      expect(copy.applyRemote(snap, match: false, repair: true), 0);
      final tieMs = sw.elapsedMilliseconds;
      expect(copy.stateDigest(), big.stateDigest());
      // ignore: avoid_print
      print('V2 perf: rows ${big.transactions().length}, stateDigest ${digestMs}ms (warm ${warmMs}ms), cached ${cachedMs}ms, '
          'repair resend of ${snap.length} ops ${tieMs}ms');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('queueStateResend', () {
    test('queues exactly snapshotOps (original clocks) and returns the count; data unchanged', () {
      final a = repo()..applyRemote(ops, match: false);
      final digest = a.stateDigest();
      final n = a.queueStateResend();
      expect(n, a.snapshotOps().length);
      expect([for (final (_, op) in a.pendingOps()) jsonEncode(op.toJson())], [for (final op in a.snapshotOps()) jsonEncode(op.toJson())]);
      expect(a.stateDigest(), digest);
    });

    test('an empty wallet queues nothing', () {
      final a = repo();
      expect(a.queueStateResend(), 0);
      expect(a.pendingOps(), isEmpty);
    });
  });

  group('conflicts on equal clocks (repair resend, VC)', () {
    test('both keep their own value; the conflict is listed with mine/theirs swapped; normal apply records nothing', () {
      final low = _setting('salary', '100', 1), high = _setting('salary', '200', 1);
      final a = repo()..applyRemote([low], match: false);
      final b = repo()..applyRemote([high], match: false);
      expect(a.applyRemote([high], match: false), 0, reason: 'normal apply keeps the stored value on an equal clock');
      expect(a.syncConflicts(), isEmpty, reason: 'only a repair resend records conflicts');
      expect(a.applyRemote([high], match: false, repair: true), 0);
      expect(b.applyRemote([low], match: false, repair: true), 0);
      expect((a.settings().salary, b.settings().salary), (100, 200), reason: 'nothing changes without the owner');
      final ca = a.syncConflicts().single, cb = b.syncConflicts().single;
      expect((ca.id, ca.entity, ca.rowId, ca.field, ca.mine, ca.theirs, ca.clock),
          ('setting|salary|value', 'setting', 'salary', 'value', '100', '200', low.hlc));
      expect((cb.mine, cb.theirs), ('200', '100'));
    });

    test('the same field again is one entry with the latest theirs; the same value or another clock records nothing', () {
      final a = repo()..applyRemote([_setting('salary', '100', 5)], match: false);
      a.applyRemote([_setting('salary', '200', 5)], match: false, repair: true);
      a.applyRemote([_setting('salary', '300', 5)], match: false, repair: true);
      expect(a.syncConflicts().single.theirs, '300');
      final b = repo()..applyRemote([_setting('salary', '100', 5)], match: false);
      expect(b.applyRemote([_setting('salary', '100', 5)], match: false, repair: true), 0);
      expect(b.applyRemote([_setting('salary', '900', 4)], match: false, repair: true), 0, reason: 'older clock');
      expect(b.syncConflicts(), isEmpty);
      expect(b.applyRemote([_setting('salary', '50', 6)], match: false, repair: true), 1, reason: 'newer clock wins as always');
      expect(b.settings().salary, 50);
    });

    test('an edit of the field (any clock change) settles the entry; resolve writes the choice with a new clock', () {
      final a = repo()..applyRemote([_setting('salary', '100', 1)], match: false);
      a.applyRemote([_setting('salary', '200', 1)], match: false, repair: true);
      expect(a.syncConflicts(), hasLength(1));
      a.updateSettings({'salary': 150});
      expect(a.syncConflicts(), isEmpty, reason: 'the edit settles it');

      final b = repo()..applyRemote([_setting('salary', '100', 1), _setting('rent', '7', 1)], match: false);
      b.applyRemote([_setting('salary', '200', 1), _setting('rent', '8', 1)], match: false, repair: true);
      final [rent, salary] = b.syncConflicts();
      expect((rent.rowId, salary.rowId), ('rent', 'salary'), reason: 'ordered by entity, row, field');
      final out = b.pendingOps().length;
      b.resolveSyncConflict(salary.id, keepMine: false);
      expect(b.settings().salary, 200);
      b.resolveSyncConflict(rent.id, keepMine: true);
      expect(b.settings().rent, 7);
      expect(b.syncConflicts(), isEmpty);
      expect(b.pendingOps().length, out + 2, reason: 'both choices are owner writes that sync, keepMine too');
      expect(() => b.resolveSyncConflict(rent.id, keepMine: true), throwsArgumentError);
      expect(() => b.resolveSyncConflict('nope', keepMine: true), throwsArgumentError);
    });

    test('a missing row whose clocks remain (damage) takes the resend value; a dry run records nothing', () {
      final a = repo()..applyRemote([ops[2]], match: false);
      a.db.execute("DELETE FROM tx WHERE id = 'tx-a'");
      expect(a.applyRemote([ops[2]], match: false, repair: true), 1);
      expect(a.transaction('tx-a'), isNotNull);
      final b = repo()..applyRemote([_setting('salary', '100', 1)], match: false);
      b.applyRemoteByEntity([_setting('salary', '200', 1)], dryRun: true, repair: true);
      expect(b.syncConflicts(), isEmpty);
    });

    test('a lost row whose newer local delete cannot be read back stays hidden and becomes a conflict', () {
      final a = repo()..applyRemote([ops[2]], match: false);
      a.applyRemote([
        Op('tx', 'tx-a', {'deleted': 1}, _hlc(50))
      ], match: false); // the owner's delete, later clock
      a.db.execute("DELETE FROM tx WHERE id = 'tx-a'"); // the row is lost, its clocks stay
      // The peer's resend: the row as it knew it (older delete state).
      expect(a.applyRemote([ops[2]], match: false, repair: true), 1);
      expect(a.db.select("SELECT deleted FROM tx WHERE id = 'tx-a'").single['deleted'], 1, reason: 'never revived as spending');
      expect(a.transactions().where((t) => t.id == 'tx-a' && !t.deleted), isEmpty);
      final c = a.syncConflicts().single;
      expect((c.field, c.mine, c.theirs, c.clock), ('deleted', 1, 0, _hlc(50)));
    });

    test('a lost row with fields under several clocks is restored whole, also across two resend files', () {
      final peer = repo()
        ..applyRemote([
          ops[2],
          Op('tx', 'tx-a', {'note': 'later'}, _hlc(60))
        ], match: false);
      final a = repo()..applyRemote(peer.snapshotOps(), match: false);
      a.db.execute("DELETE FROM tx WHERE id = 'tx-a'");
      final resend = peer.snapshotOps().where((o) => o.id == 'tx-a').toList();
      expect(resend, hasLength(2));
      a.applyRemote([resend[0]], match: false, repair: true);
      a.applyRemote([resend[1]], match: false, repair: true); // the next part of the same resend
      expect(a.syncConflicts(), isEmpty);
      expect(a.stateDigest(), peer.stateDigest());
    });

    test('settled entries go before the cap counts; a cap drop leaves the dropped mark', () {
      final a = repo()..applyRemote([for (var i = 0; i < 500; i++) _setting('k$i', '1', 1)], match: false);
      a.applyRemote([for (var i = 0; i < 500; i++) _setting('k$i', '2', 1)], match: false, repair: true);
      expect(a.localValue(WalletRepoSyncApply.syncConflictsDroppedKey), isNull);
      for (var i = 0; i < 10; i++) {
        a.updateSettings({'k$i': 3}); // settles k0..k9 (their clocks change)
      }
      a.applyRemote([for (var i = 0; i < 10; i++) _setting('n$i', '1', 1)], match: false);
      a.applyRemote([for (var i = 0; i < 10; i++) _setting('n$i', '2', 1)], match: false, repair: true);
      final open = a.syncConflicts().map((c) => c.rowId).toSet();
      expect(open, hasLength(500));
      expect(open, contains('k10'), reason: 'nothing open was dropped: the settled ones made room');
      expect(a.localValue(WalletRepoSyncApply.syncConflictsDroppedKey), isNull);
      a.applyRemote([_setting('extra', '1', 1)], match: false);
      a.applyRemote([_setting('extra', '2', 1)], match: false, repair: true);
      expect(a.localValue(WalletRepoSyncApply.syncConflictsDroppedKey), '1');
      expect(a.dropSyncConflicts(), 500);
      expect(a.syncConflicts(), isEmpty);
    });

    test('at most 500 open, the oldest dropped first', () {
      final a = repo()..applyRemote([for (var i = 0; i < 505; i++) _setting('k$i', '1', 1)], match: false);
      a.applyRemote([for (var i = 0; i < 505; i++) _setting('k$i', '2', 1)], match: false, repair: true);
      final open = a.syncConflicts();
      expect(open, hasLength(WalletRepoSyncApply.maxSyncConflicts));
      expect(open.map((c) => c.rowId), isNot(contains('k0')));
      expect(open.map((c) => c.rowId), contains('k504'));
    });

    test('record kinds (_digest, _repair) and other unknown kinds are never stored', () {
      final a = repo()..applyRemote(ops, match: false);
      final before = a.stateDigest();
      final n = a.applyRemote([
        Op(
            '_digest',
            'dev',
            {
              'digest': 'ab',
              'vector': {'dev': 1},
              'schema': WalletRepo.schemaVersion
            },
            _hlc(20)),
        Op('_repair', 'dev', {'ask': true}, _hlc(21)),
      ], match: false, repair: true);
      expect(n, 0);
      expect(a.stateDigest(), before);
    });
  });

  group('backups carry the key id (V1)', () {
    test('another key is otherKey, a changed byte is damaged, a BWOP2 backup of an older build still restores', () async {
      final key = VaultKey.generate();
      final src = repo()..importBatch(january);
      final bytes = await backupBytes(src, key);
      expect(utf8.decode(bytes.sublist(0, 5)), 'BWOP3');
      await expectLater(restoreBackupBytes(repo(), bytes, VaultKey.generate()),
          throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.otherKey)));
      await expectLater(mergeBackupBytes(repo(), bytes, VaultKey.generate()),
          throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.otherKey)));
      await expectLater(restoreBackupBytes(repo(), Uint8List.fromList(bytes)..[60] ^= 1, key),
          throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.damaged)));
      final old = await seal(backupPayload(src.snapshotOps()), key, aad: aadBackup, legacyFormat: true);
      expect(utf8.decode(old.sublist(0, 5)), 'BWOP2');
      final r = repo();
      expect(await restoreBackupBytes(r, old, key), src.snapshotOps().length);
      await expectLater(restoreBackupBytes(repo(), old, VaultKey.generate()),
          throwsA(isA<VaultException>().having((e) => e.failure, 'failure', UnsealFailure.badKey)));
    });
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
