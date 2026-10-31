// ZC: what a drag, a pinch and the buttons do to a graph's window (pure maths in lib/src/chart_window.dart), and the edges.
import 'package:budget_wallet/src/chart_window.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

DateRange r(String a, String b) => DateRange(start: a, end: b);

void main() {
  const today = '2026-10-20';
  ChartEdges edgesFor(DateRange w, {String? first}) => ChartEdges.forWindow(w, first: first, today: today);

  group('days', () {
    test('epoch days round-trip, also across a leap day and New Year', () {
      for (final d in ['1970-01-01', '2024-02-29', '2025-12-31', '2026-01-01', '2026-10-20']) {
        expect(isoOfEpochDay(epochDay(d)), d);
      }
      expect(epochDay('2026-01-01') - epochDay('2025-12-31'), 1);
    });
  });

  group('pan', () {
    test('moves by whole days and keeps the length', () {
      final w = r('2026-05-01', '2026-10-20');
      final e = edgesFor(w, first: '2025-01-01');
      final back = e.pan(w, -30);
      expect(back.days, w.days);
      expect(back.start, '2026-04-01');
      expect(back.end, '2026-09-20');
    });

    test('cannot go past today', () {
      final w = r('2026-06-01', '2026-10-20');
      final e = edgesFor(w, first: '2025-01-01');
      expect(e.pan(w, 500), w);
      expect(e.pan(r('2026-06-01', '2026-10-01'), 500).end, today);
    });

    test('a window that already sticks out (the running month) may stay, but never goes further out', () {
      final w = r('2026-05-01', '2026-10-31');
      final e = edgesFor(w, first: '2025-01-01');
      expect(e.pan(w, 10), w);
      final back = e.pan(w, -10);
      expect(back.end, '2026-10-21');
    });

    test('cannot go before the first day with data', () {
      final w = r('2026-08-01', '2026-10-20');
      final e = edgesFor(w, first: '2026-03-10');
      expect(e.pan(w, -1000).start, '2026-03-10');
      expect(e.pan(w, -1000).days, w.days);
    });

    test('an empty wallet (no first day): the window cannot go back at all', () {
      final w = r('2026-05-01', '2026-10-20');
      final e = edgesFor(w);
      expect(e.pan(w, -50), w);
    });

    test('never more than 5 years back from today', () {
      final w = r('2026-08-01', '2026-10-20');
      final e = edgesFor(w, first: '2000-01-01');
      expect(e.pan(w, -100000).start.compareTo('2021-10-20') >= 0, isTrue);
    });
  });

  group('zoom', () {
    test('in halves the window and keeps the day under the focus', () {
      final w = r('2026-01-01', '2026-04-10'); // 100 days
      final e = edgesFor(w, first: '2020-01-01');
      final z = e.zoom(w, 2, focal: 0);
      expect(z.days, 50);
      expect(z.start, w.start);
      final z1 = e.zoom(w, 2, focal: 1);
      expect(z1.end, w.end);
    });

    test('stops at 7 days, however hard you pinch', () {
      var w = r('2026-08-01', '2026-10-20');
      final e = edgesFor(w, first: '2020-01-01');
      for (var i = 0; i < 12; i++) {
        w = e.zoom(w, 2);
      }
      expect(w.days, chartMinDays);
      expect(ChartEdges.canZoomIn(w), isFalse);
      expect(e.zoom(w, 100).days, chartMinDays);
      expect(e.transform(w, 50, 0.5, 0.5).days, chartMinDays);
    });

    test('stops at 5 years (1825 days) and its end stays at today', () {
      var w = r('2026-05-01', '2026-10-20');
      final e = edgesFor(w, first: '2000-01-01');
      for (var i = 0; i < 12; i++) {
        w = e.zoom(w, 0.5);
      }
      expect(w.days, chartMaxDays);
      expect(w.end, today);
      expect(ChartEdges.canZoomOut(w), isFalse);
      // core accepts a window of this length
      expect(() => bucketsOf(w, Bucket.quarter), returnsNormally);
      expect(() => spendingSeries(DayIndex(const [], currency: 'EUR'), w, Bucket.quarter, today: today), returnsNormally);
    });

    test('a window shorter than 7 days (the edges are narrower) keeps its length', () {
      const e = ChartEdges(earliest: 100, latest: 104); // 5 days
      expect(e.clamp(100, 5).days, 5);
      expect(e.zoom(DateRange(start: isoOfEpochDay(100), end: isoOfEpochDay(104)), 2).days, 5);
    });
  });

  group('drag and pinch together', () {
    test('a one finger drag by a third of the width moves a third of the window', () {
      final w = r('2026-01-01', '2026-04-10'); // 100 days
      final e = edgesFor(w, first: '2020-01-01');
      final t = e.transform(w, 1, 0.5, 0.5 - 0.3); // finger moved left by 30 % of the width: later days come in
      expect(t.days, 100);
      expect(t.start, isoOfEpochDay(epochDay(w.start) + 30));
    });

    test('a pinch keeps the day under the fingers', () {
      final w = r('2026-01-01', '2026-04-10');
      final e = edgesFor(w, first: '2020-01-01');
      final t = e.transform(w, 2, 0.25, 0.25);
      expect(t.days, 50);
      final before = epochDay(w.start) + 0.25 * 100, after = epochDay(t.start) + 0.25 * 50;
      expect((before - after).abs() <= 1, isTrue);
    });
  });

  group('odd gesture numbers', () {
    test('a scale of 0, NaN or infinity changes nothing but the position; never throws', () {
      final w = r('2026-01-01', '2026-04-10');
      final e = edgesFor(w, first: '2020-01-01');
      for (final s in [0.0, -1.0, double.nan, double.infinity, double.negativeInfinity]) {
        expect(e.transform(w, s, 0.5, 0.5).days, w.days, reason: '$s');
        expect(e.zoom(w, s).days, w.days, reason: '$s');
      }
      expect(e.transform(w, 1, double.nan, double.nan).days, w.days);
    });
  });

  group('a week across New Year', () {
    test('moves over the year line without a jump', () {
      final w = r('2025-12-20', '2026-01-18');
      final e = ChartEdges.forWindow(w, first: '2024-01-01', today: '2026-10-20');
      final z = e.pan(w, 7);
      expect(z.start, '2025-12-27');
      expect(z.end, '2026-01-25');
    });
  });
}
