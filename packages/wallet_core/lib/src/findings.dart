// ENG §6.2: the findings engine. Auto-found patterns in the owner's spending, each with its basis and evidence series.
// Pure, web-safe, integers only (BigInt where a product could pass 2^53). Read-only: a finding never changes data.
//
// Rules (approved by the lead 2026-11-02; test/eng_findings_test.dart and the spec tests pin them):
// - Spending = `countsAsSpending` per main tag (`CategoryTable.topLevel` of the row's category): live rows in the home
//   currency, fixed + flex, refunds subtracted; transfers, IOU-linked rows, income and other currencies count nowhere.
// - "This month" = monthOf(today); W12 = the 12 calendar months before it. Tracked months = months at or after the
//   month of the first counted home-currency row (spending, income or extra), as `DayIndex.first`.
// - aboveUsual: ≥ 6 tracked months in W12; median (`medianCents`) over them, zero months included, must be > 0;
//   fires when 4·now ≥ 5·median and now − median ≥ 2000 cents. Window end = this month.
// - weeklyRhythm: whole spending (subject `all`) over the tracked months of W12 (≥ 6); mean per ISO weekday = its sum ÷
//   how many of that weekday the months hold; fires when 5·Smax·Nmin ≥ 8·Smin·Nmax with Smin > 0 (lead 2026-11-02: a weekday
//   with no spending at all never fires, so sparse data stays quiet). A standing pattern: id `weeklyRhythm:all`, no window month.
// - movesTogether: the last 24 full tracked months, the top 8 main tags by spend there; a shared month = both tags
//   nonzero; ≥ 12 shared months; |r| ≥ 0.5 ⇔ 4·Sxy² ≥ Sxx·Syy (Sxx, Syy > 0), r in permille (signed) by integer square
//   root. subject < other alphabetically. A standing pattern: its id has no window month (a dismissal holds for good).
// - slowCreep: confirmed bills (not incomes) with a payee; their rows = live bank outflows in the home currency whose
//   `merchantKey` is the payee (no transfers, no IOU-linked rows; never by amount), summed per calendar month
//   (absolute cents, so parts add up). latest3 = the last 3 full months with a payment; earliest3 = the first 3 months
//   with a payment at least 12 months before latest3's last month; both need 3 months. Fires when 4·median(latest3) ≥
//   5·median(earliest3) (`medianCents`), so one cycle that slips into the next month never fires alone (lead
//   2026-11-02). subject = bill id. Window end = latest3's last month.
// - seasonality: full calendar years fully tracked and ended before this month; per main tag per year the max month
//   (> 0, earliest on a tie); a calendar month that is the max in ≥ 3 years fires (otherKey = `MM`, n = years).
//   Window end = December of the last such year.
// - milestone: `days` (first live row → today, inclusive; levels 100, 365, then every 365), `payments` (distinct live
//   payments; 100, 500, 1000, then every 1000), `streak` (best `reviewStreak` over time; 4, 12, 26, 52, then every 52).
//   The highest level reached fires; n = that level; window end = the month it was reached (a dismissal holds until
//   the next level).
// - id = `<kind>:<subjectKey>[:<otherKey>]:<window end YYYY-MM>` (weeklyRhythm and movesTogether without the month);
//   dismissed ids are left out. Order: kind, then |strength| ?? ratio ?? n descending, then id.
import 'package:wallet_importer/wallet_importer.dart' show TxKind;

import 'budget.dart' show countsAsSpending, reviewStreak;
import 'categories.dart' show BudgetKind, CategoryTable, merchantKey;
import 'dates.dart';
import 'hours.dart' show roundDiv;
import 'logs.dart';
import 'models.dart';
import 'recurring.dart' show medianCents;

final _log = Logger('bw.findings');

enum FindingKind { aboveUsual, weeklyRhythm, movesTogether, slowCreep, seasonality, milestone }

/// One finding with its basis: [n] data points (months, years, shared months, or the milestone level) over [from]..[to]
/// (`YYYY-MM-DD`), [strengthPermille] (movesTogether only: r × 1000, signed), [ratioPermille] (now ÷ usual, max ÷ min
/// weekday, latest ÷ earliest; × 1000), and the evidence [series]: (label, cents) pairs with label `YYYY-MM`, an ISO
/// weekday `1`..`7` (weeklyRhythm, mean cents) or the milestone subject (its current value). [otherSeries]: the second
/// main tag's months for movesTogether, else empty.
class Finding {
  final String id;
  final FindingKind kind;
  final String subjectKey;
  final String? otherKey;
  final String from, to;
  final int n;
  final int? strengthPermille, ratioPermille;
  final List<(String, int)> series, otherSeries;

  const Finding({
    required this.id,
    required this.kind,
    required this.subjectKey,
    this.otherKey,
    required this.from,
    required this.to,
    required this.n,
    this.strengthPermille,
    this.ratioPermille,
    this.series = const [],
    this.otherSeries = const [],
  });

  int get _rank => strengthPermille?.abs() ?? ratioPermille ?? n;

  @override
  bool operator ==(Object other) => other is Finding && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;

  @override
  String toString() => 'Finding($id, $from..$to, n $n, strength $strengthPermille, ratio $ratioPermille, $series, $otherSeries)';
}

/// The findings in [expanded] (the expanded list, P6) as of [today], dismissed ones ([WalletSettings.dismissedFindings])
/// left out. [reviewDates]: `WalletRepo.reviewDates()`; [bills]: the live recurring bills. Rules in the file comment.
List<Finding> findings(List<CategorizedTx> expanded, WalletSettings st, CategoryTable table, String today,
    {List<String> reviewDates = const [], List<RecurringBill> bills = const []}) {
  requireIsoDate(today);
  final cur = st.currency;
  final now = _mi(monthOf(today));
  final byTag = <String, Map<int, int>>{};
  final byDay = <String, int>{};
  final payDate = <String, String>{}; // live payment id -> date
  int? first; // month index of the first counted home-currency row
  final billKeys = {
    for (final b in bills)
      if (b.status == 'confirmed' && !b.isIncome && b.payee.isNotEmpty) b.payee
  };
  final billRows = <String, Map<int, int>>{}; // payee -> month -> cents out
  final billSeen = <String>{};
  final keyOf = <String, String>{}; // description -> merchantKey (a bank row's key depends on its description only)
  for (final t in expanded) {
    final tx = t.tx;
    if (!tx.live) continue;
    payDate[tx.id] = tx.date;
    if (tx.currency != cur) continue;
    final spend = countsAsSpending(t, cur);
    if (spend || t.kind == BudgetKind.income || t.kind == BudgetKind.extra) {
      final m = _mi(monthOf(t.date));
      if (first == null || m < first) first = m;
      if (spend) {
        final tag = byTag[table.topLevel(t.category)] ??= {};
        tag[m] = (tag[m] ?? 0) - t.amount;
        byDay[t.date] = (byDay[t.date] ?? 0) - t.amount;
      }
    }
    if (billKeys.isNotEmpty &&
        !tx.manual &&
        tx.amount < 0 &&
        !t.iou &&
        (t.whole ?? t).kind != BudgetKind.transfer &&
        tx.transferTo == null &&
        tx.kindHint != TxKind.ownTransfer &&
        tx.kindHint != TxKind.exchange &&
        billSeen.add(tx.id)) {
      final key = keyOf[tx.description] ??= merchantKey(tx);
      if (billKeys.contains(key)) {
        final mm = billRows[key] ??= {};
        final m = _mi(monthOf(tx.date));
        mm[m] = (mm[m] ?? 0) - tx.amount;
      }
    }
  }
  final tags = byTag.keys.toList()..sort();
  final out = <Finding>[];
  void add(FindingKind kind, String subject, String? other, int? end, String from, String to, int n,
      {int? strength, int? ratio, List<(String, int)> series = const [], List<(String, int)> otherSeries = const []}) {
    out.add(Finding(
        id: '${kind.name}:$subject${other == null ? '' : ':$other'}${end == null ? '' : ':${_ym(end)}'}',
        kind: kind,
        subjectKey: subject,
        otherKey: other,
        from: from,
        to: to,
        n: n,
        strengthPermille: strength,
        ratioPermille: ratio,
        series: series,
        otherSeries: otherSeries));
  }

  int v(String tag, int m) => byTag[tag]![m] ?? 0;

  if (first != null) {
    // W12, tracked months only.
    final hist = [for (var m = now - 12 > first ? now - 12 : first; m < now; m++) m];
    if (hist.length >= 6) {
      for (final tag in tags) {
        final med = medianCents([for (final m in hist) v(tag, m)]), x = v(tag, now);
        if (med > 0 && 4 * x >= 5 * med && x - med >= 2000) {
          add(FindingKind.aboveUsual, tag, null, now, _firstDay(hist.first), today, hist.length,
              ratio: _div(BigInt.from(x) * _k, BigInt.from(med)),
              series: [
                for (final m in [...hist, now]) (_ym(m), v(tag, m))
              ]);
        }
      }
      _weekly(hist, byDay, add);
    }
    _moves(now, first, tags, v, add);
    _seasons(now, first, tags, v, add);
  }
  for (final b in bills) {
    final mm = billRows[b.payee];
    if (b.status != 'confirmed' || b.isIncome || b.payee.isEmpty || mm == null) continue;
    final ms = mm.keys.where((m) => m < now).toList()..sort();
    if (ms.length < 3) continue;
    final late = ms.sublist(ms.length - 3), early = ms.where((m) => m <= late.last - 12).take(3).toList();
    if (early.length < 3) continue;
    final a = medianCents([for (final m in early) mm[m]!]), z = medianCents([for (final m in late) mm[m]!]);
    if (4 * z >= 5 * a) {
      add(FindingKind.slowCreep, b.id, null, late.last, _firstDay(early.first), _lastDay(late.last), ms.length,
          ratio: _div(BigInt.from(z) * _k, BigInt.from(a)), series: [for (final m in ms) (_ym(m), mm[m]!)]);
    }
  }
  _milestones(today, payDate, reviewDates, st, add);

  final hidden = st.dismissedFindings.toSet();
  out.removeWhere((f) => hidden.contains(f.id));
  out.sort((a, b) {
    var c = a.kind.index.compareTo(b.kind.index);
    if (c == 0) c = b._rank.compareTo(a._rank);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  logEvent(_log, Level.FINE, 'findings.run', {for (final k in FindingKind.values) k.name: out.where((f) => f.kind == k).length});
  return out;
}

typedef _Add = void Function(FindingKind kind, String subject, String? other, int? end, String from, String to, int n,
    {int? strength, int? ratio, List<(String, int)> series, List<(String, int)> otherSeries});

final _k = BigInt.from(1000);

void _weekly(List<int> hist, Map<String, int> byDay, _Add add) {
  final sum = List.filled(8, 0), cnt = List.filled(8, 0);
  final end = DateTime.utc(hist.last ~/ 12, hist.last % 12 + 2); // first day after the window
  for (var d = DateTime.utc(hist.first ~/ 12, hist.first % 12 + 1); d.isBefore(end); d = DateTime.utc(d.year, d.month, d.day + 1)) {
    cnt[d.weekday]++;
    sum[d.weekday] += byDay[isoDate(d)] ?? 0;
  }
  // mean(a) vs mean(b) by cross products.
  int cmp(int a, int b) => (BigInt.from(sum[a]) * BigInt.from(cnt[b])).compareTo(BigInt.from(sum[b]) * BigInt.from(cnt[a]));
  var hi = 1, lo = 1;
  for (var w = 2; w <= 7; w++) {
    if (cmp(w, hi) > 0) hi = w;
    if (cmp(w, lo) < 0) lo = w;
  }
  if (sum[lo] <= 0) return;
  final top = BigInt.from(sum[hi]) * BigInt.from(cnt[lo]), bottom = BigInt.from(sum[lo]) * BigInt.from(cnt[hi]);
  if (BigInt.from(5) * top < BigInt.from(8) * bottom) return;
  add(FindingKind.weeklyRhythm, 'all', null, null, _firstDay(hist.first), _lastDay(hist.last), hist.length,
      ratio: _div(top * _k, bottom), series: [for (var w = 1; w <= 7; w++) ('$w', _div(BigInt.from(sum[w]), BigInt.from(cnt[w])))]);
}

void _moves(int now, int first, List<String> tags, int Function(String, int) v, _Add add) {
  final months = [for (var m = now - 24 > first ? now - 24 : first; m < now; m++) m];
  if (months.length < 12) return;
  final total = {for (final t in tags) t: months.fold(0, (s, m) => s + v(t, m))};
  final top = tags.where((t) => total[t]! > 0).toList()
    ..sort((a, b) {
      final c = total[b]!.compareTo(total[a]!);
      return c != 0 ? c : a.compareTo(b);
    });
  final picked = top.take(8).toList()..sort();
  for (var i = 0; i < picked.length; i++) {
    for (var j = i + 1; j < picked.length; j++) {
      final a = picked[i], b = picked[j];
      final shared = [
        for (final m in months)
          if (v(a, m) != 0 && v(b, m) != 0) m
      ];
      final n = shared.length;
      if (n < 12) continue;
      var sx = BigInt.zero, sy = BigInt.zero, sxx = BigInt.zero, syy = BigInt.zero, sxy = BigInt.zero;
      for (final m in shared) {
        final x = BigInt.from(v(a, m)), y = BigInt.from(v(b, m));
        sx += x;
        sy += y;
        sxx += x * x;
        syy += y * y;
        sxy += x * y;
      }
      final bn = BigInt.from(n);
      final cxx = bn * sxx - sx * sx, cyy = bn * syy - sy * sy, cxy = bn * sxy - sx * sy;
      if (cxx <= BigInt.zero || cyy <= BigInt.zero || BigInt.from(4) * cxy * cxy < cxx * cyy) continue;
      final r = _sqrtRound(BigInt.from(1000000) * cxy * cxy, cxx * cyy);
      add(FindingKind.movesTogether, a, b, null, _firstDay(shared.first), _lastDay(shared.last), n,
          strength: cxy.isNegative ? -r : r,
          series: [for (final m in shared) (_ym(m), v(a, m))],
          otherSeries: [for (final m in shared) (_ym(m), v(b, m))]);
    }
  }
}

void _seasons(int now, int first, List<String> tags, int Function(String, int) v, _Add add) {
  final y0 = (first + 11) ~/ 12, y1 = (now - 12) ~/ 12; // first fully tracked year; last year whose December has passed
  if (y1 - y0 + 1 < 3) return;
  for (final tag in tags) {
    final years = List.filled(12, 0);
    for (var y = y0; y <= y1; y++) {
      var best = -1;
      for (var mo = 0; mo < 12; mo++) {
        if (v(tag, y * 12 + mo) > 0 && (best < 0 || v(tag, y * 12 + mo) > v(tag, y * 12 + best))) best = mo;
      }
      if (best >= 0) years[best]++;
    }
    for (var mo = 0; mo < 12; mo++) {
      if (years[mo] < 3) continue;
      add(FindingKind.seasonality, tag, (mo + 1).toString().padLeft(2, '0'), y1 * 12 + 11, '${_y(y0)}-01-01', '${_y(y1)}-12-31', years[mo],
          series: [for (var m = y0 * 12; m <= y1 * 12 + 11; m++) (_ym(m), v(tag, m))]);
    }
  }
}

void _milestones(String today, Map<String, String> payDate, List<String> reviewDates, WalletSettings st, _Add add) {
  final pays = payDate.entries.where((e) => e.value.compareTo(today) <= 0).toList()
    ..sort((a, b) {
      final c = a.value.compareTo(b.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  if (pays.isNotEmpty) {
    final start = pays.first.value, days = daysBetween(start, today) + 1;
    final dl = _level(days, const [100, 365], 365);
    if (dl != null) {
      add(FindingKind.milestone, 'days', null, _mi(monthOf(addDays(start, dl - 1))), start, today, dl, series: [('days', days)]);
    }
    final pl = _level(pays.length, const [100, 500, 1000], 1000);
    if (pl != null) {
      add(FindingKind.milestone, 'payments', null, _mi(monthOf(pays[pl - 1].value)), start, today, pl, series: [('payments', pays.length)]);
    }
  }
  // Best streak over time: the streak as of each review (reviewStreak on the dates up to it), its running maximum.
  final legacy = st.lastReview != null && isIsoDate(st.lastReview!) ? st.lastReview : null;
  final dates = {...reviewDates.where(isIsoDate), if (legacy != null) legacy}.where((d) => d.compareTo(today) <= 0).toList()..sort();
  var best = 0;
  final reached = <int>[]; // the date index at which best first reached each value
  for (var i = 0; i < dates.length; i++) {
    final upTo = dates.sublist(0, i + 1);
    final s = reviewStreak([
      for (final d in upTo)
        if (d != legacy) d
    ], legacyLast: legacy != null && legacy.compareTo(dates[i]) <= 0 ? legacy : null, legacyStreak: st.reviewStreak);
    while (best < s) {
      best++;
      reached.add(i);
    }
  }
  final sl = _level(best, const [4, 12, 26, 52], 52);
  if (sl != null) {
    add(FindingKind.milestone, 'streak', null, _mi(monthOf(dates[reached[sl - 1]])), dates.first, today, sl, series: [('streak', best)]);
  }
}

/// The highest level of [base] then every [step] past its last that [v] reached; null below the first.
int? _level(int v, List<int> base, int step) {
  if (v < base.first) return null;
  if (v >= base.last) return base.last + (v - base.last) ~/ step * step;
  return base.lastWhere((b) => v >= b);
}

int _div(BigInt n, BigInt d) => roundDiv(n, d).toInt();

/// √(n ÷ d) rounded to the nearest integer (n ≥ 0, d > 0).
int _sqrtRound(BigInt n, BigInt d) {
  var p = _isqrt(n ~/ d);
  final twice = BigInt.two * p + BigInt.one;
  if (twice * twice * d <= BigInt.from(4) * n) p += BigInt.one;
  return p.toInt();
}

BigInt _isqrt(BigInt n) {
  if (n < BigInt.two) return n;
  var x = BigInt.one << ((n.bitLength + 1) >> 1);
  while (true) {
    final y = (x + n ~/ x) >> 1;
    if (y >= x) return x;
    x = y;
  }
}

/// Month index (year × 12 + month − 1) of `YYYY-MM`, and back.
int _mi(String ym) => int.parse(ym.substring(0, 4)) * 12 + int.parse(ym.substring(5, 7)) - 1;
String _y(int y) => y.toString().padLeft(4, '0');
String _ym(int m) => '${_y(m ~/ 12)}-${(m % 12 + 1).toString().padLeft(2, '0')}';
String _firstDay(int m) => '${_ym(m)}-01';
String _lastDay(int m) => '${_ym(m)}-${daysInMonth(_ym(m)).toString().padLeft(2, '0')}';
