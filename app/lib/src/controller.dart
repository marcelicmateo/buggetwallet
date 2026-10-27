import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'bill_inputs.dart';
import 'calendar_source.dart';
import 'clock_notice.dart';
import 'controller_deps.dart';
import 'format.dart' show NumberStyle, money, numberStyle;
import 'home_widget.dart';
import 'ics_fetch.dart';
import 'insights_api.dart' show InsightRange;
import 'key_store.dart';
import 'logging.dart';
import 'memo_key.dart';
import 'nudges.dart';
import 'platform.dart' show isWeb;
import 'sub_state.dart';
import 'tabs.dart';
import 'wallet_db.dart';

part 'controller_accounts.dart';
part 'controller_categories.dart';
part 'controller_tags.dart';
part 'controller_rules.dart';
part 'controller_bills.dart';
part 'controller_recurring.dart';
part 'controller_future.dart';
part 'controller_home.dart';
part 'controller_splits.dart';
part 'controller_fx.dart';

final _log = Logger('bw.app');
final _sync = Logger('bw.sync');
final _import = Logger('bw.import');
final _key = Logger('bw.key');
final _habits = Logger('bw.habits');
final _nudgeLog = Logger('bw.nudges');
final _backupLog = Logger('bw.backup');
final _searchLog = Logger('bw.search');

/// The core function; the controller method of the same name would hide it inside the class.
const _computeBudget = budgetVsActual;

/// Which transactions Plan › Export writes.
enum ExportRange { period, year, all }

/// A CSV ready for the save dialog.
class ExportFile {
  final String name;
  final Uint8List bytes;

  /// Transactions in the file; 0 means there is nothing to save.
  final int rows;
  const ExportFile(this.name, this.bytes, this.rows);
}

/// A category as a log field: a built-in name, `none`, or `custom` (an own category's id is never logged).
String _logCategory(String? c) => c == null ? 'none' : (categories.containsKey(c) ? c : 'custom');

/// Same for the review state: the controller has a method of the same name.
const reviewStateOf = reviewState;

/// The count of one review step by its id (`import`, `categories`, `pace`, `wishlist`).
extension ReviewCounts on ReviewState {
  int count(String id) => steps.where((s) => s.id == id).fold(0, (a, s) => a + s.count);
}

class ImportLine {
  final String file;
  final String message;
  final bool ok;

  /// How many rows the file added to the wallet (0 for a file that failed or held nothing new).
  final int added;

  /// Set when this import replaced a saved layout's earlier payments (P12): the toast's Undo puts them back.
  final VoidCallback? undo;
  const ImportLine(this.file, this.message, this.ok, {this.added = 0, this.undo});
}

/// What a saved layout replaced while one file was imported (P12): filled by [WalletController._readImportFile] the moment a forced save
/// deleted payments, so every outcome of the file (success, clock behind, unreadable) can still offer the Undo.
class _Remap {
  String? id;
  List<String> removed = const [];

  /// The layout as it was before (the removed one), written back by the Undo; null when core kept none.
  CsvMapping? old;
}

/// What the Map columns sheet hands back (P12): the layout and the shape id of the file at the layout's header row.
class CsvChoice {
  final String shapeId;
  final CsvMapping mapping;
  const CsvChoice(this.shapeId, this.mapping);
}

/// Asked for a CSV no bank profile and no saved layout fits: the owner maps its columns (null = cancel, nothing imported).
typedef AskMapping = Future<CsvChoice?> Function(NeedsMapping need, Uint8List bytes);

/// Asked when the chosen layout reads differently from a removed one that imported [payments] payments: true = remove them.
typedef ConfirmRemoval = Future<bool> Function(int payments);

/// Everything the Spending tab shows for one month, worked out in [WalletController.spending].
class SpendingView {
  final String month;

  /// The last 13 months, oldest first; the last one is this month.
  final List<String> months;
  final MonthSummary summary;

  /// The month's spending per main tag ([MonthSummary.byCategory]; subcategories are gone, tags replaced them).
  /// The "Where it goes" rows.
  final Map<String, int> byTopLevel;

  /// Average per category over the 6 months before [month] (a month without spend counts as zero), from `averageByCategory`.
  final Map<String, int> average;
  final List<PeriodSummary> periods;
  final List<int?> trend;
  final SavingsOverview overview;

  /// The 8 biggest card-spending places this month: (name, payments, total).
  final List<(String, int, int)> topPlaces;

  /// Every transaction of the month except transfers between own accounts.
  final List<CategorizedTx> transactions;
  const SpendingView({
    required this.month,
    required this.months,
    required this.summary,
    required this.byTopLevel,
    required this.average,
    required this.periods,
    required this.trend,
    required this.overview,
    required this.topPlaces,
    required this.transactions,
  });
}

/// Why a typed relay address is refused ([WalletController.relayAddressIssue]).
enum RelayAddressIssue { notAnAddress, needsHttps }

/// The device-local value that holds the relay's creation token.
const relayCreateTokenKey = 'relayCreateToken';

/// App state. Reads everything from the local database and writes through [WalletRepo].
class WalletController extends ChangeNotifier {
  /// The open wallet. Replaced by a fresh empty one after [forgetBrowser].
  WalletRepo repo;
  WalletDb? _db;
  VaultKey? key;

  /// Web: a wrapped key is stored in this browser but not unlocked in this tab (the app shows the Unlock screen).
  bool locked;

  /// Web: another tab of this browser has the wallet open ([WalletInUse]); this tab opened nothing and shows the InUse screen.
  /// [repo] is then an empty placeholder in memory, never the stored wallet.
  final bool inUseElsewhere;

  WalletSettings settings = const WalletSettings();
  late Categorizer categorizer;

  /// Tag writes of the last save that could not be made ([takeTagFailures]).
  int _tagFailures = 0;

  /// Every row the money is counted by (P6): a split payment is one row per part (`Categorizer.expandAll`), the rest one row each.
  /// Sums, insights, budgets, periods, CSV and search read this list.
  /// P15: rows with an owner-set rate are in the wallet currency here (originals in `originalAmount`/`originalCurrency`).
  List<CategorizedTx> txs = const [];

  /// The same rows before conversion (every part, own currency): what core's `matchRows` takes once it lands.
  List<CategorizedTx> rawExpanded = const [];

  /// [wholeTxs] rows with a rate, converted, by payment id: what the lists show ([shown]).
  Map<String, CategorizedTx> _shown = const {};

  /// [t] (a whole-payment row) as the lists show it: in the wallet currency with its original amount when its currency has a rate.
  CategorizedTx shown(CategorizedTx t) => _shown[t.tx.id] ?? t;

  /// One row per payment, whatever its split (`Categorizer.categorize`): for picking and detecting payments (matching, bills,
  /// planned costs, recurring, rule hits, tag suggestions, balances, paydays) and for lists that show a payment once.
  List<CategorizedTx> wholeTxs = const [];

  /// The part rows of each split payment (tx id -> parts, stored order); a payment without a valid split is missing.
  Map<String, List<CategorizedTx>> splitParts = const {};

  /// Ids of payments whose stored split no longer adds up (counted whole; the sheet says so and offers Fix).
  Set<String> splitBrokenIds = const {};
  List<Goal> goals = const [];
  List<WishItem> wish = const [];

  /// Counts [reload]s: the derived values below are cached per version (and per day) and recomputed only after the data changed.
  int dataVersion = 0;
  final Map<MemoKey, Object?> _memo = {};

  /// The day [_memo] was filled for: a new day drops every cached value (old days would only pile up).
  String? _memoDay;

  /// The day the screens last showed (set by [reload] and [checkDay]); a different [today] means the pages are out of date.
  String? _seenDay;

  /// Everything the controller reaches outside the app through (clock, key store, database files, relay, clipboard, platform
  /// objects); built once, never changed. Tests hand in their own (see [WalletControllerDeps]).
  final WalletControllerDeps deps;

  DateTime _clock() => deps.clock();

  /// The creation token to send to [relay]: [stored] unless it is empty or the address is a public `http://` one (a stored address
  /// from before the https rule; the token would travel in the clear).
  static String? createTokenFor(Uri relay, String? stored) =>
      stored == null || stored.isEmpty || relayAddressIssue(relay.toString()) != null ? null : stored;

  /// The real sync run ([WalletControllerDeps.syncRunner]).
  static Future<SyncReport> runRelaySync(Uri relay, VaultKey key, WalletRepo repo) async {
    final transport = RelayTransport(relay, key, createToken: createTokenFor(relay, repo.localValue(relayCreateTokenKey)));
    try {
      return await SyncEngine(transport, key, appVersion: appVersion).run(repo);
    } finally {
      transport.close();
    }
  }

  /// A wallet database exists on this device but the key we have does not open it (or there is no key). It is never deleted or
  /// overwritten: joining with the key that opens it uses it; creating a new wallet sets it aside first. Onboarding says so.
  bool hasUnopenedDb = false;

  /// True while [repo] is the in-memory placeholder used before a key exists (onboarding, web locked): [createWallet],
  /// [joinWallet] and [unlock] then open the keyed database and switch to it.
  bool _dbPending = false;

  /// The relay's address, device-local (`relayUrl` in the local settings); null until one is set.
  Uri? relayUrl;

  /// The sync status the screens show (last run, devices, problems, errors), a [Listenable] of its own; the getters and setters
  /// below forward to it. The controller does not listen to it: it notifies its own listeners exactly where it always did.
  final SyncState sync = SyncState();

  DateTime? get lastSync => sync.lastSync;
  set lastSync(DateTime? v) => sync.lastSync = v;
  String? get syncError => sync.error;
  set syncError(String? v) => sync.error = v;
  bool get syncCaughtUp => sync.caughtUp;
  set syncCaughtUp(bool v) => sync.caughtUp = v;
  List<SyncWaiting> get syncWaiting => sync.waiting;
  set syncWaiting(List<SyncWaiting> v) => sync.waiting = v;
  int get syncBlobsWaiting => sync.blobsWaiting;
  set syncBlobsWaiting(int v) => sync.blobsWaiting = v;
  bool get syncBlobsUnsupported => sync.blobsUnsupported;
  set syncBlobsUnsupported(bool v) => sync.blobsUnsupported = v;
  List<SyncDevice> get syncDevices => sync.devices;
  set syncDevices(List<SyncDevice> v) => sync.devices = v;
  int get syncBadFiles => sync.badFiles;
  set syncBadFiles(int v) => sync.badFiles = v;
  String? get syncRelayInstance => sync.relayInstance;
  set syncRelayInstance(String? v) => sync.relayInstance = v;
  int? get syncRelayBytes => sync.relayBytes;
  set syncRelayBytes(int? v) => sync.relayBytes = v;
  int? get syncRelayMaxBytes => sync.relayMaxBytes;
  set syncRelayMaxBytes(int? v) => sync.relayMaxBytes = v;
  List<SyncProblem> get syncProblems => sync.problems;
  set syncProblems(List<SyncProblem> v) => sync.problems = v;

  /// Core reports a changed relay and an id in use once, so each notice is kept on this device (device-local values, never synced)
  /// until the owner taps OK on it; a new relay address clears both.
  bool get syncRelayChanged => repo.localValue(_noticeRelayChanged) != null;
  bool get syncDeviceIdInUse => repo.localValue(_noticeIdInUse) != null;
  static const _noticeRelayChanged = 'noticeRelayChanged';
  static const _noticeIdInUse = 'noticeDeviceIdInUse';

  /// OK on a Plan › Sync notice: [relayChanged] or the device id one.
  void dismissSyncNotice({required bool relayChanged}) {
    repo.setLocalValue(relayChanged ? _noticeRelayChanged : _noticeIdInUse, null);
    logNav('sync.noticeDismissed', {'which': relayChanged ? 'relayChanged' : 'deviceIdInUse'});
    notifyListeners();
  }

  /// `xxxx-xxxx` of the relay's instance id, to compare with the other devices; null from an older relay.
  String? get relayFingerprintText => syncRelayInstance == null ? null : relayFingerprint(syncRelayInstance!);

  /// A device's clock is ahead, so its newest file waits.
  bool get syncClockDrift => syncProblems.any((p) => p.reason == SyncProblemReason.clockDrift);

  /// The relay's creation token, device-local (`relayCreateToken`, never synced, never logged); empty when none.
  String get relayCreateToken => repo.localValue(relayCreateTokenKey) ?? '';

  /// Saves (or, empty, removes) the creation token and syncs again when a relay is set. Logs `sync.createToken {set}` only.
  Future<void> setRelayCreateToken(String token) async {
    final t = token.trim();
    repo.setLocalValue(relayCreateTokenKey, t.isEmpty ? null : t);
    logEvent(_sync, Level.INFO, 'sync.createToken', {'set': t.isNotEmpty});
    notifyListeners();
    if (t.isNotEmpty && relayUrl != null) await syncNow(trigger: 'token');
  }

  bool get syncing => sync.running;
  set syncing(bool v) => sync.running = v;

  /// Completes when the running sync ends (set while [syncing]); [joinAnotherWallet] waits for it before closing the database.
  Completer<void>? _syncRun;
  List<ImportLine> lastImport = const [];

  Timer? _syncTimer;
  Timer? _dayTimer;
  Timer? _debounce;
  Timer? _persistTimer;

  /// The phone's reminders (Plan › Nudges); [NoNudges] in tests and on desktop.
  NudgePlatform get nudges => deps.nudges;

  /// How long the copied wallet key stays on the clipboard.
  static const keyClipboardLife = Duration(seconds: 60);
  Timer? _clipboardTimer;
  bool _keyPromptPending = false;

  /// The phone's calendars (Plan › Calendars); [NoCalendars] in tests and on desktop and web.
  CalendarSource get calendarSource => deps.calendars;

  /// The Android home-screen widget and launcher shortcut (P13); [NoHomeWidget] in tests, on desktop and on the web. See controller_home.dart.
  HomeWidget get homeWidget => deps.homeWidget;

  /// Device-local calendar state (events read, permission, errors); see controller_future.dart.
  final CalendarState cal = CalendarState();

  /// The camera, picture reading, PDF pages and Share intent of this device (bills); [BillInputs.none] in tests and off Android.
  BillInputs get billInputs => deps.billInputs;

  StreamSubscription<List<SharedFile>>? _shareSub;

  // Home-screen widget and shortcut (P13); the methods are in controller_home.dart.
  StreamSubscription<String>? _actionSub;
  HomeWidgetState? _widgetSent;
  bool _widgetQueued = false, _shortcutAddPending = false;
  final StreamController<void> _shortcutAdds = StreamController<void>.broadcast();
  final StreamController<BillImport> _shareResults = StreamController<BillImport>.broadcast();

  /// True after the system refused the notification permission when the switch was turned on (Plan says how to allow it).
  bool nudgesDenied = false;

  WalletController._(this.repo, this.key, {required this.deps, WalletDb? db, this.locked = false, this.inUseElsewhere = false}) : _db = db {
    relayUrl = _parseRelay(repo.localValue('relayUrl'));
    _applyNumberStyle();
  }

  /// Reads the key, opens the keyed database (only when the key is known) and loads everything. Before a key exists
  /// (onboarding, web locked) the controller runs on an in-memory placeholder; [createWallet], [joinWallet] and [unlock] open
  /// the file database later. A database file the key does not open stays untouched ([hasUnopenedDb]). Logs each startup phase as
  /// `app.start`. If another browser tab has the wallet open ([claim] throws [WalletInUse]), nothing is opened or written and
  /// [inUseElsewhere] is true. [deps] and [claim] are for tests.
  static Future<WalletController> load({
    WalletControllerDeps? deps,
    Future<void> Function() claim = claimWalletDb,
  }) async {
    final d = deps ?? WalletControllerDeps.platform();
    var sw = Stopwatch()..start();
    try {
      await claim();
    } on WalletInUse {
      logEvent(_log, Level.WARNING, 'app.start', {'phase': 'db', 'inUse': true});
      return WalletController._(WalletRepo.inMemory(), null, deps: d, inUseElsewhere: true);
    }

    VaultKey? key;
    try {
      key = await d.keyReader();
    } catch (e, st) {
      // The app then shows onboarding; the error says why the stored key could not be read.
      logError(_key, 'key.readFailed', e, st, level: Level.SEVERE);
      key = null;
    }
    final locked = key == null && d.isLocked();
    logEvent(_log, Level.INFO, 'app.start', {'phase': 'key', 'ms': sw.elapsedMilliseconds, 'found': key != null});

    sw = Stopwatch()..start();
    WalletDb? db;
    var unopened = false;
    // An interrupted "join another wallet" leaves a marker (written before the new key): the key then opens no wallet.db (it was
    // set aside already, or never will be), and the join is finished from the marker: fresh id, relay, then sync.
    Map<String, Object?>? marker;
    var finishedJoin = false;
    if (key != null) {
      try {
        final raw = await d.joinMarkerReader();
        if (raw != null && raw.trim().isNotEmpty) marker = Map<String, Object?>.from(jsonDecode(raw) as Map);
      } catch (e, st) {
        logError(_log, 'join.markerReadFailed', e, st);
      }
    }
    final markerId = marker?['id'] as String?;
    if (key != null) {
      try {
        if (marker != null && !await d.dbExists()) {
          db = await _openWithId(d.dbOpener, key, d.deviceIdReader, d.deviceIdWriter, fresh: true, useId: markerId);
          finishedJoin = true;
        } else {
          db = await _openWithId(d.dbOpener, key, d.deviceIdReader, d.deviceIdWriter);
        }
      } on WalletInUse {
        logEvent(_log, Level.WARNING, 'app.start', {'phase': 'db', 'inUse': true});
        return WalletController._(WalletRepo.inMemory(), null, deps: d, inUseElsewhere: true);
      } on WalletDbKeyException {
        var finished = false;
        if (marker != null) {
          // The new key was written but the old file was never moved: move it now and open the new wallet.
          try {
            await d.dbSetAside(isoDate(d.clock()));
            db = await _openWithId(d.dbOpener, key, d.deviceIdReader, d.deviceIdWriter, fresh: true, useId: markerId);
            finished = finishedJoin = true;
          } catch (e, st) {
            logError(_log, 'join.resumeFailed', e, st, level: Level.SEVERE);
          }
        }
        if (!finished) {
          // The stored key does not open the file: leave the file alone and start at onboarding.
          logEvent(_log, Level.WARNING, 'app.start', {'phase': 'db', 'keyMismatch': true});
          key = null;
          unopened = true;
        }
      }
    } else if (!locked) {
      unopened = await d.dbExists();
    }
    logEvent(_log, Level.INFO, 'app.start', {'phase': 'db', 'ms': sw.elapsedMilliseconds, 'opened': db != null, 'unopened': unopened});

    sw = Stopwatch()..start();
    final c = WalletController._(db?.repo ?? WalletRepo.inMemory(), key, deps: d, db: db, locked: locked);
    c._dbPending = db == null;
    c.hasUnopenedDb = unopened;
    if (marker != null && db != null) {
      // Join finished from the marker (or already finished before the marker was cleared): the relay it carried, then clear it.
      final relay = marker['relay'] as String?;
      if (relay != null && c.repo.localValue('relayUrl') == null && parseRelayAddress(relay) != null) {
        c.repo.setLocalValue('relayUrl', parseRelayAddress(relay).toString());
        c.relayUrl = parseRelayAddress(relay);
      }
      if (finishedJoin) {
        c.repo.setLocalValue('keyBackupConfirmed', c.today());
        logEvent(_log, Level.WARNING, 'wallet.joinResumed', {'relay': c.relayUrl != null});
      }
      await c._clearJoinMarker();
    }
    c.reload();
    logEvent(_log, Level.INFO, 'app.start',
        {'phase': 'reload', 'ms': sw.elapsedMilliseconds, 'tx': c.wholeTxs.length, 'relay': c.relayUrl != null, 'logLevel': c.logLevel});
    c._startAutoSync();
    c.refreshRecurring();
    scheduleMicrotask(c.rescheduleNudges);
    scheduleMicrotask(() => c.readCalendars(trigger: 'start'));
    c.startHomeIntegration();
    return c;
  }

  /// Opens the keyed database for [key] through [opener]; logs `db.open` (phases and timings only).
  static Future<WalletDb> _openKeyed(Future<WalletDb> Function(Uint8List dbKey, {String? deviceId}) opener, VaultKey key,
      {String? deviceId}) async {
    final sw = Stopwatch()..start();
    final db = await opener(await localDbKey(key), deviceId: deviceId);
    logEvent(_log, Level.INFO, 'db.open', {'keyed': true, 'converted': db.converted, 'ms': sw.elapsedMilliseconds});
    return db;
  }

  static final _deviceIdOk = RegExp(r'^[A-Za-z0-9]{1,48}$');

  /// Opens the keyed database with this install's device id (H6). The id lives next to the key, not in the database. The first
  /// open after an upgrade finds none: the database's own id is opened as it is and moved into the store once; from then on
  /// every open passes the stored id. [fresh] (a new or joined wallet) makes and stores a new id before opening. The id is
  /// never logged, a store that fails is (`deviceId.storeFailed`) and the app goes on with the database's own id.
  static Future<WalletDb> _openWithId(Future<WalletDb> Function(Uint8List dbKey, {String? deviceId}) opener, VaultKey key,
      Future<String?> Function() read, Future<void> Function(String id) write,
      {bool fresh = false, String? useId}) async {
    String? id;
    var store = false;
    if (fresh) {
      id = useId != null && _deviceIdOk.hasMatch(useId) ? useId : WalletRepo.newDeviceId();
      store = true;
    } else {
      try {
        id = await read();
      } catch (e, st) {
        logError(_log, 'deviceId.readFailed', e, st);
      }
      if (id != null && !_deviceIdOk.hasMatch(id)) {
        logEvent(_log, Level.WARNING, 'deviceId.invalid');
        id = null;
      }
      store = id == null;
    }
    if (fresh) await _storeDeviceId(write, id!);
    final db = await _openKeyed(opener, key, deviceId: id);
    if (store && !fresh) await _storeDeviceId(write, db.repo.deviceId);
    return db;
  }

  static Future<void> _storeDeviceId(Future<void> Function(String id) write, String id) async {
    try {
      await write(id);
    } catch (e, st) {
      logError(_log, 'deviceId.storeFailed', e, st);
    }
  }

  /// Switches from the in-memory placeholder to the opened [db]: the screens reload from it.
  void _useDb(WalletDb db) {
    final old = repo;
    _db = db;
    repo = db.repo;
    _dbPending = false;
    if (!identical(old, repo)) old.close();
    relayUrl = _parseRelay(repo.localValue('relayUrl'));
    reload();
  }

  Future<void> _setAsideUnopened() async {
    await deps.dbSetAside(isoDate(_clock()));
    hasUnopenedDb = false;
    logEvent(_log, Level.WARNING, 'db.setAside');
  }

  /// Opens the keyed database for [k] and switches to it. An unopened older file is never overwritten: if [k] opens it, it is
  /// used; if not, it is set aside first (`db.setAside`, no paths logged) and a new database is created. With [newWallet] the
  /// file is set aside without trying [k]. With [asideOnMismatch] false a [WalletDbKeyException] is thrown instead (unlock).
  Future<void> _openFileDb(VaultKey k, {bool newWallet = false, bool asideOnMismatch = true, bool freshId = false}) async {
    if (newWallet && hasUnopenedDb) await _setAsideUnopened();
    Future<WalletDb> open() => _openWithId(deps.dbOpener, k, deps.deviceIdReader, deps.deviceIdWriter, fresh: freshId);
    WalletDb db;
    try {
      db = await open();
    } on WalletDbKeyException {
      if (!asideOnMismatch) rethrow;
      await _setAsideUnopened();
      db = await open();
    }
    hasUnopenedDb = false;
    _useDb(db);
  }

  /// For widget tests: an already-open repo (e.g. [WalletRepo.inMemory]), no auto-sync. [clock] stands in for the current time.
  @visibleForTesting
  factory WalletController.forTest(WalletRepo repo,
          {VaultKey? key,
          WalletControllerDeps? deps,
          DateTime Function()? clock,
          NudgePlatform? nudges,
          CalendarSource? calendars,
          HomeWidget? homeWidget,
          BillInputs? billInputs,
          WalletDb? db,
          bool locked = false}) =>
      WalletController._(repo, key,
          deps: (deps ??
                  WalletControllerDeps.platform(
                      nudges: const NoNudges(),
                      calendars: const NoCalendars(),
                      homeWidget: const NoHomeWidget(),
                      billInputs: const BillInputs.none()))
              .copyWith(clock: clock, nudges: nudges, calendars: calendars, homeWidget: homeWidget, billInputs: billInputs),
          db: db,
          locked: locked)
        ..reload();

  /// The saved monthly budgets per category (cents).
  Map<String, int> get categoryBudgets => settings.categoryBudgets;

  bool get hasWallet => key != null;
  String get currency => settings.currency;

  /// The current moment from the injected clock (tests move it); widgets use this, never `DateTime.now()`.
  DateTime get now => _clock();

  String today() => isoDate(_clock());

  /// The payments left on the loan (core's [loanLeft]) or null; Plan's ledger shows it under the Loan line.
  LoanLeft? loanLeftNow() => loanLeft(settings, today());

  /// Tells the screens when the day has changed since they were last built (the app stayed open over midnight), so periods,
  /// months and the delivery panel move on without a data change. Called on resume and by the periodic timer.
  void checkDay() {
    final d = today();
    if (_seenDay == null || d == _seenDay) return;
    logEvent(_log, Level.INFO, 'day.changed', {'from': _seenDay, 'to': d});
    _seenDay = d;
    notifyListeners();
    _widgetMayHaveChanged();
  }

  /// Every change reaches the screens through here; where the database lives in memory first (the browser) it is also written
  /// to storage within a second.
  @override
  void notifyListeners() {
    numberStyle = _numberStyle; // before the screens rebuild; read from the repo only on load, reload and change
    super.notifyListeners();
    sync.flush(); // the sub-states tell their own listeners after the controller's, never the other way round
    cal.flush();
    final db = _db;
    if (db == null || !db.persists || (_persistTimer?.isActive ?? false)) return;
    _persistTimer = Timer(const Duration(milliseconds: 800), () => unawaited(persistNow()));
  }

  /// Writes pending database changes to storage now (a no-op where the database writes by itself). Also called when the page
  /// is hidden or closing.
  Future<void> persistNow() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    try {
      await _db?.persist();
    } catch (e, st) {
      logError(_log, 'db.persistFailed', e, st);
    }
  }

  void reload() {
    final t = PerfTimer('wc.reload');
    _applyNumberStyle(); // the repo may have been switched
    settings = repo.settings();
    categorizer = repo.categorizer();
    final raw = repo.transactions(); // logs repo.transactions
    final whole = <CategorizedTx>[];
    final expanded = <CategorizedTx>[];
    timed('wc.categorize', () {
      for (final t in raw) {
        final rows = categorizer.expand(t);
        expanded.addAll(rows);
        // An unsplit payment is its own row; a split one is categorized whole again.
        whole.add(rows.length == 1 && !rows.first.isPart ? rows.first : categorizer.categorize(t));
      }
    }, fields: {'tx': raw.length});
    wholeTxs = whole;
    rawExpanded = expanded;
    final shownWhole = inHomeCurrency(whole, settings);
    _shown = identical(shownWhole, whole)
        ? const {}
        : {
            for (final t in shownWhole)
              if (t.originalAmount != null) t.tx.id: t
          };
    txs = inHomeCurrency(expanded, settings); // P15: rows with an owner-set rate count in the wallet currency
    final parts = <String, List<CategorizedTx>>{};
    final broken = <String>{};
    for (final c in txs) {
      if (c.isPart) (parts[c.tx.id] ??= []).add(c);
      if (c.splitBroken) broken.add(c.tx.id);
    }
    splitParts = parts;
    splitBrokenIds = broken;
    final (g, w) = timed('wc.goalsWish', () => (repo.goals(), repo.wishlist()));
    goals = g;
    wish = w;
    dataVersion++;
    _memo.clear();
    _seenDay = _memoDay = today();
    t.done({'tx': wholeTxs.length, 'goals': goals.length, 'wish': wish.length});
    notifyListeners();
    _headsUpsMayHaveChanged();
    _widgetMayHaveChanged();
  }

  /// [_cached] for extensions in other files (the insights API): the value is kept until the data or the day changes.
  T memo<T>(MemoKey key, T Function() compute) => _cached(key, compute);

  final Map<String, InsightRange> _insightRanges = {};

  /// The range one Insights graph shows (kept for the session; its kind is remembered on this device).
  InsightRange insightRange(String id) => _insightRanges.putIfAbsent(id, () => InsightRange(this, id));

  /// Derived values are computed once per [dataVersion] and day, however often a screen asks (every build, every tab).
  T _cached<T>(MemoKey key, T Function() compute) {
    final day = today();
    if (day != _memoDay) {
      _memo.clear();
      _memoDay = day;
    }
    if (_memo.containsKey(key)) return _memo[key] as T;
    final v = compute();
    // The day may have changed while computing (an inner call cleared the memo): this value is for the old day.
    if (_memoDay == day) _memo[key] = v;
    return v;
  }

  /// This month's Food delivery orders: how many, and the total spent (positive cents).
  (int, int) get deliveries => _cached(const MemoKey('deliveries'), () {
        final month = monthOf(today());
        final xs = txs.where((t) =>
            categoryTable.topLevel(t.category) == 'Food delivery' && t.tx.currency == currency && monthOf(t.date) == month && t.amount < 0);
        return (xs.map((t) => t.tx.id).toSet().length, -xs.fold<int>(0, (a, t) => a + t.amount)); // orders, not parts
      });

  /// How many Food delivery orders the last 90 days hold (today and the 89 days before it; the wallet's currency only). Today shows its delivery-hour panel only when this is
  /// above 0, so a wallet that never orders in never sees it. Cached per data version and day.
  int get deliveryOrders90 => _cached(const MemoKey('deliveryOrders90'), () {
        final from = addDays(today(), -89);
        return txs
            .where((t) =>
                categoryTable.topLevel(t.category) == 'Food delivery' &&
                t.tx.currency == currency &&
                t.amount < 0 &&
                t.date.compareTo(from) >= 0)
            .map((t) => t.tx.id)
            .toSet()
            .length;
      });

  /// The sum of every goal's target (cents).
  int get goalTargetTotal => _cached(const MemoKey('goalTargetTotal'), () => goals.fold<int>(0, (a, g) => a + g.target));

  /// The sum of the prices of wishes still cooling off (cents). Not cached: it depends on the clock ([now], the injected one in tests).
  int get waitingTotal {
    final now = _clock().millisecondsSinceEpoch;
    return wish.where((w) => w.status == 'waiting' && w.hoursLeft(settings.coolHours, now) > 0).fold<int>(0, (a, w) => a + w.price);
  }

  /// The date of the newest transaction per bank source (`pbz`, `revolut`); a source without rows is missing.
  Map<String, String> get latestBySource => _cached(const MemoKey('latestBySource'), () {
        final out = <String, String>{};
        for (final t in wholeTxs) {
          out.putIfAbsent(t.tx.source, () => t.date); // txs are newest first
          if (out.containsKey('pbz') && out.containsKey('revolut')) break;
        }
        return out;
      });

  List<String> get _paydays => _cached(const MemoKey('paydays'), () => salaryPaydays(wholeTxs, today(), currency: currency));

  /// The period start: saved value, or the latest payday (its first salary payment), or today.
  WalletSettings get effectiveSettings => _cached(const MemoKey('effective'), () {
        if (settings.periodStart != null) return settings;
        final m = settings.toMap()..['periodStart'] = _paydays.lastOrNull ?? today();
        return WalletSettings.fromMap(m, table: categoryTable);
      });

  /// A payday more than 20 days after the current period start, not yet started as a new month.
  String? newPayday(String periodStart) => _paydays.where((d) => d.compareTo(addDays(periodStart, 20)) > 0).lastOrNull;

  /// The budget of the running pay period. Confirmed recurring bills are reserved in it (`reservedBills`, `dueBills`).
  PeriodBudget period() => _cached(
      const MemoKey('period'),
      () => timed(
          'wc.period',
          () => computePeriod(txs, effectiveSettings, goals, today(),
              bills: recurringBills(), planned: plannedOpen(), table: categoryTable, matchRows: rawExpanded),
          warnMs: 50));

  /// Saved or lost per pay period (salary to salary), oldest first; the last one is still running.
  List<PeriodSummary> payPeriods({int count = 12}) => _cached(MemoKey('payPeriods', count),
      () => timed('wc.payPeriods', () => periodSummaries(txs, settings, today(), count: count), fields: {'count': count}, warnMs: 50));

  /// What the Spending tab shows for month [sel] (`YYYY-MM`, default: this month). Cached per month until the data changes.
  SpendingView spending([String? sel]) {
    final current = monthOf(today());
    final months = monthsEnding(current, 13);
    final month = sel != null && months.contains(sel) ? sel : current;
    return _cached(
        MemoKey('spending', month),
        () => timed('spending.derive', () {
              final sums = [
                for (final m in months)
                  _cached(MemoKey('monthSummary', m),
                      () => timed('wc.monthSummary', () => monthSummary(txs, m, currency: currency), fields: {'month': m}))
              ];
              final selSum = sums.firstWhere((s) => s.month == month);
              final avg = averageByCategory(txs, month,
                  currency: currency, table: categoryTable); // the same 6-month average the suggested budgets use
              final periods = payPeriods(count: 12);

              final merch = <String, (int, int)>{};
              // The list shows each payment once (its parts hang under it, `splitParts`); the places add up the parts.
              final monthTxs = [
                for (final t in wholeTxs)
                  if (monthOf(t.date) == month && t.kind != BudgetKind.transfer) t
              ];
              final merchSeen = <String>{};
              for (final t in txs) {
                if (monthOf(t.date) != month) continue;
                if (t.kind == BudgetKind.flex && t.amount < 0) {
                  final k = merchantName(t.tx);
                  final (n, v) = merch[k] ?? (0, 0);
                  merch[k] = (merchSeen.add('${t.tx.id}|$k') ? n + 1 : n, v - t.amount); // orders, not parts
                }
              }
              final top = merch.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
              return SpendingView(
                month: month,
                months: months,
                summary: selSum,
                byTopLevel: selSum.byCategory,
                average: avg,
                periods: periods,
                trend: trendNet(periods),
                overview: savingsOverview(periods),
                topPlaces: [for (final e in top.take(8)) (e.key, e.value.$1, e.value.$2)],
                transactions: monthTxs,
              );
            }, fields: {'month': month, 'tx': txs.length}, warnMs: 100));
  }

  /// Budget against spending per category for [month] (`YYYY-MM`). Cached per month until the data changes.
  BudgetVsActual budgetVsActual(String month) => _cached(
      MemoKey('budget', month),
      () => timed(
          'wc.budgetVsActual', () => _computeBudget(txs, month, categoryBudgets, today: today(), currency: currency, table: categoryTable),
          fields: {'month': month, 'tx': txs.length}, warnMs: 50));

  /// Budgets worked out from the 6 months before [month], per category (cents, rounded up to 10).
  Map<String, int> suggestedBudgets(String month) => _cached(
      MemoKey('suggest', month),
      () => timed('wc.suggestBudgets', () => suggestBudgets(txs, month, currency: currency, table: categoryTable),
          fields: {'month': month}, warnMs: 50));

  /// The budgeted category with the least money left this month, or null when nothing is budgeted.
  CategoryBudgetLine? tightestBudget() => _cached(const MemoKey('tightest'), () {
        CategoryBudgetLine? best;
        for (final l in budgetVsActual(monthOf(today())).lines) {
          final r = l.remaining;
          if (r != null && (best == null || r < best.remaining!)) best = l;
        }
        return best;
      });

  /// Saves the whole map of budgets (an empty map clears them): one settings row per category that changed (schema 8),
  /// a missing category is removed. Logs the count only.
  void saveCategoryBudgets(Map<String, int> budgets) {
    final old = settings.categoryBudgets;
    for (final c in {...old.keys, ...budgets.keys}) {
      if (old[c] != budgets[c]) repo.setCategoryBudget(c, budgets[c]);
    }
    logEvent(_log, Level.INFO, 'budgets.saved', {'count': budgets.length}); // never the categories or amounts
    _changed();
  }

  /// Lets the controller_future.dart extension tell the screens something changed (notifyListeners is protected).
  void _refreshView() => notifyListeners();

  void _changed() {
    reload();
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => syncNow(quiet: true, trigger: 'change'));
  }

  // ---------- habits: weekly review, recurring bills, nudges ----------
  /// The day of the week the review is due from (1 = Monday … 7 = Sunday, default Sunday).
  int get reviewDay => settings.reviewDay;

  /// The date of the last finished review, or null.
  String? get lastReview => settings.lastReview;

  /// Spending rows of the last 7 days without a category the owner set: the rows the review's "Confirm categories" step
  /// counts (same rule as core's `reviewState`). "Looks right" and the category sheet pin the category, so the row leaves
  /// the list. Cached per data version and day.
  List<CategorizedTx> reviewRows() => _cached(const MemoKey('reviewRows'), () {
        final to = today(), from = addDays(to, -7);
        return [
          for (final t in wholeTxs)
            if (t.tx.live &&
                t.date.compareTo(from) > 0 &&
                t.date.compareTo(to) <= 0 &&
                (t.kind == BudgetKind.fixed || t.kind == BudgetKind.flex) &&
                (t.tx.category == null || !categoryTable.isLive(t.tx.category!)))
              t
        ];
      });

  /// "Looks right" / after the category sheet: the row keeps the category it has now as the owner's choice, and the bank
  /// merchant learns it (as the category sheet does), so the row leaves the review list.
  void confirmCategory(Tx t) {
    final now = wholeTxs.where((x) => x.tx.id == t.id).firstOrNull ?? categorizer.categorize(t);
    final cat = now.category;
    logEvent(_log, Level.INFO, 'category.confirm', {'category': _logCategory(cat), 'source': t.source}); // never the merchant
    if (t.source != 'manual') repo.setMerchantRule(merchantKey(t), cat);
    repo.setCategory(t.id, cat);
    _changed();
  }

  /// This month's budgeted categories that are over budget or spending faster than the month passes.
  List<CategoryBudgetLine> paceRows() => _cached(
      const MemoKey('paceRows'),
      () => [
            for (final l in budgetVsActual(monthOf(today())).lines)
              if (l.over || (l.pace ?? 0) > 1.0) l
          ]);

  /// Wishes that finished the cooling-off wait and wait for buy or skip. Depends on the clock, so it is not cached.
  List<WishItem> readyWishes() {
    final now = _clock().millisecondsSinceEpoch;
    return wish.where((w) => w.status == 'waiting' && w.hoursLeft(settings.coolHours, now) <= 0).toList();
  }

  /// Is the weekly review due, its steps with counts, and the streak. Cached per data version and day.
  ReviewState reviewState() => _cached(
      const MemoKey('reviewState'),
      () => reviewStateOf(txs, settings, wish, categoryBudgets,
          today: today(), nowMillis: _clock().millisecondsSinceEpoch, table: categoryTable));

  /// Finishes this week's review (writes the date; the streak grows by one).
  void markReviewDone() {
    final r = reviewState();
    repo.markReviewDone(today());
    logEvent(_habits, Level.INFO, 'review.done', {
      'categories': r.count('categories'),
      'pace': r.count('pace'),
      'wishlist': r.count('wishlist'),
    }); // counts only
    _changed();
  }

  void setReviewDay(int day) {
    if (day < 1 || day > 7 || day == reviewDay) return;
    repo.updateSettings({'reviewDay': day});
    logEvent(_habits, Level.INFO, 'review.day', {'day': day});
    _changed();
  }

  /// Recurring bills worth showing: candidates and confirmed (dismissed ones stay hidden). Cached per data version.
  /// P9: this list holds the recurring **incomes** too; anything that treats a row as a bill reads [expectedBills] instead.
  List<RecurringBill> recurringBills() => _cached(const MemoKey('recurringBills'), repo.recurringBills);

  /// The recurring bills only (no incomes): candidates and confirmed. Cached per data version.
  List<RecurringBill> expectedBills() => _cached(
      const MemoKey('expectedBills'),
      () => [
            for (final b in recurringBills())
              if (!b.isIncome) b
          ]);

  /// The recurring incomes only (P9): candidates and confirmed. Cached per data version.
  List<RecurringBill> expectedIncomes() => _cached(
      const MemoKey('expectedIncomes'),
      () => [
            for (final b in recurringBills())
              if (b.isIncome) b
          ]);

  /// Looks for bills again in the imported rows (after an import and at start).
  void refreshRecurring() {
    try {
      repo.refreshRecurring(today());
      logEvent(_habits, Level.FINE, 'recurring.refresh', {'bills': repo.recurringBills().length});
    } catch (e, st) {
      logError(_habits, 'recurring.refreshFailed', e, st);
    }
  }

  /// Was the bill's last payment made in the running pay period (the "Paid" mark on Bills)?
  bool billPaidThisPeriod(RecurringBill b) {
    final id = b.lastPaidTx;
    if (id == null) return false;
    // One id -> date map per data version: the Bills tab asks once per bill on every build.
    final dates = memo<Map<String, String>>(const MemoKey('bills.txDates'), () {
      final m = <String, String>{};
      for (final t in wholeTxs) {
        m.putIfAbsent(t.tx.id, () => t.date);
      }
      return m;
    });
    final date = dates[id];
    return date != null && date.compareTo(period().start) >= 0;
  }

  void confirmRecurring(String id) {
    repo.confirmRecurring(id);
    logEvent(_habits, Level.INFO, 'recurring.confirm', {'bills': recurringBills().length}); // never payee or amount
    _changed();
  }

  /// A confirmed bill whose payment did not match: moves its due date on by one cycle, so it stops being reserved.
  Future<void> skipRecurring(String id) async {
    try {
      await repo.skipRecurring(id);
      logEvent(_habits, Level.INFO, 'recurring.skip', {'bills': recurringBills().length});
    } on ClockBehindException catch (e) {
      noticeClockBehind(e);
    } catch (e, st) {
      logError(_habits, 'recurring.skipFailed', e, st);
    }
    _changed();
  }

  void dismissRecurring(String id) {
    repo.dismissRecurring(id);
    logEvent(_habits, Level.INFO, 'recurring.dismiss', {'bills': recurringBills().length});
    _changed();
  }

  void deleteRecurring(String id) {
    repo.deleteRecurring(id);
    logEvent(_habits, Level.INFO, 'recurring.delete', {'bills': recurringBills().length});
    _changed();
  }

  /// Device-local (never synced): are reminders on?
  bool get nudgesEnabled => repo.localValue('nudgesEnabled') == '1';

  /// Turns reminders on or off. On: asks the system for permission first; when refused the switch stays off and
  /// [nudgesDenied] says why. Returns whether reminders are on afterwards.
  Future<bool> setNudges(bool on) async {
    try {
      if (!on) {
        repo.setLocalValue('nudgesEnabled', null);
        nudgesDenied = false;
        await nudges.cancelAll();
        logEvent(_nudgeLog, Level.INFO, 'nudges.enabled', {'on': false});
        notifyListeners();
        await rescheduleHeadsUps(); // cancelAll took the heads-ups too
        return false;
      }
      final granted = await nudges.requestPermission();
      logEvent(_nudgeLog, Level.INFO, 'nudges.enabled', {'on': granted, 'granted': granted});
      nudgesDenied = !granted;
      if (granted) repo.setLocalValue('nudgesEnabled', '1');
      notifyListeners();
      if (granted) await rescheduleNudges();
      return granted;
    } catch (e, st) {
      logError(_nudgeLog, 'nudges.setFailed', e, st, fields: {'on': on});
      notifyListeners();
      return nudgesEnabled;
    }
  }

  /// Schedules the next days of reminders again (app start, resume): the list is only ever 4 weeks long.
  Future<void> rescheduleNudges() async {
    if (!nudges.supported) return;
    if (nudgesEnabled) {
      try {
        final n = await nudges.schedule(nudgeSlots(_clock()));
        logEvent(_nudgeLog, Level.INFO, 'nudges.scheduled', {'count': n});
      } catch (e, st) {
        logError(_nudgeLog, 'nudges.scheduleFailed', e, st);
      }
    }
    await rescheduleHeadsUps(); // scheduling the reminders cancelled everything, heads-ups included
  }

  // ---------- wallet / key ----------
  /// [passphrase]: the web build wraps the key with it (the other builds ignore it).
  Future<void> createWallet({String? passphrase}) async {
    final k = VaultKey.generate();
    // The older file goes aside before the key is written: a crash in between must not leave a key next to a plaintext file
    // (the next start would convert that file under the new wallet's key). A crash after the key only costs an empty database.
    if (_dbPending && hasUnopenedDb) await _setAsideUnopened();
    await deps.keyWriter(k, passphrase: passphrase);
    if (_dbPending) await _openFileDb(k, newWallet: true, freshId: true);
    key = k;
    _keyPromptPending = true; // HomeShell asks the owner to save the key before the first Today
    logEvent(_log, Level.INFO, 'wallet.create', {'defaultGoals': repo.goals().isEmpty});
    if (repo.goals().isEmpty) {
      repo.saveGoal(name: 'Emergency fund', target: 300000, saved: 0, monthly: 10000, sort: 1);
      repo.saveGoal(name: 'Yearly costs', target: 120000, saved: 0, monthly: 10000, sort: 2);
    }
    _changed();
  }

  /// Joins with the wallet [text] key. [relay] (optional, can be set later in Plan) is the relay address; the first sync follows.
  /// [keyWritten]: the key is already in the key store ([joinAnotherWallet] wrote it before setting the old database aside).
  Future<void> joinWallet(String text, {String? passphrase, Uri? relay, bool keyWritten = false}) async {
    final k = await VaultKey.parse(text); // errors are logged by the caller (never the text)
    final r = relay == null ? null : parseRelayAddress(relay.toString());
    if (relay != null && r == null) throw const FormatException('Not a relay address');
    // No key was stored but an unkeyed (plaintext) file exists: it belongs to no wallet we can name, and opening it with this key
    // would convert it and merge its data into the joined wallet. Set it aside (before the key is written, as in create).
    if (_dbPending && hasUnopenedDb && await deps.dbIsPlaintext()) await _setAsideUnopened();
    if (!keyWritten) await deps.keyWriter(k, passphrase: passphrase);
    if (_dbPending) await _openFileDb(k, freshId: true);
    key = k;
    repo.setLocalValue('keyBackupConfirmed', today()); // they typed the key in, so they have it
    if (r != null) {
      repo.setLocalValue('relayUrl', r.toString());
      relayUrl = r;
    }
    logEvent(_log, Level.INFO, 'wallet.join', {'relay': r != null});
    notifyListeners();
    await syncNow(trigger: 'join');
  }

  /// Plan › "Join another wallet…": joins the wallet with [text] while this one is open. Checked first, nothing touched on a
  /// failure: the key parses, the relay is an address, this wallet's own key was saved ([KeyNotSaved]) and [text] is not this wallet's
  /// key ([WalletAlreadyOpen]). Then, in this order: a last sync of pending changes (after that no sync starts: `_joining`); the old
  /// key is stored in a second slot (`KeyStore.writeAside`); a "join pending" marker (relay, fresh device id; a side file, never the
  /// database); the new key is written; the database is closed and moved aside (`wallet.db.unopened-<date>`, `db.setAside`, never
  /// deleted); the join goes on as on a first run; the marker is cleared. A crash on the way: the next start finds the marker and a
  /// key that opens no `wallet.db` and finishes the join from it (see [load]). Not on the web (no set-aside path).
  /// The old key never leaves the device while the old database exists: a slot is removed only once the old wallet is open again.
  Future<void> joinAnotherWallet(String text, {String? passphrase, Uri? relay}) async {
    final k = await VaultKey.parse(text);
    if (relay != null && parseRelayAddress(relay.toString()) == null) throw const FormatException('Not a relay address');
    final current = key;
    if (current != null && await current.toText() == await k.toText()) throw const WalletAlreadyOpen();
    if (!_dbPending && !keyBackupConfirmed) throw const KeyNotSaved();
    final written = !_dbPending;
    if (written) {
      await clearHomeWidget(); // the old wallet's number must not stay on the home screen
      await _setAsideOpenWallet(k, passphrase, relay);
      await clearHomeWidget(); // a reload on the way may have given it again
    }
    try {
      await joinWallet(text, passphrase: passphrase, relay: relay, keyWritten: written);
    } catch (e) {
      // The old wallet is already set aside: show first-run onboarding, so nothing looks open that is not. The marker stays: the
      // next start finishes the join.
      key = null;
      notifyListeners();
      await clearHomeWidget();
      rethrow;
    }
    await _clearJoinMarker();
  }

  /// True while [joinAnotherWallet] is closing and moving the database: [syncNow] does nothing then (a resume or a relay follow-up
  /// must not start a run on a repo that is about to close).
  bool _joining = false;

  /// Ends the running sync and sends what is still pending, then stores the old key aside, writes the marker and [newKey], closes
  /// the open database and moves it aside; the controller then runs on the in-memory placeholder like before a first key. A failure
  /// puts the old key back and opens the old database again, then throws.
  Future<void> _setAsideOpenWallet(VaultKey newKey, String? passphrase, Uri? relay) async {
    _syncTimer?.cancel();
    _dayTimer?.cancel();
    _debounce?.cancel();
    _persistTimer?.cancel();
    await _syncRun?.future;
    if (relayUrl != null && repo.pendingOps().isNotEmpty) await syncNow(quiet: true, trigger: 'beforeJoin');
    _joining = true;
    try {
      await _setAsideJoining(newKey, passphrase, relay);
    } finally {
      _joining = false;
    }
    _startAutoSync();
  }

  Future<void> _setAsideJoining(VaultKey newKey, String? passphrase, Uri? relay) async {
    while (_syncRun != null) {
      await _syncRun!.future; // one that began before the flag was set
    }
    await persistNow();
    final stamp = isoDate(_clock());
    final oldKey = key!;
    String? slot;
    try {
      slot = await deps.keyAsideWriter(stamp, oldKey);
      await deps.joinMarkerWriter(_joinMarkerText(relay));
      await deps.keyWriter(newKey, passphrase: passphrase);
    } catch (e, st) {
      logError(_log, 'db.setAside.keyFailed', e, st, level: Level.SEVERE);
      if (slot != null) {
        // Put the old key back first; only when that worked is the slot (and the marker) given up.
        try {
          await deps.keyWriter(oldKey);
          await _removeAsideKey(slot);
          await _clearJoinMarker();
        } catch (e2, st2) {
          logError(_log, 'db.setAside.keyRestoreFailed', e2, st2, level: Level.SEVERE);
        }
      }
      _startAutoSync();
      rethrow;
    }
    await _syncRun?.future; // nothing may still be running when the repo closes
    final old = repo;
    _db = null;
    repo = WalletRepo.inMemory();
    _dbPending = true;
    old.close();
    try {
      await deps.dbSetAside(stamp);
    } catch (e, st) {
      logError(_log, 'db.setAside.failed', e, st, level: Level.SEVERE);
      try {
        // A partial move (wallet.db gone) is not "reopened" as a new empty wallet.db.
        if (!await deps.dbExists()) throw StateError('wallet.db is gone after a partial set-aside');
        await deps.keyWriter(oldKey);
        await _openFileDb(oldKey, asideOnMismatch: false);
        await _removeAsideKey(slot);
        await _clearJoinMarker();
      } catch (e2, st2) {
        logError(_log, 'db.reopenFailed', e2, st2, level: Level.SEVERE);
        // Nothing is open: first-run onboarding says an older wallet is on this device. The slot stays (the old key is the only way
        // to open that copy); the marker goes, so the next start does not build a new wallet next to what is left.
        hasUnopenedDb = true;
        key = null;
        try {
          await deps.keyWriter(oldKey);
        } catch (e3, st3) {
          logError(_log, 'db.keyRestoreFailed', e3, st3, level: Level.SEVERE);
        }
        await _clearJoinMarker();
        notifyListeners();
      }
      _startAutoSync();
      rethrow;
    }
    logEvent(_log, Level.WARNING, 'db.setAside', {'reason': 'join'});
    hasUnopenedDb = false;
    _resetSyncStatus();
    lastImport = const [];
  }

  /// The small device-local "join pending" note: the relay address (if any) and the device id the new wallet will use. Never the
  /// key, never in the database.
  String _joinMarkerText(Uri? relay) => jsonEncode({'v': 1, 'relay': relay?.toString(), 'id': WalletRepo.newDeviceId()});

  Future<void> _clearJoinMarker() async {
    try {
      await deps.joinMarkerClearer();
    } catch (e, st) {
      logError(_log, 'join.markerClearFailed', e, st);
    }
  }

  Future<void> _removeAsideKey(String slot) async {
    try {
      await deps.keyAsideRemover(slot);
    } catch (e, st) {
      logError(_log, 'db.setAside.slotFailed', e, st);
    }
  }

  /// Nothing of the old wallet's sync status, devices or errors may show for the next wallet (also when it uses the same relay).
  void _resetSyncStatus() {
    relayUrl = null;
    sync.reset();
    _relayFollowUp = false;
  }

  // ---------- key backup prompt (see app/CLAUDE.md, Sync) ----------
  // Device-local values (never synced): `keyBackupConfirmed` (date) and `keyBackupSnoozedUntil` (date). Logs say `key.backup`
  // with an action word only; never the key or any part of it, also not the characters typed to confirm.

  /// The owner confirmed (or, on a joined device, typed in) the key.
  bool get keyBackupConfirmed => repo.localValue('keyBackupConfirmed') != null;

  /// Show Today's "Save your wallet key" row: a key exists, it is not confirmed, and "Later" is not in force.
  bool get keyBackupRowVisible {
    if (!hasWallet || keyBackupConfirmed) return false;
    final until = repo.localValue('keyBackupSnoozedUntil');
    return until == null || today().compareTo(until) >= 0;
  }

  /// True once after [createWallet]: the app opens the save-key screen before the first Today.
  bool takeKeyBackupPrompt() {
    final p = _keyPromptPending && hasWallet && !keyBackupConfirmed;
    _keyPromptPending = false;
    return p;
  }

  /// Today is built once per [dataVersion]: the row appears or goes with a new version (no data was reloaded).
  void _keyBackupChanged() {
    dataVersion++;
    notifyListeners();
  }

  /// Logs that the save-key screen was shown.
  void keyBackupShown() => logEvent(_key, Level.INFO, 'key.backup', {'action': 'shown'});

  /// Whether the owner hid the first-run panel on Today for exactly these open [steps] (device-local); it is then one line.
  /// A different set of open steps (a new one appeared, or one was done) shows the panel open again.
  bool setupCollapsedFor(List<String> steps) => repo.localValue('setupCollapsed') == steps.join(',');

  void setSetupCollapsed(bool v, List<String> steps) {
    repo.setLocalValue('setupCollapsed', v ? steps.join(',') : null);
    _keyBackupChanged();
  }

  /// "Later": hides Today's row for 7 days.
  void snoozeKeyBackup() {
    repo.setLocalValue('keyBackupSnoozedUntil', addDays(today(), 7));
    logEvent(_key, Level.INFO, 'key.backup', {'action': 'snoozed'});
    _keyBackupChanged();
  }

  /// Copies the key; 60 seconds later the clipboard is emptied unless it is readable and holds something else.
  /// (Android 10+ shows a background app an empty clipboard, so "null" counts as "still ours".) If the app is in the
  /// background then, the clear waits for the next resume; disposing the controller clears at once.
  Future<void> copyKeyBackup() async {
    final t = await keyText();
    if (t.isEmpty) return;
    await copySensitive(t);
    logEvent(_key, Level.INFO, 'key.backup', {'action': 'copied'});
  }

  /// Puts [text] on the clipboard and empties it again after [keyClipboardLife] (the rules of [copyKeyBackup]); a later copy
  /// replaces the pending clear. Used for the wallet key and the pay-sheet fields.
  Future<void> copySensitive(String t) async {
    await deps.clipboardWrite(t);
    _clipboardTimer?.cancel();
    _resumeClear?.dispose();
    _resumeClear = null;
    _pendingClipboardKey = t;
    _clipboardTimer = Timer(keyClipboardLife, () {
      _clipboardTimer = null;
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null && state != AppLifecycleState.resumed) {
        _resumeClear?.dispose();
        _resumeClear = AppLifecycleListener(onResume: () {
          _resumeClear?.dispose();
          _resumeClear = null;
          _clearClipboardKey();
        });
        return;
      }
      _clearClipboardKey();
    });
  }

  AppLifecycleListener? _resumeClear;
  String? _pendingClipboardKey;

  /// Empties the clipboard unless it can be read and holds something other than the copied key.
  Future<void> _clearClipboardKey() async {
    final t = _pendingClipboardKey;
    if (t == null) return;
    _pendingClipboardKey = null;
    try {
      String? now;
      var readable = true;
      try {
        now = await deps.clipboardRead();
      } catch (e, st) {
        readable = false;
        logError(_key, 'key.backup.clipboard', e, st, fields: {'type': e.runtimeType.toString()});
      }
      if (readable && now != null && now != t) return;
      await deps.clipboardWrite('');
    } catch (e, st) {
      logError(_key, 'key.backup.clipboard', e, st, fields: {'type': e.runtimeType.toString()});
    }
  }

  /// Upper case, spaces and dashes dropped, a typed 0 read as the letter O (the key has no zero), like `VaultKey.parse`.
  static String _plainKey(String s) => s.toUpperCase().replaceAll(RegExp(r'[\s-]'), '').replaceAll('0', 'O');

  /// Do [typed] (spaces and dashes ignored, any case) equal the last 4 characters of the key? Only then it is confirmed.
  Future<bool> confirmKeyBackup(String typed) async {
    final k = _plainKey(await keyText());
    final n = _plainKey(typed);
    if (k.isEmpty || n.length != 4 || !k.endsWith(n)) return false;
    repo.setLocalValue('keyBackupConfirmed', today());
    repo.setLocalValue('keyBackupSnoozedUntil', null);
    logEvent(_key, Level.INFO, 'key.backup', {'action': 'confirmed'});
    _keyBackupChanged();
    return true;
  }

  /// Web: opens the key stored in this browser with [passphrase]. Throws [WrongPassphrase]; the typed text is never logged.
  Future<void> unlock(String passphrase) async {
    final k = await deps.unlocker(passphrase);
    if (_dbPending) {
      try {
        await _openFileDb(k, asideOnMismatch: false);
      } on WalletDbKeyException {
        // The stored key does not open the stored database: keep the file, go to onboarding (create sets it aside).
        logEvent(_log, Level.WARNING, 'wallet.unlock', {'keyMismatch': true});
        hasUnopenedDb = true;
        locked = false;
        notifyListeners();
        return;
      }
    }
    key = k;
    locked = false;
    logEvent(_log, Level.INFO, 'wallet.unlock');
    notifyListeners();
    await syncNow(trigger: 'unlock');
  }

  /// Web "Forget this browser": deletes the database and the stored key, then starts over with an empty wallet and no key
  /// (the app shows onboarding). Throws the first failure after the state was reset.
  Future<void> forgetBrowser() async {
    logEvent(_log, Level.INFO, 'wallet.forget');
    _syncTimer?.cancel();
    _dayTimer?.cancel();
    _debounce?.cancel();
    _persistTimer?.cancel();
    Object? failure;
    StackTrace? failureStack;
    try {
      final db = _db;
      if (db != null) {
        await db.forget();
      } else {
        repo.close();
      }
    } catch (e, st) {
      logError(_log, 'wallet.forget.dbFailed', e, st, level: Level.SEVERE);
      failure = e;
      failureStack = st;
    }
    try {
      await deps.keyForgetter();
    } catch (e, st) {
      logError(_log, 'wallet.forget.keyFailed', e, st, level: Level.SEVERE);
      if (failure == null) {
        failure = e;
        failureStack = st;
      }
    }
    key = null;
    locked = false;
    // No key, so no database: back to the in-memory placeholder until a wallet is created or joined (a new file system then).
    _db = null;
    repo = WalletRepo.inMemory();
    _dbPending = true;
    hasUnopenedDb = false;
    relayUrl = null;
    sync.reset();
    lastImport = const [];
    reload();
    _startAutoSync();
    if (failure != null) Error.throwWithStackTrace(failure, failureStack ?? StackTrace.current);
  }

  Future<String> keyText() async => key == null ? '' : await key!.toText();

  // ---------- sync ----------
  /// Reads a typed relay address: `http://` or `https://` plus a host (a bare `host:8787` gets `http://`). Null when it is not one.
  /// A trailing slash is dropped.
  static Uri? _parseRelay(String? raw) {
    var t = raw?.trim() ?? '';
    if (t.isEmpty) return null;
    if (!t.contains('://')) t = 'http://$t';
    final u = Uri.tryParse(t);
    if (u == null || (u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9._:\-]+$').hasMatch(u.host)) return null; // a space or other odd character is a typo
    if (u.hasQuery || u.hasFragment || u.userInfo.isNotEmpty) return null;
    final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
    return u.replace(path: path);
  }

  /// Why a typed relay address is refused, or null when it is usable: [RelayAddressIssue.notAnAddress], or
  /// [RelayAddressIssue.needsHttps] for plain `http://` to a host on the internet (anyone on the way could read or change
  /// the traffic, and the creation token travels in the clear). `http://` is accepted for this device (localhost, `127.x`, `::1`),
  /// the emulator's `10.0.2.2`, private IPv4 ranges (10/8, 172.16/12, 192.168/16), `.local` names and names without a dot
  /// (a home-network name such as `homeserver`).
  static RelayAddressIssue? relayAddressIssue(String? raw) {
    final u = _parseRelay(raw);
    if (u == null) return RelayAddressIssue.notAnAddress;
    if (u.scheme == 'http' && !_privateHost(u.host)) return RelayAddressIssue.needsHttps;
    return null;
  }

  static bool _privateHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '::1' || h.endsWith('.local') || h.endsWith('.localhost')) return true;
    // A name without a dot is a home-network name, unless it is a number (`134744072` and `0x08080808` are 8.8.8.8 to the resolver).
    if (!h.contains('.') && !h.contains(':')) return !RegExp(r'^(\d+|0x[0-9a-f]*)$').hasMatch(h);
    final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
    if (m == null) return false;
    // A leading zero is octal to some resolvers (`010.8.8.8` is 8.8.8.8 there): never taken as 10/8.
    if ([for (var i = 1; i <= 4; i++) m.group(i)!].any((x) => x.length > 1 && x.startsWith('0'))) return false;
    final o = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
    if (o.any((n) => n > 255)) return false;
    return o[0] == 127 || o[0] == 10 || (o[0] == 172 && o[1] >= 16 && o[1] <= 31) || (o[0] == 192 && o[1] == 168);
  }

  /// The address typed in [raw] as a relay [Uri], or null when it is not a usable one (for the Plan field and onboarding):
  /// see [relayAddressIssue].
  static Uri? parseRelayAddress(String raw) => relayAddressIssue(raw) == null ? _parseRelay(raw) : null;

  /// Sets (or, with null, clears) the relay address, device-local, then syncs. Throws [FormatException] for a bad address
  /// (the address is never logged: only `set` / `unset`).
  Future<void> setRelay(Uri? url) async {
    final u = url == null ? null : parseRelayAddress(url.toString());
    if (url != null && u == null) throw const FormatException('Not a relay address');
    repo.setLocalValue('relayUrl', u?.toString());
    relayUrl = u;
    // What the screen shows belongs to the old relay: clear it at once (a run in flight for the old relay is dropped below).
    sync.reset(keepLastSync: true);
    repo.setLocalValue(_noticeRelayChanged, null);
    repo.setLocalValue(_noticeIdInUse, null);
    _relayFollowUp = u != null && syncing; // a run is going: exactly one follow-up for the new address when it ends
    logEvent(_sync, Level.INFO, 'sync.relay', {'set': u != null}); // never the address
    notifyListeners();
    if (u != null) await syncNow(trigger: 'relay');
  }

  /// "Test connection": returns when a relay answers at [url] and speaks this build's API. Throws [TransportException]
  /// (`unreachable`, `newerApi`, …). Nothing about the address is logged.
  Future<void> testRelay(Uri url) async {
    try {
      await deps.healthCheck(url);
      logEvent(_sync, Level.INFO, 'sync.health', {'ok': true});
    } on TransportException catch (e) {
      logEvent(_sync, Level.INFO, 'sync.health', {'ok': false, 'failure': e.failure.name});
      rethrow;
    }
  }

  /// The relay changed while a sync was running: one more run follows when it ends (whatever skipped as busy meanwhile).
  bool _relayFollowUp = false;

  /// [trigger] says why it ran (button, timer, change, resume, startup, relay, join) for the log.
  Future<void> syncNow({bool quiet = false, String trigger = 'button'}) async {
    final relay = relayUrl, k = key;
    if (relay == null || k == null || syncing || _joining) {
      logEvent(_sync, Level.FINER, 'sync.skip',
          {'trigger': trigger, 'reason': relay == null ? 'noRelay' : (k == null ? 'noKey' : (_joining ? 'joining' : 'busy'))});
      return;
    }
    syncing = true;
    final run = _syncRun = Completer<void>();
    if (!quiet) notifyListeners();
    final dataBefore = _dataMark();
    try {
      final r = await timedAsync('sync.run', () => deps.syncRunner(relay, k, repo), fields: {'trigger': trigger}, warnMs: 3000);
      if (relay != relayUrl) {
        // The address changed during this run: its status belongs to the old relay. Keep the data it applied, show nothing of it.
        logEvent(_sync, Level.INFO, 'sync.stale', {'trigger': trigger, 'sent': r.sent, 'received': r.received});
        if (r.received > 0 || r.sent > 0) reload();
        return;
      }
      lastSync = DateTime.now();
      syncError = null;
      syncBadFiles = r.badFiles;
      syncCaughtUp = r.caughtUp;
      syncWaiting = r.waiting;
      syncBlobsWaiting = r.blobsWaiting;
      syncBlobsUnsupported = r.blobsUnsupported;
      syncDevices = r.devices;
      syncRelayInstance = r.relayInstance;
      syncRelayBytes = r.relayBytes;
      syncRelayMaxBytes = r.relayMaxBytes;
      syncProblems = r.problems;
      if (r.relayChanged) repo.setLocalValue(_noticeRelayChanged, '1');
      if (r.problems.any((p) => p.reason == SyncProblemReason.deviceIdInUse)) repo.setLocalValue(_noticeIdInUse, '1');
      logEvent(_sync, Level.INFO, 'sync.done', {
        'trigger': trigger,
        'relayChanged': r.relayChanged,
        'sent': r.sent,
        'received': r.received,
        'files': r.filesRead,
        'bad': r.badFiles,
        'caughtUp': r.caughtUp,
        'waiting': r.waiting.length,
        'devices': r.devices.length,
      });
      if (r.received > 0 || r.sent > 0) reload();
    } catch (e, st) {
      logError(_sync, 'sync.failed', e, st, fields: {'trigger': trigger});
      if (relay != relayUrl) return; // the old relay's failure: not shown for the new address
      syncError = e is SyncException ? e.message : "Couldn't sync. Check the relay address and your connection.";
      // A run that failed partway may already have applied some changes. Reload only if wallet data changed during the run:
      // a sync that keeps failing before applying anything must not reload the whole wallet every few minutes.
      if (_dataMark() != dataBefore) reload();
    } finally {
      syncing = false;
      run.complete();
      if (identical(_syncRun, run)) _syncRun = null;
      final followUp = _relayFollowUp && relayUrl != null;
      _relayFollowUp = false;
      notifyListeners();
      if (followUp) scheduleMicrotask(() => syncNow(quiet: true, trigger: 'relay'));
    }
  }

  /// Changes when wallet data changes: every data write (local or applied from a peer) records its field clock. Bookkeeping
  /// a failed run still makes (the next file number in `meta`, the outbox) doesn't count.
  (WalletRepo, int) _dataMark() => (repo, repo.dataVersion);

  void _startAutoSync() {
    _dayTimer?.cancel();
    _syncTimer?.cancel();
    _dayTimer = Timer.periodic(const Duration(minutes: 2), (_) => checkDay());
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) => syncNow(quiet: true, trigger: 'timer'));
    scheduleMicrotask(() => syncNow(quiet: true, trigger: 'startup'));
  }

  // ---------- backup, export, search (see app/CLAUDE.md, Polish) ----------
  /// True while the wallet holds nothing (no transactions, goals or wishes): the only time a backup can be restored.
  bool get walletIsEmpty => _cached(const MemoKey('walletIsEmpty'), () => repo.isEmpty);

  /// A backup of the wallet as bytes for the save dialog, with its file name (never log it). Throws [StateError] without a key.
  /// [blobs] = the bill files inside it (for the toast).
  Future<({String name, Uint8List bytes, int blobs})> backupDownload() async {
    final k = key;
    if (k == null) {
      logEvent(_backupLog, Level.INFO, 'backup.skip', {'reason': 'noKey'});
      throw StateError('No wallet key');
    }
    final sw = Stopwatch()..start();
    try {
      final made = await deps.backupBytesWriter(repo, k);
      logEvent(_backupLog, Level.INFO, 'backup.done', {
        'ms': sw.elapsedMilliseconds,
        'tx': wholeTxs.length,
        'goals': goals.length,
        'wish': wish.length,
        'bytes': made.bytes.length,
        'blobs': made.blobs,
        'blobsSkipped': made.blobsSkipped
      });
      return (name: backupFileName(today()), bytes: made.bytes, blobs: made.blobs);
    } catch (e, st) {
      logError(_backupLog, 'backup.failed', e, st);
      rethrow;
    }
  }

  /// Reads a picked backup file ([bytes]) into the empty wallet; returns the number of rows restored.
  /// With [otherKey] (the typed or scanned text of the key the backup was made with) the file is opened with that key instead of
  /// this wallet's; the restored rows then belong to this wallet. That key is used once: not stored, not logged, not kept.
  /// Throws [StateError] when the wallet is not empty, [VaultException] on a wrong key (`failure` is null when [otherKey] is not a
  /// key at all), [BackupException] on a bad file.
  Future<int> restoreBackupFile(Uint8List bytes, {String? otherKey}) async {
    final k = key;
    if (k == null) throw const BackupException(BackupFailure.unreadable, 'No wallet key on this device.');
    final sw = Stopwatch()..start();
    try {
      final opener = otherKey == null ? k : await VaultKey.parse(otherKey);
      final rows = await deps.backupBytesReader(repo, bytes, opener, k); // always the wallet's own key too
      logEvent(_backupLog, Level.INFO, 'backup.restored',
          {'ms': sw.elapsedMilliseconds, 'rows': rows, 'bytes': bytes.length, 'otherKey': otherKey != null});
      _changed();
      return rows;
    } catch (e, st) {
      logError(_backupLog, 'backup.restoreFailed', e, st, fields: {'type': e.runtimeType.toString(), 'otherKey': otherKey != null});
      rethrow;
    }
  }

  /// Merges a picked backup file ([bytes]) into this wallet: the newer change wins, field by field, nothing is doubled. With
  /// [dryRun] nothing is written and the result says what a merge would bring in. [otherKey] (typed or scanned text of the key the
  /// file was made with) opens the file instead of this wallet's key; it is used once and never stored or logged. Throws
  /// [VaultException] (wrong key; `failure` null when [otherKey] is not a key at all) and [BackupException] (bad file).
  Future<MergeResult> mergeBackupFile(Uint8List bytes, {String? otherKey, bool dryRun = false}) async {
    final k = key;
    if (k == null) throw const BackupException(BackupFailure.unreadable, 'No wallet key on this device.');
    final sw = Stopwatch()..start();
    try {
      final opener = otherKey == null ? k : await VaultKey.parse(otherKey);
      final r = await deps.backupMerger(repo, bytes, opener, dryRun: dryRun, walletKey: k);
      logEvent(_backupLog, Level.INFO, dryRun ? 'backup.mergePreview' : 'backup.merged', {
        'ms': sw.elapsedMilliseconds,
        'ops': r.ops,
        'changed': r.changed,
        'blobs': r.blobs,
        'entities': r.changedByEntity.length,
        'bytes': bytes.length,
        'otherKey': otherKey != null
      });
      if (!dryRun && (r.changed > 0 || r.blobs > 0)) _changed();
      return r;
    } catch (e, st) {
      logError(_backupLog, 'backup.mergeFailed', e, st,
          fields: {'type': e.runtimeType.toString(), 'dryRun': dryRun, 'otherKey': otherKey != null});
      rethrow;
    }
  }

  /// The transactions of [range] as a CSV (category and cleaned description as the app shows them). [ExportFile.rows] is 0
  /// when the range holds none.
  ExportFile exportTransactions(ExportRange range) {
    final to0 = today();
    final (String from, String to) = switch (range) {
      ExportRange.period => (period().start, addDays(period().end, -1)),
      ExportRange.year => ('${to0.substring(0, 4)}-01-01', to0),
      ExportRange.all => (txs.isEmpty ? to0 : txs.last.date, txs.isEmpty ? to0 : txs.first.date),
    };
    final rows = [
      for (final t in txs)
        if (t.date.compareTo(from) >= 0 && t.date.compareTo(to) <= 0) t
    ];
    logEvent(_log, Level.INFO, 'export.transactions', {'range': range.name, 'rows': rows.length});
    return ExportFile('bw-transactions-$from-$to.csv', _csvBytes(transactionsCsv(rows, table: categoryTable, tags: tagTable)), rows.length);
  }

  /// The spending summary per month and category over every transaction.
  ExportFile exportSummary() {
    final csv = monthlySummaryCsv(txs, currency: currency, table: categoryTable);
    final months = csv.split('\n').where((l) => l.isNotEmpty).length - 1; // data lines after the header
    logEvent(_log, Level.INFO, 'export.summary', {'rows': months});
    return ExportFile('bw-summary.csv', _csvBytes(csv), months);
  }

  /// UTF-8 with a byte order mark, so a spreadsheet reads accents correctly.
  static Uint8List _csvBytes(String csv) => Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);

  /// Everything that matches [query] (transactions, goals, wishlist, expected bills). Cached per data version. Logs counts only.
  SearchResult search(String query) => _cached(MemoKey('search', query), () {
        final r = searchAll(query,
            txs: txs,
            goals: goals,
            wishlist: wish,
            bills: expectedBills(),
            billsDb: billsAll(),
            planned: [
              for (final p in plannedEverything())
                if (!p.deleted && p.title.isNotEmpty) p
            ],
            table: categoryTable,
            tags: tagTable);
        logEvent(_searchLog, Level.FINE, 'search.run', {
          'chars': query.length,
          'tx': r.txs.length,
          'goals': r.goals.length,
          'wish': r.wishlist.length,
          'bills': r.bills.length,
          'planned': r.planned.length,
          'billsDb': r.billsDb.length
        });
        return r;
      });

  // ---------- look (device-local) ----------
  /// Theme mode: 'system' (default), 'light' or 'dark'. Device-local, never synced.
  String get themeModeName {
    final v = repo.localValue('themeMode');
    return v == 'light' || v == 'dark' ? v! : 'system';
  }

  void setThemeMode(String mode) {
    if (mode != 'system' && mode != 'light' && mode != 'dark') return;
    final from = themeModeName;
    if (mode == from) return;
    repo.setLocalValue('themeMode', mode);
    logEvent(_log, Level.INFO, 'theme.mode', {'from': from, 'to': mode});
    notifyListeners();
  }

  /// Number style: 'point' (1,234.50, default) or 'comma' (1.234,50). Device-local, never synced.
  String get numberStyleName => _numberStyle.name;

  /// Kept in memory: screens and every notify read it, so it never costs a database read per frame.
  NumberStyle _numberStyle = NumberStyle.point;

  void _applyNumberStyle() => numberStyle = _numberStyle = NumberStyle.fromName(repo.localValue('numberStyle'));

  void setNumberStyle(String style) {
    if (style != 'point' && style != 'comma') return;
    if (style == numberStyleName) return;
    repo.setLocalValue('numberStyle', style);
    _numberStyle = NumberStyle.fromName(style);
    logEvent(_log, Level.INFO, 'number.style', {'style': style});
    notifyListeners();
  }

  /// Whether the explainer paragraphs (the muted text under section heads) have been shown once. Device-local.
  bool explainerSeen(String key) => repo.localValue('explainer:$key') != null;

  /// Notes that the explainer [key] was shown; later it starts collapsed behind an info icon.
  void markExplainerSeen(String key) {
    if (explainerSeen(key)) return;
    repo.setLocalValue('explainer:$key', today());
  }

  // ---------- diagnostics ----------
  /// Device-local log level: 'all' (debug, the default while testing), 'info' or 'warning'.
  String get logLevel => repo.localValue('logLevel') ?? 'all';

  void setLogLevel(String level) {
    final from = logLevel;
    repo.setLocalValue('logLevel', level);
    AppLog.setLevel(level); // first, so the event below is logged at the new level
    logEvent(_log, Level.INFO, 'log.level', {'from': from, 'to': level});
    notifyListeners();
  }

  Future<LogStats> logStats() => AppLog.stats();

  String logFileName() => 'budget-wallet-logs-${today()}.txt';

  /// All logs as one text file's bytes.
  Future<Uint8List> logBytes() async => Uint8List.fromList(utf8.encode(await AppLog.combined()));

  Future<void> clearLogs() => AppLog.clear();

  @override
  void dispose() {
    logEvent(_log, Level.FINE, 'wc.dispose');
    _syncTimer?.cancel();
    _dayTimer?.cancel();
    _debounce?.cancel();
    _persistTimer?.cancel();
    _clipboardTimer?.cancel();
    _resumeClear?.dispose();
    _resumeClear = null;
    _clearClipboardKey();
    _shareSub?.cancel();
    _actionSub?.cancel();
    _shareResults.close();
    _shortcutAdds.close();
    repo.close();
    sync.dispose();
    cal.dispose();
    super.dispose();
  }

  // ---------- import ----------
  /// Logs per file on `bw.import`: index, extension, size and counts. Never the file name.
  /// A CSV no bank profile knows is read with its saved layout, else [askMapping] opens the Map columns sheet (null = the
  /// message "map its columns"); the chosen layout is saved, then the file is read with it.
  Future<List<ImportLine>> importFiles(List<(String, Uint8List)> files, {AskMapping? askMapping, ConfirmRemoval? confirmRemoval}) async {
    final all = PerfTimer('import.files', warnMs: 3000);
    final lines = <ImportLine>[];
    for (final (i, (name, bytes)) in files.indexed) {
      final f = <String, Object?>{'file': i, 'ext': fileExt(name), 'bytes': bytes.length};
      final t = PerfTimer('import.file', warnMs: 1500);
      final remap = _Remap();
      VoidCallback? undoOf() => remap.id == null ? null : () => undoCsvRemap(remap.id!, remap.removed, remap.old);
      try {
        final read = await _readImportFile(name, bytes, askMapping, confirmRemoval, remap);
        if (read == null) {
          logEvent(_import, Level.INFO, 'import.mapCancelled', f);
          lines.add(ImportLine(name, 'Not imported. Map its columns to read it.', false));
          continue;
        }
        final (batch, usedMapping) = read;
        final mapped = usedMapping != null;
        // Payments a forced layout edit removed come back exactly once when the same file is read the new way (`csvRevive:<shape id>`).
        final reviveKey = batch.source.startsWith(csvSourcePrefix) ? batch.source.substring(csvSourcePrefix.length) : null;
        final revive = reviveKey == null ? const <String>[] : csvReviveIds(reviveKey);
        final s = repo.importBatch(batch, revive: revive.toSet()); // logs repo.importBatch
        if (revive.isNotEmpty) {
          // Only the ids this file read are done; the rest wait for their own files (January's and February's rows both come back).
          final read = {for (final t in batch.transactions) t.id};
          final rest = [
            for (final id in revive)
              if (!read.contains(id)) id
          ];
          repo.setLocalValue('csvRevive:$reviveKey', rest.isEmpty ? null : jsonEncode(rest));
        }
        t.done({
          ...f,
          'source': sourceLogKey(batch.source),
          if (mapped) 'mapped': true,
          'rows': batch.transactions.length,
          'added': s.added,
          'dupes': s.duplicates,
          'matched': s.matched,
          'skipped': s.skipped,
          'invalid': batch.invalid
        });
        final bank = usedMapping?.name ?? accountSourceLabel(batch.source, csvMappings: settings.csvMappings);
        final replaced = remap.removed.length;
        lines.add(ImportLine(
            name,
            '$bank: ${s.added} new, ${s.duplicates} already here${s.matched > 0 ? ', ${s.matched} matched to expenses you added' : ''}'
            '${batch.invalid > 0 ? ', ${batch.invalid} unreadable ${batch.invalid == 1 ? 'row' : 'rows'} left out' : ''}'
            '${replaced > 0 ? ', $replaced earlier ${replaced == 1 ? 'payment' : 'payments'} read again' : ''}.',
            true,
            added: s.added,
            undo: undoOf()));
      } on ClockBehindException catch (e) {
        noticeClockBehind(e); // nothing of this file was written; say why instead of "couldn't read"
        lines.add(ImportLine(name, clockBehindText, false, undo: undoOf()));
      } on ImportException catch (e, st) {
        logError(_import, 'import.rejected', e, st, fields: f);
        lines.add(ImportLine(name, e.message, false, undo: undoOf()));
      } on ArgumentError catch (e, st) {
        logError(_import, 'import.layoutRefused', e, st, fields: f); // core's owner-readable text, no cell content
        lines.add(ImportLine(name, e.message.toString(), false, undo: undoOf()));
      } catch (e, st) {
        logError(_import, 'import.failed', e, st, fields: f, level: Level.SEVERE);
        lines.add(ImportLine(name, "Couldn't read this file.", false, undo: undoOf()));
      }
    }
    all.done({'files': files.length, 'ok': lines.where((l) => l.ok).length});
    lastImport = lines;
    refreshRecurring();
    _changed();
    return lines;
  }

  /// The batch of one file and the column mapping that read it (null for a bank profile): a bank profile, a saved layout that fits, or the
  /// layout [ask] returns (saved first; [confirm] answers the "used for N payments" case). Null = the owner cancelled. When saving
  /// the layout replaced the payments of a removed one that read differently, [remap] says which (and the old layout).
  Future<(ImportBatch, CsvMapping?)?> _readImportFile(
      String name, Uint8List bytes, AskMapping? ask, ConfirmRemoval? confirm, _Remap remap) async {
    final f = <String, Object?>{'ext': fileExt(name), 'bytes': bytes.length};
    try {
      return (timed('import.parse', () => importBankFile(bytes), fields: f, warnMs: 1000), null);
    } on NeedsMapping catch (need) {
      final saved = settings.csvMappings;
      final key = matchCsvMapping(bytes, need.shape, saved);
      CsvMapping m;
      if (key != null) {
        m = saved[key]!;
      } else {
        if (ask == null) rethrow;
        final choice = await ask(need, bytes);
        if (choice == null) return null;
        final before = repo.removedCsvMapping(choice.shapeId); // what the Undo writes back
        var removed = const <String>[];
        try {
          removed = repo.setCsvMapping(choice.shapeId, choice.mapping);
        } on ArgumentError {
          final n = repo.csvRowsFor(choice.shapeId);
          if (n == 0 || confirm == null) rethrow;
          if (!await confirm(n)) return null;
          removed = repo.setCsvMapping(choice.shapeId, choice.mapping, force: true);
        }
        settings = repo.settings(); // a second file of this shape in the same pick reads with it, no new question
        if (removed.isNotEmpty) {
          // Added to what is waiting already: another file's rows, or rows an Undo took away that this reading brings back.
          repo.setLocalValue('csvRevive:${choice.shapeId}', jsonEncode({...csvReviveIds(choice.shapeId), ...removed}.toList()));
          remap
            ..id = choice.shapeId
            ..removed = removed
            ..old = before;
        }
        logEvent(_import, Level.INFO, 'import.layoutSaved', {'columns': need.shape.headers.length, 'removed': removed.length});
        m = choice.mapping;
      }
      return (
        timed('import.parse', () => parseMappedCsv(bytes, m, fileName: name, walletCurrency: currency),
            fields: {...f, 'mapped': true}, warnMs: 1000),
        m
      );
    }
  }

  /// Undo of an import that replaced a layout's earlier payments: everything now live from that layout is deleted, the earlier payments
  /// are back, and the layout is the removed one again with the reading it had ([old]), so reading the file the new way later asks again.
  void undoCsvRemap(String id, List<String> removed, CsvMapping? old) {
    final earlier = removed.toSet();
    final taken = <String>[];
    for (final t in repo.transactions(includeHidden: true)) {
      if (t.source == '$csvSourcePrefix$id' && !t.deleted && !earlier.contains(t.id)) {
        repo.deleteTransaction(t.id);
        taken.add(t.id);
      }
    }
    if (old != null) repo.setCsvMapping(id, old, force: true); // deletes what is still live (the revived ones), they come back next
    for (final r in removed) {
      repo.undeleteTransaction(r);
    }
    repo.removeCsvMapping(id);
    // The rows the new reading made stay deleted; reading the file that way again must bring them back, not skip them as known.
    repo.setLocalValue('csvRevive:$id', taken.isEmpty ? null : jsonEncode(taken));
    logEvent(_import, Level.INFO, 'csvLayout.remapUndone', {'restored': removed.length});
    _changed();
  }

  // ---------- saved CSV layouts (P12) ----------
  /// Saved file layouts, shape id → layout, sorted by name.
  List<MapEntry<String, CsvMapping>> csvLayouts() =>
      settings.csvMappings.entries.toList()..sort((a, b) => a.value.name.toLowerCase().compareTo(b.value.name.toLowerCase()));

  /// Renames layout [id]. An [ArgumentError] carries core's owner-readable text.
  void renameCsvLayout(String id, String name) {
    final m = settings.csvMappings[id];
    if (m == null) throw ArgumentError('That layout is gone.');
    repo.setCsvMapping(id, m.copyWith(name: name));
    logEvent(_import, Level.INFO, 'csvLayout.rename');
    _changed();
  }

  /// Removes layout [id] and returns it (the toast's Undo is [restoreCsvLayout]); null when it is already gone.
  CsvMapping? deleteCsvLayout(String id) {
    final m = settings.csvMappings[id];
    if (m == null) return null;
    repo.removeCsvMapping(id);
    logEvent(_import, Level.INFO, 'csvLayout.delete');
    _changed();
    return m;
  }

  /// How many payments layout [id] has imported (not deleted).
  int csvRowsFor(String id) => repo.csvRowsFor(id);

  /// Saves a changed layout [m] for [id]. Changing how it reads (columns, formats, sign) when it has imported payments throws core's
  /// [ArgumentError] unless [force]; with [force] those payments are deleted and their ids returned (the toast's Undo is
  /// [undoCsvLayoutEdit]). The ids are kept device-local as `csvRevive:<id>` for the next import of that shape.
  List<String> saveCsvLayout(String id, CsvMapping m, {bool force = false}) {
    final removed = repo.setCsvMapping(id, m, force: force);
    if (removed.isNotEmpty) repo.setLocalValue('csvRevive:$id', jsonEncode(removed));
    logEvent(_import, Level.INFO, 'csvLayout.edit', {'removed': removed.length, 'force': force});
    _changed();
    return removed;
  }

  /// The payment ids a forced edit of layout [id] removed and the next import of its shape may bring back (see [saveCsvLayout]).
  List<String> csvReviveIds(String id) {
    final v = repo.localValue('csvRevive:$id');
    if (v == null) return const [];
    try {
      return [for (final x in jsonDecode(v) as List) x as String];
    } catch (_) {
      return const [];
    }
  }

  /// Undo of a forced [saveCsvLayout]: the old layout is back and its removed payments with it.
  void undoCsvLayoutEdit(String id, CsvMapping old, List<String> removed) {
    repo.setCsvMapping(id, old, force: true);
    for (final r in removed) {
      repo.undeleteTransaction(r);
    }
    repo.setLocalValue('csvRevive:$id', null);
    logEvent(_import, Level.INFO, 'csvLayout.editUndone', {'restored': removed.length});
    _changed();
  }

  void restoreCsvLayout(String id, CsvMapping m) {
    repo.setCsvMapping(id, m);
    logEvent(_import, Level.INFO, 'csvLayout.restore');
    _changed();
  }

  // ---------- edits ----------
  /// The category of the last expense added on this device (device-local `lastExpenseCategory`), or null.
  String? get lastExpenseCategory {
    return lastExpensePick;
  }

  /// Adds a hand-made expense and returns its id; [tags] are extra tags it starts with.
  String addExpense(
      {required int amount, required String category, required String note, required String date, List<String> tags = const []}) {
    // The device-local default first: if the save then fails nothing is written, and a failure here never follows a saved expense.
    repo.setLocalValue('lastExpenseCategory', category);
    final id = repo.addTransaction(date: date, amount: amount, category: category, note: note, currency: currency);
    _linkNewTags(id, tags);
    logEvent(_log, Level.INFO, 'expense.add', {'category': _logCategory(category), 'tags': tags.length}); // category only
    _changed();
    return id;
  }

  void setCategory(Tx t, String category, {required bool always}) {
    // Built-in category names only; never the merchant.
    logEvent(_log, Level.INFO, 'category.change',
        {'from': _logCategory(categorizer.categoryOf(t)), 'to': _logCategory(category), 'always': always, 'source': t.source});
    if (always && t.source != 'manual') {
      repo.setMerchantRule(merchantKey(t), category);
      if (t.category != null) repo.setCategory(t.id, null);
    } else {
      repo.setCategory(t.id, category);
    }
    _changed();
  }

  /// The hand-added expense that the bank row [bankId] replaced (hidden from lists), or null.
  Tx? entryMatchedTo(String bankId) {
    for (final t in repo.transactions(includeHidden: true)) {
      if (t.manual && t.matchedTo == bankId && !t.deleted) return t;
    }
    return null;
  }

  /// The ids last deleted in this session: the toast's Undo restores them.
  String? lastDeletedTx, lastDeletedGoal;

  /// The split removed last (payment and its parts): the toast's Undo puts it back (`restoreSplitOf`).
  (Tx, List<SplitPart>)? lastRemovedSplit;

  void deleteTransaction(Tx t) {
    lastDeletedTx = t.id;
    repo.deleteTransaction(t.id);
    logEvent(_log, Level.INFO, 'tx.delete', {'manual': t.manual});
    _changed();
  }

  /// Undo of [deleteTransaction] (the toast's Undo).
  void undeleteTransaction(String id) {
    repo.undeleteTransaction(id);
    logEvent(_log, Level.INFO, 'tx.undelete');
    _changed();
  }

  /// Undo of [deleteGoal].
  void undeleteGoal(String id) {
    repo.undeleteGoal(id);
    logEvent(_log, Level.INFO, 'goal.undelete');
    _changed();
  }

  void updateSettings(Map<String, Object?> changes) {
    repo.updateSettings(changes);
    logEvent(_log, Level.INFO, 'settings.changed', {'keys': changes.keys.join(',')}); // keys only, never values
    _changed();
  }

  void startNewMonth(String date) {
    repo.updateSettings({'periodStart': date, 'incomeMode': 'planned'});
    logEvent(_log, Level.INFO, 'month.start', {'date': date});
    _changed();
  }

  void paydayDone(String periodStart) {
    repo.payGoals(period: periodStart);
    repo.updateSettings({'savedFor': periodStart});
    logEvent(_log, Level.INFO, 'payday.done', {'periodStart': periodStart, 'goals': goals.length});
    _changed();
  }

  void saveGoal({String? id, required String name, required int target, required int saved, required int monthly, int? sort}) {
    repo.saveGoal(id: id, name: name, target: target, saved: saved, monthly: monthly, sort: sort);
    logEvent(_log, Level.INFO, 'goal.save', {'new': id == null}); // never the name or amounts
    _changed();
  }

  void deleteGoal(String id) {
    lastDeletedGoal = id;
    repo.deleteGoal(id);
    logEvent(_log, Level.INFO, 'goal.delete');
    _changed();
  }

  /// The id of the wish added last in this session (the "Open" action of its toast).
  String? lastAddedWish;

  /// Adds a wish (cooling off) and returns its id.
  String addWish(String name, int price) {
    final id = repo.addWish(name, price);
    lastAddedWish = id;
    logEvent(_log, Level.INFO, 'wish.add', {'status': 'waiting'}); // never the name or price
    _changed();
    return id;
  }

  /// Set by the home shell: switches to tab 0..4 (Today, Budget, Bills, Save, Settings; see `Tabs`). Null outside the shell
  /// (tests of a single screen), where [openTab] does nothing.
  void Function(int tab, String via)? tabHook;

  /// The Settings place a link wants shown (a section, or Currencies inside Accounts); the Settings tab selects or scrolls to it.
  final JumpRequest<SettingsSection> settingsRequest = JumpRequest<SettingsSection>();

  /// The wish the Wishlist tab shows highlighted after a toast's "Open" (cleared by the screen once it scrolled there).
  final ValueNotifier<String?> highlightWish = ValueNotifier<String?>(null);

  /// Opens a tab from anywhere (a toast action, a row).
  void openTab(int tab, {String via = 'toast'}) => tabHook?.call(tab, via);

  /// Opens a place in Settings (the tab, then the section).
  void openSettings(SettingsSection section, {String via = 'link'}) {
    openTab(Tabs.settings, via: via);
    settingsRequest.request(section);
  }

  /// Opens the Save tab on the wish [wishId].
  void openWish(String wishId, {String via = 'toast'}) {
    highlightWish.value = wishId;
    openTab(Tabs.save, via: via);
  }

  void decideWish(String id, String status) {
    repo.decideWish(id, status);
    logEvent(_log, Level.INFO, 'wish.decide', {'status': status});
    _changed();
  }
}

/// Joining the wallet that is already open.
class WalletAlreadyOpen implements Exception {
  const WalletAlreadyOpen();
  @override
  String toString() => 'This wallet is already open.';
}

/// The open wallet's own key was never saved: setting it aside would leave no way to reopen it.
class KeyNotSaved implements Exception {
  const KeyNotSaved();
  @override
  String toString() => "Save this wallet's key first.";
}
