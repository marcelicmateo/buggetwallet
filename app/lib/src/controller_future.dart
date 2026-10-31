// Future spending in the controller (API: docs/context/FUTURE_SPENDING_API.md): planned costs, the Upcoming list, calendars (phone calendars and `.ics`),
// heads-up lines and notifications, export and search. A `part` of controller.dart so it can use the cache and `_changed`.
//
// Privacy: logs carry counts and enum words only, never titles, amounts, calendar names, links or file names.
part of 'controller.dart';

final _planLog = Logger('bw.planned');
final _calLog = Logger('bw.calendar');
final _headLog = Logger('bw.headsup');

/// How far ahead calendar events are read.
const calendarHorizonDays = 90;

enum CalendarKind { device, file, link }

/// Is [link] a plain `http://` address (the calendar would travel unencrypted)?
bool isInsecureLink(String? link) => link != null && link.trim().toLowerCase().startsWith('http://');

/// One row of Plan › Calendars.
class CalendarEntry {
  final String id;
  final CalendarKind kind;
  final String name;
  final String? account;
  final bool on;

  /// A plain message when the last read of this calendar failed (the saved copy is still used).
  final String? error;

  /// A link that starts with `http://` (not encrypted).
  final bool insecure;
  const CalendarEntry(this.id, this.kind, this.name, {this.account, this.on = true, this.error, this.insecure = false});
}

/// Device-local calendar state. Events are only ever held in memory here: they are re-read from the phone (or the saved `.ics`
/// text) at start and resume, and never synced.
class CalendarState extends SubState {
  List<CalendarEvent> _events = const [];
  List<DeviceCalendarInfo> _device = const [];
  bool _permission = false;
  bool _denied = false;
  bool _reading = false;
  String? _lastRead;
  final Map<String, String> _errors = {};

  List<CalendarEvent> get events => _events;
  set events(List<CalendarEvent> v) {
    _events = v;
    touch();
  }

  List<DeviceCalendarInfo> get device => _device;
  set device(List<DeviceCalendarInfo> v) {
    _device = v;
    touch();
  }

  bool get permission => _permission;
  set permission(bool v) {
    if (v != _permission) touch();
    _permission = v;
  }

  bool get denied => _denied;
  set denied(bool v) {
    if (v != _denied) touch();
    _denied = v;
  }

  bool get reading => _reading;
  set reading(bool v) {
    if (v != _reading) touch();
    _reading = v;
  }

  String? get lastRead => _lastRead;
  set lastRead(String? v) {
    if (v != _lastRead) touch();
    _lastRead = v;
  }

  /// A plain message when the last read of a calendar source failed (change it with [setError] / [clearError]).
  String? errorFor(String id) => _errors[id];

  void setError(String id, String message) {
    if (_errors[id] != message) touch();
    _errors[id] = message;
  }

  void clearError(String id) {
    if (_errors.remove(id) != null) touch();
  }

  /// How many saved sources the last read could not use (logged when it changes).
  int skippedSources = 0;

  bool headsUpQueued = false;

  /// The last scheduled heads-up run: the next one waits for it, so two overlapping calls never cancel and schedule in turn.
  Future<void> headsUpChain = Future.value();

  /// Bumped whenever [events] change, so cached Upcoming lists are made again.
  int version = 0;
}

/// What one [WalletController.readCalendars] run collects: the events and the counts it logs.
class _CalendarRead {
  final events = <CalendarEvent>[];
  var unsupported = 0, calendars = 0;
}

/// Saved `.ics` calendar sources (files and links), kept in a device-local value; the text of each in `icsText:<id>`.
class _IcsSource {
  final String id, name;
  final CalendarKind kind;
  final String? url;
  const _IcsSource(this.id, this.name, this.kind, this.url);
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'kind': kind.name, if (url != null) 'url': url};
}

extension FutureSpending on WalletController {
  // ---------- planned costs and Upcoming ----------

  /// Every planned row, open or closed (the list core needs to tell which calendar events are already stored). Cached.
  List<PlannedCost> plannedEverything() => _cached(const MemoKey('plannedAll'), () => repo.plannedCosts(includeClosed: true));

  /// Open planned costs only.
  List<PlannedCost> plannedOpen() => _cached(const MemoKey('plannedOpen'), () => repo.plannedCosts());

  /// Planned costs, confirmed bills and unconfirmed calendar events from [from] to [to] (inclusive), by date. Cached.
  List<UpcomingItem> upcomingItems(String from, String to) => _cached(MemoKey('upcoming', (from, to, cal.version)),
      () => upcoming(planned: plannedEverything(), bills: recurringBills(),
          events: cal.events,
          from: from,
          to: to,
          billsDb: billsAll(),
          payeeAliases: payeeAliases()));

  /// The dates Upcoming shows: the pay period, or the next one of the same length ([next]). `end` is the last day shown.
  ({String start, String end}) upcomingRange({bool next = false}) {
    final p = period();
    return next ? (start: p.end, end: addDays(p.end, p.length - 1)) : (start: p.start, end: addDays(p.end, -1));
  }

  /// "Coming up": exactly the planned costs this period reserves (core's `PeriodBudget.reservedPlannedRows`, summed into
  /// `reservedPlanned`), so the count and total shown are what comes off the spending money. Suggestions and bills are not in it.
  ({int count, int total}) comingUp() => _cached(const MemoKey('comingUp'), () {
        final p = period();
        return (count: p.reservedPlannedRows.length, total: p.reservedPlanned);
      });

  /// The bill rows due this period that have no category: listed, not reserved, until the owner picks one (Today says so).
  List<PlannedCost> plannedNeedingCategory() => _cached(
      const MemoKey('needsCategory'),
      () => [
            for (final p in period().duePlanned)
              if (p.needsCategory && p.sourceRef != null) p
          ]);

  /// Upcoming's "Set aside" (KL-A: always what Today's "Before payday" holds). The running period: core's own numbers for the period
  /// (`beforePayday` = Σ `reservedCycles` reserve + Σ `reservedPlannedRows` amount, overdue bill cycles and held long bills included), so
  /// the two screens can never differ. The next period has no budget yet: [countedIn] over its [items].
  ({int count, int total}) setAside(List<UpcomingItem> items, {bool next = false}) {
    if (next) return countedIn(items);
    final p = period();
    return (count: p.beforePaydayCount, total: p.beforePayday);
  }

  /// A bill's cycle listed in Upcoming that is already past its due date and unpaid ("Overdue"; it is still set aside).
  bool isOverdueCycle(UpcomingItem i) => i.kind == UpcomingKind.bill && i.date.compareTo(today()) < 0;

  /// Cycles that are set aside but fall before the period's first day (an old unpaid bill): the list of the period cannot show them,
  /// so Upcoming lists them apart (core's `reservedCycles`, each with its own reserve).
  List<DueCycle> overdueEarlier() {
    final p = period();
    return [
      for (final x in p.reservedCycles)
        if (x.due.compareTo(p.start) < 0) x
    ];
  }

  /// What [items] set aside, rule by rule (used for the next period and for any shown subset): confirmed recurring bills with an amount
  /// outside the fixed plan (an overdue cycle too), and the planned costs core's `plannedReserves` accepts, given those bill
  /// occurrences (the same rule as `computePeriod`).
  ({int count, int total}) countedIn(List<UpcomingItem> items) {
    final t = today();
    bool ahead(UpcomingItem i) => i.amount != null && i.date.compareTo(t) >= 0;
    final occurrences = {
      for (final i in items)
        if (i.kind == UpcomingKind.bill && i.bill != null && i.amount != null) occurrenceKey(i.bill!.id, i.date)
    };
    final recurring = expectedBills();
    final aliases = payeeAliases();
    final xs = items.where((i) => switch (i.kind) {
          UpcomingKind.bill => i.amount != null && !(i.bill?.coveredByPlanIn(categoryTable) ?? false),
          UpcomingKind.planned =>
            ahead(i) && i.planned != null && plannedReserves(i.planned!, recurring, occurrences, table: categoryTable, payeeAliases: aliases),
          _ => false,
        });
    return (count: xs.length, total: xs.fold<int>(0, (a, i) => a + i.amount!));
  }

  /// Calendar events given no amount yet in the shown range (the "Suggested" rows).
  int suggestionCount() => upcomingItems(period().start, addDays(period().end, -1)).where((i) => i.kind == UpcomingKind.suggestion).length;

  void addPlannedCost({required String title, required String date, int? amount, String? category}) {
    repo.addPlanned(title: title.trim(), date: date, amount: amount, category: category);
    logEvent(_planLog, Level.INFO, 'planned.add', {'source': 'manual', 'amount': amount != null});
    _changed();
  }

  /// [clearCategory] removes the category (a null [category] alone means unchanged).
  void updatePlanned(String id, {String? title, String? date, int? amount, String? category, bool clearCategory = false}) {
    repo.updatePlanned(id, title: title?.trim(), date: date, amount: amount, category: category, clearCategory: clearCategory);
    logEvent(_planLog, Level.INFO, 'planned.edit', {'amount': amount != null});
    _changed();
  }

  /// "Confirm" or "Change" on a calendar suggestion: stores the event as a planned cost with [amount] (title and date may be
  /// changed). Only now does the cost count in the safe-to-spend number.
  void confirmSuggestion(UpcomingItem it, {required int amount, String? title, String? date, String? category}) {
    final e = it.event!;
    repo.addPlanned(
        title: (title ?? e.title).trim(),
        date: date ?? it.date,
        amount: amount,
        category: category,
        source: PlannedSource.calendar,
        sourceRef: e.ref);
    logEvent(_planLog, Level.INFO, 'planned.add', {'source': 'calendar', 'amount': true, 'from': it.suggestedFrom ?? 'typed'});
    _changed();
  }

  /// "No cost" on a calendar suggestion: stores only a dismissed marker (no title) so no device suggests it again.
  void dismissSuggestion(UpcomingItem it) {
    repo.dismissCalendarEvent(it.event!.ref, it.date, legacyRef: it.event!.legacyRef);
    logEvent(_planLog, Level.INFO, 'planned.dismiss', {});
    _changed();
  }

  /// "Paid" with the transaction the owner picked.
  void markPlannedPaid(PlannedCost p, Tx tx) {
    repo.markPlannedPaid(p.id, tx.id);
    logEvent(_planLog, Level.INFO, 'planned.paid', {});
    _changed();
  }

  void skipPlanned(PlannedCost p) {
    repo.skipPlanned(p.id);
    logEvent(_planLog, Level.INFO, 'planned.skip', {});
    _changed();
  }

  /// KL-A: the planned costs this device closed by itself (an import or a sync run matched exactly one bank row), once per data change:
  /// they are acknowledged here, so the toast shows once. Empty when nothing new. Logs the count only.
  List<AutoPaid> takeAutoPaid() {
    if (_autoPaidSeen == dataVersion) return const [];
    _autoPaidSeen = dataVersion;
    final done = repo.autoPaidPlanned();
    if (done.isEmpty) return const [];
    repo.ackAutoPaidPlanned([for (final a in done) a.plannedId]);
    logEvent(_planLog, Level.INFO, 'planned.autoPaid', {'count': done.length});
    return done;
  }

  /// The toast's text: the title of one cost, else the count.
  String autoPaidText(List<AutoPaid> done) => done.length == 1
      ? 'Marked paid: ${done.single.title.isEmpty ? 'planned cost' : done.single.title}'
      : '${done.length} planned costs marked paid';

  /// "Undo" on the auto-Paid toast: all of [done] are open again (core keeps them from closing by the same bank row).
  void undoAutoPaid(List<AutoPaid> done) {
    for (final a in done) {
      repo.reopenPlanned(a.plannedId);
    }
    logEvent(_planLog, Level.INFO, 'planned.autoPaid.undo', {'count': done.length});
    _changed();
  }

  /// "Undo" after Paid or Skip: the cost is open again (and counts again).
  void reopenPlanned(PlannedCost p) {
    repo.reopenPlanned(p.id);
    logEvent(_planLog, Level.INFO, 'planned.reopen', {});
    _changed();
  }

  void deletePlanned(PlannedCost p) {
    repo.deletePlanned(p.id);
    logEvent(_planLog, Level.INFO, 'planned.delete', {});
    _changed();
  }

  /// "Paid by this?" candidates for [p]: same category within 3 days, never by amount alone.
  List<CategorizedTx> paidCandidatesFor(PlannedCost p) => paidCandidates(p, wholeTxs, plannedEverything());

  // ---------- heads-up ----------

  /// The heads-up threshold (cents) and days: synced settings.
  int get headsUpCents => settings.headsUpCents;
  int get headsUpDays => settings.headsUpDays;
  void saveHeadsUp({required int cents, required int days}) => updateSettings({'headsUpCents': cents, 'headsUpDays': days});

  /// The big costs within the heads-up days (planned with an amount and confirmed bills; suggestions never). Cached.
  List<HeadsUp> headsUpLines() => _cached(const MemoKey('headsUps'), () {
        final t = today();
        return headsUps(upcomingItems(t, addDays(t, headsUpDays)), t, thresholdCents: headsUpCents, days: headsUpDays);
      });

  /// Device-local: show a notification for each heads-up (Android).
  bool get headsUpNotify => repo.localValue('headsUpNotify') == '1';

  /// Turns the heads-up notifications on or off; on asks the system for the notification permission first. Returns whether
  /// they are on afterwards.
  Future<bool> setHeadsUpNotify(bool on) async {
    try {
      if (!on) {
        repo.setLocalValue('headsUpNotify', null);
        await nudges.cancelHeadsUps();
        logEvent(_headLog, Level.INFO, 'headsup.enabled', {'on': false});
        _refreshView();
        return false;
      }
      final granted = await nudges.requestPermission();
      logEvent(_headLog, Level.INFO, 'headsup.enabled', {'on': granted, 'granted': granted});
      nudgesDenied = !granted;
      if (granted) repo.setLocalValue('headsUpNotify', '1');
      _refreshView();
      if (granted) await rescheduleHeadsUps();
      return granted;
    } catch (e, st) {
      logError(_headLog, 'headsup.setFailed', e, st, fields: {'on': on});
      _refreshView();
      return headsUpNotify;
    }
  }

  /// Called after every reload: heads-ups depend on planned costs, bills and the settings.
  void _headsUpsMayHaveChanged() {
    if (cal.headsUpQueued || !nudges.supported || !headsUpNotify) return;
    cal.headsUpQueued = true;
    scheduleMicrotask(() {
      cal.headsUpQueued = false;
      rescheduleHeadsUps();
    });
  }

  /// Schedules a notification at 09:00 local on (cost date − heads-up days) for every big planned cost in the next 90 days.
  /// The text never carries an amount or a title. Replaces the earlier heads-ups; cancels them when the switch is off.
  /// Runs one after another: a call made while another is running waits for it and then reads the state as it is by then.
  Future<void> rescheduleHeadsUps() {
    if (!nudges.supported) return Future.value();
    // A link that throws is logged and the chain goes on: one failure must not leave every later call rejected.
    return cal.headsUpChain = cal.headsUpChain.catchError((Object e, StackTrace st) {
      logError(_headLog, 'headsup.chainFailed', e, st);
    }).then((_) async {
      try {
        await _rescheduleHeadsUpsNow();
      } catch (e, st) {
        logError(_headLog, 'headsup.chainFailed', e, st);
      }
    });
  }

  Future<void> _rescheduleHeadsUpsNow() async {
    await _rescheduleCostHeadsUpsNow();
    await _rescheduleBillRemindersNow(); // same chain: return windows and warranties follow the heads-ups
  }

  Future<void> _rescheduleCostHeadsUpsNow() async {
    try {
      if (!headsUpNotify) {
        await nudges.cancelHeadsUps();
        return;
      }
      final t = today();
      final all = headsUps(upcomingItems(t, addDays(t, calendarHorizonDays)), t, thresholdCents: headsUpCents, days: calendarHorizonDays);
      final slots = headsUpSlots(_clock(), [for (final h in all) (h.item.date, headsUpDays)]);
      final n = await nudges.scheduleHeadsUps(slots);
      logEvent(_headLog, Level.INFO, 'headsup.scheduled', {'count': n});
    } catch (e, st) {
      logError(_headLog, 'headsup.scheduleFailed', e, st);
    }
  }

  // ---------- calendars ----------

  /// Can this device read its phone calendars (Android)?
  bool get deviceCalendarsSupported => calendarSource.supported;

  /// Can this build fetch an `.ics` link (not the browser)?
  bool get linksSupported => icsLinksSupported;

  Set<String> get _deviceOn => {
        for (final x in _jsonList('calendarsOn'))
          if (x is String) x
      };

  /// The saved sources. An entry that cannot be read (an unknown kind from a newer build, a missing field) is skipped and counted in
  /// the log; the others still load.
  List<_IcsSource> get _icsSources {
    final out = <_IcsSource>[];
    var skipped = 0;
    for (final m in _jsonList('icsSources')) {
      final kind = m is Map && m['kind'] is String ? CalendarKind.values.asNameMap()[m['kind']] : null;
      if (m is Map && kind != null && m['id'] is String && m['name'] is String) {
        out.add(_IcsSource(m['id'] as String, m['name'] as String, kind, m['url'] as String?));
      } else {
        skipped++;
      }
    }
    // Logged when the count changes, not on every read (the getter is read by every Calendars build).
    if (skipped != cal.skippedSources) {
      cal.skippedSources = skipped;
      if (skipped > 0) logEvent(_calLog, Level.WARNING, 'calendar.sourceSkipped', {'count': skipped});
    }
    return out;
  }

  /// The JSON list saved under the device-local [key]; empty when missing or damaged (the log names the key, never the text).
  List<Object?> _jsonList(String key) {
    final raw = repo.localValue(key);
    if (raw == null) return const [];
    try {
      return jsonDecode(raw) as List<Object?>;
    } catch (e, st) {
      logError(_calLog, 'localList.invalid', e, st, fields: {'key': key});
      return const [];
    }
  }

  void _saveIcsSources(List<_IcsSource> xs) =>
      repo.setLocalValue('icsSources', xs.isEmpty ? null : jsonEncode([for (final x in xs) x.toJson()]));

  /// Every calendar Plan lists: the phone's (once allowed), then imported files and links.
  List<CalendarEntry> calendarEntries() {
    final on = _deviceOn;
    return [
      if (cal.permission)
        for (final d in cal.device) CalendarEntry(d.id, CalendarKind.device, d.name, account: d.account, on: on.contains(d.id)),
      for (final s in _icsSources) CalendarEntry(s.id, s.kind, s.name, error: cal.errorFor(s.id), insecure: isInsecureLink(s.url)),
    ];
  }

  /// Plan › Calendars opened: finds out (without a dialog) whether the phone's calendars may be read, and lists them.
  Future<void> checkCalendarAccess() async {
    if (!calendarSource.supported) return;
    try {
      cal.permission = await calendarSource.hasPermission();
      if (cal.permission) cal.device = await calendarSource.calendars();
    } catch (e, st) {
      cal.permission = false;
      logError(_calLog, 'calendar.accessCheckFailed', e, st);
    }
    _refreshView();
  }

  /// The "Allow calendar access" button. Returns whether it was allowed; [CalendarState.denied] says it was refused.
  Future<bool> requestCalendarAccess() async {
    if (!calendarSource.supported) return false;
    try {
      cal.permission = await calendarSource.requestPermission();
      cal.denied = !cal.permission;
      if (cal.permission) cal.device = await calendarSource.calendars();
      logEvent(_calLog, Level.INFO, 'calendar.access', {'granted': cal.permission, 'calendars': cal.device.length});
    } catch (e, st) {
      cal.permission = false;
      cal.denied = true;
      logError(_calLog, 'calendar.accessFailed', e, st);
    }
    _refreshView();
    return cal.permission;
  }

  Future<void> setCalendarOn(String id, bool on) async {
    final ids = _deviceOn;
    on ? ids.add(id) : ids.remove(id);
    repo.setLocalValue('calendarsOn', ids.isEmpty ? null : jsonEncode(ids.toList()));
    logEvent(_calLog, Level.INFO, 'calendar.choose', {'on': on, 'chosen': ids.length});
    _refreshView();
    await readCalendars(trigger: 'choose');
  }

  /// Imports an `.ics` file: returns a plain error message, or null when it was saved. The text stays on this device.
  Future<String?> importIcsFile(String name, Uint8List bytes) async {
    if (bytes.length > icsMaxBytes) {
      logEvent(_calLog, Level.WARNING, 'calendar.import', {'ok': false, 'reason': 'tooBig', 'bytes': bytes.length});
      return 'That file is bigger than 2 MB. Export a shorter range from your calendar.';
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    final bad = _icsProblem(text);
    if (bad != null) {
      logEvent(_calLog, Level.WARNING, 'calendar.import', {'ok': false, 'reason': 'notCalendar', 'bytes': bytes.length});
      return bad;
    }
    final id = _newIcsId();
    repo.setLocalValue('icsText:$id', text);
    _saveIcsSources([..._icsSources, _IcsSource(id, _shortName(name), CalendarKind.file, null)]);
    logEvent(_calLog, Level.INFO, 'calendar.import', {'ok': true, 'kind': 'file', 'bytes': bytes.length});
    await readCalendars(trigger: 'import');
    return null;
  }

  /// Adds an `.ics` link (http or https, or `webcal://`): fetches it once now. Returns a plain error message, or null.
  Future<String?> addIcsLink(String raw) async {
    final u = Uri.tryParse(raw.trim().replaceFirst(RegExp(r'^webcal://', caseSensitive: false), 'https://'));
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https') || u.host.isEmpty) {
      return 'Enter a web address that starts with http:// or https://';
    }
    final String text;
    try {
      text = await deps.icsFetcher(u);
    } on IcsFetchException catch (e) {
      logEvent(_calLog, Level.WARNING, 'calendar.import', {'ok': false, 'kind': 'link', 'reason': 'fetch'});
      return e.message;
    } catch (e, st) {
      logError(_calLog, 'calendar.linkFailed', e, st, fields: {'type': e.runtimeType.toString()});
      return "Couldn't read the link.";
    }
    if (text.length > icsMaxBytes) return 'That calendar is bigger than 2 MB.';
    final bad = _icsProblem(text);
    if (bad != null) {
      logEvent(_calLog, Level.WARNING, 'calendar.import', {'ok': false, 'kind': 'link', 'reason': 'notCalendar'});
      return bad;
    }
    final id = _newIcsId();
    repo.setLocalValue('icsText:$id', text);
    _saveIcsSources([..._icsSources, _IcsSource(id, u.host, CalendarKind.link, u.toString())]);
    logEvent(_calLog, Level.INFO, 'calendar.import', {'ok': true, 'kind': 'link', 'bytes': text.length});
    await readCalendars(trigger: 'import');
    return null;
  }

  void removeCalendarSource(String id) {
    repo.setLocalValue('icsText:$id', null);
    _saveIcsSources([
      for (final s in _icsSources)
        if (s.id != id) s
    ]);
    cal.clearError(id);
    logEvent(_calLog, Level.INFO, 'calendar.remove', {});
    _refreshView();
    unawaited(readCalendars(trigger: 'remove'));
  }

  String _newIcsId() => 'ics${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  static String _shortName(String fileName) {
    final base = fileName.split(RegExp(r'[\\/]')).last;
    final n = base.toLowerCase().endsWith('.ics') ? base.substring(0, base.length - 4) : base;
    return n.isEmpty ? 'Calendar file' : n;
  }

  static String? _icsProblem(String text) {
    if (!text.contains('BEGIN:VCALENDAR')) return "That doesn't look like a calendar file (.ics).";
    return null;
  }

  /// Reads every chosen calendar for [today, today + 90 days] into [CalendarState.events]: the phone's calendars, and the saved
  /// text of each `.ics` source (links are fetched again first; if that fails the saved copy is used and the entry says so).
  /// Called at start and resume, after a calendar is chosen or imported, and by "Read now". Logs counts only.
  Future<void> readCalendars({String trigger = 'button'}) async {
    final sources = _icsSources;
    final ids = calendarSource.supported ? _deviceOn : <String>{};
    if (sources.isEmpty && ids.isEmpty && cal.events.isEmpty) return;
    if (cal.reading) return;
    cal.reading = true;
    _refreshView();
    final from = today(), to = addDays(from, calendarHorizonDays);
    final read = _CalendarRead();
    try {
      if (calendarSource.supported && ids.isNotEmpty) await _readDevice(ids, from, to, read);
      for (final s in sources) {
        await _readSource(s, from, to, read);
      }
      cal.events = read.events;
      cal.lastRead = from;
      cal.version++;
      logEvent(_calLog, Level.INFO, 'calendar.read',
          {'calendars': read.calendars, 'events': read.events.length, 'unsupported': read.unsupported, 'trigger': trigger});
    } finally {
      cal.reading = false;
      dataVersion++; // the pages are built per data version: Today and Upcoming show the new events
      _memo.clear();
      _refreshView();
    }
  }

  /// The phone's chosen calendars into [read]; without the calendar permission nothing is read and `cal.permission` says so.
  Future<void> _readDevice(Set<String> ids, String from, String to, _CalendarRead read) async {
    try {
      if (await calendarSource.hasPermission()) {
        cal.permission = true;
        read.events.addAll(await calendarSource.events(ids, from, to));
        read.calendars += ids.length;
      } else {
        cal.permission = false;
      }
    } catch (e, st) {
      logError(_calLog, 'calendar.deviceReadFailed', e, st, fields: {'type': e.runtimeType.toString()});
    }
  }

  /// One `.ics` source into [read]: a link is fetched again first (the saved copy is used when that fails), then its text is parsed.
  Future<void> _readSource(_IcsSource s, String from, String to, _CalendarRead read) async {
    var text = repo.localValue('icsText:${s.id}');
    cal.clearError(s.id);
    if (s.kind == CalendarKind.link && s.url != null) text = await _refreshLink(s, text);
    if (text == null) return;
    _parseSource(s, text, from, to, read);
  }

  /// The fresh text of a link source, saved as its copy; on a failure the entry says so and [saved] stays in use. A fresh text that
  /// could not be saved is still the one to read this time.
  Future<String?> _refreshLink(_IcsSource s, String? saved) async {
    var text = saved;
    try {
      final fresh = await deps.icsFetcher(Uri.parse(s.url!));
      if (fresh.length > icsMaxBytes || _icsProblem(fresh) != null) {
        throw const IcsFetchException("That link isn't a calendar any more.");
      }
      text = fresh;
      repo.setLocalValue('icsText:${s.id}', fresh);
    } on IcsFetchException catch (e) {
      cal.setError(s.id, "Couldn't refresh this link. ${e.message} Showing what was saved.");
    } catch (e, st) {
      cal.setError(s.id, "Couldn't refresh this link. Showing what was saved.");
      logError(_calLog, 'calendar.refreshFailed', e, st, fields: {'type': e.runtimeType.toString()});
    }
    return text;
  }

  void _parseSource(_IcsSource s, String text, String from, String to, _CalendarRead read) {
    try {
      final r = parseIcs(text, calendarId: s.id, from: from, to: to, toLocal: (t) => t.toLocal());
      read.events.addAll(r.events);
      read.unsupported += r.unsupported;
      read.calendars++;
    } catch (e, st) {
      cal.setError(s.id, "Couldn't read this calendar.");
      logError(_calLog, 'calendar.parseFailed', e, st, fields: {'type': e.runtimeType.toString()});
    }
  }

  // ---------- export and search ----------

  /// Planned costs with an amount (and confirmed bills) from today for a year, as an `.ics` file for other calendar apps.
  /// [ExportFile.rows] is the number of events; 0 means there is nothing to save.
  ExportFile exportPlannedIcs() {
    final t = today();
    final text = plannedIcs(plannedOpen(), recurringBills(),
        from: t, to: addDays(t, 365), payeeAliases: payeeAliases(), events: cal.events);
    final rows = 'BEGIN:VEVENT'.allMatches(text).length;
    return ExportFile('budget-wallet-planned.ics', Uint8List.fromList(utf8.encode(text)), rows);
  }

  /// Planned costs matching [query] (the planned part of [search]).
  List<PlannedCost> searchPlanned(String query) => search(query).planned;
}
