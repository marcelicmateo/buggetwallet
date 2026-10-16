/// Hybrid logical clock. String form sorts in causal order:
/// `<millis 15 digits>:<counter 5 digits>:<node>`.
class Hlc implements Comparable<Hlc> {
  final int millis;
  final int counter;
  final String node;
  const Hlc(this.millis, this.counter, this.node);

  static Hlc parse(String s) {
    final p = s.split(':');
    return Hlc(int.parse(p[0]), int.parse(p[1]), p.sublist(2).join(':'));
  }

  @override
  String toString() => '${millis.toString().padLeft(15, '0')}:${counter.toString().padLeft(5, '0')}:$node';

  @override
  int compareTo(Hlc o) => toString().compareTo(o.toString());
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
      _last = Hlc(_last.millis, _last.counter + 1, node);
    }
    return _last;
  }

  void receive(Hlc remote) {
    final wall = now();
    final m = [wall, _last.millis, remote.millis].reduce((a, b) => a > b ? a : b);
    int c;
    if (m == _last.millis && m == remote.millis) {
      c = (_last.counter > remote.counter ? _last.counter : remote.counter) + 1;
    } else if (m == _last.millis) {
      c = _last.counter + 1;
    } else if (m == remote.millis) {
      c = remote.counter + 1;
    } else {
      c = 0;
    }
    _last = Hlc(m, c, node);
  }
}
