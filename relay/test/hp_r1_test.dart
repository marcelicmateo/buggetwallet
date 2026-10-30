// Stage HP-R1: findings of the adversarial relay review before the relay faces the internet (slow bodies, open
// requests, streamed answers, device cap, minimum file cost, IPv6 /64 keys, `first` after a restart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:relay/relay.dart';
import 'package:test/test.dart';

import 'support.dart';

const String attacker = '198.51.100.7';
const String other = '203.0.113.9';

Future<String> hashOf(List<int> b) async => [for (final x in (await Sha256().hash(b)).bytes) x.toRadixString(16).padLeft(2, '0')].join();

Uint8List noise(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

/// A raw HTTP/1.1 connection: the request head with [headers] and `Content-Length: [length]` (when > 0), then [part]
/// of the body. What the relay answers is collected; [closed] completes when the relay closes the connection.
class Raw {
  Raw._(this.socket, {bool read = true}) {
    sub = socket.listen((b) {
      received.addAll(b);
      if (!answered.isCompleted && latin1.decode(received).contains('\r\n\r\n')) answered.complete();
    }, onDone: _done, onError: (Object _) => _done());
    if (!read) sub.pause();
  }

  final Socket socket;
  late final StreamSubscription<Uint8List> sub;
  final List<int> received = [];
  final Completer<void> closed = Completer<void>();

  /// The answer's status line and headers arrived.
  final Completer<void> answered = Completer<void>();

  void _done() {
    if (!closed.isCompleted) closed.complete();
    if (!answered.isCompleted) answered.complete();
  }

  static Future<Raw> open(Harness h, String method, String path,
      {int length = 0, List<int> part = const [], Map<String, String> headers = const {}, bool read = true}) async {
    final raw = Raw._(await Socket.connect('127.0.0.1', h.server.port), read: read);
    final head = [for (final e in headers.entries) '${e.key}: ${e.value}\r\n'].join();
    raw.socket.write('$method $path HTTP/1.1\r\nHost: ${h.base.authority}\r\n$head${length > 0 ? 'Content-Length: $length\r\n' : ''}\r\n');
    await raw.send(part);
    return raw;
  }

  Future<void> send(List<int> more) async {
    socket.add(more);
    await socket.flush();
  }

  int get status => int.parse(latin1.decode(received).split(' ')[1]);

  String get text => latin1.decode(received);
}

/// Completes when [Relay.onOpen] reports [n] open requests of one address.
Future<void> openReaches(Harness h, int n) {
  final c = Completer<void>();
  h.relay.onOpen = (open) {
    if (open == n && !c.isCompleted) c.complete();
  };
  return c.future.timeout(const Duration(seconds: 10));
}

/// Completes after [n] calls of [Relay.onOpen] (requests counted or done).
Future<void> openCalls(Harness h, int n) {
  final c = Completer<void>();
  var calls = 0;
  h.relay.onOpen = (_) {
    if (++calls == n && !c.isCompleted) c.complete();
  };
  return c.future.timeout(const Duration(seconds: 10));
}

void main() {
  group('slow bodies (finding 1)', () {
    test('slow PUTs without a create token are cut off at the body deadline; health answers throughout; the per-address cap is 429',
        () async {
      final h = await Harness.start(
          createToken: 'synthetic-token', trustProxy: true, bodyTimeout: const Duration(milliseconds: 300), maxOpenPerClient: 3);
      addTearDown(h.stop);
      const path = '/v2/w/$w1/d/a/1';
      final sig = await h.sign(keyA, 'PUT', path, Uint8List(0));
      final opened = openReaches(h, 3);
      final slow = [
        for (var i = 0; i < 3; i++)
          await Raw.open(h, 'PUT', path, length: 30000000, part: [0], headers: {...sig, 'x-forwarded-for': attacker}),
      ];
      await opened;
      h.relay.onOpen = null;
      expect((await h.get('/v2/health')).statusCode, 200);
      // Another address is not affected by the attacker's open requests.
      expect((await h.get('/v2/w/$w2/state', key: keyA, headers: {'x-forwarded-for': other})).statusCode, 404);
      final fourth = await h.send('PUT', path, key: keyA, body: bytes('x'), headers: {'x-forwarded-for': attacker});
      expect(fourth.statusCode, 429);
      expect(jsonDecode(fourth.body), {'error': 'too many open requests'});
      for (final s in slow) {
        await s.closed.future.timeout(const Duration(seconds: 10));
        expect(s.text, isEmpty); // cut off: the relay stops reading and drops the connection, no answer
        s.socket.destroy();
      }
      expect((await h.get('/v2/health')).statusCode, 200);
      // The slots are free again.
      expect((await h.send('PUT', path, key: keyA, body: bytes('x'), headers: {'x-forwarded-for': attacker})).statusCode, 403);
      expect(
          h.logs.where((l) => l == 'relay put-d 403 0 w=${w1.substring(0, 6)} d=a'), hasLength(4)); // the 3 slow ones and the last request
      expect(h.logs.join('\n'), isNot(contains(attacker)));
    });

    test('a stalled body is dropped (logged 429 slow); one that keeps up with minBodyRate goes on past bodyTimeout', () async {
      final h = await Harness.start(bodyTimeout: const Duration(milliseconds: 300), minBodyRate: 1000);
      addTearDown(h.stop);
      expect((await h.putData(w1, 'dev1', 1, 'a')).statusCode, 201);
      const stalledPath = '/v2/w/$w1/d/dev1/2';
      final stalled =
          await Raw.open(h, 'PUT', stalledPath, length: 5000, part: [0], headers: await h.sign(keyA, 'PUT', stalledPath, Uint8List(5000)));
      // 1500 bytes buy 1.5 s on top of the 300 ms.
      const steadyPath = '/v2/w/$w1/d/dev2/1';
      final steady = await Raw.open(h, 'PUT', steadyPath,
          length: 3000, part: Uint8List(1500), headers: await h.sign(keyA, 'PUT', steadyPath, Uint8List(3000)));
      await stalled.closed.future.timeout(const Duration(seconds: 10));
      expect(stalled.text, isEmpty);
      expect(steady.closed.isCompleted, isFalse);
      await steady.send(Uint8List(1500));
      await steady.answered.future.timeout(const Duration(seconds: 10));
      expect(steady.status, 201);
      steady.socket.destroy();
      stalled.socket.destroy();
      expect(h.logs, contains('relay put-d!slow 429 1 w=${w1.substring(0, 6)} d=dev1'));
    });

    test('a connection that never finishes its request headers is closed after the idle timeout', () async {
      final h = await Harness.start(idleTimeout: const Duration(milliseconds: 200));
      addTearDown(h.stop);
      final s = await Socket.connect('127.0.0.1', h.server.port);
      final got = <int>[];
      final closed = Completer<void>();
      s.listen(got.addAll, onDone: closed.complete, onError: (Object _) => closed.complete());
      s.write('GET /v2/hea');
      await s.flush();
      await closed.future.timeout(const Duration(seconds: 10));
      expect(got, isEmpty);
      s.destroy();
      expect((await h.get('/v2/health')).statusCode, 200);
    });

    test('the relay-wide cap on open requests is 429 for any address', () async {
      final h = await Harness.start(createToken: 'synthetic-token', trustProxy: true, maxOpen: 2);
      addTearDown(h.stop);
      const path = '/v2/w/$w1/d/a/1';
      final sig = await h.sign(keyA, 'PUT', path, Uint8List(0));
      final opened = openCalls(h, 2);
      final a = await Raw.open(h, 'PUT', path, length: 1000, part: [0], headers: {...sig, 'x-forwarded-for': attacker});
      final b = await Raw.open(h, 'PUT', path, length: 1000, part: [0], headers: {...sig, 'x-forwarded-for': '192.0.2.1'});
      await opened;
      h.relay.onOpen = null;
      expect((await h.get('/v2/w/$w2/state', key: keyA, headers: {'x-forwarded-for': other})).statusCode, 429);
      expect((await h.get('/v2/health', headers: {'x-forwarded-for': other})).statusCode, 200);
      a.socket.destroy();
      b.socket.destroy();
    });
  });

  group('streamed answers (finding 4)', () {
    late Harness h;
    setUp(() async {
      h = await Harness.start();
      addTearDown(h.stop);
    });

    Future<void> same(String path, Uint8List want) async {
      final g = await h.get(path, key: keyA);
      expect(g.statusCode, 200);
      expect(g.headers['content-type'], 'application/octet-stream');
      expect(g.bodyBytes, want);
      final head = await h.send('HEAD', path, key: keyA);
      expect(head.statusCode, 200);
      expect(head.headers['content-length'], '${want.length}');
      expect(head.bodyBytes, isEmpty);
    }

    test('data, snapshot and blob answers are byte for byte the stored files (several chunks), HEAD has the length', () async {
      final data = noise(300 * 1024 + 7, 1);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: data)).statusCode, 201);
      await same('/v2/w/$w1/d/dev1/1', data);
      final snap = noise(200 * 1024 + 3, 2);
      expect((await h.send('PUT', '/v2/w/$w1/snapshot/s1', key: keyA, body: snap, headers: {'x-bw-covers': '{"dev1":1}'})).statusCode, 201);
      await same('/v2/w/$w1/snapshot/s1', snap);
      final blob = noise(100 * 1024 + 1, 3);
      final hash = await hashOf(blob);
      expect((await h.send('PUT', '/v2/w/$w1/blob/$hash', key: keyA, body: blob)).statusCode, 201);
      await same('/v2/w/$w1/blob/$hash', blob);
      final empty = Uint8List(0);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev2/1', key: keyA, body: empty)).statusCode, 201);
      await same('/v2/w/$w1/d/dev2/1', empty);
    });

    test('replays compare with the stored file without reading it whole: same bytes 200, other bytes 409', () async {
      final data = noise(150 * 1024, 4);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: data)).statusCode, 201);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: data)).statusCode, 200);
      final flipped = Uint8List.fromList(data)..[data.length - 1] ^= 1;
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: flipped)).statusCode, 409);
      expect((await h.send('PUT', '/v2/w/$w1/d/dev1/1', key: keyA, body: data.sublist(1))).statusCode, 409);
      final snap = noise(90 * 1024, 5);
      final covers = {'x-bw-covers': '{"dev1":1}'};
      expect((await h.send('PUT', '/v2/w/$w1/snapshot/s1', key: keyA, body: snap, headers: covers)).statusCode, 201);
      expect((await h.send('PUT', '/v2/w/$w1/snapshot/s1', key: keyA, body: snap, headers: covers)).statusCode, 200);
      final other = Uint8List.fromList(snap)..[0] ^= 1;
      expect((await h.send('PUT', '/v2/w/$w1/snapshot/s1', key: keyA, body: other, headers: covers)).statusCode, 409);
    });
  });

  group('open requests and in-flight bytes (findings 1, 4)', () {
    test('downloads count as open requests of their address until sent: one past the cap is 429', () async {
      final h = await Harness.start(maxOpenPerClient: 2);
      addTearDown(h.stop);
      final big = Uint8List(48 << 20);
      expect((await h.putData(w1, 'dev1', 1, 'a')).statusCode, 201);
      expect((await h.send('PUT', '/v2/w/$w1/snapshot/big', key: keyA, body: big, headers: {'x-bw-covers': '{"dev1":1}'})).statusCode, 201);
      const path = '/v2/w/$w1/snapshot/big';
      final opened = openReaches(h, 2);
      // Two downloads whose readers do not read: the relay cannot finish sending 48 MiB into them.
      final readers = [
        for (var i = 0; i < 2; i++)
          await Raw.open(h, 'GET', path, headers: await h.sign(keyA, 'GET', path, const [], withPub: false), read: false),
      ];
      await opened;
      final released = Completer<void>();
      h.relay.onOpen = (open) {
        if (open == 0 && !released.isCompleted) released.complete();
      };
      expect((await h.get('/v2/w/$w1/state', key: keyA)).statusCode, 429);
      for (final r in readers) {
        r.socket.destroy();
      }
      await released.future.timeout(const Duration(seconds: 10));
      h.relay.onOpen = null;
      final g = await h.get(path, key: keyA);
      expect(g.statusCode, 200);
      expect(g.bodyBytes.length, big.length);
    });

    test('a declared body counts against the in-flight budget from the start, and the relay-wide budget applies across addresses',
        () async {
      final h = await Harness.start(maxTotalInFlightBytes: 1 << 20, trustProxy: true);
      addTearDown(h.stop);
      expect((await h.putData(w1, 'dev1', 1, 'a')).statusCode, 201);
      var held = 0;
      final reserved = Completer<void>();
      h.relay.onHold = (total) {
        held = total;
        if (!reserved.isCompleted) reserved.complete();
      };
      const path = '/v2/w/$w1/d/dev1/2';
      final first = await Raw.open(h, 'PUT', path,
          length: 900 << 10, part: [0], headers: {...await h.sign(keyA, 'PUT', path, Uint8List(900 << 10)), 'x-forwarded-for': attacker});
      await reserved.future.timeout(const Duration(seconds: 10));
      expect(held, 900 << 10);
      h.relay.onHold = null;
      final r = await h.send('PUT', '/v2/w/$w1/d/dev2/1', key: keyA, body: Uint8List(600 << 10), headers: {'x-forwarded-for': other});
      expect(r.statusCode, 429);
      await first.send(Uint8List((900 << 10) - 1));
      await first.answered.future.timeout(const Duration(seconds: 10));
      expect(first.status, 201);
      first.socket.destroy();
      expect(
          (await h.send('PUT', '/v2/w/$w1/d/dev2/1', key: keyA, body: Uint8List(600 << 10), headers: {'x-forwarded-for': other}))
              .statusCode,
          201);
    });
  });

  group('disk use by a key holder (finding 3)', () {
    test('a wallet holds at most maxDevices streams: a new name by PUT d or by ack is 507, known ones go on', () async {
      expect(defaultMaxDevices, 256);
      final h = await Harness.start(maxDevices: 3);
      addTearDown(h.stop);
      for (final d in ['dev1', 'dev2', 'dev3']) {
        expect((await h.putData(w1, d, 1, 'x')).statusCode, 201);
      }
      final r = await h.putData(w1, 'dev4', 1, 'x');
      expect(r.statusCode, 507);
      expect(jsonDecode(r.body), {'error': 'too many devices'});
      expect((await h.ack(w1, 'dev5', {'dev1': 1})).statusCode, 507);
      expect((await h.ack(w1, 'dev1', {'dev2': 1})).statusCode, 204);
      expect((await h.putData(w1, 'dev2', 2, 'y')).statusCode, 201);
      expect(Directory('${h.dir.path}/$w1/d/dev4').existsSync(), isFalse);
      await h.restart();
      expect((await h.putData(w1, 'dev4', 1, 'x')).statusCode, 507);
      expect(((await h.state(w1))['devices'] as Map).keys, unorderedEquals(['dev1', 'dev2', 'dev3']));
    });

    test('every stored file counts at least 4 KiB toward --max-bytes, so many tiny files hit the quota', () async {
      expect(defaultMinFileCost, 4096);
      final h = await Harness.start(maxBytes: 10 * 4096);
      addTearDown(h.stop);
      for (var seq = 1; seq <= 9; seq++) {
        expect((await h.putData(w1, 'dev1', seq, 'x')).statusCode, 201, reason: 'seq $seq');
      }
      final blob = bytes('b');
      expect((await h.send('PUT', '/v2/w/$w1/blob/${await hashOf(blob)}', key: keyA, body: blob)).statusCode, 201);
      expect((await h.state(w1))['bytes'], 10 * 4096);
      expect((await h.putData(w1, 'dev1', 10, 'x')).statusCode, 507);
      final blob2 = bytes('c');
      expect((await h.send('PUT', '/v2/w/$w1/blob/${await hashOf(blob2)}', key: keyA, body: blob2)).statusCode, 507);
      await h.restart();
      expect((await h.state(w1))['bytes'], 10 * 4096);
      expect((await h.putData(w1, 'dev1', 10, 'x')).statusCode, 507);
    });
  });

  group('IPv6 clients by /64 (finding 5)', () {
    Future<int> health(Harness h, String forwarded) async =>
        (await h.get('/v2/health', headers: {'x-forwarded-for': forwarded})).statusCode;

    test('two addresses in one /64 share a rate bucket; another /64 has its own', () async {
      final h = await freshHarness(trustProxy: true);
      for (var i = 0; i < 100; i++) {
        expect(await health(h, '2001:db8:1:2::${i.toRadixString(16)}'), 200);
      }
      expect(await health(h, '2001:db8:1:2:ffff:ffff:ffff:fffe'), 429);
      expect(await health(h, '2001:db8:1:3::1'), 200);
      expect(h.logs.join('\n'), isNot(contains('2001:db8')));
    });

    test('an IPv4-mapped IPv6 address is its IPv4 address', () async {
      final h = await freshHarness(trustProxy: true);
      for (var i = 0; i < 100; i++) {
        expect(await health(h, '198.51.100.7'), 200);
      }
      expect(await health(h, '::ffff:198.51.100.7'), 429);
      expect(await health(h, '198.51.100.8'), 200);
    });

    test('clientKey', () {
      expect(clientKey(InternetAddress('192.0.2.1')), '192.0.2.1');
      expect(clientKey(InternetAddress('::ffff:192.0.2.1')), '192.0.2.1');
      expect(clientKey(InternetAddress('2001:db8:a:b:1:2:3:4')), '2001:db8:a:b::/64');
      expect(clientKey(InternetAddress('2001:db8:a:b::9')), '2001:db8:a:b::/64');
      expect(clientKey(InternetAddress('::1')), '0:0:0:0::/64');
    });
  });

  test('restart: a device whose last file is gone keeps its lower files (finding 6)', () async {
    final h = await freshHarness();
    expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201);
    expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 201);
    await File('${h.dir.path}/$w1/d/dev1/2').delete();
    await h.restart();
    final g = await h.getData(w1, 'dev1', 1);
    expect(g.statusCode, 200);
    expect(g.body, 'one');
    final d = await h.device(w1, 'dev1');
    expect(d['first'], 1);
    expect(d['last'], 2);
    final missing = await h.getData(w1, 'dev1', 2);
    expect(missing.statusCode, 404);
    expect(jsonDecode(missing.body), {'error': 'missing'});
    // All files gone: everything up to last counts as pruned.
    await File('${h.dir.path}/$w1/d/dev1/1').delete();
    await h.restart();
    expect((await h.device(w1, 'dev1'))['first'], 3);
    expect((await h.getData(w1, 'dev1', 1)).statusCode, 410);
  });

  group('HP-R1b review fixes', () {
    test('a listed file gone from disk that the latest snapshot covers is 410 pruned; an uncovered one stays 404 missing', () async {
      final h = await freshHarness();
      expect((await h.putData(w1, 'dev1', 1, 'one')).statusCode, 201);
      expect((await h.putData(w1, 'dev1', 2, 'two')).statusCode, 201);
      expect((await h.putData(w1, 'dev2', 1, 'other')).statusCode, 201);
      expect((await h.putData(w1, 'dev2', 2, 'other two')).statusCode, 201);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 2, 'dev2': 1}, 'snap')).statusCode, 201);
      await File('${h.dir.path}/$w1/d/dev1/2').delete();
      await File('${h.dir.path}/$w1/d/dev2/2').delete();
      await h.restart();
      final covered = await h.getData(w1, 'dev1', 2);
      expect(covered.statusCode, 410);
      expect(jsonDecode(covered.body), {'error': 'pruned'});
      expect((await h.send('HEAD', '/v2/w/$w1/d/dev1/2', key: keyA)).statusCode, 410);
      final uncovered = await h.getData(w1, 'dev2', 2);
      expect(uncovered.statusCode, 404);
      expect(jsonDecode(uncovered.body), {'error': 'missing'});
      expect((await h.getData(w1, 'dev1', 1)).statusCode, 200);
      expect((await h.device(w1, 'dev1'))['first'], 1, reason: 'file 1 is still there');
      // Once file 1 is pruned, the lost file 2 the snapshot covers counts as pruned too: state first moves past it, so
      // a reader (also an older app) takes the snapshot path.
      expect((await h.ack(w1, 'dev2', {'dev1': 1})).statusCode, 204);
      expect((await h.device(w1, 'dev1'))['first'], 3);
      expect((await h.device(w1, 'dev2'))['first'], 1, reason: 'its lost file 2 is not covered');
    });

    test('a wallet at maxDevices forgets a stream with no files unseen for 90 days; snapshots no longer need to cover it', () async {
      final h = await Harness.start(maxDevices: 2);
      addTearDown(h.stop);
      expect((await h.putData(w1, 'dev1', 1, 'a')).statusCode, 201);
      expect((await h.putData(w1, 'dev2', 1, 'b')).statusCode, 201);
      expect((await h.putSnapshot(w1, 's1', {'dev1': 1, 'dev2': 1}, 'snap')).statusCode, 201);
      expect((await h.ack(w1, 'dev1', {'dev2': 1})).statusCode, 204);
      expect((await h.ack(w1, 'dev2', {'dev1': 1})).statusCode, 204); // dev2's file is pruned: it holds none now
      expect((await h.device(w1, 'dev2'))['first'], 2);
      h.advance(const Duration(days: 89));
      expect((await h.ack(w1, 'dev1', {'dev2': 1})).statusCode, 204); // dev1 stays seen
      expect((await h.putData(w1, 'dev3', 1, 'c')).statusCode, 507, reason: 'dev2 seen 89 days ago: kept');
      h.advance(const Duration(days: 2));
      expect((await h.ack(w1, 'dev1', {'dev2': 1})).statusCode, 204);
      expect((await h.putData(w1, 'dev3', 1, 'c')).statusCode, 201);
      expect(((await h.state(w1))['devices'] as Map).keys, unorderedEquals(['dev1', 'dev3']));
      expect(Directory('${h.dir.path}/$w1/d/dev2').existsSync(), isFalse);
      // The kept snapshot still names dev2: a new one without it is accepted.
      expect((await h.putSnapshot(w1, 's2', {'dev1': 1, 'dev3': 1}, 'snap2')).statusCode, 201);
      await h.restart();
      expect(((await h.state(w1))['devices'] as Map).keys, unorderedEquals(['dev1', 'dev3']));
      // Long after: dev1 (no files left) is forgotten for a new stream, dev3 (still holds its file) never is.
      h.advance(const Duration(days: 200));
      expect((await h.putData(w1, 'dev4', 1, 'd')).statusCode, 201);
      expect(((await h.state(w1))['devices'] as Map).keys, unorderedEquals(['dev3', 'dev4']));
      expect((await h.putData(w1, 'dev5', 1, 'e')).statusCode, 507);
    });

    test('a refusal before the body (no create token) drains for refusalTimeout only, not bodyTimeout', () async {
      final h = await Harness.start(createToken: 'synthetic-token', refusalTimeout: const Duration(milliseconds: 200));
      addTearDown(h.stop);
      expect(h.relay.bodyTimeout, const Duration(seconds: 30));
      const path = '/v2/w/$w1/d/a/1';
      final slow = await Raw.open(h, 'PUT', path, length: 30000000, part: [0], headers: await h.sign(keyA, 'PUT', path, Uint8List(0)));
      await slow.closed.future.timeout(const Duration(seconds: 5));
      slow.socket.destroy();
    });

    test('a stalled streamed download leaves the wallet lock free: a PUT to the same wallet goes through', () async {
      final h = await Harness.start();
      addTearDown(h.stop);
      expect((await h.putData(w1, 'dev1', 1, 'a')).statusCode, 201);
      final big = Uint8List(48 << 20);
      expect((await h.send('PUT', '/v2/w/$w1/snapshot/big', key: keyA, body: big, headers: {'x-bw-covers': '{"dev1":1}'})).statusCode, 201);
      const path = '/v2/w/$w1/snapshot/big';
      final reader = await Raw.open(h, 'GET', path, headers: await h.sign(keyA, 'GET', path, const [], withPub: false));
      await reader.answered.future.timeout(const Duration(seconds: 10)); // streaming has started (outside the lock)
      reader.sub.pause(); // and now it cannot finish: 48 MiB into a reader that stopped reading
      expect(reader.status, 200);
      expect((await h.putData(w1, 'dev1', 2, 'b')).statusCode, 201);
      expect((await h.ack(w1, 'dev2', {'dev1': 2})).statusCode, 204);
      reader.socket.destroy();
    });
  });
}
