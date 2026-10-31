// V3 (schema 18): the weekly-review streak is read from dated `review` rows, so two devices that finish reviews on
// different days before syncing keep both days. The legacy `lastReview` / `reviewStreak` settings stay the base the
// rows continue and are never written again. All data is SYNTHETIC.
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 60));

void main() {
  group('reviewStreak (pure)', () {
    test('no dates: 0, or the legacy streak when a legacy last review is set', () {
      expect(reviewStreak(const []), 0);
      expect(reviewStreak(const [], legacyStreak: 5), 0, reason: 'a streak without its date is no base');
      expect(reviewStreak(const [], legacyLast: '2026-03-01', legacyStreak: 5), 5);
      expect(reviewStreak(const [], legacyLast: '2026-03-01'), 0);
    });

    test('one date: 1; a gap of 13 days continues, 14 restarts', () {
      expect(reviewStreak(['2026-03-01']), 1);
      expect(reviewStreak(['2026-03-01', '2026-03-14']), 2);
      expect(reviewStreak(['2026-03-01', '2026-03-15']), 1);
      expect(reviewStreak(['2026-03-01', '2026-03-08', '2026-03-15', '2026-03-22', '2026-03-29']), 5);
      // Only the chain ending at the newest date counts.
      expect(reviewStreak(['2026-01-04', '2026-01-11', '2026-01-18', '2026-03-01', '2026-03-08']), 2);
    });

    test('unsorted, duplicate and non-date input is ignored', () {
      expect(reviewStreak(['2026-03-15', '2026-03-01', '2026-03-08', '2026-03-08']), 3);
      expect(reviewStreak(['2026-03-08', '2026-02-30', 'x', '', '2026-03-01']), 2);
      expect(reviewStreak(['x']), 0);
    });

    test('the legacy base joins the chain: same day (counted once), within 13 days, not at 14', () {
      const dates = ['2026-03-01', '2026-03-08'];
      expect(reviewStreak(dates, legacyLast: '2026-03-01', legacyStreak: 4), 5, reason: 'same day: 1 + 4');
      expect(reviewStreak(dates, legacyLast: '2026-02-22', legacyStreak: 4), 6, reason: '7 days before: 2 + 4');
      expect(reviewStreak(dates, legacyLast: '2026-02-16', legacyStreak: 4), 6, reason: '13 days before: 2 + 4');
      expect(reviewStreak(dates, legacyLast: '2026-02-15', legacyStreak: 4), 2, reason: '14 days before: no join');
      expect(reviewStreak(['2026-01-04', '2026-03-01'], legacyLast: '2026-01-04', legacyStreak: 9), 1, reason: 'chain broken before it');
      expect(reviewStreak(dates, legacyLast: '2026-02-30', legacyStreak: 4), 2, reason: 'a bad legacy date is no base');
    });

    test('a legacy review newer than some rows (an older build kept counting): rows after it + its streak', () {
      expect(reviewStreak(['2026-03-01', '2026-03-15'], legacyLast: '2026-03-08', legacyStreak: 6), 7);
      expect(reviewStreak(['2026-03-01'], legacyLast: '2026-03-08', legacyStreak: 6), 6, reason: 'legacy is the newest');
      expect(reviewStreak(['2026-03-01'], legacyLast: '2026-03-22', legacyStreak: 6), 6, reason: 'legacy newest, rows too old');
    });

    test('clamped to 0 .. maxStreak', () {
      expect(reviewStreak(['2026-03-08'], legacyLast: '2026-03-01', legacyStreak: WalletSettings.maxStreak), WalletSettings.maxStreak);
      expect(reviewStreak(const [], legacyLast: '2026-03-01', legacyStreak: -3), 0);
    });
  });

  group('repo', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    int streak() => reviewStreak(r.reviewDates(), legacyLast: r.settings().lastReview, legacyStreak: r.settings().reviewStreak);

    test('markReviewDone writes one review row (id = date), no setting; the same day again writes nothing', () {
      final before = r.pendingOps().length;
      r.markReviewDone('2026-03-01');
      final ops = [for (final (_, op) in r.pendingOps().skip(before)) op];
      expect([for (final o in ops) (o.entity, o.id)], [('review', '2026-03-01')]);
      expect(ops.single.fields, {'done': '2026-03-01', 'deleted': 0});
      r.markReviewDone('2026-03-01');
      expect(r.pendingOps(), hasLength(before + 1));
      expect(r.reviewDates(), ['2026-03-01']);
      expect(() => r.markReviewDone('2026-02-30'), throwsArgumentError);
      expect(r.reviewDates(), ['2026-03-01']);
    });

    test('reviewDates is ascending whatever the order of writing', () {
      r.markReviewDone('2026-03-15');
      r.markReviewDone('2026-03-01');
      r.markReviewDone('2026-03-08');
      expect(r.reviewDates(), ['2026-03-01', '2026-03-08', '2026-03-15']);
      expect(streak(), 3);
    });

    test('legacy settings are the base the rows continue, and are never written again', () {
      r.updateSettings({'lastReview': '2026-03-01', 'reviewStreak': 7}); // as an older build left them
      r.markReviewDone('2026-03-08');
      expect((r.settings().lastReview, r.settings().reviewStreak), ('2026-03-01', 7));
      expect(streak(), 8);
      r.markReviewDone('2026-03-29'); // 21 days: restarts
      expect(streak(), 1);
      expect((r.settings().lastReview, r.settings().reviewStreak), ('2026-03-01', 7));
    });

    test('a damaged remote review row (done is not a date) is skipped', () {
      r.applyRemote([
        const Op('review', 'junk', {'done': 'not a date', 'deleted': 0}, '001768035600000:00001:peer0001'),
        const Op('review', '2026-03-01', {'done': '2026-03-01', 'deleted': 0}, '001768035600000:00002:peer0001'),
        const Op('review', '2026-03-08', {'done': '2026-03-08', 'deleted': 1}, '001768035600000:00003:peer0001'),
      ]);
      expect(r.reviewDates(), ['2026-03-01'], reason: 'junk skipped, deleted row not live');
    });

    test('a live review row of today with a damaged done value is written again', () {
      r.db.execute("INSERT INTO reviews(id, done, deleted) VALUES('2026-03-01', 'not a date', 0)");
      expect(r.reviewDates(), isEmpty);
      final before = r.pendingOps().length;
      r.markReviewDone('2026-03-01');
      expect(r.pendingOps(), hasLength(before + 1));
      expect(r.reviewDates(), ['2026-03-01']);
      r.markReviewDone('2026-03-01');
      expect(r.pendingOps(), hasLength(before + 1), reason: 'repaired: the next call is a no-op');
    });

    test('a deleted review row of today is written live again', () {
      r.applyRemote([
        const Op('review', '2026-03-01', {'done': '2026-03-01', 'deleted': 1}, '001768035600000:00001:peer0001')
      ]);
      r.markReviewDone('2026-03-01');
      expect(r.reviewDates(), ['2026-03-01']);
    });

    test('recent changes label a review with its date', () {
      r.markReviewDone('2026-03-01');
      final e = r.recentChanges().firstWhere((c) => c.entity == 'review');
      expect((e.id, e.label), ('2026-03-01', '2026-03-01'));
    });

    test('reviewState: due and next from the newest of the rows and the legacy date; streak from the rows', () {
      final legacy = WalletSettings.fromMap({'lastReview': '2026-03-01', 'reviewStreak': 3}); // 2026-03-01 is a Sunday
      // Rows newer than the legacy date: the next review is the Sunday after the newest row.
      final s = reviewState(const [], legacy, const [], const {}, today: '2026-03-10', reviewDates: const ['2026-03-08']);
      expect((s.due, s.nextReviewDate, s.streak), (false, '2026-03-15', 4));
      // The legacy date newer than the rows (an older build reviewed later).
      final later = WalletSettings.fromMap({'lastReview': '2026-03-15', 'reviewStreak': 2});
      final s2 = reviewState(const [], later, const [], const {}, today: '2026-03-16', reviewDates: const ['2026-03-08']);
      expect((s2.due, s2.nextReviewDate, s2.streak), (false, '2026-03-22', 2));
      // Rows only.
      final none = WalletSettings.fromMap({});
      final s3 = reviewState(const [], none, const [], const {}, today: '2026-03-15', reviewDates: const ['2026-03-01', '2026-03-08']);
      expect((s3.due, s3.nextReviewDate, s3.streak), (true, '2026-03-15', 2));
      // Default: no rows, the legacy settings as before.
      final s4 = reviewState(const [], legacy, const [], const {}, today: '2026-03-02');
      expect((s4.due, s4.nextReviewDate, s4.streak), (false, '2026-03-08', 3));
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
    final devices = <Device>[];

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now, net: net);
      devices.add(d);
      return d;
    }

    Future<void> round() async {
      for (final d in devices) {
        now += 1000;
        await d.run();
      }
    }

    int streak(WalletRepo r) => reviewStreak(r.reviewDates(), legacyLast: r.settings().lastReview, legacyStreak: r.settings().reviewStreak);

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-review-');
      key = VaultKey.generate();
      net = Net();
      devices.clear();
      now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    test('reviews on different days before syncing: both days kept, the streak counts both', () async {
      final a = device('a'), b = device('b');
      a.repo.markReviewDone('2026-03-01');
      b.repo.markReviewDone('2026-03-08');
      await round();
      await round();
      for (final d in [a, b]) {
        expect(d.repo.reviewDates(), ['2026-03-01', '2026-03-08'], reason: d.name);
        expect(streak(d.repo), 2, reason: d.name);
      }
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
    }, timeout: _t);

    test('a review on the same day on both devices is one row', () async {
      final a = device('a'), b = device('b');
      a.repo.markReviewDone('2026-03-01');
      now += 5000;
      b.repo.markReviewDone('2026-03-01');
      await round();
      await round();
      for (final d in [a, b]) {
        expect(d.repo.db.select('SELECT COUNT(*) AS n FROM reviews').first['n'], 1, reason: d.name);
        expect(streak(d.repo), 1, reason: d.name);
      }
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
    }, timeout: _t);

    test('the legacy base from one device and rows from both add up the same on each', () async {
      final a = device('a'), b = device('b');
      a.repo.updateSettings({'lastReview': '2026-02-22', 'reviewStreak': 5}); // as an older build left them
      await round();
      a.repo.markReviewDone('2026-03-01');
      b.repo.markReviewDone('2026-03-08');
      await round();
      await round();
      expect([streak(a.repo), streak(b.repo)], [7, 7]);
    }, timeout: _t);
  });

  group('migration 17 → 18', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bw-review-mig-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    for (final keyed in [false, true]) {
      test('${keyed ? 'encrypted' : 'plain'}: the reviews table appears, the legacy streak is the base, nothing is rewritten', () async {
        final path = '${tmp.path}/w.db';
        final dbKey = keyed ? await localDbKey(VaultKey(List<int>.generate(32, (i) => i + 7))) : null;
        // A schema-17 wallet: legacy review settings, no reviews table.
        final old = WalletRepo.open(path, dbKey: dbKey);
        old.updateSettings({'lastReview': '2026-03-01', 'reviewStreak': 4});
        old.close();
        final raw = sqlite3.open(path);
        if (dbKey != null) {
          raw.execute("PRAGMA cipher = 'chacha20'");
          raw.execute('PRAGMA key = "x\'${dbKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\'"');
        }
        raw.execute('DROP TABLE reviews');
        raw.execute("UPDATE meta SET value = '17' WHERE key = 'schema'");
        raw.close();

        final r = WalletRepo.open(path, dbKey: dbKey);
        addTearDown(r.close);
        expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
        expect(r.reviewDates(), isEmpty);
        final ops = r.pendingOps().length;
        final st = r.settings();
        expect(reviewState(const [], st, const [], const {}, today: '2026-03-02', reviewDates: r.reviewDates()).streak, 4);
        r.markReviewDone('2026-03-08');
        expect(r.pendingOps().length, ops + 1, reason: 'one review op, no setting op');
        final s = reviewState(const [], r.settings(), const [], const {}, today: '2026-03-09', reviewDates: r.reviewDates());
        expect((s.streak, s.nextReviewDate, s.due), (5, '2026-03-15', false));
        expect((r.settings().lastReview, r.settings().reviewStreak), ('2026-03-01', 4));
      }, timeout: _t);
    }
  });
}
