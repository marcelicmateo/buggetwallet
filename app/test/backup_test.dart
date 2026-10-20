// Plan › Backup: panel states, the button without a sync folder, restore only into an empty wallet, errors, the log.
// The core's backup functions are replaced by fakes (their round trip is tested in wallet_core). All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/core_shim.dart'; // TEMPORARY: BackupInfo and BackupException come from wallet_core after the merge
import 'package:budget_wallet/src/screens/backup_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

const _folder = '/home/someone/private-sync';

/// Stands in for an I/O error whose text names a path; the log must keep only the type.
class DiskTrouble implements Exception {
  @override
  String toString() => 'DiskTrouble: cannot write /home/someone/x';
}

BackupInfo _info(String date) => BackupInfo('bw-backup-$date.bwb', date);

/// A wallet with a sync folder and the given backups "found" in it. [full]: it holds data (restore must not show).
WalletController wallet({bool full = false, bool folder = true, List<BackupInfo> found = const []}) {
  final wc = full ? habitsWallet() : emptyWallet();
  addTearDown(wc.dispose);
  if (folder) wc.syncFolder = _folder;
  wc.syncRunner = (f, k, r) async => const SyncReport(0, 0, 0);
  wc.backupLister = (f) async => found;
  return wc;
}

Future<void> pumpPanel(WidgetTester t, WalletController wc, {Size size = const Size(400, 900), double scale = 1}) async {
  await pumpApp(t, Scaffold(body: SingleChildScrollView(child: BackupPanel(wc: wc))), size: size, textScale: scale);
  await t.pump(); // the list of backups
}

Finder get backupBtn => find.byKey(const ValueKey('backupNow'));
Finder get restoreBtn => find.byKey(const ValueKey('restoreBackup'));
bool enabled(WidgetTester t, Finder f) => t.widget<ButtonStyleButton>(f).onPressed != null;

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  testWidgets('no sync folder: the button is off and says why', (t) async {
    final wc = wallet(full: true, folder: false);
    await pumpPanel(t, wc);
    expect(find.text('BACKUP'), findsOneWidget);
    expect(find.text('No backup yet'), findsOneWidget);
    expect(find.text('Set the sync folder first'), findsOneWidget);
    expect(enabled(t, backupBtn), isFalse);
  });

  testWidgets('with a folder and no backup: "No backup yet", button on', (t) async {
    final wc = wallet(full: true);
    await pumpPanel(t, wc);
    expect(find.text('No backup yet'), findsOneWidget);
    expect(find.text('Set the sync folder first'), findsNothing);
    expect(enabled(t, backupBtn), isTrue);
  });

  testWidgets('shows the date of the newest backup', (t) async {
    final wc = wallet(full: true, found: [_info('2026-10-20'), _info('2026-10-02')]);
    await pumpPanel(t, wc);
    expect(find.text('Last backup: 20 Oct'), findsOneWidget);
    expect(find.text('No backup yet'), findsNothing);
  });

  testWidgets('Back up now writes into the sync folder, toasts, refreshes the date and logs no path or file name', (t) async {
    final wc = wallet(full: true);
    final calls = <String>[];
    wc.backupWriter = (repo, folder, key, {required today}) async {
      calls.add('$folder|$today');
      return 'bw-backup-$today.bwb';
    };
    await pumpPanel(t, wc);
    wc.backupLister = (f) async => [_info('2026-10-20')];
    await t.tap(backupBtn);
    await t.pump();
    await t.pump();
    expect(calls, ['$_folder|${wc.today()}']);
    expect(find.text('Backup saved to the sync folder'), findsOneWidget);
    expect(find.text('Last backup: 20 Oct'), findsOneWidget);
    final log = lines.join('\n');
    expect(log, contains('backup.done'));
    expect(log, isNot(contains('private-sync')));
    expect(log, isNot(contains('bw-backup-')));
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('a failing write shows a message, keeps the button usable and logs the error', (t) async {
    final wc = wallet(full: true);
    wc.backupWriter = (repo, folder, key, {required today}) async => throw DiskTrouble();
    await pumpPanel(t, wc);
    await t.tap(backupBtn);
    await t.pump();
    await t.pump();
    expect(find.textContaining("Couldn't save the backup"), findsOneWidget);
    expect(find.text('Backup saved to the sync folder'), findsNothing);
    expect(enabled(t, backupBtn), isTrue);
    expect(lines.any((l) => l.contains('backup.failed')), isTrue);
    expect(lines.join('\n'), isNot(contains('someone')));
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('Restore from backup… is hidden while the wallet has data and shown on an empty one', (t) async {
    final full = wallet(full: true, found: [_info('2026-10-20')]);
    await pumpPanel(t, full);
    expect(restoreBtn, findsNothing);
    expect(find.text('Restore from backup…'), findsNothing);

    final empty = wallet(found: [_info('2026-10-20')]);
    await pumpPanel(t, empty);
    expect(restoreBtn, findsOneWidget);
    expect(enabled(t, restoreBtn), isTrue);
  });

  testWidgets('an empty wallet with no backups found: Restore is off and says so', (t) async {
    final wc = wallet();
    await pumpPanel(t, wc);
    expect(enabled(t, restoreBtn), isFalse);
    expect(find.textContaining('No backups found in the sync folder.'), findsOneWidget);
  });

  testWidgets('restore: pick a backup, confirm, rows are restored and counted in the toast', (t) async {
    final wc = wallet(found: [_info('2026-10-20'), _info('2026-10-02')]);
    final files = <String>[];
    wc.backupReader = (repo, file, key) async {
      files.add(file);
      return 12;
    };
    await pumpPanel(t, wc);
    await t.tap(restoreBtn);
    await t.pumpAndSettle();
    expect(find.text('20 Oct · bw-backup-2026-10-20.bwb'), findsOneWidget);
    expect(find.text('2 Oct · bw-backup-2026-10-02.bwb'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('backup:bw-backup-2026-10-02.bwb')));
    await t.pumpAndSettle();
    expect(find.text('This replaces nothing; the wallet is empty.'), findsOneWidget);
    expect(files, isEmpty, reason: 'nothing is read before the owner confirms');
    await t.tap(find.byKey(const ValueKey('restoreConfirm')));
    await t.pump();
    await t.pump();
    expect(files, hasLength(1));
    expect(files.single, startsWith(_folder));
    expect(files.single, endsWith('bw-backup-2026-10-02.bwb'));
    expect(find.text('Restored 12 rows'), findsOneWidget);
    final log = lines.join('\n');
    expect(log, contains('backup.restored'));
    expect(log, contains('"rows":12'));
    expect(log, isNot(contains('private-sync')));
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('cancelling the confirm restores nothing', (t) async {
    final wc = wallet(found: [_info('2026-10-20')]);
    var reads = 0;
    wc.backupReader = (repo, file, key) async => ++reads;
    await pumpPanel(t, wc);
    await t.tap(restoreBtn);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('backup:bw-backup-2026-10-20.bwb')));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(reads, 0);
    expect(find.textContaining('Restored'), findsNothing);
  });

  for (final (name, error, message) in <(String, Object, String)>[
    ('wrong key', const VaultException('wrong key'), 'This backup was made with a different wallet key.'),
    ('bad file', const BackupException('damaged'), "This backup file can't be read."),
    ('not empty any more', StateError('not empty'), 'The wallet is not empty, so nothing was restored.'),
    ('anything else', const FormatException('boom'), "Couldn't restore the backup."),
  ]) {
    testWidgets('restore error ($name) shows a short message and no toast', (t) async {
      final wc = wallet(found: [_info('2026-10-20')]);
      wc.backupReader = (repo, file, key) => Future<int>.error(error);
      await pumpPanel(t, wc);
      await t.tap(restoreBtn);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('backup:bw-backup-2026-10-20.bwb')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('restoreConfirm')));
      await t.pump();
      await t.pump();
      expect(find.textContaining(message), findsOneWidget);
      expect(find.textContaining('Restored'), findsNothing);
      expect(enabled(t, restoreBtn), isTrue);
      await t.pump(const Duration(seconds: 4));
    });
  }

  test('the controller refuses a backup name that is a path', () async {
    final wc = wallet(found: [_info('2026-10-20')]);
    expect(() => wc.restoreBackup('../x.bwb'), throwsArgumentError);
    expect(() => wc.restoreBackup(r'..\x.bwb'), throwsArgumentError);
  });

  test('without a sync folder the controller has no backups and backupNow throws', () async {
    final wc = wallet(folder: false);
    expect(await wc.listBackups(), isEmpty);
    await expectLater(wc.backupNow(), throwsStateError);
  });

  for (final (w, h, scale) in [(320.0, 640.0, 2.0), (360.0, 800.0, 1.0), (1280.0, 800.0, 1.0)]) {
    testWidgets('layout at ${w.toInt()} dp, text ${scale}x: no overflow, both buttons reachable', (t) async {
      final wc = wallet(found: [_info('2026-10-20')]);
      final errors = Errors();
      await pumpPanel(t, wc, size: Size(w, h), scale: scale);
      await t.ensureVisible(restoreBtn);
      expect(find.text('Last backup: 20 Oct'), findsOneWidget);
      scanFlex(t);
      errors.check();
    });
  }
}
