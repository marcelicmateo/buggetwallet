import 'dart:typed_data';

import 'package:file_picker/file_picker.dart' show PlatformFile;
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';

final _log = Logger('bw.backup');

/// Plan › Backup: an encrypted copy of the wallet in the sync folder. "Restore from backup…" shows only while the wallet is empty.
/// In a browser (no sync folder) "Back up now" downloads the file and "Restore from backup…" picks a `.bwb` file.
class BackupPanel extends StatefulWidget {
  final WalletController wc;

  /// The system file chooser (tests pass a fake).
  final FileChooser chooser;
  const BackupPanel({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  State<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends State<BackupPanel> {
  List<BackupInfo>? _backups;
  String? _loadedFolder;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.wc.addListener(_onChange);
    _refresh();
  }

  @override
  void dispose() {
    widget.wc.removeListener(_onChange);
    super.dispose();
  }

  /// A new sync folder means a new list of backups.
  void _onChange() {
    if (widget.wc.syncFolder != _loadedFolder) _refresh();
  }

  Future<void> _refresh() async {
    if (isWeb) return; // no sync folder, no list: a backup is a download
    final folder = _loadedFolder = widget.wc.syncFolder;
    final list = await widget.wc.listBackups();
    if (mounted && folder == _loadedFolder) setState(() => _backups = list);
  }

  Future<void> _backup() async {
    logNav('backup.pressed');
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    String? downloaded;
    try {
      if (isWeb) {
        final b = await widget.wc.backupDownload();
        await widget.chooser.saveBackup(fileName: b.name, bytes: b.bytes, title: 'Save backup');
        downloaded = b.name;
      } else {
        await widget.wc.backupNow();
      }
    } catch (e) {
      error = isWeb ? "Couldn't save the backup." : "Couldn't save the backup. Check that the sync folder can be written to.";
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) {
      toast(context, downloaded != null ? 'Saved $downloaded' : 'Backup saved to the sync folder');
      await _refresh();
    }
  }

  /// Web: pick a `.bwb` file, confirm, restore.
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
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

  Future<void> _restore() async {
    logNav('restore.pressed');
    final list = _backups ?? const <BackupInfo>[];
    final picked = await showDialog<BackupInfo>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Restore from backup'),
        children: [
          for (final b in list)
            SimpleDialogOption(
              key: ValueKey('backup:${b.name}'),
              onPressed: () => Navigator.pop(ctx, b),
              child: Text('${shortDateOrRaw(b.date)} · ${b.name}'),
            ),
        ],
      ),
    );
    if (picked == null || !mounted || !await _confirmRestore()) return;
    await _runRestore(() => widget.wc.restoreBackup(picked));
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final web = isWeb;
    final hasFolder = wc.syncFolder != null;
    final latest = _backups?.firstOrNull;
    final canRestore = wc.walletIsEmpty;
    return Panel(children: [
      const SectionHead('Backup'),
      Muted(web
          ? 'An encrypted copy of your wallet as a file. Only your wallet key opens it. Keep the file somewhere safe.'
          : 'An encrypted copy of your wallet in the sync folder. Only your wallet key opens it.'),
      if (!web)
        Text(latest == null ? 'No backup yet' : 'Last backup: ${shortDateOrRaw(latest.date)}',
            style: const TextStyle(fontWeight: FontWeight.w500)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
            key: const ValueKey('backupNow'),
            style: accentOutlined(context),
            onPressed: (!web && !hasFolder) || _busy ? null : _backup,
            child: Text(_busy ? 'Working…' : 'Back up now')),
        if (canRestore)
          OutlinedButton(
              key: const ValueKey('restoreBackup'),
              onPressed: _busy || (!web && (_backups?.isEmpty ?? true)) ? null : (web ? _restoreFile : _restore),
              child: const Text('Restore from backup…')),
      ]),
      if (!web && !hasFolder) const Muted('Set the sync folder first'),
      if (!web && hasFolder && canRestore && (_backups?.isEmpty ?? false)) const Muted('No backups found in the sync folder.'),
      if (_error != null) StatusLabel(good: false, text: _error!),
    ]);
  }
}
