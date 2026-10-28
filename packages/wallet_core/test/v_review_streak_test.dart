// Stage V3 spec tests: review streak from dated rows. Written from docs/context/STAGE_V_PLAN.md only. SYNTHETIC data.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

void main() {
  group('reviewStreak (pure)', () {
    test('no dates: 0; with only a legacy streak: that streak', () {
      expect(reviewStreak([]), 0);
      expect(reviewStreak([], legacyLast: '2026-03-01', legacyStreak: 5), 5);
      expect(reviewStreak([], legacyStreak: 3), 3);
    });

    test('one date: 1', () => expect(reviewStreak(['2026-03-01']), 1));

    test('gap of 13 days continues the streak, 14 breaks it', () {
      expect(reviewStreak(['2026-01-01', '2026-01-14']), 2);
      expect(reviewStreak(['2026-01-01', '2026-01-15']), 1);
      expect(reviewStreak(['2026-01-01', '2026-01-08', '2026-01-15', '2026-01-22']), 4);
    });

    test('the walk goes back from the newest date and stops at the first break', () {
      expect(reviewStreak(['2026-01-01', '2026-01-10', '2026-01-25']), 1, reason: '15 days between the last two');
      expect(reviewStreak(['2026-01-01', '2026-01-14', '2026-01-27']), 3);
      expect(reviewStreak(['2025-06-01', '2026-01-01', '2026-01-08']), 2, reason: 'old rows before a long gap do not count');
    });

    test('unsorted and duplicate dates give the same result as the clean list', () {
      expect(reviewStreak(['2026-01-14', '2026-01-01', '2026-01-01', '2026-01-14']), 2);
      expect(reviewStreak(['2026-01-22', '2026-01-08', '2026-01-15', '2026-01-01']), 4);
    });

    test('legacy joined within 13 days adds the legacy streak', () {
      expect(reviewStreak(['2026-03-10'], legacyLast: '2026-03-01', legacyStreak: 4), 5);
      expect(reviewStreak(['2026-03-14'], legacyLast: '2026-03-01', legacyStreak: 4), 5, reason: 'gap 13');
    });

    test('legacy 14 or more days before: not joined', () {
      expect(reviewStreak(['2026-03-15'], legacyLast: '2026-03-01', legacyStreak: 4), 1);
      expect(reviewStreak(['2026-06-15'], legacyLast: '2026-03-01', legacyStreak: 4), 1);
    });

    test('legacy joined on the same day counts that day once', () {
      expect(reviewStreak(['2026-03-01'], legacyLast: '2026-03-01', legacyStreak: 4), 4);
      expect(reviewStreak(['2026-03-01', '2026-03-08'], legacyLast: '2026-03-01', legacyStreak: 4), 5);
    });

    test('the walk must reach the legacy date: a break before it hides the legacy streak', () {
      expect(reviewStreak(['2026-03-20'], legacyLast: '2026-03-01', legacyStreak: 4), 1);
    });

    test('clamped at WalletSettings.maxStreak', () {
      expect(reviewStreak(['2026-03-10'], legacyLast: '2026-03-01', legacyStreak: WalletSettings.maxStreak), WalletSettings.maxStreak);
      expect(reviewStreak([], legacyStreak: WalletSettings.maxStreak + 50), WalletSettings.maxStreak);
    });
  });

  group('reviews in the repo', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    final devices = <Device>[];
    const now = 1767225600000;
    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> sync(List<Device> ds) async {
      for (var round = 0; round < 3; round++) {
        for (final d in ds) {
          d.deliver(net, Random(round));
          await d.run();
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-v3-');
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

    test('a fresh wallet has no review dates', () {
      expect(device('a').repo.reviewDates(), isEmpty);
    });

    test('markReviewDone twice on one day: one row', () {
      final r = device('a').repo;
      r.markReviewDone('2026-01-04');
      r.markReviewDone('2026-01-04');
      expect(r.reviewDates(), ['2026-01-04']);
      expect(reviewStreak(r.reviewDates()), 1);
    });

    test('dates come back ascending and the streak counts weekly reviews', () {
      final r = device('a').repo;
      r.markReviewDone('2026-01-18');
      r.markReviewDone('2026-01-04');
      r.markReviewDone('2026-01-11');
      expect(r.reviewDates(), ['2026-01-04', '2026-01-11', '2026-01-18']);
      expect(reviewStreak(r.reviewDates()), 3);
    });

    test('a bad date is refused and writes nothing', () {
      final r = device('a').repo;
      expect(() => r.markReviewDone('04.01.2026'), throwsA(anything));
      expect(r.reviewDates(), isEmpty);
    });

    test('the old settings lastReview / reviewStreak are never written by markReviewDone', () {
      final r = device('a').repo;
      r.updateSettings({'lastReview': '2025-12-28', 'reviewStreak': 6});
      final before = dump(r)['setting'];
      r.markReviewDone('2026-01-04');
      r.markReviewDone('2026-01-11');
      final st = r.settings();
      expect(st.lastReview, '2025-12-28');
      expect(st.reviewStreak, 6);
      expect(dump(r)['setting'], before);
      expect(reviewStreak(r.reviewDates(), legacyLast: st.lastReview, legacyStreak: st.reviewStreak), 8);
    });

    test('two devices finish reviews on different days before syncing: both dates kept, both see streak 2', () async {
      final a = device('a'), b = device('b');
      await sync([a, b]);
      a.repo.markReviewDone('2026-01-04');
      b.repo.markReviewDone('2026-01-11');
      await sync([a, b]);
      for (final d in [a, b]) {
        expect(d.repo.reviewDates(), ['2026-01-04', '2026-01-11']);
        expect(reviewStreak(d.repo.reviewDates()), 2);
      }
    });

    test('two devices finish on the same day: one row, streak 1', () async {
      final a = device('a'), b = device('b');
      a.repo.markReviewDone('2026-01-04');
      b.repo.markReviewDone('2026-01-04');
      await sync([a, b]);
      for (final d in [a, b]) {
        expect(d.repo.reviewDates(), ['2026-01-04']);
      }
      expect(dump(a.repo)['review'], dump(b.repo)['review']);
    });

    test('a device joining later gets the dates', () async {
      final a = device('a');
      a.repo.markReviewDone('2026-01-04');
      a.repo.markReviewDone('2026-01-11');
      await sync([a]);
      final c = device('c');
      await sync([a, c]);
      expect(c.repo.reviewDates(), ['2026-01-04', '2026-01-11']);
    });
  });
}
