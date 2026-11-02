// Web compile check for the wallet_sync barrel: this file must compile with dart2js and dart2wasm, which fails if
// anything the barrel exports pulls in dart:io, dart:ffi or the native sqlite3 library. It is never run; the
// database it would need is the WASM one the web app opens (`package:sqlite3/wasm.dart`).
//
//   make shell C='cd packages/sync && dart pub get && dart compile js -o /tmp/web_smoke.js tool/web_smoke.dart \
//     && dart compile wasm -o /tmp/web_smoke.wasm tool/web_smoke.dart'
import 'dart:typed_data';

import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

Future<void> main(List<String> args) async {
  final log = Logger('bw.smoke');
  final key = VaultKey.generate();
  if (args.isEmpty) {
    // Not reached when run without a database; here only so the symbols are used.
    logEvent(log, Level.INFO, 'web.smoke', {'bad': const SyncReport(0, 0, 0).badFiles});
    return;
  }
  final db = args.first as CommonDatabase; // a real caller passes a WASM database
  final repo = WalletRepo.fromDatabase(openKeyed(() => db, await localDbKey(key)), file: false);
  final SyncTransport transport = args.length > 1 ? RelayTransport(Uri.parse(args[1]), key) : MemoryTransport();
  final report = await SyncEngine(transport, key).run(repo);
  final file = await BlobStore(repo, key).add(Uint8List(1), 'jpg');
  logEvent(log, Level.INFO, 'web.smoke.sync', {'caughtUp': report.caughtUp, 'bytes': file.bytes});
  repo.close();
}
