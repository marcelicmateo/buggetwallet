import 'dart:io';

/// The key a client address is limited under (rate limit, open requests, in-flight bytes): an IPv4 address as is
/// (also one mapped into IPv6, `::ffff:a.b.c.d`), an IPv6 address by its /64 (one home or phone network gets a whole
/// /64, so per-address keys would let one client spread over 2^64 buckets).
String clientKey(InternetAddress a) {
  final raw = a.rawAddress;
  if (raw.length != 16) return a.address;
  var mapped = raw[10] == 0xff && raw[11] == 0xff;
  for (var i = 0; i < 10 && mapped; i++) {
    mapped = raw[i] == 0;
  }
  if (mapped) return raw.sublist(12).join('.');
  final hex = [for (var i = 0; i < 8; i += 2) ((raw[i] << 8) | raw[i + 1]).toRadixString(16)].join(':');
  return '$hex::/64';
}

/// Token bucket per client address ([clientKey]): [ratePerSecond] refill, [burst] capacity. In memory only.
class RateLimiter {
  RateLimiter({this.ratePerSecond = 20, this.burst = 100});

  final double ratePerSecond;
  final int burst;
  final Map<String, _Bucket> _buckets = {};

  /// True when the request from [client] may go on at [now].
  bool allow(String client, DateTime now) {
    if (_buckets.length > 4096) _forgetIdle(now);
    final b = _buckets.putIfAbsent(client, () => _Bucket(burst.toDouble(), now));
    final dt = now.difference(b.at).inMicroseconds;
    if (dt > 0) {
      b.tokens = b.tokens + dt / 1e6 * ratePerSecond;
      if (b.tokens > burst) b.tokens = burst.toDouble();
      b.at = now;
    }
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  }

  void _forgetIdle(DateTime now) {
    _buckets.removeWhere((_, b) => b.tokens + now.difference(b.at).inMicroseconds / 1e6 * ratePerSecond >= burst);
  }
}

class _Bucket {
  _Bucket(this.tokens, this.at);

  double tokens;
  DateTime at;
}
