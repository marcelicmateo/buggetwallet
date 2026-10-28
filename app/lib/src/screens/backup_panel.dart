import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../backup_texts.dart';
import '../bill_inputs.dart' show ScannedCode;
import '../controller.dart';
import '../file_chooser.dart';
import '../layout.dart';
import '../logging.dart';
import '../secure_window.dart';
import '../theme.dart';
import '../widgets/async_action.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

final _log = Logger('bw.backup');

/// Plan › Backup: an encrypted copy of the wallet as a `.bwb` file, saved through the system save dialog (a download in a
/// browser). "Restore from backup…" picks such a file and shows only while the wallet is empty.
class BackupPanel extends StatefulWidget {
  final WalletController wc;

  /// The system file chooser (tests pass a fake).
  final FileChooser chooser;
  const BackupPanel({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  State<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends State<BackupPanel> with AsyncAction {
  Future<void> _backup() async {
    logNav('backup.pressed');
    setState(() => error = null);
    String? saved;
    var files = 0;
    final failed = await run(() async {
      try {
        final b = await widget.wc.backupDownload();
        final uri = await widget.chooser.saveBackup(fileName: b.name, bytes: b.bytes, title: 'Save backup');
        if (uri != null) {
          saved = b.name;
          files = b.blobs;
        }
        logEvent(_log, Level.INFO, 'backup.saveDialog', {'saved': uri != null, 'bytes': b.bytes.length});
        return null;
      } catch (e, st) {
        logError(_log, 'backup.saveFailed', e, st, fields: {'type': e.runtimeType.toString()});
        return "Couldn't save the backup.";
      }
    });
    if (!mounted) return;
    setState(() => error = failed);
    if (saved != null) toast(context, files > 0 ? 'Backup saved with ${billFilesText(files)}' : 'Saved $saved');
  }

  /// Pick a `.bwb` file, confirm, restore. With [otherKey] the file was made with another wallet key: ask for it, then restore.
  Future<void> _restoreFile({bool otherKey = false}) async {
    logNav(otherKey ? 'restore.otherKey.pressed' : 'restore.pressed');
    final List<PickedFile> picked;
    try {
      picked = await widget.chooser.pickBackupFile();
    } catch (e, st) {
      logError(_log, 'restore.pickerFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) toast(context, chooserFailedMessage);
      return;
    }
    if (picked.isEmpty || !mounted) return;
    final Uint8List bytes;
    try {
      bytes = await picked.first.readBytes();
    } catch (e, st) {
      logError(_log, 'restore.openFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) setState(() => error = "This backup file can't be read.");
      return;
    }
    if (!mounted) return;
    if (otherKey) {
      final text = await askOldKey(context, widget.wc);
      if (text == null || !mounted) return;
      await _runRestore(() => widget.wc.restoreBackupFile(bytes, otherKey: text), otherKey: true);
      return;
    }
    if (!await _confirmRestore()) return;
    await _runRestore(() => widget.wc.restoreBackupFile(bytes));
  }

  Future<bool> _confirmRestore() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: const Text('This replaces nothing; the wallet is empty.'),
        actions: [
          TextButton(key: const ValueKey('restoreCancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('restoreConfirm'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
        ],
      ),
    );
    return ok == true && mounted;
  }

  /// Runs a restore and shows its error text (one text per failure) or the toast with the row count.
  Future<void> _runRestore(Future<int> Function() restore, {bool otherKey = false}) async {
    setState(() => error = null);
    int rows = 0;
    final failed = await run(() async {
      try {
        rows = await restore();
        return null;
      } on StateError {
        return 'The wallet is not empty, so nothing was restored.';
      } on VaultException catch (e) {
        return _keyErrorText(e, otherKey);
      } on BackupException catch (e) {
        return _backupErrorText(e);
      } catch (e, st) {
        logError(_log, 'restore.unexpected', e, st);
        return "Couldn't restore the backup.";
      }
    });
    if (!mounted) return;
    setState(() => error = failed);
    if (failed == null) toast(context, rows == 1 ? 'Restored 1 row' : 'Restored $rows rows');
  }

  /// Pick a `.bwb` file and merge it into this wallet: a dry run, a preview with the counts, then the merge. A file made with
  /// another key asks for that key first (used once, kept only in this call).
  Future<void> _mergeFile() async {
    logNav('merge.pressed');
    final List<PickedFile> picked;
    try {
      picked = await widget.chooser.pickBackupFile();
    } catch (e, st) {
      logError(_log, 'merge.pickerFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) toast(context, chooserFailedMessage);
      return;
    }
    if (picked.isEmpty || !mounted) return;
    final Uint8List bytes;
    try {
      bytes = await picked.first.readBytes();
    } catch (e, st) {
      logError(_log, 'merge.openFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) setState(() => error = "This backup file can't be read.");
      return;
    }
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    String? failed;
    String? done;
    String? otherKey;
    try {
      MergeResult preview;
      try {
        preview = await widget.wc.mergeBackupFile(bytes, dryRun: true);
      } on VaultException catch (e) {
        // Only a key that does not open it means "another key"; a damaged or newer file has its own text.
        if (e.failure != UnsealFailure.badKey && e.failure != UnsealFailure.otherKey) rethrow;
        // Not this wallet's key: ask for the one the backup was made with.
        if (!mounted) return;
        setState(() => busy = false);
        otherKey = await askOldKey(context, widget.wc, action: 'Continue');
        if (otherKey == null || !mounted) return;
        setState(() => busy = true);
        preview = await widget.wc.mergeBackupFile(bytes, otherKey: otherKey, dryRun: true);
      }
      if (!mounted) return;
      if (preview.changed == 0 && preview.blobs == 0) {
        done = 'Nothing new in this backup';
      } else {
        setState(() => busy = false);
        final go = await _confirmMerge(preview);
        if (!go || !mounted) return;
        setState(() => busy = true);
        final r = await widget.wc.mergeBackupFile(bytes, otherKey: otherKey);
        done = r.changed == 0 && r.blobs == 0 ? 'Nothing new in this backup' : mergedToastText(r);
      }
    } on VaultException catch (e) {
      failed = _keyErrorText(e, otherKey != null);
    } on BackupException catch (e) {
      failed = _backupErrorText(e);
    } catch (e, st) {
      logError(_log, 'merge.unexpected', e, st);
      failed = "Couldn't merge the backup.";
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      error = failed;
    });
    if (done != null) toast(context, done);
  }

  Future<bool> _confirmMerge(MergeResult preview) async {
    logNav('dialog.open', {'dialog': 'mergePreview'});
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('mergePreview'),
        title: const Text('Merge this backup?'),
        content: SingleChildScrollView(child: Text(mergePreviewText(preview), key: const ValueKey('mergePreviewText'))),
        actions: [
          TextButton(key: const ValueKey('mergeCancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('mergeConfirm'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Merge')),
        ],
      ),
    );
    return ok == true && mounted;
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    return Panel(children: [
      const SectionHead('Backup'),
      Explainer(wc, 'backup', 'An encrypted copy of your wallet as a file. Only your wallet key opens it. Keep the file somewhere safe.'),
      const Muted(
          'Bill files on this device go into the backup (up to ${backupBlobBytesDefault >> 20} MB). Files only on your relay do not.',
          key: ValueKey('backupNoFiles'),
          size: BwType.metaSize),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
            key: const ValueKey('backupNow'),
            style: accentOutlined(context),
            onPressed: busy ? null : _backup,
            child: Text(busy ? 'Working…' : 'Back up now')),
        if (wc.walletIsEmpty)
          OutlinedButton(
              key: const ValueKey('restoreBackup'), onPressed: busy ? null : _restoreFile, child: const Text('Restore from backup…')),
        if (!wc.walletIsEmpty)
          OutlinedButton(key: const ValueKey('mergeBackup'), onPressed: busy ? null : _mergeFile, child: const Text('Merge a backup…')),
      ]),
      if (wc.walletIsEmpty)
        TextButton(
            key: const ValueKey('restoreOtherKey'),
            onPressed: busy ? null : () => _restoreFile(otherKey: true),
            child: const Text('Restore a backup made with another key…')),
      if (error != null) StatusLabel(good: false, text: error!),
    ]);
  }
}

String _keyErrorText(VaultException e, bool otherKey) => switch (e.failure) {
      // null: the typed text is not a key (its message says what is wrong with it).
      null =>
        otherKey ? e.message : "This backup doesn't open with this wallet's key. It was made with another key, or the file is damaged.",
      UnsealFailure.badKey => otherKey
          ? "That key doesn't open this backup (or the file is damaged)."
          : "This backup doesn't open with this wallet's key. It was made with another key, or the file is damaged.",
      UnsealFailure.otherKey => otherKey ? "That key doesn't open this backup." : 'This backup was made with another wallet key.',
      UnsealFailure.damaged || UnsealFailure.tooLarge => 'This backup file is damaged.',
      UnsealFailure.newerFormat => 'Made by a newer app version. Update first.',
    };

String _backupErrorText(BackupException e) => switch (e.reason) {
      BackupFailure.unreadable => "This backup file can't be read.",
      BackupFailure.otherKey => 'This backup was made with another wallet key.',
      BackupFailure.damaged => 'This backup file is damaged.',
      BackupFailure.newerVersion => 'Made by a newer app version. Update first.',
      BackupFailure.clockAhead => "This backup has changes dated later than this device's clock. Check the date and time.",
    };

/// Asks for the key an old backup was made with: typed, pasted or scanned from its QR code (where the camera works). Returns the
/// text (not yet checked) or null when cancelled. The text lives in this dialog only: it is never stored or logged.
Future<String?> askOldKey(BuildContext context, WalletController wc, {String action = 'Restore'}) {
  logNav('dialog.open', {'dialog': 'oldKey'});
  return showDialog<String>(context: context, builder: (ctx) => _OldKeyDialog(wc: wc, action: action));
}

class _OldKeyDialog extends StatefulWidget {
  final WalletController wc;
  final String action;
  const _OldKeyDialog({required this.wc, required this.action});
  @override
  State<_OldKeyDialog> createState() => _OldKeyDialogState();
}

class _OldKeyDialogState extends State<_OldKeyDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    logNav('oldKey.scan');
    final code = await openPageOrDialog<ScannedCode>(context, _ScanKeyScreen(wc: widget.wc), width: 520);
    if (code != null && mounted) setState(() => _text.text = code.raw);
  }

  @override
  Widget build(BuildContext context) {
    final canScan = widget.wc.billInputs.camera.supported;
    return SecureWindow(
        child: AlertDialog(
      key: const ValueKey('oldKeyDialog'),
      title: const Text('Key of the backup'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Type or paste the wallet key this backup was made with. It is used once and not kept.',
              style: TextStyle(fontSize: BwType.metaSize)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('oldKeyField'),
            controller: _text,
            minLines: 2,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Old wallet key', hintText: 'BW1-…'),
          ),
          if (canScan)
            TextButton.icon(
                key: const ValueKey('oldKeyScan'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan its QR code'),
                onPressed: _scan),
        ]),
      ),
      actions: [
        TextButton(key: const ValueKey('oldKeyCancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
            key: const ValueKey('oldKeyRestore'), onPressed: () => Navigator.pop(context, _text.text.trim()), child: Text(widget.action)),
      ],
    ));
  }
}

/// The camera looking for the QR code of a wallet key; pops the first code that is a key and ignores every other one (another QR
/// in view, a second code in the same frame).
class _ScanKeyScreen extends StatefulWidget {
  final WalletController wc;
  const _ScanKeyScreen({required this.wc});
  @override
  State<_ScanKeyScreen> createState() => _ScanKeyScreenState();
}

class _ScanKeyScreenState extends State<_ScanKeyScreen> {
  bool _busy = false;
  bool _done = false;

  Future<void> _onCode(ScannedCode c) async {
    if (_done || _busy) return;
    final plain = c.raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (!plain.startsWith('BW1')) return; // not a wallet key
    _busy = true; // set before the first await: a second code in the same frame is ignored
    try {
      await VaultKey.parse(c.raw);
    } on VaultException {
      _busy = false;
      return;
    }
    if (_done || !mounted) return;
    _done = true;
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: const DialogAppBar(title: 'Scan the key'),
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: widget.wc.billInputs.camera.view(onCode: _onCode)),
          const Padding(
              padding: EdgeInsets.fromLTRB(pagePad, 10, pagePad, 14), child: Muted('Point at the QR code of the old wallet key.')),
        ]),
      );
}
