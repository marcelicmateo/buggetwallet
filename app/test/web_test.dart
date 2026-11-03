// The web build's screens and controller paths, run on the VM with `debugIsWebOverride`: Plan with Sync (through the relay, here a
// MemoryTransport) but without Nudges, Backup as download and file restore, "Forget this browser", the passphrase step of
// onboarding, the Unlock screen and the database flush.
// The browser itself (IndexedDB, localStorage, file downloads) is replaced by fakes. All data is SYNTHETIC.
import 'dart:typed_data';

import 'package:budget_wallet/main.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/key_store.dart' show WrongPassphrase;
import 'package:budget_wallet/src/platform.dart' as plat;
import 'package:budget_wallet/src/screens/backup_panel.dart';
import 'package:budget_wallet/src/screens/diagnostics.dart';
import 'package:budget_wallet/src/screens/in_use.dart';
import 'package:budget_wallet/src/screens/onboarding.dart';
import 'package:budget_wallet/src/screens/unlock.dart';
import 'package:budget_wallet/src/wallet_db.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/layout.dart';
import 'support/plan_page.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

/// Throws any object (the fakes hold errors of every kind).
Never raise(Object error) => Error.throwWithStackTrace(error, StackTrace.current);

/// A picked file with its bytes in memory.
class FakePicked extends PickedFile {
  FakePicked(String name, Uint8List bytes) : super(name, () async => bytes, length: () async => bytes.length);
}

class FakeChooser extends FileChooser {
  final backups = <({String name, Uint8List bytes})>[];
  final texts = <({String name, Uint8List bytes})>[];
  List<PickedFile> picks = [];
  Object? saveError, pickError;
  FakeChooser();
  @override
  Future<Uri?> saveBackup({required String fileName, required Uint8List bytes, required String title}) async {
    if (saveError != null) raise(saveError!);
    backups.add((name: fileName, bytes: bytes));
    return Uri(path: fileName);
  }

  @override
  Future<Uri?> saveText({required String fileName, required Uint8List bytes, required String title}) async {
    if (saveError != null) raise(saveError!);
    texts.add((name: fileName, bytes: bytes));
    return Uri(path: fileName);
  }

  @override
  Future<List<PickedFile>> pickBackupFile() async {
    if (pickError != null) raise(pickError!);
    return picks;
  }
}

/// A database that counts what the controller asks of it, like the browser's does.
class FakeDb {
  int persists = 0;
  bool forgotten = false;
  Object? forgetError, persistError;
  late final WalletDb db;
  FakeDb(WalletRepo repo) {
    db = WalletDb(repo, persist: () async {
      persists++;
      if (persistError != null) raise(persistError!);
    }, forget: () async {
      forgotten = true;
      if (forgetError != null) raise(forgetError!);
    });
  }
}

/// A web wallet: a browser database fake, key fakes and a fresh empty database for after "Forget this browser".
class Web {
  final WalletController wc;
  final FakeDb db;
  bool _disposed = false;

  /// Stops the controller's timers (tests that forget the browser start new ones, which would still be pending at the end).
  void dispose() {
    if (!_disposed) wc.dispose();
    _disposed = true;
  }

  final keyWrites = <String?>[]; // the passphrase of each key write
  int keyForgets = 0;
  Web(this.wc, this.db);
}

Web webWallet({bool full = false, bool withKey = true, bool locked = false, VaultKey? key}) {
  final repo = WalletRepo.inMemory();
  final fake = FakeDb(repo);
  final wc = seamedController(repo, key: withKey ? (key ?? VaultKey.generate()) : null, db: fake.db, locked: locked);
  final w = Web(wc, fake);
  addTearDown(w.dispose);
  if (full) {
    wc.repo.addTransaction(date: wc.today(), amount: 1200, category: 'Groceries');
    wc.reload();
  }
  wc.seams.keyWriter = (key, {passphrase}) async => w.keyWrites.add(passphrase);
  wc.seams.keyForgetter = () async => w.keyForgets++;
  wc.seams.dbOpener = (dbKey, {deviceId}) async => FakeDb(WalletRepo.inMemory()).db;
  return w;
}

/// A widget test that lets the controller's timers (flush after 800 ms, sync after a change after 3 s) run out before it ends,
/// because a pending timer fails a test.
void webTest(String name, Future<void> Function(WidgetTester t) body) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 5));
    });

Finder get backupBtn => find.byKey(const ValueKey('backupNow'));
Finder get pass => find.byKey(const ValueKey('unlockPassphrase'));
Finder get restoreBtn => find.byKey(const ValueKey('restoreBackup'));
bool enabled(WidgetTester t, Finder f) => t.widget<ButtonStyleButton>(f).onPressed != null;

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
    plat.debugIsWebOverride = true;
    addTearDown(() => plat.debugIsWebOverride = null);
  });

  test('isWeb follows the override and is false on the VM otherwise', () {
    plat.debugIsWebOverride = null;
    expect(plat.isWeb, isFalse);
    plat.debugIsWebOverride = true;
    expect(plat.isWeb, isTrue);
  });

  group('Backup panel on the web', () {
    Future<void> pumpPanel(WidgetTester t, WalletController wc, FakeChooser c, {Size size = const Size(400, 900), double scale = 1}) async {
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: BackupPanel(wc: wc, chooser: c))), size: size, textScale: scale);
      await t.pump();
    }

    webTest('no relay needed: the button is on, no folder text, no "last backup" line', (t) async {
      final w = webWallet(full: true);
      await pumpPanel(t, w.wc, FakeChooser());
      expect(enabled(t, backupBtn), isTrue);
      expect(find.text('No backup yet'), findsNothing);
      expect(find.textContaining('folder'), findsNothing);
      expect(find.textContaining('as a file'), findsOneWidget);
    });

    webTest('Back up now downloads the dated file with the bytes from the core, toasts the name, logs no name or key', (t) async {
      final w = webWallet(full: true);
      final c = FakeChooser();
      final sealed = Uint8List.fromList([1, 2, 3, 4]);
      VaultKey? usedKey;
      w.wc.seams.backupBytesWriter = (repo, key) async {
        usedKey = key;
        return fakeBackup(sealed);
      };
      await pumpPanel(t, w.wc, c);
      await t.tap(backupBtn);
      await t.pump();
      await t.pump();
      final name = 'bw-backup-${w.wc.today()}.bwb';
      expect(c.backups.map((b) => b.name), [name]);
      expect(c.backups.single.bytes, sealed);
      expect(usedKey, same(w.wc.key));
      expect(find.text('Saved $name'), findsOneWidget);
      final log = lines.join('\n');
      expect(log, contains('backup.done'));
      expect(log, isNot(contains(name)));
    });

    webTest('a failed download shows one short text and the button works again', (t) async {
      final w = webWallet(full: true);
      final c = FakeChooser()..saveError = StateError('browser said no');
      w.wc.seams.backupBytesWriter = (repo, key) async => fakeBackup(Uint8List(3));
      await pumpPanel(t, w.wc, c);
      await t.tap(backupBtn);
      await t.pump();
      await t.pump();
      expect(find.textContaining("Couldn't save the backup."), findsOneWidget);
      expect(find.textContaining('browser said no'), findsNothing);
      expect(enabled(t, backupBtn), isTrue);
    });

    webTest('a core failure while making the backup shows the same text', (t) async {
      final w = webWallet(full: true);
      w.wc.seams.backupBytesWriter = (repo, key) async => throw const VaultException('x');
      await pumpPanel(t, w.wc, FakeChooser());
      await t.tap(backupBtn);
      await t.pump();
      await t.pump();
      expect(find.textContaining("Couldn't save the backup."), findsOneWidget);
      expect(lines.join('\n'), contains('backup.failed'));
    });

    webTest('Restore shows only while the wallet is empty', (t) async {
      await pumpPanel(t, webWallet(full: true).wc, FakeChooser());
      expect(restoreBtn, findsNothing);
      await pumpPanel(t, webWallet().wc, FakeChooser());
      expect(restoreBtn, findsOneWidget);
      expect(enabled(t, restoreBtn), isTrue, reason: 'no list of backups to wait for in a browser');
    });

    webTest('Restore picks a file, asks, reads its bytes through the core and toasts the row count', (t) async {
      final w = webWallet();
      final file = Uint8List.fromList([9, 8, 7]);
      final c = FakeChooser()..picks = [FakePicked('wallet.bwb', file)];
      Uint8List? got;
      w.wc.seams.backupBytesReader = (repo, bytes, key) async {
        got = bytes;
        return 12;
      };
      await pumpPanel(t, w.wc, c);
      await t.tap(restoreBtn);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('restoreConfirm')), findsOneWidget);
      expect(got, isNull, reason: 'nothing is read before the owner confirms');
      await t.tap(find.byKey(const ValueKey('restoreConfirm')));
      await t.pumpAndSettle();
      expect(got, file);
      expect(find.text('Restored 12 rows'), findsOneWidget);
      final log = lines.join('\n');
      expect(log, contains('backup.restored'));
      expect(log, isNot(contains('wallet.bwb')));
    });

    webTest('Cancel in the picker or in the question restores nothing', (t) async {
      final w = webWallet();
      var reads = 0;
      w.wc.seams.backupBytesReader = (repo, bytes, key) async => ++reads;
      final c = FakeChooser();
      await pumpPanel(t, w.wc, c);
      await t.tap(restoreBtn); // picker cancelled: empty list
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('restoreConfirm')), findsNothing);
      c.picks = [FakePicked('a.bwb', Uint8List(2))];
      await t.tap(restoreBtn);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('restoreCancel')));
      await t.pumpAndSettle();
      expect(reads, 0);
    });

    webTest('a picker that fails shows the chooser text and keeps the button', (t) async {
      final w = webWallet();
      final c = FakeChooser()..pickError = StateError('no file input');
      await pumpPanel(t, w.wc, c);
      await t.tap(restoreBtn);
      await t.pump();
      await t.pump();
      expect(find.text(chooserFailedMessage), findsOneWidget);
      expect(enabled(t, restoreBtn), isTrue);
    });

    for (final (label, error, text) in <(String, Object, String)>[
      (
        'a different wallet key',
        const VaultException('bad key', failure: UnsealFailure.badKey),
        "This backup doesn't open with this wallet's key. It was made with another key, or the file is damaged."
      ),
      (
        'another wallet key',
        const VaultException('other key', failure: UnsealFailure.otherKey),
        'This backup was made with another wallet key.'
      ),
      ('a damaged file, right key', const VaultException('damaged', failure: UnsealFailure.damaged), 'This backup file is damaged.'),
      ('an unreadable file', const BackupException(BackupFailure.unreadable, 'x'), "This backup file can't be read."),
      ('a damaged file', const BackupException(BackupFailure.damaged, 'x'), 'This backup file is damaged.'),
      ('a newer app version', const BackupException(BackupFailure.newerVersion, 'x'), 'Made by a newer app version. Update first.'),
      (
        'a clock ahead',
        const BackupException(BackupFailure.clockAhead, 'x'),
        "This backup has changes dated later than this device's clock. Check the date and time."
      ),
      ('a wallet that got data meanwhile', StateError('not empty'), 'The wallet is not empty, so nothing was restored.'),
      ('anything else', const FormatException('odd'), "Couldn't restore the backup."),
    ]) {
      webTest('restore with $label: the same texts as on the other platforms', (t) async {
        final w = webWallet();
        final c = FakeChooser()..picks = [FakePicked('a.bwb', Uint8List(2))];
        w.wc.seams.backupBytesReader = (repo, bytes, key) async => raise(error);
        await pumpPanel(t, w.wc, c);
        await t.tap(restoreBtn);
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('restoreConfirm')));
        await t.pumpAndSettle();
        expect(find.textContaining(text), findsOneWidget);
        expect(find.textContaining('Restored'), findsNothing);
        expect(enabled(t, restoreBtn), isTrue);
      });
    }

    webTest('fits 320 dp at text scale 2.0', (t) async {
      final w = webWallet();
      await pumpPanel(t, w.wc, FakeChooser(), size: const Size(320, 900), scale: 2);
      expect(t.takeException(), isNull);
      expect(backupBtn, findsOneWidget);
      expect(restoreBtn, findsOneWidget);
    });
  });

  group('WalletController on the web', () {
    test('backupDownload without a key is a StateError and logs the reason only', () async {
      final w = webWallet(withKey: false);
      await expectLater(w.wc.backupDownload(), throwsStateError);
      expect(lines.join('\n'), contains('backup.skip {"reason":"noKey"}'));
    });

    test('restoreBackupFile without a key is a BackupException; with one, a restore reloads the wallet', () async {
      final noKey = webWallet(withKey: false);
      await expectLater(noKey.wc.restoreBackupFile(Uint8List(1)), throwsA(isA<BackupException>()));
      final w = webWallet();
      final before = w.wc.dataVersion;
      w.wc.seams.backupBytesReader = (repo, bytes, key) async => 5;
      expect(await w.wc.restoreBackupFile(Uint8List(1)), 5);
      expect(w.wc.dataVersion, greaterThan(before));
    });

    test('createWallet and joinWallet hand the passphrase to the key store', () async {
      final w = webWallet(withKey: false);
      await w.wc.createWallet(passphrase: 'a long passphrase');
      expect(w.keyWrites, ['a long passphrase']);
      expect(w.wc.hasWallet, isTrue);
      final w2 = webWallet(withKey: false);
      final text = await VaultKey.generate().toText();
      await w2.wc.joinWallet(text, passphrase: 'another passphrase');
      expect(w2.keyWrites, ['another passphrase']);
      expect(w2.wc.hasWallet, isTrue);
    });

    test('unlock sets the key; a wrong passphrase leaves the wallet locked', () async {
      final w = webWallet(withKey: false, locked: true);
      final key = VaultKey.generate();
      w.wc.seams.unlocker = (p) async {
        if (p != 'right passphrase') throw const WrongPassphrase();
        return key;
      };
      await expectLater(w.wc.unlock('nope'), throwsA(isA<WrongPassphrase>()));
      expect(w.wc.locked, isTrue);
      expect(w.wc.hasWallet, isFalse);
      await w.wc.unlock('right passphrase');
      expect(w.wc.locked, isFalse);
      expect(w.wc.key, same(key));
      final log = lines.join('\n');
      expect(log, contains('wallet.unlock'));
      expect(log, isNot(contains('right passphrase')));
      expect(log, isNot(contains('nope')));
    });

    test('forgetBrowser deletes the database and the key, starts an empty wallet and logs only the event', () async {
      final w = webWallet(full: true);
      final oldRepo = w.wc.repo;
      expect(w.wc.txs, isNotEmpty);
      w.wc.sync.badFiles = 2;
      w.wc.sync.relayInstance = 'A1B2C3D4E5F60718';
      w.wc.sync.problems = const [SyncProblem('abcd1234', SyncProblemReason.deviceIdInUse, bytes: 0)];
      await w.wc.forgetBrowser();
      expect((w.wc.sync.badFiles, w.wc.sync.relayInstance), (0, null), reason: 'the old status is gone');
      expect(w.wc.sync.problems, isEmpty);
      expect(w.db.forgotten, isTrue);
      expect(w.keyForgets, 1);
      expect(w.wc.hasWallet, isFalse);
      expect(w.wc.locked, isFalse);
      expect(w.wc.repo, isNot(same(oldRepo)));
      expect(w.wc.txs, isEmpty);
      expect(w.wc.walletIsEmpty, isTrue);
      expect(w.wc.relayUrl, isNull);
      expect(lines.join('\n'), contains('wallet.forget'));
    });

    test('forgetBrowser with a database that cannot be deleted still clears the key and the state, then reports it', () async {
      final w = webWallet(full: true);
      w.db.forgetError = StateError('blocked by another tab');
      await expectLater(w.wc.forgetBrowser(), throwsStateError);
      expect(w.keyForgets, 1);
      expect(w.wc.hasWallet, isFalse);
      expect(w.wc.txs, isEmpty);
      expect(lines.join('\n'), contains('wallet.forget.dbFailed'));
    });
  });

  group('database flush', () {
    webTest('a change is written within a second; several changes in that time make one write', (t) async {
      final w = webWallet(full: true);
      await t.pump(const Duration(seconds: 2)); // the controller's own startup notification
      final base = w.db.persists;
      w.wc.addExpense(amount: 100, category: 'Groceries', note: '', date: w.wc.today());
      w.wc.addExpense(amount: 200, category: 'Groceries', note: '', date: w.wc.today());
      w.wc.setLogLevel('info');
      expect(w.db.persists, base, reason: 'not on every change');
      await t.pump(const Duration(seconds: 1));
      expect(w.db.persists, base + 1);
      await t.pump(const Duration(seconds: 5));
      expect(w.db.persists, base + 1, reason: 'nothing changed since');
    });

    webTest('persistNow writes at once and cancels the timer', (t) async {
      final w = webWallet(full: true);
      w.wc.addExpense(amount: 100, category: 'Groceries', note: '', date: w.wc.today());
      final base = w.db.persists;
      await w.wc.persistNow();
      expect(w.db.persists, base + 1);
      await t.pump(const Duration(seconds: 2));
      expect(w.db.persists, base + 1);
    });

    webTest('a failed flush is logged and does not break the app', (t) async {
      final w = webWallet(full: true);
      w.db.persistError = StateError('quota exceeded');
      w.wc.addExpense(amount: 100, category: 'Groceries', note: '', date: w.wc.today());
      await t.pump(const Duration(seconds: 1));
      expect(lines.join('\n'), contains('db.persistFailed'));
      w.db.persistError = null;
      final failed = w.db.persists;
      w.wc.addExpense(amount: 100, category: 'Groceries', note: '', date: w.wc.today());
      await t.pump(const Duration(seconds: 1));
      expect(w.db.persists, failed + 1, reason: 'the next change is flushed as usual');
    });

    testWidgets('a file database (nothing to flush) starts no timer', (t) async {
      final repo = WalletRepo.inMemory();
      final wc = seamedController(repo, key: VaultKey.generate(), db: WalletDb(repo));
      addTearDown(wc.dispose);
      wc.reload();
      // The test fails on its own if a timer is still pending when it ends.
      await wc.persistNow();
    });
  });

  group('Sync on the web', () {
    final relay = Uri.parse('http://127.0.0.1:8080');

    test('an expense added in one web wallet shows up in the other after syncNow (one MemoryTransport)', () async {
      final key = VaultKey.generate();
      final mem = MemoryTransport();
      Future<SyncReport> run(Uri r, VaultKey k, WalletRepo repo) => SyncEngine(mem, k).run(repo);
      final a = webWallet(key: key), b = webWallet(key: key);
      for (final w in [a, b]) {
        w.wc.seams.syncRunner = run;
        w.wc.relayUrl = relay;
      }
      a.wc.repo.addTransaction(date: a.wc.today(), amount: 4250, category: 'Groceries');
      a.wc.reload();
      await a.wc.syncNow();
      expect(a.wc.syncError, isNull);
      expect(b.wc.txs, isEmpty);
      await b.wc.syncNow();
      expect(b.wc.syncError, isNull);
      expect(b.wc.txs.map((t) => t.amount), [-4250]);
      expect(b.wc.syncDevices.length, 2);
      // And back: the second wallet's expense reaches the first.
      b.wc.repo.addTransaction(date: b.wc.today(), amount: 900, category: 'Transport');
      b.wc.reload();
      await b.wc.syncNow();
      await a.wc.syncNow();
      expect(a.wc.txs.map((t) => t.amount).toSet(), {-4250, -900});
      expect(lines.join('\n'), isNot(contains('127.0.0.1')), reason: 'the address is never logged');
    });

    test('a web wallet and a native-style wallet (not web) share one transport', () async {
      final key = VaultKey.generate();
      final mem = MemoryTransport();
      Future<SyncReport> run(Uri r, VaultKey k, WalletRepo repo) => SyncEngine(mem, k).run(repo);
      final web = webWallet(key: key);
      web.wc.seams.syncRunner = run;
      web.wc.relayUrl = relay;
      final other = seamedController(WalletRepo.inMemory(), key: key)
        ..seams.syncRunner = run
        ..relayUrl = relay;
      addTearDown(other.dispose);
      other.repo.addTransaction(date: other.today(), amount: 777, category: 'Groceries');
      other.reload();
      await other.syncNow();
      await web.wc.syncNow();
      expect(web.wc.syncError, isNull);
      expect(web.wc.txs.map((t) => t.amount), [-777]);
    });
  });

  group('Plan on the web', () {
    Future<void> pumpPlan(WidgetTester t, WalletController wc,
            {FakeChooser? chooser, Size size = const Size(400, 10500), double scale = 1}) =>
        pumpApp(t, Scaffold(body: PlanPage(wc: wc, chooser: chooser ?? FakeChooser())), size: size, textScale: scale);

    webTest('Sync (relay) is there, Nudges are not; Backup, Export, Diagnostics and This browser stay', (t) async {
      final w = webWallet(full: true);
      await pumpPlan(t, w.wc);
      expect(find.text('SYNC'), findsOneWidget);
      expect(find.byKey(const ValueKey('syncNow')), findsOneWidget);
      expect(find.byKey(const ValueKey('relayTest')), findsOneWidget);
      expect(find.text('NUDGES'), findsNothing);
      expect(find.text('Choose folder'), findsNothing);
      expect(find.text('BACKUP'), findsOneWidget);
      expect(find.text('EXPORT'), findsOneWidget);
      expect(find.text('DIAGNOSTICS'), findsOneWidget);
      expect(find.text('THIS BROWSER'), findsOneWidget);
      expect(find.byKey(const ValueKey('forgetBrowser')), findsOneWidget);
      expect(find.byKey(const ValueKey('showKey')), findsOneWidget, reason: 'the key is still needed for another device or a backup');
    });

    webTest('on the other platforms Sync and Nudges stay and there is no Forget row', (t) async {
      plat.debugIsWebOverride = false;
      final w = webWallet(full: true);
      await pumpPlan(t, w.wc);
      expect(find.text('SYNC'), findsOneWidget);
      expect(find.text('NUDGES'), findsOneWidget);
      expect(find.byKey(const ValueKey('forgetBrowser')), findsNothing);
      expect(find.text('THIS BROWSER'), findsNothing);
    });

    webTest('Forget this browser asks first; Cancel changes nothing', (t) async {
      final w = webWallet(full: true);
      await pumpPlan(t, w.wc);
      await t.tap(find.byKey(const ValueKey('forgetBrowser')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('forgetConfirm')), findsOneWidget);
      expect(w.db.forgotten, isFalse);
      await t.tap(find.byKey(const ValueKey('forgetCancel')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('forgetConfirm')), findsNothing);
      expect(w.db.forgotten, isFalse);
      expect(w.keyForgets, 0);
      expect(w.wc.hasWallet, isTrue);
    });

    webTest('confirming deletes the database and the key, closes the sheet and leaves no wallet', (t) async {
      final w = webWallet(full: true);
      await pumpPlan(t, w.wc);
      await t.tap(find.byKey(const ValueKey('forgetBrowser')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('forgetConfirm')));
      await t.pumpAndSettle();
      expect(w.db.forgotten, isTrue);
      expect(w.keyForgets, 1);
      expect(w.wc.hasWallet, isFalse);
      expect(find.byKey(const ValueKey('forgetConfirm')), findsNothing);
      expect(lines.join('\n'), contains('wallet.forget'));
      w.dispose(); // forgetting starts new timers
    });

    webTest('a failure shows one text in the sheet', (t) async {
      final w = webWallet(full: true);
      w.db.forgetError = StateError('blocked');
      await pumpPlan(t, w.wc);
      await t.tap(find.byKey(const ValueKey('forgetBrowser')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('forgetConfirm')));
      await t.pumpAndSettle();
      expect(find.textContaining("Couldn't clear everything"), findsOneWidget);
      expect(find.textContaining('blocked'), findsNothing);
      w.dispose();
    });

    webTest('fits 320 dp at text scale 2.0', (t) async {
      final w = webWallet(full: true);
      await pumpPlan(t, w.wc, size: const Size(320, 900), scale: 2);
      // The page's own vertical list: rows with sideways chips are Scrollables too and come and go while scrolling.
      final page = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
      await t.scrollUntilVisible(find.byKey(const ValueKey('forgetBrowser')), 500, scrollable: page, maxScrolls: 400);
      await t.pump();
      expect(t.takeException(), isNull); // an overflow would show up here
      expect(find.byKey(const ValueKey('forgetBrowser')), findsOneWidget);
    });
  });

  group('Diagnostics on the web', () {
    webTest('Save logs downloads the logs and says so', (t) async {
      final w = webWallet();
      final c = FakeChooser();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: DiagnosticsPanel(wc: w.wc, chooser: c))));
      await t.tap(find.byKey(const ValueKey('logsSave')));
      await t.pumpAndSettle();
      expect(c.texts.map((x) => x.name), [w.wc.logFileName()]);
      expect(find.text('Logs downloaded.'), findsOneWidget);
    });

    webTest('a failed download says so', (t) async {
      final w = webWallet();
      final c = FakeChooser()..saveError = StateError('no');
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: DiagnosticsPanel(wc: w.wc, chooser: c))));
      await t.tap(find.byKey(const ValueKey('logsSave')));
      await t.pumpAndSettle();
      expect(find.text("Couldn't download the logs."), findsOneWidget);
    });
  });

  group('Onboarding on the web', () {
    Future<void> pumpOnboarding(WidgetTester t, WalletController wc, {Size size = const Size(400, 900), double scale = 1}) =>
        pumpApp(t, OnboardingScreen(wc: wc), size: size, textScale: scale);

    Finder field(String key) => find.byKey(ValueKey(key));

    webTest('New wallet asks for a passphrase first; nothing is created yet', (t) async {
      final w = webWallet(withKey: false);
      await pumpOnboarding(t, w.wc);
      expect(find.textContaining('kept in this browser'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('startWallet')));
      await t.pump();
      expect(find.byKey(const ValueKey('passphraseHeading')), findsOneWidget);
      expect(find.textContaining('this browser only'), findsOneWidget);
      expect(field('passphrase'), findsOneWidget);
      expect(field('passphrase2'), findsOneWidget);
      expect(w.keyWrites, isEmpty);
      expect(w.wc.hasWallet, isFalse);
    });

    webTest('fewer than 8 characters and two different passphrases are refused with a text', (t) async {
      final w = webWallet(withKey: false);
      await pumpOnboarding(t, w.wc);
      expect(find.byKey(const ValueKey('startWallet')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('startWallet')));
      await t.pump();
      expect(find.byKey(const ValueKey('passphraseHeading')), findsOneWidget);
      await t.enterText(field('passphrase'), '1234567');
      await t.enterText(field('passphrase2'), '1234567');
      await t.tap(field('passphraseContinue'));
      await t.pump();
      expect(find.textContaining('The passphrase needs at least 8 characters.'), findsOneWidget);
      await t.enterText(field('passphrase'), '12345678');
      await t.enterText(field('passphrase2'), '12345679');
      await t.tap(field('passphraseContinue'));
      await t.pump();
      expect(find.textContaining("The two passphrases don't match."), findsOneWidget);
      expect(w.keyWrites, isEmpty);
      expect(w.wc.hasWallet, isFalse);
    });

    webTest('exactly 8 matching characters create the wallet and wrap the key with that passphrase; it is never logged', (t) async {
      final w = webWallet(withKey: false);
      await pumpOnboarding(t, w.wc);
      await t.tap(find.byKey(const ValueKey('startWallet')));
      await t.pump();
      await t.enterText(field('passphrase'), 'pass-1234');
      await t.enterText(field('passphrase2'), 'pass-1234');
      await t.tap(field('passphraseContinue'));
      await t.pumpAndSettle();
      expect(w.keyWrites, ['pass-1234']);
      expect(w.wc.hasWallet, isTrue);
      expect(lines.join('\n'), isNot(contains('pass-1234')));
    });

    webTest('the passphrase fields hide what is typed, and Back returns to the first choice', (t) async {
      final w = webWallet(withKey: false);
      await pumpOnboarding(t, w.wc);
      await t.tap(find.byKey(const ValueKey('startWallet')));
      await t.pump();
      for (final k in ['passphrase', 'passphrase2']) {
        expect(t.widget<TextField>(field(k)).obscureText, isTrue);
      }
      await t.tap(find.byKey(const ValueKey('passphraseBack')));
      await t.pump();
      expect(find.byKey(const ValueKey('startWallet')), findsOneWidget);
      expect(field('passphrase'), findsNothing);
    });

    webTest('a key that cannot be saved shows a short text and lets the owner try again', (t) async {
      final w = webWallet(withKey: false);
      w.wc.seams.keyWriter = (key, {passphrase}) async => throw StateError('storage is full');
      await pumpOnboarding(t, w.wc);
      await t.tap(find.byKey(const ValueKey('startWallet')));
      await t.pump();
      await t.enterText(field('passphrase'), 'pass-1234');
      await t.enterText(field('passphrase2'), 'pass-1234');
      await t.tap(field('passphraseContinue'));
      await t.pumpAndSettle();
      expect(find.textContaining("Couldn't save the wallet key in this browser."), findsOneWidget);
      expect(find.textContaining('storage is full'), findsNothing);
      expect(w.wc.hasWallet, isFalse);
    });

    webTest('Use my wallet key: a typo shows at once, a good key goes on to the passphrase and is wrapped with it', (t) async {
      final w = webWallet(withKey: false);
      await pumpOnboarding(t, w.wc);
      await t.tap(find.byKey(const ValueKey('joinStart')));
      await t.pump();
      await t.enterText(find.widgetWithText(TextField, 'Wallet key'), 'not a key');
      await t.tap(find.byKey(const ValueKey('joinWallet')));
      await t.pump();
      expect(find.textContaining('This is not a Budget Wallet key (it should start with BW1).'), findsOneWidget);
      expect(field('passphrase'), findsNothing);
      final text = await VaultKey.generate().toText();
      await t.enterText(find.widgetWithText(TextField, 'Wallet key'), text);
      await t.tap(find.byKey(const ValueKey('joinWallet')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('passphraseHeading')), findsOneWidget);
      await t.enterText(field('passphrase'), 'my passphrase');
      await t.enterText(field('passphrase2'), 'my passphrase');
      await t.tap(field('passphraseContinue'));
      await t.pumpAndSettle();
      expect(w.keyWrites, ['my passphrase']);
      expect(w.wc.hasWallet, isTrue);
      final log = lines.join('\n');
      expect(log, isNot(contains(text)));
      expect(log, isNot(contains('my passphrase')));
    });

    webTest('on the other platforms there is no passphrase step', (t) async {
      plat.debugIsWebOverride = false;
      final w = webWallet(withKey: false);
      await pumpOnboarding(t, w.wc);
      await t.tap(find.byKey(const ValueKey('startWallet')));
      await t.pumpAndSettle();
      expect(field('passphrase'), findsNothing);
      expect(w.keyWrites, [null]);
      expect(w.wc.hasWallet, isTrue);
    });

    webTest('fits 320 dp at text scale 2.0, first screen and passphrase step', (t) async {
      final w = webWallet(withKey: false);
      await pumpOnboarding(t, w.wc, size: const Size(320, 2000), scale: 2); // tall: the width is what is tested
      expect(find.byKey(const ValueKey('startWallet')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('startWallet')));
      await t.pump();
      expect(find.text('Choose a passphrase'), findsOneWidget, reason: 'the heading is built; the fields are further down the lazy list');
      // The text is so tall at 2.0 that the fields are below the built part of the lazy list: scroll to them, as a user does.
      final list = find.byType(Scrollable).first;
      await t.scrollUntilVisible(field('passphrase'), 200, scrollable: list);
      await t.enterText(field('passphrase'), '1234567');
      await t.scrollUntilVisible(field('passphraseContinue'), 200, scrollable: list);
      await t.tap(field('passphraseContinue'));
      await t.pump();
      expect(t.takeException(), isNull); // an overflow would show up here
    });
  });

  group('Unlock screen', () {
    Future<void> pumpUnlock(WidgetTester t, WalletController wc, {Size size = const Size(400, 900), double scale = 1}) =>
        pumpApp(t, UnlockScreen(wc: wc), size: size, textScale: scale);

    webTest('asks for the passphrase and hides it', (t) async {
      final w = webWallet(withKey: false, locked: true);
      await pumpUnlock(t, w.wc);
      expect(find.textContaining('locked'), findsOneWidget);
      expect(t.widget<TextField>(pass).obscureText, isTrue);
      expect(find.byKey(const ValueKey('unlockButton')), findsOneWidget);
      expect(find.byKey(const ValueKey('unlockForget')), findsOneWidget);
    });

    webTest('a wrong passphrase shows an error, keeps the screen and allows another try', (t) async {
      final w = webWallet(withKey: false, locked: true);
      final tried = <String>[];
      final key = VaultKey.generate();
      w.wc.seams.unlocker = (p) async {
        tried.add(p);
        if (p != 'right-one') throw const WrongPassphrase();
        return key;
      };
      await pumpUnlock(t, w.wc);
      await t.enterText(pass, 'wrong-one');
      await t.tap(find.byKey(const ValueKey('unlockButton')));
      await t.pumpAndSettle();
      expect(find.textContaining('Wrong passphrase. Try again.'), findsOneWidget);
      expect(w.wc.locked, isTrue);
      expect(w.wc.hasWallet, isFalse);
      expect(enabled(t, find.byKey(const ValueKey('unlockButton'))), isTrue);
      await t.enterText(pass, 'right-one');
      await t.tap(find.byKey(const ValueKey('unlockButton')));
      await t.pumpAndSettle();
      expect(tried, ['wrong-one', 'right-one']);
      expect(w.wc.locked, isFalse);
      expect(w.wc.key, same(key));
      final log = lines.join('\n');
      expect(log, isNot(contains('wrong-one')));
      expect(log, isNot(contains('right-one')));
    });

    webTest('an unexpected failure shows a short text without its message', (t) async {
      final w = webWallet(withKey: false, locked: true);
      w.wc.seams.unlocker = (p) async => throw const FormatException('stored blob is damaged: secret detail');
      await pumpUnlock(t, w.wc);
      await t.enterText(pass, 'whatever-123');
      await t.tap(find.byKey(const ValueKey('unlockButton')));
      await t.pumpAndSettle();
      expect(find.textContaining("Couldn't open the wallet key stored in this browser."), findsOneWidget);
      expect(find.textContaining('secret detail'), findsNothing);
      expect(lines.join('\n'), contains('unlock.failed'));
    });

    webTest('Forget this browser from here deletes everything and the app shows the first screen', (t) async {
      final w = webWallet(withKey: false, locked: true);
      await pumpFull(t, w.wc, 1, size: const Size(400, 900));
      expect(find.byType(UnlockScreen), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('unlockForget')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('forgetConfirm')));
      await t.pumpAndSettle();
      expect(w.db.forgotten, isTrue);
      expect(w.keyForgets, 1);
      expect(find.byType(UnlockScreen), findsNothing);
      expect(find.byType(OnboardingScreen), findsOneWidget);
      w.dispose();
    });

    webTest('the app shows Unlock while locked and the wallet after the right passphrase', (t) async {
      final w = webWallet(withKey: false, locked: true);
      w.wc.seams.unlocker = (p) async => VaultKey.generate();
      await pumpFull(t, w.wc, 1, size: const Size(400, 900));
      expect(find.byType(UnlockScreen), findsOneWidget);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(HomeShell), findsNothing);
      await t.enterText(pass, 'right-one');
      await t.tap(find.byKey(const ValueKey('unlockButton')));
      await t.pumpAndSettle();
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(UnlockScreen), findsNothing);
    });

    webTest('an unlocked or key-less app never shows Unlock', (t) async {
      final w = webWallet(withKey: false);
      await pumpFull(t, w.wc, 1, size: const Size(400, 900));
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(UnlockScreen), findsNothing);
    });

    webTest('fits 320 dp at text scale 2.0 with an error showing', (t) async {
      final w = webWallet(withKey: false, locked: true);
      w.wc.seams.unlocker = (p) async => throw const WrongPassphrase();
      await pumpUnlock(t, w.wc, size: const Size(320, 1600), scale: 2);
      await t.enterText(pass, 'abcdefgh');
      await t.tap(find.byKey(const ValueKey('unlockButton')));
      await t.pumpAndSettle();
      expect(find.textContaining('Wrong passphrase. Try again.'), findsOneWidget);
      expect(t.takeException(), isNull); // an overflow would show up here
    });
  });

  group('Wallet open in another tab', () {
    Future<WalletController> loadInUse() => WalletController.load(claim: () async => throw const WalletInUse());

    webTest('load keeps the tab out: flag set, no wallet, nothing opened or flushed', (t) async {
      final wc = await loadInUse();
      expect(wc.inUseElsewhere, isTrue);
      expect(wc.hasWallet, isFalse);
      expect(wc.locked, isFalse);
      expect(wc.txs, isEmpty);
      expect(wc.repo.pendingOps(), isEmpty); // the placeholder repo has no writes
      await wc.persistNow(); // no database to flush
      expect(lines.join('\n'), contains('inUse'));
    });

    webTest('another failure from the opener is not swallowed', (t) async {
      await expectLater(WalletController.load(claim: () async => throw StateError('disk')), throwsStateError);
    });

    webTest('the app shows the InUse screen instead of onboarding or unlock', (t) async {
      final wc = await loadInUse();
      await t.pumpWidget(BudgetWalletApp(wc: wc));
      await t.pump();
      expect(find.byType(InUseScreen), findsOneWidget);
      expect(find.textContaining('open in another tab'), findsOneWidget);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(UnlockScreen), findsNothing);
    });

    webTest('Reload calls the injected callback', (t) async {
      var reloads = 0;
      await pumpApp(t, InUseScreen(onReload: () => reloads++));
      await t.tap(find.byKey(const ValueKey('inUseReload')));
      expect(reloads, 1);
    });

    webTest('fits 320 dp at text scale 2', (t) async {
      await pumpApp(t, InUseScreen(onReload: () {}), size: const Size(320, 1600), textScale: 2);
      expect(find.byKey(const ValueKey('inUseReload')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
