// Stage H12 (relay protocol fuzz): hostile or merely wrong requests get a 4xx, never a 5xx, and a refused request leaves
// the stored state and the files on disk as they were. Seeded and fixed, so a failure reproduces; the request that
// failed is in the failure text (without signatures or keys). Synthetic ids only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

const _t = Timeout(Duration(seconds: 55));

/// The state without times (lastSeen refreshes on some refused requests by design) and the files on disk with sizes.
Future<String> _fingerprint(Harness h) async {
  final out = <String>[];
  for (final (wallet, key) in [(w1, keyA), (w2, keyB)]) {
    final r = await h.get('/v2/w/$wallet/state', key: key);
    if (r.statusCode != 200) {
      out.add('$wallet ${r.statusCode}');
      continue;
    }
    final j = jsonDecode(r.body) as Map<String, Object?>;
    for (final d in (j['devices'] as Map<String, Object?>).values) {
      (d! as Map<String, Object?>).remove('lastSeen');
    }
    out.add(jsonEncode(j));
  }
  final files = [
    for (final e in h.dir.listSync(recursive: true))
      if (e is File && !e.path.contains('/.tmp-')) '${e.path.substring(h.dir.path.length)}:${e.lengthSync()}'
  ]..sort();
  return '${out.join('\n')}\n${files.join('\n')}';
}

Future<Harness> _populated() async {
  final h = await freshHarness();
  for (var i = 1; i <= 3; i++) {
    await h.putData(w1, 'dev1', i, 'file $i');
  }
  await h.putData(w1, 'dev2', 1, 'x');
  await h.ack(w1, 'dev2', {'dev1': 2});
  await h.putSnapshot(w1, 's1', {'dev1': 2, 'dev2': 1}, 'snapshot');
  await h.putData(w2, 'devX', 1, 'other', key: keyB);
  return h;
}

const _methods = ['GET', 'GET', 'GET', 'PUT', 'PUT', 'PUT', 'POST', 'DELETE', 'HEAD', 'OPTIONS', 'PATCH'];
const _wids = [w1, w1, w1, w2, 'short', 'GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG', 'A1B2C3D4E5F60718293A4B5C6D7E8F90', '', '%00', 'z', '..'];
const _devs = ['dev1', 'dev1', 'dev2', 'devNew', 'bad%20name', '..', '%2e%2e', '', '_-', '%C3%BC', 'dev1%2F..%2Fdev2', 'a.b', 'D'];
const _seqs = ['1', '2', '3', '4', '5', '0', '-1', '9007199254740993', '99999999999999999999', '1.5', 'abc', '', '0x10', '%201', '1e3'];
const _ids = ['s1', 's2', 's3', '', '..', 'a b', 'ü'];
const _covers = [
  '',
  '',
  '{}',
  '{"dev1":99}',
  '{"dev1":3,"dev2":1}',
  'not json',
  '[1]',
  '{"dev1":-1}',
  '{"dev1":"x"}',
  '{"dev1":1.5}',
  '{"":1}',
  'null'
];
const _bodies = [
  '',
  'x',
  '{}',
  '{"dev1":1}',
  '{"dev1":99}',
  '{"dev1":-5}',
  '{"dev1":"a"}',
  '{"dev1":1,"dev2":99}',
  '[]',
  'null',
  '{"a":{"b":1}}',
  '{"dev1":1.5}',
  '{"dev1":9223372036854775808}',
  '{"dev1":3,"..":1}',
  'snapshot bytes',
];

String _pick(Random r, List<String> l) => l[r.nextInt(l.length)];

String _path(Random r) {
  final w = _pick(r, _wids);
  return switch (r.nextInt(11)) {
    0 || 1 => '/v2/w/$w/state',
    2 || 3 || 4 => '/v2/w/$w/d/${_pick(r, _devs)}/${_pick(r, _seqs)}',
    5 || 6 => '/v2/w/$w/ack/${_pick(r, _devs)}',
    7 || 8 => '/v2/w/$w/snapshot/${_pick(r, _ids)}',
    9 => '/v2/w/$w/blob/${_pick(r, ['0' * 64, 'f' * 64, 'xyz', '0' * 63, '0' * 65, 'A' * 64])}',
    _ => _pick(r, ['/v2/health', '/v1/health', '/', '/v2', '/v2/w', '/v2/w/', '/v3/w/$w/state', '/v2/w/$w', '/v2/w/$w/', '/v2/w/$w/zzz']),
  };
}

void main() {
  for (final seed in [1, 20261023, 424242]) {
    test('seed $seed: 500 random requests, none answered with a 5xx, every refused one leaves the state untouched', () async {
      final h = await _populated();
      final r = Random(seed);
      var baseline = await _fingerprint(h);
      final seen = <int, int>{};
      for (var i = 0; i < 500; i++) {
        h.advance(const Duration(seconds: 1)); // the rate limit refills with the relay's clock
        final method = _pick(r, _methods);
        final path = _path(r);
        final body = r.nextInt(4) == 0 ? List<int>.generate(r.nextInt(64), (_) => r.nextInt(256)) : utf8.encode(_pick(r, _bodies));
        final covers = path.contains('/snapshot/') || r.nextInt(6) == 0 ? _pick(r, _covers) : '';
        final mode = r.nextInt(10);
        final TestKey? key = switch (mode) {
          < 6 => path.contains(w2) ? keyB : keyA,
          < 8 => path.contains(w2) ? keyA : keyB, // wrong key
          _ => null, // unsigned
        };
        h.skew = switch (r.nextInt(12)) {
          0 => const Duration(minutes: 10),
          1 => const Duration(minutes: -10),
          _ => Duration.zero,
        };
        final label =
            '$method $path covers=<$covers> body=${body.length}B key=${key == null ? 'none' : (key == keyA ? 'A' : 'B')} skew=${h.skew.inSeconds}s';
        http.Response res;
        try {
          res = await h.send(method, path,
              key: key,
              body: body.isEmpty && r.nextBool() ? null : body,
              headers: {if (covers.isNotEmpty) 'x-bw-covers': covers}).timeout(const Duration(seconds: 10));
        } on FormatException {
          continue; // not a URL the client can even build
        } on ArgumentError {
          continue;
        }
        h.skew = Duration.zero;
        seen[res.statusCode] = (seen[res.statusCode] ?? 0) + 1;
        expect(res.statusCode, lessThan(500), reason: 'request $i: $label -> ${res.statusCode} ${res.body}');
        if (res.statusCode >= 400) {
          final now = await _fingerprint(h);
          expect(now, baseline, reason: 'request $i: $label -> ${res.statusCode} changed the stored state');
        } else {
          baseline = await _fingerprint(h); // an accepted request may change things; follow it
        }
      }
      expect(seen.keys.where((s) => s >= 400).length, greaterThan(2), reason: 'the fuzz reached several kinds of refusal: $seen');
      expect((await h.get('/v2/health')).statusCode, 200);
      // The relay still does its job, and the log holds no key material.
      expect((await h.getData(w1, 'dev1', 3)).body, 'file 3');
      final pub = await keyA.pub();
      expect(h.logs.join('\n'), isNot(contains(pub)));
    }, timeout: _t);
  }

  test('a refused ack is refused whole: one valid entry next to a bad one is not applied', () async {
    final h = await _populated();
    final before = await _fingerprint(h);
    for (final body in ['{"dev1":1,"dev2":99}', '{"dev1":1,"dev2":"x"}', '{"dev1":3,"dev9":1}', '{"dev1":1,"dev2":-1}']) {
      final res = await h.send('PUT', '/v2/w/$w1/ack/dev2', key: keyA, body: utf8.encode(body));
      if (res.statusCode >= 400) {
        expect(res.statusCode, lessThan(500), reason: body);
        expect(await _fingerprint(h), before, reason: 'ack $body was refused but changed something');
      }
    }
  }, timeout: _t);

  test('a snapshot that covers more than exists, or whose covers header is broken, is 4xx and prunes nothing', () async {
    final h = await _populated();
    final before = await _fingerprint(h);
    for (final covers in ['{"dev1":99}', 'garbage', '{"dev1":-1}', '[]', '{"dev1":1.5}', '{"dev1":"3"}', '']) {
      final res = await h.send('PUT', '/v2/w/$w1/snapshot/sNew', key: keyA, body: utf8.encode('snap'), headers: {'x-bw-covers': covers});
      expect(res.statusCode, inInclusiveRange(400, 499), reason: 'covers=<$covers>');
      expect(await _fingerprint(h), before, reason: 'covers=<$covers>');
    }
  }, timeout: _t);

  test('raw hostile request lines and framing: the relay answers or closes, never crashes, and stays healthy', () async {
    final h = await _populated();
    final port = h.base.port;
    final host = '127.0.0.1:$port';
    final cases = <String>[
      'GET /v2/w/../../etc/passwd HTTP/1.1\r\nHost: $host\r\n\r\n',
      'GET /v2/w/$w1/d/dev1/%2e%2e/2 HTTP/1.1\r\nHost: $host\r\n\r\n',
      'GET /%00 HTTP/1.1\r\nHost: $host\r\n\r\n',
      'GET /v2/w/$w1/state?x=%ZZ HTTP/1.1\r\nHost: $host\r\n\r\n',
      'GET http://evil.example/v2/health HTTP/1.1\r\nHost: $host\r\n\r\n',
      'BREW /v2/health HTTP/1.1\r\nHost: $host\r\n\r\n',
      'CONNECT $host HTTP/1.1\r\nHost: $host\r\n\r\n',
      'PUT /v2/w/$w1/d/dev1/4 HTTP/1.1\r\nHost: $host\r\nContent-Length: -1\r\n\r\n',
      'PUT /v2/w/$w1/d/dev1/4 HTTP/1.1\r\nHost: $host\r\nContent-Length: abc\r\n\r\n',
      'PUT /v2/w/$w1/d/dev1/4 HTTP/1.1\r\nHost: $host\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nabcde',
      'PUT /v2/w/$w1/d/dev1/4 HTTP/1.1\r\nHost: $host\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\nabc\r\n0\r\n\r\n',
      'PUT /v2/w/$w1/d/dev1/4 HTTP/1.1\r\nHost: $host\r\nContent-Length: 99999999999999\r\n\r\nabc',
      'PUT /v2/w/$w1/d/dev1/4 HTTP/1.1\r\nHost: $host\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\nabc',
      'GET /v2/health HTTP/1.1\r\nHost: $host\r\nX-BW-Time: ${'9' * 400}\r\nX-BW-Sig: ${'A' * 5000}\r\n\r\n',
      'GET /v2/w/$w1/state HTTP/1.1\r\nHost: $host\r\nX-BW-Pub: ü\r\n\r\n',
      'GET /v2/health HTTP/9.9\r\nHost: $host\r\n\r\n',
      '\r\n\r\n',
      'GARBAGE\r\n\r\n',
    ];
    final before = await _fingerprint(h);
    for (final raw in cases) {
      final status = await _rawStatus(port, raw);
      if (status != null) {
        expect(status, lessThan(500), reason: 'raw request ${raw.split('\r\n').first}');
      }
    }
    expect((await h.get('/v2/health')).statusCode, 200);
    expect(await _fingerprint(h), before, reason: 'no hostile request changed what is stored');
  }, timeout: _t);

  test('a body over the file limit is refused with 413 and not stored', () async {
    final h = await _populated();
    final before = await _fingerprint(h);
    final big = List<int>.filled(17 * 1024 * 1024, 0x61);
    final res = await h.putData(w1, 'dev1', 4, String.fromCharCodes(big));
    expect(res.statusCode, 413);
    expect(await _fingerprint(h), before);
  }, timeout: _t);
}

/// Sends [raw] on a fresh socket; the status code of the answer, or null when the relay closed without one.
Future<int?> _rawStatus(int port, String raw) async {
  Socket? s;
  try {
    s = await Socket.connect('127.0.0.1', port).timeout(const Duration(seconds: 3));
    s.add(latin1.encode(raw));
    await s.flush();
    final buf = StringBuffer();
    final done = Completer<void>();
    final sub = s.listen((d) {
      buf.write(latin1.decode(d, allowInvalid: true));
      if (buf.toString().contains('\r\n') && !done.isCompleted) done.complete();
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    }, onError: (Object _) {
      if (!done.isCompleted) done.complete();
    });
    await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    await sub.cancel();
    final m = RegExp(r'^HTTP/\d\.\d (\d{3})').firstMatch(buf.toString());
    return m == null ? null : int.parse(m.group(1)!);
  } on Object {
    return null; // refused or reset at the socket: the relay did not answer 5xx
  } finally {
    s?.destroy();
  }
}
