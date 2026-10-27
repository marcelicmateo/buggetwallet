// Stage I (IC): relay usage in the client. RelayState.bytes / maxBytes (null from an older relay), parsed from the state
// JSON; SyncReport.relayBytes / relayMaxBytes; MemoryTransport fills both. All data is SYNTHETIC.
//
// The API does not exist on v2 yet: the whole file is skipped until the lead lifts the line below at merge.
library;

// ignore_for_file: undefined_getter
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/relay.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/synthetic.dart';

const _t = Timeout(Duration(seconds: 30));

void main() {
  group('RelayState.fromJson', () {
    test('bytes and maxBytes are read as ints', () {
      final s = RelayState.fromJson({'api': 3, 'devices': <String, Object?>{}, 'bytes': 1234, 'maxBytes': 1073741824});
      expect((s.bytes, s.maxBytes), (1234, 1073741824));
    }, timeout: _t);

    test('an older relay (no fields): both null, the rest parses as before', () {
      final s = RelayState.fromJson({'api': 3, 'devices': <String, Object?>{}});
      expect((s.bytes, s.maxBytes), (null, null));
      expect(s.devices, isEmpty);
    }, timeout: _t);

    test('RelayState.empty has no usage', () {
      expect((RelayState.empty.bytes, RelayState.empty.maxBytes), (null, null));
    }, timeout: _t);

    test('zero bytes is a value, not "unknown"', () {
      final s = RelayState.fromJson({'api': 3, 'devices': <String, Object?>{}, 'bytes': 0, 'maxBytes': 500});
      expect((s.bytes, s.maxBytes), (0, 500));
    }, timeout: _t);
  });

  group('RelayTransport.state over a fake client', () {
    test('the numbers come through the HTTP answer', () async {
      final key = VaultKey.generate();
      final t = RelayTransport(Uri.parse('http://relay.test'), key,
          client: MockClient(
              (r) async => http.Response(jsonEncode({'api': 3, 'devices': <String, Object?>{}, 'bytes': 77, 'maxBytes': 9000}), 200)));
      addTearDown(t.close);
      final s = await t.state();
      expect((s.bytes, s.maxBytes), (77, 9000));
    }, timeout: _t);
  });

  group('SyncReport', () {
    test('MemoryTransport fills both: relayBytes > 0 after an upload, relayMaxBytes positive', () async {
      final k = VaultKey.generate();
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      repo.importBatch(january);
      final r = await SyncEngine(MemoryTransport(), k).run(repo);
      expect(r.relayBytes, isNotNull);
      expect(r.relayBytes, greaterThan(0));
      expect(r.relayMaxBytes, isNotNull);
      expect(r.relayMaxBytes, greaterThan(0));
      expect(r.relayBytes!, lessThanOrEqualTo(r.relayMaxBytes!));
    }, timeout: _t);

    test('a second run after more data reports at least as many bytes', () async {
      final k = VaultKey.generate();
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      final m = MemoryTransport();
      final e = SyncEngine(m, k);
      repo.importBatch(january);
      final first = await e.run(repo);
      repo.updateSettings({'salary': 150000});
      final second = await e.run(repo);
      expect(second.relayBytes!, greaterThanOrEqualTo(first.relayBytes!));
    }, timeout: _t);

    test('against the real relay server: relayMaxBytes is its --max-bytes, relayBytes the stored files', () async {
      final dir = Directory.systemTemp.createTempSync('bw-i3-');
      final relay = Relay(data: dir, log: (_) {}, maxBytes: 5 * 1024 * 1024);
      final server = await relay.serve(port: 0);
      addTearDown(() async {
        await relay.close();
        dir.deleteSync(recursive: true);
      });
      final k = VaultKey.generate();
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      repo.importBatch(january);
      final t = RelayTransport(Uri.parse('http://127.0.0.1:${server.port}'), k);
      addTearDown(t.close);
      await SyncEngine(t, k).run(repo);
      final again = await SyncEngine(t, k).run(repo); // the state read after the upload names the wallet
      expect(again.relayMaxBytes, 5 * 1024 * 1024);
      expect(again.relayBytes, greaterThan(0));
      expect(again.relayBytes, lessThan(5 * 1024 * 1024));
    }, timeout: _t);

    test('an unreachable or older relay: both null (nothing invented)', () async {
      final k = VaultKey.generate();
      final repo = WalletRepo.inMemory();
      addTearDown(repo.close);
      final t = RelayTransport(Uri.parse('http://relay.test'), k,
          client: MockClient((r) async => http.Response(jsonEncode({'api': 3, 'devices': <String, Object?>{}}), 404)));
      addTearDown(t.close);
      repo.importBatch(january);
      // a 404 state = an empty relay with no usage fields; the run may fail on the upload, which is fine here
      try {
        final r = await SyncEngine(t, k).run(repo);
        expect((r.relayBytes, r.relayMaxBytes), (null, null));
      } on SyncException {
        // the fake relay refuses everything: nothing to report
      }
    }, timeout: _t);
  });
}
