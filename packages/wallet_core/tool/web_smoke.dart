// Web compile check for the wallet_core barrel: this file must compile with dart2js and dart2wasm, which fails if
// anything the barrel exports pulls in dart:io, dart:ffi or the native sqlite3 library. It is never run; the
// database it would need is the WASM one the web app opens (`package:sqlite3/wasm.dart`).
//
//   tools/build.sh shell -c 'cd packages/wallet_core && dart pub get && dart compile js -o /tmp/web_smoke.js tool/web_smoke.dart \
//     && dart compile wasm -o /tmp/web_smoke.wasm tool/web_smoke.dart'
import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:wallet_core/wallet_core.dart';

Future<void> main(List<String> args) async {
  final log = Logger('bw.smoke');
  final key = VaultKey.generate();
  final sealed = await seal(utf8.encode('[]'), key, aad: aadBackup);
  final clear = await unseal(sealed, key, aad: aadBackup);
  final sink = MemoryLogSink()..add('web smoke: ${clear.length} bytes');
  if (args.isEmpty) {
    // Not reached when run without a database; here only so the symbols are used.
    logEvent(log, Level.INFO, 'web.smoke', {'lines': sink.lines.length, 'name': backupFileName('2026-01-01')});
    return;
  }
  final db = args.first as CommonDatabase; // a real caller passes a WASM database
  final dbKey = await localDbKey(key);
  final repo = WalletRepo.fromDatabase(openKeyed(() => db, dbKey), file: false);
  final Uint8List bytes = await backupBytes(repo, key);
  final ops = await restoreBackupBytes(repo, bytes, key);
  final SyncTransport transport = args.length > 1 ? RelayTransport(Uri.parse(args[1]), key) : MemoryTransport();
  final report = await SyncEngine(transport, key).run(repo);
  logEvent(log, Level.INFO, 'web.smoke.sync', {'caughtUp': report.caughtUp, 'id': (await deriveKey(key, 'smoke')).length});
  final ics = parseIcs(plannedIcs(repo.plannedCosts(), const [], from: '2026-01-01', to: '2026-12-31'),
      calendarId: 'smoke', from: '2026-01-01', to: '2026-12-31', toLocal: (t) => t.toLocal());
  logEvent(log, Level.INFO, 'web.smoke.ics', {'events': ics.events.length, 'ref': calendarRef('c', 'u', '2026-01-01').length});
  logEvent(log, Level.INFO, 'web.smoke', {
    'rows': repo.transactions().length,
    'ops': ops,
    'failures': BackupFailure.values.length,
    'bad': const SyncReport(0, 0, 0).badFiles,
  });
  repo.close();
}
