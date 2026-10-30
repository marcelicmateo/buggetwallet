// HP-R1: "Remove all other devices" against a real relay when this device's clock is behind the relay's. The relay
// spares keys and requests newer than the request's signed time (RELAY_PROTOCOL.md "Device keys"), so the client
// sends `devices/others` again, signed after the newest one left, until only this device remains.
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay/relay.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

/// Synthetic device seeds.
List<int> seed(int n) => List.generate(32, (i) => (n * 0x11) ^ (i * 7 + 1) & 0xff);

Matcher fails(TransportFailure f, [String? message]) =>
    throwsA(isA<TransportException>().having((e) => e.failure, 'failure', f).having((e) => e.message, 'message', message ?? anything));

/// Forwards to [inner]; after each answer to `devices/others` runs [after] (another device acting meanwhile).
class _Interleave extends http.BaseClient {
  _Interleave(this.inner, this.after);

  final http.Client inner;
  final Future<void> Function() after;
  int others = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final r = await inner.send(request);
    if (request.url.path.endsWith('/devices/others')) {
      others++;
      final body = await r.stream.toBytes();
      await after();
      return http.StreamedResponse(Stream.value(body), r.statusCode, headers: r.headers, request: request);
    }
    return r;
  }

  @override
  void close() => inner.close();
}

void main() {
  final key = VaultKey.generate();
  late DateTime relayNow;
  late Uri base;

  setUp(() async {
    relayNow = DateTime.utc(2026, 10, 30, 12);
    final dir = Directory.systemTemp.createTempSync('bw-relay-others-');
    final relay = Relay(data: dir, log: (_) {}, now: () => relayNow);
    final server = await relay.serve(port: 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    addTearDown(() async {
      await relay.close();
      dir.deleteSync(recursive: true);
    });
  });

  RelayTransport transport(List<int> deviceKey, {Duration behind = Duration.zero, http.Client? client}) {
    final t = RelayTransport(base, key, deviceKey: deviceKey, now: () => relayNow.subtract(behind), client: client);
    addTearDown(t.close);
    return t;
  }

  /// A creates the wallet (an api-5 creation starts locked).
  Future<void> create(RelayTransport a) async {
    final repo = WalletRepo.inMemory();
    addTearDown(repo.close);
    repo.updateSettings({'salary': 1});
    await SyncEngine(a, key).run(repo);
  }

  test('a clock 3 min behind the relay: a helper approved 2 min ago and a newer request are removed too', () async {
    const behind = Duration(minutes: 3);
    final a = transport(seed(1), behind: behind);
    await create(a);
    // A helper asks, A approves it now (relay time), then two minutes pass and another device asks.
    final helper = transport(seed(2));
    await expectLater(helper.state(), fails(TransportFailure.pending));
    await a.approveDevice((await helper.fingerprint)!);
    expect((await helper.state()).api, 5, reason: 'enrolled');
    relayNow = relayNow.add(const Duration(minutes: 2));
    final asker = transport(seed(3));
    await expectLater(asker.state(), fails(TransportFailure.pending));
    // A's first `devices/others` is signed 3 min behind the relay: before the approval and the request.
    expect(await a.revokeOthers(), 1);
    await expectLater(helper.state(), fails(TransportFailure.revoked));
    await expectLater(asker.state(), fails(TransportFailure.revoked), reason: 'its request was rejected');
    final s = await a.state();
    expect(s.keys!.where((k) => !k.isRevoked).map((k) => k.self), [true]);
    expect(s.pending, isEmpty);
    expect(s.locked, isTrue);
  });

  test('clocks that agree: one call, the same answer as before', () async {
    final calls = <int>[];
    late _Interleave client;
    client = _Interleave(http.Client(), () async => calls.add(client.others));
    final a = transport(seed(1), client: client);
    await create(a);
    final helper = transport(seed(2));
    await expectLater(helper.state(), fails(TransportFailure.pending));
    await a.approveDevice((await helper.fingerprint)!);
    relayNow = relayNow.add(const Duration(seconds: 1));
    expect(await a.revokeOthers(), 1);
    expect(calls, [1]);
    expect(await a.revokeOthers(), 0, reason: 'nothing left: one more call, nothing removed');
  });

  test('a device that keeps asking between the calls does not make it fail: done once no other key is active', () async {
    var n = 10;
    final askers = <RelayTransport>[];
    late _Interleave client;
    client = _Interleave(http.Client(), () async {
      // A minute later, yet another device asks (newer than the call that was just answered).
      relayNow = relayNow.add(const Duration(minutes: 1));
      final t = transport(seed(n++));
      askers.add(t);
      await expectLater(t.state(), fails(TransportFailure.pending));
    });
    final a = transport(seed(1), behind: const Duration(minutes: 3), client: client);
    await create(a);
    final helper = transport(seed(2));
    await expectLater(helper.state(), fails(TransportFailure.pending));
    await a.approveDevice((await helper.fingerprint)!);
    relayNow = relayNow.add(const Duration(minutes: 1));
    // Round 1 (signed 3 min behind) spares the helper; round 2 revokes it and rejects the request made meanwhile.
    expect(await a.revokeOthers(), 1);
    expect(client.others, 2);
    await expectLater(helper.state(), fails(TransportFailure.revoked));
    await expectLater(askers.first.state(), fails(TransportFailure.revoked));
    expect((await a.state()).pending, hasLength(1), reason: 'the one that asked after the last call waits, enrolled by nobody');
  });

  group('against a stub relay', () {
    const self = '{"fp":"AAAA-AAAA","added":"2026-10-30T12:00:00Z","by":"wallet","revoked":null,"self":true}';
    const other = '{"fp":"BBBB-BBBB","added":"2026-10-30T12:00:00Z","by":"wallet","revoked":null,"self":false}';
    String stateWith(String keys) => '{"api":5,"devices":{},"keys":[$keys],"pending":[],"locked":true}';

    RelayTransport stub(http.Response Function(http.Request r) answer) {
      final t = RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seed(1), client: MockClient((r) async => answer(r)));
      addTearDown(t.close);
      return t;
    }

    test('a key that stays active after 3 calls fails clearly with others remain', () async {
      var calls = 0;
      final t = stub((r) {
        if (r.url.path.endsWith('/devices/others')) {
          calls++;
          return http.Response('{"revoked":0}', 200);
        }
        return http.Response(stateWith('$self,$other'), 200);
      });
      await expectLater(t.revokeOthers(), fails(TransportFailure.other, 'others remain'));
      expect(calls, RelayTransport.revokeOthersRounds);
    });

    test('HP-R1c: a state read that fails after an accepted call fails the call (never "done" unchecked)', () async {
      final t = stub(
          (r) => r.url.path.endsWith('/devices/others') ? http.Response('{"revoked":2}', 200) : http.Response('{"error":"internal"}', 500));
      await expectLater(t.revokeOthers(), fails(TransportFailure.other));
    });

    test('pending requests alone: one call, done', () async {
      var calls = 0;
      final t = stub((r) {
        if (r.url.path.endsWith('/devices/others')) {
          calls++;
          return http.Response('{"revoked":1}', 200);
        }
        return http.Response(
            '{"api":5,"devices":{},"keys":[$self],"pending":[{"fp":"CCCC-CCCC","at":"2026-10-30T12:00:00Z"}],"locked":true}', 200);
      });
      expect(await t.revokeOthers(), 1);
      expect(calls, 1);
    });
  });
}
