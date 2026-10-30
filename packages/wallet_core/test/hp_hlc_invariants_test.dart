// HP-T2: invariants pinned from mutation testing of hlc.dart. Synthetic values only.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _max = 9223372036854775807;

void main() {
  group('Hlc.parse / compare', () {
    test('three parts minimum, node may hold colons', () {
      final h = Hlc.parse('000000000000100:00002:dev:with:colons');
      expect((h.millis, h.counter, h.node), (100, 2, 'dev:with:colons'));
      expect(() => Hlc.parse('1:2'), throwsFormatException);
      expect(() => Hlc.parse('a:2:n'), throwsFormatException);
      expect(() => Hlc.parse('1:b:n'), throwsFormatException);
      expect(Hlc.parse('1:2:n').node, 'n');
    });

    test('compare by millis, then counter, then node', () {
      expect(const Hlc(1, 9, 'z').compareTo(const Hlc(2, 0, 'a')), lessThan(0));
      expect(const Hlc(2, 0, 'a').compareTo(const Hlc(1, 9, 'z')), greaterThan(0));
      expect(const Hlc(1, 1, 'z').compareTo(const Hlc(1, 2, 'a')), lessThan(0));
      expect(const Hlc(1, 2, 'a').compareTo(const Hlc(1, 1, 'z')), greaterThan(0));
      expect(const Hlc(1, 1, 'a').compareTo(const Hlc(1, 1, 'b')), lessThan(0));
      expect(const Hlc(1, 1, 'b').compareTo(const Hlc(1, 1, 'a')), greaterThan(0));
      expect(const Hlc(1, 1, 'a').compareTo(const Hlc(1, 1, 'a')), 0);
    });

    test('compareStrings compares by value, also across counter widths', () {
      expect(Hlc.compareStrings('5:10:n', '5:9:n'), greaterThan(0));
      expect(Hlc.compareStrings('5:9:n', '5:10:n'), lessThan(0));
      expect(Hlc.compareStrings('5:9:n', '5:9:n'), 0);
      expect(Hlc.compareStrings('5:09:n', '5:9:n'), 0, reason: 'equal by value though the strings differ');
      expect(() => Hlc.compareStrings('x', '5:9:n'), throwsFormatException);
    });

    test('toString pads and sorts like the value', () {
      expect(const Hlc(7, 3, 'n').toString(), '000000000000007:00003:n');
      expect(const Hlc(7, 3, 'n').toString().compareTo(const Hlc(7, 10, 'n').toString()), lessThan(0));
    });
  });

  group('HlcClock', () {
    test('tick: wall ahead resets the counter, wall at or behind counts on', () {
      var wall = 1000;
      final c = HlcClock('n', now: () => wall);
      expect(c.last.toString(), const Hlc(0, 0, 'n').toString());
      expect(c.tick().toString(), const Hlc(1000, 0, 'n').toString());
      expect(c.tick().toString(), const Hlc(1000, 1, 'n').toString());
      wall = 900; // behind
      expect(c.tick().toString(), const Hlc(1000, 2, 'n').toString());
      wall = 1001;
      expect(c.tick().toString(), const Hlc(1001, 0, 'n').toString());
    });

    test('tick is strictly increasing even with a frozen wall clock', () {
      final c = HlcClock('n', now: () => 500);
      var prev = c.tick();
      for (var i = 0; i < 50; i++) {
        final next = c.tick();
        expect(next.compareTo(prev), greaterThan(0));
        prev = next;
      }
    });

    test('last: the clock resumes from a stored value', () {
      final c = HlcClock('n', now: () => 10, last: const Hlc(2000, 4, 'n').toString());
      expect(c.tick().toString(), const Hlc(2000, 5, 'n').toString());
    });

    test('counter overflow moves to the next millisecond', () {
      final c = HlcClock('n', now: () => 10, last: const Hlc(2000, Hlc.maxCounter, 'n').toString());
      expect(c.tick().toString(), const Hlc(2001, 0, 'n').toString());
      final d = HlcClock('n', now: () => 10, last: const Hlc(2000, Hlc.maxCounter - 1, 'n').toString());
      expect(d.tick().toString(), const Hlc(2000, Hlc.maxCounter, 'n').toString());
    });

    test('at the largest millis the counter grows instead of wrapping', () {
      final c = HlcClock('n', now: () => 10, last: const Hlc(_max, Hlc.maxCounter, 'n').toString());
      final t = c.tick();
      expect(t.millis, _max);
      expect(t.counter, Hlc.maxCounter + 1);
    });

    test('receive: all four cases of the maximum', () {
      // wall is the largest: counter 0
      var c = HlcClock('n', now: () => 9000, last: const Hlc(100, 7, 'n').toString())..receive(const Hlc(200, 3, 'r'));
      expect(c.last.toString(), const Hlc(9000, 0, 'n').toString());
      // local is the largest: counter + 1
      c = HlcClock('n', now: () => 10, last: const Hlc(500, 7, 'n').toString())..receive(const Hlc(200, 30, 'r'));
      expect(c.last.toString(), const Hlc(500, 8, 'n').toString());
      // remote is the largest: its counter + 1
      c = HlcClock('n', now: () => 10, last: const Hlc(100, 70, 'n').toString())..receive(const Hlc(500, 3, 'r'));
      expect(c.last.toString(), const Hlc(500, 4, 'n').toString());
      // local and remote tie: max counter + 1, either way round
      c = HlcClock('n', now: () => 10, last: const Hlc(500, 7, 'n').toString())..receive(const Hlc(500, 3, 'r'));
      expect(c.last.toString(), const Hlc(500, 8, 'n').toString());
      c = HlcClock('n', now: () => 10, last: const Hlc(500, 3, 'n').toString())..receive(const Hlc(500, 7, 'r'));
      expect(c.last.toString(), const Hlc(500, 8, 'n').toString());
      // wall equals the largest: still a fresh counter 0 when neither clock reaches it... but ties with wall count on
      c = HlcClock('n', now: () => 500, last: const Hlc(500, 7, 'n').toString())..receive(const Hlc(200, 3, 'r'));
      expect(c.last.toString(), const Hlc(500, 8, 'n').toString());
    });

    test('receive then tick never goes backwards; a received clock far ahead is followed', () {
      final c = HlcClock('n', now: () => 10);
      c.receive(const Hlc(50000, 12, 'r'));
      final t = c.tick();
      expect(t.compareTo(const Hlc(50000, 12, 'r')), greaterThan(0));
      expect(t.node, 'n');
    });

    test('receive keeps the counter within five digits and never wraps', () {
      var c = HlcClock('n', now: () => 10, last: const Hlc(500, Hlc.maxCounter, 'n').toString())..receive(const Hlc(500, 1, 'r'));
      expect(c.last.toString(), const Hlc(501, 0, 'n').toString());
      c = HlcClock('n', now: () => 10, last: const Hlc(_max, 5, 'n').toString())..receive(const Hlc(_max, Hlc.maxCounter, 'r'));
      expect(c.last.millis, _max);
      expect(c.last.counter, Hlc.maxCounter + 1);
    });
  });
}
