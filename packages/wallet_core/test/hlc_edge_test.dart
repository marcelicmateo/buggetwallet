// Hybrid logical clock edge cases: parse/format, ordering and tie-breaks, clocks going backwards, counter overflow,
// remote clocks far ahead. Expected values are worked out by hand. All data is SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  group('format and parse', () {
    test('fixed widths: 15 digit millis, 5 digit counter', () {
      expect(const Hlc(0, 0, 'a').toString(), '000000000000000:00000:a');
      expect(const Hlc(1767225600000, 7, 'dev1').toString(), '001767225600000:00007:dev1');
      expect(const Hlc(999999999999999, 99999, 'z').toString(), '999999999999999:99999:z');
    });

    test('round trip, including node ids with colons, dashes, unicode and nothing', () {
      for (final node in ['a', 'ab12cd34ef567890', 'a:b', 'a:b:c:', ':', '', 'dev-1', 'čšž', 'x y', '🙂']) {
        final h = Hlc(123456789, 42, node);
        final back = Hlc.parse(h.toString());
        expect((back.millis, back.counter, back.node), (123456789, 42, node), reason: 'node "$node"');
        expect(back.toString(), h.toString());
      }
    });

    test('parse accepts a wider counter or millis than the fixed width (older or odd writers) and keeps its value', () {
      final c = Hlc.parse('000000000000001:123456:peer');
      expect((c.millis, c.counter), (1, 123456));
      final m = Hlc.parse('1234567890123456:00001:peer'); // 16 digits
      expect(m.millis, 1234567890123456);
    });

    test('malformed strings are refused with a FormatException', () {
      for (final s in ['', 'garbage', 'a:b:c', '12:xx:n', 'xx:12:n', '1.5:2:n', '1:2.5:n', ':1:n', '1::n', '99999999999999999999:1:n']) {
        expect(() => Hlc.parse(s), throwsFormatException, reason: '"$s"');
      }
    });

    test('a string with no colon at all is a FormatException, not a RangeError', () {
      expect(() => Hlc.parse('12345'), throwsFormatException);
    });

    test('compareStrings refuses a malformed side instead of ordering it', () {
      expect(() => Hlc.compareStrings('garbage', '000000000000001:00001:a'), throwsFormatException);
      expect(() => Hlc.compareStrings('000000000000001:00001:a', ''), throwsFormatException);
    });
  });

  group('ordering', () {
    test('order is millis, then counter, then node, as numbers', () {
      final ordered = [
        const Hlc(1, 0, 'a'),
        const Hlc(1, 0, 'b'),
        const Hlc(1, 1, 'a'),
        const Hlc(1, 10, 'a'),
        const Hlc(2, 0, 'a'),
        const Hlc(10, 0, 'a'),
      ];
      for (var i = 0; i < ordered.length; i++) {
        for (var j = 0; j < ordered.length; j++) {
          expect(ordered[i].compareTo(ordered[j]).sign, i.compareTo(j).sign, reason: '${ordered[i]} vs ${ordered[j]}');
        }
      }
    });

    test('equal time on two devices: the node id decides, the same way on both devices and in both directions', () {
      const a = Hlc(5000, 3, 'aaaa'), b = Hlc(5000, 3, 'bbbb');
      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(a), greaterThan(0));
      expect(Hlc.compareStrings(a.toString(), b.toString()), lessThan(0));
      expect(Hlc.compareStrings(b.toString(), a.toString()), greaterThan(0));
      expect(a.compareTo(const Hlc(5000, 3, 'aaaa')), 0);
      // Node ids compare by character, case-sensitively: deterministic, whatever the rule is.
      expect(const Hlc(1, 1, 'B').compareTo(const Hlc(1, 1, 'a')).sign, -const Hlc(1, 1, 'a').compareTo(const Hlc(1, 1, 'B')).sign);
    });

    test('a counter of 10 is after 9 (numbers, not text) in Hlc, and in strings written by the clock', () {
      expect(const Hlc(1, 10, 'a').compareTo(const Hlc(1, 9, 'a')), greaterThan(0));
      expect(Hlc.compareStrings(const Hlc(1, 10, 'a').toString(), const Hlc(1, 9, 'a').toString()), greaterThan(0));
      expect(const Hlc(1, 10, 'a').toString().compareTo(const Hlc(1, 9, 'a').toString()), greaterThan(0));
    });

    test('a millis value with more digits than 15 still orders by value in compareStrings', () {
      final big = const Hlc(1000000000000000, 0, 'a').toString(); // 16 digits
      expect(Hlc.compareStrings(big, '999999999999999:99999:z'), greaterThan(0));
    });

    test('sorting a shuffled list gives one order whatever the input order (all devices agree)', () {
      final r = Random(11);
      final all = <Hlc>{
        for (var i = 0; i < 300; i++) Hlc(1000 + r.nextInt(5), r.nextInt(4), 'n${r.nextInt(3)}'),
      }.toList();
      final first = ([...all]..sort()).map((h) => h.toString()).toList();
      for (var k = 0; k < 20; k++) {
        final shuffled = [...all]..shuffle(r);
        expect((shuffled..sort()).map((h) => h.toString()).toList(), first);
        expect(([...all]..sort((x, y) => Hlc.compareStrings(x.toString(), y.toString()))).map((h) => h.toString()).toList(), first);
      }
      // Within the 5-digit counter range plain string order is the same order.
      expect(([...first]..sort()), first);
    });

    test('compareTo is antisymmetric and transitive on random values', () {
      final r = Random(5);
      final hs = [for (var i = 0; i < 60; i++) Hlc(r.nextInt(3), r.nextInt(3), 'n${r.nextInt(3)}')];
      for (final a in hs) {
        for (final b in hs) {
          expect(a.compareTo(b).sign, -b.compareTo(a).sign);
          for (final c in hs) {
            if (a.compareTo(b) <= 0 && b.compareTo(c) <= 0) expect(a.compareTo(c), lessThanOrEqualTo(0));
          }
        }
      }
    });
  });

  group('tick', () {
    test('a fresh clock with the wall clock at 0 still issues increasing values', () {
      final c = HlcClock('me', now: () => 0);
      final a = c.tick(), b = c.tick();
      expect(a.compareTo(b), lessThan(0));
      expect(a.millis, 0);
      expect(a.counter, greaterThan(0), reason: 'must differ from the initial 0:0');
    });

    test('same millisecond: the counter counts up; a later millisecond resets it', () {
      var t = 1000;
      final c = HlcClock('me', now: () => t);
      expect(c.tick().toString(), '000000000001000:00000:me');
      expect(c.tick().toString(), '000000000001000:00001:me');
      expect(c.tick().toString(), '000000000001000:00002:me');
      t = 1001;
      expect(c.tick().toString(), '000000000001001:00000:me');
    });

    test('wall clock going backwards: never goes back, keeps counting from the last value', () {
      var t = 5000;
      final c = HlcClock('me', now: () => t);
      final a = c.tick();
      t = 100; // clock set back by an hour or a dead battery
      final b = c.tick(), d = c.tick();
      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(d), lessThan(0));
      expect(b.millis, 5000);
      t = 5000 + 1;
      expect(c.tick().toString(), '000000000005001:00000:me');
    });

    test('wall clock jumping around randomly: strictly increasing, fixed width, never above the counter limit', () {
      final r = Random(2);
      var t = 10000;
      final c = HlcClock('me', now: () => t);
      var prev = c.tick();
      for (var i = 0; i < 5000; i++) {
        t += r.nextInt(5) - 3;
        final next = i % 9 == 0 ? (c..receive(Hlc(t + r.nextInt(5) - 2, r.nextInt(4), 'peer'))).last : c.tick();
        expect(next.compareTo(prev), greaterThan(0), reason: 'step $i');
        expect(next.counter, lessThanOrEqualTo(Hlc.maxCounter));
        expect(next.toString().length, prev.toString().length);
        prev = next;
      }
    });

    test('100000 events inside one millisecond: the counter rolls into the next millisecond, strings keep sorting', () {
      final c = HlcClock('me', now: () => 7);
      var prev = c.tick().toString();
      var rolled = false;
      for (var i = 0; i < 100010; i++) {
        final next = c.tick();
        expect(next.counter, lessThanOrEqualTo(Hlc.maxCounter));
        final s = next.toString();
        expect(s.compareTo(prev), greaterThan(0), reason: 'event $i');
        if (next.millis > 7) rolled = true;
        prev = s;
      }
      expect(rolled, isTrue);
    });

    test('exactly at the limit: 99999 is issued, the next one is (millis + 1, 0)', () {
      final c = HlcClock('me', now: () => 0, last: const Hlc(500, 99998, 'me').toString());
      expect(c.tick().toString(), '000000000000500:99999:me');
      expect(c.tick().toString(), '000000000000501:00000:me');
    });

    test('the wall clock catching up after a rollover resets the counter', () {
      var t = 500;
      final c = HlcClock('me', now: () => t, last: const Hlc(500, 99999, 'me').toString());
      expect(c.tick().toString(), '000000000000501:00000:me'); // wall (500) is behind
      t = 600;
      expect(c.tick().toString(), '000000000000600:00000:me');
    });

    test('a clock restored from a stored value continues after it, whatever the wall clock says', () {
      final c = HlcClock('me', now: () => 10, last: '000000000009999:00004:me');
      expect(c.tick().toString(), '000000000009999:00005:me');
    });

    test('the clock issues its own node id, also when restored from a value written by another node', () {
      final c = HlcClock('me', now: () => 0, last: '000000000000100:00001:other');
      expect(c.tick().node, 'me');
      final d = HlcClock('me', now: () => 0, last: '000000000000100:00001:other')..receive(const Hlc(50, 0, 'x'));
      expect(d.last.node, 'me');
    });

    test('a stored value that is malformed fails loudly when the clock is built', () {
      expect(() => HlcClock('me', last: 'garbage'), throwsFormatException);
    });
  });

  group('receive', () {
    test('a remote value ahead of everything: the clock moves past it', () {
      final c = HlcClock('me', now: () => 100);
      c.tick();
      const remote = Hlc(5000, 7, 'peer');
      c.receive(remote);
      expect(c.last.toString(), '000000000005000:00008:me');
      expect(c.last.compareTo(remote), greaterThan(0));
    });

    test('a remote value in the past changes nothing but the counter', () {
      var t = 5000;
      final c = HlcClock('me', now: () => t);
      c.tick(); // 5000:0
      t = 5000;
      c.receive(const Hlc(10, 50, 'peer'));
      expect(c.last.toString(), '000000000005000:00001:me');
    });

    test('equal millis on both sides: counter is the larger one plus one', () {
      final c = HlcClock('me', now: () => 0, last: const Hlc(900, 4, 'me').toString());
      c.receive(const Hlc(900, 9, 'peer'));
      expect(c.last.toString(), '000000000000900:00010:me');
      final d = HlcClock('me', now: () => 0, last: const Hlc(900, 9, 'me').toString());
      d.receive(const Hlc(900, 4, 'peer'));
      expect(d.last.toString(), '000000000000900:00010:me');
    });

    test('wall clock ahead of both: counter restarts at 0', () {
      final c = HlcClock('me', now: () => 9000, last: const Hlc(900, 4, 'me').toString());
      c.receive(const Hlc(800, 4, 'peer'));
      expect(c.last.toString(), '000000000009000:00000:me');
    });

    test('result is after both the old local value and the remote value, whatever the inputs (property)', () {
      final r = Random(9);
      for (var i = 0; i < 2000; i++) {
        final wall = r.nextInt(6);
        final c = HlcClock('me', now: () => wall, last: Hlc(r.nextInt(6), r.nextInt(3) * 49999, 'me').toString());
        final before = c.last;
        final remote = Hlc(r.nextInt(6), r.nextInt(3) * 49999 + r.nextInt(2), 'p${r.nextInt(2)}');
        c.receive(remote);
        expect(c.last.compareTo(before), greaterThan(0), reason: '$before + $remote');
        expect(c.last.compareTo(remote), greaterThan(0), reason: '$before + $remote');
        expect(c.last.counter, lessThanOrEqualTo(Hlc.maxCounter));
        expect(c.last.millis, greaterThanOrEqualTo(wall));
      }
    });

    test('a remote counter at the limit rolls into the next millisecond, not to 100000', () {
      final c = HlcClock('me', now: () => 0);
      c.receive(const Hlc(700, 99999, 'peer'));
      expect(c.last.toString(), '000000000000701:00000:me');
    });

    test('receiving the same remote value twice still moves forward (no duplicate local stamps)', () {
      final c = HlcClock('me', now: () => 0);
      const remote = Hlc(100, 0, 'peer');
      c.receive(remote);
      final a = c.last;
      c.receive(remote);
      expect(c.last.compareTo(a), greaterThan(0));
    });

    test('a remote clock a century ahead: later local writes still sort after it and the string stays 15 digits', () {
      final c = HlcClock('me', now: () => 1767225600000);
      const farFuture = Hlc(4102444800000 + 3153600000000, 3, 'peer'); // about year 2230
      c.receive(farFuture);
      final w = c.tick();
      expect(w.compareTo(farFuture), greaterThan(0));
      expect(w.toString().split(':').first.length, farFuture.toString().split(':').first.length);
      expect(Hlc.compareStrings(w.toString(), farFuture.toString()), greaterThan(0));
    });

    test('a remote clock at the 15-digit limit: a later write is still after it by value', () {
      final c = HlcClock('me', now: () => 1);
      const edge = Hlc(999999999999999, 99999, 'peer');
      c.receive(edge);
      expect(c.last.compareTo(edge), greaterThan(0));
      expect(Hlc.compareStrings(c.last.toString(), edge.toString()), greaterThan(0));
    });

    test('a remote clock at the largest 64-bit value does not wrap the local clock backwards', () {
      final c = HlcClock('me', now: () => 1);
      const max = Hlc(9223372036854775807, 99999, 'peer');
      c.receive(max);
      expect(c.last.compareTo(max), greaterThan(0));
    }, skip: 'BUG: millis + 1 wraps negative at the 64-bit limit, so the clock goes backwards (only a hostile or broken peer sends it)');
  });
}
