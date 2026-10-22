/// Token bucket per client address: [ratePerSecond] refill, [burst] capacity. In memory only.
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
