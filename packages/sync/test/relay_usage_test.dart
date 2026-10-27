// Stage I (IC): relay usage — `GET state` `bytes`/`maxBytes` (RELAY_PROTOCOL.md "State JSON"), RelayState.bytes/maxBytes,
// SyncReport.relayBytes/relayMaxBytes, filled by MemoryTransport. SYNTHETIC data only.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

import '../../wallet_core/test/support/sim.dart';

void main() {
  group('RelayState.fromJson', () {
    test('reads bytes and maxBytes; an older relay without them gives null', () {
      final s = RelayState.fromJson({'devices': <String, Object?>{}, 'bytes': 2048, 'maxBytes': 1 << 30});
      expect((s.bytes, s.maxBytes), (2048, 1 << 30));
      final old = RelayState.fromJson({'devices': <String, Object?>{}});
      expect((old.bytes, old.maxBytes), (null, null));
      expect((RelayState.empty.bytes, RelayState.empty.maxBytes), (null, null));
    });

    test('a value that is not a non-negative integer is unknown (null), never a failed sync', () {
      for (final bad in [-1, 1.5, '10', true, <String, Object?>{}]) {
        final s = RelayState.fromJson({'devices': <String, Object?>{}, 'bytes': bad, 'maxBytes': bad});
        expect((s.bytes, s.maxBytes), (null, null), reason: '$bad');
      }
      final one = RelayState.fromJson({'devices': <String, Object?>{}, 'bytes': 0, 'maxBytes': 'x'});
      expect((one.bytes, one.maxBytes), (0, null));
    });

    test('toJson round-trips them and leaves them out when unknown', () {
      const s = RelayState(bytes: 10, maxBytes: 100);
      final back = RelayState.fromJson(jsonDecode(jsonEncode(s.toJson())));
      expect((back.bytes, back.maxBytes), (10, 100));
      expect(RelayState.empty.toJson().keys, isNot(anyOf(contains('bytes'), contains('maxBytes'))));
    });
  });

  group('MemoryTransport and SyncReport', () {
    test('the memory relay reports files + snapshots + blobs and its limit once the wallet exists', () async {
      final relay = MemoryTransport();
      var s = await relay.state();
      expect((s.bytes, s.maxBytes), (null, null), reason: 'a wallet the relay does not know yet');
      await relay.put('dev1', 1, List.filled(30, 1));
      await relay.put('dev1', 2, List.filled(12, 2));
      relay.maxBytes = 5000;
      s = await relay.state();
      expect((s.bytes, s.maxBytes), (42, 5000));
      expect(relay.storedBytes, 42);
      relay.maxBytes = null; // an older relay
      s = await relay.state();
      expect((s.bytes, s.maxBytes), (null, null));
    });

    test('a sync run reports the relay usage of its state read', () async {
      final net = Net();
      final a = Device('a', null, VaultKey.generate(), () => 1767225600000, net: net);
      addTearDown(a.close);
      a.repo.updateSettings({'salary': 1});
      final first = await a.run();
      // The upload created the wallet, so the run read state again: its own file is counted.
      expect(first.relayMaxBytes, net.relay.maxBytes);
      expect(first.relayBytes, net.relay.storedBytes, reason: 'exactly the file the run uploaded (nothing stored after the re-read)');
      expect(first.relayBytes, greaterThan(0));
      final before = net.relay.storedBytes;
      final second = await a.run();
      expect((second.relayBytes, second.relayMaxBytes), (before, net.relay.maxBytes), reason: 'the state read at the start of the run');
      net.relay.maxBytes = null;
      final old = await a.run();
      expect((old.relayBytes, old.relayMaxBytes), (null, null), reason: 'an older relay: unknown');
    });
  });
}
