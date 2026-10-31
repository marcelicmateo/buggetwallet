// Calendar refs built from the event's content (F4a) for events without a stable uid: every device and source agree.
// KL-A: an event with a uid is identified by it (kl_4_calendar_ids_test.dart); these tests use uid '' for content refs.
// Synthetic data only.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

CalendarEvent cev(String calendarId, String uid, String date, String title, {String? notes}) =>
    CalendarEvent(calendarId: calendarId, uid: uid, title: title, date: date, notes: notes);

final _st = WalletSettings.fromMap({'salary': 100000, 'periodStart': '2026-02-15', 'paydayDay': 15});

void main() {
  group('calendarEventRef', () {
    test('without a uid: built from the normalized title and date, the same on every calendar and source', () {
      final android = cev('7', '', '2026-03-10', 'Dentist');
      final ics = cev('ics1761000000000000', '', '2026-03-10', 'dentist 80 €');
      expect(android.ref, ics.ref);
      expect(android.ref, calendarEventRef(calendarId: 'x', uid: '', title: 'DENTIST', date: '2026-03-10'));
      expect(android.ref, legacyCalendarEventRef(calendarId: 'x', uid: 'y', title: 'DENTIST', date: '2026-03-10'));
      expect(android.ref, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(android.ref, isNot(calendarRef('7', '', '2026-03-10')));
    });

    test('a different title or date gives another ref', () {
      final r = calendarEventRef(calendarId: 'c', uid: '', title: 'Dentist', date: '2026-03-10');
      expect(calendarEventRef(calendarId: 'c', uid: '', title: 'Dentist', date: '2026-03-11'), isNot(r));
      expect(calendarEventRef(calendarId: 'c', uid: '', title: 'Concert', date: '2026-03-10'), isNot(r));
    });

    test('a title with no letters falls back to the per-calendar ref', () {
      for (final title in ['80 €', '', '  2026 ']) {
        expect(calendarEventRef(calendarId: 'c1', uid: '', title: title, date: '2026-03-10'), calendarRef('c1', '', '2026-03-10'),
            reason: title);
      }
      expect(cev('c1', '', '2026-03-10', '80 €').ref, isNot(cev('c2', '', '2026-03-10', '80 €').ref));
    });
  });

  group('upcoming with content refs', () {
    test('two events with the same normalized title on one day are one suggestion, picked the same in any order', () {
      final a = cev('a-cal', '', '2026-03-10', 'Dentist 80 €');
      final b = cev('b-cal', '', '2026-03-10', 'dentist 90 €');
      for (final events in [
        [a, b],
        [b, a],
      ]) {
        final items = upcoming(planned: const [], bills: const [], events: events, from: '2026-03-01', to: '2026-03-31');
        expect(items, hasLength(1));
        expect((items.single.event!.calendarId, items.single.suggested), ('a-cal', 8000));
      }
    });

    test('without a uid, different titles on one day stay two suggestions; with one uid they are one event (KL-A)', () {
      final items = upcoming(planned: const [], bills: const [], events: [
        cev('c1', '', '2026-03-10', 'Dentist'),
        cev('c1', '', '2026-03-10', 'Concert'),
      ], from: '2026-03-01', to: '2026-03-31');
      expect(items.map((i) => i.title), ['Concert', 'Dentist']);
      final same = upcoming(planned: const [], bills: const [], events: [
        cev('c1', 'u1', '2026-03-10', 'Dentist'),
        cev('c1', 'u1', '2026-03-10', 'Concert'),
      ], from: '2026-03-01', to: '2026-03-31');
      expect(same, hasLength(1));
    });

    test('titles without letters on two calendars stay two suggestions', () {
      final items = upcoming(planned: const [], bills: const [], events: [
        cev('c1', '', '2026-03-10', '80 €'),
        cev('c2', '', '2026-03-10', '80 €'),
      ], from: '2026-03-01', to: '2026-03-31');
      expect(items, hasLength(2));
    });
  });

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

    // A reads the event from an imported .ics, B from its Android calendar: other calendar ids, no stable uid (KL-A:
    // an event with one uses it, kl_4_calendar_ids_test.dart).
    final onA = cev('ics1761000000000001', '', '2026-03-10', 'Synthetic dentist');
    final onB = cev('12', '', '2026-03-10', 'Synthetic Dentist 80 €');

    test('No cost on A hides the event on B after sync', () async {
      final a = device('a'), b = device('b');
      await round();
      a.repo.dismissCalendarEvent(onA.ref, onA.date);
      await round();
      await round();
      final items =
          upcoming(planned: b.repo.plannedCosts(includeClosed: true), bills: const [], events: [onB], from: '2026-03-01', to: '2026-03-31');
      expect(items, isEmpty);
    });

    test('confirmed on both devices before syncing: one row, reserved once', () async {
      final a = device('a'), b = device('b');
      a.repo.addPlanned(title: 'Dentist', date: onA.date, amount: 4000, source: PlannedSource.calendar, sourceRef: onA.ref);
      now += 5000;
      b.repo.addPlanned(title: 'Dentist', date: onB.date, amount: 4500, source: PlannedSource.calendar, sourceRef: onB.ref);
      await round();
      await round();
      for (final d in [a, b]) {
        expect(d.repo.plannedCosts(includeClosed: true), hasLength(1));
        final p = computePeriod(const [], _st, const [], '2026-03-01', planned: d.repo.plannedCosts(), table: CategoryTable.builtIn);
        expect(p.reservedPlanned, 4500);
      }
    });
  });
}
