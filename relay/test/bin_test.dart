import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

/// Starts `bin/relay.dart`; returns the process and its port once it says it is listening.
Future<(Process, int, Stream<String>)> start(List<String> args, {Map<String, String> env = const {}}) async {
  final p = await Process.start(Platform.resolvedExecutable, ['bin/relay.dart', ...args], environment: env);
  final lines = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
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
}
