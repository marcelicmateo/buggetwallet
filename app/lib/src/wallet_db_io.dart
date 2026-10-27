import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';

import 'wallet_db_base.dart';

/// Side files of `wallet.db` (SQLite's, and the plaintext copy kept while an old database is being encrypted).
const _sideSuffixes = ['-wal', '-shm', '-journal', '.plain-copy', '.plain-copy.tmp'];

/// The path of `wallet.db`; [dir] is for tests, which point the database at a temporary folder (null = the app support folder).
Future<String> _path(String? dir) async {
  if (dir != null) return '$dir${Platform.pathSeparator}wallet.db';
  final support = await getApplicationSupportDirectory();
  await support.create(recursive: true);
  return '${support.path}${Platform.pathSeparator}wallet.db';
}

/// Phones and computers: nothing to claim (the browser build guards against a second tab here).
Future<void> claimWalletDb() async {}

/// Is there a `wallet.db` (or an interrupted conversion's copy of one) in the app folder?
Future<bool> walletDbExists({String? dir}) async {
  final path = await _path(dir);
  return await File(path).exists() || await File('$path.plain-copy').exists();
}

/// Moves `wallet.db` and its side files to `wallet.db.unopened-<stamp>` (+ the same suffixes), a new stamp when it is taken.
/// Nothing is deleted: the old file stays for whoever has the key that opens it. No-op without a file.
Future<void> setAsideWalletDb(String stamp, {String? dir}) async {
  final path = await _path(dir);
  var target = '$path.unopened-$stamp';
  for (var n = 2; await File(target).exists(); n++) {
    target = '$path.unopened-$stamp-$n';
  }
  // Every rename is remembered: if one fails, the ones already done are renamed back, so wallet.db and its side files stay together
  // (a new wallet.db must never be opened next to stale side files of the old one). Nothing is deleted either way.
  final moved = <(String, String)>[];
  try {
    final main = File(path);
    if (await main.exists()) {
      await main.rename(target);
      moved.add((path, target));
    }
    for (final s in _sideSuffixes) {
      final f = File('$path$s');
      if (await f.exists()) {
        await f.rename('$target$s');
        moved.add(('$path$s', '$target$s'));
      }
    }
  } on Object {
    for (final (from, to) in moved.reversed) {
      try {
        await File(to).rename(from);
      } on Object {
        // left where it is: the caller finds wallet.db missing and does not build a new one next to the remains
      }
    }
    rethrow;
  }
}

/// Is the file at [path] a plaintext SQLite database (the header `SQLite format 3`)? A missing or empty file is not.
bool _isPlaintext(String path) {
  final f = File(path);
  if (!f.existsSync()) return false;
  final raf = f.openSync();
  try {
    final head = raf.readSync(16);
    return head.length == 16 && String.fromCharCodes(head.sublist(0, 15)) == 'SQLite format 3';
  } finally {
    raf.closeSync();
  }
}

/// Is the stored wallet an unkeyed one (a plaintext `wallet.db`, or a plaintext copy left by an interrupted conversion)?
/// Opening it with any key would convert it, so joining a wallet never does that.
Future<bool> walletDbIsPlaintext({String? dir}) async {
  final path = await _path(dir);
  return _isPlaintext(path) || await File('$path.plain-copy').exists();
}

/// `wallet.db` in the app support folder, encrypted with [dbKey] (`localDbKey`). An older plaintext file is converted in place
/// (crash-safe in core). A key that does not open it throws [WalletDbKeyException]; the file is not touched then.
/// [deviceId] is this install's id from the key store (null = the database's own). [WalletDb.forget] closes it and deletes the file and its side files.
Future<WalletDb> openWalletDb(Uint8List dbKey, {String? deviceId, String? dir}) async {
  final path = await _path(dir);
  final converted = _isPlaintext(path);
  final repo = WalletRepo.open(path, dbKey: dbKey, deviceId: deviceId);
  return WalletDb(repo, converted: converted, forget: () async {
    for (final suffix in ['', ..._sideSuffixes]) {
      final f = File('$path$suffix');
      if (await f.exists()) await f.delete();
    }
  });
}
