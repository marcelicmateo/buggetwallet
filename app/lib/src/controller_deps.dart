import 'dart:typed_data';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'bill_inputs.dart';
import 'bill_platform.dart';
import 'calendar_platform.dart';
import 'calendar_source.dart';
import 'controller.dart' show WalletController;
import 'home_widget.dart';
import 'ics_fetch.dart';
import 'key_store.dart';
import 'nudge_platform.dart';
import 'nudges.dart' show NudgePlatform;
import 'pdf_parse.dart';
import 'wallet_db.dart';

/// Everything [WalletController] reaches outside the app through: the clock, the key store, the database files, the relay, the
/// clipboard, the phone's platform objects. One immutable object, so the controller has no seam that is reassigned after it was
/// built; a test builds one with [copyWith] (or the mutable fake in `test/support/seams.dart`) and hands it in.
///
/// [WalletControllerDeps.platform] holds the real ones.
class WalletControllerDeps {
  const WalletControllerDeps({
    required this.clock,
    required this.nudges,
    required this.calendars,
    required this.homeWidget,
    required this.billInputs,
    required this.syncRunner,
    required this.healthCheck,
    required this.backupBytesWriter,
    required this.backupMerger,
    required this.keyReader,
    required this.keyWriter,
    required this.unlocker,
    required this.keyForgetter,
    required this.isLocked,
    required this.joinMarkerReader,
    required this.joinMarkerWriter,
    required this.joinMarkerClearer,
    required this.keyAsideWriter,
    required this.keyAsideRemover,
    required this.deviceIdReader,
    required this.deviceIdWriter,
    required this.dbOpener,
    required this.dbExists,
    required this.dbIsPlaintext,
    required this.dbSetAside,
    required this.clipboardWrite,
    required this.clipboardRead,
    required this.icsFetcher,
    required this.pdfParser,
    required this.billCategorySuggester,
    required this.backupBytesReader,
  });

  /// The real ones. The four platform objects are looked up only when not given (tests pass the inert ones); [dbDir] points the
  /// database files at another folder (tests; null = the app support folder), [keyStore] replaces the key store.
  factory WalletControllerDeps.platform({
    NudgePlatform? nudges,
    CalendarSource? calendars,
    HomeWidget? homeWidget,
    BillInputs? billInputs,
    KeyStore? keyStore,
    String? dbDir,
  }) {
    final ks = keyStore ?? KeyStore();
    return WalletControllerDeps(
      clock: DateTime.now,
      nudges: nudges ?? defaultNudgePlatform(),
      calendars: calendars ?? defaultCalendarSource(),
      homeWidget: homeWidget ?? defaultHomeWidget(),
      billInputs: billInputs ?? defaultBillInputs(),
      syncRunner: WalletController.runRelaySync,
      healthCheck: RelayTransport.health,
      backupBytesWriter: backupBytesWithInfo,
      backupMerger: mergeBackupBytes,
      keyReader: ks.read,
      keyWriter: ks.write,
      unlocker: ks.unlock,
      keyForgetter: ks.forget,
      isLocked: () => ks.isLocked,
      joinMarkerReader: ks.readJoinMarker,
      joinMarkerWriter: ks.writeJoinMarker,
      joinMarkerClearer: ks.clearJoinMarker,
      keyAsideWriter: ks.writeAside,
      keyAsideRemover: ks.removeAside,
      deviceIdReader: ks.readDeviceId,
      deviceIdWriter: ks.writeDeviceId,
      dbOpener: (k, {deviceId}) => openWalletDb(k, deviceId: deviceId, dir: dbDir),
      dbExists: () => walletDbExists(dir: dbDir),
      dbIsPlaintext: () => walletDbIsPlaintext(dir: dbDir),
      dbSetAside: (stamp) => setAsideWalletDb(stamp, dir: dbDir),
      clipboardWrite: (t) => Clipboard.setData(ClipboardData(text: t)),
      clipboardRead: () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
      icsFetcher: fetchIcs,
      pdfParser: parsePdf,
      billCategorySuggester: (b, builtIn) => builtIn(),
      backupBytesReader: (r, bytes, opener, walletKey) => restoreBackupBytes(r, bytes, opener, walletKey: walletKey),
    );
  }

  /// The current time; tests move it.
  final DateTime Function() clock;

  /// The phone's reminders (Plan › Nudges); [NoNudges] in tests and on desktop.
  final NudgePlatform nudges;

  /// The phone's calendars (Plan › Calendars); [NoCalendars] in tests and on desktop and web.
  final CalendarSource calendars;

  /// The Android home-screen widget and launcher shortcut (P13); [NoHomeWidget] in tests, on desktop and web.
  final HomeWidget homeWidget;

  /// The camera, picture reading, PDF pages and Share intent (bills); [BillInputs.none] in tests and off Android.
  final BillInputs billInputs;

  /// Runs the sync against the relay at an address.
  final Future<SyncReport> Function(Uri relay, VaultKey key, WalletRepo repo) syncRunner;

  /// Checks that a relay answers at an address.
  final Future<void> Function(Uri relay) healthCheck;

  /// A backup is the bytes of an encrypted file (saved through the system save dialog).
  final Future<BackupResult> Function(WalletRepo repo, VaultKey key) backupBytesWriter;

  /// Merges a picked backup into the open wallet.
  final Future<MergeResult> Function(WalletRepo repo, Uint8List bytes, VaultKey key, {bool dryRun, VaultKey? walletKey}) backupMerger;

  /// Reads the stored wallet key at start-up (null = none).
  final Future<VaultKey?> Function() keyReader;

  /// Stores the wallet key.
  final Future<void> Function(VaultKey key, {String? passphrase}) keyWriter;

  /// Opens the stored key with a passphrase (browser only).
  final Future<VaultKey> Function(String passphrase) unlocker;

  /// Deletes the stored key and device id.
  final Future<void> Function() keyForgetter;

  /// True when a wrapped key is stored but this tab is not unlocked (browser only).
  final bool Function() isLocked;

  /// Reads the "join pending" marker of Join another wallet.
  final Future<String?> Function() joinMarkerReader;

  /// Writes the "join pending" marker.
  final Future<void> Function(String text) joinMarkerWriter;

  /// Clears the "join pending" marker.
  final Future<void> Function() joinMarkerClearer;

  /// Keeps the old wallet's key under a second slot named after the set-aside stamp (returns the slot).
  final Future<String> Function(String stamp, VaultKey key) keyAsideWriter;

  /// Takes back a slot made by [keyAsideWriter] whose set-aside did not happen.
  final Future<void> Function(String slot) keyAsideRemover;

  /// This install's device id (H6), kept next to the key.
  final Future<String?> Function() deviceIdReader;

  /// Stores this install's device id.
  final Future<void> Function(String id) deviceIdWriter;

  /// Opens (or creates) the keyed wallet database with `localDbKey(key)`.
  final Future<WalletDb> Function(Uint8List dbKey, {String? deviceId}) dbOpener;

  /// Is there a wallet database file on this device? (Asked only while no key is known.)
  final Future<bool> Function() dbExists;

  /// Is the stored wallet file an unkeyed (plaintext) one? Asked on join, which must never convert such a file.
  final Future<bool> Function() dbIsPlaintext;

  /// Moves the wallet database aside (`wallet.db.unopened-<stamp>`), nothing deleted.
  final Future<void> Function(String stamp) dbSetAside;

  /// The system clipboard, write ([WalletController.copyKeyBackup] clears the key from it again).
  final Future<void> Function(String text) clipboardWrite;

  /// The system clipboard, read.
  final Future<String?> Function() clipboardRead;

  /// Downloads the text of an `.ics` link.
  final Future<String> Function(Uri url) icsFetcher;

  /// Reads a PDF's text layer and the bill in it: off the UI isolate on native (pdf_parse.dart).
  final PdfParser pdfParser;

  /// The category to suggest for a bill; [builtIn] works out the real suggestion (the default returns it).
  final String? Function(Bill b, String? Function() builtIn) billCategorySuggester;

  /// Restores picked backup bytes with [opener]; the controller always passes the wallet's own key too ([walletKey]).
  final Future<int> Function(WalletRepo repo, Uint8List bytes, VaultKey opener, VaultKey walletKey) backupBytesReader;

  /// A copy with the given members replaced (a nullable member cannot be reset to null this way).
  WalletControllerDeps copyWith({
    DateTime Function()? clock,
    NudgePlatform? nudges,
    CalendarSource? calendars,
    HomeWidget? homeWidget,
    BillInputs? billInputs,
    Future<SyncReport> Function(Uri relay, VaultKey key, WalletRepo repo)? syncRunner,
    Future<void> Function(Uri relay)? healthCheck,
    Future<BackupResult> Function(WalletRepo repo, VaultKey key)? backupBytesWriter,
    Future<MergeResult> Function(WalletRepo repo, Uint8List bytes, VaultKey key, {bool dryRun, VaultKey? walletKey})? backupMerger,
    Future<VaultKey?> Function()? keyReader,
    Future<void> Function(VaultKey key, {String? passphrase})? keyWriter,
    Future<VaultKey> Function(String passphrase)? unlocker,
    Future<void> Function()? keyForgetter,
    bool Function()? isLocked,
    Future<String?> Function()? joinMarkerReader,
    Future<void> Function(String text)? joinMarkerWriter,
    Future<void> Function()? joinMarkerClearer,
    Future<String> Function(String stamp, VaultKey key)? keyAsideWriter,
    Future<void> Function(String slot)? keyAsideRemover,
    Future<String?> Function()? deviceIdReader,
    Future<void> Function(String id)? deviceIdWriter,
    Future<WalletDb> Function(Uint8List dbKey, {String? deviceId})? dbOpener,
    Future<bool> Function()? dbExists,
    Future<bool> Function()? dbIsPlaintext,
    Future<void> Function(String stamp)? dbSetAside,
    Future<void> Function(String text)? clipboardWrite,
    Future<String?> Function()? clipboardRead,
    Future<String> Function(Uri url)? icsFetcher,
    PdfParser? pdfParser,
    String? Function(Bill b, String? Function() builtIn)? billCategorySuggester,
    Future<int> Function(WalletRepo repo, Uint8List bytes, VaultKey opener, VaultKey walletKey)? backupBytesReader,
  }) =>
      WalletControllerDeps(
        clock: clock ?? this.clock,
        nudges: nudges ?? this.nudges,
        calendars: calendars ?? this.calendars,
        homeWidget: homeWidget ?? this.homeWidget,
        billInputs: billInputs ?? this.billInputs,
        syncRunner: syncRunner ?? this.syncRunner,
        healthCheck: healthCheck ?? this.healthCheck,
        backupBytesWriter: backupBytesWriter ?? this.backupBytesWriter,
        backupMerger: backupMerger ?? this.backupMerger,
        keyReader: keyReader ?? this.keyReader,
        keyWriter: keyWriter ?? this.keyWriter,
        unlocker: unlocker ?? this.unlocker,
        keyForgetter: keyForgetter ?? this.keyForgetter,
        isLocked: isLocked ?? this.isLocked,
        joinMarkerReader: joinMarkerReader ?? this.joinMarkerReader,
        joinMarkerWriter: joinMarkerWriter ?? this.joinMarkerWriter,
        joinMarkerClearer: joinMarkerClearer ?? this.joinMarkerClearer,
        keyAsideWriter: keyAsideWriter ?? this.keyAsideWriter,
        keyAsideRemover: keyAsideRemover ?? this.keyAsideRemover,
        deviceIdReader: deviceIdReader ?? this.deviceIdReader,
        deviceIdWriter: deviceIdWriter ?? this.deviceIdWriter,
        dbOpener: dbOpener ?? this.dbOpener,
        dbExists: dbExists ?? this.dbExists,
        dbIsPlaintext: dbIsPlaintext ?? this.dbIsPlaintext,
        dbSetAside: dbSetAside ?? this.dbSetAside,
        clipboardWrite: clipboardWrite ?? this.clipboardWrite,
        clipboardRead: clipboardRead ?? this.clipboardRead,
        icsFetcher: icsFetcher ?? this.icsFetcher,
        pdfParser: pdfParser ?? this.pdfParser,
        billCategorySuggester: billCategorySuggester ?? this.billCategorySuggester,
        backupBytesReader: backupBytesReader ?? this.backupBytesReader,
      );
}
