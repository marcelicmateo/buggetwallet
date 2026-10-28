// Stage DK spec tests (api 5) for the client side: RelayTransport against the real relay (port 0) and MemoryTransport's
// device views. Written from docs/context/RELAY_PROTOCOL.md api 5 only. All keys and data are SYNTHETIC.
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:relay/relay.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/wallet_sync.dart';

Matcher fails(TransportFailure f) => throwsA(isA<TransportException>().having((e) => e.failure, 'failure', f));

/// Records "METHOD last-path-segment" of every request, then sends it.
class _Counting extends http.BaseClient {
  final http.Client inner = http.Client();
  final List<String> seen = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    seen.add('${request.method} ${request.url.path.split('/').last}');
    return inner.send(request);
  }

  int count(String s) => seen.where((x) => x == s).length;
}

List<int> _seed(int n) => List.generate(32, (i) => (0x50 + n * 11) ^ (i * (n + 3)));

void main() {
  /// Changed (security review): a wallet created by an api-5 app starts locked. The real-relay tests here start from an
  /// unlocked wallet, as before: create, then unlock a few ms later (lock changes apply only when signed later).
  Future<void> createUnlocked(RelayTransport a, List<int> bytes) async {
    await a.put('d1', 1, bytes);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(await a.setLocked(false), isFalse);
  }

  group('RelayTransport against the real relay', () {
    late Directory dir;
    late Relay relay;
    late Uri base;
    late VaultKey key;
    final made = <RelayTransport>[];

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('bw-dk-sync-');
      relay = Relay(data: dir, log: (_) {});
      base = Uri.parse('http://127.0.0.1:${(await relay.serve(port: 0)).port}');
      key = VaultKey.generate();
    });
    tearDown(() async {
      for (final t in made) {
        t.close();
      }
      made.clear();
      await relay.close();
      dir.deleteSync(recursive: true);
    });

    (RelayTransport, _Counting) dev(int n, {VaultKey? k, bool withDeviceKey = true}) {
      final c = _Counting();
      final t = RelayTransport(base, k ?? key, client: c, deviceKey: withDeviceKey ? _seed(n) : null, deviceId: 'dev$n');
      made.add(t);
      return (t, c);
    }

    test('create, unlocked join enrols exactly once; locked join is pending and never loops; approve then syncs', () async {
      final (a, _) = dev(1);
      await createUnlocked(a, [1, 2, 3]);
      final (b, cb) = dev(2);
      expect((await b.state()).devices.keys, contains('d1'));
      expect(cb.seen, ['GET state', 'PUT enrol', 'GET state'], reason: 'one enrol, one retry');
      expect(await a.setLocked(true), isTrue);
      final (c, cc) = dev(3);
      await expectLater(c.state(), fails(TransportFailure.pending));
      expect(cc.count('PUT enrol'), 1);
      expect(cc.seen.where((s) => s == 'GET state').length, 1, reason: 'no retry while pending');
      await expectLater(c.get('d1', 1), fails(TransportFailure.pending));
      expect(cc.count('PUT enrol'), 2, reason: 'one enrol per refused call, never more');
      await a.approveDevice((await c.fingerprint)!);
      expect(await c.get('d1', 1), [1, 2, 3]);
      await c.put('d3', 1, [9]);
    });

    test('after revoke the client stops: one request per call, no enrol, no health check; revoked everywhere', () async {
      final (a, _) = dev(1);
      await createUnlocked(a, [1]);
      final (b, cb) = dev(2);
      await b.state();
      cb.seen.clear();
      await a.revokeDevice((await b.fingerprint)!);
      final calls = <Future<Object?> Function()>[
        b.state,
        () => b.get('d1', 1),
        () => b.put('d2', 1, [1]),
        () => b.ack('d2', {'d1': 1}),
        () => b.getSnapshot('s1'),
        () => b.putSnapshot('s1', {'d1': 1}, [1]),
        () => b.getBlob('0' * 64),
        () => b.putBlob('0' * 64, [1]),
        () => b.putSnapshotBlobs('s1', []),
        b.enrol,
        () => b.approveDevice('AAAA-AAAA'),
        () => b.revokeDevice('AAAA-AAAA'),
        () => b.setLocked(false),
      ];
      for (final call in calls) {
        cb.seen.clear();
        await expectLater(call(), fails(TransportFailure.revoked));
        expect(cb.seen, hasLength(1), reason: 'no retry, no health check: ${cb.seen}');
        expect(cb.count('PUT enrol') + cb.count('GET health'), lessThanOrEqualTo(1));
        expect(cb.seen.single, isNot('GET health'));
      }
      // the others are fine, and the wallet is locked now
      expect((await a.state()).devices.keys, contains('d1'));
    });

    // Changed (security review): a revoke holds the lock for 5 minutes (no unlock signed before then applies), so the
    // way back in here is an approval.
    test('the removed device with only the wallet key cannot get back in; an unlock right after is refused; approval lets a new key in',
        () async {
      final (a, _) = dev(1);
      await createUnlocked(a, [1]);
      final (b, _) = dev(2);
      await b.state();
      await a.revokeDevice((await b.fingerprint)!);
      final (c, _) = dev(3);
      await expectLater(c.state(), fails(TransportFailure.pending));
      await expectLater(c.put('d3', 1, [1]), fails(TransportFailure.pending));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(await a.setLocked(false), isTrue, reason: 'within 5 minutes of a revoke the wallet stays locked');
      await a.approveDevice((await c.fingerprint)!);
      expect((await c.state()).devices.keys, contains('d1'));
      await expectLater(b.state(), fails(TransportFailure.revoked));
    });

    test('the last enrolled device cannot be revoked; revoke of an unknown fingerprint is missing; bad fingerprint rejected', () async {
      final (a, _) = dev(1);
      await createUnlocked(a, [1]);
      await expectLater(a.revokeDevice((await a.fingerprint)!), fails(TransportFailure.lastDevice));
      expect(await a.setLocked(false), isFalse, reason: 'refused revoke did not lock');
      await expectLater(a.revokeDevice('AAAA-AAAA'), fails(TransportFailure.missing));
      await expectLater(a.approveDevice('AAAA-AAAA'), fails(TransportFailure.missing));
      await expectLater(a.approveDevice('nope'), fails(TransportFailure.rejected));
    });

    test('an api-4 client (wallet key) works unlocked; after a lock it stops with newerApi, on every call', () async {
      final (a, _) = dev(1);
      await createUnlocked(a, [1]);
      final (old, co) = dev(9, withDeviceKey: false);
      final s = await old.state();
      expect(s.api, 4);
      await old.put('d1', 2, [2]);
      expect(co.seen.where((x) => x.contains('enrol')), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await a.setLocked(true), isTrue);
      await expectLater(old.state(), fails(TransportFailure.newerApi));
      final (old2, _) = dev(8, withDeviceKey: false);
      await expectLater(old2.put('d1', 3, [3]), fails(TransportFailure.newerApi));
      final (old3, _) = dev(7, withDeviceKey: false);
      await expectLater(old3.get('d1', 1), fails(TransportFailure.newerApi));
      expect((await a.state()).devices['d1']!.last, 2, reason: 'nothing written while locked');
    });

    test('a transport for another wallet (other key) cannot use a revoked/enrolled key of this one', () async {
      final (a, _) = dev(1);
      await createUnlocked(a, [1]);
      // same device key, other wallet: unknown wallet, so state is empty, never someone else's data
      final (other, _) = dev(1, k: VaultKey.generate());
      expect((await other.state()).devices, isEmpty, reason: 'an unknown wallet reads as an empty relay');
      expect((await a.state()).devices.keys, contains('d1'));
    });
  });

  group('MemoryTransport device views', () {
    test('create enrols; join unlocked enrols; revoke locks, revoked everywhere; last device refused', () async {
      final m = MemoryTransport();
      final a = m.device('A'), b = m.device('B');
      await a.put('d1', 1, [1]);
      expect(m.enrolledKeys, {a.fingerprint});
      expect(m.locked, isTrue, reason: 'changed (security review): a created wallet starts locked');
      await a.setLocked(false);
      await expectLater(a.revokeDevice(a.fingerprint), fails(TransportFailure.lastDevice));
      await b.state();
      expect(m.enrolledKeys, {a.fingerprint, b.fingerprint});
      await a.revokeDevice(b.fingerprint);
      expect(m.revokedKeys, {b.fingerprint});
      for (final call in <Future<Object?> Function()>[
        b.state,
        () => b.get('d1', 1),
        () => b.put('d2', 1, [1]),
        () => b.ack('d2', {}),
        () => b.getSnapshot('s'),
        () => b.putSnapshot('s', {'d1': 1}, [1]),
        () => b.getBlob('0' * 64),
        () => b.putBlob('0' * 64, [1]),
        b.enrol,
        () => b.setLocked(false),
        () => b.approveDevice(a.fingerprint),
        () => b.revokeDevice(a.fingerprint),
      ]) {
        await expectLater(call(), fails(TransportFailure.revoked));
      }
      // revoke locked: a new view is pending, the bare wallet-key transport is newerApi
      final c = m.device('C');
      await expectLater(c.state(), fails(TransportFailure.pending));
      await expectLater(m.state(), fails(TransportFailure.newerApi));
      await expectLater(m.put('d1', 2, [2]), fails(TransportFailure.newerApi));
      expect(m.pendingKeys, {c.fingerprint});
      await a.approveDevice(c.fingerprint);
      await c.state();
      expect(m.enrolledKeys, {a.fingerprint, c.fingerprint});
    });

    test('a revoked key can never be approved or re-enrolled; revoking a pending key rejects it; pending cap is 8', () async {
      final m = MemoryTransport();
      final a = m.device('A');
      await a.put('d1', 1, [1]);
      await a.setLocked(true);
      final views = [for (var i = 0; i < 9; i++) m.device('P$i')];
      for (var i = 0; i < 8; i++) {
        await expectLater(views[i].state(), fails(TransportFailure.pending));
      }
      expect(m.pendingKeys, hasLength(8));
      await expectLater(views[8].state(), fails(TransportFailure.pendingFull), reason: 'changed (security review): its own failure');
      expect(m.pendingKeys, hasLength(8), reason: 'the 9th is not kept');
      await a.revokeDevice(views[0].fingerprint);
      expect(m.revokedKeys, {views[0].fingerprint});
      await expectLater(views[0].state(), fails(TransportFailure.revoked));
      await expectLater(a.approveDevice(views[0].fingerprint), fails(TransportFailure.conflict));
      await expectLater(a.approveDevice('AAAA-AAAA'), fails(TransportFailure.missing));
    });

    test('unlocked wallet-key transport works, lock by an enrolled view stops it, unlock reopens it', () async {
      final m = MemoryTransport();
      final a = m.device('A');
      await a.put('d1', 1, [1]);
      await a.setLocked(false); // changed (security review): a created wallet starts locked
      await m.put('d1', 2, [2]);
      expect(await a.setLocked(true), isTrue);
      await expectLater(m.get('d1', 1), fails(TransportFailure.newerApi));
      expect(await a.setLocked(false), isFalse);
      expect(await m.get('d1', 1), [1]);
    });
  });
}
