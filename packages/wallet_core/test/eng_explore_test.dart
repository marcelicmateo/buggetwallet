// ENG core 2: the Explore query (ENG_UI_SPEC §6.3): runQuery equals the Insights series, long windows, `together`,
// moveTogether, heatmap levels and the synced `view` entity (patch, two devices, backup, a schema-20 build). SYNTHETIC data.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/src/insights.dart' show merchantGroupKey;
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/n3.dart';
import 'support/sim.dart';

const today = '2026-10-31';
const _t = Timeout(Duration(seconds: 60));
DateRange dr(String a, String b) => DateRange(start: a, end: b);
SeriesQuery q(Measure m, List<SeriesKey> keys, Bucket b, DateRange w) => SeriesQuery(measure: m, keys: keys, bucket: b, window: w);
CategorizedTx tagged(CategorizedTx t, List<String> tags) => CategorizedTx(t.tx, t.category, t.kind, tags: tags);
String yearMonth(int i) => '${2016 + i ~/ 12}-${(i % 12 + 1).toString().padLeft(2, '0')}';

void main() {
  // bigWalletRows: the built-in rules put every card payment in 'Bills & one-offs'.
  group('equals the Insights series', () {
    final rows = [
      for (final (i, t) in bigWalletRows(today, days: 700, perDay: 6).indexed) i % 5 == 0 ? tagged(t, ['trip']) : t,
    ];
    final ix = DayIndex(rows, currency: 'EUR');
    final w = dr('2025-01-01', '2026-10-31');

    test('main tag = spendingSeries(category) = spendingByMonth of its rows', () {
      const k = SeriesKey(SeriesKind.mainTag, 'Bills & one-offs');
      final res = runQuery(ix, q(Measure.spent, [k], Bucket.month, w), today: today);
      final ref = spendingByMonth(rows.where((t) => t.category == 'Bills & one-offs').toList(), w, currency: 'EUR', today: today);
      expect([for (final r in res) r.cents[k]], [for (final m in ref) m.spent]);
      expect([for (final r in res) r.partial], [for (final m in ref) m.partial]);
    });

    test('tag = tagTrend, payee = merchantTrend', () {
      const tag = SeriesKey(SeriesKind.tag, 'trip');
      final payee = merchantGroupKey(rows.firstWhere((t) => t.category == 'Bills & one-offs').tx);
      final cats = {
        for (final t in rows)
          if (merchantGroupKey(t.tx) == payee) t.category
      };
      expect(cats, hasLength(1), reason: 'the payee lives in one main tag, so merchantTrend is its whole spending');
      final pk = SeriesKey(SeriesKind.payee, payee);
      final res = runQuery(ix, q(Measure.spent, [tag, pk], Bucket.month, w), today: today);
      expect([for (final r in res) r.cents[tag]], [for (final m in tagTrend('trip', rows, w, today: today, currency: 'EUR')) m.spent]);
      expect([for (final r in res) r.cents[pk]],
          [for (final m in merchantTrend(cats.single, payee, rows, w, currency: 'EUR', today: today)) m.spent]);
    });

    test('cameIn and kept = monthSummary income and net; count = payments out', () {
      final keys = [
        for (final c in ['Salary', 'Bills & one-offs']) SeriesKey(SeriesKind.mainTag, c)
      ];
      final inc = runQuery(ix, q(Measure.cameIn, keys, Bucket.month, w), today: today);
      final kept = runQuery(ix, q(Measure.kept, keys, Bucket.month, w), today: today);
      final count = runQuery(ix, q(Measure.count, keys, Bucket.month, w), today: today);
      for (var i = 0; i < inc.length; i++) {
        final m = inc[i].bucket.start.substring(0, 7);
        final s = monthSummary(rows.where((t) => t.category == 'Salary' || t.category == 'Bills & one-offs').toList(), m, currency: 'EUR');
        expect(inc[i].together, s.income, reason: m);
        expect(kept[i].together, s.net, reason: m);
        final n = rows.where((t) => t.category == 'Bills & one-offs' && t.date.startsWith(m) && t.amount < 0).length;
        expect(count[i].cents[keys[1]], n, reason: m);
        expect(count[i].cents[keys[0]], 0, reason: 'income is no payment out');
      }
    });
  });

  group('long windows', () {
    // One payment on the 15th of every month, 2016-01 .. 2026-10: 130 months, cents = month number + 1.
    final rows = [for (var i = 0; i < 130; i++) row('${yearMonth(i)}-15', -(i + 1), 'Groceries')];
    final ix = DayIndex(rows, currency: 'EUR');
    const k = SeriesKey(SeriesKind.mainTag, 'Groceries');
    final all = dr('2016-01-01', today);

    test('year buckets over 11 years sum the months exactly', () {
      final res = runQuery(ix, q(Measure.spent, [k], Bucket.year, all), today: today);
      expect([for (final r in res) r.bucket.start], [for (var y = 2016; y <= 2026; y++) '$y-01-01']);
      for (var y = 0; y < 11; y++) {
        var sum = 0;
        for (var m = 0; m < 12 && y * 12 + m < 130; m++) {
          sum += y * 12 + m + 1;
        }
        expect(res[y].cents[k], sum, reason: '${2016 + y}');
      }
      expect([for (final r in res) r.partial], [...List.filled(10, false), true]);
      expect(bucketLabel(res.last.bucket, Bucket.year), '2026');
    });

    test('quarter buckets over 11 years: 44 aligned quarters, total = every payment', () {
      final res = runQuery(ix, q(Measure.spent, [k], Bucket.quarter, all), today: today);
      expect(res, hasLength(44));
      expect(res.fold<int>(0, (s, r) => s + r.cents[k]!), 130 * 131 ~/ 2);
      expect(res[1].bucket.start, '2016-04-01');
      expect(res[1].cents[k], 4 + 5 + 6);
    });

    test('day, week and month buckets keep the 5-year cap', () {
      for (final b in [Bucket.day, Bucket.week, Bucket.month]) {
        expect(() => runQuery(ix, q(Measure.spent, [k], b, all), today: today), throwsArgumentError, reason: b.name);
      }
      expect(bucketsOf(dr('2021-11-01', '2026-10-31'), Bucket.month), hasLength(60));
      expect(() => spendingSeries(ix, dr('2021-11-01', '2026-11-01'), Bucket.month, today: today), throwsArgumentError);
    });

    test('bucketFor goes on to years once quarters exceed maxBars', () {
      expect(bucketFor(dr('2017-01-01', today)), Bucket.quarter); // 40 quarters
      expect(bucketFor(dr('2016-01-01', today)), Bucket.year); // 44 quarters
      expect(bucketFor(dr('2021-11-01', today), maxBars: 12), Bucket.year);
    });
  });

  test('together counts a row carrying two tags once, for every measure', () {
    const a = SeriesKey(SeriesKind.tag, 'trip'), b = SeriesKey(SeriesKind.tag, 'gift'), c = SeriesKey(SeriesKind.mainTag, 'Shopping');
    final rows = [
      tagged(row('2026-05-04', -1000, 'Shopping'), ['trip', 'gift']),
      tagged(row('2026-05-05', -500, 'Eating out'), ['trip']),
      tagged(row('2026-05-06', 200, 'Shopping'), ['gift']), // refund
      tagged(row('2026-05-07', 30000, 'Salary'), ['trip']),
    ];
    final ix = DayIndex(rows, currency: 'EUR');
    final w = dr('2026-05-01', '2026-05-31');
    QueryRow run(Measure m) => runQuery(ix, q(m, [a, b, c], Bucket.month, w), today: today).single;
    expect(run(Measure.spent).cents, {a: 1500, b: 800, c: 800});
    expect(run(Measure.spent).together, 1300);
    expect(run(Measure.count).together, 2);
    expect(run(Measure.cameIn).together, 30000);
    expect(run(Measure.kept).together, 30000 - 1300);
    expect(runQuery(ix, q(Measure.spent, const [], Bucket.month, w), today: today).single.together, 0);
  });

  test('account series follow RowAccounts: a main account counts its rows without tx.account, as its balance does', () {
    Account acc(String id, String source, {String? matchKey}) => Account(
        id: id, name: 'A $id', source: source, currency: 'EUR', opening: 0, openingDate: '2025-12-31', deleted: false, matchKey: matchKey);
    CategorizedTx on(String date, int cents, String category, String account) {
      final t = Tx(id: 'k-$date-$cents', source: 'pbz', date: date, amount: cents, description: 'POS SYNTH', account: account);
      return CategorizedTx(t, category, BudgetKind.flex);
    }

    final accounts = [acc('main', 'pbz'), acc('keyed', 'pbz', matchKey: 'ak:0000000000000001'), acc('rev', 'revolut')];
    final rows = [
      row('2026-01-10', 200000, 'Salary'),
      row('2026-01-12', -4500, 'Groceries'),
      row('2026-02-03', 1200, 'Groceries'), // refund
      row('2026-03-20', -9900, 'Shopping'),
      on('2026-02-14', -7000, 'Shopping', 'keyed'),
      row('2026-02-15', -3000, 'Groceries', source: 'revolut'),
      row('2026-07-01', -100, 'Groceries'), // after the window
    ];
    final w = dr('2026-01-01', '2026-06-30');
    const main = SeriesKey(SeriesKind.account, 'main'), keyed = SeriesKey(SeriesKind.account, 'keyed');
    final ix = DayIndex(rows, currency: 'EUR', accounts: accounts);
    final res = runQuery(ix, q(Measure.kept, [main, keyed], Bucket.quarter, w), today: today);
    int balanceOn(String id, String day) => accountBalances(accounts, [
          for (final t in rows)
            if (t.date.compareTo(day) <= 0) t.tx
        ]).firstWhere((b) => b.account.id == id).balance;
    for (final (k, id) in [(main, 'main'), (keyed, 'keyed')]) {
      expect(res.fold<int>(0, (s, r) => s + r.cents[k]!), balanceOn(id, w.end) - balanceOn(id, '2025-12-31'), reason: id);
    }
    expect(res.first.cents[main], 200000 - 4500 + 1200 - 9900);
    expect(
        runQuery(ix, q(Measure.spent, [const SeriesKey(SeriesKind.account, 'rev')], Bucket.quarter, w), today: today)
            .first
            .cents
            .values
            .single,
        3000);
    // Without the accounts only a stored tx.account counts (the main account's rows have none).
    expect(runQuery(DayIndex(rows, currency: 'EUR'), q(Measure.kept, [main], Bucket.quarter, w), today: today).first.cents[main], 0);
  });

  group('moveTogether', () {
    const a = SeriesKey(SeriesKind.mainTag, 'Groceries'), b = SeriesKey(SeriesKind.mainTag, 'Eating out');
    DayIndex ix(List<int> xs, List<int> ys) => DayIndex([
          for (var i = 0; i < xs.length; i++) ...[
            if (xs[i] != 0) row('${yearMonth(i)}-10', -xs[i], 'Groceries'),
            if (ys[i] != 0) row('${yearMonth(i)}-12', -ys[i], 'Eating out'),
          ]
        ], currency: 'EUR');
    final w = dr('2016-01-01', '2026-10-31'); // longer than 5 years: no cap

    test('exact r in permille, both signs', () {
      expect(moveTogether(ix([100, 200, 300], [200, 400, 600]), a, b, w)!.strength, 1000);
      expect(moveTogether(ix([100, 200, 300], [600, 400, 200]), a, b, w)!.strength, -1000);
      final m = moveTogether(ix([100, 200, 300, 400], [100, 300, 200, 400]), a, b, w)!; // r = 0.8
      expect((m.strength, m.months, m.from, m.to), (800, 4, '2016-01-01', '2016-04-30'));
    });

    test('only months where both spent; flat or too few is null', () {
      final m = moveTogether(ix([100, 0, 200, 300], [200, 999, 400, 600]), a, b, w)!;
      expect((m.strength, m.months), (1000, 3));
      expect(moveTogether(ix([100, 100, 100], [1, 2, 3]), a, b, w), isNull);
      expect(moveTogether(ix([100], [100]), a, b, w), isNull);
      expect(moveTogether(ix([], []), a, b, w), isNull);
    });
  });

  test('heatmap: tied cells share a level, net refunds are 0, cells run to today', () {
    const k = SeriesKey(SeriesKind.mainTag, 'Groceries');
    final rows = [
      row('2025-01-05', -500, 'Groceries'),
      row('2025-02-05', -500, 'Groceries'),
      row('2025-03-05', -900, 'Groceries'),
      row('2025-04-05', 300, 'Groceries'),
    ];
    final cs = heatmap(DayIndex(rows, currency: 'EUR'), k, today: today);
    expect(cs, hasLength(12 + 10));
    expect((cs.last.year, cs.last.month), (2026, 10));
    expect([for (final c in cs.take(4)) (c.cents, c.level)], [(500, 1), (500, 1), (900, 3), (-300, 0)]);
    expect(heatmap(DayIndex(const [], currency: 'EUR'), k, today: today), isEmpty);
  });

  group('saved views', () {
    final json = jsonEncode(q(Measure.kept, [const SeriesKey(SeriesKind.payee, 'lidl')], Bucket.year, dr('2016-01-01', today)).toJson());
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = DateTime.utc(2026, 10, 1, 9).millisecondsSinceEpoch;
    final devices = <Device>[];
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-views-');
      key = VaultKey.generate();
      net = Net();
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });
    Device dev(String name, {bool file = false}) {
      final d = Device(name, file ? tmp : null, key, () => now, dbPath: file ? '${tmp.path}/$name.db' : null, net: net);
      devices.add(d);
      return d;
    }

    test('order, generic patch with checks, parsed query', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final a = r.addView(name: '  Food ', query: json), b = r.addView(name: 'Trips', query: json);
      expect([for (final v in r.views()) (v.name, v.sort, v.pinned)], [('Food', 0, false), ('Trips', 1, false)]);
      r.patch(ViewCols.entity, b, {ViewCols.sort: -1, ViewCols.pinned: true});
      expect([for (final v in r.views()) v.id], [b, a]);
      expect(r.views().first.parsed!.bucket, Bucket.year);
      expect(() => r.patch(ViewCols.entity, a, {ViewCols.query: '{"measure":"spent"}'}), throwsArgumentError);
      expect(() => r.patch(ViewCols.entity, a, {ViewCols.deleted: true}), throwsArgumentError);
      expect(() => r.patchView(a, name: '   '), throwsArgumentError);
      expect(() => r.addView(name: 'x' * 61, query: json), throwsArgumentError);
      r.deleteView(a);
      expect(() => r.patchView(a, pinned: true), throwsArgumentError, reason: 'a deleted view is not edited');
      expect(() => r.deleteView('nope'), throwsArgumentError);
      expect(const SavedView(id: 'v', name: 'n', query: '{"measure":"later"}', pinned: false).parsed, isNull);
    });

    test('two devices: add, rename, pin, delete and undo converge', () async {
      final one = dev('one'), two = dev('two');
      final id = one.repo.addView(name: 'Food', query: json);
      now += 1000;
      await one.run();
      await two.run();
      expect(two.repo.views().single.name, 'Food');
      two.repo.patchView(id, pinned: true);
      now += 1000;
      one.repo.patchView(id, name: 'Groceries');
      now += 1000;
      await one.run();
      await two.run();
      await one.run();
      for (final d in [one, two]) {
        expect([for (final v in d.repo.views()) (v.name, v.pinned)], [('Groceries', true)], reason: d.name);
      }
      one.repo.deleteView(id);
      now += 1000;
      await one.run();
      await two.run();
      expect(two.repo.views(), isEmpty);
      two.repo.undeleteView(id);
      now += 1000;
      await two.run();
      await one.run();
      expect(one.repo.views().single.name, 'Groceries');
      expect(dump(one.repo, clocks: false), dump(two.repo, clocks: false));
    }, timeout: _t);

    test('backup round trip keeps views, deleted ones included', () async {
      final r = WalletRepo.inMemory(), fresh = WalletRepo.inMemory();
      addTearDown(r.close);
      addTearDown(fresh.close);
      final a = r.addView(name: 'Food', query: json);
      r.addView(name: 'Gone', query: json);
      r.deleteView(r.views().last.id);
      r.patchView(a, pinned: true);
      await restoreBackupBytes(fresh, await backupBytes(r, key), key);
      expect([for (final v in fresh.views()) (v.id, v.name, v.pinned, v.query)], [(a, 'Food', true, json)]);
      expect(dump(fresh, clocks: false)['views'], dump(r, clocks: false)['views']);
    }, timeout: _t);

    test('a schema-20 build skips view ops; after its upgrade they replay', () async {
      final neu = dev('new'), old = dev('old', file: true);
      old.repo.db.execute("UPDATE meta SET value = '20' WHERE key = 'schema'");
      final reader = _Schema20Reader(old.relay, key);
      neu.repo.addView(name: 'Food', query: json);
      now += 1000;
      await neu.run();
      final report = await SyncEngine(reader, key).run(old.repo);
      expect(report.problems, isEmpty);
      expect(reader.renamed, 1);
      expect(old.repo.views(), isEmpty);
      old.reopen(); // 20 -> 21 clears the cursors
      now += 1000;
      await old.run();
      expect(old.repo.views().single.name, 'Food');
      expect(dump(old.repo, clocks: false), dump(neu.repo, clocks: false));
    }, timeout: _t);
  });

  test('perf: "All" over 10 years, quarter buckets, 4 keys, under ~50 ms', () {
    final rows = bigWalletRows(today, days: 3650);
    final ix = DayIndex(rows, currency: 'EUR');
    final payee = merchantGroupKey(rows.firstWhere((t) => t.category == 'Bills & one-offs').tx);
    final keys = [
      const SeriesKey(SeriesKind.mainTag, 'Bills & one-offs'),
      const SeriesKey(SeriesKind.mainTag, 'Rent'),
      SeriesKey(SeriesKind.payee, payee),
      const SeriesKey(SeriesKind.tag, 'none'),
    ];
    final sw = Stopwatch()..start();
    final res = runQuery(ix, q(Measure.spent, keys, Bucket.quarter, dr(ix.first!, today)), today: today);
    sw.stop();
    expect(res, hasLength(41));
    // ignore: avoid_print
    print('runQuery all/quarter/4 keys: ${rows.length} rows, ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsedMilliseconds, lessThan(100), reason: 'loose bound for a shared laptop; about 16 ms here');
  });
}

/// What a schema-20 build sees of the relay: `view` is a name it does not know (the real unknown-entity path).
class _Schema20Reader implements SyncTransport {
  final SyncTransport inner;
  final VaultKey key;
  int renamed = 0;
  _Schema20Reader(this.inner, this.key);

  Future<List<int>> _rewrite(List<int> bytes, List<int> aad) async {
    final j = jsonDecode(utf8.decode(await unseal(bytes, key, aad: aad)));
    final ops = (j is Map ? j['ops'] : j) as List;
    final out = [
      for (final o in ops.cast<Map<String, Object?>>())
        if (o['e'] == 'view') {...o, 'e': 'view~v21'} else o
    ];
    final n = out.where((o) => o['e'] == 'view~v21').length;
    if (n == 0) return bytes;
    renamed += n;
    return seal(utf8.encode(jsonEncode(j is Map ? {...j, 'ops': out} : out)), key, aad: aad);
  }

  @override
  Future<List<int>> get(String device, int seq) async => _rewrite(await inner.get(device, seq), aadSyncFile(device, seq));
  @override
  Future<List<int>> getSnapshot(String id) async => _rewrite(await inner.getSnapshot(id), aadSnapshot(id));
  @override
  Future<RelayState> state() => inner.state();
  @override
  Future<void> put(String device, int seq, List<int> bytes) => inner.put(device, seq, bytes);
  @override
  Future<void> ack(String device, Map<String, int> cursors) => inner.ack(device, cursors);
  @override
  Future<void> putSnapshot(String id, Map<String, int> covers, List<int> bytes) => inner.putSnapshot(id, covers, bytes);
  @override
  Future<void> putBlob(String hash, List<int> bytes) => inner.putBlob(hash, bytes);
  @override
  Future<List<int>?> getBlob(String hash) => inner.getBlob(hash);
  @override
  Future<void> putSnapshotBlobs(String id, List<String> hashes) => inner.putSnapshotBlobs(id, hashes);
}
