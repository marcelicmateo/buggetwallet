// Plan › Backup on a computer or phone (not the browser): "Back up now" saves through the system save dialog, "Restore from backup…"
// picks a file, only into an empty wallet; errors, the log. The core's backup functions are replaced by fakes (their round
// trip is tested in wallet_core). All data is SYNTHETIC.
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/backup_panel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

/// Stands in for an I/O error whose text names a path; the log must keep only the type.
class DiskTrouble implements Exception {
  @override
  String toString() => 'DiskTrouble: cannot write /home/someone/x';
}

base class _Picked extends PlatformFile {
  @override
  final String name = 'picked.bwb';
  final Uint8List data;
  _Picked(this.data);
  @override
  Uri get uri => Uri(path: name);
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => data.length;
  @override
  Future<int?> length() async => data.length;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(data);
}

class FakeChooser extends FileChooser {
  final saved = <({String name, Uint8List bytes})>[];
  List<PlatformFile> picks = [];
  Object? saveError;
  bool cancelSave = false;
  FakeChooser();
  @override
  Future<Uri?> saveBackup({required String fileName, required Uint8List bytes, required String title}) async {
    if (saveError != null) Error.throwWithStackTrace(saveError!, StackTrace.current);
    if (cancelSave) return null;
    saved.add((name: fileName, bytes: bytes));
    return Uri(path: fileName);
  }

  @override
  Future<List<PlatformFile>> pickBackupFile() async => picks;
}

/// [full]: the wallet holds data (restore must not show).
WalletController wallet({bool full = false}) {
  final wc = full ? habitsWallet() : emptyWallet();
  addTearDown(wc.dispose);
  wc.syncRunner = (u, k, r) async => const SyncReport(0, 0, 0);
  return wc;
}

Future<void> pumpPanel(WidgetTester t, WalletController wc, FakeChooser c, {Size size = const Size(400, 900), double scale = 1}) async {
  await pumpApp(t, Scaffold(body: SingleChildScrollView(child: BackupPanel(wc: wc, chooser: c))), size: size, textScale: scale);
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

  testWidgets('no sync folder text any more: the button is on without a relay and the text names a file', (t) async {
    final wc = wallet(full: true);
    expect(wc.relayUrl, isNull);
    await pumpPanel(t, wc, FakeChooser());
    expect(find.text('BACKUP'), findsOneWidget);
    expect(enabled(t, backupBtn), isTrue);
    expect(find.textContaining('folder'), findsNothing);
    expect(find.textContaining('as a file'), findsOneWidget);
  });

  testWidgets('Back up now saves the dated file through the save dialog, toasts the name and logs no name or key', (t) async {
    final wc = wallet(full: true);
    final c = FakeChooser();
    final sealed = Uint8List.fromList([1, 2, 3, 4]);
    wc.backupBytesWriter = (repo, key) async => sealed;
    await pumpPanel(t, wc, c);
    await t.tap(backupBtn);
    await t.pump();
    await t.pump();
    final name = 'bw-backup-${wc.today()}.bwb';
    expect(c.saved.map((b) => b.name), [name]);
    expect(c.saved.single.bytes, sealed);
    expect(find.text('Saved $name'), findsOneWidget);
    final log = lines.join('\n');
    expect(log, contains('backup.done'));
    expect(log, isNot(contains(name)));
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('cancelling the save dialog shows neither a toast nor an error', (t) async {
    final wc = wallet(full: true);
    wc.backupBytesWriter = (repo, key) async => Uint8List(3);
    await pumpPanel(t, wc, FakeChooser()..cancelSave = true);
    await t.tap(backupBtn);
    await t.pump();
    await t.pump();
    expect(find.textContaining('Saved'), findsNothing);
    expect(find.textContaining("Couldn't"), findsNothing);
    expect(enabled(t, backupBtn), isTrue);
  });

  testWidgets('a failing save shows a message, keeps the button usable and logs the type only', (t) async {
    final wc = wallet(full: true);
    wc.backupBytesWriter = (repo, key) async => Uint8List(3);
    await pumpPanel(t, wc, FakeChooser()..saveError = DiskTrouble());
    await t.tap(backupBtn);
    await t.pump();
    await t.pump();
    expect(find.textContaining("Couldn't save the backup."), findsOneWidget);
    expect(enabled(t, backupBtn), isTrue);
    expect(lines.any((l) => l.contains('backup.saveFailed') && l.contains('"type":"DiskTrouble"')), isTrue);
    expect(lines.join('\n'), isNot(contains('someone')));
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('Restore from backup… is hidden while the wallet has data and shown on an empty one', (t) async {
    await pumpPanel(t, wallet(full: true), FakeChooser());
    expect(restoreBtn, findsNothing);
    await pumpPanel(t, wallet(), FakeChooser());
    expect(restoreBtn, findsOneWidget);
    expect(enabled(t, restoreBtn), isTrue);
  });

  testWidgets('restore: pick a file, confirm, its bytes go through the core and the toast counts the rows', (t) async {
    final wc = wallet();
    final bytes = Uint8List.fromList([9, 8, 7]);
    final c = FakeChooser()..picks = [_Picked(bytes)];
    final reads = <Uint8List>[];
    wc.backupBytesReader = (repo, b, key) async {
      reads.add(b);
      return 12;
    };
    await pumpPanel(t, wc, c);
    await t.tap(restoreBtn);
    await t.pumpAndSettle();
    expect(find.text('This replaces nothing; the wallet is empty.'), findsOneWidget);
    expect(reads, isEmpty, reason: 'nothing is read before the owner confirms');
    await t.tap(find.byKey(const ValueKey('restoreConfirm')));
    await t.pump();
    await t.pump();
    expect(reads, [bytes]);
    expect(find.text('Restored 12 rows'), findsOneWidget);
    final log = lines.join('\n');
    expect(log, contains('backup.restored'));
    expect(log, contains('"rows":12'));
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('cancelling the picker or the confirm restores nothing', (t) async {
    final wc = wallet();
    var reads = 0;
    wc.backupBytesReader = (repo, b, key) async => ++reads;
    final c = FakeChooser();
    await pumpPanel(t, wc, c);
    await t.tap(restoreBtn); // picker cancelled: an empty list
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('restoreConfirm')), findsNothing);
    c.picks = [_Picked(Uint8List(2))];
    await t.tap(restoreBtn);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('restoreCancel')));
    await t.pumpAndSettle();
    expect(reads, 0);
    expect(find.textContaining('Restored'), findsNothing);
  });

  for (final (name, error, message) in <(String, Object, String)>[
    ('wrong key', const VaultException('wrong key'), 'This backup was made with a different wallet key.'),
    ('unreadable file', const BackupException(BackupFailure.unreadable, 'x'), "This backup file can't be read."),
    ('damaged file', const BackupException(BackupFailure.damaged, 'x'), 'This backup file is damaged.'),
    ('newer version', const BackupException(BackupFailure.newerVersion, 'x'), 'Made by a newer app version. Update first.'),
    (
      'clock ahead',
      const BackupException(BackupFailure.clockAhead, 'x'),
      "This backup has changes dated later than this device's clock. Check the date and time."
    ),
    ('not empty any more', StateError('not empty'), 'The wallet is not empty, so nothing was restored.'),
    ('anything else', const FormatException('boom'), "Couldn't restore the backup."),
  ]) {
    testWidgets('restore error ($name) shows a short message and no toast', (t) async {
      final wc = wallet();
      wc.backupBytesReader = (repo, b, key) => Future<int>.error(error);
      await pumpPanel(t, wc, FakeChooser()..picks = [_Picked(Uint8List(2))]);
      await t.tap(restoreBtn);
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

  for (final (w, h, scale) in [(320.0, 640.0, 2.0), (360.0, 800.0, 1.0), (1280.0, 800.0, 1.0)]) {
    testWidgets('layout at ${w.toInt()} dp, text ${scale}x: no overflow, both buttons reachable', (t) async {
      final errors = Errors();
      await pumpPanel(t, wallet(), FakeChooser(), size: Size(w, h), scale: scale);
      await t.ensureVisible(restoreBtn);
      scanFlex(t);
      errors.check();
    });
  }
}
