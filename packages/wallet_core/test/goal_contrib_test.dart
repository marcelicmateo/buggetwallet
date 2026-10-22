// Goal contributions: a goal's saved total is its stored base plus synced contribution rows, so adds made on
// offline devices are never lost. Migration, mixed versions, caps, sync. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

/// The schema as builds before `goal_contrib` created it (no contributions table, no `schema` meta key).
const _schemaBeforeContrib = '''
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS tx(
  id TEXT PRIMARY KEY, source TEXT NOT NULL DEFAULT '', date TEXT NOT NULL DEFAULT '', amount INTEGER NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'EUR', bank_type TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
  category TEXT, note TEXT, manual INTEGER NOT NULL DEFAULT 0, matched_to TEXT, deleted INTEGER NOT NULL DEFAULT 0, seen_bank TEXT);
CREATE INDEX IF NOT EXISTS tx_date ON tx(date);
CREATE TABLE IF NOT EXISTS goals(id TEXT PRIMARY KEY, name TEXT, target INTEGER NOT NULL DEFAULT 0, saved INTEGER NOT NULL DEFAULT 0,
  monthly INTEGER NOT NULL DEFAULT 0, sort INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS wish(id TEXT PRIMARY KEY, name TEXT, price INTEGER NOT NULL DEFAULT 0, added INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'waiting', decided INTEGER, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS settings(id TEXT PRIMARY KEY, value TEXT, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS merchant_rules(id TEXT PRIMARY KEY, category TEXT, deleted INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS clocks(entity TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, hlc TEXT NOT NULL, PRIMARY KEY(entity, id, field));
CREATE TABLE IF NOT EXISTS outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS peer_files(device TEXT NOT NULL, file TEXT NOT NULL, PRIMARY KEY(device, file));
''';

var _t = 4000000000000;
String _h([String node = 'peer']) => Hlc(_t++, 0, node).toString();

Op _goalOp(String id, Map<String, Object?> f, {String node = 'peer'}) => Op('goal', id, f, _h(node));
Op _contribOp(String id, String goal, int cents, {String date = '2026-01-20', String node = 'peer', int deleted = 0}) =>
    Op('goal_contrib', id, {'goal_id': goal, 'amount': cents, 'date': date, 'deleted': deleted}, _h(node));

int _savedOf(WalletRepo r, String id) => r.goals().singleWhere((g) => g.id == id).saved;

/// Fields of every pending op for [entity].
List<Map<String, Object?>> _pending(WalletRepo r, String entity) => [
      for (final (_, op) in r.pendingOps())
        if (op.entity == entity) op.fields
    ];

void main() {
  group('goalTotal (pure)', () {
    test('base plus contributions, negative ones subtract', () {
      expect(goalTotal(1000, [500, -200, 3000]), 4300);
      expect(goalTotal(0, const []), 0);
      expect(goalTotal(-500, const []), -500, reason: 'a negative total is allowed, not clamped to 0');
    });

    test('clamped to ±maxSaved; unclamped on request; never overflows', () {
      expect(goalTotal(Goal.maxSaved, [1]), Goal.maxSaved);
      expect(goalTotal(Goal.maxSaved, [1], clamped: false), Goal.maxSaved + 1);
      expect(goalTotal(-Goal.maxSaved, [-1]), -Goal.maxSaved);
      const huge = 9007199254740992; // 2^53, the largest synced whole number
      final many = List.filled(5000, huge);
      expect(goalTotal(huge, many), Goal.maxSaved);
      expect(goalTotal(huge, many, clamped: false), huge + 5000 * Goal.maxContribution, reason: 'each row counts at most maxContribution');
      expect(goalTotal(-huge, List.filled(5000, -huge)), -Goal.maxSaved);
      expect(goalTotal(-9223372036854775807, [-9223372036854775807]), -Goal.maxSaved, reason: 'a damaged stored base');
    });
  });

  group('saveGoal and addGoalContribution (one device)', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('a new goal stores its saved total as the base; no contribution', () {
      final id = r.saveGoal(name: 'Synthetic fund', target: 100000, saved: 2500, monthly: 5000, sort: 1);
      expect(_savedOf(r, id), 2500);
      expect(_pending(r, 'goal').single['saved'], 2500);
      expect(_pending(r, 'goal_contrib'), isEmpty);
    });

    test('an edit with the same total writes no saved field and no contribution', () {
      final id = r.saveGoal(name: 'Synthetic fund', target: 100000, saved: 2500, monthly: 5000, sort: 1);
      r.markExported(r.pendingOps().last.$1);
      r.saveGoal(id: id, name: 'Renamed fund', target: 200000, saved: 2500, monthly: 6000, sort: 1);
      final f = _pending(r, 'goal').single;
      expect(f.containsKey('saved'), isFalse);
      expect((f['name'], f['target'], f['monthly']), ('Renamed fund', 200000, 6000));
      expect(_pending(r, 'goal_contrib'), isEmpty);
      expect(_savedOf(r, id), 2500);
    });

    test('a changed total becomes ONE contribution of the difference; the base is untouched', () {
      final id = r.saveGoal(name: 'Synthetic fund', target: 100000, saved: 2500, monthly: 5000, sort: 1);
      r.markExported(r.pendingOps().last.$1);
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: 7500, monthly: 5000, sort: 1);
      final c = _pending(r, 'goal_contrib').single;
      expect((c['goal_id'], c['amount']), (id, 5000));
      expect(c['date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(_pending(r, 'goal').single.containsKey('saved'), isFalse);
      expect(r.db.select('SELECT saved FROM goals WHERE id = ?', [id]).first['saved'], 2500);
      expect(_savedOf(r, id), 7500);
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 5000, sort: 1);
      expect(_savedOf(r, id), 1000);
      expect([for (final c in r.goalContributions(id)) c.amount], unorderedEquals([5000, -6500]));
    });

    test('addGoalContribution: adds a dated row with its creation clock; 0 writes nothing', () {
      final id = r.saveGoal(name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      final c1 = r.addGoalContribution(id, 5000, date: '2026-01-20');
      final c2 = r.addGoalContribution(id, -300);
      expect(c1, isNotNull);
      expect(_savedOf(r, id), 5700);
      final list = r.goalContributions(id);
      expect(list.map((c) => c.id), [c1, c2]);
      expect((list.first.goalId, list.first.amount, list.first.date), (id, 5000, '2026-01-20'));
      expect(list.first.created, isNotNull);
      expect(Hlc.parse(list.first.created!).node, r.deviceId);
      expect(list.last.date, isoDate(DateTime.now()));
      final before = r.pendingOps().length;
      expect(r.addGoalContribution(id, 0), isNull);
      expect(r.pendingOps().length, before);
    });

    test('addGoalContribution refuses a missing goal, a bad date and totals beyond the cap; a deleted goal gets nothing', () {
      final id = r.saveGoal(name: 'Synthetic fund', target: 100000, saved: 0, monthly: 0, sort: 1);
      expect(() => r.addGoalContribution('nope', 100), throwsArgumentError);
      expect(() => r.addGoalContribution(id, 100, date: '20.01.2026'), throwsArgumentError);
      expect(() => r.addGoalContribution(id, Goal.maxContribution + 1), throwsArgumentError);
      expect(() => r.addGoalContribution(id, -Goal.maxContribution - 1), throwsArgumentError);
      expect(() => r.addGoalContribution(id, Goal.maxSaved + 1), throwsArgumentError);
      expect(() => r.addGoalContribution(id, -Goal.maxSaved - 1), throwsArgumentError);
      r.deleteGoal(id);
      expect(r.addGoalContribution(id, 100), isNull, reason: 'deleted meanwhile: nothing to add to, no error');
      expect(r.goals(), isEmpty, reason: 'not brought back');
      expect(r.db.select('SELECT * FROM goal_contrib'), isEmpty);
    });

    test('deleting a goal hides its contributions', () {
      final id = r.saveGoal(name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      final other = r.saveGoal(name: 'Other fund', target: 100000, saved: 0, monthly: 0, sort: 2);
      r.addGoalContribution(id, 5000);
      r.addGoalContribution(other, 700);
      r.deleteGoal(id);
      expect(r.goals().map((g) => g.id), [other]);
      expect(_savedOf(r, other), 700);
      expect(r.goalContributions(id), isEmpty);
    });

    test('a correction below zero is allowed (not clamped), and setting a value again is exact', () {
      final id = r.saveGoal(name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      r.addGoalContribution(id, -3000);
      expect(_savedOf(r, id), -2000);
      expect(monthsToGoal(r.goals().single), isNull, reason: 'monthly 0: never');
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: 0, monthly: 0, sort: 1);
      expect(_savedOf(r, id), 0);
    });

    test('totals at the ±10 billion cap: clamped on save, refused beyond on add, a set from the cap is exact', () {
      final id = r.saveGoal(name: 'Synthetic fund', target: 100000, saved: Goal.maxSaved + 999, monthly: 0, sort: 1);
      expect(_savedOf(r, id), Goal.maxSaved, reason: 'saved is clamped to the cap');
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: Goal.maxSaved - 1, monthly: 0, sort: 1);
      expect(_savedOf(r, id), Goal.maxSaved - 1);
      r.addGoalContribution(id, 1);
      expect(_savedOf(r, id), Goal.maxSaved);
      expect(() => r.addGoalContribution(id, 1), throwsArgumentError);
      r.addGoalContribution(id, -5);
      expect(_savedOf(r, id), Goal.maxSaved - 5);
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: -Goal.maxSaved, monthly: 0, sort: 1);
      expect(_savedOf(r, id), -Goal.maxSaved);
      expect(() => r.addGoalContribution(id, -1), throwsArgumentError);
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: Goal.maxSaved, monthly: 0, sort: 1);
      expect(_savedOf(r, id), Goal.maxSaved, reason: 'a full swing from -cap to +cap fits one contribution');
      expect(r.pendingOps().every((o) => o.$2.fields.values.every((v) => v is! int || v.abs() <= Goal.maxContribution)), isTrue);
    });

    test('a total beyond the cap (adds on several devices at once) reads as the cap; sets and corrections still work', () {
      final id = r.saveGoal(name: 'Synthetic fund', target: 100000, saved: Goal.maxSaved, monthly: 0, sort: 1);
      r.applyRemote([_contribOp('c1', id, Goal.maxSaved)]);
      expect(_savedOf(r, id), Goal.maxSaved);
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: Goal.maxSaved, monthly: 0, sort: 1);
      expect(r.goalContributions(id).length, 1, reason: 'the shown total is unchanged: no contribution');
      r.addGoalContribution(id, -100);
      expect(_savedOf(r, id), Goal.maxSaved, reason: 'a correction toward zero is allowed, still beyond the cap');
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      expect(_savedOf(r, id), 1000, reason: 'twice the cap away: one contribution, exact');
      r.applyRemote([_contribOp('c2', id, Goal.maxContribution), _contribOp('c3', id, Goal.maxContribution)]);
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      expect(_savedOf(r, id), Goal.maxSaved, reason: 'four times the cap away: the first set moves by maxContribution');
      r.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      expect(_savedOf(r, id), 1000, reason: 'the second set lands exactly');
    });

    test('payGoals adds each monthly as a contribution; a period pays once per goal; never writes saved', () {
      final a = r.saveGoal(name: 'Fund A', target: 100000, saved: 1000, monthly: 5000, sort: 1);
      final b = r.saveGoal(name: 'Fund B', target: 100000, saved: 0, monthly: 0, sort: 2);
      r.markExported(r.pendingOps().last.$1);
      r.payGoals(period: '2026-01-15');
      r.payGoals(period: '2026-01-15');
      expect((_savedOf(r, a), _savedOf(r, b)), (6000, 0));
      expect(r.goalContributions(b), isEmpty, reason: 'monthly 0: no row');
      r.payGoals(period: '2026-02-15');
      expect(_savedOf(r, a), 11000);
      expect(_pending(r, 'goal'), isEmpty);
      r.updateSettings({'periodStart': '2026-03-15'});
      r.payGoals();
      r.payGoals();
      expect(_savedOf(r, a), 21000, reason: 'no period given: a new row per call, never the periodStart setting');
    });

    test('payGoals with no period known adds a row per call', () {
      final a = r.saveGoal(name: 'Fund A', target: 100000, saved: 0, monthly: 5000, sort: 1);
      r.payGoals();
      r.payGoals();
      expect(_savedOf(r, a), 10000);
    });

    test('the budget engine: goal monthly counts in the plan, contributions do not; months-to-goal uses the total', () {
      final a = r.saveGoal(name: 'Fund A', target: 100000, saved: 10000, monthly: 10000, sort: 1);
      final gone = r.saveGoal(name: 'Fund B', target: 100000, saved: 0, monthly: 7000, sort: 2);
      r.addGoalContribution(a, 40000);
      r.addGoalContribution(gone, 1000);
      r.deleteGoal(gone);
      r.updateSettings({'salary': 200000, 'periodStart': '2026-01-15', 'paydayDay': 15});
      final p = computePeriod(const [], r.settings(), r.goals(), '2026-01-20');
      expect(p.goalMonthly, 10000);
      expect(p.flexBudget, 200000 - 10000);
      expect(r.goals().single.saved, 50000);
      expect(monthsToGoal(r.goals().single), 5);
    });

    test('logs carry no amounts or goal names', () {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = was;
      });
      final id = r.saveGoal(name: 'Synthetic secret fund', target: 9876543, saved: 1234567, monthly: 7654321, sort: 1);
      r.addGoalContribution(id, 3456789);
      r.saveGoal(id: id, name: 'Synthetic secret fund', target: 9876543, saved: 2345678, monthly: 7654321, sort: 1);
      r.payGoals(period: '2026-01-15');
      r.goals();
      final text = lines.join('\n');
      expect(text, contains('goal_contrib'));
      for (final s in ['secret', '1234567', '3456789', '2345678', '7654321', '9876543', '12345.67', '34567.89']) {
        expect(text, isNot(contains(s)), reason: s);
      }
    });
  });

  group('remote contribution ops', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('the same op applied twice counts once (idempotent by id and clock)', () {
      final op = _contribOp('c1', 'g1', 5000);
      expect(
          r.applyRemote([
            _goalOp('g1', {'name': 'Synthetic', 'saved': 1000, 'deleted': 0}),
            op
          ]),
          2);
      expect(r.applyRemote([op]), 0);
      expect(r.applyRemote([op, op]), 0);
      expect(_savedOf(r, 'g1'), 6000);
    });

    test('a contribution for an unknown goal is kept hidden and counts when the goal arrives', () {
      r.applyRemote([_contribOp('c1', 'g-later', 2500)]);
      expect(r.goals(), isEmpty);
      expect(r.goalContributions('g-later'), isEmpty);
      r.applyRemote([
        _goalOp('g-later', {'name': 'Synthetic', 'saved': 500, 'deleted': 0})
      ]);
      expect(_savedOf(r, 'g-later'), 3000);
    });

    test('a contribution for a deleted goal stays hidden; undeleting brings it back', () {
      r.applyRemote([
        _goalOp('g1', {'name': 'Synthetic', 'saved': 500, 'deleted': 0}),
        _goalOp('g1', {'deleted': 1}),
        _contribOp('c1', 'g1', 2500),
      ]);
      expect(r.goals(), isEmpty);
      r.applyRemote([
        _goalOp('g1', {'deleted': 0})
      ]);
      expect(_savedOf(r, 'g1'), 3000);
    });

    test('a deleted contribution does not count; damaged fields are refused', () {
      r.applyRemote([
        _goalOp('g1', {'name': 'Synthetic', 'saved': 0, 'deleted': 0}),
        _contribOp('c1', 'g1', 2500),
        _contribOp('c2', 'g1', 700),
        Op('goal_contrib', 'c1', const {'deleted': 1}, _h()),
        Op('goal_contrib', 'c3', const {'goal_id': 'g1', 'amount': 'lots', 'date': '2026-01-20', 'deleted': 0}, _h()),
        Op('goal_contrib', 'c4', const {'goal_id': 'g1', 'amount': 0.5}, _h()),
        Op('goal_contrib', 'c5', const {'deleted': 0}, _h()), // no goal: a row that belongs to nothing
      ]);
      expect(_savedOf(r, 'g1'), 700);
      expect(r.goalContributions('g1').map((c) => c.id), ['c2']);
    });

    test('remote amounts far beyond the cap cannot overflow the total', () {
      const huge = 9007199254740992;
      r.applyRemote([
        _goalOp('g1', {'name': 'Synthetic', 'saved': huge, 'deleted': 0}),
        for (var i = 0; i < 1200; i++) _contribOp('c$i', 'g1', huge),
      ]);
      expect(_savedOf(r, 'g1'), Goal.maxSaved);
      r.applyRemote([
        for (var i = 0; i < 1200; i++) Op('goal_contrib', 'c$i', const {'amount': -huge}, _h()),
        _goalOp('g1', {'saved': -huge}),
      ]);
      expect(_savedOf(r, 'g1'), -Goal.maxSaved);
    });
  });

  group('mixed versions (an older build only knows the saved field)', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('a later remote write of saved is the new base; contributions still add on top (no double count)', () {
      // Start 1000 on every device. A new device adds 5000 as a contribution; the old device, which never sees
      // contributions, still shows 1000 and adds 2000 by writing saved = 3000.
      r.applyRemote([
        _goalOp('g1', {'name': 'Synthetic', 'target': 100000, 'saved': 1000, 'deleted': 0}, node: 'old')
      ]);
      r.addGoalContribution('g1', 5000);
      expect(_savedOf(r, 'g1'), 6000);
      r.applyRemote([
        _goalOp('g1', {'name': 'Synthetic', 'target': 100000, 'saved': 3000, 'monthly': 0}, node: 'old')
      ]);
      expect(_savedOf(r, 'g1'), 8000, reason: 'base 3000 + 5000: both adds count once');
    });

    test('new builds never write the saved field of an existing goal', () {
      r.applyRemote([
        _goalOp('g1', {'name': 'Synthetic', 'saved': 1000, 'monthly': 500, 'deleted': 0}, node: 'old')
      ]);
      r.saveGoal(id: 'g1', name: 'Synthetic', target: 1, saved: 4000, monthly: 500, sort: 0);
      r.addGoalContribution('g1', 10);
      r.payGoals(period: '2026-01-15');
      expect(_pending(r, 'goal').where((f) => f.containsKey('saved')), isEmpty);
      expect(_savedOf(r, 'g1'), 4510);
      expect(r.db.select("SELECT saved FROM goals WHERE id = 'g1'").first['saved'], 1000);
    });
  });

  group('migration', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bw-contrib-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String oldDb({List<String> peerFiles = const []}) {
      final path = '${tmp.path}/old.db';
      final db = sqlite3.open(path);
      db.execute(_schemaBeforeContrib);
      db.execute(
          "INSERT INTO meta(key, value) VALUES('device_id', '00112233aabbccdd'), ('hlc', '000004000000000000:00000:00112233aabbccdd')");
      db.execute("INSERT INTO goals(id, name, target, saved, monthly, sort) VALUES('g1', 'Synthetic fund', 100000, 2345, 5000, 1), "
          "('g2', 'Other fund', 50000, 0, 1000, 2), ('g3', 'Gone fund', 50000, 999, 0, 3)");
      db.execute("UPDATE goals SET deleted = 1 WHERE id = 'g3'");
      for (final f in peerFiles) {
        db.execute("INSERT INTO peer_files(device, file) VALUES('p1', ?)", [f]);
      }
      db.close();
      return path;
    }

    test('existing goals keep their saved totals exactly; nothing is written', () {
      final r = WalletRepo.open(oldDb());
      expect([for (final g in r.goals()) (g.id, g.saved, g.monthly)], [('g1', 2345, 5000), ('g2', 0, 1000)]);
      expect(r.pendingOps(), isEmpty);
      expect(r.db.select('SELECT * FROM goal_contrib'), isEmpty);
      expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
      r.close();
    });

    test('an upgraded device re-reads peer files once and picks up contributions an older build skipped', () async {
      final key = VaultKey.generate();
      final dir = Directory('${tmp.path}/sync/budget-wallet/devices/p1')..createSync(recursive: true);
      File('${tmp.path}/sync/budget-wallet/vault.json').writeAsStringSync(jsonEncode({'v': 1, 'kid': await key.keyId()}));
      final ops = [
        _goalOp('g1', {'name': 'Synthetic fund'}).toJson(),
        _contribOp('c1', 'g1', 5000).toJson(),
      ];
      File('${dir.path}/0000000001.bwop').writeAsBytesSync(await seal(utf8.encode(jsonEncode(ops)), key));
      // The old build already read that file (and ignored the contribution).
      final path = oldDb(peerFiles: ['0000000001.bwop']);
      final r = WalletRepo.open(path);
      expect(r.peerFileSeen('p1', '0000000001.bwop'), isFalse);
      expect(_savedOf(r, 'g1'), 2345);
      final rep = await FolderSync('${tmp.path}/sync', key).run(r);
      expect(rep.filesRead, 1);
      expect(_savedOf(r, 'g1'), 7345);
      expect((await FolderSync('${tmp.path}/sync', key).run(r)).filesRead, 0);
      r.close();
      final again = WalletRepo.open(path);
      expect(again.peerFileSeen('p1', '0000000001.bwop'), isTrue, reason: 'the replay happens once, not on every open');
      expect(_savedOf(again, 'g1'), 7345);
      again.close();
    });

    test('a new database records the schema version and keeps its peer files on reopen', () {
      final path = '${tmp.path}/new.db';
      final r = WalletRepo.open(path);
      r.markPeerFile('p1', '0000000001.bwop');
      r.close();
      final again = WalletRepo.open(path);
      expect(again.peerFileSeen('p1', '0000000001.bwop'), isTrue);
      again.close();
    });
  });

  group('sync between devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = 1767225600000;
    final devices = <Device>[];

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> syncAll(List<Device> ds) async {
      for (var round = 0; round < 2; round++) {
        for (final d in ds) {
          d.deliver(net, Random(round));
          await d.run();
          d.upload(net);
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-contrib-sync-');
      key = VaultKey.generate();
      net = Net();
      now = 1767225600000;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    test('A +5000 and B +3000 offline from the same start: both see start + 8000', () async {
      final a = device('a'), b = device('b');
      final id = a.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      await syncAll([a, b]);
      Goal g(Device d) => d.repo.goals().single;
      // Each device types its new total into the goal sheet (the app's only way today).
      a.repo.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: g(a).saved + 5000, monthly: 0, sort: 1);
      now += 10;
      b.repo.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: g(b).saved + 3000, monthly: 0, sort: 1);
      await syncAll([a, b]);
      expect((g(a).saved, g(b).saved), (9000, 9000));
      expect(dump(a.repo), dump(b.repo));
    });

    for (final n in [2, 3, 4]) {
      test('$n devices add concurrently (saveGoal, addGoalContribution, corrections): all adds count, all converge', () async {
        final ds = [for (var i = 0; i < n; i++) device('d$i')];
        final id = ds.first.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 2000, monthly: 1000, sort: 1);
        await syncAll(ds);
        var expected = 2000;
        for (var i = 0; i < n; i++) {
          final r = ds[i].repo;
          final add = 100 * (i + 1);
          r.saveGoal(id: id, name: 'Name $i', target: 100000, saved: r.goals().single.saved + add, monthly: 1000, sort: 1);
          r.addGoalContribution(id, 7 * (i + 1));
          r.addGoalContribution(id, -(i + 1));
          expected += add + 6 * (i + 1);
          now += 3;
        }
        await syncAll(ds);
        for (final d in ds) {
          expect(d.repo.goals().single.saved, expected, reason: d.name);
          expect(dump(d.repo), dump(ds.first.repo), reason: d.name);
        }
        expect(ds.first.repo.goals().single.name, 'Name ${n - 1}', reason: 'other fields stay last-writer-wins');
        final want = lastWriterWins(await opsInNet(net, key));
        for (final d in ds) {
          expect(lwwDiff(d.repo, want), isEmpty, reason: d.name);
        }
      });
    }

    test('two offline corrections to 0 overshoot below zero (documented); the next set is exact everywhere', () async {
      final a = device('a'), b = device('b');
      final id = a.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 5000, monthly: 0, sort: 1);
      await syncAll([a, b]);
      a.repo.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: 0, monthly: 0, sort: 1);
      b.repo.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: 0, monthly: 0, sort: 1);
      await syncAll([a, b]);
      expect(a.repo.goals().single.saved, -5000);
      a.repo.saveGoal(id: id, name: 'Synthetic fund', target: 100000, saved: 0, monthly: 0, sort: 1);
      await syncAll([a, b]);
      expect((a.repo.goals().single.saved, b.repo.goals().single.saved), (0, 0));
    });

    test('a name edit on A while B adds offline: B\'s add survives', () async {
      final a = device('a'), b = device('b');
      final id = a.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      await syncAll([a, b]);
      b.repo.addGoalContribution(id, 3000);
      now += 10;
      a.repo.saveGoal(id: id, name: 'Renamed fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        expect((d.repo.goals().single.name, d.repo.goals().single.saved), ('Renamed fund', 4000), reason: d.name);
      }
    });

    test('paying the same period on two offline devices counts once', () async {
      final a = device('a'), b = device('b');
      final id = a.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 5000, sort: 1);
      await syncAll([a, b]);
      a.repo.payGoals(period: '2026-01-15');
      now += 10;
      b.repo.payGoals(period: '2026-01-15');
      await syncAll([a, b]);
      expect((a.repo.goals().single.saved, b.repo.goals().single.saved), (6000, 6000));
      expect(a.repo.goalContributions(id).length, 1);
    });

    test('a goal deleted on A while B adds to it: hidden on both, same tables', () async {
      final a = device('a'), b = device('b');
      final id = a.repo.saveGoal(name: 'Synthetic fund', target: 100000, saved: 1000, monthly: 0, sort: 1);
      await syncAll([a, b]);
      a.repo.deleteGoal(id);
      b.repo.addGoalContribution(id, 3000);
      await syncAll([a, b]);
      expect(a.repo.goals(), isEmpty);
      expect(b.repo.goals(), isEmpty);
      expect(dump(a.repo), dump(b.repo));
    });
  });
}
