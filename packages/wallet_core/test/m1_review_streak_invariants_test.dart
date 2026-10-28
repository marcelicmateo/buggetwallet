// M1: reviewStreak invariants restated from the V3 rule (walk back from the newest while gaps are < 14 days; the legacy
// streak is added when the walk reaches `lastReview`, that day counted once; bad dates ignored). Synthetic dates.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  test('no dates, no legacy: 0', () {
    expect(reviewStreak([]), 0);
  });

  test('a gap of 13 days continues the streak, 14 days ends it', () {
    expect(reviewStreak(['2026-01-01', '2026-01-14']), 2);
    expect(reviewStreak(['2026-01-01', '2026-01-15']), 1);
    expect(reviewStreak(['2026-01-01', '2026-01-08', '2026-01-22']), 1); // 8 -> 22 is exactly 14 days
  });

  test('order of the input does not matter, duplicates count once', () {
    expect(reviewStreak(['2026-01-15', '2026-01-01', '2026-01-08', '2026-01-08']), 3);
  });

  test('invalid dates are ignored, also as legacyLast', () {
    expect(reviewStreak(['nope', '2026-01-08', '2026-13-45']), 1);
    expect(reviewStreak(['2026-01-08'], legacyLast: 'garbage', legacyStreak: 9), 1);
  });

  test('legacy streak is added once when the walk reaches lastReview; that day is counted by the legacy value only', () {
    // New reviews on 22nd and 15th, legacy last review on the 8th with a streak of 4: 1 + 1 + 4.
    expect(reviewStreak(['2026-01-22', '2026-01-15'], legacyLast: '2026-01-08', legacyStreak: 4), 6);
    // The same day in both lists: counted once (as the legacy value).
    expect(reviewStreak(['2026-01-15', '2026-01-08'], legacyLast: '2026-01-08', legacyStreak: 4), 5);
  });

  test('legacy is not added when a gap of 14+ days lies between it and the newer review', () {
    expect(reviewStreak(['2026-01-22'], legacyLast: '2026-01-08', legacyStreak: 4), 1);
    expect(reviewStreak(['2026-01-21'], legacyLast: '2026-01-08', legacyStreak: 4), 5); // 13 days
  });

  test('legacy alone gives its streak; a zero legacy streak adds nothing', () {
    expect(reviewStreak([], legacyLast: '2026-01-08', legacyStreak: 3), 3);
    expect(reviewStreak(['2026-01-15'], legacyLast: '2026-01-08'), 1);
  });

  test('the streak is clamped to maxStreak and never negative', () {
    expect(reviewStreak([], legacyLast: '2026-01-08', legacyStreak: WalletSettings.maxStreak + 50), WalletSettings.maxStreak);
    expect(reviewStreak([], legacyLast: '2026-01-08', legacyStreak: -5), 0);
  });
}
