// TEMPORARY SHIM (stage F3). Stands in for the core API of docs/context/FUTURE_SPENDING_API.md until F1 lands in
// packages/wallet_core. THE LEAD DELETES THIS FILE AT MERGE:
//   git rm app/lib/src/future_shim.dart && sed -i "/future_shim.dart/d" $(grep -rl future_shim.dart app/lib app/test app/integration_test app/tool)
// and then replaces the lines marked `SHIM:` in the app (controller_future.dart, 3 places; controller.dart `period()` gets
// `planned: plannedOpen()`). Same names and signatures as the API doc; a simplified behaviour (no RRULE expansion in
// [parseIcs], planned costs kept in a device-local value instead of synced rows). Never use it for real data.
import 'dart:convert';

import 'package:wallet_core/wallet_core.dart';

enum PlannedSource { manual, calendar, bill }

enum PlannedStatus { open, paid, skipped }

class PlannedCost {
  final String id, title, date;
  final int? amount;
  final String? category, sourceRef, paidTx;
  final PlannedSource source;
  final PlannedStatus status;
  const PlannedCost({
    required this.id,
    required this.title,
    required this.date,
    this.amount,
    this.category,
    this.sourceRef,
    this.paidTx,
    this.source = PlannedSource.manual,
    this.status = PlannedStatus.open,
  });

  bool get deleted => false;
  bool get isOpen => status == PlannedStatus.open && !deleted;

  /// A fixed-category cost (Rent, Loan, Bills & subscriptions): listed, but the plan already counts it, so it reserves nothing.
  bool get coveredByPlan => category != null && kindOf(category!) == Kind.fixed;

  PlannedCost copyWith({String? title, String? date, int? amount, String? category, String? paidTx, PlannedStatus? status}) => PlannedCost(
      id: id,
      title: title ?? this.title,
      date: date ?? this.date,
      amount: amount ?? this.amount,
      category: category ?? this.category,
      sourceRef: sourceRef,
      paidTx: paidTx ?? this.paidTx,
      source: source,
      status: status ?? this.status);

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'date': date,
        'amount': amount,
        'category': category,
        'sourceRef': sourceRef,
        'paidTx': paidTx,
        'source': source.name,
        'status': status.name,
      };

  static PlannedCost fromJson(Map<String, Object?> m) => PlannedCost(
      id: m['id'] as String,
      title: m['title'] as String,
      date: m['date'] as String,
      amount: m['amount'] as int?,
      category: m['category'] as String?,
      sourceRef: m['sourceRef'] as String?,
      paidTx: m['paidTx'] as String?,
      source: PlannedSource.values.byName(m['source'] as String),
      status: PlannedStatus.values.byName(m['status'] as String));
}

const _store = 'shimPlanned';

List<PlannedCost> _readAll(WalletRepo r) {
  final raw = r.localValue(_store);
  if (raw == null) return const [];
  return [for (final m in jsonDecode(raw) as List) PlannedCost.fromJson((m as Map).cast<String, Object?>())];
}

void _writeAll(WalletRepo r, List<PlannedCost> xs) => r.setLocalValue(_store, jsonEncode([for (final x in xs) x.toJson()]));

/// The repo methods of the API doc. Real members of [WalletRepo] with the same names take precedence over these.
extension ShimPlannedRepo on WalletRepo {
  List<PlannedCost> plannedCosts({bool includeClosed = false}) =>
      [for (final p in _readAll(this)) if (includeClosed || p.status == PlannedStatus.open) p];

  String addPlanned(
      {required String title,
      required String date,
      int? amount,
      String? category,
      PlannedSource source = PlannedSource.manual,
      String? sourceRef}) {
    final all = _readAll(this);
    final id = 'pl-${all.length + 1}-${date.replaceAll('-', '')}';
    _writeAll(this, [
      ...all,
      PlannedCost(id: id, title: title, date: date, amount: amount, category: category, source: source, sourceRef: sourceRef),
    ]);
    return id;
  }

  void _edit(String id, PlannedCost Function(PlannedCost) f) =>
      _writeAll(this, [for (final p in _readAll(this)) p.id == id ? f(p) : p]);

  void updatePlanned(String id, {String? title, String? date, int? amount, String? category}) =>
      _edit(id, (p) => p.copyWith(title: title, date: date, amount: amount, category: category));
  void markPlannedPaid(String id, String txId) => _edit(id, (p) => p.copyWith(paidTx: txId, status: PlannedStatus.paid));
  void skipPlanned(String id) => _edit(id, (p) => p.copyWith(status: PlannedStatus.skipped));
  void deletePlanned(String id) => _writeAll(this, [for (final p in _readAll(this)) if (p.id != id) p]);
  void dismissCalendarEvent(String sourceRef, String date) {
    final all = _readAll(this);
    _writeAll(this, [
      ...all,
      PlannedCost(
          id: 'pl-d${all.length + 1}',
          title: '',
          date: date,
          source: PlannedSource.calendar,
          sourceRef: sourceRef,
          status: PlannedStatus.skipped),
    ]);
  }
}

/// The heads-up settings (synced in core; here device-local so the screens work).
int shimHeadsUpCents(WalletRepo r) => int.tryParse(r.localValue('shimHeadsUpCents') ?? '') ?? 10000;
int shimHeadsUpDays(WalletRepo r) => int.tryParse(r.localValue('shimHeadsUpDays') ?? '') ?? 3;
void shimSaveHeadsUp(WalletRepo r, int cents, int days) {
  r.setLocalValue('shimHeadsUpCents', '$cents');
  r.setLocalValue('shimHeadsUpDays', '$days');
}

// ---------- calendar events ----------
String calendarRef(String calendarId, String uid, String date) {
  // Not a real hash; the core one is a SHA-256 prefix.
  var a = 0x811c9dc5, b = 0x01000193;
  for (final u in '$calendarId|$uid|$date'.codeUnits) {
    a = ((a ^ u) * 0x01000193) & 0xffffffff;
    b = ((b + u) * 0x9e3779b1) & 0xffffffff;
  }
  return a.toRadixString(16).padLeft(8, '0') * 2 + b.toRadixString(16).padLeft(8, '0') * 2;
}

class CalendarEvent {
  final String calendarId, uid, title, date;
  final String? notes;
  final bool allDay;
  const CalendarEvent(
      {required this.calendarId, required this.uid, required this.title, required this.date, this.notes, this.allDay = true});
  String get ref => calendarRef(calendarId, uid, date);
}

class IcsParseResult {
  final List<CalendarEvent> events;
  final int unsupported;
  const IcsParseResult(this.events, this.unsupported);
}

IcsParseResult parseIcs(String text,
    {required String calendarId, required String from, required String to, DateTime Function(DateTime)? toLocal}) {
  final lines = <String>[];
  for (final l in text.split(RegExp(r'\r?\n'))) {
    if ((l.startsWith(' ') || l.startsWith('\t')) && lines.isNotEmpty) {
      lines[lines.length - 1] += l.substring(1);
    } else {
      lines.add(l);
    }
  }
  final events = <CalendarEvent>[];
  var unsupported = 0;
  Map<String, String>? cur;
  for (final l in lines) {
    if (l == 'BEGIN:VEVENT') {
      cur = {};
    } else if (l == 'END:VEVENT' && cur != null) {
      final start = cur['DTSTART'];
      if (cur.containsKey('RRULE')) unsupported++;
      if (start != null && start.length >= 8) {
        final d = '${start.substring(0, 4)}-${start.substring(4, 6)}-${start.substring(6, 8)}';
        if (d.compareTo(from) >= 0 && d.compareTo(to) <= 0) {
          events.add(CalendarEvent(
              calendarId: calendarId,
              uid: cur['UID'] ?? cur['SUMMARY'] ?? d,
              title: _unescape(cur['SUMMARY'] ?? ''),
              notes: cur['DESCRIPTION'] == null ? null : _unescape(cur['DESCRIPTION']!),
              date: d,
              allDay: !start.contains('T')));
        }
      }
      cur = null;
    } else if (cur != null) {
      final i = l.indexOf(':');
      if (i > 0) cur.putIfAbsent(l.substring(0, i).split(';').first, () => l.substring(i + 1));
    }
  }
  return IcsParseResult(events, unsupported);
}

String _unescape(String s) => s.replaceAll(r'\n', '\n').replaceAll(r'\,', ',').replaceAll(r'\;', ';').replaceAll(r'\\', r'\');

// ---------- suggestions and the Upcoming list ----------
int? amountFromText(String text) {
  final found = <int>{};
  final re = RegExp(r'(?:€\s*(\d+(?:[.,]\d{1,2})?)|(\d+(?:[.,]\d{1,2})?)\s*(?:€|EUR\b))', caseSensitive: false);
  for (final m in re.allMatches(text)) {
    final raw = (m.group(1) ?? m.group(2))!.replaceAll(',', '.');
    found.add((double.parse(raw) * 100).round());
  }
  return found.length == 1 ? found.first : null;
}

String normalizeTitle(String title) =>
    title.toLowerCase().replaceAll(RegExp(r'[\d.,]+\s*(€|eur)?'), ' ').replaceAll('€', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

enum UpcomingKind { planned, bill, suggestion }

class UpcomingItem {
  final UpcomingKind kind;
  final String key, date, title;
  final int? amount, suggested;
  final String? suggestedFrom, category;
  final PlannedCost? planned;
  final RecurringBill? bill;
  final CalendarEvent? event;
  const UpcomingItem({
    required this.kind,
    required this.key,
    required this.date,
    required this.title,
    this.amount,
    this.suggested,
    this.suggestedFrom,
    this.category,
    this.planned,
    this.bill,
    this.event,
  });
}

List<UpcomingItem> upcoming({
  required List<PlannedCost> planned,
  required List<RecurringBill> bills,
  required List<CalendarEvent> events,
  required String from,
  required String to,
}) {
  bool inRange(String d) => d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
  final out = <UpcomingItem>[];
  for (final p in planned) {
    if (p.status == PlannedStatus.open && inRange(p.date)) {
      out.add(UpcomingItem(
          kind: UpcomingKind.planned,
          key: 'p:${p.id}',
          date: p.date,
          title: p.title,
          amount: p.amount,
          category: p.category,
          planned: p));
    }
  }
  for (final b in bills.where((b) => b.status == 'confirmed')) {
    for (var d = b.nextDue; d.compareTo(to) <= 0; d = addDays(d, b.intervalDays)) {
      if (inRange(d)) {
        out.add(UpcomingItem(
            kind: UpcomingKind.bill,
            key: 'b:${b.id}@$d',
            date: d,
            title: b.label.isNotEmpty ? b.label : b.payee,
            amount: b.expectedAmount,
            category: b.category,
            bill: b));
      }
    }
  }
  final refs = {for (final p in planned) if (p.sourceRef != null) p.sourceRef};
  for (final e in events.where((e) => inRange(e.date) && !refs.contains(e.ref))) {
    var s = amountFromText('${e.title} ${e.notes ?? ''}');
    var how = 'title';
    if (s == null) {
      final norm = normalizeTitle(e.title);
      s = planned.where((p) => p.amount != null && normalizeTitle(p.title) == norm && norm.isNotEmpty).firstOrNull?.amount;
      how = 'earlier';
    }
    out.add(UpcomingItem(
        kind: UpcomingKind.suggestion,
        key: 'e:${e.ref}',
        date: e.date,
        title: e.title,
        suggested: s,
        suggestedFrom: s == null ? null : how,
        event: e));
  }
  out.sort((a, b) {
    final c = a.date.compareTo(b.date);
    return c != 0 ? c : a.title.compareTo(b.title);
  });
  return out;
}

int _dayDiff(String a, String b) => parseIso(b).difference(parseIso(a)).inDays;

List<CategorizedTx> paidCandidates(PlannedCost p, List<CategorizedTx> txs, List<PlannedCost> all) {
  if (p.category == null) return const [];
  final taken = {for (final x in all) if (x.paidTx != null) x.paidTx};
  final out = [
    for (final t in txs)
      if (t.amount < 0 && t.category == p.category && _dayDiff(p.date, t.date).abs() <= 3 && !taken.contains(t.tx.id)) t
  ]..sort((a, b) => _dayDiff(p.date, a.date).abs().compareTo(_dayDiff(p.date, b.date).abs()));
  return out;
}

class HeadsUp {
  final UpcomingItem item;
  final int daysLeft;
  const HeadsUp(this.item, this.daysLeft);
}

List<HeadsUp> headsUps(List<UpcomingItem> items, String today, {required int thresholdCents, required int days}) => [
      for (final i in items)
        if (i.amount != null &&
            i.kind != UpcomingKind.suggestion &&
            i.amount! >= thresholdCents &&
            i.date.compareTo(today) >= 0 &&
            _dayDiff(today, i.date) <= days)
          HeadsUp(i, _dayDiff(today, i.date))
    ];

String plannedIcs(List<PlannedCost> planned, List<RecurringBill> bills, {required String from, required String to}) {
  final b = StringBuffer('BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Budget Wallet//Planned costs//EN\r\n');
  for (final p in planned) {
    if (p.status != PlannedStatus.open || p.amount == null || p.date.compareTo(from) < 0 || p.date.compareTo(to) > 0) continue;
    final d = p.date.replaceAll('-', '');
    b.write('BEGIN:VEVENT\r\nUID:${p.id}@budget-wallet\r\nDTSTAMP:${d}T000000Z\r\nDTSTART;VALUE=DATE:$d\r\n'
        'SUMMARY:${p.title} · ${(p.amount! / 100).toStringAsFixed(2)} €\r\nEND:VEVENT\r\n');
  }
  b.write('END:VCALENDAR\r\n');
  return b.toString();
}

/// Open planned costs with an amount dated [today] .. before [end] (payday) that the plan does not already count.
List<PlannedCost> duePlanned(List<PlannedCost> planned, String today, String end) => [
      for (final p in planned)
        if (p.isOpen && p.amount != null && !p.coveredByPlan && p.date.compareTo(today) >= 0 && p.date.compareTo(end) < 0) p
    ];

/// Free-text search over planned costs (the real one is `SearchResult.planned` from `searchAll(..., planned:)`).
List<PlannedCost> shimSearchPlanned(String q, List<PlannedCost> all) {
  final f = q.trim().toLowerCase();
  if (f.length < 2) return const [];
  return [for (final p in all) if (p.title.toLowerCase().contains(f) || (p.category ?? '').toLowerCase().contains(f)) p];
}
