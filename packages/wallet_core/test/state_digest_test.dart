// V2 (Stage V): the synced-state digest, the repair resend queue and the equal-clock tie-break; V1 key id through
// backups. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

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

    test('a field changed behind the change log (no clock change) changes it: what the digest exists to catch', () {
      final a = repo()..applyRemote(ops, match: false);
      final before = a.stateDigest();
      a.db.execute("UPDATE settings SET value = '1' WHERE id = 'salary'");
      expect(a.stateDigest(), isNot(before));
    });
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

  group('tie-break on equal clocks (repair resend)', () {
    test('without it the stored value stays; with it the value whose JSON sorts higher wins, on both sides alike', () {
      final low = _setting('salary', '100', 1), high = _setting('salary', '200', 1);
      final a = repo()..applyRemote([low], match: false);
      final b = repo()..applyRemote([high], match: false);
      expect(a.applyRemote([high], match: false), 0, reason: 'normal apply keeps the stored value on an equal clock');
      expect(a.settings().salary, 100);
      expect(a.applyRemote([high], match: false, tieBreak: true), 1);
      expect(b.applyRemote([low], match: false, tieBreak: true), 0, reason: 'the lower value never wins');
      expect((a.settings().salary, b.settings().salary), (200, 200));
      expect(a.stateDigest(), b.stateDigest());
    });

    test('the same value on an equal clock changes nothing, and a newer or older clock follows the normal rule', () {
      final a = repo()..applyRemote([_setting('salary', '100', 5)], match: false);
      expect(a.applyRemote([_setting('salary', '100', 5)], match: false, tieBreak: true), 0);
      expect(a.applyRemote([_setting('salary', '900', 4)], match: false, tieBreak: true), 0, reason: 'older clock');
      expect(a.applyRemote([_setting('salary', '50', 6)], match: false, tieBreak: true), 1, reason: 'newer clock wins whatever the value');
      expect(a.settings().salary, 50);
    });

    test('types compare by canonical JSON: an integer column and null', () {
      final a = repo()..applyRemote([ops[2]], match: false);
      final b = repo()
        ..applyRemote([
          Op('tx', 'tx-a', {...ops[2].fields, 'amount': -1300}, ops[2].hlc)
        ], match: false);
      // "-1300" > "-1200" as JSON text: b's value wins on both.
      a.applyRemote([
        Op('tx', 'tx-a', {'amount': -1300}, ops[2].hlc)
      ], match: false, tieBreak: true);
      b.applyRemote([
        Op('tx', 'tx-a', {'amount': -1200}, ops[2].hlc)
      ], match: false, tieBreak: true);
      expect(a.transaction('tx-a')!.amount, b.transaction('tx-a')!.amount);
      expect(a.stateDigest(), b.stateDigest());
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
      ], match: false, tieBreak: true);
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
