import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'key_store.dart';

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
    reload();
  }

  static Future<WalletController> load() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final repo = WalletRepo.open('${dir.path}${Platform.pathSeparator}wallet.db');
    VaultKey? key;
    try {
      key = await KeyStore.read();
    } catch (_) {
      key = null;
    }
    final c = WalletController._(repo, key);
    c._startAutoSync();
    return c;
  }

  bool get hasWallet => key != null;
  String get currency => settings.currency;

  String today() => isoDate(DateTime.now());

  void reload() {
    settings = repo.settings();
    categorizer = repo.categorizer();
    txs = repo.transactions().map(categorizer.categorize).toList();
    goals = repo.goals();
    wish = repo.wishlist();
    notifyListeners();
  }

  /// The period start: saved value, or the latest salary payment, or today.
  WalletSettings get effectiveSettings {
    if (settings.periodStart != null) return settings;
    final sal = txs.where((t) => t.kind == Kind.income && t.amount > 0).firstOrNull;
    final m = settings.toMap()..['periodStart'] = sal?.date ?? today();
    return WalletSettings.fromMap(m);
  }

  PeriodBudget period() => computePeriod(txs, effectiveSettings, goals, today());

  void _changed() {
    reload();
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => syncNow(quiet: true));
  }

  // ---------- wallet / key ----------
  Future<void> createWallet() async {
    final k = VaultKey.generate();
    await KeyStore.write(k);
    key = k;
    if (repo.goals().isEmpty) {
      repo.saveGoal(name: 'Emergency fund', target: 300000, saved: 0, monthly: 10000, sort: 1);
      repo.saveGoal(name: 'Yearly costs', target: 120000, saved: 0, monthly: 10000, sort: 2);
    }
    _changed();
  }

  Future<void> joinWallet(String text) async {
    final k = await VaultKey.parse(text);
    await KeyStore.write(k);
    key = k;
    notifyListeners();
    await syncNow();
  }

  Future<String> keyText() async => key == null ? '' : await key!.toText();

  // ---------- sync ----------
  Future<void> setSyncFolder(String? path) async {
    repo.setLocalValue('syncFolder', path);
    syncFolder = path;
    syncError = null;
    notifyListeners();
    if (path != null) await syncNow();
  }

  /// Default folder on iPhone: the app's Documents folder, visible in the Files app.
  Future<String> defaultSyncFolder() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}${Platform.pathSeparator}BudgetWalletSync');
    await d.create(recursive: true);
    return d.path;
  }

  Future<void> syncNow({bool quiet = false}) async {
    final folder = syncFolder, k = key;
    if (folder == null || k == null || syncing) return;
    syncing = true;
    if (!quiet) notifyListeners();
    try {
      final r = await FolderSync(folder, k).run(repo);
      lastSync = DateTime.now();
      syncError = null;
      if (r.received > 0 || r.sent > 0) reload();
    } catch (e) {
      syncError = e.toString();
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  void _startAutoSync() {
    _syncTimer = Timer.periodic(const Duration(minutes: 2), (_) => syncNow(quiet: true));
    scheduleMicrotask(() => syncNow(quiet: true));
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _debounce?.cancel();
    repo.close();
    super.dispose();
  }

  // ---------- import ----------
  Future<List<ImportLine>> importFiles(List<(String, Uint8List)> files) async {
    final lines = <ImportLine>[];
    for (final (name, bytes) in files) {
      try {
        final batch = importBankFile(bytes);
        final s = repo.importBatch(batch);
        final bank = batch.source == 'pbz' ? 'PBZ' : 'Revolut';
        lines.add(ImportLine(name, '$bank: ${s.added} new, ${s.duplicates} already here${s.matched > 0 ? ', ${s.matched} matched to expenses you added' : ''}.', true));
      } on ImportException catch (e) {
        lines.add(ImportLine(name, e.message, false));
      } catch (e) {
        lines.add(ImportLine(name, "Couldn't read this file.", false));
      }
    }
    lastImport = lines;
    _changed();
    return lines;
  }

  // ---------- edits ----------
  void addExpense({required int amount, required String category, required String note, required String date}) {
    repo.addManual(date: date, amount: amount, category: category, note: note, currency: currency);
    _changed();
  }

  void setCategory(Tx t, String category, {required bool always}) {
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
    _changed();
  }

  void updateSettings(Map<String, Object?> changes) {
    repo.updateSettings(changes);
    _changed();
  }

  void startNewMonth(String date) {
    repo.updateSettings({'periodStart': date, 'incomeMode': 'planned'});
    _changed();
  }

  void paydayDone(String periodStart) {
    repo.payGoals();
    repo.updateSettings({'savedFor': periodStart});
    _changed();
  }

  void saveGoal({String? id, required String name, required int target, required int saved, required int monthly, int? sort}) {
    repo.saveGoal(id: id, name: name, target: target, saved: saved, monthly: monthly, sort: sort);
    _changed();
  }

  void deleteGoal(String id) {
    repo.deleteGoal(id);
    _changed();
  }

  void addWish(String name, int price) {
    repo.addWish(name, price);
    _changed();
  }

  void decideWish(String id, String status) {
    repo.decideWish(id, status);
    _changed();
  }
}
