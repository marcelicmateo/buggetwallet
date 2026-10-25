// Stage P4 spec tests, repo half: addRecurring / updateRecurring, detection and payment refresh through the repo,
// schema 11 -> 12, backup round trip, two devices. Written from docs/context/P4_SPEC.md only. SYNTHETIC data.
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

NormalizedTransaction zorb(String date, int cents) => n(date, -cents, 'POS plaćanje', 'Zorblex Club 2026');

final zorblex = merchantKey(
    const Tx(id: 'x', source: 'pbz', date: '2026-01-01', amount: -1, bankType: 'POS plaćanje', description: 'Zorblex Club 2026'));

void main() {
  late WalletRepo r;
  var now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
  setUp(() {
    now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
    r = WalletRepo.inMemory(now: () => now);
  });
  tearDown(() => r.close());

  ImportBatch batch(List<NormalizedTransaction> rows) => ImportBatch(source: 'pbz', transactions: rows);

  String add({
    String label = 'Zorblex Club',
    String category = 'Shopping',
    int amount = 5000,
    int? min,
    int? max,
    int interval = 30,
    String firstDue = '2026-03-20',
    String? payee,
    int? instalments,
  }) =>
      r.addRecurring(
          label: label,
          category: category,
          amount: amount,
          minAmount: min,
          maxAmount: max,
          intervalDays: interval,
          firstDue: firstDue,
          payee: payee,
          instalments: instalments);

  RecurringBill byId(String id) => r.recurringBills().singleWhere((b) => b.id == id);

  group('schema', () {
    test('schema version is 12 and the recurring entity declares the new columns', () {
      expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(12)); // P6 made it 13
      final e = entitySchema['recurring']!;
      expect(e.columnNames, containsAll(['min_amount', 'max_amount', 'ends_on', 'manual']));
      expect(e.column('min_amount')!.type, ColumnType.integer);
      expect(e.column('min_amount')!.nullable, isTrue);
      expect(e.column('max_amount')!.type, ColumnType.integer);
      expect(e.column('max_amount')!.nullable, isTrue);
      expect(e.column('ends_on')!.type, ColumnType.text);
      expect(e.column('ends_on')!.nullable, isTrue);
      expect(e.column('manual')!.type, ColumnType.flag);
      expect(entityTables['recurring']!.$2, containsAll(['min_amount', 'max_amount', 'ends_on', 'manual']));
    });

    test('a schema 11 database opens: columns added, old row readable as a plain monthly bill, meta says 12', () {
      final tmp = Directory.systemTemp.createTempSync('bw-p4-schema-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/old.db';
      WalletRepo.open(path).close();
      final db = sqlite3.open(path);
      for (final c in ['min_amount', 'max_amount', 'ends_on', 'manual']) {
        db.execute('ALTER TABLE recurring DROP COLUMN $c');
      }
      db.execute(
          "INSERT INTO recurring(id, payee, label, category, expected_amount, interval_days, next_due, status) VALUES('rec:old', 'old_payee', 'Old', 'Shopping', 2500, 30, '2026-04-01', 'confirmed')");
      db.execute("UPDATE meta SET value = '11' WHERE key = 'schema'");
      db.close();

      final o = WalletRepo.open(path, now: () => now);
      addTearDown(o.close);
      final cols = [for (final c in o.db.select('PRAGMA table_info(recurring)')) c['name']];
      expect(cols, containsAll(['min_amount', 'max_amount', 'ends_on', 'manual']));
      expect(o.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'].toString(), '${WalletRepo.schemaVersion}');
      final b = o.recurringBills().singleWhere((x) => x.id == 'rec:old');
      expect((b.minAmount, b.maxAmount, b.endsOn, b.manual, b.expectedAmount, b.intervalDays), (null, null, null, false, 2500, 30));
      expect(b.hasRange, isFalse);
    });
  });

  group('addRecurring', () {
    test('a manual bill: id rec:m + 12 hex, confirmed at once, manual, fields as given', () {
      final id = add(payee: zorblex);
      expect(id, matches(RegExp(r'^rec:m[0-9a-f]{12}$')));
      final b = byId(id);
      expect((b.manual, b.status, b.confirmed), (true, 'confirmed', true));
      expect((b.label, b.category, b.expectedAmount, b.intervalDays, b.nextDue, b.payee),
          ('Zorblex Club', 'Shopping', 5000, 30, '2026-03-20', zorblex));
      expect((b.minAmount, b.maxAmount, b.endsOn, b.lastPaidTx), (null, null, null, null));
      expect(add(payee: null), isNot(id));
    });

    test('it syncs as a recurring op with the new column names', () {
      final id = add(min: 4000, max: 7000, payee: zorblex);
      final op = r.pendingOps().map((o) => o.$2).lastWhere((o) => o.entity == 'recurring' && o.id == id);
      expect(op.fields['min_amount'], 4000);
      expect(op.fields['max_amount'], 7000);
      expect(op.fields['manual'], 1);
      expect(op.fields['status'], 'confirmed');
    });

    test('a range is stored; reserveAmount is the highest', () {
      final b = byId(add(min: 4000, max: 7000));
      expect((b.minAmount, b.maxAmount, b.hasRange, b.reserveAmount), (4000, 7000, true, 7000));
      final edge = byId(add(amount: 4000, min: 4000, max: 4000, firstDue: '2026-04-01'));
      expect(edge.hasRange, isTrue);
    });

    test('instalments set endsOn: calendar months for a monthly interval, else firstDue + (N - 1) * interval', () {
      expect(byId(add(instalments: 3)).endsOn, '2026-05-20', reason: '2026-03-20 + 2 calendar months (lead decision, HIGH 2)');
      expect(byId(add(instalments: 1, firstDue: '2026-03-21')).endsOn, '2026-03-21');
      expect(byId(add(instalments: 4, interval: 7, firstDue: '2026-03-02')).endsOn, '2026-03-23');
      expect(byId(add(firstDue: '2026-03-22')).endsOn, isNull);
    });

    test('instalments 1 and 600 are allowed, 0 and 601 are not', () {
      add(instalments: 1, firstDue: '2026-04-01');
      add(instalments: 600, interval: 1, firstDue: '2026-04-02');
      expect(() => add(instalments: 0, firstDue: '2026-04-03'), throwsArgumentError);
      expect(() => add(instalments: 601, firstDue: '2026-04-03'), throwsArgumentError);
      expect(() => add(instalments: -1, firstDue: '2026-04-03'), throwsArgumentError);
    });

    test('interval 1 and 400 are allowed, 0 and 401 are not', () {
      add(interval: 1, firstDue: '2026-04-01');
      add(interval: 400, firstDue: '2026-04-02');
      expect(() => add(interval: 0), throwsArgumentError);
      expect(() => add(interval: 401), throwsArgumentError);
      expect(() => add(interval: -7), throwsArgumentError);
    });

    test('label 1..40 characters', () {
      add(label: 'x');
      add(label: 'y' * 40, firstDue: '2026-04-01');
      expect(() => add(label: ''), throwsArgumentError);
      expect(() => add(label: 'z' * 41), throwsArgumentError);
    });

    test('amount 1..maxAmount', () {
      add(amount: 1);
      add(amount: WalletSettings.maxAmount, firstDue: '2026-04-01');
      expect(() => add(amount: 0), throwsArgumentError);
      expect(() => add(amount: -5), throwsArgumentError);
      expect(() => add(amount: WalletSettings.maxAmount + 1), throwsArgumentError);
    });

    test('range rules: 0 < min <= max <= maxAmount, amount within it', () {
      expect(() => add(min: 0, max: 7000), throwsArgumentError);
      expect(() => add(min: 7001, max: 7000, amount: 7000), throwsArgumentError);
      expect(() => add(min: 4000, max: WalletSettings.maxAmount + 1), throwsArgumentError);
      expect(() => add(min: 4000, max: 7000, amount: 3999), throwsArgumentError);
      expect(() => add(min: 4000, max: 7000, amount: 7001), throwsArgumentError);
      add(min: 4000, max: 7000, amount: 4000);
      add(min: 4000, max: 7000, amount: 7000, firstDue: '2026-04-01');
    });

    test('firstDue must be an ISO date', () {
      for (final bad in ['tomorrow', '2026-3-5', '', '2026/03/05', '05.03.2026']) {
        expect(() => add(firstDue: bad), throwsArgumentError, reason: bad);
      }
    });

    test('the category must be live', () {
      expect(() => add(category: 'No such category'), throwsArgumentError);
    });

    test('a payee another live bill uses is refused; after delete or for a distinct payee it is fine', () {
      final first = add(payee: zorblex);
      expect(() => add(payee: zorblex, firstDue: '2026-04-01'), throwsArgumentError);
      add(payee: 'quorvant_shop', firstDue: '2026-04-01');
      add(firstDue: '2026-04-02');
      add(firstDue: '2026-04-03');
      r.deleteRecurring(first);
      add(payee: zorblex, firstDue: '2026-04-04');
    });

    test('a refused call writes nothing', () {
      final ops = r.pendingOps().length;
      expect(() => add(amount: 0), throwsArgumentError);
      expect(() => add(interval: 401), throwsArgumentError);
      expect(r.pendingOps().length, ops);
      expect(r.recurringBills(includeDismissed: true), isEmpty);
    });

    test('the error text is readable (not empty, no id)', () {
      try {
        add(amount: 0);
        fail('should throw');
      } on ArgumentError catch (e) {
        expect(e.message.toString().trim(), isNotEmpty);
      }
    });
  });

  group('instalmentsLeft', () {
    test('cycles from nextDue to endsOn inclusive; null without endsOn', () {
      final id = add(instalments: 3);
      expect(r.instalmentsLeft(byId(id)), 3);
      expect(r.instalmentsLeft(byId(add(firstDue: '2026-04-01'))), isNull);
      expect(r.instalmentsLeft(byId(add(instalments: 1, firstDue: '2026-04-02'))), 1);
    });

    test('after a skip one fewer; after the last one 0', () async {
      final id = add(instalments: 2, firstDue: '2026-03-20');
      await r.skipRecurring(id);
      expect(r.instalmentsLeft(byId(id)), 1);
      await r.skipRecurring(id);
      expect(r.instalmentsLeft(byId(id)), 0);
      expect(byId(id).finished, isTrue);
    });
  });

  group('updateRecurring', () {
    test('changes only the given fields and writes only what changed', () {
      final id = add(payee: zorblex);
      final before = r.pendingOps().length;
      r.updateRecurring(id, label: 'Renamed');
      final ops = r.pendingOps().skip(before).map((o) => o.$2).where((o) => o.entity == 'recurring').toList();
      expect(ops, hasLength(1));
      expect(ops.single.fields, {'label': 'Renamed'});
      final b = byId(id);
      expect((b.label, b.expectedAmount, b.nextDue, b.category), ('Renamed', 5000, '2026-03-20', 'Shopping'));
      final again = r.pendingOps().length;
      r.updateRecurring(id, label: 'Renamed');
      expect(r.pendingOps().length, again, reason: 'same value: nothing to write');
    });

    test('amount, category, interval, nextDue, range and end can be changed', () {
      final id = add();
      r.updateRecurring(id,
          amount: 6000,
          category: 'Groceries',
          intervalDays: 7,
          nextDue: '2026-03-25',
          minAmount: 5000,
          maxAmount: 8000,
          endsOn: '2026-06-01');
      final b = byId(id);
      expect((b.expectedAmount, b.category, b.intervalDays, b.nextDue, b.minAmount, b.maxAmount, b.endsOn),
          (6000, 'Groceries', 7, '2026-03-25', 5000, 8000, '2026-06-01'));
    });

    test('clearRange and clearEnd remove them', () {
      final id = add(min: 4000, max: 7000, instalments: 3);
      r.updateRecurring(id, clearRange: true);
      expect(byId(id).minAmount, isNull);
      expect(byId(id).maxAmount, isNull);
      expect(byId(id).endsOn, isNotNull);
      r.updateRecurring(id, clearEnd: true);
      expect(byId(id).endsOn, isNull);
    });

    test('it works on a detected bill and does not confirm a candidate', () {
      r.importBatch(batch([zorb('2025-12-10', 2999), zorb('2026-01-09', 2999), zorb('2026-02-08', 2999)]));
      final c = r.recurringBills().single;
      expect(c.status, 'candidate');
      r.updateRecurring(c.id, label: 'My club', amount: 3100);
      final e = r.recurringBills().single;
      expect((e.label, e.expectedAmount, e.status, e.manual), ('My club', 3100, 'candidate', false));
    });

    test('same validation as addRecurring', () {
      final id = add();
      expect(() => r.updateRecurring(id, label: ''), throwsArgumentError);
      expect(() => r.updateRecurring(id, label: 'a' * 41), throwsArgumentError);
      expect(() => r.updateRecurring(id, amount: 0), throwsArgumentError);
      expect(() => r.updateRecurring(id, amount: WalletSettings.maxAmount + 1), throwsArgumentError);
      expect(() => r.updateRecurring(id, intervalDays: 0), throwsArgumentError);
      expect(() => r.updateRecurring(id, intervalDays: 401), throwsArgumentError);
      expect(() => r.updateRecurring(id, nextDue: 'soon'), throwsArgumentError);
      expect(() => r.updateRecurring(id, endsOn: '2026-13-40'), throwsArgumentError);
      expect(() => r.updateRecurring(id, category: 'No such category'), throwsArgumentError);
      expect(() => r.updateRecurring(id, minAmount: 8000, maxAmount: 7000), throwsArgumentError);
      expect(() => r.updateRecurring(id, minAmount: 0, maxAmount: 7000), throwsArgumentError);
      expect(() => r.updateRecurring(id, minAmount: 4000, maxAmount: 4500), throwsArgumentError, reason: 'amount 5000 outside the range');
      expect(byId(id).minAmount, isNull, reason: 'a refused call changes nothing');
      expect(byId(id).label, 'Zorblex Club');
    });

    test('an unknown id is an ArgumentError', () {
      expect(() => r.updateRecurring('rec:nope', label: 'x'), throwsArgumentError);
    });
  });

  group('detection through the repo', () {
    final weekly = [zorb('2026-02-02', 1500), zorb('2026-02-09', 1500), zorb('2026-02-16', 1500), zorb('2026-02-23', 1500)];

    test('weekly rows make a candidate with interval 7', () {
      r.importBatch(batch(weekly));
      final c = r.recurringBills().single;
      expect((c.status, c.intervalDays, c.nextDue, c.manual), ('candidate', 7, '2026-03-02', false));
    });

    test('a manual bill\'s payee is never detected: no duplicate candidate', () {
      add(payee: zorblex);
      r.importBatch(batch(weekly));
      final all = r.recurringBills(includeDismissed: true);
      expect(all, hasLength(1));
      expect(all.single.manual, isTrue);
      expect(all.single.id, isNot('rec:$zorblex'));
    });

    test('detection never rewrites a manual bill', () {
      final id = add(payee: zorblex, amount: 9999, interval: 91, firstDue: '2026-09-01');
      r.importBatch(batch(weekly));
      final b = byId(id);
      expect((b.expectedAmount, b.intervalDays, b.nextDue, b.label), (9999, 91, '2026-09-01', 'Zorblex Club'));
    });

    test('a dismissed weekly bill stays dismissed', () {
      r.importBatch(batch(weekly));
      final id = r.recurringBills().single.id;
      r.dismissRecurring(id);
      now = DateTime.utc(2026, 3, 20, 12).millisecondsSinceEpoch;
      r.importBatch(batch([zorb('2026-03-02', 1500)]));
      expect(r.recurringBills(), isEmpty);
      expect(r.recurringBills(includeDismissed: true).single.status, 'dismissed');
    });
  });

  group('payment refresh', () {
    test('a bill with no payee never matches a payment, whatever the amount', () {
      final id = add(amount: 5000, firstDue: '2026-03-10');
      r.importBatch(batch([zorb('2026-03-10', 5000)]));
      r.refreshRecurring('2026-03-15');
      final b = byId(id);
      expect((b.lastPaidTx, b.nextDue), (null, '2026-03-10'));
    });

    test('skipRecurring is the Mark paid of a bill without payee: nextDue moves one interval', () async {
      final id = add(interval: 91, firstDue: '2026-03-10');
      await r.skipRecurring(id);
      expect(byId(id).nextDue, '2026-06-09');
      expect(byId(id).lastPaidTx, isNull);
    });

    test('a single payment of a manual bill: lastPaidTx and nextDue = paying date + interval', () {
      final id = add(payee: zorblex, firstDue: '2026-03-10', interval: 91, amount: 5000);
      final pay = zorb('2026-03-12', 5000);
      r.importBatch(batch([pay]));
      final b = byId(id);
      expect((b.lastPaidTx, b.nextDue), (pay.id, '2026-06-11'));
      expect(b.manual, isTrue);
    });

    test('a payment outside the tolerance does not pay (quarterly: +8 days)', () {
      final id = add(payee: zorblex, firstDue: '2026-03-01', interval: 91, amount: 5000);
      r.importBatch(batch([zorb('2026-03-09', 5000)]));
      expect(byId(id).lastPaidTx, isNull);
    });

    test('a payment in range pays a bill with a range', () {
      final id = add(payee: zorblex, firstDue: '2026-03-10', amount: 5500, min: 4000, max: 7000);
      final pay = zorb('2026-03-10', 6900);
      r.importBatch(batch([pay]));
      expect(byId(id).lastPaidTx, pay.id);
    });

    test('paid in parts: 60 + 40 pays; nextDue = old nextDue + interval; the completing row is lastPaidTx', () {
      final id = add(payee: zorblex, firstDue: '2026-03-10', amount: 10000);
      final p1 = zorb('2026-03-05', 6000), p2 = zorb('2026-03-09', 4000);
      r.importBatch(batch([p1]));
      var b = byId(id);
      expect((b.lastPaidTx, b.nextDue), (null, '2026-03-10'), reason: '60 alone leaves the rest set aside');
      r.importBatch(batch([p2]));
      b = byId(id);
      expect(b.lastPaidTx, p2.id);
      expect(b.nextDue, '2026-04-09', reason: 'nextDue + 30, not paying date + 30 (that would be 2026-04-08)');
    });

    test('refresh is idempotent: no new op when nothing changes', () {
      add(payee: zorblex, firstDue: '2026-03-10', amount: 10000);
      r.importBatch(batch([zorb('2026-03-05', 6000), zorb('2026-03-09', 4000)]));
      final ops = r.pendingOps().length;
      r.refreshRecurring('2026-03-15');
      expect(r.pendingOps().length, ops);
    });

    test('an instalment bill finishes after its last payment and is then left alone', () {
      now = DateTime.utc(2026, 5, 20, 12).millisecondsSinceEpoch;
      final id = add(payee: zorblex, firstDue: '2026-03-10', amount: 5000, instalments: 2);
      expect(byId(id).endsOn, '2026-04-10', reason: 'calendar months (lead decision, HIGH 2)');
      r.importBatch(batch([zorb('2026-03-10', 5000)]));
      expect(byId(id).nextDue, '2026-04-09');
      final last = zorb('2026-04-09', 5000);
      r.importBatch(batch([last]));
      var b = byId(id);
      expect((b.nextDue, b.finished, b.lastPaidTx), ('2026-05-09', true, last.id));
      r.importBatch(batch([zorb('2026-05-09', 5000)]));
      b = byId(id);
      expect((b.nextDue, b.lastPaidTx), ('2026-05-09', last.id), reason: 'a finished bill is left alone');
    });

    test('another payee\'s row of the same amount does not pay (never on amount alone)', () {
      final id = add(payee: zorblex, firstDue: '2026-03-10', amount: 5000);
      r.importBatch(batch([n('2026-03-10', -5000, 'POS plaćanje', 'Quorvant Shop 2026')]));
      expect(byId(id).lastPaidTx, isNull);
    });
  });

  group('computePeriod from the repo', () {
    test('a long manual bill is held in full from the day it is added', () {
      final id = add(amount: 60000, interval: 365, firstDue: '2027-01-10', category: 'Shopping');
      final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
      final cz = r.categorizer();
      final p = computePeriod([for (final t in r.transactions()) cz.categorize(t)], st, const [], '2026-03-01',
          bills: r.recurringBills(), table: CategoryTable.builtIn);
      expect(p.reservedBills, 60000);
      expect(p.dueBills.single.id, id);
    });
  });

  group('backup', () {
    test('a manual bill with range and instalments survives a backup round trip with every clock', () async {
      final key = VaultKey.generate();
      add(payee: zorblex, min: 4000, max: 7000, instalments: 5, interval: 14, firstDue: '2026-03-20');
      add(label: 'Rent share', amount: 2000, interval: 91, firstDue: '2026-06-01');
      final file = await backupBytes(r, key);
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, file, key);
      expect(dump(fresh), dump(r));
      final a = fresh.recurringBills().firstWhere((b) => b.payee == zorblex);
      expect((a.minAmount, a.maxAmount, a.endsOn, a.manual, a.intervalDays), (4000, 7000, '2026-05-15', true, 14));
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var clock = 1767225600000;
    final devices = <Device>[];
    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => clock);
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
      tmp = Directory.systemTemp.createTempSync('bw-p4-dev-');
      key = VaultKey.generate();
      net = Net();
      clock = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    String addOn(Device d) => d.repo
        .addRecurring(label: 'Zorblex Club', category: 'Shopping', amount: 5000, intervalDays: 30, firstDue: '2026-03-20', payee: zorblex);

    test('a new bill reaches the other device with all its fields', () async {
      final a = device('a'), b = device('b');
      final id = a.repo.addRecurring(
          label: 'Car insurance',
          category: 'Shopping',
          amount: 5000,
          minAmount: 4000,
          maxAmount: 7000,
          intervalDays: 91,
          firstDue: '2026-06-01',
          instalments: 4);
      await syncAll([a, b]);
      final got = b.repo.recurringBills().singleWhere((x) => x.id == id);
      expect((got.minAmount, got.maxAmount, got.endsOn, got.manual, got.status, got.intervalDays),
          (4000, 7000, '2027-03-01', true, 'confirmed', 91));
      expect(dump(a.repo), dump(b.repo));
    });

    test('two devices edit different fields of the same bill offline: both edits survive', () async {
      final a = device('a'), b = device('b');
      final id = addOn(a);
      await syncAll([a, b]);
      clock += 1000;
      a.repo.updateRecurring(id, amount: 6000);
      clock += 1000;
      b.repo.updateRecurring(id, label: 'Renamed', minAmount: 5000, maxAmount: 8000);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final x = d.repo.recurringBills().single;
        expect((x.expectedAmount, x.label, x.minAmount, x.maxAmount), (6000, 'Renamed', 5000, 8000), reason: d.name);
      }
      expect(dump(a.repo), dump(b.repo));
    });

    test('the same field edited on both: the later edit wins on both devices', () async {
      final a = device('a'), b = device('b');
      final id = addOn(a);
      await syncAll([a, b]);
      clock += 1000;
      a.repo.updateRecurring(id, amount: 6000);
      clock += 1000;
      b.repo.updateRecurring(id, amount: 7000);
      await syncAll([a, b]);
      expect(a.repo.recurringBills().single.expectedAmount, 7000);
      expect(b.repo.recurringBills().single.expectedAmount, 7000);
      expect(dump(a.repo), dump(b.repo));
    });

    test('a payment refresh on one device and an edit on the other merge field by field', () async {
      final a = device('a'), b = device('b');
      final id = addOn(a);
      await syncAll([a, b]);
      clock += 1000;
      final pay = zorb('2026-03-20', 5000);
      a.repo.importBatch(batch([pay]));
      expect(a.repo.recurringBills().single.lastPaidTx, pay.id, reason: 'precondition: paid on a');
      clock += 1000;
      b.repo.updateRecurring(id, label: 'Renamed', minAmount: 4500, maxAmount: 6500, endsOn: '2026-12-31');
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final x = d.repo.recurringBills().single;
        expect((x.lastPaidTx, x.nextDue), (pay.id, '2026-04-19'), reason: '${d.name}: payment kept');
        expect((x.label, x.minAmount, x.maxAmount, x.endsOn), ('Renamed', 4500, 6500, '2026-12-31'), reason: '${d.name}: edit kept');
      }
      expect(dump(a.repo), dump(b.repo));
    });

    test('a delete on one device and an edit on the other converge to the same state', () async {
      final a = device('a'), b = device('b');
      final id = addOn(a);
      await syncAll([a, b]);
      clock += 1000;
      a.repo.deleteRecurring(id);
      clock += 1000;
      b.repo.updateRecurring(id, amount: 6000);
      await syncAll([a, b]);
      expect(dump(a.repo), dump(b.repo));
    });
  });
}
