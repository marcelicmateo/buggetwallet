// KL-A item 4: calendar events are identified by their stable event id (.ics UID, Android's iCal UID) plus the start
// time; normalized title + date + start time when a source has none. Decisions stored under the old title + date ref
// (`legacyCalendarEventRef`) still apply. Synthetic data only.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

CalendarEvent ev(String uid, String title, {String date = '2026-03-10', int? at, String cal = 'c1'}) =>
    CalendarEvent(calendarId: cal, uid: uid, title: title, date: date, startMinutes: at, allDay: at == null);

List<UpcomingItem> sugg(List<PlannedCost> planned, List<CalendarEvent> events) =>
    upcoming(planned: planned, bills: const [], events: events, from: '2026-03-01', to: '2026-03-31')
        .where((i) => i.kind == UpcomingKind.suggestion)
        .toList();

String ics(List<List<String>> events) => [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      for (final e in events) ...['BEGIN:VEVENT', ...e, 'END:VEVENT'],
      'END:VCALENDAR',
      '',
    ].join('\r\n');

final _st = WalletSettings.fromMap({'salary': 100000, 'periodStart': '2026-03-01', 'paydayDay': 1});

void main() {
  group('calendarEventRef', () {
    test('with a uid: uid + date + start time; the title and the calendar id do not count', () {
      final a = ev('u1@example.invalid', 'Dentist', at: 600);
      expect(ev('u1@example.invalid', 'Dentist (moved room)', at: 600).ref, a.ref, reason: 'a rename keeps the ref');
      expect(ev('u1@example.invalid', 'Dentist', at: 600, cal: 'other').ref, a.ref, reason: 'device-local calendar ids do not count');
      expect(ev('u1@example.invalid', 'Dentist', at: 660).ref, isNot(a.ref));
      expect(ev('u1@example.invalid', 'Dentist', at: 600, date: '2026-03-11').ref, isNot(a.ref));
      expect(ev('u2@example.invalid', 'Dentist', at: 600).ref, isNot(a.ref));
      expect(a.ref, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('without a uid: normalized title + date + start time, the same on every source; all-day = the legacy ref', () {
      expect(ev('', 'Dentist 80 €', at: 600, cal: 'x').ref, ev('', 'dentist', at: 600, cal: 'y').ref);
      expect(ev('', 'Dentist', at: 600).ref, isNot(ev('', 'Dentist', at: 900).ref), reason: 'same name, other time');
      expect(ev('', 'Dentist').ref, ev('', 'Dentist').legacyRef);
      expect(ev('', 'Dentist').refs, hasLength(1));
      expect(ev('', '80 €', at: 600, cal: 'c1').ref, isNot(ev('', '80 €', at: 600, cal: 'c2').ref), reason: 'no letters: per calendar');
    });

    test('legacyCalendarEventRef is the pre-KL ref: normalized title + date', () {
      final legacy = legacyCalendarEventRef(calendarId: 'x', uid: 'y', title: 'DENTIST', date: '2026-03-10');
      expect(ev('u1', 'Dentist 80 €', at: 600).legacyRef, legacy);
      expect(ev('u1', 'Dentist 80 €', at: 600).refs, hasLength(2));
      expect(legacyCalendarEventRef(calendarId: 'c1', uid: 'u1', title: '80 €', date: '2026-03-10'), calendarRef('c1', 'u1', '2026-03-10'));
    });
  });

  group('parseIcs', () {
    test('fills startMinutes from DTSTART (floating, TZID, UTC through toLocal); all-day and no-UID events', () {
      final r = parseIcs(
          ics([
            ['UID:a', 'DTSTART:20260310T093000', 'SUMMARY:Floating'],
            ['UID:b', 'DTSTART;TZID=Europe/Zagreb:20260310T140500', 'SUMMARY:Zoned'],
            ['UID:c', 'DTSTART:20260310T230000Z', 'SUMMARY:Utc'],
            ['UID:d', 'DTSTART;VALUE=DATE:20260310', 'SUMMARY:All day'],
            ['DTSTART:20260310T080000', 'SUMMARY:No uid'],
          ]),
          calendarId: 'cal1',
          from: '2026-03-01',
          to: '2026-03-31',
          toLocal: (t) => t.add(const Duration(hours: 2)));
      final by = {for (final e in r.events) e.title: e};
      expect(by['Floating']!.startMinutes, 570);
      expect(by['Zoned']!.startMinutes, 845);
      expect((by['Utc']!.date, by['Utc']!.startMinutes), ('2026-03-11', 60));
      expect((by['All day']!.startMinutes, by['All day']!.allDay), (null, true));
      expect((by['No uid']!.uid, by['No uid']!.startMinutes), ('', 480), reason: 'no UID: no per-file placeholder as its id');
    });

    test('a recurring event: every occurrence has the start time and its own ref', () {
      final r = parseIcs(
          ics([
            ['UID:w', 'DTSTART:20260302T180000', 'RRULE:FREQ=WEEKLY;COUNT=3', 'SUMMARY:Synth class'],
          ]),
          calendarId: 'cal1',
          from: '2026-03-01',
          to: '2026-03-31');
      expect(r.events.map((e) => e.startMinutes), [1080, 1080, 1080]);
      expect(r.events.map((e) => e.ref).toSet(), hasLength(3));
    });
  });

  group('decisions', () {
    test('same-name events at different times are two suggestions; a dismiss of one leaves the other', () {
      final morning = ev('m@example.invalid', 'Synth dentist', at: 540), evening = ev('e@example.invalid', 'Synth dentist', at: 1080);
      expect(sugg(const [], [morning, evening]), hasLength(2));
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.dismissCalendarEvent(morning.ref, morning.date, legacyRef: morning.legacyRef);
      expect(sugg(r.plannedCosts(includeClosed: true), [morning, evening]).map((i) => i.event!.uid), ['e@example.invalid']);
    });

    test('a renamed event keeps its decision', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final e = ev('u1@example.invalid', 'Synth concert', at: 1200);
      r.addPlanned(title: 'Synth concert', date: e.date, amount: 3000, source: PlannedSource.calendar, sourceRef: e.ref);
      final renamed = ev('u1@example.invalid', 'Synth concert, front row', at: 1200);
      expect(sugg(r.plannedCosts(includeClosed: true), [renamed]), isEmpty);
    });

    test('decisions stored under the legacy ref are honoured: no suggestion again, dismiss reuses that row', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final e = ev('u9@example.invalid', 'Synth vet', at: 600);
      // What a build before KL-A wrote: a confirm under the title + date ref.
      r.addPlanned(title: 'Synth vet', date: e.date, amount: 2500, source: PlannedSource.calendar, sourceRef: e.legacyRef);
      expect(sugg(r.plannedCosts(includeClosed: true), [e]), isEmpty);
      r.dismissCalendarEvent(e.ref, e.date, legacyRef: e.legacyRef);
      final rows = r.plannedCosts(includeClosed: true);
      expect(rows, hasLength(1), reason: 'the old row is the decision; no second row');
      expect((rows.single.id, rows.single.status), ('calendar:${e.legacyRef}', PlannedStatus.skipped));
      // A legacy dismiss also hides the event.
      final f = ev('u10@example.invalid', 'Synth gym', at: 600);
      r.dismissCalendarEvent(f.legacyRef, f.date);
      expect(sugg(r.plannedCosts(includeClosed: true), [f]), isEmpty);
    });

    test('new writes use the new ref', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final e = ev('u3@example.invalid', 'Synth lunch', at: 750);
      r.dismissCalendarEvent(e.ref, e.date, legacyRef: e.legacyRef);
      expect(r.plannedCosts(includeClosed: true).single.id, 'calendar:${e.ref}');
    });

    test('RF4: a legacy row and a new-ref row of the same event both reserve, so both are listed and exported', () {
      final e = ev('u4@example.invalid', 'Synth dinner', at: 1140);
      final old = PlannedCost(
          id: 'calendar:${e.legacyRef}',
          title: 'Synth dinner',
          date: e.date,
          amount: 4000,
          source: PlannedSource.calendar,
          sourceRef: e.legacyRef);
      final fresh = PlannedCost(
          id: 'calendar:${e.ref}', title: 'Synth dinner', date: e.date, amount: 4000, source: PlannedSource.calendar, sourceRef: e.ref);
      final items = upcoming(planned: [old, fresh], bills: const [], events: [e], from: '2026-03-01', to: '2026-03-31');
      expect(items.map((i) => i.key).toSet(), {'p:${old.id}', 'p:${fresh.id}'}, reason: 'the owner sees both and can delete one');
      final today = computePeriod(const [], _st, const [], '2026-03-01', planned: [old, fresh], table: CategoryTable.builtIn);
      expect(items.fold<int>(0, (s, i) => s + (i.amount ?? 0)), today.reservedPlanned, reason: 'Upcoming = Today, exactly');
      final text = plannedIcs([old, fresh], const [], from: '2026-03-01', to: '2026-03-31');
      expect('BEGIN:VEVENT'.allMatches(text), hasLength(2));
      expect(text, allOf(contains('planned-${old.id}'), contains('planned-${fresh.id}')));
      // Deleting one leaves one row, listed and reserved once.
      final gone = PlannedCost(
          id: old.id,
          title: old.title,
          date: old.date,
          amount: 4000,
          source: PlannedSource.calendar,
          sourceRef: e.legacyRef,
          deleted: true);
      final left = upcoming(planned: [gone, fresh], bills: const [], events: [e], from: '2026-03-01', to: '2026-03-31');
      expect(left.map((i) => i.key), ['p:${fresh.id}']);
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    var now = 0;
    final devices = <Device>[];
    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> round(Net net) async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-kl4-');
      key = VaultKey.generate();
      devices.clear();
      now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    for (final (name, uid) in [('a uid event', 'u7@example.invalid'), ('a no-uid event', '')]) {
      test('$name confirmed on both devices before syncing: one row, reserved once', () async {
        final net = Net();
        final a = device('a'), b = device('b');
        // Each device reads the same source under its own local calendar id.
        final onA = ev(uid, 'Synth dentist', at: 600, cal: 'ics-a'), onB = ev(uid, 'Synth dentist', at: 600, cal: 'ics-b');
        expect(onA.ref, onB.ref);
        a.repo.addPlanned(title: 'Synth dentist', date: onA.date, amount: 4000, source: PlannedSource.calendar, sourceRef: onA.ref);
        now += 5000;
        b.repo.addPlanned(title: 'Synth dentist', date: onB.date, amount: 4500, source: PlannedSource.calendar, sourceRef: onB.ref);
        await round(net);
        await round(net);
        for (final d in [a, b]) {
          expect(d.repo.plannedCosts(includeClosed: true), hasLength(1), reason: d.name);
          final p = computePeriod(const [], _st, const [], '2026-03-01', planned: d.repo.plannedCosts(), table: CategoryTable.builtIn);
          expect(p.reservedPlanned, 4500, reason: d.name);
          expect(sugg(d.repo.plannedCosts(includeClosed: true), [onA, onB]), isEmpty, reason: d.name);
        }
      });
    }

    test('a dismiss on A under the new ref hides the event on B; an old-build dismiss under the legacy ref too', () async {
      final net = Net();
      final a = device('a'), b = device('b');
      final e1 = ev('u8@example.invalid', 'Synth haircut', at: 600), e2 = ev('', 'Synth plumber', at: 480);
      await round(net);
      a.repo.dismissCalendarEvent(e1.ref, e1.date, legacyRef: e1.legacyRef);
      a.repo.dismissCalendarEvent(e2.legacyRef, e2.date); // what a pre-KL build wrote
      await round(net);
      await round(net);
      expect(sugg(b.repo.plannedCosts(includeClosed: true), [e1, e2]), isEmpty);
    });
  });
}
