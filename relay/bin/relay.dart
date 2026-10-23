import 'dart:async';
import 'dart:convert';
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
  --create-token <file>  file holding the creation token: a request that would create a wallet must send it in
                      X-BW-Create-Token (403 otherwise). Env BW_RELAY_CREATE_TOKEN_FILE (file) or BW_RELAY_CREATE_TOKEN
                      (the token itself, at least 16 characters). Not set = anyone can create a wallet (dev mode).
  --trust-proxy       take the client address from the last X-Forwarded-For hop (only behind a reverse proxy that is the
                      sole way to reach the relay)                env BW_RELAY_TRUST_PROXY=1
  --public-host <name>  the name clients use to reach the relay (e.g. the domain behind Caddy); the host in signed requests must
                      match it. Default: the request's Host header   env BW_RELAY_PUBLIC_HOST (or BW_RELAY_DOMAIN)
  --health-check      ask http://127.0.0.1:<port>/v2/health and exit 0 (healthy) or 1; for the container HEALTHCHECK
Flags win over environment variables.''';

class _UsageError implements Exception {
  _UsageError(this.message);

  final String message;
}

/// Parsed settings; throws [_UsageError].
class _Config {
  _Config(List<String> args, Map<String, String> env) {
    final flags = <String, List<String>>{};
    const known = {'host', 'port', 'data', 'origin', 'max-wallets', 'max-bytes', 'create-token', 'public-host'};
    const switches = {'trust-proxy', 'health-check'};
    final on = <String>{};
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
      if (switches.contains(a)) {
        if (value != null) throw _UsageError('--$a takes no value');
        on.add(a);
        continue;
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
    healthCheck = on.contains('health-check');
    trustProxy = on.contains('trust-proxy') || const {'1', 'true'}.contains(env['BW_RELAY_TRUST_PROXY']);
    final host0 = (one('public-host', 'BW_RELAY_PUBLIC_HOST') ?? env['BW_RELAY_DOMAIN'])?.trim().toLowerCase();
    if (host0 != null && host0.isNotEmpty && !RegExp(r'^[a-z0-9.-]+(:[0-9]{1,5})?$').hasMatch(host0)) {
      throw _UsageError('--public-host must be a host name (optionally with :port), without scheme or path');
    }
    publicHost = host0 == null || host0.isEmpty ? null : host0;
    final dir = one('data', 'BW_RELAY_DATA');
    if (!healthCheck && (dir == null || dir.isEmpty)) throw _UsageError('--data is required');
    data = dir ?? '';
    createToken =
        healthCheck ? null : _token(flags['create-token']?.last ?? env['BW_RELAY_CREATE_TOKEN_FILE'], env['BW_RELAY_CREATE_TOKEN']);
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
  late final bool healthCheck;
  late final bool trustProxy;
  late final String? publicHost;
  late final String? createToken;

  /// The token from [file] (trimmed) or, without a file, from [inline]; null when neither is set.
  static String? _token(String? file, String? inline) {
    String? t = inline;
    if (file != null) {
      try {
        t = File(file).readAsStringSync();
      } on FileSystemException {
        throw _UsageError('cannot read the create-token file');
      }
    }
    if (t == null) return null;
    t = t.trim();
    if (t.length < 16) throw _UsageError('the create token must have at least 16 characters');
    return t;
  }

  static int _int(String name, String? raw, int fallback, {int min = 0, int max = 1 << 62}) {
    if (raw == null) return fallback;
    final n = int.tryParse(raw);
    if (n == null || n < min || n > max) throw _UsageError('--$name must be a number from $min to $max');
    return n;
  }
}

/// 0 when `/v2/health` on localhost answers 200 with an `api` number, else 1.
Future<int> _healthCheck(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.get('127.0.0.1', port, '/v2/health').timeout(const Duration(seconds: 3));
    final res = await req.close().timeout(const Duration(seconds: 3));
    final body = await utf8.decodeStream(res).timeout(const Duration(seconds: 3));
    return res.statusCode == 200 && body.contains('"api"') ? 0 : 1;
  } on Object {
    return 1;
  } finally {
    client.close(force: true);
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
  if (cfg.healthCheck) exit(await _healthCheck(cfg.port));
  final relay = Relay(
    data: Directory(cfg.data),
    origins: cfg.origins,
    maxWallets: cfg.maxWallets,
    maxBytes: cfg.maxBytes,
    createToken: cfg.createToken,
    trustProxy: cfg.trustProxy,
    publicHost: cfg.publicHost,
  );
  final server = await relay.serve(host: cfg.host, port: cfg.port);
  stdout.writeln('relay listening port=${server.port} wallets=${relay.walletCount}');
  stdout.writeln(cfg.createToken == null
      ? 'relay wallet creation is OPEN (no --create-token): development mode only'
      : 'relay wallet creation needs the create token');
  if (cfg.publicHost != null) stdout.writeln('relay public host is set (--public-host)');
  if (cfg.trustProxy) stdout.writeln('relay client addresses taken from X-Forwarded-For (--trust-proxy)');

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
