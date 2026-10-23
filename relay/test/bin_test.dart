import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

/// Every stdout line of a started process (the startup lines come in one chunk, so they are there once the port line is).
final Expando<Seen> stdoutOf = Expando();

class Seen {
  final List<String> lines = [];
  final List<(String, Completer<void>)> _waiting = [];

  void add(String line) {
    lines.add(line);
    for (final w in _waiting.toList()) {
      if (line.contains(w.$1)) {
        w.$2.complete();
        _waiting.remove(w);
      }
    }
  }

  /// Completes when a line containing [needle] has been printed (now or later).
  Future<void> saw(String needle) {
    if (lines.any((l) => l.contains(needle))) return Future.value();
    final c = Completer<void>();
    _waiting.add((needle, c));
    return c.future.timeout(const Duration(seconds: 30));
  }
}

/// Starts `bin/relay.dart`; returns the process and its port once it says it is listening.
Future<(Process, int, Stream<String>)> start(List<String> args, {Map<String, String> env = const {}}) async {
  final p = await Process.start(Platform.resolvedExecutable, ['bin/relay.dart', ...args], environment: env);
  final lines = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
  final seen = stdoutOf[p] = Seen();
  lines.listen(seen.add);
  final first = await lines.first.timeout(const Duration(seconds: 60));
  final m = RegExp(r'^relay listening port=(\d+) wallets=(\d+)$').firstMatch(first);
  expect(m, isNotNull, reason: first);
  return (p, int.parse(m!.group(1)!), lines);
}

Future<int> exitOf(List<String> args, {Map<String, String> env = const {}}) async {
  final p = await Process.start(Platform.resolvedExecutable, ['bin/relay.dart', ...args], environment: env);
  unawaited(p.stdout.drain<void>());
  unawaited(p.stderr.drain<void>());
  return p.exitCode.timeout(const Duration(seconds: 60));
}

void main() {
  test('flags: serves on the port, applies --origin, shuts down cleanly on SIGTERM', () async {
    final dir = await Directory.systemTemp.createTemp('relay-bin-');
    addTearDown(() => dir.delete(recursive: true));
    final (p, port, lines) =
        await start(['--host', '127.0.0.1', '--port=0', '--data', dir.path, '--origin', 'https://a.example', '--origin=https://b.example']);
    addTearDown(p.kill);
    final base = 'http://127.0.0.1:$port';
    final r = await http.get(Uri.parse('$base/v2/health'), headers: {'origin': 'https://b.example'});
    expect(r.statusCode, 200);
    expect(r.headers['access-control-allow-origin'], 'https://b.example');
    expect(
        (await http.get(Uri.parse('$base/v2/health'), headers: {'origin': 'http://localhost:8080'})).headers['access-control-allow-origin'],
        isNull);
    final stopping = lines.firstWhere((l) => l == 'relay stopping');
    expect(p.kill(ProcessSignal.sigterm), isTrue);
    expect(await p.exitCode.timeout(const Duration(seconds: 30)), 0);
    await stopping;
  });

  test('env vars configure the relay, flags win; SIGINT also stops it', () async {
    final dir = await Directory.systemTemp.createTemp('relay-bin-');
    addTearDown(() => dir.delete(recursive: true));
    final (p, port, _) = await start(
      ['--port', '0'],
      env: {
        'BW_RELAY_HOST': '127.0.0.1',
        'BW_RELAY_PORT': '9',
        'BW_RELAY_DATA': dir.path,
        'BW_RELAY_ORIGINS': 'https://c.example, https://d.example',
        'BW_RELAY_MAX_WALLETS': '1',
      },
    );
    addTearDown(p.kill);
    final base = 'http://127.0.0.1:$port';
    expect((await http.get(Uri.parse('$base/v2/health'), headers: {'origin': 'https://d.example'})).headers['access-control-allow-origin'],
        'https://d.example');
    Future<int> put(String wid) async => (await http.put(
          Uri.parse('$base/v2/w/$wid/d/dev1/1'),
          headers: await keyA.headers('PUT', '/v2/w/$wid/d/dev1/1', bytes('x'),
              timeMs: DateTime.now().millisecondsSinceEpoch, host: '127.0.0.1:$port'),
          body: 'x',
        ))
            .statusCode;
    expect(await put(w1), 201);
    expect(await put(w2), 507);
    p.kill(ProcessSignal.sigint);
    expect(await p.exitCode.timeout(const Duration(seconds: 30)), 0);
    expect(File('${dir.path}/$w1/meta.json').existsSync(), isTrue);
  });

  test('usage errors exit 64: no data folder, unknown flag, bad numbers, missing values', () async {
    expect(await exitOf([]), 64);
    expect(await exitOf(['--data', '/tmp/x', '--nope', '1']), 64);
    expect(await exitOf(['--data', '/tmp/x', '--port', 'abc']), 64);
    expect(await exitOf(['--data', '/tmp/x', '--max-bytes', '-5']), 64);
    expect(await exitOf(['--data']), 64);
    expect(await exitOf([], env: {'BW_RELAY_DATA': '/tmp/x', 'BW_RELAY_PORT': 'x'}), 64);
  });
  test('--create-token <file>: creation needs the token, startup says so; env var works too; short tokens are usage errors', () async {
    final dir = await Directory.systemTemp.createTemp('relay-bin-');
    addTearDown(() => dir.delete(recursive: true));
    const token = 'synthetic-create-token-0123456789';
    final file = File('${dir.path}/token')..writeAsStringSync('$token\n');
    final (p, port, _) = await start(['--host', '127.0.0.1', '--port=0', '--data', '${dir.path}/data', '--create-token', file.path]);
    addTearDown(p.kill);
    await stdoutOf[p]!.saw('relay wallet creation needs the create token');
    final url = Uri.parse('http://127.0.0.1:$port/v2/w/$w1/d/dev1/1');
    Future<int> put(Map<String, String> extra) async => (await http.put(
          url,
          headers: {...await keyA.headers('PUT', url.path, bytes('x'), timeMs: DateTime.now().millisecondsSinceEpoch), ...extra},
          body: 'x',
        ))
            .statusCode;
    expect(await put({}), 403);
    expect(await put({'x-bw-create-token': token}), 201);
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 30));

    final (q, qport, _) =
        await start(['--host', '127.0.0.1', '--port=0'], env: {'BW_RELAY_DATA': '${dir.path}/data2', 'BW_RELAY_CREATE_TOKEN': token});
    addTearDown(q.kill);
    await stdoutOf[q]!.saw('relay wallet creation needs the create token');
    final url2 = Uri.parse('http://127.0.0.1:$qport/v2/w/$w1/d/dev1/1');
    final r = await http.put(
      url2,
      headers: await keyA.headers('PUT', url2.path, bytes('x'), timeMs: DateTime.now().millisecondsSinceEpoch),
      body: 'x',
    );
    expect(r.statusCode, 403);
    q.kill(ProcessSignal.sigterm);
    await q.exitCode.timeout(const Duration(seconds: 30));

    expect(await exitOf(['--data', dir.path], env: {'BW_RELAY_CREATE_TOKEN': 'short'}), 64);
    expect(await exitOf(['--data', dir.path, '--create-token', '${dir.path}/nope']), 64);
    expect(await exitOf(['--data', dir.path, '--create-token']), 64);
  });

  test('the template placeholders are refused as a create token (also from a file)', () async {
    final dir = await Directory.systemTemp.createTemp('relay-bin-');
    addTearDown(() => dir.delete(recursive: true));
    for (final placeholder in ['CHANGE_ME', 'replace-with-a-long-random-token']) {
      expect(await exitOf(['--data', dir.path], env: {'BW_RELAY_CREATE_TOKEN': placeholder}), 64, reason: placeholder);
      final file = File('${dir.path}/token')..writeAsStringSync('$placeholder\n');
      expect(await exitOf(['--data', dir.path, '--create-token', file.path]), 64, reason: 'file $placeholder');
    }
  });

  test('BW_RELAY_TRUST_PROXY: 1/true turn it on, 0/false/empty off, anything else is a usage error', () async {
    final dir = await Directory.systemTemp.createTemp('relay-bin-');
    addTearDown(() => dir.delete(recursive: true));
    for (final bad in ['yes', 'on', 'TRUE', '2', 'enabled', ' 1']) {
      expect(await exitOf(['--data', dir.path], env: {'BW_RELAY_TRUST_PROXY': bad}), 64, reason: 'value "$bad"');
    }
    final (p, _, _) = await start(['--host', '127.0.0.1', '--port=0', '--data', dir.path], env: {'BW_RELAY_TRUST_PROXY': 'true'});
    addTearDown(p.kill);
    await stdoutOf[p]!.saw('X-Forwarded-For');
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 30));
    final (q, _, _) = await start(['--host', '127.0.0.1', '--port=0', '--data', dir.path], env: {'BW_RELAY_TRUST_PROXY': '0'});
    addTearDown(q.kill);
    await stdoutOf[q]!.saw('creation is OPEN');
    expect(stdoutOf[q]!.lines.any((l) => l.contains('X-Forwarded-For')), isFalse);
    q.kill(ProcessSignal.sigterm);
    await q.exitCode.timeout(const Duration(seconds: 30));
  });

  test('without --create-token the startup log says creation is open', () async {
    final dir = await Directory.systemTemp.createTemp('relay-bin-');
    addTearDown(() => dir.delete(recursive: true));
    final (p, _, lines) = await start(['--host', '127.0.0.1', '--port=0', '--data', dir.path, '--trust-proxy']);
    addTearDown(p.kill);
    await stdoutOf[p]!.saw('creation is OPEN');
    await stdoutOf[p]!.saw('X-Forwarded-For');
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 30));
  });

  test('--public-host (or BW_RELAY_PUBLIC_HOST / BW_RELAY_DOMAIN) is accepted; a scheme or path is a usage error', () async {
    final dir = await Directory.systemTemp.createTemp('relay-bin-');
    addTearDown(() => dir.delete(recursive: true));
    final (p, _, _) = await start(['--host', '127.0.0.1', '--port=0', '--data', dir.path, '--public-host', 'Wallet.Example.org']);
    addTearDown(p.kill);
    await stdoutOf[p]!.saw('relay public host is set');
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 30));

    final (q, _, _) = await start(['--host', '127.0.0.1', '--port=0', '--data', dir.path], env: {'BW_RELAY_DOMAIN': 'wallet.example.org'});
    addTearDown(q.kill);
    await stdoutOf[q]!.saw('relay public host is set');
    q.kill(ProcessSignal.sigterm);
    await q.exitCode.timeout(const Duration(seconds: 30));

    expect(await exitOf(['--data', dir.path, '--public-host', 'https://wallet.example.org']), 64);
    expect(await exitOf(['--data', dir.path, '--public-host', 'wallet.example.org/x']), 64);
    expect(await exitOf(['--data', dir.path], env: {'BW_RELAY_PUBLIC_HOST': 'bad host'}), 64);
    expect(await exitOf(['--data', dir.path, '--public-host']), 64);
  });

  test('--health-check exits 0 when /v2/health answers on the port, 1 otherwise; needs no --data', () async {
    final dir = await Directory.systemTemp.createTemp('relay-bin-');
    addTearDown(() => dir.delete(recursive: true));
    final (p, port, _) = await start(['--host', '127.0.0.1', '--port=0', '--data', dir.path]);
    addTearDown(p.kill);
    expect(await exitOf(['--health-check', '--port', '$port']), 0);
    expect(await exitOf(['--health-check'], env: {'BW_RELAY_PORT': '$port'}), 0);
    p.kill(ProcessSignal.sigterm);
    await p.exitCode.timeout(const Duration(seconds: 30));
    expect(await exitOf(['--health-check', '--port', '$port']), 1);
    expect(await exitOf(['--health-check=1']), 64);
  });
}
