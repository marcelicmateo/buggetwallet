// HP-T1: invariants of the relay client found by mutation testing (status boundaries, no-downgrade rule, minApi,
// HTTP date limits, reader version). All data and keys are SYNTHETIC.
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

void main() {
  final key = VaultKey.generate();
  final seed = List.generate(32, (i) => 0x21 ^ (i * 5));
  final base = Uri.parse('http://relay.test');

  RelayTransport make(http.Client c, {int? minApi, List<int>? deviceKey, void Function(int, String?)? onMinApi}) =>
      RelayTransport(base, key, deviceKey: deviceKey, client: c, minApi: minApi ?? 3, onMinApi: onMinApi);

  group('only 2xx is success', () {
    for (final (status, ok) in [(199, false), (200, true), (204, true), (299, true), (300, false), (301, false), (399, false)]) {
      test('status $status ${ok ? 'is' : 'is not'} an answer', () async {
        final t = make(MockClient((r) async => http.Response('{"api":4}', status)));
        addTearDown(t.close);
        if (ok) {
          expect((await t.state()).devices, isEmpty);
        } else {
          await expectLater(t.state(), throwsA(isA<TransportException>()));
        }
      });
    }
  });

  group('no downgrade (a 401 that is not clock/revoked/unenrolled asks health)', () {
    Future<(Object, int)> run(int minApi, int healthApi) async {
      var states = 0;
      final t = make(MockClient((r) async {
        if (r.url.path.endsWith('/health')) return http.Response('{"api":$healthApi}', 200);
        states++;
        return states == 1 ? http.Response('{"error":"signature"}', 401) : http.Response('{"api":4,"devices":{}}', 200);
      }), deviceKey: seed, minApi: minApi);
      addTearDown(t.close);
      try {
        return (await t.state(), states);
      } on TransportException catch (e) {
        return (e.failure, states);
      }
    }

    test('health equal to minApi (4) is not a downgrade: sign as api 4 and ask again', () async {
      final (r, states) = await run(4, 4);
      expect(r, isA<RelayState>());
      expect(states, 2);
    });

    test('health below minApi is olderApi, never a retry', () async {
      final (r, states) = await run(5, 4);
      expect(r, TransportFailure.olderApi);
      expect(states, 1);
    });
  });

  group('minApi rises to 5 once, on a state that says api 5 to a device-key transport', () {
    Future<List<(int, String?)>> run({required int api, List<int>? deviceKey, int minApi = 3}) async {
      final calls = <(int, String?)>[];
      final t = make(MockClient((r) async => http.Response('{"api":$api,"instance":"${'cd' * 16}"}', 200)),
          deviceKey: deviceKey, minApi: minApi, onMinApi: (m, i) => calls.add((m, i)));
      addTearDown(t.close);
      await t.state();
      await t.state();
      expect(t.minApi, calls.isEmpty ? minApi : 5);
      return calls;
    }

    test('api 5 with a device key: told once with the instance', () async {
      expect(await run(api: 5, deviceKey: seed), [(5, 'cd' * 16)]);
    });
    test('api 4, or already 5: never told', () async {
      expect(await run(api: 4, deviceKey: seed), isEmpty);
      expect(await run(api: 5, deviceKey: seed, minApi: 5), isEmpty);
    });
  });

  group('parseHttpDate limits', () {
    test('field boundaries', () {
      expect(parseHttpDate('Thu, 22 Oct 2026 10:00:00 GMT'), DateTime.utc(2026, 10, 22, 10));
      expect(parseHttpDate('Thu, 22 Oct 2026 23:59:59 GMT'), DateTime.utc(2026, 10, 22, 23, 59, 59));
      expect(parseHttpDate('Thu, 22 Oct 2026 24:00:00 GMT'), isNull);
      expect(parseHttpDate('Thu, 22 Oct 2026 10:60:00 GMT'), isNull);
      expect(parseHttpDate('Thu, 22 Oct 2026 10:59:00 GMT'), isNotNull);
      expect(parseHttpDate('Thu, 22 Oct 2026 10:00:61 GMT'), isNull);
      expect(parseHttpDate('Thu, 00 Oct 2026 10:00:00 GMT'), isNull);
      expect(parseHttpDate('Thu, 32 Oct 2026 10:00:00 GMT'), isNull);
      expect(parseHttpDate('Sat, 31 Oct 2026 10:00:00 GMT'), DateTime.utc(2026, 10, 31, 10));
      expect(parseHttpDate('Thu, 22 Foo 2026 10:00:00 GMT'), isNull);
      expect(parseHttpDate('Thu, 22 Jan 2026 10:00:00 GMT'), DateTime.utc(2026, 1, 22, 10));
      expect(parseHttpDate('Thu, 22 Dec 2026 10:00:00 GMT'), DateTime.utc(2026, 12, 22, 10));
      expect(parseHttpDate('  Thu, 22 Oct 2026 10:00:00 GMT  '), isNotNull);
      expect(parseHttpDate('Thu, 22 Oct 2026 10:00:00 UTC'), isNull);
    });
  });

  test('syncReaderVersion is 3 (BWOP3): a bump is a deliberate format change that must update this test', () {
    expect(syncReaderVersion, 3);
  });
}
