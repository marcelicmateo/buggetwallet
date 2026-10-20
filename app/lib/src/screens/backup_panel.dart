import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../core_shim.dart'; // TEMPORARY: BackupInfo/BackupException come from wallet_core after the merge
import '../format.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';

final _log = Logger('bw.backup');

/// Plan › Backup: an encrypted copy of the wallet in the sync folder. "Restore from backup…" shows only while the wallet is empty.
class BackupPanel extends StatefulWidget {
  final WalletController wc;
  const BackupPanel({super.key, required this.wc});
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
    try {
      await widget.wc.backupNow();
    } catch (e) {
      error = "Couldn't save the backup. Check that the sync folder can be written to.";
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) {
      toast(context, 'Backup saved to the sync folder');
      await _refresh();
    }
  }

  Future<void> _restore() async {
    logNav('restore.pressed');
    final list = _backups ?? const <BackupInfo>[];
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Restore from backup'),
        children: [
          for (final b in list)
            SimpleDialogOption(
              key: ValueKey('backup:${b.name}'),
              onPressed: () => Navigator.pop(ctx, b.name),
              child: Text('${shortDateOrRaw(b.date)} · ${b.name}'),
            ),
        ],
      ),
    );
    if (name == null || !mounted) return;
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
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    int rows = 0;
    try {
      rows = await widget.wc.restoreBackup(name);
    } on StateError {
      error = 'The wallet is not empty, so nothing was restored.';
    } on VaultException {
      error = 'This backup was made with a different wallet key.';
    } on BackupException {
      error = "This backup file can't be read.";
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
    final hasFolder = wc.syncFolder != null;
    final latest = _backups?.firstOrNull;
    final canRestore = wc.walletIsEmpty;
    return Panel(children: [
      const SectionHead('Backup'),
      const Muted('An encrypted copy of your wallet in the sync folder. Only your wallet key opens it.'),
      Text(latest == null ? 'No backup yet' : 'Last backup: ${shortDateOrRaw(latest.date)}',
          style: const TextStyle(fontWeight: FontWeight.w500)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
            key: const ValueKey('backupNow'),
            style: accentOutlined(context),
            onPressed: !hasFolder || _busy ? null : _backup,
            child: Text(_busy ? 'Working…' : 'Back up now')),
        if (canRestore)
          OutlinedButton(
              key: const ValueKey('restoreBackup'),
              onPressed: _busy || (_backups?.isEmpty ?? true) ? null : _restore,
              child: const Text('Restore from backup…')),
      ]),
      if (!hasFolder) const Muted('Set the sync folder first'),
      if (hasFolder && canRestore && (_backups?.isEmpty ?? false)) const Muted('No backups found in the sync folder.'),
      if (_error != null) StatusLabel(good: false, text: _error!),
    ]);
  }
}
