import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';

import 'wallet_db_base.dart';

/// Side files of `wallet.db` (SQLite's, and the plaintext copy kept while an old database is being encrypted).
const _sideSuffixes = ['-wal', '-shm', '-journal', '.plain-copy', '.plain-copy.tmp'];

/// Tests point the database at a temporary folder.
@visibleForTesting
String? walletDbDirOverride;

Future<String> _path() async {
  final over = walletDbDirOverride;
  if (over != null) return '$over${Platform.pathSeparator}wallet.db';
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return '${dir.path}${Platform.pathSeparator}wallet.db';
}

/// Phones and computers: nothing to claim (the browser build guards against a second tab here).
Future<void> claimWalletDb() async {}

/// Is there a `wallet.db` (or an interrupted conversion's copy of one) in the app folder?
Future<bool> walletDbExists() async {
  final path = await _path();
  return await File(path).exists() || await File('$path.plain-copy').exists();
}

/// Moves `wallet.db` and its side files to `wallet.db.unopened-<stamp>` (+ the same suffixes), a new stamp when it is taken.
/// Nothing is deleted: the old file stays for whoever has the key that opens it. No-op without a file.
Future<void> setAsideWalletDb(String stamp) async {
  final path = await _path();
  var target = '$path.unopened-$stamp';
  for (var n = 2; await File(target).exists(); n++) {
    target = '$path.unopened-$stamp-$n';
  }
  final main = File(path);
  if (await main.exists()) await main.rename(target);
  for (final s in _sideSuffixes) {
    final f = File('$path$s');
    if (await f.exists()) await f.rename('$target$s');
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

/// `wallet.db` in the app support folder, encrypted with [dbKey] (`localDbKey`). An older plaintext file is converted in place
/// (crash-safe in core). A key that does not open it throws [WalletDbKeyException]; the file is not touched then.
/// [WalletDb.forget] closes it and deletes the file and its side files.
Future<WalletDb> openWalletDb(Uint8List dbKey) async {
  final path = await _path();
  final converted = _isPlaintext(path);
  final repo = WalletRepo.open(path, dbKey: dbKey);
  return WalletDb(repo, converted: converted, forget: () async {
    for (final suffix in ['', ..._sideSuffixes]) {
      final f = File('$path$suffix');
      if (await f.exists()) await f.delete();
    }
  });
}
