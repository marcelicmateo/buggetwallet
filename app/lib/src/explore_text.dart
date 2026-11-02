// The words and labels of Explore (ENG E4) and Project (E5). Pure: no widgets, so tests can pin every sentence.
import 'package:wallet_core/wallet_core.dart';

import 'format.dart';

/// The measure as the query bar says it ("spent", "came in", "kept", "payments").
String measureName(Measure m) => switch (m) {
      Measure.spent => 'spent',
      Measure.cameIn => 'came in',
      Measure.kept => 'kept',
      Measure.count => 'payments',
    };

String bucketName(Bucket b) => b.name;

/// One bucket's label: "Mar 2023", "Q2 2024", "2025", "12 Mar" (a week or day).
String exploreBucketLabel(DateRange r, Bucket b) {
  final ym = r.start.substring(0, 7), year = r.start.substring(0, 4);
  return switch (b) {
    Bucket.month => '${monthShort(ym)} $year',
    Bucket.quarter => 'Q${(int.parse(r.start.substring(5, 7)) - 1) ~/ 3 + 1} $year',
    Bucket.year => year,
    _ => shortDate(r.start),
  };
}

/// A value of [m] as the table and tooltip write it: exact money, or a plain count. Never a negative number: kept below zero is its
/// absolute value with the word "lost" ("12.50 € lost", as Spending's "N saved · N lost").
String measureValue(Measure m, int v, String currency) {
  if (m == Measure.count) return groupInt(v);
  if (m == Measure.kept && v < 0) return '${moneyExact(-v, currency)} lost';
  return moneyExact(v, currency);
}

/// An axis tick: whole units, the same rule for kept ("100 € lost" under the zero line).
String axisValue(Measure m, int v, String currency) {
  if (m == Measure.count) return groupInt(v);
  if (m == Measure.kept && v < 0) return '${money(-v, currency, decimals: 0)} lost';
  return money(v, currency, decimals: 0);
}

/// Pearson r in permille as "0.62" (or "−0.62"), two decimals, rounded half away from zero, in the number style.
String strengthText(int permille) {
  final a = permille.abs(), h = (a + 5) ~/ 10; // hundredths
  return '${permille < 0 && h > 0 ? '−' : ''}${h ~/ 100}${numberStyle.decimal}${(h % 100).toString().padLeft(2, '0')}';
}

/// The words for a result of `moveTogether`: strength word (0.7 and over "strong", 0.5 to 0.69 "fairly strong", 0.3 to 0.49 "weak",
/// below that "hardly any link"), then the direction for a negative r, then the months counted. Null: "not enough shared months".
String moveWords(MoveTogether? m) {
  if (m == null) return 'not enough shared months';
  final a = m.strength.abs();
  final word = a >= 700 ? 'strong' : (a >= 500 ? 'fairly strong' : (a >= 300 ? 'weak' : 'hardly any link'));
  final dir = m.strength < 0 && a >= 300 ? ', when one goes up the other goes down' : '';
  return '$word$dir · ${m.months} months';
}

/// "December is your priciest month in 4 of 5 years." from [cells] (month x year), or null. A month counts for a year when it is that
/// year's top one (a tie for the top counts for nobody); only complete years are looked at ([thisYear] is skipped). Needs the same month
/// on top in at least 3 years.
String? topMonthSentence(List<HeatCell> cells, int thisYear, Measure m) {
  final byYear = <int, List<HeatCell>>{};
  for (final c in cells) {
    if (c.year < thisYear) (byYear[c.year] ??= []).add(c);
  }
  final wins = <int, int>{};
  var years = 0;
  for (final cs in byYear.values) {
    final top = cs.map((c) => c.cents).fold<int>(0, (a, b) => a > b ? a : b);
    if (top <= 0) continue;
    years++;
    final tops = cs.where((c) => c.cents == top).toList();
    if (tops.length == 1) wins[tops.single.month] = (wins[tops.single.month] ?? 0) + 1;
  }
  if (wins.isEmpty) return null;
  final best = wins.entries.reduce((a, b) => b.value > a.value ? b : a);
  if (best.value < 3) return null;
  final name = monthYear(2000, best.key).split(' ').first;
  final noun = switch (m) {
    Measure.spent => 'priciest month',
    Measure.cameIn => 'month with most money in',
    Measure.kept => 'best month',
    Measure.count => 'busiest month',
  };
  return best.value == years ? '$name is your $noun every year.' : '$name is your $noun in ${best.value} of $years years.';
}

/// "3.1 %" from permille.
String permilleText(int p) => '${p ~/ 10}${numberStyle.decimal}${p % 10} %';

/// Work time from tenths of an hour: "832 h", or "12.5 h" under 100 hours.
String hoursText(int tenths) =>
    tenths < 1000 ? '${tenths ~/ 10}${numberStyle.decimal}${tenths % 10} h' : '${groupInt((tenths + 5) ~/ 10)} h';

/// "Mar 2023 → today" / "Mar 2023 → Oct 2025 · ended", then the length and the payment count.
String projectSpanText(ProjectStats s) {
  String m(String d) => '${monthShort(d.substring(0, 7))} ${d.substring(0, 4)}';
  final span = '${m(s.first)} → ${s.ended ? m(s.last) : 'today'}';
  final y = s.months ~/ 12, mo = s.months % 12;
  final len = [
    if (y > 0) '$y ${y == 1 ? 'year' : 'years'}',
    if (mo > 0 || y == 0) '$mo ${mo == 1 ? 'month' : 'months'}',
  ].join(' ');
  return '$span${s.ended ? ' · ended' : ''} · $len · ${s.count} ${s.count == 1 ? 'payment' : 'payments'}';
}
