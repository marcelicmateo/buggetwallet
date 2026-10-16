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

class ImportLine {
  final String file;
  final String message;
  final bool ok;
  const ImportLine(this.file, this.message, this.ok);
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

  String? syncFolder;
  DateTime? lastSync;
  String? syncError;
  bool syncing = false;
  List<ImportLine> lastImport = const [];

  Timer? _syncTimer;
  Timer? _debounce;

  WalletController._(this.repo, this.key) {
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

  bool get hasWallet => key != null;
  String get currency => settings.currency;

  String today() => isoDate(DateTime.now());

  void reload() {
    final t = PerfTimer('wc.reload');
    settings = repo.settings();
    categorizer = repo.categorizer();
    final raw = repo.transactions(); // logs repo.transactions
    txs = timed('wc.categorize', () => raw.map(categorizer.categorize).toList(), fields: {'tx': raw.length});
    final (g, w) = timed('wc.goalsWish', () => (repo.goals(), repo.wishlist()));
    goals = g;
    wish = w;
    t.done({'tx': txs.length, 'goals': goals.length, 'wish': wish.length});
    notifyListeners();
  }

  /// The period start: saved value, or the latest payday (its first salary payment), or today.
  WalletSettings get effectiveSettings {
    if (settings.periodStart != null) return settings;
    final m = settings.toMap()..['periodStart'] = salaryPaydays(txs, today()).lastOrNull ?? today();
    return WalletSettings.fromMap(m);
  }

  /// A payday more than 20 days after the current period start, not yet started as a new month.
  String? newPayday(String periodStart) => salaryPaydays(txs, today()).where((d) => d.compareTo(addDays(periodStart, 20)) > 0).lastOrNull;

  PeriodBudget period() => timed('wc.period', () => computePeriod(txs, effectiveSettings, goals, today()), warnMs: 50);

  /// Saved or lost per pay period (salary to salary), oldest first; the last one is still running.
  List<PeriodSummary> payPeriods({int count = 12}) =>
      timed('wc.payPeriods', () => periodSummaries(txs, settings, today(), count: count), fields: {'count': count}, warnMs: 50);

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
  Future<void> setSyncFolder(String? path) async {
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
    try {
      final r = await timedAsync('sync.run', () => FolderSync(folder, k).run(repo), fields: {'trigger': trigger}, warnMs: 3000);
      lastSync = DateTime.now();
      syncError = null;
      logEvent(_sync, Level.INFO, 'sync.done', {'trigger': trigger, 'sent': r.sent, 'received': r.received, 'files': r.filesRead});
      if (r.received > 0 || r.sent > 0) reload();
    } catch (e, st) {
      logError(_sync, 'sync.failed', e, st, fields: {'trigger': trigger});
      syncError = e.toString();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  void _startAutoSync() {
    _syncTimer = Timer.periodic(const Duration(minutes: 2), (_) => syncNow(quiet: true, trigger: 'timer'));
    scheduleMicrotask(() => syncNow(quiet: true, trigger: 'startup'));
  }

  // ---------- diagnostics ----------
  /// Device-local log level: 'all' (debug, the default while testing), 'info' or 'warning'.
  String get logLevel => repo.localValue('logLevel') ?? 'all';

  void setLogLevel(String level) {
    logEvent(_log, Level.INFO, 'log.level', {'from': logLevel, 'to': level});
    repo.setLocalValue('logLevel', level);
    AppLog.setLevel(level);
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
          'skipped': s.skipped
        });
        final bank = batch.source == 'pbz' ? 'PBZ' : 'Revolut';
        lines.add(ImportLine(
            name,
            '$bank: ${s.added} new, ${s.duplicates} already here${s.matched > 0 ? ', ${s.matched} matched to expenses you added' : ''}.',
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
    repo.payGoals();
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
