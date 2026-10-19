import 'dart:convert';
import 'dart:io';

import 'logs.dart';
import 'repo.dart';
import 'vault.dart';

final _log = Logger('bw.sync');

/// What is logged of a sync file name: its sequence number only (`0000000042` of `0000000042.bwop`). Conflict
/// copies add a file-sync device id to the name, and device folder names are random ids, so neither is logged.
String _seq(String name) => RegExp(r'^\d+').stringMatch(name) ?? '?';

class SyncException implements Exception {
  final String message;
  const SyncException(this.message);
  @override
  String toString() => message;
}

class SyncReport {
  final int sent, received, filesRead;

  /// Files from other devices that could not be decrypted or read (damaged, half-synced, or sealed with
  /// another key). They are skipped and retried on every run, so a repaired copy still applies later.
  final int badFiles;
  const SyncReport(this.sent, this.received, this.filesRead, {this.badFiles = 0});
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
        logEvent(_log, Level.WARNING, 'sync.vault.mismatch');
        throw const SyncException(
            'This sync folder belongs to a wallet with a different key. Join that wallet with its key, or pick another folder.');
      }
    } else {
      await f.writeAsString(jsonEncode({'v': 1, 'kid': kid}));
      logEvent(_log, Level.INFO, 'sync.vault.created');
    }
  }

  Future<SyncReport> run(WalletRepo repo) async {
    if (!await Directory(folder).exists()) {
      // No path in the message: it is logged, and paths can contain the user's name.
      throw const SyncException('The sync folder is missing. Check that it still exists, or pick it again.');
    }
    await _checkVault();
    final sep = Platform.pathSeparator;

    // 1. Export this device's pending changes as one encrypted file.
    var sent = 0;
    final pending = repo.pendingOps();
    final export = PerfTimer('sync.export', warnMs: 500);
    if (pending.isNotEmpty) {
      final mine = Directory('${_devices.path}$sep${repo.deviceId}');
      await mine.create(recursive: true);
      final n = repo.nextFileNumber();
      final name = '${n.toString().padLeft(10, '0')}.bwop';
      final payload = utf8.encode(jsonEncode([for (final (_, op) in pending) op.toJson()]));
      final tmp = File('${mine.path}$sep.$name.tmp');
      final sealed = await seal(payload, key);
      await tmp.writeAsBytes(sealed, flush: true);
      await tmp.rename('${mine.path}$sep$name');
      repo.markExported(pending.last.$1);
      sent = pending.length;
      export.done({'ops': sent, 'file': n, 'jsonBytes': payload.length, 'bytes': sealed.length});
    } else {
      logEvent(_log, Level.FINE, 'sync.export.none');
    }

    // 2. Read every file from other devices that hasn't been applied yet. Hand-added expenses are matched to bank
    //    rows once at the end, not after every file (a new device's first sync can read hundreds).
    var received = 0, filesRead = 0, opsRead = 0, bytesRead = 0, devices = 0, bad = 0;
    final apply = PerfTimer('sync.apply', warnMs: 1000);
    try {
      await for (final dev in _devices.list()) {
        if (dev is! Directory) continue;
        final device = dev.path.split(sep).last;
        if (device == repo.deviceId) continue;
        devices++;
        final files =
            await dev.list().where((f) => f is File && f.path.endsWith('.bwop') && !f.path.split(sep).last.startsWith('.')).toList();
        files.sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          final name = f.path.split(sep).last;
          if (repo.peerFileSeen(device, name)) continue;
          final List<int> bytes;
          final List<Object?> list;
          final int changed;
          try {
            bytes = await (f as File).readAsBytes();
            final clear = await unseal(bytes, key);
            list = jsonDecode(utf8.decode(clear)) as List;
            changed = repo.applyRemote([for (final j in list) Op.fromJson(Map<String, Object?>.from(j as Map))], match: false);
          } catch (e, st) {
            // Skip it (not marked as seen, so a repaired copy applies on a later run) and keep applying the
            // others: one damaged file must not block every file after it. applyRemote rolled back its part.
            logError(_log, 'sync.file.failed', e, st, fields: {'file': _seq(name)});
            bad++;
            continue;
          }
          received += changed;
          repo.markPeerFile(device, name);
          filesRead++;
          opsRead += list.length;
          bytesRead += bytes.length;
          logEvent(_log, Level.FINE, 'sync.file', {'file': _seq(name), 'bytes': bytes.length, 'ops': list.length, 'changed': changed});
        }
      }
    } finally {
      repo.runPendingMatch(); // also if reading the folder failed midway: what was applied gets matched
    }
    apply.done({'devices': devices, 'files': filesRead, 'ops': opsRead, 'changed': received, 'bytes': bytesRead, 'bad': bad});
    if (bad > 0) logEvent(_log, Level.WARNING, 'sync.files.skipped', {'bad': bad});
    return SyncReport(sent, received, filesRead, badFiles: bad);
  }
}
