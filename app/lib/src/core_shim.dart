// TEMPORARY: names the web-core branch adds to wallet_core. Delete this file when web-core is merged:
// remove `import 'core_shim.dart'` (controller.dart, log_backend_web.dart, wallet_db_web.dart and the tests that import it)
// and call `WalletRepo.fromDatabase(db, file: true)` instead of `walletRepoFromDatabase`. If both exist, the import is ambiguous
// and the analyzer says so.
import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/common.dart';
import 'package:wallet_core/wallet_core.dart';

/// TODO(web-core): `WalletRepo.fromDatabase(db, file: file)`.
WalletRepo walletRepoFromDatabase(CommonDatabase db, {required bool file}) =>
    throw UnimplementedError('WalletRepo.fromDatabase comes with web-core');

/// TODO(web-core): core's `backupFileName`.
String backupFileName(String today) => 'bw-backup-$today.bwb';

/// TODO(web-core): core's `backupBytes` (same bytes as `writeBackup` puts in a file).
Future<Uint8List> backupBytes(WalletRepo repo, VaultKey key) async {
  final payload = utf8.encode(jsonEncode({
    'v': backupVersion,
    'ops': [for (final op in repo.snapshotOps()) op.toJson()]
  }));
  return seal(payload, key);
}

/// TODO(web-core): core's `restoreBackupBytes` (same errors as `restoreBackup`).
Future<int> restoreBackupBytes(WalletRepo repo, Uint8List bytes, VaultKey key) =>
    throw UnimplementedError('restoreBackupBytes comes with web-core');

/// TODO(web-core): core's `LogSink`.
abstract interface class LogSink {
  void add(String line);
  Future<void> flush();
  Future<void> close();
}

/// TODO(web-core): core's `MemoryLogSink`: keeps the newest lines, at most [maxBytes] of text.
class MemoryLogSink implements LogSink {
  final int maxBytes;
  final List<String> _lines = [];
  int _bytes = 0;

  /// Lines dropped to stay under [maxBytes].
  int dropped = 0;
  MemoryLogSink({this.maxBytes = 1024 * 1024});

  List<String> get lines => List.unmodifiable(_lines);

  @override
  void add(String line) {
    _lines.add(line);
    _bytes += line.length + 1;
    while (_bytes > maxBytes && _lines.length > 1) {
      _bytes -= _lines.removeAt(0).length + 1;
      dropped++;
    }
  }

  String dump() => _lines.isEmpty ? '' : '${_lines.join('\n')}\n';

  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
}
