# Future spending — core API (stage F, spec DESIGN_DECISIONS §4.3 "Approved 2026-10-22")

Fixed by the lead so core (F1), tests (F2) and UI (F3) build in parallel. Additions are fine; renames are not.
Amounts are cents (positive = a cost), dates `YYYY-MM-DD`. Nothing here logs titles, notes, amounts or calendar names.

## Data (synced entity `planned`, schema 6)
```dart
enum PlannedSource { manual, calendar, bill }      // bill: reserved for the bills database (§4.2)
enum PlannedStatus { open, paid, skipped }
class PlannedCost {
  final String id, title, date;                    // title may be '' for a dismissed calendar event
  final int? amount;                               // null = no confirmed amount: never reserved
  final String? category, sourceRef, paidTx;       // sourceRef = calendarRef(...) for calendar rows
  final PlannedSource source;
  final PlannedStatus status;
}
```
Repo (all writes through `_write`):
```dart
List<PlannedCost> plannedCosts({bool includeClosed = false});   // closed = paid, skipped or deleted
String addPlanned({required String title, required String date, int? amount, String? category,
    PlannedSource source = PlannedSource.manual, String? sourceRef}); // returns the new id
void updatePlanned(String id, {String? title, String? date, int? amount, String? category});
void markPlannedPaid(String id, String txId);      // the owner picked the transaction
void skipPlanned(String id);
void deletePlanned(String id);
/// "No cost" on a calendar suggestion: a synced row {source: calendar, sourceRef, status: skipped, title: ''}, so no
/// device suggests that event again. Stores no title.
void dismissCalendarEvent(String sourceRef, String date);
```

## Calendar events (device-local, never synced or stored by core)
```dart
class CalendarEvent {
  final String calendarId, uid, title, date;       // date = the occurrence's local date
  final String? notes;
  final bool allDay;
  String get ref => calendarRef(calendarId, uid, date);
}
String calendarRef(String calendarId, String uid, String date);   // hex SHA-256 prefix (32), no raw ids kept
class IcsParseResult { final List<CalendarEvent> events; final int unsupported; }
/// VEVENT with DTSTART (date or date-time, TZID/UTC/floating), SUMMARY, DESCRIPTION, UID; RRULE FREQ=DAILY|WEEKLY|
/// MONTHLY|YEARLY with INTERVAL, COUNT, UNTIL, BYDAY (weekly; monthly with ordinal like 2MO/-1FR), EXDATE.
/// Other rules: the first occurrence only, counted in `unsupported`. Occurrences in [from, to] only.
IcsParseResult parseIcs(String text, {required String calendarId, required String from, required String to});
```

## Suggestions and the Upcoming list
```dart
int? amountFromText(String text);  // '80 €', '€80', '80 EUR', '80,00 €', '1.250,00 €', '1,250.00 €', '80.5€' → cents;
                                   // null if none or ambiguous (two different amounts)
String normalizeTitle(String title); // folded, lower case, digits and amounts removed, single spaces
enum UpcomingKind { planned, bill, suggestion }
class UpcomingItem {
  final UpcomingKind kind;
  final String key, date, title;   // key: 'p:<id>' | 'b:<id>' | 'e:<ref>'
  final int? amount;               // counted amount (planned with amount, confirmed bill expected amount)
  final int? suggested;            // suggestion only
  final String? suggestedFrom;     // 'title' | 'earlier'  (an earlier confirmed planned cost with the same normalizeTitle)
  final String? category;
  final PlannedCost? planned; final RecurringBill? bill; final CalendarEvent? event;
}
/// Planned (open), confirmed recurring bills (virtual occurrences, `coveredByPlan` ones included but marked by their
/// bill) and calendar events not yet stored (no planned row with the same sourceRef), dated [from, to], sorted by date
/// then title. A calendar event whose ref has a planned row (any status) is never listed twice.
List<UpcomingItem> upcoming({required List<PlannedCost> planned, required List<RecurringBill> bills,
    required List<CalendarEvent> events, required String from, required String to});
/// "Paid by this?" candidates for an open planned cost: expenses of the same category within date ±3 days that are not
/// already some planned cost's paidTx, closest date first. Never by amount alone; amount only sorts ties.
List<CategorizedTx> paidCandidates(PlannedCost p, List<CategorizedTx> txs, List<PlannedCost> all);
```

## Safe to spend
`computePeriod(txs, st, goals, today, {bills, planned})` → `PeriodBudget` gains `reservedPlanned` (int) and
`duePlanned` (List<PlannedCost>): open planned costs with an amount, dated from `today` to the day before payday,
not `paid`/`skipped`. `flexBudget` subtracts `reservedBills + reservedPlanned`. With `planned` empty every number is
exactly as before (M4 tests unchanged). A planned cost dated before today reserves nothing (its day has passed).

## Heads-up and settings
```dart
class HeadsUp { final UpcomingItem item; final int daysLeft; }
/// Items (planned with amount, confirmed bills) with amount ≥ thresholdCents dated within [today, today + days].
List<HeadsUp> headsUps(List<UpcomingItem> items, String today, {required int thresholdCents, required int days});
```
Synced settings in `WalletSettings`: `headsUpCents` (default 10000, 0..10000000), `headsUpDays` (default 3, 0..14).
Device-local (app, `setLocalValue`): chosen Android calendar ids, `.ics` imports/links — never synced, never logged.

## Export and search
`String plannedIcs(List<PlannedCost> planned, List<RecurringBill> bills, {required String from, required String to})` —
an `.ics` (VEVENT per planned cost with an amount and per confirmed bill occurrence; SUMMARY `<title> · <amount €>`,
all-day, stable UIDs). `searchAll(..., planned:)` adds `SearchResult.planned` (title/category folded, exact amount).
