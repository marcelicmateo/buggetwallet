// Stage F review fixes (F4a): a dismissed calendar row that keeps a title written elsewhere.
// Calendar refs: calendar_ref_test.dart. Synthetic data only.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

CalendarEvent cev(String calendarId, String uid, String date, String title, {String? notes}) =>
    CalendarEvent(calendarId: calendarId, uid: uid, title: title, date: date, notes: notes);

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
}
