// H1: invariants that killed survivors of the mutation run over the device parts of sync_relay.dart / sync_memory.dart
// (RELAY_PROTOCOL.md api 5). All data and keys are SYNTHETIC.
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

Matcher fails(TransportFailure f) => throwsA(isA<TransportException>().having((e) => e.failure, 'failure', f));

void main() {
  final key = VaultKey.generate();
  final seed = List.generate(32, (i) => 0x11 ^ (i * 7));

  test('signedHost: the port is named unless it is the scheme default (80 for http, 443 for https)', () {
    String h(String u) => RelayTransport.signedHost(Uri.parse(u));
    expect(h('http://Relay.Test/x'), 'relay.test');
    expect(h('http://relay.test:80/x'), 'relay.test');
    expect(h('http://relay.test:81/x'), 'relay.test:81');
    expect(h('http://relay.test:443/x'), 'relay.test:443');
    expect(h('https://relay.test:443/x'), 'relay.test');
    expect(h('https://relay.test:80/x'), 'relay.test:80');
    expect(h('https://relay.test:444/x'), 'relay.test:444');
    expect(h('http://[::1]:8080/x'), '[::1]:8080');
  });

  group('revokeOthers answer', () {
    Future<Object?> run(String body) async {
      final t =
          RelayTransport(Uri.parse('http://relay.test'), key, deviceKey: seed, client: MockClient((r) async => http.Response(body, 200)));
      addTearDown(t.close);
      try {
        return await t.revokeOthers();
      } on TransportException catch (e) {
        return e.failure;
      }
    }

    test('only {"revoked": int} is an answer; anything else is "other", never a crash', () async {
      expect(await run('{"revoked":3}'), 3);
      expect(await run('{"revoked":0}'), 0);
      expect(await run('[]'), TransportFailure.other);
      expect(await run('[1,2]'), TransportFailure.other);
      expect(await run('"x"'), TransportFailure.other);
      expect(await run('{"revoked":"3"}'), TransportFailure.other);
      expect(await run('{}'), TransportFailure.other);
      expect(await run('not json'), TransportFailure.other);
    });
  });

  group('MemoryTransport counts every device call once', () {
    test('a normal call and a revoked call each add exactly 1 to calls[kind]', () async {
      var now = DateTime.utc(2026, 10, 1);
      final m = MemoryTransport(now: () => now);
      final va = m.device('key-a'), vb = m.device('key-b');
      await va.put('a', 1, [1]);
      await expectLater(vb.state(), fails(TransportFailure.pending));
      await va.approveDevice(vb.fingerprint);
      now = now.add(const Duration(seconds: 1));
      await vb.state();
      final before = m.calls['state'] ?? 0;
      await va.state();
      expect(m.calls['state'], before + 1);
      await va.state();
      expect(m.calls['state'], before + 2);
      await va.revokeDevice(vb.fingerprint);
      final c = m.calls['state'] ?? 0;
      await expectLater(vb.state(), fails(TransportFailure.revoked));
      expect(m.calls['state'], c + 1, reason: 'a revoked call is counted once');
      await expectLater(vb.state(), fails(TransportFailure.revoked));
      expect(m.calls['state'], c + 2);
    });
  });
}
