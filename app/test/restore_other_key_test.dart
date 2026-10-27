// Plan › Backup › "Restore a backup made with another key…" (HU 12): a real backup sealed with key A restores into an empty wallet
// with key B once the old key A is given (typed or scanned); a wrong key shows the vault error; the old key is used once and
// never stored or logged. Real core backup functions, SYNTHETIC data.

import 'package:budget_wallet/src/bill_inputs.dart' show CodeKind, ScannedCode;
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/backup_panel.dart';
import 'package:budget_wallet/src/secure_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/bills.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

base class _Picked extends PlatformFile {
  @override
  final String name = 'old.bwb';
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

class _Chooser extends FileChooser {
  List<PlatformFile> picks = [];
  int picked = 0;
  @override
  Future<List<PlatformFile>> pickBackupFile() async {
    picked++;
    return picks;
  }
}

Finder get _other => find.byKey(const ValueKey('restoreOtherKey'));
Finder get _field => find.byKey(const ValueKey('oldKeyField'));
Finder get _go => find.byKey(const ValueKey('oldKeyRestore'));

/// A backup of a small wallet sealed with [key] (synthetic rows).
Future<Uint8List> _backupWith(VaultKey key) async {
  final a = WalletRepo.inMemory();
  a.addTransaction(date: '2026-10-01', amount: -1250, category: 'Groceries');
  a.addTransaction(date: '2026-10-02', amount: -4000, category: 'Transport');
  a.saveGoal(name: 'Synthetic goal', target: 100000, saved: 0, monthly: 1000, sort: 1);
  return backupBytes(a, key);
}

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });
  String log() => lines.join('\n');

  Future<WalletController> pump(WidgetTester t, _Chooser c,
      {VaultKey? walletKey, Size size = const Size(400, 900), double scale = 1, FakeBillInputs? inputs}) async {
    final wc = seamedController(WalletRepo.inMemory(),
        key: walletKey ?? VaultKey.generate(), billInputs: (inputs ?? FakeBillInputs(camera: FakeCamera(canShow: false))).inputs);
    addTearDown(wc.dispose);
    wc.seams.syncRunner = (u, k, r) async => const SyncReport(0, 0, 0);
    await pumpApp(t, Scaffold(body: SingleChildScrollView(child: BackupPanel(wc: wc, chooser: c))), size: size, textScale: scale);
    return wc;
  }

  testWidgets('a backup sealed with key A restores into a wallet with key B when A is typed', (t) async {
    final keyA = VaultKey.generate(), keyB = VaultKey.generate();
    final c = _Chooser()..picks = [_Picked(await _backupWith(keyA))];
    final wc = await pump(t, c, walletKey: keyB);
    expect(await keyA.toText(), isNot(await keyB.toText()));

    // The normal restore refuses it: it was made with another key.
    await t.tap(find.byKey(const ValueKey('restoreBackup')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('restoreConfirm')));
    await t.pump();
    await t.pump();
    expect(find.textContaining("doesn't open with this wallet's key", findRichText: true), findsOneWidget);
    expect(wc.walletIsEmpty, isTrue);

    await t.tap(_other);
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('oldKeyDialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('oldKeyScan')), findsNothing, reason: 'no camera here');
    final textA = await keyA.toText();
    await t.enterText(_field, '  $textA  ');
    await t.tap(_go);
    await t.pump();
    await t.pump();
    await t.pump();
    expect(find.text('Restored 3 rows'), findsOneWidget, reason: 'two rows and a goal');
    expect(wc.walletIsEmpty, isFalse);
    expect(wc.txs.map((x) => x.amount.abs()).toSet(), {1250, 4000});
    expect(wc.goals.single.name, 'Synthetic goal');
    expect(wc.key!.bytes, keyB.bytes, reason: 'the wallet keeps its own key');
    expect(find.textContaining("doesn't open this backup (or the file is damaged)", findRichText: true), findsNothing);

    // The old key was used once: not stored, not logged, not in the wallet's device-local values.
    final plain = textA.replaceAll('-', '');
    expect(log(), isNot(contains(textA)));
    expect(log(), isNot(contains(plain.substring(3, 20))));
    expect(log(), contains('"otherKey":true'));
    expect(log(), contains('backup.restored'));
    expect(wc.repo.db.select('SELECT key, value FROM meta').map((r) => '${r['value']}').join('|'), isNot(contains(plain.substring(3, 20))));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('a wrong old key shows the vault error and restores nothing; the dialog can be tried again', (t) async {
    final keyA = VaultKey.generate();
    final c = _Chooser()..picks = [_Picked(await _backupWith(keyA))];
    final wc = await pump(t, c);
    final wrong = await VaultKey.generate().toText();

    await t.tap(_other);
    await t.pump();
    await t.pump();
    await t.enterText(_field, wrong);
    await t.tap(_go);
    await t.pump();
    await t.pump();
    expect(find.textContaining("doesn't open this backup (or the file is damaged)", findRichText: true), findsOneWidget);
    expect(wc.walletIsEmpty, isTrue);
    expect(log(), isNot(contains(wrong)));
    expect(log(), contains('backup.restoreFailed'));

    // not a key at all: the key error's own text
    await t.tap(_other);
    await t.pump();
    await t.pump();
    await t.enterText(_field, 'hello');
    await t.tap(_go);
    await t.pump();
    await t.pump();
    expect(find.textContaining('This is not a Budget Wallet key (it should start with BW1).', findRichText: true), findsOneWidget);
    expect(wc.walletIsEmpty, isTrue);

    // and the right one still works afterwards
    await t.tap(_other);
    await t.pump();
    await t.pump();
    await t.enterText(_field, await keyA.toText());
    await t.tap(_go);
    await t.pump();
    await t.pump();
    await t.pump();
    expect(wc.walletIsEmpty, isFalse);
    expect(find.textContaining("doesn't open"), findsNothing);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('Cancel (or no file) restores nothing and asks nothing more; the button only shows while the wallet is empty', (t) async {
    final c = _Chooser()..picks = [_Picked(await _backupWith(VaultKey.generate()))];
    final wc = await pump(t, c);
    await t.tap(_other);
    await t.pump();
    await t.pump();
    await t.tap(find.byKey(const ValueKey('oldKeyCancel')));
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('oldKeyDialog')), findsNothing);
    expect(wc.walletIsEmpty, isTrue);

    c.picks = [];
    await t.tap(_other);
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('oldKeyDialog')), findsNothing, reason: 'no file picked, no question');

    wc.repo.addTransaction(date: '2026-10-03', amount: -100, category: 'Groceries');
    wc.reload();
    await pumpApp(t, Scaffold(body: SingleChildScrollView(child: BackupPanel(wc: wc, chooser: c))));
    expect(_other, findsNothing);
    expect(find.byKey(const ValueKey('restoreBackup')), findsNothing);
  });

  testWidgets('with a camera the dialog offers "Scan its QR code" and fills the field from the code', (t) async {
    final keyA = VaultKey.generate();
    final inputs = FakeBillInputs();
    final c = _Chooser()..picks = [_Picked(await _backupWith(keyA))];
    final wc = await pump(t, c, inputs: inputs);
    await t.tap(_other);
    await t.pump();
    await t.pump();
    await t.tap(find.byKey(const ValueKey('oldKeyScan')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    final text = await keyA.toText();
    inputs.camera.emit(ScannedCode(CodeKind.qr, text));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(t.widget<TextField>(_field).controller!.text, text);
    await t.tap(_go);
    await t.pump();
    await t.pump();
    await t.pump();
    expect(wc.walletIsEmpty, isFalse);
    expect(log(), isNot(contains(text)));
    await t.pump(const Duration(seconds: 5));
  });

  for (final (name, size, scale) in [('320 dp at 2.0', const Size(320, 700), 2.0), ('wide', const Size(1280, 800), 1.0)]) {
    testWidgets('the button and the dialog fit $name', (t) async {
      final c = _Chooser()..picks = [_Picked(await _backupWith(VaultKey.generate()))];
      await pump(t, c, size: size, scale: scale, inputs: FakeBillInputs());
      expect(_other, findsOneWidget);
      expect(t.takeException(), isNull);
      await t.ensureVisible(_other);
      await t.pump();
      await t.tap(_other);
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('oldKeyDialog')), findsOneWidget);
      expect(t.takeException(), isNull);
      expect(_go, findsOneWidget);
    });
  }

  testWidgets('the scanner ignores a QR that is not a key and a second code in the same frame; only the first key closes it', (t) async {
    final keyA = VaultKey.generate(), keyOther = VaultKey.generate();
    final inputs = FakeBillInputs();
    final c = _Chooser()..picks = [_Picked(await _backupWith(keyA))];
    final wc = await pump(t, c, inputs: inputs);
    await t.tap(_other);
    await t.pump();
    await t.pump();
    await t.tap(find.byKey(const ValueKey('oldKeyScan')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Scan the key'), findsOneWidget);

    inputs.camera.emit(const ScannedCode(CodeKind.qr, 'https://example.org/not-a-key'));
    inputs.camera.emit(const ScannedCode(CodeKind.qr, 'BW1-NOT-A-REAL-KEY'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Scan the key'), findsOneWidget, reason: 'still looking');

    // two real keys in one frame: the first one wins, the second cannot pop a closed screen
    final first = await keyA.toText(), second = await keyOther.toText();
    inputs.camera.emit(ScannedCode(CodeKind.qr, first));
    inputs.camera.emit(ScannedCode(CodeKind.qr, second));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(t.takeException(), isNull);
    expect(find.text('Scan the key'), findsNothing);
    expect(find.byKey(const ValueKey('oldKeyDialog')), findsOneWidget, reason: 'the dialog under it is still open');
    expect(t.widget<TextField>(_field).controller!.text, first);
    await t.tap(_go);
    await t.pump();
    await t.pump();
    await t.pump();
    expect(wc.walletIsEmpty, isFalse);
    expect(log(), isNot(contains(first)));
    expect(log(), isNot(contains(second)));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('the old-key dialog keeps the window secure on Android while it is open', (t) async {
    final calls = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('bw/secure'),
        (call) async {
      calls.add(call.arguments);
      return null;
    });
    addTearDown(() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('bw/secure'), null));
    resetSecureWindowCount();
    final c = _Chooser()..picks = [_Picked(await _backupWith(VaultKey.generate()))];
    await pump(t, c);
    await t.tap(_other);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('oldKeyDialog')), findsOneWidget);
    expect(calls, [true]);
    await t.tap(find.byKey(const ValueKey('oldKeyCancel')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 50));
    expect(calls, [true, false]);
  });
}
