import 'dart:async';
import 'dart:io';

import 'package:relay/relay.dart';

const _usage = '''
Usage: relay --data <dir> [options]
  --host <addr>       listen address (default 0.0.0.0)        env BW_RELAY_HOST
  --port <n>          listen port (default 8787)              env BW_RELAY_PORT
  --data <dir>        data folder (required)                  env BW_RELAY_DATA
  --origin <url>      allowed CORS origin, repeatable         env BW_RELAY_ORIGINS (comma separated)
                      (default http://127.0.0.1:8080 and http://localhost:8080)
  --max-wallets <n>   most wallets (default 16)               env BW_RELAY_MAX_WALLETS
  --max-bytes <n>     most bytes per wallet (default 1 GiB)   env BW_RELAY_MAX_BYTES
Flags win over environment variables.''';

class _UsageError implements Exception {
  _UsageError(this.message);

  final String message;
}

/// Parsed settings; throws [_UsageError].
class _Config {
  _Config(List<String> args, Map<String, String> env) {
    final flags = <String, List<String>>{};
    const known = {'host', 'port', 'data', 'origin', 'max-wallets', 'max-bytes'};
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      if (!a.startsWith('--')) throw _UsageError('unexpected argument');
      a = a.substring(2);
      String? value;
      final eq = a.indexOf('=');
      if (eq >= 0) {
        value = a.substring(eq + 1);
        a = a.substring(0, eq);
      }
      if (!known.contains(a)) throw _UsageError('unknown flag --$a');
      if (value == null) {
        if (i + 1 >= args.length) throw _UsageError('--$a needs a value');
        value = args[++i];
      }
      flags.putIfAbsent(a, () => []).add(value);
    }
    String? one(String flag, String envName) => flags[flag]?.last ?? env[envName];
    host = one('host', 'BW_RELAY_HOST') ?? '0.0.0.0';
    port = _int('port', one('port', 'BW_RELAY_PORT'), 8787, max: 65535);
    maxWallets = _int('max-wallets', one('max-wallets', 'BW_RELAY_MAX_WALLETS'), 16, min: 1);
    maxBytes = _int('max-bytes', one('max-bytes', 'BW_RELAY_MAX_BYTES'), 1024 * 1024 * 1024, min: 1);
    final dir = one('data', 'BW_RELAY_DATA');
    if (dir == null || dir.isEmpty) throw _UsageError('--data is required');
    data = dir;
    final envOrigins = env['BW_RELAY_ORIGINS'];
    origins = flags['origin'] ??
        (envOrigins == null ? defaultOrigins : envOrigins.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList());
  }

  late final String host;
  late final int port;
  late final String data;
  late final List<String> origins;
  late final int maxWallets;
  late final int maxBytes;

  static int _int(String name, String? raw, int fallback, {int min = 0, int max = 1 << 62}) {
    if (raw == null) return fallback;
    final n = int.tryParse(raw);
    if (n == null || n < min || n > max) throw _UsageError('--$name must be a number from $min to $max');
    return n;
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }
  final _Config cfg;
  try {
    cfg = _Config(args, Platform.environment);
  } on _UsageError catch (e) {
    stderr.writeln('relay: ${e.message}\n$_usage');
    exit(64);
  }
  final relay = Relay(data: Directory(cfg.data), origins: cfg.origins, maxWallets: cfg.maxWallets, maxBytes: cfg.maxBytes);
  final server = await relay.serve(host: cfg.host, port: cfg.port);
  stdout.writeln('relay listening port=${server.port} wallets=${relay.walletCount}');

  final stop = Completer<void>();
  final subs = <StreamSubscription<ProcessSignal>>[];
  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    try {
      subs.add(
        sig.watch().listen((_) {
          if (!stop.isCompleted) stop.complete();
        }),
      );
    } on SignalException {
      // not supported on this platform
    }
  }
  await stop.future;
  stdout.writeln('relay stopping');
  await relay.close();
  for (final s in subs) {
    await s.cancel();
  }
}
