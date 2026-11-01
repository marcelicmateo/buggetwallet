import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:wallet_core/wallet_core.dart';
// `periodDays()` below has the core function's name, so the function is reached through a prefix.
import 'package:wallet_core/wallet_core.dart' as core show periodDays;
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'bill_inputs.dart';
import 'calendar_source.dart';
import 'clock_notice.dart';
import 'conflict_text.dart';
import 'controller_deps.dart';
import 'device_list.dart';
import 'device_relay.dart';
import 'format.dart' show NumberStyle, money, moneyExact, numberStyle, shortDateOrRaw, walletCurrencyCode;
import 'hero.dart';
import 'home_widget.dart';
import 'ics_fetch.dart';
import 'insights_api.dart' show InsightRange, WalletInsights, insightGraphs;
import 'key_store.dart';
import 'logging.dart';
import 'memo_key.dart';
import 'nudges.dart';
import 'platform.dart' show isWeb;
import 'sub_state.dart';
import 'sync_status.dart' show relayOlderThanBeforeText;
import 'tabs.dart';
import 'wallet_db.dart';
import 'warm_up.dart';

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
part 'controller_sync.dart';
part 'controller_devices.dart';
part 'controller_import.dart';
part 'controller_settings.dart';
part 'controller_review.dart';
part 'controller_tx.dart';
part 'controller_forecast.dart';
part 'controller_iou.dart';
part 'controller_suggest.dart';
part 'controller_setup.dart';
part 'controller_warmup.dart';

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

  /// Bank balance questions this import leaves (Q5): accounts the file gave no balance for. The import flow asks them in order.
  final List<BankQuestion> questions;

  /// Why rows of the file were left out (core's `ImportBatch.problems`: "Row 3: the amount … has more than 2 decimals") and how many
  /// were left out in all. Shown under the result line; never logged (they hold amounts as written).
  final List<String> problems;
  final int invalid;
  const ImportLine(this.file, this.message, this.ok,
      {this.added = 0, this.undo, this.questions = const [], this.problems = const [], this.invalid = 0});
}

/// "What did the bank app show when you downloaded this file?" (Q5): account [accountId] ([name], [currency]), the file's newest row
/// date [date] and what the app itself counts for that day ([appCents], the prefill of the answer).
class BankQuestion {
  final String accountId, name, currency, date;
  final int appCents;
  const BankQuestion({required this.accountId, required this.name, required this.currency, required this.date, required this.appCents});
}

/// What a saved layout replaced while one file was imported (P12): filled by [WalletController._readImportFile] the moment a forced save
/// deleted payments, so every outcome of the file (success, clock behind, unreadable) can still offer the Undo.
class _Remap {
  String? id;
  List<String> removed = const [];

  /// The waiting `csvRevive:<id>` value before the forced save (null = none): Cancel puts exactly that back.
  String? reviveBefore;

  /// The layout as it was before (the removed one), written back by the Undo; null when core kept none.
  CsvMapping? old;
}

/// One question per account: of several (several files of one pick) the one with the newest date.
List<BankQuestion> newestPerAccount(Iterable<BankQuestion> questions) {
  final by = <String, BankQuestion>{};
  for (final q in questions) {
    final have = by[q.accountId];
    if (have == null || q.date.compareTo(have.date) > 0) by[q.accountId] = q;
  }
  return by.values.toList();
}

/// One file read: its [batch], the column [mapping] that read it (null for a bank profile) and, for a layout the owner just chose,
/// [commit] (saves it once the preview is confirmed) and [revert] (takes a layout saved early back on Cancel).
class _ReadFile {
  final ImportBatch batch;
  final CsvMapping? mapping;

  /// [commit] runs before the rows are written and throws core's [ArgumentError] for a refused layout (shown as the layout line);
  /// [revert] takes a layout saved early back on Cancel.
  final void Function()? commit, revert;
  const _ReadFile(this.batch, this.mapping, {this.commit, this.revert});
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

/// Asked before a file is written (Q4): the owner sees [preview] of [bank]'s file. The ids to leave out (the Skip toggles), or null =
/// Cancel, nothing is written. [canSkip] is false when per-row Skip cannot be offered honestly.
typedef ConfirmPreview = Future<Set<String>?> Function(ImportPreview preview, String bank);

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

  /// What went out in each of [months] (same order, cents), the "Out in October" sparkline.
  final List<int> outByMonth;

  /// Core's `averageOut`: the 6 months before [month] as one monthly average (cents), and `changePermille` of this month's
  /// out against it (1000 = +100 %); null when the average is 0 (nothing to compare with).
  final int averageOut;
  final int? outChange;
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
    required this.outByMonth,
    required this.averageOut,
    required this.outChange,
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

  /// The [dataVersion] [pendingAutoPaid] last looked at, and what it found.
  int _autoPaidSeen = -1;
  List<AutoPaid> _autoPaidPending = const [];

  /// The idle warm-up of the derived values the tabs need (see `controller_warmup.dart`).
  final WarmUp warmUp = WarmUp();
  final Map<MemoKey, Object?> _memo = {};

  bool _disposed = false;

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

  /// The device-local value holding the lowest relay api accepted at [relay] (no downgrade, DK): keyed by the normalised address,
  /// cleared only when the owner saves an address in Settings › Sync ([setRelay]), never because a check or an error names a lower api.
  static String minApiKey(Uri relay) {
    final path = relay.path.endsWith('/') ? relay.path.substring(0, relay.path.length - 1) : relay.path;
    return 'relayMinApi:${relay.scheme}://${relay.host.toLowerCase()}:${relay.port}$path';
  }

  /// The api floor kept for [relay] (null: none yet).
  static int? minApiFor(WalletRepo repo, Uri relay) => int.tryParse(repo.localValue(minApiKey(relay)) ?? '');

  /// A [RelayTransport] to [relay] for this wallet. Once the relay said api 5 it is never trusted below 5 again: the transport tells
  /// us ([RelayTransport.onMinApi]) and the value is kept device-local (never synced, no address in it) until the address changes.
  static RelayTransport relayTransport(Uri relay, VaultKey key, WalletRepo repo, {List<int>? deviceKey, String? deviceId}) {
    final t = RelayTransport(relay, key,
        createToken: createTokenFor(relay, repo.localValue(relayCreateTokenKey)),
        deviceKey: deviceKey,
        deviceId: deviceId, onMinApi: (min, instance) {
      try {
        repo.setLocalValue(minApiKey(relay), '$min');
      } catch (e, st) {
        logError(_sync, 'sync.minApiFailed', e, st);
      }
    });
    final stored = minApiFor(repo, relay);
    if (stored != null && stored > t.minApi) t.minApi = stored;
    return t;
  }

  /// The real sync run ([WalletControllerDeps.syncRunner]).
  /// [deviceKey] (this install's seed) and [deviceId] make it an api-5 device (DK); null signs with the wallet key as before.
  static Future<SyncReport> runRelaySync(Uri relay, VaultKey key, WalletRepo repo, {List<int>? deviceKey, String? deviceId}) async {
    final transport = relayTransport(relay, key, repo, deviceKey: deviceKey, deviceId: deviceId);
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

  /// Open equal-clock conflicts (V, VC): fields two devices hold with the same clock and different values, waiting for the owner's
  /// choice. Read from the repo (device-local, set by a repair resend), so it is right at start, after a sync and after a choice.
  int get syncConflictCount => repo.syncConflicts().length;

  /// The open conflicts for the "Choose the right values" page, in the owner's words (never logged).
  List<ConflictLine> conflictLines() => [
        for (final c in repo.syncConflicts())
          conflictLineOf(this, id: c.id, entity: c.entity, rowId: c.rowId, field: c.field, mine: c.mine, theirs: c.theirs)
      ];

  /// The owner's choice for one conflict: writes the chosen value (it syncs). False when the conflict was already settled (an edit or
  /// another choice removed it): nothing is written. Logs the choice only.
  bool resolveConflict(String id, {required bool keepMine}) {
    try {
      repo.resolveSyncConflict(id, keepMine: keepMine);
    } on ArgumentError {
      logEvent(_sync, Level.INFO, 'sync.conflict.gone', {});
      _changed();
      return false;
    }
    logEvent(_sync, Level.INFO, 'sync.conflict.resolve',
        {'keepMine': keepMine, 'left': repo.syncConflicts().length}); // never the field or a value
    _changed();
    return true;
  }

  /// A file sealed with another wallet key is on the relay; it was ignored.
  bool get syncOtherKey => syncProblems.any((p) => p.reason == SyncProblemReason.otherKey);

  /// After a sync this device's data still differs from a peer's (core repaired what it could).
  bool get syncDevicesDisagree => syncProblems.any((p) => p.reason == SyncProblemReason.devicesDisagree);

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

  /// While the import preview of a file is open: why rows of that file are left out (core's `ImportBatch.problems`) and how many.
  List<String> previewProblems = const [];
  int previewInvalid = 0;

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
      return WalletController._(placeholderRepo(), null, deps: d, inUseElsewhere: true);
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
        return WalletController._(placeholderRepo(), null, deps: d, inUseElsewhere: true);
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
    final c = WalletController._(db?.repo ?? placeholderRepo(), key, deps: d, db: db, locked: locked);
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
    if (_disposed) return; // a sync run that was still awaiting the device key or relay when the screen went away
    numberStyle = _numberStyle; // before the screens rebuild; read from the repo only on load, reload and change
    walletCurrencyCode = settings.currency;
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

  /// The period start: saved value, or the latest payday (its first salary payment), or with no salary the latest
  /// expected payday on or before today (owner 2026-10-31).
  WalletSettings get effectiveSettings => _cached(const MemoKey('effective'), () {
        if (settings.periodStart != null) return settings;
        final m = settings.toMap()..['periodStart'] = _paydays.lastOrNull ?? latestExpectedPayday();
        return WalletSettings.fromMap(m, table: categoryTable);
      });

  /// The latest expected payday (`paydayDay`, clamped to short months) on or before today: core's `currentPeriodStart` walks the
  /// expected paydays on from a start 62 days back (no period is longer), so this is core's own rule, not date maths here.
  String latestExpectedPayday() => currentPeriodStart(addDays(today(), -62), settings.paydayDay, today());

  /// A payday more than 20 days after the current period start, not yet started as a new month.
  String? newPayday(String periodStart) => _paydays.where((d) => d.compareTo(addDays(periodStart, 20)) > 0).lastOrNull;

  /// KL-A: slip payee key -> the recurring bill payee key it stands for (`repo.payeeAliases()`), kept per data version. Every core call that
  /// takes `payeeAliases:` gets it, so a slip spelled differently is covered, listed and counted like the bill it belongs to.
  Map<String, String> payeeAliases() => _cached(const MemoKey('payeeAliases'), repo.payeeAliases);

  /// The budget of the running pay period. Confirmed recurring bills are reserved in it (`reservedBills`, `dueBills`).
  PeriodBudget period() => _cached(
      const MemoKey('period'),
      () => timed(
          'wc.period',
          () => computePeriod(txs, effectiveSettings, goals, today(),
              bills: recurringBills(), planned: plannedOpen(), table: categoryTable, matchRows: rawExpanded, payeeAliases: payeeAliases()),
          warnMs: 50));

  /// One entry per day of the running pay period: within the day's money, over, today or to come (Today's day dots).
  List<PeriodDay> periodDays() => _cached(
      const MemoKey('periodDays'),
      () => timed(
          'wc.periodDays',
          () => core.periodDays(txs, effectiveSettings, goals, today(),
              bills: recurringBills(), planned: plannedOpen(), table: categoryTable, matchRows: rawExpanded, payeeAliases: payeeAliases()),
          warnMs: 100));

  /// Saved or lost per pay period (salary to salary), oldest first; the last one is still running.
  List<PeriodSummary> payPeriods({int count = 12}) => _cached(MemoKey('payPeriods', count),
      () => timed('wc.payPeriods', () => periodSummaries(txs, settings, today(), count: count), fields: {'count': count}, warnMs: 50));

  /// The month's totals ([month] `YYYY-MM`). Cached per month until the data changes (the idle warm-up fills one month at a time).
  MonthSummary monthSummaryFor(String month) => _cached(MemoKey('monthSummary', month),
      () => timed('wc.monthSummary', () => monthSummary(txs, month, currency: currency), fields: {'month': month}));

  /// The 6-month average per category before [month], the same one the suggested budgets use. Cached per month.
  Map<String, int> averageSpending(String month) =>
      _cached(MemoKey('averageSpending', month), () => averageByCategory(txs, month, currency: currency, table: categoryTable));

  /// What the Spending tab shows for month [sel] (`YYYY-MM`, default: this month). Cached per month until the data changes.
  SpendingView spending([String? sel]) {
    final current = monthOf(today());
    final months = monthsEnding(current, 13);
    final month = sel != null && months.contains(sel) ? sel : current;
    return _cached(
        MemoKey('spending', month),
        () => timed('spending.derive', () {
              final sums = [for (final m in months) monthSummaryFor(m)]; // memo per month (PF warm-up splits them)
              final selSum = monthSummaryFor(month);
              final avg = averageSpending(month); // the same 6-month average the suggested budgets use
              final avgOut = averageOut(txs, month, currency: currency);
              final periods = payPeriods(count: 12);

              final merch = <String, (int, int)>{};
              // The list shows each payment once (its parts hang under it, `splitParts`); the places add up the parts. A payment linked to
              // an IOU is neither spending nor income but is still a payment: it is listed, with its "lent" / "repaid" tag.
              final monthTxs = [
                for (final t in wholeTxs)
                  if (monthOf(t.date) == month && (t.kind != BudgetKind.transfer || t.iou)) t
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
                outByMonth: [for (final m in sums) m.out],
                averageOut: avgOut,
                outChange: changePermille(selSum.out, avgOut),
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

  /// Budgets for [month] by [kind] ("Start from…" on Budget › Budgets), per category in cents. Cached per kind and month until the
  /// data changes. Nothing is written: the owner saves them like typed ones.
  BudgetPreset budgetPresetFor(BudgetPresetKind kind, String month) => _cached(
      MemoKey('budgetPreset', (kind, month)),
      () => timed('wc.budgetPreset', () => budgetPreset(kind, txs, settings, month, currency: currency, table: categoryTable, goals: goals),
          fields: {'month': month, 'kind': kind.name}, warnMs: 50));

  /// The menu item of a preset.
  String budgetPresetLabel(BudgetPresetKind kind) => switch (kind) {
        BudgetPresetKind.avg3 => 'Average of the last 3 months',
        BudgetPresetKind.avg6 => 'Average of the last 6 months',
        BudgetPresetKind.avg12 => 'Average of the last 12 months',
        BudgetPresetKind.spendLess => 'Spend 10% less',
        BudgetPresetKind.fitPlan => 'Fit my plan',
        BudgetPresetKind.fiftyThirtyTwenty => '50/30/20',
      };

  /// The header of a preset: (title, one line saying where the numbers come from and what they add up to a month, [total] = the
  /// preset's own total in cents).
  (String, String) budgetPresetNote(BudgetPresetKind kind, int total) {
    String euros(int cents) => money(cents ~/ 100 * 100, currency, decimals: 0);
    final all = '${moneyExact(total, currency)} a month in all.';
    final title = switch (kind) {
      BudgetPresetKind.avg3 => 'Average of 3 months',
      BudgetPresetKind.avg6 => 'Average of 6 months',
      BudgetPresetKind.avg12 => 'Average of 12 months',
      BudgetPresetKind.spendLess => 'Spend 10% less',
      BudgetPresetKind.fitPlan => 'Fit my plan',
      BudgetPresetKind.fiftyThirtyTwenty => '50/30/20',
    };
    final line = switch (kind) {
      BudgetPresetKind.avg3 => 'What you spent a month in the last 3 months, per category.',
      BudgetPresetKind.avg6 => 'What you spent a month in the last 6 months, per category.',
      BudgetPresetKind.avg12 => 'What you spent a month in the last 12 months, per category.',
      BudgetPresetKind.spendLess => '10 % under your average of the last 6 months, per category.',
      BudgetPresetKind.fitPlan =>
        '${euros(monthlyFlex(settings, goals: goals, table: categoryTable))} a month of flexible money, split by what you spent in the last 6 months.',
      BudgetPresetKind.fiftyThirtyTwenty =>
        '30 % of your salary for wants: ${euros(settings.salary * 30 ~/ 100)}. Needs are your payday plan; 20 % is for savings.',
    };
    return (title, '$line $all');
  }

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
    markSetupWizardPending(); // then it opens the "Set up my wallet" wizard (never for a joined wallet)
    logEvent(_log, Level.INFO, 'wallet.create', {'defaultGoals': repo.goals().isEmpty});
    if (repo.goals().isEmpty) {
      repo.saveGoal(name: 'Emergency fund', target: 300000, saved: 0, monthly: 10000, sort: 1);
      repo.saveGoal(name: 'Yearly costs', target: 120000, saved: 0, monthly: 10000, sort: 2);
    }
    _changed();
  }

  /// True while [joinAnotherWallet] is closing and moving the database: [syncNow] does nothing then (a resume or a relay follow-up
  /// must not start a run on a repo that is about to close).
  bool _joining = false;

  /// True once after [createWallet]: the app opens the save-key screen before the first Today.
  bool takeKeyBackupPrompt() {
    final p = _keyPromptPending && hasWallet && !keyBackupConfirmed;
    _keyPromptPending = false;
    return p;
  }

  /// "Later": hides Today's row for 7 days.
  void snoozeKeyBackup() {
    repo.setLocalValue('keyBackupSnoozedUntil', addDays(today(), 7));
    logEvent(_key, Level.INFO, 'key.backup', {'action': 'snoozed'});
    _keyBackupChanged();
  }

  AppLifecycleListener? _resumeClear;
  String? _pendingClipboardKey;

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
    // A removed device does not try again by itself (no retry loop): only a new relay address, a key or an unlock starts a run.
    if (sync.deviceStop == DeviceStop.revoked && !const {'relay', 'join', 'unlock'}.contains(trigger)) {
      logEvent(_sync, Level.FINER, 'sync.skip', {'trigger': trigger, 'reason': 'revoked'});
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
      _deviceRunOk(r);
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
      final stop = deviceStopOf(e);
      if (stop != null) await _noteDeviceStop(stop);
      if (relay != relayUrl) return;
      // A removed or waiting key has its own notice (with the code); the plain error line would only repeat it.
      // An older relay than this address answered before (api floor 5): a likely downgrade, not a plain "update the relay".
      final downgraded =
          e is SyncException && e.failure == TransportFailure.olderApi && (WalletController.minApiFor(repo, relay) ?? 0) >= 5;
      syncError = stop != null
          ? null
          : downgraded
              ? relayOlderThanBeforeText
              : (e is SyncException ? e.message : "Couldn't sync. Check the relay address and your connection.");
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
            tags: tagTable,
            rules: rulesList);
        logEvent(_searchLog, Level.FINE, 'search.run', {
          'chars': query.length,
          'tx': r.txs.length,
          'goals': r.goals.length,
          'wish': r.wishlist.length,
          'bills': r.bills.length,
          'planned': r.planned.length,
          'billsDb': r.billsDb.length,
          'rules': r.rules.length
        });
        return r;
      });

  /// Kept in memory: screens and every notify read it, so it never costs a database read per frame.
  NumberStyle _numberStyle = NumberStyle.point;

  @override
  void dispose() {
    _disposed = true;
    warmUp.cancel();
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

  /// Logs per file on `bw.import`: index, extension, size and counts. Never the file name.
  /// A CSV no bank profile knows is read with its saved layout, else [askMapping] opens the Map columns sheet (null = the
  /// message "map its columns"); the chosen layout is saved, then the file is read with it.
  Future<List<ImportLine>> importFiles(List<(String, Uint8List)> files,
      {AskMapping? askMapping, ConfirmRemoval? confirmRemoval, ConfirmPreview? confirmPreview}) async {
    final all = PerfTimer('import.files', warnMs: 3000);
    final lines = <ImportLine>[];
    for (final (i, (name, bytes)) in files.indexed) {
      final f = <String, Object?>{'file': i, 'ext': fileExt(name), 'bytes': bytes.length};
      final t = PerfTimer('import.file', warnMs: 1500);
      final remap = _Remap();
      VoidCallback? undoOf() => remap.id == null ? null : () => undoCsvRemap(remap.id!, remap.removed, remap.old);
      try {
        final read = await _readImportFile(name, bytes, askMapping, confirmRemoval, remap, deferLayout: confirmPreview != null);
        if (read == null) {
          logEvent(_import, Level.INFO, 'import.mapCancelled', f);
          lines.add(ImportLine(name, 'Not imported. Map its columns to read it.', false));
          continue;
        }
        final batch = read.batch, usedMapping = read.mapping;
        final mapped = usedMapping != null;
        // Payments a forced layout edit removed come back exactly once when the same file is read the new way (`csvRevive:<shape id>`).
        final reviveKey = batch.source.startsWith(csvSourcePrefix) ? batch.source.substring(csvSourcePrefix.length) : null;
        final revive = reviveKey == null ? const <String>[] : csvReviveIds(reviveKey);
        var skip = const <String>{};
        if (confirmPreview != null) {
          // Q4: the preview equals the import (same batch, same revive set, after the layout is decided); Cancel writes nothing.
          final preview = repo.previewImport(batch, revive: revive.toSet());
          final bank = usedMapping?.name ?? accountSourceLabel(batch.source, csvMappings: settings.csvMappings);
          previewProblems = batch.problems;
          previewInvalid = batch.invalid;
          final Set<String>? chosen;
          try {
            chosen = await confirmPreview(preview, bank);
          } finally {
            previewProblems = const [];
            previewInvalid = 0;
          }
          if (chosen == null) {
            read.revert?.call();
            logEvent(_import, Level.INFO, 'import.previewCancelled', {...f, 'rows': batch.transactions.length, 'fresh': preview.fresh});
            lines.add(ImportLine(name, 'Not imported. You chose Cancel.', false));
            continue;
          }
          skip = chosen;
        }
        read.commit?.call(); // a new column layout is saved only now
        final s = repo.importBatch(batch, revive: revive.toSet(), skip: skip); // logs repo.importBatch
        if (revive.isNotEmpty) {
          // Only the ids this file read are done; the rest wait for their own files (January's and February's rows both come back).
          // A row the owner skipped is not done: its id stays waiting, so the file brings it back later as "Read again".
          final done = {
            for (final t in batch.transactions)
              if (!skip.contains(t.id)) t.id
          };
          final rest = [
            for (final id in revive)
              if (!done.contains(id)) id
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
          'invalid': batch.invalid,
          if (skip.isNotEmpty) 'skippedByOwner': s.skippedByOwner,
          if (s.bankChecks.isNotEmpty) 'checks': s.bankChecks.length,
        });
        final bank = usedMapping?.name ?? accountSourceLabel(batch.source, csvMappings: settings.csvMappings);
        final replaced = remap.removed.length;
        lines.add(ImportLine(
            name,
            '$bank: ${s.added} new, ${s.duplicates} already here${s.matched > 0 ? ', ${s.matched} matched to expenses you added' : ''}'
            '${batch.invalid > 0 ? ', ${batch.invalid} unreadable ${batch.invalid == 1 ? 'row' : 'rows'} left out' : ''}'
            '${replaced > 0 ? ', $replaced earlier ${replaced == 1 ? 'payment' : 'payments'} read again' : ''}.'
            '${s.skippedByOwner > 0 ? ' ${s.skippedByOwner} left out by you.' : ''}${_bankCheckText(s.bankChecks)}',
            true,
            added: s.added,
            problems: batch.problems,
            invalid: batch.invalid,
            undo: undoOf(),
            questions: _bankQuestions(batch, s.bankChecks)));
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

  /// The ids last deleted in this session: the toast's Undo restores them.
  String? lastDeletedTx, lastDeletedGoal;

  /// The (hand-added expense, bank row) pair unlinked last (D2): the toast's Undo links it again (`relinkCashMatch`).
  (String, String)? lastUnlinked;

  /// The alias a slip's payee key had before "Belongs to bill…" replaced it (null: none), for the Undo ([unlinkSlip]).
  final Map<String, String?> _aliasBeforeLink = {};

  /// After [unlinkCashMatch]: core matched the entry to another bank row at once (the toast says so).
  bool lastUnlinkedRematched = false;

  /// The payee rule offered after the last hand-set main tag (Q6): the toast after the sheet reads it once (`takeRuleOffer`).
  RuleOffer? ruleOffer;

  /// The split removed last (payment and its parts): the toast's Undo puts it back (`restoreSplitOf`).
  (Tx, List<SplitPart>)? lastRemovedSplit;

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
