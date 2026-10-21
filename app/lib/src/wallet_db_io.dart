import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:wallet_core/wallet_core.dart';

import 'wallet_db_base.dart';

/// `wallet.db` in the app support folder. [WalletDb.forget] closes it and deletes the file (and SQLite's side files).
Future<WalletDb> openWalletDb() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final path = '${dir.path}${Platform.pathSeparator}wallet.db';
  final repo = WalletRepo.open(path);
  return WalletDb(repo, forget: () async {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final f = File('$path$suffix');
      if (await f.exists()) await f.delete();
    }
  });
}
