import 'dart:typed_data';

import 'package:file_picker/file_picker.dart' show PlatformFile;
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';

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

class _BackupPanelState extends State<BackupPanel> {
  bool _busy = false;
  String? _error;

  Future<void> _backup() async {
    logNav('backup.pressed');
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    String? saved;
    try {
      final b = await widget.wc.backupDownload();
      final uri = await widget.chooser.saveBackup(fileName: b.name, bytes: b.bytes, title: 'Save backup');
      if (uri != null) saved = b.name;
      logEvent(_log, Level.INFO, 'backup.saveDialog', {'saved': uri != null, 'bytes': b.bytes.length});
    } catch (e, st) {
      logError(_log, 'backup.saveFailed', e, st, fields: {'type': e.runtimeType.toString()});
      error = "Couldn't save the backup.";
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (saved != null) toast(context, 'Saved $saved');
  }

  /// Pick a `.bwb` file, confirm, restore.
  Future<void> _restoreFile() async {
    logNav('restore.pressed');
    final List<PlatformFile> picked;
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
      bytes = await picked.first.readAsBytes();
    } catch (e, st) {
      logError(_log, 'restore.openFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) setState(() => _error = "This backup file can't be read.");
      return;
    }
    if (!mounted || !await _confirmRestore()) return;
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
  Future<void> _runRestore(Future<int> Function() restore) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    int rows = 0;
    try {
      rows = await restore();
    } on StateError {
      error = 'The wallet is not empty, so nothing was restored.';
    } on VaultException {
      error = 'This backup was made with a different wallet key.';
    } on BackupException catch (e) {
      error = switch (e.reason) {
        BackupFailure.unreadable => "This backup file can't be read.",
        BackupFailure.damaged => 'This backup file is damaged.',
        BackupFailure.newerVersion => 'Made by a newer app version. Update first.',
      };
    } catch (e, st) {
      logError(_log, 'restore.unexpected', e, st);
      error = "Couldn't restore the backup.";
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) toast(context, rows == 1 ? 'Restored 1 row' : 'Restored $rows rows');
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    return Panel(children: [
      const SectionHead('Backup'),
      const Muted('An encrypted copy of your wallet as a file. Only your wallet key opens it. Keep the file somewhere safe.'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
            key: const ValueKey('backupNow'),
            style: accentOutlined(context),
            onPressed: _busy ? null : _backup,
            child: Text(_busy ? 'Working…' : 'Back up now')),
        if (wc.walletIsEmpty)
          OutlinedButton(
              key: const ValueKey('restoreBackup'), onPressed: _busy ? null : _restoreFile, child: const Text('Restore from backup…')),
      ]),
      if (_error != null) StatusLabel(good: false, text: _error!),
    ]);
  }
}
