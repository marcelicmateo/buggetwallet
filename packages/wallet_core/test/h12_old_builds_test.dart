// ignore_for_file: avoid_dynamic_calls
// Stage H12 (old builds): every release's committed database and backup (test/fixtures/old_builds, written by
// generate.dart from the code of that release) must still open and restore with the current code, sync to a new
// device, and survive a second open. A schema-7 reader meets files of a newer format. Settings rows it does not know
// are kept out of the way. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/engine_spec_sim.dart';
import 'support/h_compat.dart';
import 'support/h_sim.dart';

const _t = Timeout(Duration(seconds: 60));
final _dir = Directory('test/fixtures/old_builds');

/// The throwaway key of the fixtures (bytes 1..32), as generate.dart writes them.
final _key = VaultKey(List<int>.generate(32, (i) => i + 1));

/// Release names: every `<name>.json` in the folder.
List<String> _releases() => [
      for (final f in _dir.listSync())
        if (f is File && f.path.endsWith('.json') && !f.path.contains('peer')) f.uri.pathSegments.last.replaceAll('.json', '')
    ]..sort();

Map<String, Object?> _expect(String name) => jsonDecode(File('${_dir.path}/$name.json').readAsStringSync()) as Map<String, Object?>;

Directory _scratch() {
  final d = Directory.systemTemp.createTempSync('bw-h12-old-');
  addTearDown(() => d.deleteSync(recursive: true));
  return d;
}

/// A copy of a fixture database (never open the committed file itself: opening writes to it).
String _copy(String file, Directory to) {
  final out = '${to.path}/$file';
  File('${_dir.path}/$file').copySync(out);
  return out;
}

void main() {
  test('the fixtures folder holds at least the schema 7 release', () {
    expect(_releases(), contains('schema7'));
  });

  for (final name in _releases()) {
    group('release $name', () {
      for (final keyed in [false, true]) {
        final file = '${name}_${keyed ? 'keyed' : 'plain'}.db';

        test('$file opens with the current code (${keyed ? 'encrypted' : 'converted to encrypted'}) and keeps every row', () async {
          final path = _copy(file, _scratch());
          final r = WalletRepo.open(path, dbKey: await localDbKey(_key));
          addTearDown(r.close);
          final want = _expect(name);
          expect(r.transactions(includeHidden: true).length, want['transactions']);
          expect(r.bills().length, want['bills']);
          expect(r.db.select('SELECT COUNT(*) AS n FROM goals').first['n'], want['goals']);
          final st = r.settings();
          expect(st.salary, 150000);
          expect(st.paydayDay, 15);
          expect(st.categoryBudgets, {'Groceries': 30000, 'Eating out': 12000});
          expect(st.merchantPatterns, [
            ['Shopping', 'synth shop']
          ]);
          expect(r.transactions().where((t) => t.note == 'synthetic'), hasLength(1));
          expect(r.bills().single.confirmed, isTrue);
          // N2 (schema 9): the old database is migrated to the current version and gains the accounts table.
          expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
          expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(9));
          expect(r.accounts(includeDeleted: true), isEmpty);
          await r.addAccount(name: 'Cash', currency: 'EUR', opening: 1000, openingDate: '2026-01-01');
          expect(r.accounts().single.isCash, isTrue);
          // P1 (schema 10): it gains the categories table too, empty, and takes custom categories.
          expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(10));
          expect(r.categoryRows(includeDeleted: true), isEmpty);
          final k = await r.addCategory(name: 'Pets', kind: BudgetKind.flex);
          expect(r.categoryTable().isLive(k), isTrue);
          // T1 (schema 11): it gains the tag tables, empty, and takes tags.
          expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(11));
          expect(r.tags(includeDeleted: true), isEmpty);
          expect(r.ruleTags(), isEmpty);
          final g = await r.addTag('Trip');
          expect(r.tagTable().isLive(g), isTrue);
        }, timeout: _t);

        test('$file: a second open changes nothing and queues no new ops', () async {
          final dir = _scratch();
          final path = _copy(file, dir);
          final dbKey = await localDbKey(_key);
          final first = WalletRepo.open(path, dbKey: dbKey);
          final ops = first.pendingOps().length;
          final snap = canon(first, clocks: true);
          first.close();
          final again = WalletRepo.open(path, dbKey: dbKey);
          addTearDown(again.close);
          expect(again.pendingOps().length, ops, reason: 'the migration runs once');
          expect(canon(again, clocks: true), snap);
        }, timeout: _t);

        test('$file: the old wallet syncs to a new device and both hold the same data', () async {
          final path = _copy(file, _scratch());
          final clock = SimClock();
          final c = Cluster(MemoryTransport(now: () => clock.t), clock, _key);
          addTearDown(c.closeAll);
          final old = WalletRepo.open(path, dbKey: await localDbKey(_key), now: () => clock.ms);
          final oldDev = Dev(old, SyncEngine(c.transport, _key, appVersion: '1.0.0', now: () => clock.t));
          c.devs.add(oldDev);
          final fresh = c.add();
          await c.syncAll(rounds: 3);
          expect(fresh.repo.transactions(includeHidden: true).length, _expect(name)['transactions']);
          expect(fresh.repo.settings().salary, 150000);
          expect(fresh.repo.settings().categoryBudgets, {'Groceries': 30000, 'Eating out': 12000});
          expect(data(oldDev), data(fresh));
        }, timeout: _t);
      }

      test('$name.bwb restores into an empty wallet and equals the database fixture (rows, clocks)', () async {
        final bytes = File('${_dir.path}/$name.bwb').readAsBytesSync();
        final r = WalletRepo.inMemory();
        addTearDown(r.close);
        final n = await restoreBackupBytes(r, bytes, _key);
        expect(n, _expect(name)['ops']);
        final db = WalletRepo.open(_copy('${name}_plain.db', _scratch()));
        addTearDown(db.close);
        bool notSetting(String line) => !line.startsWith('setting|');
        expect(canon(r, clocks: true).where(notSetting).toList(), canon(db, clocks: true).where(notSetting).toList());
        expect(r.settings().salary, 150000);
        expect(r.settings().categoryBudgets, {'Groceries': 30000, 'Eating out': 12000});
      }, timeout: _t);

      test('$name.bwb: the wrong key, a damaged file and a non-empty wallet are refused; the wallet is untouched', () async {
        final bytes = File('${_dir.path}/$name.bwb').readAsBytesSync();
        final r = WalletRepo.inMemory();
        addTearDown(r.close);
        await expectLater(restoreBackupBytes(r, bytes, VaultKey(List<int>.filled(32, 4))), throwsA(isA<VaultException>()));
        final bad = Uint8List.fromList(bytes)..[bytes.length ~/ 2] ^= 0x10;
        await expectLater(restoreBackupBytes(r, bad, _key), throwsA(isA<VaultException>()));
        await expectLater(restoreBackupBytes(r, bytes.sublist(0, bytes.length - 3), _key), throwsA(isA<VaultException>()));
        expect(r.isEmpty, isTrue);
        r.addTransaction(date: '2026-01-14', amount: -100, category: 'Groceries');
        await expectLater(restoreBackupBytes(r, bytes, _key), throwsStateError);
      }, timeout: _t);

      test('$name.bwb restored on a device that is also on the relay converges with the others', () async {
        final clock = SimClock();
        final c = Cluster(MemoryTransport(now: () => clock.t), clock, _key);
        addTearDown(c.closeAll);
        final [a, b] = [c.add(), c.add()];
        await restoreBackupBytes(a.repo, File('${_dir.path}/$name.bwb').readAsBytesSync(), _key);
        await c.syncAll(rounds: 3);
        expect(b.repo.transactions(includeHidden: true).length, _expect(name)['transactions']);
        expect(data(a), data(b));
      }, timeout: _t);
    });
  }

  group('a reader of schema 7 meets what a newer build writes', () {
    test('settings rows with ids it does not know (budget:<category>, pattern:<key>) are stored but never break reads', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.updateSettings({'salary': 120000});
      final before = r.settings().salary;
      r.applyRemote([
        const Op('setting', 'budget:Groceries', {'value': '30000'}, '001768035600000:00001:peer0001'),
        const Op('setting', 'pattern:synth', {'value': '["Shopping","synth"]'}, '001768035600000:00002:peer0001'),
      ]);
      final st = r.settings(); // must not throw
      expect(st.salary, before);
      expect(r.snapshotOps().where((o) => o.id == 'budget:Groceries'), hasLength(1), reason: 'kept, so a later upgrade sees it');
    }, timeout: _t);

    test('a file with a newer magic (BWOP9) is an unknownVersion problem, not corruption; the other files still apply', () async {
      final clock = SimClock();
      final mem = MemoryTransport(now: () => clock.t);
      final c = Cluster(mem, clock);
      addTearDown(c.closeAll);
      final [a, b, d] = [c.add(), c.add(), c.add()];
      a.repo.addTransaction(date: '2026-01-14', amount: -100, category: 'Groceries', note: 'from a');
      await a.sync();
      d.repo.addTransaction(date: '2026-01-14', amount: -200, category: 'Groceries', note: 'from d');
      await d.sync();
      final good = Uint8List.fromList(mem.files['d/${a.id}/1']!);
      good[4] = '9'.codeUnitAt(0);
      mem.replace(a.id, 1, good);
      final r = await b.sync();
      expect(r.problems.map((p) => p.reason), [SyncProblemReason.unknownVersion]);
      expect(r.caughtUp, isFalse);
      expect(b.repo.transactions().map((t) => t.note), ['from d'], reason: "another device's file is not held back");
      final again = await b.sync();
      expect(again.problems.single.isNew, isFalse, reason: 'refused once, not re-read on every run');
      // The app is updated (a different build string): the file is read again, once.
      final upgraded = SyncEngine(mem, c.key, appVersion: '2.0.0', now: () => clock.t);
      final after = await upgraded.run(b.repo);
      expect(after.problems.map((p) => p.reason), [SyncProblemReason.unknownVersion], reason: 'this build still cannot read BWOP9');
    }, timeout: _t);

    test(
        'files written after an upgrade need the upgraded reader only for the new bits: unknown fields in ops are ignored, known ones apply',
        () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final changed = r.applyRemote([
        const Op(
            'tx',
            'peer-row-1',
            {'amount': -1234, 'date': '2026-01-14', 'description': 'synthetic', 'source': 'pbz', 'future_field': 'x'},
            '001768035600000:00001:peer0001'),
      ]);
      expect(changed, greaterThan(0));
      expect(r.transaction('peer-row-1')!.amount, -1234);
    }, timeout: _t);
  });

  group('the migration to per-key settings (H3, schema 8)', () {
    test('opening a schema 7 database writes one row per category budget and per pattern, once, through the change log', () async {
      final path = _copy('schema7_plain.db', _scratch());
      final r = WalletRepo.open(path, dbKey: await localDbKey(_key));
      addTearDown(r.close);
      final rows = [for (final x in r.db.select("SELECT id FROM settings WHERE id LIKE 'budget:%'")) x['id']];
      expect(rows, unorderedEquals(['budget:Groceries', 'budget:Eating out']));
      expect(r.settings().categoryBudgets, {'Groceries': 30000, 'Eating out': 12000});
      expect(r.pendingOps().any((p) => p.$2.id == 'budget:Groceries'), isTrue, reason: 'so it syncs');
      final ops = r.pendingOps().length;
      r.close();
      final again = WalletRepo.open(path, dbKey: await localDbKey(_key));
      addTearDown(again.close);
      expect(again.pendingOps().length, ops, reason: 'migrated once');
    }, skip: bugUnless(WalletRepo.schemaVersion >= 8, 'H3', 'schema 8 per-key settings migration'), timeout: _t);

    test(
        'peer rows already in the database (budget:/pattern: with an OLDER clock than the legacy maps) are never overwritten by the migration',
        () async {
      // schema7peer_plain.db: a build that had synced with a newer one holds budget:Groceries = 450.00 and the
      // pattern row for "synth shop" in category Groceries, both older than the legacy maps (300.00, Shopping).
      final path = _copy('schema7peer_plain.db', _scratch());
      final r = WalletRepo.open(path, dbKey: await localDbKey(_key));
      addTearDown(r.close);
      Map<String, Object?> row(String id) => Map<String, Object?>.from(r.db.select('SELECT * FROM settings WHERE id = ?', [id]).single);
      expect(jsonDecode(row('budget:Groceries')['value']! as String), 45000, reason: 'the peer row stays, whatever the clocks say');
      expect(jsonDecode(row('budget:Eating out')['value']! as String), 12000, reason: 'an id without a row is created from the map');
      expect(r.settings().categoryBudgets, {'Groceries': 45000, 'Eating out': 12000});
      final patterns = [for (final x in r.db.select("SELECT id, value FROM settings WHERE id LIKE 'pattern:%'")) x];
      expect(patterns, hasLength(1), reason: 'the same pattern is one row, the id never shows the pattern');
      expect((jsonDecode(patterns.single['value']! as String) as Map)['category'], 'Groceries');
      expect(r.settings().merchantPatterns, [
        ['Groceries', 'synth shop']
      ]);
      // The migration ran once: a second open queues nothing more.
      final ops = r.pendingOps().length;
      r.close();
      final again = WalletRepo.open(path, dbKey: await localDbKey(_key));
      addTearDown(again.close);
      expect(again.pendingOps().length, ops);
      expect(again.settings().categoryBudgets, {'Groceries': 45000, 'Eating out': 12000});
    },
        skip: bugUnless(WalletRepo.schemaVersion >= 8, 'H3', 'schema 8: the migration never overwrites an id that already has a row'),
        timeout: _t);

    test('a schema 7 device and a schema 8 device sync: both end with the same category budgets', () async {
      final clock = SimClock();
      final c = Cluster(MemoryTransport(now: () => clock.t), clock, _key);
      addTearDown(c.closeAll);
      final dir = _scratch();
      final old = WalletRepo.open(_copy('schema7_plain.db', dir), dbKey: await localDbKey(_key), now: () => clock.ms);
      final oldDev = Dev(old, SyncEngine(c.transport, _key, appVersion: '1.0.0', now: () => clock.t));
      c.devs.add(oldDev);
      final fresh = c.add();
      await c.syncAll(rounds: 3);
      expect(fresh.repo.settings().categoryBudgets, {'Groceries': 30000, 'Eating out': 12000});
      expect(oldDev.repo.settings().categoryBudgets, fresh.repo.settings().categoryBudgets);
    }, skip: bugUnless(WalletRepo.schemaVersion >= 8, 'H3', 'schema 8'), timeout: _t);
  });
}
