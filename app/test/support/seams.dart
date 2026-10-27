// Mutable stand-ins for the controller's seams. [WalletControllerDeps] is immutable, so a test that swaps a seam mid-test
// (`wc.seams.syncRunner = ...`) goes through these: every function in the deps handed to the controller forwards to the field here.
// Create the controller with [seamedController] (or [seamedLoad]); [ControllerSeams.seams] gives the fake back.
import 'dart:typed_data';

import 'package:budget_wallet/src/bill_inputs.dart';
import 'package:budget_wallet/src/calendar_source.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/controller_deps.dart';
import 'package:budget_wallet/src/home_widget.dart';
import 'package:budget_wallet/src/nudges.dart';
import 'package:budget_wallet/src/pdf_parse.dart';
import 'package:budget_wallet/src/wallet_db.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

final _registry = Expando<TestSeams>('seams');

/// The fake behind one controller's deps: settable callbacks, starting as the ones in the deps it was made from.
class TestSeams {
  TestSeams(WalletControllerDeps base)
      : syncRunner = base.syncRunner,
        healthCheck = base.healthCheck,
        backupBytesWriter = base.backupBytesWriter,
        backupMerger = base.backupMerger,
        keyReader = base.keyReader,
        keyWriter = base.keyWriter,
        unlocker = base.unlocker,
        keyForgetter = base.keyForgetter,
        isLocked = base.isLocked,
        joinMarkerReader = base.joinMarkerReader,
        joinMarkerWriter = base.joinMarkerWriter,
        joinMarkerClearer = base.joinMarkerClearer,
        keyAsideWriter = base.keyAsideWriter,
        keyAsideRemover = base.keyAsideRemover,
        deviceIdReader = base.deviceIdReader,
        deviceIdWriter = base.deviceIdWriter,
        dbOpener = base.dbOpener,
        dbExists = base.dbExists,
        dbIsPlaintext = base.dbIsPlaintext,
        dbSetAside = base.dbSetAside,
        clipboardWrite = base.clipboardWrite,
        clipboardRead = base.clipboardRead,
        icsFetcher = base.icsFetcher,
        pdfParser = base.pdfParser,
        billCategorySuggester = null,
        backupBytesReader = null;

  Future<SyncReport> Function(Uri relay, VaultKey key, WalletRepo repo) syncRunner;
  Future<void> Function(Uri relay) healthCheck;
  Future<BackupResult> Function(WalletRepo repo, VaultKey key) backupBytesWriter;
  Future<MergeResult> Function(WalletRepo repo, Uint8List bytes, VaultKey key, {bool dryRun, VaultKey? walletKey}) backupMerger;
  Future<VaultKey?> Function() keyReader;
  Future<void> Function(VaultKey key, {String? passphrase}) keyWriter;
  Future<VaultKey> Function(String passphrase) unlocker;
  Future<void> Function() keyForgetter;
  bool Function() isLocked;
  Future<String?> Function() joinMarkerReader;
  Future<void> Function(String text) joinMarkerWriter;
  Future<void> Function() joinMarkerClearer;
  Future<String> Function(String stamp, VaultKey key) keyAsideWriter;
  Future<void> Function(String slot) keyAsideRemover;
  Future<String?> Function() deviceIdReader;
  Future<void> Function(String id) deviceIdWriter;
  Future<WalletDb> Function(Uint8List dbKey, {String? deviceId}) dbOpener;
  Future<bool> Function() dbExists;
  Future<bool> Function() dbIsPlaintext;
  Future<void> Function(String stamp) dbSetAside;
  Future<void> Function(String text) clipboardWrite;
  Future<String?> Function() clipboardRead;
  Future<String> Function(Uri url) icsFetcher;
  PdfParser pdfParser;

  /// null = the controller's own suggestion (not forwarded).
  String? Function(Bill b)? billCategorySuggester;

  /// null = the controller's own restore path (not forwarded).
  Future<int> Function(WalletRepo repo, Uint8List bytes, VaultKey key)? backupBytesReader;

  /// The deps for the controller: each function forwards to the field of the same name, read at call time.
  WalletControllerDeps build(WalletControllerDeps base) => base.copyWith(
        syncRunner: (relay, key, repo) => syncRunner(relay, key, repo),
        healthCheck: (relay) => healthCheck(relay),
        backupBytesWriter: (repo, key) => backupBytesWriter(repo, key),
        backupMerger: (repo, bytes, key, {dryRun = false, walletKey}) =>
            backupMerger(repo, bytes, key, dryRun: dryRun, walletKey: walletKey),
        keyReader: () => keyReader(),
        keyWriter: (key, {passphrase}) => keyWriter(key, passphrase: passphrase),
        unlocker: (passphrase) => unlocker(passphrase),
        keyForgetter: () => keyForgetter(),
        isLocked: () => isLocked(),
        joinMarkerReader: () => joinMarkerReader(),
        joinMarkerWriter: (text) => joinMarkerWriter(text),
        joinMarkerClearer: () => joinMarkerClearer(),
        keyAsideWriter: (stamp, key) => keyAsideWriter(stamp, key),
        keyAsideRemover: (slot) => keyAsideRemover(slot),
        deviceIdReader: () => deviceIdReader(),
        deviceIdWriter: (id) => deviceIdWriter(id),
        dbOpener: (dbKey, {deviceId}) => dbOpener(dbKey, deviceId: deviceId),
        dbExists: () => dbExists(),
        dbIsPlaintext: () => dbIsPlaintext(),
        dbSetAside: (stamp) => dbSetAside(stamp),
        clipboardWrite: (text) => clipboardWrite(text),
        clipboardRead: () => clipboardRead(),
        icsFetcher: (url) => icsFetcher(url),
        pdfParser: (pdf) => pdfParser(pdf),
        // Forwarded only when a test set them; otherwise the controller's own (production) path runs.
        billCategorySuggester: (b, builtIn) => billCategorySuggester != null ? billCategorySuggester!(b) : builtIn(),
        backupBytesReader: (r, bytes, opener, walletKey) =>
            backupBytesReader != null ? backupBytesReader!(r, bytes, opener) : base.backupBytesReader(r, bytes, opener, walletKey),
      );
}

WalletControllerDeps _inert() => WalletControllerDeps.platform(
    nudges: const NoNudges(), calendars: const NoCalendars(), homeWidget: const NoHomeWidget(), billInputs: const BillInputs.none());

/// [WalletController.forTest] with deps that forward to a [TestSeams] (reachable as `wc.seams`).
WalletController seamedController(WalletRepo repo,
    {VaultKey? key,
    WalletControllerDeps? deps,
    DateTime Function()? clock,
    NudgePlatform? nudges,
    CalendarSource? calendars,
    HomeWidget? homeWidget,
    BillInputs? billInputs,
    WalletDb? db,
    bool locked = false}) {
  final base = deps ?? _inert();
  final seams = TestSeams(base);
  final wc = WalletController.forTest(repo,
      key: key,
      deps: seams.build(base),
      clock: clock,
      nudges: nudges,
      calendars: calendars,
      homeWidget: homeWidget,
      billInputs: billInputs,
      db: db,
      locked: locked);
  _registry[wc] = seams;
  return wc;
}

/// Builds a controller with [make] (which must hand the deps to `WalletController.load`, e.g. through `bootstrap(deps:)`) on deps
/// that forward to a [TestSeams] (reachable as `wc.seams`); [base] holds the starting values (default: the real ones).
Future<WalletController> seamedBoot(Future<WalletController> Function(WalletControllerDeps deps) make, [WalletControllerDeps? base]) async {
  final b = base ?? WalletControllerDeps.platform();
  final seams = TestSeams(b);
  final wc = await make(seams.build(b));
  _registry[wc] = seams;
  return wc;
}

/// [WalletController.load] with deps that forward to a [TestSeams] (reachable as `wc.seams`); [base] holds the starting values.
Future<WalletController> seamedLoad(WalletControllerDeps base, {Future<void> Function()? claim}) =>
    seamedBoot((deps) => WalletController.load(deps: deps, claim: claim ?? () async {}), base);

/// A starting point for [seamedLoad]: the real deps (as `load` would use) with the given members replaced.
WalletControllerDeps loadDeps({String? dbDir}) => WalletControllerDeps.platform(dbDir: dbDir);

extension ControllerSeams on WalletController {
  /// The mutable seams of a controller made by [seamedController] or [seamedLoad].
  TestSeams get seams => _registry[this]!;
}
