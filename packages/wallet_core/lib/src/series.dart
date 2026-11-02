// Scrollable, zoomable graph data (stage ZC, docs/context/ZC_SPEC.md §3–4). Pure, web-safe, ints only.
//
// A [DayIndex] is built once per data version from the expanded, home-currency list (one pass): exact cent sums per
// day for spending (the "Where it goes" rule, `countsAsSpending`), income and extra, with prefix sums so any span is
// two binary searches. Per category / tag / merchant key the prefix sums are made on first use and kept. The series
// functions cut a window into aligned buckets (days, Monday weeks, calendar months, calendar quarters) and read the
// index only: a drag frame never walks the payments again.
import 'dart:convert';

import 'accounts.dart' show RowAccounts;
import 'budget.dart' show countsAsSpending;
import 'categories.dart' show BudgetKind, CategoryTable;
import 'cols.dart';
import 'dates.dart' show requireIsoDate;
import 'findings.dart' show pearsonPermille;
import 'insights.dart' show merchantGroupKey;
import 'models.dart';
import 'ranges.dart';

part 'explore.dart';

/// The size of one bar.
enum Bucket { day, week, month, quarter, year }

/// The longest window of day, week or month buckets, in years: it must end before its start + this many years (as
/// `rangeFor`'s custom range). Quarter and year buckets have no limit (ENG §6.3: Explore "All" = the whole history).
const _maxYears = 5;

/// Bar size for [window]: the coarsest of [finest] and the size the span calls for (up to 35 days: day, up to 155 days:
/// week, up to 4 years: month, longer: quarter; ZC_SPEC §1), made coarser while [window] would have more than
/// [maxBars] bars (a narrow screen passes fewer), up to years. Year when nothing fits.
Bucket bucketFor(DateRange window, {int maxBars = 40, Bucket finest = Bucket.day}) {
  final lo = _epoch(window.start), hi = _epoch(window.end);
  final days = hi - lo + 1;
  final bySpan = days <= 35
      ? Bucket.day
      : days <= 155
          ? Bucket.week
          : days <= 4 * 366
              ? Bucket.month
              : Bucket.quarter;
  var b = bySpan.index < finest.index ? finest : bySpan;
  while (b != Bucket.year && _count(lo, hi, b) > maxBars) {
    b = Bucket.values[b.index + 1];
  }
  return b;
}

/// The buckets of size [b] that [window] overlaps, oldest first, aligned (days, Monday–Sunday weeks, calendar months,
/// calendar quarters starting Jan/Apr/Jul/Oct, calendar years); the first and last are clipped at the window's edges.
/// Throws [ArgumentError] for day, week or month buckets over 5 years or more (`to >= from + 5 years`, as a custom range).
List<DateRange> bucketsOf(DateRange window, Bucket b) {
  final (lo, hi) = _window(window, b);
  final out = <DateRange>[];
  _spans(lo, hi, b, (s, e, fs, fe) => out.add(_range(s, e)));
  return out;
}

/// One bar of [spendingSeries]: spending inside [span] (refunds subtracted, so a net refund is below zero). [partial]:
/// the bucket holds today, or the window cuts it (as `MonthBar.partial`).
class SeriesBar {
  final DateRange span;
  final Bucket bucket;
  final int spent;
  final bool partial;
  const SeriesBar({required this.span, required this.bucket, required this.spent, required this.partial});

  @override
  bool operator ==(Object other) =>
      other is SeriesBar && other.span == span && other.bucket == bucket && other.spent == spent && other.partial == partial;

  @override
  int get hashCode => Object.hash(span, bucket, spent, partial);

  @override
  String toString() => 'SeriesBar(${span.start}..${span.end}, ${bucket.name}, $spent${partial ? ', partial' : ''})';
}

/// One bar of [incomeSeries]: money in and out of [span], counted as `IncomeVsSpending`.
class IncomeSpendingBar {
  final DateRange span;
  final Bucket bucket;
  final int income; // BudgetKind.income
  final int extra; // BudgetKind.extra
  final int spent;
  final bool partial;
  const IncomeSpendingBar(
      {required this.span, required this.bucket, required this.income, required this.extra, required this.spent, required this.partial});

  int get net => income + extra - spent;

  @override
  bool operator ==(Object other) =>
      other is IncomeSpendingBar &&
      other.span == span &&
      other.bucket == bucket &&
      other.income == income &&
      other.extra == extra &&
      other.spent == spent &&
      other.partial == partial;

  @override
  int get hashCode => Object.hash(span, bucket, income, extra, spent, partial);

  @override
  String toString() =>
      'IncomeSpendingBar(${span.start}..${span.end}, ${bucket.name}, $income, $extra, $spent${partial ? ', partial' : ''})';
}

/// One bar of [budgetSeries]. [budgeted] is exact for a whole month or quarter (the month budgets summed) and the
/// pro-rated share otherwise ([prorated]: a day or week, or a month/quarter the window clips); [actual] = the budgeted
/// categories' spending in [span] (refunds subtracted); [over] = Σ per category of max(0, actual_c − share_c), as
/// `BudgetMonth.over`.
class BudgetBar {
  final DateRange span;
  final Bucket bucket;
  final int budgeted;
  final int actual;
  final int over;
  final bool prorated;
  final bool partial;
  const BudgetBar(
      {required this.span,
      required this.bucket,
      required this.budgeted,
      required this.actual,
      required this.over,
      required this.prorated,
      required this.partial});

  @override
  bool operator ==(Object other) =>
      other is BudgetBar &&
      other.span == span &&
      other.bucket == bucket &&
      other.budgeted == budgeted &&
      other.actual == actual &&
      other.over == over &&
      other.prorated == prorated &&
      other.partial == partial;

  @override
  int get hashCode => Object.hash(span, bucket, budgeted, actual, over, prorated, partial);

  @override
  String toString() => 'BudgetBar(${span.start}..${span.end}, ${bucket.name}, $budgeted, $actual, over $over'
      '${prorated ? ', prorated' : ''}${partial ? ', partial' : ''})';
}

/// Per-day sums of one wallet's money, built in one pass over the expanded list (P6: split parts, never the whole
/// payment too) with the rules of `monthSummary` / `spendingByMonth` / `rowsForTag`: live rows in [currency] only;
/// spending = fixed + flex (`countsAsSpending`, refunds subtracted); income = [BudgetKind.income], extra =
/// [BudgetKind.extra]; transfers (and IOU-linked rows) and other currencies count nowhere.
class DayIndex {
  /// Kept for callers written for categories with children (as `insights.dart`); since T1 a category is its own tree.
  final CategoryTable? table;

  final String _currency;

  /// Distinct days that hold a counted row, as epoch days, ascending.
  final List<int> _days;

  /// Prefix sums over [_days] (length `_days.length + 1`): spending (positive = out), income, extra.
  final List<int> _spentP, _incomeP, _extraP;

  /// The spending rows and the index of their day in [_days].
  final List<CategorizedTx> _rows;
  final List<int> _rowDay;
  final Map<String, List<int>> _byCategory, _byTag;
  final List<String?> _merchant;

  /// The income and extra rows and the index of their day in [_days] (for [runQuery]'s cameIn and kept).
  final List<CategorizedTx> _money;
  final List<int> _moneyDay;
  final List<String?> _moneyMerchant;
  final Map<String, List<int>> _cache = {};

  /// `merchantGroupKey` per description: a bank row's key depends on its description only.
  final Map<String, String> _keyByDescription = {};

  /// The counting rule for account series ([SeriesKind.account]); null: a row's `tx.account` as stored.
  final RowAccounts? _owners;

  DayIndex._(this.table, this._currency, this._days, this._spentP, this._incomeP, this._extraP, this._rows, this._rowDay, this._byCategory,
      this._byTag, this._money, this._moneyDay, this._owners)
      : _merchant = List<String?>.filled(_rows.length, null),
        _moneyMerchant = List<String?>.filled(_money.length, null);

  /// [accounts]: every account (`WalletRepo.accounts`), so an account series counts the rows [RowAccounts] gives it (a
  /// main account's rows without `tx.account` included, as its balance does).
  factory DayIndex(List<CategorizedTx> expanded, {required String currency, CategoryTable? table, Iterable<Account>? accounts}) {
    final epochOf = <String, int>{};
    final rows = <CategorizedTx>[], rowE = <int>[];
    final money = <CategorizedTx>[], moneyE = <int>[]; // income and extra rows
    for (final t in expanded) {
      if (!t.tx.live || t.tx.currency != currency) continue;
      final spending = countsAsSpending(t, currency);
      if (!spending && t.kind != BudgetKind.income && t.kind != BudgetKind.extra) continue;
      final e = epochOf[t.date] ??= _epoch(t.date);
      if (spending) {
        rows.add(t);
        rowE.add(e);
      } else {
        money.add(t);
        moneyE.add(e);
      }
    }
    final days = epochOf.values.toSet().toList()..sort();
    final slot = {for (var i = 0; i < days.length; i++) days[i]: i};
    final spent = List<int>.filled(days.length + 1, 0), income = List<int>.filled(days.length + 1, 0);
    final extra = List<int>.filled(days.length + 1, 0);
    final rowDay = List<int>.filled(rows.length, 0);
    final byCategory = <String, List<int>>{}, byTag = <String, List<int>>{};
    for (var i = 0; i < rows.length; i++) {
      final t = rows[i], d = slot[rowE[i]]!;
      rowDay[i] = d;
      spent[d + 1] -= t.amount;
      (byCategory[t.category] ??= []).add(i);
      for (final g in t.tags.length < 2 ? t.tags : t.tags.toSet()) {
        (byTag[g] ??= []).add(i);
      }
    }
    final moneyDay = List<int>.filled(money.length, 0);
    for (var i = 0; i < money.length; i++) {
      final t = money[i], d = slot[moneyE[i]]! + 1;
      moneyDay[i] = d - 1;
      if (t.kind == BudgetKind.income) {
        income[d] += t.amount;
      } else {
        extra[d] += t.amount;
      }
    }
    for (var i = 1; i <= days.length; i++) {
      spent[i] += spent[i - 1];
      income[i] += income[i - 1];
      extra[i] += extra[i - 1];
    }
    return DayIndex._(table, currency, days, spent, income, extra, rows, rowDay, byCategory, byTag, money, moneyDay,
        accounts == null ? null : RowAccounts(accounts));
  }

  /// The wallet currency the sums are in.
  String get currency => _currency;

  /// The first and last day holding a counted row (spending, income or extra); null when there is none.
  String? get first => _days.isEmpty ? null : _iso(_days.first);
  String? get last => _days.isEmpty ? null : _iso(_days.last);

  /// Spending in [r] (refunds subtracted): of [category] (the row's category), of rows carrying [tag], of the
  /// drill-down payee [merchantKey] (`merchantsIn`' key, '' = Other); the filters given all apply.
  int spent(DateRange r, {String? category, String? tag, String? merchantKey}) =>
      _sum(_spentPrefix(category, tag, merchantKey), _epoch(r.start), _epoch(r.end));

  /// Income ([BudgetKind.income]) in [r].
  int income(DateRange r) => _sum(_incomeP, _epoch(r.start), _epoch(r.end));

  /// Extra income ([BudgetKind.extra]) in [r].
  int extra(DateRange r) => _sum(_extraP, _epoch(r.start), _epoch(r.end));

  /// The categories with spending rows (for [budgetSeries]' roll-up).
  Iterable<String> get _categories => _byCategory.keys;

  /// Σ over the epoch days [lo]..[hi] of the prefix sums [p].
  int _sum(List<int> p, int lo, int hi) => p[_lower(hi + 1)] - p[_lower(lo)];

  /// The first slot of [_days] at or after epoch day [e].
  int _lower(int e) {
    var a = 0, b = _days.length;
    while (a < b) {
      final m = (a + b) >> 1;
      if (_days[m] < e) {
        a = m + 1;
      } else {
        b = m;
      }
    }
    return a;
  }

  String _keyOf(Tx t) => t.source == 'manual' ? merchantGroupKey(t) : _keyByDescription[t.description] ??= merchantGroupKey(t);

  List<int> _spentPrefix(String? category, String? tag, String? merchant) {
    if (category == null && tag == null && merchant == null) return _spentP;
    final key =
        '${category == null ? '-' : '+$category'}\u0000${tag == null ? '-' : '+$tag'}\u0000${merchant == null ? '-' : '+$merchant'}';
    final hit = _cache[key];
    if (hit != null) return hit;
    final Iterable<int> candidates = category != null
        ? (_byCategory[category] ?? const <int>[])
        : tag != null
            ? (_byTag[tag] ?? const <int>[])
            : Iterable<int>.generate(_rows.length);
    final p = List<int>.filled(_days.length + 1, 0);
    for (final i in candidates) {
      final t = _rows[i];
      if (tag != null && category != null && !t.tags.contains(tag)) continue;
      if (merchant != null && (_merchant[i] ??= _keyOf(t.tx)) != merchant) continue;
      p[_rowDay[i] + 1] -= t.amount;
    }
    for (var i = 1; i < p.length; i++) {
      p[i] += p[i - 1];
    }
    return _cache[key] = p;
  }
}

/// Spending per bucket of [window] ([bucketsOf]), filtered as [DayIndex.spent]. For whole calendar months this is
/// exactly `spendingByMonth` (with [tag]: `tagTrend`; [category] + [merchantKey]: `merchantTrend`).
List<SeriesBar> spendingSeries(DayIndex ix, DateRange window, Bucket b,
    {required String today, String? category, String? tag, String? merchantKey}) {
  final (lo, hi) = _window(window, b);
  final t = _today(today);
  final p = ix._spentPrefix(category, tag, merchantKey);
  final out = <SeriesBar>[];
  _spans(lo, hi, b, (s, e, fs, fe) {
    out.add(SeriesBar(span: _range(s, e), bucket: b, spent: ix._sum(p, s, e), partial: _isPartial(s, e, fs, fe, t)));
  });
  return out;
}

/// Income, extra income and spending per bucket of [window]; for whole calendar months exactly `incomeVsSpending`.
List<IncomeSpendingBar> incomeSeries(DayIndex ix, DateRange window, Bucket b, {required String today}) {
  final (lo, hi) = _window(window, b);
  final t = _today(today);
  final out = <IncomeSpendingBar>[];
  _spans(lo, hi, b, (s, e, fs, fe) {
    out.add(IncomeSpendingBar(
      span: _range(s, e),
      bucket: b,
      income: ix._sum(ix._incomeP, s, e),
      extra: ix._sum(ix._extraP, s, e),
      spent: ix._sum(ix._spentP, s, e),
      partial: _isPartial(s, e, fs, fe, t),
    ));
  });
  return out;
}

/// Budgets ([budgets]: category → cents per calendar month, `WalletSettings.categoryBudgets`) against the spending of
/// the budgeted categories ([category] null: every category in [budgets]; else that one) per bucket of [window]
/// ([bucketsOf]). A [category] with no entry in [budgets] counts nowhere: every bar is budgeted 0, actual 0, over 0
/// (a budget set to 0 is a real one: its spending is over). Rows count in their top-level category ([table], as `budgetVsActual`).
/// Each category's month budget is split over the month's days in integer cents by largest remainder (all remainders
/// tie, so the earlier days get the extra cent), on its own (owner §6 Q2, settled 2026-11-01); a bar's `budgeted` is
/// the sum of its days' shares, so the days of a month add up to its budget exactly and a whole month or quarter is
/// the exact month budgets summed. Whole months equal `budgetVsActualSeries` (budgeted, actual, over).
/// `prorated` = the bar is not whole calendar months (a day, a week, or a month/quarter the window clips).
List<BudgetBar> budgetSeries(DayIndex ix, DateRange window, Bucket b, Map<String, int> budgets,
    {required String today, required CategoryTable table, String? category}) {
  final (lo, hi) = _window(window, b);
  final t = _today(today);
  // A [category] without an entry in [budgets] counts nowhere (budgetVsActualSeries sums budgeted lines only); a budget
  // set to 0 is a real budget, so its spending is over.
  final lines = category == null
      ? budgets
      : {
          if (budgets[category] case final c?) category: c,
        };
  // Each budgeted category: its month budget and the prefix sums of the index categories that roll up into it.
  final keys = lines.keys.toList(growable: false);
  final cents = [for (final k in keys) lines[k]!];
  final slot = {for (var i = 0; i < keys.length; i++) keys[i]: i};
  final prefixes = [for (final _ in keys) <List<int>>[]];
  for (final k in ix._categories) {
    final i = slot[table.topLevel(k)];
    if (i != null) prefixes[i].add(ix._spentPrefix(k, null, null));
  }
  final out = <BudgetBar>[];
  _spans(lo, hi, b, (s, e, fs, fe) {
    var budgeted = 0, actual = 0, over = 0;
    for (var i = 0; i < keys.length; i++) {
      var a = 0;
      for (final p in prefixes[i]) {
        a += ix._sum(p, s, e);
      }
      final share = _share(cents[i], s, e);
      budgeted += share;
      actual += a;
      if (a > share) over += a - share;
    }
    final whole = b != Bucket.day && b != Bucket.week && s == fs && e == fe;
    out.add(BudgetBar(
      span: _range(s, e),
      bucket: b,
      budgeted: budgeted,
      actual: actual,
      over: over,
      prorated: !whole,
      partial: _isPartial(s, e, fs, fe, t),
    ));
  });
  return out;
}

/// A short label for one bar: day `14`, week `6–12 Oct` (`29 Sep – 5 Oct` across months, `29 Dec 25 – 4 Jan 26` across
/// years, `12 Oct` for a one-day piece), month `Oct 26`, quarter `Q4 26`, year `2026`. A clipped span is labelled as it is.
String bucketLabel(DateRange span, Bucket b) {
  final (sy, sm, sd) = _civil(_epoch(span.start));
  final yy = _p(sy % 100);
  switch (b) {
    case Bucket.day:
      return '$sd';
    case Bucket.month:
      return '${_monthNames[sm - 1]} $yy';
    case Bucket.quarter:
      return 'Q${(sm - 1) ~/ 3 + 1} $yy';
    case Bucket.year:
      return '$sy';
    case Bucket.week:
      if (span.start == span.end) return '$sd ${_monthNames[sm - 1]}';
      final (ey, em, ed) = _civil(_epoch(span.end));
      if (sy != ey) return '$sd ${_monthNames[sm - 1]} $yy – $ed ${_monthNames[em - 1]} ${_p(ey % 100)}';
      if (sm != em) return '$sd ${_monthNames[sm - 1]} – $ed ${_monthNames[em - 1]}';
      return '$sd–$ed ${_monthNames[sm - 1]}';
  }
}

const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _p(int n) => n.toString().padLeft(2, '0');

/// [window] as epoch days; refused for buckets finer than quarters when it spans 5 years or more.
(int, int) _window(DateRange window, Bucket b) {
  final lo = _epoch(window.start), hi = _epoch(window.end);
  if (b.index >= Bucket.quarter.index) return (lo, hi);
  final (y, m, d) = _civil(lo);
  // The same day 5 years later (29 Feb → 1 Mar: the civil formula carries an impossible day over).
  if (hi >= _days(y + _maxYears, m, d)) throw ArgumentError('The range is longer than 5 years.');
  return (lo, hi);
}

/// `partial` as `insights.dart`'s `_partial`: the whole bucket [fs]..[fe] holds [today], or the window cut it.
bool _isPartial(int s, int e, int fs, int fe, int today) => (today >= fs && today <= fe) || s != fs || e != fe;

/// Calls [f] with every bucket of size [b] overlapping [lo]..[hi]: the clipped span `s..e` and the whole bucket
/// `fs..fe` (epoch days, inclusive).
void _spans(int lo, int hi, Bucket b, void Function(int s, int e, int fs, int fe) f) {
  var s = lo;
  while (s <= hi) {
    final (fs, fe) = _bucketAt(s, b);
    final e = fe < hi ? fe : hi;
    f(s, e, fs, fe);
    s = e + 1;
  }
}

/// How many buckets of size [b] overlap [lo]..[hi].
int _count(int lo, int hi, Bucket b) {
  switch (b) {
    case Bucket.day:
      return hi - lo + 1;
    case Bucket.week:
      return ((hi - _weekday(hi)) - (lo - _weekday(lo))) ~/ 7 + 1;
    case Bucket.month || Bucket.quarter || Bucket.year:
      final (ly, lm, _) = _civil(lo);
      final (hy, hm, _) = _civil(hi);
      final months = (hy - ly) * 12 + hm - lm;
      return switch (b) {
        Bucket.month => months + 1,
        Bucket.quarter => (hy * 12 + hm - 1) ~/ 3 - (ly * 12 + lm - 1) ~/ 3 + 1,
        _ => hy - ly + 1,
      };
  }
}

/// The whole bucket of size [b] holding epoch day [e], inclusive.
(int, int) _bucketAt(int e, Bucket b) {
  switch (b) {
    case Bucket.day:
      return (e, e);
    case Bucket.week:
      final s = e - _weekday(e);
      return (s, s + 6);
    case Bucket.month:
      final (y, m, d) = _civil(e);
      final s = e - d + 1;
      return (s, (m == 12 ? _days(y + 1, 1, 1) : _days(y, m + 1, 1)) - 1);
    case Bucket.quarter:
      final (y, m, _) = _civil(e);
      final q = (m - 1) ~/ 3 * 3 + 1;
      return (_days(y, q, 1), (q == 10 ? _days(y + 1, 1, 1) : _days(y, q + 3, 1)) - 1);
    case Bucket.year:
      final (y, _, _) = _civil(e);
      return (_days(y, 1, 1), _days(y + 1, 1, 1) - 1);
  }
}

/// Σ of one monthly budget's daily shares over epoch days [lo]..[hi]: each month's [cents] split over its days by
/// largest remainder (every remainder ties, so the first `cents mod days` days get one cent more).
int _share(int cents, int lo, int hi) {
  if (cents == 0) return 0;
  var sum = 0;
  var s = lo;
  while (s <= hi) {
    final (ms, me) = _bucketAt(s, Bucket.month);
    final e = me < hi ? me : hi;
    final n = me - ms + 1;
    final rem = cents % n; // Dart: never negative, so base * n + rem == cents for any sign
    final base = (cents - rem) ~/ n;
    final a = s - ms, z = e - ms; // day offsets inside the month, inclusive
    final extra = (z + 1 < rem ? z + 1 : rem) - a;
    sum += base * (z - a + 1) + (extra > 0 ? extra : 0);
    s = e + 1;
  }
  return sum;
}

/// 0 = Monday … 6 = Sunday (1970-01-01 was a Thursday).
int _weekday(int e) => (e + 3) % 7;

int _today(String today) {
  requireIsoDate(today);
  return _epoch(today);
}

DateRange _range(int s, int e) => DateRange(start: _iso(s), end: _iso(e));

/// Days since 1970-01-01 of a `YYYY-MM-DD` date (no DateTime: exact on the web, no time zones). Only the shape is
/// checked here: a [DateRange] already passed `requireIsoDate`, `today` passes it in [_today].
int _epoch(String iso) {
  if (iso.length != 10 || iso.codeUnitAt(4) != 0x2d || iso.codeUnitAt(7) != 0x2d) throw ArgumentError('The date is not YYYY-MM-DD.');
  return _days(int.parse(iso.substring(0, 4)), int.parse(iso.substring(5, 7)), int.parse(iso.substring(8, 10)));
}

/// Days since 1970-01-01 of civil date [y]-[m]-[d] (H. Hinnant's `days_from_civil`; an impossible day carries over).
int _days(int y, int m, int d) {
  final yy = m <= 2 ? y - 1 : y;
  final era = (yy >= 0 ? yy : yy - 399) ~/ 400;
  final yoe = yy - era * 400;
  final doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) ~/ 5 + d - 1;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
  return era * 146097 + doe - 719468;
}

/// The civil date of epoch day [e] (`civil_from_days`).
(int, int, int) _civil(int e) {
  final z = e + 719468;
  final era = (z >= 0 ? z : z - 146096) ~/ 146097;
  final doe = z - era * 146097;
  final yoe = (doe - doe ~/ 1460 + doe ~/ 36524 - doe ~/ 146096) ~/ 365;
  final doy = doe - (365 * yoe + yoe ~/ 4 - yoe ~/ 100);
  final mp = (5 * doy + 2) ~/ 153;
  final d = doy - (153 * mp + 2) ~/ 5 + 1;
  final m = mp < 10 ? mp + 3 : mp - 9;
  return (m <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, m, d);
}

String _iso(int e) {
  final (y, m, d) = _civil(e);
  return '${y.toString().padLeft(4, '0')}-${_p(m)}-${_p(d)}';
}
