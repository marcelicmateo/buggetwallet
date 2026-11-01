// The window a time graph shows (stage ZC): what a drag, a pinch or a button does to it, and where it may not go. Pure Dart (no
// Flutter): `widgets/chart_viewport.dart` turns gestures into these calls, `InsightRange` uses them for ‹ › on a free window.
// A window is whole days, both ends counted. The calendar rules (bars, buckets) stay in wallet_core.
import 'package:wallet_core/wallet_core.dart';

/// The shortest window a pinch or "+" leads to, and the longest (core's custom-range limit is 5 years).
const chartMinDays = 7, chartMaxDays = 1825;

/// A date as days since 1970-01-01.
int epochDay(String iso) {
  final d = DateTime.parse(iso);
  return DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
}

String isoOfEpochDay(int e) => isoDate(DateTime.fromMillisecondsSinceEpoch(e * Duration.millisecondsPerDay, isUtc: true));

/// Where a window may go: it starts no earlier than [earliest] and ends no later than [latest] (epoch days), as far as its length
/// allows. Built for the window a gesture starts from, so a window that already sticks out (the running month ends after today) can
/// stay as it is but never moves further out, and a zoom that makes it shorter takes the overhang off ([limit]).
class ChartEdges {
  final int earliest, latest;

  /// The real end of the graph (today, payday on the forecast), where [latest] may be later because the window started past it.
  /// Null: [latest].
  final int? limit;
  const ChartEdges({required this.earliest, required this.latest, this.limit});

  /// [first]: the first day with data (null: none, the window cannot go back); [today]; [last]: the latest end instead of today (the
  /// forecast ends at payday); [from]: the earliest start instead of the data and the 5 year limit (the forecast starts today).
  factory ChartEdges.forWindow(DateRange w, {String? first, required String today, String? last, String? from}) {
    final t = DateTime.parse(today);
    final fiveBack = epochDay(isoDate(DateTime.utc(t.year - 5, t.month, t.day)));
    final start = epochDay(w.start);
    final lo = from != null
        ? epochDay(from)
        : first == null
            ? start
            : (epochDay(first) < fiveBack ? fiveBack : epochDay(first));
    final hi = epochDay(last ?? today);
    final end = epochDay(w.end);
    return ChartEdges(earliest: lo < start ? lo : start, latest: hi > end ? hi : end, limit: hi);
  }

  /// The edges for a window that gets [by] days shorter: its overhang past [limit] shrinks by as much, so it reaches the limit exactly
  /// when it has shrunk by the whole overhang, and a pinch moves it continuously. A running month's middle is a future window with
  /// nothing in it; a zoom must not land there. [by] at or above the overhang (the discrete zoom steps pass a big number) = no overhang.
  ChartEdges _shrunkBy(int by) {
    final l = limit;
    if (l == null || l >= latest) return this;
    final over = latest - l - by;
    return ChartEdges(earliest: earliest, latest: over > 0 ? l + over : l, limit: l);
  }

  /// The window of [len] days starting at [start], kept inside the edges and the length limits.
  DateRange clamp(int start, int len) {
    final shortest = latest - earliest + 1 < chartMinDays ? latest - earliest + 1 : chartMinDays;
    len = len.clamp(shortest < 1 ? 1 : shortest, chartMaxDays);
    var end = start + len - 1;
    if (end > latest) {
      end = latest;
      start = end - len + 1;
    }
    if (start < earliest && latest - earliest + 1 >= len) {
      start = earliest;
      end = start + len - 1;
    }
    return DateRange(start: isoOfEpochDay(start), end: isoOfEpochDay(end));
  }

  /// [w] moved by [days] (negative = earlier), same length.
  DateRange pan(DateRange w, int days) => clamp(epochDay(w.start) + days, w.days);

  /// [w] zoomed by [factor] (above 1 = shorter, finer bars) around [focal] (0 = its first day, 1 = its last): the day under that
  /// point stays under it.
  DateRange zoom(DateRange w, double factor, {double focal = 0.5}) {
    if (!factor.isFinite || factor <= 0) factor = 1; // a wheel or a gesture can report 0 or NaN
    if (!focal.isFinite) focal = 0.5;
    final len = w.days;
    final next = (len / factor).round().clamp(1, chartMaxDays);
    final at = epochDay(w.start) + focal * len;
    if (next >= len) return clamp((at - focal * next).round(), next);
    final shorter = _shrunkBy(len).clamp((at - focal * next).round(), next);
    return shorter.days < len ? shorter : w; // at the shortest window a zoom in changes nothing (it must not just move it)
  }

  /// A drag and pinch together: [w0] is the window when the fingers went down, [scale] how far they spread since (above 1 = shorter),
  /// [f0] / [f1] where their middle was then / is now, as 0..1 of the graph's width. The day that was under the middle stays under it.
  DateRange transform(DateRange w0, double scale, double f0, double f1) {
    if (!scale.isFinite || scale <= 0) scale = 1; // a gesture can report 0 or NaN (found by the perf run)
    if (!f0.isFinite) f0 = 0.5;
    if (!f1.isFinite) f1 = f0;
    final len0 = w0.days;
    final len = (len0 / scale).round().clamp(1, chartMaxDays);
    final day = epochDay(w0.start) + f0 * len0;
    if (len >= len0) return clamp((day - f1 * len).round(), len);
    final shorter = _shrunkBy(len0 - len).clamp((day - f1 * len).round(), len);
    return shorter.days < len0 ? shorter : w0;
  }

  /// Another window of the same length cannot be shorter / longer than this.
  static bool canZoomIn(DateRange w) => w.days > chartMinDays;
  static bool canZoomOut(DateRange w) => w.days < chartMaxDays;
}
