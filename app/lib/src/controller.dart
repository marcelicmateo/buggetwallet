import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'key_store.dart';
import 'logging.dart';

final _log = Logger('bw.app');
final _sync = Logger('bw.sync');
final _import = Logger('bw.import');
final _key = Logger('bw.key');

/// The core function; the controller method of the same name would hide it inside the class.
const _computeBudget = budgetVsActual;

class ImportLine {
  final String file;
  final String message;
  final bool ok;
  const ImportLine(this.file, this.message, this.ok);
}

/// Everything the Spending tab shows for one month, worked out in [WalletController.spending].
class SpendingView {
  final String month;

  /// The last 13 months, oldest first; the last one is this month.
  final List<String> months;
  final MonthSummary summary;

  /// Average per category over the (up to 6) months before [month].
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
    required this.average,
    required this.periods,
    required this.trend,
    required this.overview,
    required this.topPlaces,
    required this.transactions,
  });
}

/// App state. Reads everything from the local database and writes through [WalletRepo].
class WalletController extends ChangeNotifier {
  final WalletRepo repo;
  VaultKey? key;

  WalletSettings settings = const WalletSettings();
  late Categorizer categorizer;
  List<CategorizedTx> txs = const [];
  List<Goal> goals = const [];
  List<WishItem> wish = const [];

  /// Counts [reload]s: the derived values below are cached per version (and per day) and recomputed only after the data changed.
  int dataVersion = 0;
  final Map<String, Object?> _memo = {};

  /// The day [_memo] was filled for: a new day drops every cached value (old days would only pile up).
  String? _memoDay;

  /// The day the screens last showed (set by [reload] and [checkDay]); a different [today] means the pages are out of date.
  String? _seenDay;
  final DateTime Function() _clock;

  /// Runs the sync of one folder; tests replace it.
  @visibleForTesting
  Future<SyncReport> Function(String folder, VaultKey key, WalletRepo repo) syncRunner = _runFolderSync;
  static Future<SyncReport> _runFolderSync(String folder, VaultKey key, WalletRepo repo) =>
      FolderSync(folder, key, appVersion: appVersion).run(repo);

  String? syncFolder;
  DateTime? lastSync;
  String? syncError;

  /// Files from other devices the last sync could not read (damaged or half-synced); retried on every sync.
  int syncBadFiles = 0;
  bool syncing = false;
  List<ImportLine> lastImport = const [];

  Timer? _syncTimer;
  Timer? _debounce;

  WalletController._(this.repo, this.key, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    syncFolder = repo.localValue('syncFolder');
  }

  /// Opens the database, reads the key and loads everything. Logs each startup phase as `app.start`.
  static Future<WalletController> load() async {
    var sw = Stopwatch()..start();
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final repo = WalletRepo.open('${dir.path}${Platform.pathSeparator}wallet.db');
    logEvent(_log, Level.INFO, 'app.start', {'phase': 'db', 'ms': sw.elapsedMilliseconds});

    sw = Stopwatch()..start();
    VaultKey? key;
    try {
      key = await KeyStore.read();
    } catch (e, st) {
      // The app then shows onboarding; the error says why the stored key could not be read.
      logError(_key, 'key.readFailed', e, st, level: Level.SEVERE);
      key = null;
    }
    logEvent(_log, Level.INFO, 'app.start', {'phase': 'key', 'ms': sw.elapsedMilliseconds, 'found': key != null});

    sw = Stopwatch()..start();
    final c = WalletController._(repo, key);
    c.reload();
    logEvent(_log, Level.INFO, 'app.start',
        {'phase': 'reload', 'ms': sw.elapsedMilliseconds, 'tx': c.txs.length, 'syncFolder': c.syncFolder != null, 'logLevel': c.logLevel});
    c._startAutoSync();
    return c;
  }

  /// For widget tests: an already-open repo (e.g. [WalletRepo.inMemory]), no auto-sync. [clock] stands in for the current time.
  @visibleForTesting
  factory WalletController.forTest(WalletRepo repo, {VaultKey? key, DateTime Function()? clock}) =>
      WalletController._(repo, key, clock: clock)..reload();

  /// The saved monthly budgets per category (cents).
  Map<String, int> get categoryBudgets => settings.categoryBudgets;

  bool get hasWallet => key != null;
  String get currency => settings.currency;

  String today() => isoDate(_clock());

  /// Tells the screens when the day has changed since they were last built (the app stayed open over midnight), so periods,
  /// months and the delivery panel move on without a data change. Called on resume and by the periodic timer.
  void checkDay() {
    final d = today();
    if (_seenDay == null || d == _seenDay) return;
    logEvent(_log, Level.INFO, 'day.changed', {'from': _seenDay, 'to': d});
    _seenDay = d;
    notifyListeners();
  }

  void reload() {
    final t = PerfTimer('wc.reload');
    settings = repo.settings();
    categorizer = repo.categorizer();
    final raw = repo.transactions(); // logs repo.transactions
    txs = timed('wc.categorize', () => raw.map(categorizer.categorize).toList(), fields: {'tx': raw.length});
    final (g, w) = timed('wc.goalsWish', () => (repo.goals(), repo.wishlist()));
    goals = g;
    wish = w;
    dataVersion++;
    _memo.clear();
    _seenDay = _memoDay = today();
    t.done({'tx': txs.length, 'goals': goals.length, 'wish': wish.length});
    notifyListeners();
  }

  /// Derived values are computed once per [dataVersion] and day, however often a screen asks (every build, every tab).
  T _cached<T>(String key, T Function() compute) {
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
  (int, int) get deliveries => _cached('deliveries', () {
        final month = monthOf(today());
        final xs = txs.where((t) => t.category == 'Food delivery' && monthOf(t.date) == month && t.amount < 0);
        return (xs.length, -xs.fold<int>(0, (a, t) => a + t.amount));
      });

  /// The sum of every goal's target (cents).
  int get goalTargetTotal => _cached('goalTargetTotal', () => goals.fold<int>(0, (a, g) => a + g.target));

  /// The sum of the prices of wishes still cooling off (cents). Not cached: it depends on the wall clock.
  int get waitingTotal {
    final now = DateTime.now().millisecondsSinceEpoch;
    return wish.where((w) => w.status == 'waiting' && w.hoursLeft(settings.coolHours, now) > 0).fold<int>(0, (a, w) => a + w.price);
  }

  /// The date of the newest transaction per bank source (`pbz`, `revolut`); a source without rows is missing.
  Map<String, String> get latestBySource => _cached('latestBySource', () {
        final out = <String, String>{};
        for (final t in txs) {
          out.putIfAbsent(t.tx.source, () => t.date); // txs are newest first
          if (out.containsKey('pbz') && out.containsKey('revolut')) break;
        }
        return out;
      });

  List<String> get _paydays => _cached('paydays', () => salaryPaydays(txs, today()));

  /// The period start: saved value, or the latest payday (its first salary payment), or today.
  WalletSettings get effectiveSettings => _cached('effective', () {
        if (settings.periodStart != null) return settings;
        final m = settings.toMap()..['periodStart'] = _paydays.lastOrNull ?? today();
        return WalletSettings.fromMap(m);
      });

  /// A payday more than 20 days after the current period start, not yet started as a new month.
  String? newPayday(String periodStart) => _paydays.where((d) => d.compareTo(addDays(periodStart, 20)) > 0).lastOrNull;

  PeriodBudget period() =>
      _cached('period', () => timed('wc.period', () => computePeriod(txs, effectiveSettings, goals, today()), warnMs: 50));

  /// Saved or lost per pay period (salary to salary), oldest first; the last one is still running.
  List<PeriodSummary> payPeriods({int count = 12}) => _cached('payPeriods$count',
      () => timed('wc.payPeriods', () => periodSummaries(txs, settings, today(), count: count), fields: {'count': count}, warnMs: 50));

  /// What the Spending tab shows for month [sel] (`YYYY-MM`, default: this month). Cached per month until the data changes.
  SpendingView spending([String? sel]) {
    final current = monthOf(today());
    final months = monthsEnding(current, 13);
    final month = sel != null && months.contains(sel) ? sel : current;
    return _cached(
        'spending$month',
        () => timed('spending.derive', () {
              final sums = [
                for (final m in months)
                  _cached('monthSummary$m', () => timed('wc.monthSummary', () => monthSummary(txs, m), fields: {'month': m}))
              ];
              final selSum = sums.firstWhere((s) => s.month == month);
              final prev = sums.where((s) => s.month.compareTo(month) < 0).toList();
              final prev6 = prev.length > 6 ? prev.sublist(prev.length - 6) : prev;
              final avg = <String, int>{};
              for (final p in prev6) {
                p.byCategory.forEach((k, v) => avg[k] = (avg[k] ?? 0) + (v / (prev6.isEmpty ? 1 : prev6.length)).round());
              }
              final periods = payPeriods(count: 12);

              final merch = <String, (int, int)>{};
              final monthTxs = <CategorizedTx>[];
              for (final t in txs) {
                if (monthOf(t.date) != month) continue;
                if (t.kind != Kind.transfer) monthTxs.add(t);
                if (t.kind == Kind.flex && t.amount < 0) {
                  final k = merchantName(t.tx);
                  final (n, v) = merch[k] ?? (0, 0);
                  merch[k] = (n + 1, v - t.amount);
                }
              }
              final top = merch.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
              return SpendingView(
                month: month,
                months: months,
                summary: selSum,
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
      'budget$month',
      () => timed('wc.budgetVsActual', () => _computeBudget(txs, month, categoryBudgets, today: today()),
          fields: {'month': month, 'tx': txs.length}, warnMs: 50));

  /// Budgets worked out from the 6 months before [month], per category (cents, rounded up to 10).
  Map<String, int> suggestedBudgets(String month) =>
      _cached('suggest$month', () => timed('wc.suggestBudgets', () => suggestBudgets(txs, month), fields: {'month': month}, warnMs: 50));

  /// The budgeted category with the least money left this month, or null when nothing is budgeted.
  CategoryBudgetLine? tightestBudget() => _cached('tightest', () {
        CategoryBudgetLine? best;
        for (final l in budgetVsActual(monthOf(today())).lines) {
          final r = l.remaining;
          if (r != null && (best == null || r < best.remaining!)) best = l;
        }
        return best;
      });

  /// Saves the whole map of budgets (an empty map clears them). Logs the count only.
  void saveCategoryBudgets(Map<String, int> budgets) {
    repo.updateSettings({'categoryBudgets': budgets});
    logEvent(_log, Level.INFO, 'budgets.saved', {'count': budgets.length}); // never the categories or amounts
    _changed();
  }

  void _changed() {
    reload();
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => syncNow(quiet: true, trigger: 'change'));
  }

  // ---------- wallet / key ----------
  Future<void> createWallet() async {
    final k = VaultKey.generate();
    await KeyStore.write(k);
    key = k;
    logEvent(_log, Level.INFO, 'wallet.create', {'defaultGoals': repo.goals().isEmpty});
    if (repo.goals().isEmpty) {
      repo.saveGoal(name: 'Emergency fund', target: 300000, saved: 0, monthly: 10000, sort: 1);
      repo.saveGoal(name: 'Yearly costs', target: 120000, saved: 0, monthly: 10000, sort: 2);
    }
    _changed();
  }

  Future<void> joinWallet(String text) async {
    final k = await VaultKey.parse(text); // errors are logged by the caller (never the text)
    await KeyStore.write(k);
    key = k;
    logEvent(_log, Level.INFO, 'wallet.join');
    notifyListeners();
    await syncNow(trigger: 'join');
  }

  Future<String> keyText() async => key == null ? '' : await key!.toText();

  // ---------- sync ----------
  /// [create]: make the folder first if it is missing (a typed path); a failure is logged and sync then reports it.
  Future<void> setSyncFolder(String? path, {bool create = false}) async {
    if (create && path != null) {
      try {
        await Directory(path).create(recursive: true);
      } catch (e, st) {
        // Sync then reports the missing folder; describeError drops the path.
        logError(_sync, 'sync.folderCreateFailed', e, st);
      }
    }
    repo.setLocalValue('syncFolder', path);
    syncFolder = path;
    syncError = null;
    logEvent(_sync, Level.INFO, 'sync.folder', {'set': path != null}); // never the path
    notifyListeners();
    if (path != null) await syncNow(trigger: 'folder');
  }

  /// Default folder on iPhone: the app's Documents folder, visible in the Files app.
  Future<String> defaultSyncFolder() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}${Platform.pathSeparator}BudgetWalletSync');
    await d.create(recursive: true);
    return d.path;
  }

  /// [trigger] says why it ran (button, timer, change, resume, startup, folder, join) for the log.
  Future<void> syncNow({bool quiet = false, String trigger = 'button'}) async {
    final folder = syncFolder, k = key;
    if (folder == null || k == null || syncing) {
      logEvent(
          _sync, Level.FINER, 'sync.skip', {'trigger': trigger, 'reason': folder == null ? 'noFolder' : (k == null ? 'noKey' : 'busy')});
      return;
    }
    syncing = true;
    if (!quiet) notifyListeners();
    final dataBefore = _dataMark();
    try {
      final r = await timedAsync('sync.run', () => syncRunner(folder, k, repo), fields: {'trigger': trigger}, warnMs: 3000);
      lastSync = DateTime.now();
      syncError = null;
      syncBadFiles = r.badFiles;
      logEvent(_sync, Level.INFO, 'sync.done',
          {'trigger': trigger, 'sent': r.sent, 'received': r.received, 'files': r.filesRead, 'bad': r.badFiles});
      if (r.received > 0 || r.sent > 0) reload();
    } catch (e, st) {
      logError(_sync, 'sync.failed', e, st, fields: {'trigger': trigger});
      syncError = e.toString();
      // A run that failed partway (a folder that stopped being readable after file A) may already have applied A's changes.
      // Reload only if wallet data changed during the run: a sync that keeps failing before applying anything (no folder
      // access, read-only mount) must not reload the whole wallet every 2 minutes.
      if (_dataMark() != dataBefore) reload();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Changes when wallet data changes: every data write (local or applied from a peer) records its field clock. Bookkeeping
  /// a failed run still makes (the next file number in `meta`, the outbox) doesn't count.
  String _dataMark() {
    final r = repo.db.select('SELECT count(*) AS n, max(hlc) AS m FROM clocks').first;
    return '${r['n']}|${r['m']}';
  }

  void _startAutoSync() {
    _syncTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      checkDay();
      syncNow(quiet: true, trigger: 'timer');
    });
    scheduleMicrotask(() => syncNow(quiet: true, trigger: 'startup'));
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

  /// Writes the logs into the sync folder's `diagnostics/` (or the app documents folder) and returns the path.
  Future<String> saveLogsToFolder() async {
    final sep = Platform.pathSeparator;
    final base = syncFolder ?? (await getApplicationDocumentsDirectory()).path;
    final dir = Directory('$base${sep}diagnostics');
    await dir.create(recursive: true);
    final f = File('${dir.path}$sep${logFileName()}');
    final bytes = await logBytes();
    await f.writeAsBytes(bytes, flush: true);
    logEvent(_log, Level.INFO, 'log.saved', {'to': syncFolder != null ? 'syncFolder' : 'documents', 'bytes': bytes.length});
    return f.path;
  }

  Future<void> clearLogs() => AppLog.clear();

  @override
  void dispose() {
    logEvent(_log, Level.FINE, 'wc.dispose');
    _syncTimer?.cancel();
    _debounce?.cancel();
    repo.close();
    super.dispose();
  }

  // ---------- import ----------
  /// Logs per file on `bw.import`: index, extension, size and counts. Never the file name.
  Future<List<ImportLine>> importFiles(List<(String, Uint8List)> files) async {
    final all = PerfTimer('import.files', warnMs: 3000);
    final lines = <ImportLine>[];
    for (final (i, (name, bytes)) in files.indexed) {
      final f = <String, Object?>{'file': i, 'ext': fileExt(name), 'bytes': bytes.length};
      final t = PerfTimer('import.file', warnMs: 1500);
      try {
        final batch = timed('import.parse', () => importBankFile(bytes), fields: f, warnMs: 1000);
        final s = repo.importBatch(batch); // logs repo.importBatch
        t.done({
          ...f,
          'source': batch.source,
          'rows': batch.transactions.length,
          'added': s.added,
          'dupes': s.duplicates,
          'matched': s.matched,
          'skipped': s.skipped,
          'invalid': batch.invalid
        });
        final bank = batch.source == 'pbz' ? 'PBZ' : 'Revolut';
        lines.add(ImportLine(
            name,
            '$bank: ${s.added} new, ${s.duplicates} already here${s.matched > 0 ? ', ${s.matched} matched to expenses you added' : ''}'
            '${batch.invalid > 0 ? ', ${batch.invalid} unreadable ${batch.invalid == 1 ? 'row' : 'rows'} left out' : ''}.',
            true));
      } on ImportException catch (e, st) {
        logError(_import, 'import.rejected', e, st, fields: f);
        lines.add(ImportLine(name, e.message, false));
      } catch (e, st) {
        logError(_import, 'import.failed', e, st, fields: f, level: Level.SEVERE);
        lines.add(ImportLine(name, "Couldn't read this file.", false));
      }
    }
    all.done({'files': files.length, 'ok': lines.where((l) => l.ok).length});
    lastImport = lines;
    _changed();
    return lines;
  }

  // ---------- edits ----------
  void addExpense({required int amount, required String category, required String note, required String date}) {
    repo.addManual(date: date, amount: amount, category: category, note: note, currency: currency);
    logEvent(_log, Level.INFO, 'expense.add', {'category': category}); // category only
    _changed();
  }

  void setCategory(Tx t, String category, {required bool always}) {
    // Built-in category names only; never the merchant.
    logEvent(
        _log, Level.INFO, 'category.change', {'from': categorizer.categoryOf(t), 'to': category, 'always': always, 'source': t.source});
    if (always && t.source != 'manual') {
      repo.setMerchantRule(merchantKey(t), category);
      if (t.category != null) repo.setCategory(t.id, null);
    } else {
      repo.setCategory(t.id, category);
    }
    _changed();
  }

  void deleteTx(Tx t) {
    repo.deleteTransaction(t.id);
    logEvent(_log, Level.INFO, 'tx.delete', {'manual': t.manual});
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
    repo.deleteGoal(id);
    logEvent(_log, Level.INFO, 'goal.delete');
    _changed();
  }

  void addWish(String name, int price) {
    repo.addWish(name, price);
    logEvent(_log, Level.INFO, 'wish.add', {'status': 'waiting'}); // never the name or price
    _changed();
  }

  void decideWish(String id, String status) {
    repo.decideWish(id, status);
    logEvent(_log, Level.INFO, 'wish.decide', {'status': status});
    _changed();
  }
}
