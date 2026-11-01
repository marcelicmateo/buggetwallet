// Web-safe sync (§4.8): the sync types and the engine are exported and no sync file imports dart:io (the barrel must
// compile with dart2js and dart2wasm; tool/web_smoke.dart is the compile check). Moved from wallet_core's
// web_core_test.dart in J4. All data is SYNTHETIC.
import 'dart:io' show File;

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

void main() {
  group('web-safe sync types', () {
    test('SyncReport, SyncException and the engine are exported (no dart:io in the engine)', () {
      const r = SyncReport(1, 2, 3, problems: [SyncProblem('abcdef01', SyncProblemReason.badKey, bytes: 10)]);
      expect(r.badFiles, 1);
      expect(r.problemsByDevice, {'abcdef01': 1});
      expect([r.caughtUp, r.waiting.isEmpty, r.devices.isEmpty], [false, true, true]);
      expect(const SyncException('x').toString(), 'x');
      expect(SyncEngine(MemoryTransport(), VaultKey.generate(), appVersion: '1.2').build, endsWith('+1.2'));
      for (final f in [
        'sync_engine.dart',
        'sync_memory.dart',
        'sync_relay.dart',
        'sync.dart',
        'sync_problems.dart',
        'sync_blocked.dart',
        'blob_store.dart',
        'ecb_fetch.dart'
      ]) {
        expect(File('lib/src/$f').readAsStringSync(), isNot(contains("import 'dart:io'")), reason: f);
      }
    });

    test('describeError logs a SyncException as its text (LogSafeError, J4)', () {
      expect(const SyncException('The relay is full.'), isA<LogSafeError>());
      expect(describeError(const SyncException('The relay is full.')), 'The relay is full.');
      expect(describeError(const VaultException('Wrong key.')), 'Wrong key.');
    });
  });
}
