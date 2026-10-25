// Stage P9 spec tests, repo half: addRecurring(direction: 'in') validation, detection through the repo, schema 13 -> 14,
// backup round trip, two devices (confirm on one, dismiss on the other). Written from docs/context/P9_SPEC.md only. SYNTHETIC data.
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

NormalizedTransaction payout(String date, int cents) => n(date, cents, 'Ostalo', 'Quorvant Payout 2026');

NormalizedTransaction zorb(String date, int cents) => n(date, -cents, 'POS plaćanje', 'Zorblex Club 2026');

final quorvant =
    merchantKey(const Tx(id: 'x', source: 'pbz', date: '2026-01-01', amount: 1, bankType: 'Ostalo', description: 'Quorvant Payout 2026'));

final threeMonths = [payout('2026-01-10', 30000), payout('2026-02-10', 30000), payout('2026-03-10', 30000)];

void main() {
  late WalletRepo r;
  var now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
  setUp(() {
    now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
    r = WalletRepo.inMemory(now: () => now);
  });
  tearDown(() => r.close());

  ImportBatch batch(List<NormalizedTransaction> rows) => ImportBatch(source: 'pbz', transactions: rows);

  String addIn({
    String label = 'Quorvant Payout',
    String category = 'Extra income',
    int amount = 30000,
    int? min,
    int? max,
    int interval = 30,
    String firstDue = '2026-03-20',
    String? payee,
    int? instalments,
    String direction = 'in',
  }) =>
      r.addRecurring(
          label: label,
          category: category,
          amount: amount,
          minAmount: min,
          maxAmount: max,
          intervalDays: interval,
          firstDue: firstDue,
          payee: payee ?? quorvant,
          instalments: instalments,
          direction: direction);

  RecurringBill byId(String id) => r.recurringBills(includeDismissed: true).singleWhere((b) => b.id == id);

  group('schema', () {
    test('schema version is at least 14 and the recurring entity declares a nullable text direction', () {
      expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(14));
      final e = entitySchema['recurring']!;
      expect(e.columnNames, contains('direction'));
      expect(e.column('direction')!.type, ColumnType.text);
      expect(e.column('direction')!.nullable, isTrue);
      expect(entityTables['recurring']!.$2, contains('direction'));
    });

    test('a schema 13 database opens: column added, the old bill is a bill (not income), meta says current', () {
      final tmp = Directory.systemTemp.createTempSync('bw-p9-schema-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/old.db';
      WalletRepo.open(path).close();
      final db = sqlite3.open(path);
      db.execute('ALTER TABLE recurring DROP COLUMN direction');
      db.execute(
          "INSERT INTO recurring(id, payee, label, category, expected_amount, interval_days, next_due, status) VALUES('rec:old', 'old_payee', 'Old', 'Shopping', 2500, 30, '2026-04-01', 'confirmed')");
      db.execute("UPDATE meta SET value = '13' WHERE key = 'schema'");
      db.close();

      final o = WalletRepo.open(path, now: () => now);
      addTearDown(o.close);
      final cols = [for (final c in o.db.select('PRAGMA table_info(recurring)')) c['name']];
      expect(cols, contains('direction'));
      expect(o.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'].toString(), '${WalletRepo.schemaVersion}');
      final b = o.recurringBills().singleWhere((x) => x.id == 'rec:old');
      expect((b.isIncome, b.expectedAmount, b.status), (false, 2500, 'confirmed'));
    });
  });

  group('addRecurring: income', () {
    test('an income is stored confirmed, manual, direction in, with the given fields', () {
      final id = addIn();
      final b = byId(id);
      expect((b.isIncome, b.direction, b.status, b.manual), (true, 'in', 'confirmed', true));
      expect((b.label, b.category, b.expectedAmount, b.intervalDays, b.nextDue, b.payee),
          ('Quorvant Payout', 'Extra income', 30000, 30, '2026-03-20', quorvant));
    });

    test('a range is allowed on an income', () {
      final b = byId(addIn(min: 20000, max: 40000));
      expect((b.minAmount, b.maxAmount, b.hasRange), (20000, 40000, true));
    });

    test('the default direction is a bill and stays a bill', () {
      final id = r.addRecurring(label: 'Zorblex Club', category: 'Shopping', amount: 5000, intervalDays: 30, firstDue: '2026-03-20');
      expect(byId(id).isIncome, isFalse);
    });

    test('a payee is required: missing or blank is refused, nothing written', () {
      final before = r.recurringBills(includeDismissed: true).length;
      expect(
          () => r.addRecurring(
              label: 'Side job', category: 'Extra income', amount: 30000, intervalDays: 30, firstDue: '2026-03-20', direction: 'in'),
          throwsArgumentError);
      expect(
          () => r.addRecurring(
              label: 'Side job',
              category: 'Extra income',
              amount: 30000,
              intervalDays: 30,
              firstDue: '2026-03-20',
              payee: '   ',
              direction: 'in'),
          throwsArgumentError);
      expect(r.recurringBills(includeDismissed: true), hasLength(before));
    });

    test('the category must be of kind extra: a flex, a fixed and a transfer category are refused', () {
      for (final c in ['Shopping', 'Rent', 'Groceries', 'Internal transfer']) {
        expect(() => addIn(category: c), throwsArgumentError, reason: c);
      }
    });

    test('a salary-kind category is refused with the spec text', () {
      expect(() => addIn(category: 'Salary'),
          throwsA(isA<ArgumentError>().having((e) => e.message.toString(), 'message', contains('This tag already counts as salary.'))));
    });

    test('an unknown category is refused', () {
      expect(() => addIn(category: 'No such category'), throwsArgumentError);
    });

    test('instalments are refused for an income', () {
      expect(() => addIn(instalments: 3), throwsArgumentError);
      expect(() => addIn(instalments: 1), throwsArgumentError);
    });

    test('an unknown direction is refused', () {
      expect(() => addIn(direction: 'sideways'), throwsArgumentError);
    });

    test('the other validation still applies: amount, range, interval, label, date', () {
      expect(() => addIn(amount: 0), throwsArgumentError);
      expect(() => addIn(amount: -5), throwsArgumentError);
      expect(() => addIn(min: 40000, max: 20000), throwsArgumentError);
      expect(() => addIn(min: 20000, max: 40000, amount: 50000), throwsArgumentError);
      expect(() => addIn(interval: 0), throwsArgumentError);
      expect(() => addIn(label: ''), throwsArgumentError);
      expect(() => addIn(firstDue: 'tomorrow'), throwsArgumentError);
    });

    test('an income and a bill may share a payee (their ids differ)', () {
      final bill =
          r.addRecurring(label: 'Quorvant', category: 'Shopping', amount: 2000, intervalDays: 30, firstDue: '2026-03-21', payee: quorvant);
      final inc = addIn();
      expect(inc, isNot(bill));
      expect(byId(bill).isIncome, isFalse);
      expect(byId(inc).isIncome, isTrue);
    });

    test('it syncs as a recurring op carrying direction in', () {
      final id = addIn();
      final op = r.pendingOps().map((o) => o.$2).lastWhere((o) => o.entity == 'recurring' && o.id == id);
      expect(op.fields['direction'], 'in');
      expect(op.fields['status'], 'confirmed');
    });

    test('updateRecurring keeps the direction', () {
      final id = addIn();
      r.updateRecurring(id, label: 'Side job', amount: 35000, nextDue: '2026-03-25');
      final b = byId(id);
      expect((b.isIncome, b.direction, b.label, b.expectedAmount, b.nextDue), (true, 'in', 'Side job', 35000, '2026-03-25'));
    });

    test('confirm, dismiss and delete work on an income as on a bill', () {
      final id = addIn();
      r.dismissRecurring(id);
      expect(byId(id).status, 'dismissed');
      r.confirmRecurring(id);
      expect(byId(id).status, 'confirmed');
      r.deleteRecurring(id);
      expect(r.recurringBills(includeDismissed: true).where((b) => b.id == id), isEmpty);
    });
  });

  group('detection and landing through the repo', () {
    test('three monthly inflows make an income candidate recin:<payee>, not a bill', () {
      r.importBatch(batch(threeMonths));
      final c = r.recurringBills().singleWhere((b) => b.id == 'recin:$quorvant');
      expect((c.isIncome, c.status, c.expectedAmount, c.nextDue), (true, 'candidate', 30000, '2026-04-09'));
      expect(r.recurringBills().where((b) => b.id == 'rec:$quorvant'), isEmpty);
    });

    test('a salary row is never an income candidate', () {
      r.importBatch(batch([
        n('2026-01-10', 150000, 'Plaća/Mirovina', 'Neto plaća za 12/2025'),
        n('2026-02-10', 150000, 'Plaća/Mirovina', 'Neto plaća za 01/2026'),
        n('2026-03-10', 150000, 'Plaća/Mirovina', 'Neto plaća za 02/2026'),
      ]));
      expect(r.recurringBills().where((b) => b.isIncome), isEmpty);
    });

    test('a dismissed income candidate is not added again by the next import', () {
      r.importBatch(batch(threeMonths));
      r.dismissRecurring('recin:$quorvant');
      r.importBatch(batch([payout('2026-03-11', 100)]));
      r.refreshRecurring('2026-03-15');
      expect(byId('recin:$quorvant').status, 'dismissed');
      expect(r.recurringBills().where((b) => b.id == 'recin:$quorvant'), isEmpty);
    });

    test('a confirmed income moves its nextDue on when the money lands', () {
      r.importBatch(batch(threeMonths));
      r.confirmRecurring('recin:$quorvant');
      now = DateTime.utc(2026, 4, 10, 12).millisecondsSinceEpoch;
      r.importBatch(batch([payout('2026-04-09', 30500)]));
      final b = byId('recin:$quorvant');
      expect(b.nextDue, '2026-05-09');
      expect(b.lastPaidTx, isNotNull);
      expect(b.expectedAmount, 30000);
    });

    test('a payee with a bill and an income keeps both candidates', () {
      r.importBatch(batch([
        zorb('2026-01-10', 2000),
        zorb('2026-02-10', 2000),
        zorb('2026-03-10', 2000),
        n('2026-01-12', 45000, 'Ostalo', 'Zorblex Club 2026'),
        n('2026-02-12', 45000, 'Ostalo', 'Zorblex Club 2026'),
        n('2026-03-12', 45000, 'Ostalo', 'Zorblex Club 2026'),
      ]));
      final ids = r.recurringBills().map((b) => b.id).toSet();
      expect(ids, containsAll(['rec:zorblex_club', 'recin:zorblex_club']));
      expect(byId('rec:zorblex_club').isIncome, isFalse);
      expect(byId('recin:zorblex_club').isIncome, isTrue);
    });
  });

  group('backup', () {
    test('an income survives a backup round trip with its direction and every clock', () async {
      final key = VaultKey.generate();
      addIn(min: 20000, max: 40000);
      r.addRecurring(label: 'Rent share', category: 'Shopping', amount: 2000, intervalDays: 91, firstDue: '2026-06-01');
      final file = await backupBytes(r, key);
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, file, key);
      expect(dump(fresh), dump(r));
      final inc = fresh.recurringBills().singleWhere((b) => b.payee == quorvant);
      expect((inc.isIncome, inc.direction, inc.minAmount, inc.maxAmount), (true, 'in', 20000, 40000));
      expect(fresh.recurringBills().singleWhere((b) => b.label == 'Rent share').isIncome, isFalse);
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
      tmp = Directory.systemTemp.createTempSync('bw-p9-dev-');
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

    String statusOf(Device d, String id) => d.repo.recurringBills(includeDismissed: true).singleWhere((b) => b.id == id).status;

    test('a manual income reaches the other device with its direction', () async {
      final a = device('a'), b = device('b');
      final id = a.repo.addRecurring(
          label: 'Side job',
          category: 'Extra income',
          amount: 30000,
          minAmount: 20000,
          maxAmount: 40000,
          intervalDays: 30,
          firstDue: '2026-03-20',
          payee: 'side_job',
          direction: 'in');
      await syncAll([a, b]);
      final got = b.repo.recurringBills().singleWhere((x) => x.id == id);
      expect((got.isIncome, got.direction, got.status, got.minAmount, got.maxAmount), (true, 'in', 'confirmed', 20000, 40000));
      expect(dump(a.repo), dump(b.repo));
    });

    test('confirm on A and dismiss on B (later): both end up dismissed', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(ImportBatch(source: 'pbz', transactions: threeMonths));
      await syncAll([a, b]);
      final id = 'recin:$quorvant';
      expect(statusOf(b, id), 'candidate');
      clock += 60000;
      a.repo.confirmRecurring(id);
      clock += 60000;
      b.repo.dismissRecurring(id);
      await syncAll([a, b]);
      expect(statusOf(a, id), 'dismissed');
      expect(statusOf(b, id), 'dismissed');
      expect(dump(a.repo), dump(b.repo));
    });

    test('dismiss on B and confirm on A (later): both end up confirmed', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(ImportBatch(source: 'pbz', transactions: threeMonths));
      await syncAll([a, b]);
      final id = 'recin:$quorvant';
      clock += 60000;
      b.repo.dismissRecurring(id);
      clock += 60000;
      a.repo.confirmRecurring(id);
      await syncAll([a, b]);
      expect(statusOf(a, id), 'confirmed');
      expect(statusOf(b, id), 'confirmed');
      expect(dump(a.repo), dump(b.repo));
    });

    test('both devices detect the same candidate id from the same rows (one row after sync)', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(ImportBatch(source: 'pbz', transactions: threeMonths));
      b.repo.importBatch(ImportBatch(source: 'pbz', transactions: threeMonths));
      await syncAll([a, b]);
      expect(a.repo.recurringBills().where((x) => x.isIncome), hasLength(1));
      expect(dump(a.repo), dump(b.repo));
    });
  });
}
