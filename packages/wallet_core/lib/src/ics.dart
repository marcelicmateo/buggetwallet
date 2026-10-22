/// iCalendar (`.ics`, RFC 5545) for future spending (§4.3): reading calendar events from an imported file or link,
/// and writing the planned costs as a calendar. Pure and web-safe; events are never stored or synced by core.
library;

import 'dart:convert';

import 'package:cryptography/dart.dart';

import 'bills.dart' show plannedCoverage;
import 'dates.dart';
import 'logs.dart';
import 'models.dart';
import 'planned.dart';

final _log = Logger('bw.ics');

/// One occurrence of a calendar event, read on this device (Android calendar or [parseIcs]).
class CalendarEvent {
  final String calendarId, uid, title;

  /// The occurrence's local date, `YYYY-MM-DD`.
  final String date;
  final String? notes;
  final bool allDay;
  const CalendarEvent(
      {required this.calendarId, required this.uid, required this.title, required this.date, this.notes, this.allDay = true});

  /// [calendarEventRef] of this occurrence: what a planned row stores as `sourceRef`.
  String get ref => calendarEventRef(calendarId: calendarId, uid: uid, title: title, date: date);
}

/// A stable reference to one occurrence of one event in one calendar: the first 32 hex characters of the SHA-256 of
/// calendar id, uid and date, so no raw calendar or event id is ever stored or synced. Calendar and event ids differ
/// per device and per import, so [calendarEventRef] uses this only for titles with no letters.
String calendarRef(String calendarId, String uid, String date) => _hashRef('bw-cal-v1\u0000$calendarId\u0000$uid\u0000$date');

/// The ref of one calendar event occurrence, the same on every device and from every source (Android calendar,
/// imported `.ics` file, `.ics` link of the same calendar): the first 32 hex characters of the SHA-256 of
/// `normalizeTitle(title)` and [date]. A title that normalizes to '' (no letters, e.g. `80 €`) falls back to
/// [calendarRef] (per calendar and device). No raw title or id is kept. Consequences: two events with the same
/// normalized title on the same day (amounts are stripped, so `Dentist 80 €` and `Dentist 90 €`) are one suggestion,
/// and renaming an event in the calendar makes it a new suggestion.
String calendarEventRef({required String calendarId, required String uid, required String title, required String date}) {
  final t = normalizeTitle(title);
  return t.isEmpty ? calendarRef(calendarId, uid, date) : _hashRef('bw-cal-v2\u0000$t\u0000$date');
}

String _hashRef(String text) {
  final bytes = const DartSha256().hashSync(utf8.encode(text)).bytes;
  return [for (final b in bytes.take(16)) b.toRadixString(16).padLeft(2, '0')].join();
}

/// What [parseIcs] read: the occurrences in range (sorted by date, then title, then uid), and how many events were
/// read only in part: an unsupported recurrence rule (first occurrence only), a missing or broken start date (dropped),
/// a file cut off inside an event (dropped).
class IcsParseResult {
  final List<CalendarEvent> events;
  final int unsupported;
  const IcsParseResult({this.events = const [], this.unsupported = 0});
}

/// Most periods a recurrence rule is stepped through (a daily rule over 270 years); beyond that it stops.
const _maxPeriods = 100000;

/// Most recurrence periods stepped through in one file (all events together), so a hostile or huge file cannot
/// freeze the caller (parseIcs runs on the UI isolate). Once spent, each later recurring event gives its first
/// occurrence in range only (if one is found within [_cheapPeriods] periods of the range start) and counts in
/// [IcsParseResult.unsupported].
const _stepBudget = 1000000;

/// Periods tried for the first in-range occurrence of an event once [_stepBudget] is spent (8 covers Feb 29 on a
/// yearly rule).
const _cheapPeriods = 8;

/// The recurrence steps left for one [parseIcs] call.
class _Budget {
  int left;
  _Budget(this.left);
}

/// Reads the `VEVENT`s of an iCalendar text: `UID`, `SUMMARY` (title), `DESCRIPTION` (notes), `DTSTART` (a date =
/// all-day; a date-time floating or with `TZID` = its wall-clock date, the `VTIMEZONE` is not needed; a UTC `…Z` time =
/// the date of [toLocal] applied to it, the UTC date when [toLocal] is null — the app passes `(t) => t.toLocal()`),
/// `RRULE` with `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY`, `INTERVAL`, `COUNT` (counted from `DTSTART`, also before [from]),
/// `UNTIL` (inclusive, compared by date), `BYDAY` (weekly and daily: weekdays; monthly: with or without an ordinal like
/// `2MO`/`-1FR`), `BYMONTHDAY` (monthly), `BYMONTH`/`BYMONTHDAY` on a yearly rule only when they repeat `DTSTART`;
/// dates a rule gives that do not exist (the 31st in a short month, Feb 29 outside leap years) are skipped (RFC 5545).
/// `EXDATE` removes occurrences, `RDATE` (dates) adds some, an event with `RECURRENCE-ID` replaces the occurrence it
/// names, `STATUS:CANCELLED` drops the event (or that occurrence). Any other rule gives the first occurrence only and
/// counts in [IcsParseResult.unsupported]. Only occurrences dated in [from, to] (inclusive) are returned. Folded lines
/// (CRLF or LF + space/tab), CR, LF or CRLF line ends and escaped text (`\,` `\;` `\\` `\n`) are handled; broken input
/// never throws. Logs counts only.
IcsParseResult parseIcs(String text,
    {required String calendarId, required String from, required String to, DateTime Function(DateTime utc)? toLocal}) {
  final t = PerfTimer('ics.parse');
  if (!_validIso(from) || !_validIso(to) || from.compareTo(to) > 0) return const IcsParseResult();
  final raw = <_RawEvent>[];
  var unsupported = 0;
  _RawEvent? cur;
  var depth = 0;
  for (final line in _unfold(text)) {
    final cl = _ContentLine.parse(line);
    if (cl == null) continue;
    if (cl.name == 'BEGIN') {
      if (cur != null) {
        depth++;
      } else if (cl.value.trim().toUpperCase() == 'VEVENT') {
        cur = _RawEvent();
        depth = 0;
      }
      continue;
    }
    if (cl.name == 'END') {
      if (cur == null) continue;
      if (depth > 0) {
        depth--;
      } else {
        raw.add(cur);
        cur = null;
      }
      continue;
    }
    if (cur == null || depth > 0) continue;
    cur.props.add(cl);
  }
  if (cur != null) unsupported++; // cut off inside an event

  final masters = <String, _Event>{};
  final overrides = <_Event>[];
  final out = <String, CalendarEvent>{};
  var n = 0;
  for (final r in raw) {
    final e = _Event.from(r, n++, toLocal);
    if (e == null) {
      unsupported++;
      continue;
    }
    if (e.recurrenceId != null) {
      overrides.add(e);
    } else {
      masters[e.uid] = e; // the same UID twice: the later one
    }
  }
  final replaced = <String, Set<String>>{};
  for (final o in overrides) {
    (replaced[o.uid] ??= {}).add(o.recurrenceId!);
  }
  void emit(_Event e, String date) {
    if (date.compareTo(from) < 0 || date.compareTo(to) > 0) return;
    out['${e.uid}\u0000$date'] =
        CalendarEvent(calendarId: calendarId, uid: e.uid, title: e.summary, date: date, notes: e.description, allDay: e.allDay);
  }

  final budget = _Budget(_stepBudget);
  for (final e in masters.values) {
    if (e.cancelled) continue;
    try {
      final (dates, ok) = _expand(e, from, to, toLocal, budget);
      if (!ok) unsupported++;
      final skip = replaced[e.uid] ?? const {};
      for (final d in dates) {
        if (!skip.contains(d)) emit(e, d);
      }
    } catch (err, st) {
      unsupported++;
      logError(_log, 'ics.eventFailed', err, st);
    }
  }
  for (final o in overrides) {
    if (!o.cancelled) emit(o, o.start);
  }
  final events = out.values.toList()
    ..sort((a, b) {
      var c = a.date.compareTo(b.date);
      if (c == 0) c = a.title.compareTo(b.title);
      return c != 0 ? c : a.uid.compareTo(b.uid);
    });
  t.done({'vevents': raw.length, 'events': events.length, 'unsupported': unsupported, 'budgetSpent': budget.left <= 0});
  return IcsParseResult(events: events, unsupported: unsupported);
}

bool _validIso(String s) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s) && isoDate(parseIso(s)) == s;

/// Content lines with folds joined: a line starting with a space or tab continues the previous one (the first
/// character is dropped). Any of CRLF, LF, CR ends a line; a leading BOM is dropped.
List<String> _unfold(String text) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final out = <String>[];
  StringBuffer? cur; // the line being joined (linear: a long folded value is never copied once per fold)
  for (final l in text.split(RegExp(r'\r\n|\n|\r'))) {
    if ((l.startsWith(' ') || l.startsWith('\t')) && cur != null) {
      cur.write(l.substring(1));
    } else {
      if (cur != null) out.add(cur.toString());
      cur = StringBuffer(l);
    }
  }
  if (cur != null) out.add(cur.toString());
  return out;
}

class _ContentLine {
  final String name;
  final Map<String, String> params;
  final String value;
  _ContentLine(this.name, this.params, this.value);

  /// `NAME;P=V;P2="a:b":value`; null for a line without a name or `:`.
  static _ContentLine? parse(String line) {
    var quoted = false;
    var colon = -1;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') quoted = !quoted;
      if (c == ':' && !quoted) {
        colon = i;
        break;
      }
    }
    if (colon <= 0) return null;
    final head = line.substring(0, colon).split(';');
    final name = head.first.trim().toUpperCase();
    if (name.isEmpty) return null;
    final params = <String, String>{};
    for (final p in head.skip(1)) {
      final eq = p.indexOf('=');
      if (eq > 0) params[p.substring(0, eq).trim().toUpperCase()] = p.substring(eq + 1).replaceAll('"', '');
    }
    return _ContentLine(name, params, line.substring(colon + 1));
  }
}

class _RawEvent {
  final props = <_ContentLine>[];
}

/// Text value with RFC 5545 escapes undone.
String _unescape(String s) {
  if (!s.contains(r'\')) return s;
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final n = s[++i];
      sb.write(n == 'n' || n == 'N' ? '\n' : n);
    } else {
      sb.write(c);
    }
  }
  return sb.toString();
}

/// A DATE or DATE-TIME value → (local date, is a date only); null if broken.
(String, bool)? _parseStamp(String v, Map<String, String> params, DateTime Function(DateTime)? toLocal) {
  v = v.trim();
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$').firstMatch(v);
  if (m == null) return null;
  final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
  if (y < 1000 || mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final day = DateTime.utc(y, mo, d);
  if (day.month != mo) return null; // 2026-02-30
  if (m.group(4) == null) return (isoDate(day), true);
  final h = int.parse(m.group(4)!), mi = int.parse(m.group(5)!), s = int.parse(m.group(6) ?? '0');
  if (h > 24 || mi > 59 || s > 60) return null;
  final dateOnly = params['VALUE']?.toUpperCase() == 'DATE';
  if (m.group(7) != null && toLocal != null) {
    final local = toLocal(DateTime.utc(y, mo, d, h, mi, s));
    return (isoDate(DateTime.utc(local.year, local.month, local.day)), dateOnly);
  }
  return (isoDate(day), dateOnly);
}

class _Event {
  final String uid, summary, start;
  final String? description, recurrenceId;
  final bool allDay, cancelled;
  final Map<String, String>? rule; // null = no RRULE
  final bool ruleBroken;
  final Set<String> exdates, rdates;

  _Event(this.uid, this.summary, this.description, this.start, this.allDay, this.cancelled, this.rule, this.ruleBroken, this.exdates,
      this.rdates, this.recurrenceId);

  static _Event? from(_RawEvent r, int index, DateTime Function(DateTime)? toLocal) {
    String? uid, summary, description, recurrenceId;
    (String, bool)? start;
    Map<String, String>? rule;
    var ruleBroken = false, cancelled = false;
    final ex = <String>{}, rd = <String>{};
    for (final p in r.props) {
      switch (p.name) {
        case 'UID':
          uid = p.value.trim();
        case 'SUMMARY':
          summary = _unescape(p.value);
        case 'DESCRIPTION':
          description = _unescape(p.value);
        case 'DTSTART':
          start = _parseStamp(p.value, p.params, toLocal);
        case 'RECURRENCE-ID':
          recurrenceId = _parseStamp(p.value, p.params, toLocal)?.$1;
        case 'STATUS':
          cancelled = p.value.trim().toUpperCase() == 'CANCELLED';
        case 'RRULE':
          if (rule != null) ruleBroken = true; // two rules: the first one only, not fully supported
          rule ??= {
            for (final part in p.value.split(';'))
              if (part.contains('='))
                part.substring(0, part.indexOf('=')).trim().toUpperCase(): part.substring(part.indexOf('=') + 1).trim(),
          };
        case 'EXDATE' || 'RDATE':
          if (p.params['VALUE']?.toUpperCase() == 'PERIOD') {
            ruleBroken = true;
            break;
          }
          for (final v in p.value.split(',')) {
            final s = _parseStamp(v, p.params, toLocal);
            if (s != null) (p.name == 'EXDATE' ? ex : rd).add(s.$1);
          }
      }
    }
    if (start == null) return null;
    final id = uid == null || uid.isEmpty ? 'bw-nouid-$index' : uid;
    return _Event(id, summary ?? '', description, start.$1, start.$2, cancelled, rule, ruleBroken, ex, rd, recurrenceId);
  }
}

const _weekdays = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};

/// One `BYDAY` entry: weekday 1..7 and ordinal (0 = every one in the period).
typedef _ByDay = ({int weekday, int ordinal});

DateTime _d(String iso) => parseIso(iso);

/// The dates of [e] (DTSTART, the rule's dates, RDATEs; EXDATEs removed) up to [to], and whether every part was
/// supported (false = DTSTART only, plus RDATEs). A rule met with [budget] already spent gives the event's first
/// occurrence in [from, to] only (false); one that spends the rest of it keeps the dates found so far (false).
(List<String>, bool) _expand(_Event e, String from, String to, DateTime Function(DateTime)? toLocal, _Budget budget) {
  final dates = <String>{e.start, ...e.rdates};
  var ok = !e.ruleBroken;
  final rule = e.rule;
  if (rule != null) {
    final r = _Rule.parse(rule, e.start, toLocal);
    if (r == null) {
      ok = false;
    } else if (budget.left <= 0) {
      final first = r.firstInRange(e.start, from, to);
      if (first != null) dates.add(first);
      final inRange = [
        for (final d in dates)
          if (!e.exdates.contains(d) && d.compareTo(from) >= 0 && d.compareTo(to) <= 0) d
      ]..sort();
      return (inRange.take(1).toList(), false);
    } else {
      final (more, done) = r.dates(e.start, from, to, budget);
      dates.addAll(more);
      if (!done) ok = false;
    }
  }
  final list = dates.where((d) => !e.exdates.contains(d)).toList()..sort();
  return (list, ok);
}

class _Rule {
  final String freq;
  final int interval;
  final int? count;
  final String? until;
  final List<_ByDay> byDay;
  final List<int> byMonthDay;

  _Rule(this.freq, this.interval, this.count, this.until, this.byDay, this.byMonthDay);

  static const _known = {'FREQ', 'INTERVAL', 'COUNT', 'UNTIL', 'BYDAY', 'BYMONTHDAY', 'BYMONTH', 'WKST'};

  /// null = not supported (the event then gives its first occurrence only).
  static _Rule? parse(Map<String, String> m, String start, DateTime Function(DateTime)? toLocal) {
    if (m.keys.any((k) => !_known.contains(k))) return null;
    final freq = (m['FREQ'] ?? '').toUpperCase();
    if (!const {'DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'}.contains(freq)) return null;
    final interval = m['INTERVAL'] == null ? 1 : int.tryParse(m['INTERVAL']!);
    if (interval == null || interval < 1 || interval > 10000) return null;
    int? count;
    if (m['COUNT'] != null) {
      count = int.tryParse(m['COUNT']!);
      if (count == null || count < 1) return null;
    }
    String? until;
    if (m['UNTIL'] != null) {
      until = _parseStamp(m['UNTIL']!, const {}, toLocal)?.$1;
      if (until == null) return null;
    }
    final byDay = <_ByDay>[];
    if (m['BYDAY'] != null) {
      for (final part in m['BYDAY']!.split(',')) {
        final x = RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$').firstMatch(part.trim().toUpperCase());
        if (x == null) return null;
        final ord = x.group(1) == null ? 0 : int.parse(x.group(1)!);
        if (ord.abs() > 5) return null;
        byDay.add((weekday: _weekdays[x.group(2)!]!, ordinal: ord));
      }
      if (freq == 'YEARLY') return null;
      if (freq != 'MONTHLY' && byDay.any((b) => b.ordinal != 0)) return null;
    }
    final byMonthDay = <int>[];
    if (m['BYMONTHDAY'] != null) {
      for (final part in m['BYMONTHDAY']!.split(',')) {
        final v = int.tryParse(part.trim());
        if (v == null || v == 0 || v.abs() > 31) return null;
        byMonthDay.add(v);
      }
    }
    final s = _d(start);
    if (m['BYMONTH'] != null) {
      // Only a yearly rule repeating DTSTART's month (and day) is understood.
      if (freq != 'YEARLY' || int.tryParse(m['BYMONTH']!.trim()) != s.month) return null;
    }
    if (byMonthDay.isNotEmpty) {
      if (freq == 'YEARLY') {
        if (byMonthDay.length != 1 || byMonthDay.single != s.day) return null;
        byMonthDay.clear();
      } else if (freq != 'MONTHLY' || byDay.isNotEmpty) {
        return null;
      }
    }
    return _Rule(freq, interval, count, until, byDay, byMonthDay);
  }

  /// The candidate dates of period [p] (0 = the one holding DTSTART), sorted.
  List<DateTime> _period(DateTime s, int p) {
    switch (freq) {
      case 'DAILY':
        final d = DateTime.utc(s.year, s.month, s.day + p * interval);
        return byDay.isEmpty || byDay.any((b) => b.weekday == d.weekday) ? [d] : const [];
      case 'WEEKLY':
        final monday = DateTime.utc(s.year, s.month, s.day - (s.weekday - 1) + 7 * interval * p);
        final days = byDay.isEmpty ? [s.weekday] : ({for (final b in byDay) b.weekday}.toList()..sort());
        return [for (final w in days) DateTime.utc(monday.year, monday.month, monday.day + w - 1)];
      case 'MONTHLY':
        final first = DateTime.utc(s.year, s.month + p * interval, 1);
        final len = DateTime.utc(first.year, first.month + 1, 0).day;
        final out = <int>{};
        if (byDay.isNotEmpty) {
          for (final b in byDay) {
            final firstW = 1 + (b.weekday - first.weekday + 7) % 7; // first such weekday
            final all = [for (var d = firstW; d <= len; d += 7) d];
            if (b.ordinal == 0) {
              out.addAll(all);
            } else {
              final i = b.ordinal > 0 ? b.ordinal - 1 : all.length + b.ordinal;
              if (i >= 0 && i < all.length) out.add(all[i]);
            }
          }
        } else {
          for (final md in byMonthDay.isEmpty ? [s.day] : byMonthDay) {
            final d = md > 0 ? md : len + md + 1;
            if (d >= 1 && d <= len) out.add(d); // a day the month does not have is skipped
          }
        }
        return [for (final d in out.toList()..sort()) DateTime.utc(first.year, first.month, d)];
      default: // YEARLY
        final y = s.year + p * interval;
        final d = DateTime.utc(y, s.month, s.day);
        return d.month == s.month ? [d] : const []; // Feb 29 outside leap years is skipped
    }
  }

  /// The first period that can still reach [from] when no COUNT has to be counted from DTSTART.
  int _firstPeriod(DateTime s, String from) {
    if (count != null) return 0;
    final f = _d(from);
    if (!f.isAfter(s)) return 0;
    final periods = switch (freq) {
      'DAILY' => f.difference(s).inDays ~/ interval,
      'WEEKLY' => f.difference(s).inDays ~/ (7 * interval),
      'MONTHLY' => ((f.year - s.year) * 12 + f.month - s.month) ~/ interval,
      _ => (f.year - s.year) ~/ interval,
    };
    return periods > 1 ? periods - 1 : 0;
  }

  /// The first possible day of period [p] (periods only move forward).
  DateTime _periodStart(DateTime s, int p) => switch (freq) {
        'MONTHLY' => DateTime.utc(s.year, s.month + p * interval, 1),
        'YEARLY' => DateTime.utc(s.year + p * interval, 1, 1),
        'WEEKLY' => DateTime.utc(s.year, s.month, s.day - (s.weekday - 1) + 7 * interval * p),
        _ => DateTime.utc(s.year, s.month, s.day + p * interval),
      };

  /// The rule's dates after DTSTART up to [to] (and UNTIL, COUNT incl. DTSTART itself), and whether the rule was
  /// stepped to its end (false = [budget] ran out first: the dates found so far). Each period takes one step.
  (List<String>, bool) dates(String start, String from, String to, _Budget budget) {
    final s = _d(start);
    final end = _d(until != null && until!.compareTo(to) < 0 ? until! : to);
    final out = <String>[];
    var n = 1; // DTSTART is the first occurrence
    for (var p = _firstPeriod(s, from), steps = 0; steps < _maxPeriods; p++, steps++) {
      if (budget.left <= 0) return (out, false);
      budget.left--;
      // The period's first possible day past the end stops the loop.
      if (_periodStart(s, p).isAfter(end)) break;
      for (final d in _period(s, p)) {
        if (!d.isAfter(s)) continue;
        if (d.isAfter(end)) return (out, true);
        if (count != null && n >= count!) return (out, true);
        n++;
        out.add(isoDate(d));
      }
    }
    return (out, true);
  }

  /// Once the step budget is spent: the rule's first date in [from, to] (after DTSTART, before UNTIL) found within
  /// [_cheapPeriods] periods of [from], or null. A rule with COUNT gives null (its count can only be known by stepping
  /// from DTSTART).
  String? firstInRange(String start, String from, String to) {
    if (count != null) return null;
    final s = _d(start), f = _d(from);
    final end = _d(until != null && until!.compareTo(to) < 0 ? until! : to);
    for (var p = _firstPeriod(s, from), i = 0; i < _cheapPeriods; p++, i++) {
      if (_periodStart(s, p).isAfter(end)) return null;
      for (final d in _period(s, p)) {
        if (!d.isAfter(s) || d.isBefore(f)) continue;
        return d.isAfter(end) ? null : isoDate(d);
      }
    }
    return null;
  }
}

/// [cents] as euros the way [amountFromText] reads them back: `80,00 €`, `1.250,50 €`.
String euroText(int cents) {
  final abs = cents.abs();
  final whole = (abs ~/ 100).toString();
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write('.');
    grouped.write(whole[i]);
  }
  return '${cents < 0 ? '-' : ''}$grouped,${(abs % 100).toString().padLeft(2, '0')} €';
}

String _escape(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll(';', r'\;')
    .replaceAll(',', r'\,')
    .replaceAll('\r\n', r'\n')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', '');

/// [line] folded at 75 octets (UTF-8, never inside a character), CRLF after each piece.
void _writeFolded(StringBuffer sb, String line) {
  var bytes = 0;
  for (final r in line.runes) {
    final ch = String.fromCharCode(r);
    final len = utf8.encode(ch).length;
    if (bytes + len > 75) {
      sb.write('\r\n ');
      bytes = 1; // the leading space counts
    }
    sb.write(ch);
    bytes += len;
  }
  sb.write('\r\n');
}

String _compact(String iso) => iso.replaceAll('-', '');

/// The planned costs as an iCalendar text for other calendar apps: one all-day `VEVENT` per planned cost with an
/// amount that is open or paid (not skipped, not deleted, not a bill's row whose covering recurring occurrence, [plannedCoverage], is in range
/// too or is the cycle just paid or skipped)
/// and per occurrence of a confirmed bill ([billOccurrences]),
/// dated in [from, to]. `SUMMARY` = `<title> · <amount>` ([euroText], so [amountFromText] reads the amount back),
/// stable UIDs (`planned-<id>@budget-wallet`, `bill-<id>-<yyyymmdd>@budget-wallet`), `DTSTAMP` from [from] so the same
/// data gives the same text. CRLF, folded at 75 octets, text escaped.
String plannedIcs(List<PlannedCost> planned, List<RecurringBill> bills, {required String from, required String to}) {
  final rows = <(String uid, String date, String title, int amount)>[];
  if (_validIso(from) && _validIso(to) && from.compareTo(to) <= 0) {
    bool inRange(String d) => d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
    for (final p in planned) {
      if (p.deleted || p.status == PlannedStatus.skipped || p.amount == null) continue;
      if (plannedCoverage(p, bills) case final c? when c.occurrence == null || inRange(c.occurrence!)) continue;
      if (p.date.compareTo(from) < 0 || p.date.compareTo(to) > 0 || !_validIso(p.date)) continue;
      rows.add(('planned-${p.id}@budget-wallet', p.date, p.title, p.amount!));
    }
    for (final b in bills) {
      if (!b.confirmed) continue;
      for (final d in billOccurrences(b, from, to)) {
        rows.add(('bill-${b.id}-${_compact(d)}@budget-wallet', d, b.label, b.expectedAmount));
      }
    }
  }
  rows.sort((a, b) {
    final c = a.$2.compareTo(b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final sb = StringBuffer();
  for (final l in ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Budget Wallet//Planned costs//EN', 'CALSCALE:GREGORIAN']) {
    _writeFolded(sb, l);
  }
  final stamp = '${_validIso(from) ? _compact(from) : '19700101'}T000000Z';
  for (final (uid, date, title, amount) in rows) {
    for (final l in [
      'BEGIN:VEVENT',
      'UID:${_escape(uid)}',
      'DTSTAMP:$stamp',
      'DTSTART;VALUE=DATE:${_compact(date)}',
      'DTEND;VALUE=DATE:${_compact(addDays(date, 1))}',
      'SUMMARY:${_escape(title.isEmpty ? euroText(amount) : '$title · ${euroText(amount)}')}',
      'TRANSP:TRANSPARENT',
      'END:VEVENT',
    ]) {
      _writeFolded(sb, l);
    }
  }
  _writeFolded(sb, 'END:VCALENDAR');
  logEvent(_log, Level.INFO, 'ics.export', {'events': rows.length});
  return sb.toString();
}
