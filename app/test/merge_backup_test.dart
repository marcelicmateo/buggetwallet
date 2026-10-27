// Plan › Backup › "Merge a backup…" (P10): only with data; a dry run feeds the preview (counts per kind); Cancel changes nothing;
// Merge applies and toasts; "Nothing new"; a backup made with another key asks for it; errors; the backup toast with bill files;
// the preview fits 360 dp at text scale 2. Real core backup/merge functions, SYNTHETIC data.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/backup_texts.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/backup_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/bills.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

class _Picked extends PickedFile {
  _Picked(Uint8List data) : super('other.bwb', () async => data, length: () async => data.length);
}

class _Chooser extends FileChooser {
  List<PickedFile> picks = [];
  final saved = <String>[];
  @override
  Future<List<PickedFile>> pickBackupFile() async => picks;
  @override
  Future<Uri?> saveBackup({required String fileName, required Uint8List bytes, required String title}) async {
    saved.add(fileName);
    return Uri(path: fileName);
  }
}

/// A backup of another device's wallet sealed with [key]: [txs] payments, one tag and one goal.
Future<Uint8List> _otherBackup(VaultKey key, {int txs = 3}) async {
  final a = WalletRepo.inMemory();
  for (var i = 0; i < txs; i++) {
    a.addTransaction(date: '2026-09-0${i + 1}', amount: -1000 - i, category: 'Groceries');
  }
  await a.addTag('Synthetic tag');
  a.saveGoal(name: 'Synthetic goal', target: 100000, saved: 0, monthly: 1000, sort: 1);
  return backupBytes(a, key);
}

String _state(WalletRepo r) => jsonEncode([for (final o in r.snapshotOps()) o.toJson()]);

Finder get _merge => find.byKey(const ValueKey('mergeBackup'));
Finder get _preview => find.byKey(const ValueKey('mergePreview'));
Finder get _previewText => find.byKey(const ValueKey('mergePreviewText'));
Finder get _confirm => find.byKey(const ValueKey('mergeConfirm'));
Finder get _cancel => find.byKey(const ValueKey('mergeCancel'));

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });
  String log() => lines.join('\n');

  /// A wallet that holds one payment (so "Merge" shows) with [walletKey].
  Future<WalletController> pump(WidgetTester t, _Chooser c,
      {VaultKey? walletKey, bool data = true, Size size = const Size(400, 900), double scale = 1}) async {
    final repo = WalletRepo.inMemory();
    if (data) repo.addTransaction(date: '2026-10-01', amount: -500, category: 'Transport');
    final wc = seamedController(repo,
        key: walletKey ?? VaultKey.generate(), billInputs: FakeBillInputs(camera: FakeCamera(canShow: false)).inputs);
    addTearDown(wc.dispose);
    wc.seams.syncRunner = (u, k, r) async => const SyncReport(0, 0, 0);
    await pumpApp(t, Scaffold(body: SingleChildScrollView(child: BackupPanel(wc: wc, chooser: c))), size: size, textScale: scale);
    return wc;
  }

  Future<void> settle(WidgetTester t, [int n = 4]) async {
    for (var i = 0; i < n * 2; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  test('preview and toast texts: plain names, singular/plural, bill files, unknown kinds', () {
    const r = MergeResult(ops: 50, changed: 42, changedByEntity: {'tx': 30, 'tag': 8, 'setting': 4}, blobs: 0);
    expect(mergePreviewText(r), 'This brings in 42 updates: 30 payments, 8 tags, 4 settings. Newer changes win; nothing is doubled.');
    expect(mergedToastText(r), 'Merged 42 updates');
    const one = MergeResult(ops: 1, changed: 1, changedByEntity: {'tx': 1}, blobs: 1);
    expect(mergePreviewText(one), 'This brings in 1 update: 1 payment and 1 bill file. Newer changes win; nothing is doubled.');
    expect(mergedToastText(one), 'Merged 1 update and 1 bill file');
    const files = MergeResult(ops: 2, changed: 0, changedByEntity: {}, blobs: 2);
    expect(mergePreviewText(files), 'This brings in 2 bill files. Newer changes win; nothing is doubled.');
    expect(mergedToastText(files), 'Merged 2 bill files');
    // Every entitySchema key has a plain name; txtag and ruletag add up as tag links; an unknown one is "other".
    for (final e in [
      'tx',
      'goal',
      'wish',
      'setting',
      'rule',
      'goal_contrib',
      'recurring',
      'planned',
      'bill',
      'account',
      'category',
      'tag',
      'txtag',
      'ruletag',
      'split'
    ]) {
      expect(changeBreakdown({e: 2}), isNot(contains('other')), reason: e);
    }
    expect(changeBreakdown({'txtag': 2, 'ruletag': 1, 'nope': 3}), '3 tag links, 3 other');
    expect(changeBreakdown({'recurring': 2, 'planned': 1, 'category': 1, 'rule': 2}),
        '2 expected bills, 2 payee rules, 1 main tag, 1 planned cost');
  });

  testWidgets('Merge a backup shows only when the wallet has data', (t) async {
    await pump(t, _Chooser(), data: false);
    expect(_merge, findsNothing);
    expect(find.byKey(const ValueKey('restoreBackup')), findsOneWidget);
    await pump(t, _Chooser());
    expect(_merge, findsOneWidget);
    expect(find.byKey(const ValueKey('restoreBackup')), findsNothing);
  });

  testWidgets('the preview names the counts; Cancel changes nothing; Merge applies, toasts and a second merge has nothing new', (t) async {
    final key = VaultKey.generate();
    final c = _Chooser()..picks = [_Picked(await _otherBackup(key))];
    final wc = await pump(t, c, walletKey: key);
    final before = _state(wc.repo);
    final txBefore = wc.wholeTxs.length;

    await t.tap(_merge);
    await settle(t);
    expect(_preview, findsOneWidget);
    final text = (t.widget(_previewText) as Text).data!;
    expect(text, startsWith('This brings in '));
    expect(text, contains('3 payments'));
    expect(text, contains('1 tag'));
    expect(text, contains('1 goal'));
    expect(text, endsWith('Newer changes win; nothing is doubled.'));

    await t.tap(_cancel);
    await settle(t);
    expect(_preview, findsNothing);
    expect(_state(wc.repo), before, reason: 'cancel changes nothing');
    expect(wc.wholeTxs.length, txBefore);
    expect(find.textContaining('Merged'), findsNothing);

    await t.tap(_merge);
    await settle(t);
    await t.tap(_confirm);
    await settle(t);
    expect(find.textContaining(RegExp(r'^Merged \d+ updates$')), findsOneWidget);
    expect(wc.wholeTxs.length, txBefore + 3);
    expect(wc.goals.length, 1);
    expect(log(), contains('backup.merged'));
    expect(log(), contains('backup.mergePreview'));
    expect(log(), isNot(contains('Synthetic')));
    await t.pump(const Duration(seconds: 5));

    // The same file again: nothing is doubled, nothing to confirm.
    final after = _state(wc.repo);
    await t.tap(_merge);
    await settle(t);
    expect(_preview, findsNothing);
    expect(find.text('Nothing new in this backup'), findsOneWidget);
    expect(_state(wc.repo), after);
    expect(wc.wholeTxs.length, txBefore + 3);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('a backup made with another key asks for it, then previews and merges with the wallet keeping its own key', (t) async {
    final keyA = VaultKey.generate(), keyB = VaultKey.generate();
    final c = _Chooser()..picks = [_Picked(await _otherBackup(keyA, txs: 2))];
    final wc = await pump(t, c, walletKey: keyB);
    final txBefore = wc.wholeTxs.length;

    await t.tap(_merge);
    await settle(t);
    expect(find.byKey(const ValueKey('oldKeyDialog')), findsOneWidget);
    expect(_preview, findsNothing);
    final textA = await keyA.toText();
    await t.enterText(find.byKey(const ValueKey('oldKeyField')), '  $textA  ');
    await t.tap(find.byKey(const ValueKey('oldKeyRestore')));
    await settle(t, 6);
    expect(_preview, findsOneWidget);
    expect((t.widget(_previewText) as Text).data, contains('2 payments'));
    await t.tap(_confirm);
    await settle(t, 6);
    expect(find.textContaining(RegExp(r'^Merged \d+ updates$')), findsOneWidget);
    expect(wc.wholeTxs.length, txBefore + 2);
    expect(wc.key!.bytes, keyB.bytes);
    final plain = textA.replaceAll('-', '');
    expect(log(), isNot(contains(textA)));
    expect(log(), isNot(contains(plain.substring(3, 20))));
    expect(log(), contains('"otherKey":true'));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('a wrong old key shows the key error and changes nothing; cancelling the key dialog is silent', (t) async {
    final keyA = VaultKey.generate();
    final c = _Chooser()..picks = [_Picked(await _otherBackup(keyA))];
    final wc = await pump(t, c);
    final before = _state(wc.repo);

    await t.tap(_merge);
    await settle(t);
    await t.tap(find.byKey(const ValueKey('oldKeyCancel')));
    await settle(t);
    expect(find.textContaining("doesn't open"), findsNothing, reason: 'no error after a cancel');
    expect(find.textContaining("doesn't open with this wallet's key"), findsNothing);
    expect(wc.wholeTxs.length, 1);

    await t.tap(_merge);
    await settle(t);
    await t.enterText(find.byKey(const ValueKey('oldKeyField')), await VaultKey.generate().toText());
    await t.tap(find.byKey(const ValueKey('oldKeyRestore')));
    await settle(t, 6);
    expect(find.textContaining("doesn't open this backup (or the file is damaged)", findRichText: true), findsOneWidget);
    expect(_preview, findsNothing);
    expect(_state(wc.repo), before);
  });

  testWidgets('errors from the core show the same texts as restore, and the wallet is untouched', (t) async {
    final key = VaultKey.generate();
    final c = _Chooser()
      ..picks = [
        _Picked(Uint8List.fromList([1, 2, 3]))
      ];
    final wc = await pump(t, c, walletKey: key);
    final before = _state(wc.repo);
    final cases = {
      BackupFailure.damaged: 'This backup file is damaged.',
      BackupFailure.newerVersion: 'Made by a newer app version. Update first.',
      BackupFailure.clockAhead: "This backup has changes dated later than this device's clock. Check the date and time.",
      BackupFailure.unreadable: "This backup file can't be read.",
    };
    for (final e in cases.entries) {
      wc.seams.backupMerger = (repo, bytes, k, {dryRun = false, walletKey}) async => throw BackupException(e.key, 'core text');
      await t.tap(_merge);
      await settle(t);
      expect(find.textContaining(e.value, findRichText: true), findsOneWidget, reason: e.key.name);
      expect(_preview, findsNothing);
    }
    expect(_state(wc.repo), before);
    expect(log(), contains('backup.mergeFailed'));
    expect(log(), isNot(contains('core text')));
  });

  /// Files the real core calls damaged: 3 bytes and 200 pseudo-random bytes.
  Map<String, Uint8List> garbage() => {
        'three bytes': Uint8List.fromList([1, 2, 3]),
        '200 random bytes': Uint8List.fromList([for (var i = 0; i < 200; i++) (i * 73 + 41) % 256]),
      };

  /// A real backup cut in half: the seal's check fails, which the core cannot tell from another key (`badKey`).
  Future<Uint8List> cutOff(VaultKey key) async {
    final real = await _otherBackup(key);
    return Uint8List.sublistView(real, 0, real.length ~/ 2);
  }

  testWidgets('merge: a damaged file says damaged (no key dialog) and changes nothing; real core', (t) async {
    final key = VaultKey.generate();
    final c = _Chooser();
    final wc = await pump(t, c, walletKey: key);
    final before = _state(wc.repo);
    for (final e in garbage().entries) {
      c.picks = [_Picked(e.value)];
      await t.tap(_merge);
      await settle(t, 6);
      expect(find.byKey(const ValueKey('oldKeyDialog')), findsNothing, reason: e.key);
      expect(_preview, findsNothing, reason: e.key);
      expect(find.textContaining('This backup file is damaged.', findRichText: true), findsOneWidget, reason: e.key);
    }
    // A cut-off real backup fails the seal check like another key: the key dialog opens; cancelling changes nothing.
    c.picks = [_Picked(await cutOff(key))];
    await t.tap(_merge);
    await settle(t, 6);
    expect(find.byKey(const ValueKey('oldKeyDialog')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('oldKeyCancel')));
    await settle(t);
    expect(_state(wc.repo), before);
  });

  testWidgets('restore: a damaged file says damaged, not the key text; real core', (t) async {
    final key = VaultKey.generate();
    final c = _Chooser();
    final wc = await pump(t, c, walletKey: key, data: false);
    for (final e in garbage().entries) {
      c.picks = [_Picked(e.value)];
      await t.tap(find.byKey(const ValueKey('restoreBackup')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('restoreConfirm')));
      await settle(t, 6);
      expect(find.textContaining('This backup file is damaged.', findRichText: true), findsOneWidget, reason: e.key);
      expect(find.textContaining("doesn't open with this wallet's key", findRichText: true), findsNothing, reason: e.key);
    }
    c.picks = [_Picked(await cutOff(key))];
    await t.tap(find.byKey(const ValueKey('restoreBackup')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('restoreConfirm')));
    await settle(t, 6);
    expect(find.textContaining("doesn't open with this wallet's key", findRichText: true), findsOneWidget,
        reason: 'cut-off = seal check failed');
    expect(wc.walletIsEmpty, isTrue);
  });

  testWidgets('a real merge that brings in nothing says "Nothing new", not "Merged 0"', (t) async {
    final c = _Chooser()..picks = [_Picked(Uint8List(4))];
    final wc = await pump(t, c);
    wc.seams.backupMerger = (repo, bytes, k, {dryRun = false, walletKey}) async => dryRun
        ? const MergeResult(ops: 2, changed: 2, changedByEntity: {'tx': 2})
        : const MergeResult(ops: 2, changed: 0, changedByEntity: {});
    await t.tap(_merge);
    await settle(t);
    await t.tap(_confirm);
    await settle(t);
    expect(find.text('Nothing new in this backup'), findsOneWidget);
    expect(find.textContaining('Merged 0'), findsNothing);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('Back up now says how many bill files went in; no files, the old toast', (t) async {
    final c = _Chooser();
    final wc = await pump(t, c);
    wc.seams.backupBytesWriter = (repo, key) async => fakeBackup(Uint8List(4), blobs: 3);
    await t.tap(find.byKey(const ValueKey('backupNow')));
    await settle(t);
    expect(find.text('Backup saved with 3 bill files'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    expect(lines.any((l) => l.contains('backup.done') && l.contains('"blobs":3')), isTrue);

    wc.seams.backupBytesWriter = (repo, key) async => fakeBackup(Uint8List(4), blobs: 1);
    await t.tap(find.byKey(const ValueKey('backupNow')));
    await settle(t);
    expect(find.text('Backup saved with 1 bill file'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));

    wc.seams.backupBytesWriter = (repo, key) async => fakeBackup(Uint8List(4));
    await t.tap(find.byKey(const ValueKey('backupNow')));
    await settle(t);
    expect(find.text('Saved ${backupFileName(wc.today())}'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('the preview dialog fits 360 dp at text scale 2 and 320 dp', (t) async {
    for (final w in [360.0, 320.0]) {
      final key = VaultKey.generate();
      final c = _Chooser()..picks = [_Picked(await _otherBackup(key))];
      final wc = await pump(t, c, walletKey: key, size: Size(w, 1400), scale: 2);
      wc.seams.backupMerger = (repo, bytes, k, {dryRun = false, walletKey}) async => const MergeResult(
          ops: 90,
          changed: 84,
          blobs: 12,
          changedByEntity: {'tx': 30, 'tag': 8, 'setting': 4, 'txtag': 20, 'recurring': 6, 'planned': 4, 'bill': 8, 'category': 4});
      await t.tap(_merge);
      await settle(t);
      expect(_preview, findsOneWidget);
      expect(t.takeException(), isNull, reason: 'no overflow at $w');
      expect(_confirm, findsOneWidget);
      final box = t.getRect(_preview);
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(w));
      await t.tap(_cancel);
      await settle(t);
    }
  });
}
