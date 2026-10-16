import 'dart:convert';
import 'dart:io';

import 'repo.dart';
import 'vault.dart';

class SyncException implements Exception {
  final String message;
  const SyncException(this.message);
  @override
  String toString() => message;
}

class SyncReport {
  final int sent, received, filesRead;
  const SyncReport(this.sent, this.received, this.filesRead);
}

/// Sync through a shared folder kept in step by Syncthing (or any file sync).
///
/// Layout inside the chosen folder:
/// ```
/// budget-wallet/vault.json                      key fingerprint (no secrets)
/// budget-wallet/devices/<deviceId>/<n>.bwop     encrypted batches of changes
/// ```
/// Each device only ever writes into its own folder, so file sync never sees
/// conflicting edits. Files are never rewritten, which also makes them safe to
/// sync in any order.
class FolderSync {
  final String folder;
  final VaultKey key;
  FolderSync(this.folder, this.key);

  Directory get _root => Directory('$folder${Platform.pathSeparator}budget-wallet');
  Directory get _devices => Directory('${_root.path}${Platform.pathSeparator}devices');

  Future<void> _checkVault() async {
    await _devices.create(recursive: true);
    final f = File('${_root.path}${Platform.pathSeparator}vault.json');
    final kid = await key.keyId();
    if (await f.exists()) {
      final j = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      if (j['kid'] != kid) {
        throw const SyncException('This sync folder belongs to a wallet with a different key. Join that wallet with its key, or pick another folder.');
      }
    } else {
      await f.writeAsString(jsonEncode({'v': 1, 'kid': kid}));
    }
  }

  Future<SyncReport> run(WalletRepo repo) async {
    if (!await Directory(folder).exists()) {
      throw SyncException('The sync folder is missing: $folder');
    }
    await _checkVault();
    final sep = Platform.pathSeparator;

    // 1. Export this device's pending changes as one encrypted file.
    var sent = 0;
    final pending = repo.pendingOps();
    if (pending.isNotEmpty) {
      final mine = Directory('${_devices.path}$sep${repo.deviceId}');
      await mine.create(recursive: true);
      final n = repo.nextFileNumber();
      final name = '${n.toString().padLeft(10, '0')}.bwop';
      final payload = utf8.encode(jsonEncode([for (final (_, op) in pending) op.toJson()]));
      final tmp = File('${mine.path}$sep.$name.tmp');
      await tmp.writeAsBytes(await seal(payload, key), flush: true);
      await tmp.rename('${mine.path}$sep$name');
      repo.markExported(pending.last.$1);
      sent = pending.length;
    }

    // 2. Read every file from other devices that hasn't been applied yet.
    var received = 0, filesRead = 0;
    await for (final dev in _devices.list()) {
      if (dev is! Directory) continue;
      final device = dev.path.split(sep).last;
      if (device == repo.deviceId) continue;
      final files = await dev.list().where((f) => f is File && f.path.endsWith('.bwop') && !f.path.split(sep).last.startsWith('.')).toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final name = f.path.split(sep).last;
        if (repo.peerFileSeen(device, name)) continue;
        final clear = await unseal(await (f as File).readAsBytes(), key);
        final list = jsonDecode(utf8.decode(clear)) as List;
        received += repo.applyRemote([for (final j in list) Op.fromJson(Map<String, Object?>.from(j as Map))]);
        repo.markPeerFile(device, name);
        filesRead++;
      }
    }
    return SyncReport(sent, received, filesRead);
  }
}
