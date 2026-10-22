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
  final String? category, sourceRef, paidTx;       // sourceRef = CalendarEvent.ref (calendarEventRef) for calendar rows
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
/// "No cost" on a calendar suggestion: a synced row {source: calendar, sourceRef, status: skipped}, so no device
/// suggests that event again. Writes no title (column default '').
void dismissCalendarEvent(String sourceRef, String date);
```

## Calendar events (device-local, never synced or stored by core)
```dart
class CalendarEvent {
  final String calendarId, uid, title, date;       // date = the occurrence's local date
  final String? notes;
  final bool allDay;
  String get ref => calendarEventRef(calendarId: calendarId, uid: uid, title: title, date: date);
}
String calendarRef(String calendarId, String uid, String date);   // hex SHA-256 prefix (32), no raw ids kept
String calendarEventRef({required String calendarId, required String uid, required String title, required String date});
                                                    // F4a: from normalizeTitle + date; calendarRef if that is ''
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

## Decisions and additions (F1, 2026-10-22)
- Constructors take named args matching the field names; `PlannedCost.source` defaults to manual, `status` to open.
  Additions: `PlannedCost.deleted` (default false) and `isOpen` (open and not deleted).
- Repo additions: `reopenPlanned(id)` (open again, `paid_tx` cleared); `updatePlanned(..., clearAmount: false,
  clearCategory: false)`. `addPlanned`/`updatePlanned`: bad date or amount ≤ 0 → `ArgumentError`; unknown id →
  `ArgumentError`. With a `sourceRef` the row id is `<source>:<ref>` (`calendar:<ref>`), the same on every device: two
  devices confirming one event write one row (last writer wins per field); confirming a dismissed event reopens it.
  `dismissCalendarEvent` on an event that already has a row only sets `status: skipped` (title kept).
- `plannedCosts(includeClosed: true)` returns every row incl. deleted ones; pass that list to `upcoming()` so an event
  with any row (deleted included) is never suggested again.
- Bill keys are `b:<billId>@<date>` (one bill can occur several times in a range). Occurrences: `nextDue`, then every
  `intervalDays`, inside [from, to]; an overdue bill shows from its next occurrence. `billOccurrences(bill, from, to)`.
- "Earlier" suggestion: the latest planned cost dated before the event with the same non-empty `normalizeTitle`, with an
  amount, open or paid, not deleted; its category is suggested too. An amount in the title (or else the notes,
  `suggestedFrom: 'title'`) wins.
- `amountFromText`: a single `.`/`,` followed by exactly three digits is a thousands separator (`1.250 €` = 1250 €);
  zero and negative amounts are not amounts; malformed separators (`1.250.00 €`) → null. `normalizeTitle` also turns
  every non-letter into a space.
- `paidCandidates`: live expenses only (no income, deleted or replaced rows), ties by date distance, then amount
  closeness, then date, then id; `paidWindowDays = 3`.
- `parseIcs(..., toLocal:)`: optional `DateTime Function(DateTime utc)`; a UTC `Z` time takes the date of
  `toLocal(t)` (the app passes `(t) => t.toLocal()`), the UTC date without it. TZID and floating times keep their wall
  date. Also supported: monthly `BYDAY` without ordinal, `BYMONTHDAY` (monthly), daily `BYDAY`, yearly `BYMONTH`/
  `BYMONTHDAY` repeating DTSTART, `RDATE`, `RECURRENCE-ID` overrides, `STATUS:CANCELLED`. RRULE MONTHLY on the 31st:
  RFC 5545 (months without that day skipped). `unsupported` also counts events without a usable DTSTART and a file cut
  off inside an event.
- `computePeriod`: `duePlanned(planned, today, end)` is public. `PlannedCost.coveredByPlan` (category of kind fixed:
  Rent, Loan, Bills & subscriptions; same rule as `RecurringBill.coveredByPlan`): listed in `duePlanned`, Upcoming and
  heads-ups, but never added to `reservedPlanned` (already in the fixed plan; lead 2026-10-22). Deleted rows and
  non-positive amounts never reserve.
- `plannedIcs`: open and paid costs with an amount (not skipped/deleted); SUMMARY `<title> · <euroText(amount)>`
  (`1.250,50 €`, so `amountFromText(summary) == amount`); UIDs `planned-<id>@budget-wallet`,
  `bill-<id>-<yyyymmdd>@budget-wallet`; `DTSTAMP` from `from` (same input → same text).
- `searchAll(..., planned:)` is optional (default empty).

## Review fixes (F4a, 2026-10-22)
- **Calendar refs come from the event's content.** `CalendarEvent.ref` = `calendarEventRef(...)`: the first 32 hex of
  SHA-256 over `bw-cal-v2`, `normalizeTitle(title)` and `date`, so every device and every source (Android calendar,
  `.ics` file, `.ics` link of the same calendar) gives the same ref and the row id `calendar:<ref>` converges: "No cost"
  on one device hides the event on all, and confirming on two devices before they sync writes one row (reserved once).
  A title that normalizes to '' (no letters, e.g. `80 €`) falls back to `calendarRef(calendarId, uid, date)` (per
  calendar, so per device). No raw title is stored. Consequences: two events with the same normalized title on the same
  day (amounts are stripped: `Dentist 80 €` and `Dentist 90 €`) show as ONE suggestion; renaming an event in the
  calendar makes it a new suggestion (the old row stays, the new title is suggested again). `upcoming()` lists equal
  refs once, picking the event first by calendarId, uid, title, notes (the same on every device, whatever the order).
  Refs of rows written by F1–F3 builds (`bw-cal-v1`) no longer match; stage F was not released, so nothing migrates.
- `parseIcs` cost bounds (it runs on the UI isolate): folded lines are joined in linear time; a whole-file budget of
  10⁶ recurrence steps (one step = one period of one rule). Once spent, each later recurring event gives only its first
  occurrence in [from, to] (a rule without COUNT: looked for within 8 periods of `from`; with COUNT: none, as that needs
  stepping from DTSTART) and counts in `unsupported`; the event during which it runs out keeps the dates found so far
  and counts too. Never throws.
- `dismissCalendarEvent` on an event with no row writes `date`, `source`, `source_ref`, `status`, `deleted` but no
  `title`: a "No cost" on one device after a confirm on another (not yet synced) keeps the confirmed title.
