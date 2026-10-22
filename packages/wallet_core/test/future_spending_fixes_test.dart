// Stage F review fixes (F4a): parseIcs cost bounds, a dismissed calendar row that keeps a title written elsewhere.
// Calendar refs: calendar_ref_test.dart. Synthetic data only.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

CalendarEvent cev(String calendarId, String uid, String date, String title, {String? notes}) =>
    CalendarEvent(calendarId: calendarId, uid: uid, title: title, date: date, notes: notes);

String vcal(List<String> body) => ['BEGIN:VCALENDAR', 'VERSION:2.0', ...body, 'END:VCALENDAR', ''].join('\r\n');

void main() {
  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = 0;
    final devices = <Device>[];

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> round() async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-planned-fix-');
      key = VaultKey.generate();
      net = Net();
      devices.clear();
      now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    final onA = cev('ics1761000000000001', 'evt-1@example.invalid', '2026-03-10', 'Synthetic dentist');

    test('No cost on B after A confirmed (not yet synced) keeps A\'s title', () async {
      final a = device('a'), b = device('b');
      await round();
      a.repo.addPlanned(title: 'Dentist', date: onA.date, amount: 4000, source: PlannedSource.calendar, sourceRef: onA.ref);
      now += 5000;
      b.repo.dismissCalendarEvent(onA.ref, onA.date);
      await round();
      await round();
      for (final d in [a, b]) {
        final p = d.repo.plannedCosts(includeClosed: true).single;
        expect((p.title, p.status, p.amount), ('Dentist', PlannedStatus.skipped, 4000), reason: d.name);
      }
    });
  });

  group('parseIcs cost bounds', () {
    test('a huge folded ATTACH line parses quickly', () {
      final rnd = Random(3);
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      final b64 = String.fromCharCodes([for (var i = 0; i < 1500000; i++) alphabet.codeUnitAt(rnd.nextInt(64))]);
      final folded = StringBuffer('ATTACH;ENCODING=BASE64;VALUE=BINARY:');
      for (var i = 0; i < b64.length; i += 74) {
        folded.write('\r\n ${b64.substring(i, min(i + 74, b64.length))}');
      }
      final text = vcal(['BEGIN:VEVENT', 'UID:big', 'DTSTART;VALUE=DATE:20260310', 'SUMMARY:With attachment', '$folded', 'END:VEVENT']);
      final sw = Stopwatch()..start();
      final res = parseIcs(text, calendarId: 'c1', from: '2026-03-01', to: '2026-03-31');
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(10000)); // ~1 s idle; generous for a shared, loaded laptop (before the fix: minutes)
      expect(res.events.map((e) => (e.title, e.date)), [('With attachment', '2026-03-10')]);
      expect(res.unsupported, 0);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('thousands of long counted rules stop at the whole-file step budget', () {
      final body = <String>[];
      for (var i = 0; i < 30000; i++) {
        body.addAll(['BEGIN:VEVENT', 'DTSTART:10000101', 'RRULE:FREQ=DAILY;COUNT=999999', 'END:VEVENT']);
      }
      // Normal events after the budget is spent: their first occurrence in range only, counted as unsupported.
      body.addAll([
        'BEGIN:VEVENT', 'UID:weekly', 'DTSTART;VALUE=DATE:20250106', 'RRULE:FREQ=WEEKLY', 'SUMMARY:Weekly', 'END:VEVENT', //
        'BEGIN:VEVENT', 'UID:single', 'DTSTART;VALUE=DATE:20260320', 'SUMMARY:Single', 'END:VEVENT',
      ]);
      final text = vcal(body);
      final sw = Stopwatch()..start();
      final res = parseIcs(text, calendarId: 'c1', from: '2026-03-01', to: '2026-03-31');
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(10000)); // ~1 s idle; generous for a shared, loaded laptop (before the fix: minutes)
      expect(res.events.map((e) => (e.title, e.date)), [('Weekly', '2026-03-02'), ('Single', '2026-03-20')]);
      expect(res.unsupported, greaterThan(29000));
      expect(res.unsupported, lessThanOrEqualTo(30001));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a normal file is unchanged: every weekly occurrence, nothing unsupported', () {
      final res = parseIcs(
          vcal(['BEGIN:VEVENT', 'UID:w', 'DTSTART;VALUE=DATE:20250106', 'RRULE:FREQ=WEEKLY;COUNT=500', 'SUMMARY:Weekly', 'END:VEVENT']),
          calendarId: 'c1',
          from: '2026-03-01',
          to: '2026-03-31');
      expect(res.events.map((e) => e.date), ['2026-03-02', '2026-03-09', '2026-03-16', '2026-03-23', '2026-03-30']);
      expect(res.unsupported, 0);
    });
  });
}
