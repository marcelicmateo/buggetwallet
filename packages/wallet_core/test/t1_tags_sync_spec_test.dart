// Stage T1 (docs/context/T1_SPEC.md §1, §7): tags across devices, backup round trip and schema 10 -> 11.
// Written from the spec. All data SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/n2.dart';
import 'support/sim.dart' hide dump;
import 'support/t1.dart';

const _t = Timeout(Duration(seconds: 60));
const _tables = ['tags', 'tx_tags', 'rule_tags'];

void main() {
  late Directory tmp;
  late VaultKey key;
  late Net net;
  var now = n2Now;
  final devices = <Device>[];

  Device device(String name) {
    final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
    devices.add(d);
    return d;
  }

  Future<void> syncAll(List<Device> ds) async {
    for (var round = 0; round < 3; round++) {
      for (final d in ds) {
        d.deliver(net, Random(round));
        await d.run();
        d.upload(net);
      }
    }
  }

  void sameTables(WalletRepo x, WalletRepo y, {String? why}) {
    for (final t in _tables) {
      expect(dump(x, t), dump(y, t), reason: '$t ${why ?? ''}');
    }
  }

  String expense(Device d, String note, [String date = '2026-10-05']) =>
      d.repo.addTransaction(date: date, amount: 1000, category: 'Groceries', note: note);

  String payee(Device d, String txId) => merchantKey(d.repo.transactions().firstWhere((t) => t.id == txId));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bw-t1-');
    key = VaultKey.generate();
    net = Net();
    now = n2Now;
  });
  tearDown(() {
    for (final d in devices) {
      d.repo.close();
    }
    devices.clear();
    tmp.deleteSync(recursive: true);
  });

  group('tags across devices', () {
    test('a tag, a link and a rule tag reach the other device with identical rows', () async {
      final a = device('a'), b = device('b');
      final tag = await a.repo.addTag('Trip');
      final tx = expense(a, 'Hotel');
      await a.repo.setTxTag(tx, tag, true);
      await a.repo.setRuleTag(payee(a, tx), tag, true);
      await syncAll([a, b]);
      expect(b.repo.tagTable().label(tag), 'Trip');
      expect(effective(b.repo, tx), [tag]);
      expect(b.repo.ruleTags()[payee(a, tx)], {tag});
      sameTables(a.repo, b.repo);
    }, timeout: _t);

    test('the same name added offline on two devices is one tag in reads: smallest id wins', () async {
      final a = device('a'), b = device('b');
      final ia = await a.repo.addTag('Trip');
      final ib = await b.repo.addTag('trip');
      final small = ia.compareTo(ib) < 0 ? ia : ib;
      final big = small == ia ? ib : ia;
      await syncAll([a, b]);
      sameTables(a.repo, b.repo);
      for (final d in [a, b]) {
        final t = d.repo.tagTable();
        expect(t.duplicateOf(big), small, reason: d.name);
        expect(t.duplicateOf(small), isNull, reason: d.name);
        expect(t.resolve(big), small, reason: d.name);
        expect(t.resolve(small), small, reason: d.name);
        expect(t.pickable().where((x) => x == small || x == big), [small], reason: d.name);
      }
    }, timeout: _t);

    test('rows tagged with the duplicate and the original count once, under the original', () async {
      final a = device('a'), b = device('b');
      final ia = await a.repo.addTag('Trip');
      final ib = await b.repo.addTag('Trip');
      final small = ia.compareTo(ib) < 0 ? ia : ib;
      final big = small == ia ? ib : ia;
      final tx1 = expense(a, 'Hotel');
      final tx2 = expense(a, 'Taxi', '2026-10-06');
      final tx3 = expense(a, 'Museum', '2026-10-07');
      await syncAll([a, b]);
      await (small == ia ? a : b).repo.setTxTag(tx1, small, true);
      await (big == ia ? a : b).repo.setTxTag(tx2, big, true);
      await a.repo.setTxTag(tx3, small, true);
      await b.repo.setTxTag(tx3, big, true);
      await syncAll([a, b]);
      final range = DateRange(start: '2026-10-01', end: '2026-10-31');
      for (final d in [a, b]) {
        expect(effective(d.repo, tx1), [small], reason: d.name);
        expect(effective(d.repo, tx2), [small], reason: d.name);
        expect(effective(d.repo, tx3), [small], reason: 'both links, one tag');
        final cz = d.repo.categorizer();
        final rows = [
          for (final t in d.repo.transactions())
            CategorizedTx(t, cz.categorize(t).category, cz.categorize(t).kind, tags: effective(d.repo, t.id))
        ];
        final share = tagShare(rows, range, currency: 'EUR');
        expect(share.slices, hasLength(1), reason: d.name);
        expect((share.slices.single.tag, share.slices.single.spent, share.slices.single.count), (small, 3000, 3));
        expect(share.untaggedSpent, 0);
      }
    }, timeout: _t);

    test('the same link edited offline on both devices: the later write wins', () async {
      final a = device('a'), b = device('b');
      final tag = await a.repo.addTag('Trip');
      final tx = expense(a, 'Hotel');
      await syncAll([a, b]);
      await a.repo.setTxTag(tx, tag, true);
      await syncAll([a, b]);
      now += 1000;
      await a.repo.setTxTag(tx, tag, false); // earlier
      now += 1000;
      await b.repo.setTxTag(tx, tag, false);
      now += 1000;
      await b.repo.setTxTag(tx, tag, true); // later
      await syncAll([a, b]);
      expect(effective(a.repo, tx), [tag]);
      expect(effective(b.repo, tx), [tag]);
      now += 1000;
      await a.repo.setTxTag(tx, tag, false); // latest
      await syncAll([a, b]);
      expect(effective(a.repo, tx), isEmpty);
      expect(effective(b.repo, tx), isEmpty);
      sameTables(a.repo, b.repo);
      expect(a.repo.db.select('SELECT id FROM tx_tags'), hasLength(1), reason: 'one row per link, id <tx>|<tag>');
    }, timeout: _t);

    test('rule on A and an off link on B for one row: that row stays off, the others get the tag', () async {
      final a = device('a'), b = device('b');
      final tag = await a.repo.addTag('Weekly shop');
      final r1 = expense(a, 'Lidl');
      final r2 = expense(a, 'Lidl', '2026-10-06');
      await syncAll([a, b]);
      now += 1000;
      await b.repo.setTxTag(r1, tag, true);
      await b.repo.setTxTag(r1, tag, false);
      now += 1000;
      await a.repo.setRuleTag(payee(a, r1), tag, true);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        expect(effective(d.repo, r1), isEmpty, reason: d.name);
        expect(effective(d.repo, r2), [tag], reason: d.name);
      }
      sameTables(a.repo, b.repo);
    }, timeout: _t);

    test('rule removed on A while B sets an on link: the on link keeps the tag; the other rows lose it', () async {
      final a = device('a'), b = device('b');
      final tag = await a.repo.addTag('Weekly shop');
      final r1 = expense(a, 'Lidl');
      final r2 = expense(a, 'Lidl', '2026-10-06');
      await a.repo.setRuleTag(payee(a, r1), tag, true);
      await syncAll([a, b]);
      now += 1000;
      await a.repo.setRuleTag(payee(a, r1), tag, false);
      now += 1000;
      await b.repo.setTxTag(r1, tag, false);
      now += 1000;
      await b.repo.setTxTag(r1, tag, true);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        expect(effective(d.repo, r1), [tag], reason: d.name);
        expect(effective(d.repo, r2), isEmpty, reason: d.name);
      }
      sameTables(a.repo, b.repo);
    }, timeout: _t);

    test('off link, then rule, then on link, in three orders of arrival: always converge to the same tags', () async {
      for (final order in [
        [0, 1, 2],
        [2, 1, 0],
        [1, 2, 0],
      ]) {
        final x = device('x${order.join()}'), y = device('y${order.join()}'), z = device('z${order.join()}');
        final tag = await x.repo.addTag('Trip${order.join()}');
        final tx = expense(x, 'Hotel${order.join()}');
        await syncAll([x, y, z]);
        final writes = <int, Future<void> Function()>{
          0: () => y.repo.setTxTag(tx, tag, false),
          1: () => z.repo.setRuleTag(payee(x, tx), tag, true),
          2: () => y.repo.setTxTag(tx, tag, true),
        };
        for (final i in order) {
          now += 1000;
          await writes[i]!();
        }
        await syncAll([x, y, z]);
        final results = [
          for (final d in [x, y, z]) effective(d.repo, tx)
        ];
        expect(results[1], results[0], reason: 'order $order');
        expect(results[2], results[0], reason: 'order $order');
        sameTables(x.repo, y.repo, why: '$order');
        sameTables(x.repo, z.repo, why: '$order');
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('delete on A and undelete on B: the later write wins; links and rules survive', () async {
      final a = device('a'), b = device('b');
      final tag = await a.repo.addTag('Trip');
      final tx = expense(a, 'Hotel');
      await a.repo.setTxTag(tx, tag, true);
      await syncAll([a, b]);
      now += 1000;
      await a.repo.deleteTag(tag);
      await syncAll([a, b]);
      expect(effective(b.repo, tx), isEmpty);
      expect(b.repo.tagTable().isLive(tag), isFalse);
      now += 1000;
      await b.repo.undeleteTag(tag);
      await syncAll([a, b]);
      expect(effective(a.repo, tx), [tag]);
      sameTables(a.repo, b.repo);
    }, timeout: _t);

    test('a link edited on B while A deletes the tag: the tag stays deleted, the link row is kept for undelete', () async {
      final a = device('a'), b = device('b');
      final tag = await a.repo.addTag('Trip');
      final tx = expense(a, 'Hotel');
      await syncAll([a, b]);
      now += 1000;
      await a.repo.deleteTag(tag);
      now += 1000;
      await b.repo.setTxTag(tx, tag, true);
      await syncAll([a, b]);
      expect(effective(a.repo, tx), isEmpty);
      expect(effective(b.repo, tx), isEmpty);
      now += 1000;
      await a.repo.undeleteTag(tag);
      await syncAll([a, b]);
      expect(effective(b.repo, tx), [tag]);
    }, timeout: _t);

    test('a late third device gets every tag, link, rule and deletion', () async {
      final a = device('a'), b = device('b');
      final trip = await a.repo.addTag('Trip');
      final gift = await a.repo.addTag('Gift');
      final old = await a.repo.addTag('Old');
      final tx1 = expense(a, 'Hotel');
      final tx2 = expense(a, 'Lidl', '2026-10-06');
      await a.repo.setTxTag(tx1, trip, true);
      await a.repo.setRuleTag(payee(a, tx2), gift, true);
      await a.repo.setTxTag(tx2, gift, false);
      await a.repo.deleteTag(old);
      await syncAll([a, b]);
      now += 1000;
      await b.repo.setTxTag(tx1, trip, false);
      await syncAll([a, b]);
      final c = device('c');
      await syncAll([a, b, c]);
      expect(effective(c.repo, tx1), isEmpty);
      expect(effective(c.repo, tx2), isEmpty);
      expect(c.repo.tagTable().isLive(old), isFalse);
      expect(c.repo.tags(includeDeleted: true), hasLength(3));
      expect(c.repo.ruleTags()[payee(a, tx2)], {gift});
      sameTables(a.repo, c.repo);
    }, timeout: _t);

    test('a tag used in a refused name on one device cannot make the other fail: sync never refuses', () async {
      final a = device('a'), b = device('b');
      await a.repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await b.repo.addTag('Pets');
      await syncAll([a, b]);
      expect(a.repo.tags(), hasLength(1));
      expect(b.repo.tags(), hasLength(1));
      sameTables(a.repo, b.repo);
    }, timeout: _t);
  });

  group('backup', () {
    test('a backup round trip keeps tags (deleted, hidden), off and on links and rule tags', () async {
      final a = device('a');
      final trip = await a.repo.addTag('Trip');
      final gift = await a.repo.addTag('Gift');
      final gone = await a.repo.addTag('Gone');
      final tx1 = expense(a, 'Lidl');
      final tx2 = expense(a, 'Lidl', '2026-10-06');
      await a.repo.setRuleTag(payee(a, tx1), gift, true);
      await a.repo.setTxTag(tx1, gift, false);
      await a.repo.setTxTag(tx2, trip, true);
      now += 1000;
      await a.repo.updateTag(trip, hidden: true);
      await a.repo.deleteTag(gone);

      final file = await backupBytes(a.repo, key);
      final fresh = WalletRepo.inMemory(now: () => now);
      addTearDown(fresh.close);
      final count = await restoreBackupBytes(fresh, file, key);
      expect(count, a.repo.snapshotOps().length);
      for (final t in _tables) {
        expect(dump(fresh, t), dump(a.repo, t), reason: t);
      }
      expect(effective(fresh, tx1), isEmpty);
      expect(effective(fresh, tx2), effective(a.repo, tx2));
      expect(effective(fresh, tx2), unorderedEquals([trip, gift]), reason: 'trip by link, gift by the Lidl rule');
      expect(fresh.tagTable().isLive(gone), isFalse);
      expect(fresh.tags(includeDeleted: true), hasLength(3));
    }, timeout: _t);

    test('a wallet holding only a tag is not empty (restore refuses it)', () async {
      final a = device('a');
      final b = device('b');
      expect(a.repo.isEmpty, isTrue);
      await a.repo.addTag('Trip');
      expect(a.repo.isEmpty, isFalse);
      final file = await backupBytes(b.repo, key);
      await expectLater(restoreBackupBytes(a.repo, file, key), throwsStateError);
    }, timeout: _t);

    test('a restored backup reaches another device with its tags', () async {
      final a = device('a');
      final trip = await a.repo.addTag('Trip');
      final tx = expense(a, 'Hotel');
      await a.repo.setTxTag(tx, trip, true);
      final file = await backupBytes(a.repo, key);
      final c = device('c');
      await restoreBackupBytes(c.repo, file, key);
      final d = device('d');
      await syncAll([c, d]);
      expect(effective(d.repo, tx), [trip]);
      sameTables(c.repo, d.repo);
    }, timeout: _t);
  });

  group('schema 10 -> 11', () {
    test('the schema is 11 and the three tables exist and are empty on a new wallet', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      expect(WalletRepo.schemaVersion, 11);
      for (final t in _tables) {
        expect(r.db.select('SELECT * FROM $t'), isEmpty, reason: t);
      }
      expect(r.tagTable().pickable(), isEmpty);
      expect(r.ruleTags(), isEmpty);
    });

    test('an old schema-7 database opens at 11, keeps its rows, writes no tag ops, and accepts tags', () async {
      final d = Directory.systemTemp.createTempSync('bw-t1-old-');
      addTearDown(() => d.deleteSync(recursive: true));
      final path = '${d.path}/schema7_plain.db';
      File('test/fixtures/old_builds/schema7_plain.db').copySync(path);
      final r = WalletRepo.open(path, now: () => now);
      addTearDown(r.close);
      expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'].toString(), '11');
      expect(r.transactions(includeHidden: true), isNotEmpty);
      for (final t in _tables) {
        expect(r.db.select('SELECT * FROM $t'), isEmpty, reason: t);
      }
      expect(r.pendingOps().where((o) => const {'tag', 'txtag', 'ruletag'}.contains(o.$2.entity)), isEmpty);
      final id = await r.addTag('Trip');
      expect(r.tagTable().label(id), 'Trip');
    }, timeout: _t);

    test('a schema-10 database (no tag tables) opens, gets them, keeps its data, and a second open changes nothing', () async {
      final d = Directory.systemTemp.createTempSync('bw-t1-v10-');
      addTearDown(() => d.deleteSync(recursive: true));
      final path = '${d.path}/w.db';
      final first = WalletRepo.open(path, now: () => now);
      final cat = await first.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final tx = first.addTransaction(date: '2026-10-05', amount: 1234, category: cat, note: 'Pet shop');
      for (final t in _tables) {
        first.db.execute('DROP TABLE $t');
      }
      first.db.execute("UPDATE meta SET value = '10' WHERE key = 'schema'");
      first.close();

      final again = WalletRepo.open(path, now: () => now);
      expect(again.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'].toString(), '11');
      for (final t in _tables) {
        expect(again.db.select('SELECT * FROM $t'), isEmpty, reason: t);
      }
      expect(again.transactions().single.id, tx);
      expect(again.categoryTable().label(cat), 'Pets');
      final ops = again.pendingOps().length;
      again.close();
      final third = WalletRepo.open(path, now: () => now);
      addTearDown(third.close);
      expect(third.pendingOps().length, ops);
      final id = await third.addTag('Trip');
      await third.setTxTag(tx, id, true);
      expect(effective(third, tx), [id]);
    }, timeout: _t);

    test('a new tag on an upgraded wallet syncs to a new device', () async {
      final d = Directory.systemTemp.createTempSync('bw-t1-up-');
      addTearDown(() => d.deleteSync(recursive: true));
      final path = '${d.path}/schema7_plain.db';
      File('test/fixtures/old_builds/schema7_plain.db').copySync(path);
      final old = WalletRepo.open(path, now: () => now);
      addTearDown(old.close);
      final oldDev = Device('old', null, key, () => now)..repo = old;
      devices.add(oldDev);
      final fresh = device('fresh');
      final id = await old.addTag('Trip');
      await syncAll([oldDev, fresh]);
      expect(fresh.repo.tagTable().label(id), 'Trip');
    }, timeout: _t);
  });
}
