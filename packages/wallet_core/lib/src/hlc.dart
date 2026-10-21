/// Hybrid logical clock. String form: `<millis 15 digits>:<counter 5 digits>:<node>`.
///
/// Order is (millis, counter, node), compared as numbers. [HlcClock] never issues a counter above [maxCounter]
/// (it moves millis on by one instead), so every HLC it writes also sorts correctly as a plain string, which is
/// how devices on older versions compare them: the stored and synced format is unchanged.
class Hlc implements Comparable<Hlc> {
  /// The largest counter that fits the 5-digit field.
  static const maxCounter = 99999;

  final int millis;
  final int counter;
  final String node;
  const Hlc(this.millis, this.counter, this.node);

  /// Reads `<millis>:<counter>:<node>`; anything else (no colons, non-numeric parts) is a [FormatException].
  static Hlc parse(String s) {
    final p = s.split(':');
    if (p.length < 3) throw const FormatException('An HLC has three parts');
    return Hlc(int.parse(p[0]), int.parse(p[1]), p.sublist(2).join(':'));
  }

  @override
  String toString() => '${millis.toString().padLeft(15, '0')}:${counter.toString().padLeft(5, '0')}:$node';

  @override
  int compareTo(Hlc o) {
    if (millis != o.millis) return millis.compareTo(o.millis);
    if (counter != o.counter) return counter.compareTo(o.counter);
    return node.compareTo(o.node);
  }

  /// Compares two HLC strings by value (correct for any counter width, old strings included).
  static int compareStrings(String a, String b) => a == b ? 0 : parse(a).compareTo(parse(b));
}

/// Issues timestamps for local writes and absorbs remote ones.
class HlcClock {
  final String node;
  final int Function() now;
  Hlc _last;
  HlcClock(this.node, {int Function()? now, String? last})
      : now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _last = last != null ? Hlc.parse(last) : Hlc(0, 0, node);

  Hlc get last => _last;

  Hlc tick() {
    final wall = now();
    if (wall > _last.millis) {
      _last = Hlc(wall, 0, node);
    } else {
      _last = _next(_last.millis, _inc(_last.counter));
    }
    return _last;
  }

  void receive(Hlc remote) {
    final wall = now();
    final m = [wall, _last.millis, remote.millis].reduce((a, b) => a > b ? a : b);
    int c;
    if (m == _last.millis && m == remote.millis) {
      c = _inc(_last.counter > remote.counter ? _last.counter : remote.counter);
    } else if (m == _last.millis) {
      c = _inc(_last.counter);
    } else if (m == remote.millis) {
      c = _inc(remote.counter);
    } else {
      c = 0;
    }
    _last = _next(m, c);
  }

  /// A counter past [Hlc.maxCounter] moves the clock on by one millisecond instead, which keeps the counter
  /// within 5 digits (string order = value order) and still sorts after everything seen so far. At the largest
  /// millis value (only a broken or hostile peer sends one) millis cannot move on without wrapping negative, so the
  /// counter grows past 5 digits instead: the clock never goes backwards by value.
  Hlc _next(int millis, int counter) =>
      counter > Hlc.maxCounter && millis < _maxInt ? Hlc(millis + 1, 0, node) : Hlc(millis, counter, node);

  /// The largest int (millis and counters never wrap past it): 2^63 − 1 on the VM and dart2wasm. On dart2js ints are
  /// doubles, the literal cannot be written (compile error) and the largest exact one is 2^53 − 1; `identical(1, 1.0)`
  /// is true only there. Parsed at start-up because the literal is refused at compile time on that platform.
  static final _maxInt = identical(1, 1.0) ? 9007199254740991 : int.parse('9223372036854775807');

  /// counter + 1, stopping at the largest int instead of wrapping negative.
  static int _inc(int counter) => counter == _maxInt ? counter : counter + 1;
}
