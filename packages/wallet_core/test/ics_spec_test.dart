// Spec tests for the .ics parser and the planned-costs export (docs/context/FUTURE_SPENDING_API.md), written from the
// spec only. All data is SYNTHETIC. Calendar facts used: 2026-03-01 is a Sunday.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

String ics(List<String> eventLines, {String eol = '\r\n'}) =>
    ['BEGIN:VCALENDAR', 'VERSION:2.0', 'BEGIN:VEVENT', ...eventLines, 'END:VEVENT', 'END:VCALENDAR', ''].join(eol);

IcsParseResult parse(String text, {String from = '2026-03-01', String to = '2026-03-31'}) =>
    parseIcs(text, calendarId: 'cal1', from: from, to: to);

List<String> dates(IcsParseResult r) => [for (final e in r.events) e.date];

void main() {
  group('basic events', () {
    test('all-day event: date, title, notes, allDay', () {
      final r = parse(ics(['UID:a1', 'DTSTART;VALUE=DATE:20260310', 'SUMMARY:Dentist', 'DESCRIPTION:bring card']));
      final e = r.events.single;
      expect((e.date, e.title, e.notes, e.allDay, e.uid, e.calendarId), ('2026-03-10', 'Dentist', 'bring card', true, 'a1', 'cal1'));
      expect(r.unsupported, 0);
    });

    test('timed events: floating, UTC and TZID keep the local date of the stamp and are not all-day', () {
      for (final line in ['DTSTART:20260310T093000', 'DTSTART;TZID=Europe/Zagreb:20260310T233000']) {
        final e = parse(ics(['UID:t', line, 'SUMMARY:Meet'])).events.single;
        expect((e.date, e.allDay), ('2026-03-10', false), reason: line);
      }
      final utc = parse(ics(['UID:t', 'DTSTART:20260310T120000Z', 'SUMMARY:Meet'])).events.single;
      expect(utc.allDay, isFalse);
      expect(utc.date, '2026-03-10', reason: 'midday UTC is the same date in any sane zone');
    });

    test('LF line ends parse like CRLF', () {
      final lines = ['UID:a', 'DTSTART;VALUE=DATE:20260310', 'SUMMARY:Dentist'];
      expect(dates(parse(ics(lines, eol: '\n'))), dates(parse(ics(lines))));
      expect(parse(ics(lines, eol: '\n')).events.single.title, 'Dentist');
    });

    test('folded lines are joined (CRLF or LF + one space/tab), the fold character is dropped', () {
      final a = parse('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:a\r\nDTSTART;VALUE=DATE:20260310\r\nSUMMARY:Dentist ap\r\n pointment\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n');
      expect(a.events.single.title, 'Dentist appointment');
      final b = parse('BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20260310\nSUMMARY:Dentist ap\n\tpointment\nEND:VEVENT\nEND:VCALENDAR\n');
      expect(b.events.single.title, 'Dentist appointment');
    });

    test('escaped characters in text are unescaped', () {
      final e = parse(ics(['UID:a', 'DTSTART;VALUE=DATE:20260310', r'SUMMARY:Lunch\, team\; A\\B'])).events.single;
      expect(e.title, r'Lunch, team; A\B');
    });

    test('events outside [from, to] are dropped; the bounds are inclusive', () {
      String one(String d) => ics(['UID:$d', 'DTSTART;VALUE=DATE:$d', 'SUMMARY:E']);
      expect(parse(one('20260228')).events, isEmpty);
      expect(parse(one('20260301')).events, hasLength(1));
      expect(parse(one('20260331')).events, hasLength(1));
      expect(parse(one('20260401')).events, isEmpty);
    });

    test('several events in one file', () {
      final text = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20260310\nSUMMARY:A\nEND:VEVENT\n'
          'BEGIN:VEVENT\nUID:b\nDTSTART;VALUE=DATE:20260311\nSUMMARY:B\nEND:VEVENT\nEND:VCALENDAR\n';
      expect({for (final e in parse(text).events) e.title}, {'A', 'B'});
    });

    test('an event without a title still parses (empty or placeholder title, no throw)', () {
      expect(() => parse(ics(['UID:a', 'DTSTART;VALUE=DATE:20260310'])), returnsNormally);
    });
  });

  group('recurrence', () {
    List<String> rule(String dtstart, String rrule, {List<String> extra = const [], String from = '2026-03-01', String to = '2026-03-31'}) =>
        dates(parse(ics(['UID:r', 'DTSTART;VALUE=DATE:$dtstart', 'SUMMARY:R', 'RRULE:$rrule', ...extra]), from: from, to: to));

    test('DAILY with COUNT', () {
      expect(rule('20260302', 'FREQ=DAILY;COUNT=3'), ['2026-03-02', '2026-03-03', '2026-03-04']);
    });

    test('DAILY INTERVAL=2 with UNTIL inclusive', () {
      expect(rule('20260302', 'FREQ=DAILY;INTERVAL=2;UNTIL=20260308'), ['2026-03-02', '2026-03-04', '2026-03-06', '2026-03-08']);
    });

    test('EXDATE removes one occurrence', () {
      expect(rule('20260302', 'FREQ=DAILY;COUNT=3', extra: ['EXDATE;VALUE=DATE:20260303']), ['2026-03-02', '2026-03-04']);
    });

    test('WEEKLY BYDAY=MO,WE', () {
      expect(rule('20260302', 'FREQ=WEEKLY;BYDAY=MO,WE', to: '2026-03-15'), ['2026-03-02', '2026-03-04', '2026-03-09', '2026-03-11']);
    });

    test('WEEKLY INTERVAL=2', () {
      expect(rule('20260302', 'FREQ=WEEKLY;INTERVAL=2'), ['2026-03-02', '2026-03-16', '2026-03-30']);
    });

    test('MONTHLY on the 31st skips months without a 31st (RFC 5545)', () {
      expect(rule('20260131', 'FREQ=MONTHLY', from: '2026-01-01', to: '2026-06-30'), ['2026-01-31', '2026-03-31', '2026-05-31']);
    });

    test('MONTHLY BYDAY ordinals: 2MO and -1FR', () {
      expect(rule('20260309', 'FREQ=MONTHLY;BYDAY=2MO', from: '2026-03-01', to: '2026-05-31'), ['2026-03-09', '2026-04-13', '2026-05-11']);
      expect(rule('20260327', 'FREQ=MONTHLY;BYDAY=-1FR', from: '2026-03-01', to: '2026-05-31'), ['2026-03-27', '2026-04-24', '2026-05-29']);
    });

    test('YEARLY on Feb 29 only occurs in leap years', () {
      expect(rule('20240229', 'FREQ=YEARLY', from: '2024-01-01', to: '2033-01-01'), ['2024-02-29', '2028-02-29', '2032-02-29']);
    });

    test('COUNT counts occurrences from DTSTART, also those before [from]', () {
      expect(rule('20260201', 'FREQ=WEEKLY;COUNT=5', from: '2026-03-01', to: '2026-03-31'), ['2026-03-01']);
    });

    test('an unsupported rule gives the first occurrence only and counts it', () {
      final r = parse(ics(['UID:u', 'DTSTART;VALUE=DATE:20260302', 'SUMMARY:U', 'RRULE:FREQ=HOURLY;COUNT=5']));
      expect(dates(r), ['2026-03-02']);
      expect(r.unsupported, 1);
    });

    test('a supported rule is not counted as unsupported', () {
      final r = parse(ics(['UID:u', 'DTSTART;VALUE=DATE:20260302', 'SUMMARY:U', 'RRULE:FREQ=DAILY;COUNT=2']));
      expect(r.unsupported, 0);
    });

    test('a recurring event that starts before [from] still yields its later occurrences', () {
      expect(rule('20250101', 'FREQ=MONTHLY', from: '2026-03-01', to: '2026-03-31'), ['2026-03-01']);
    });
  });

  group('broken input does not throw', () {
    for (final text in [
      '',
      'garbage',
      'BEGIN:VCALENDAR',
      'BEGIN:VEVENT\nDTSTART:xx\nEND:VEVENT',
      'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20260310\nSUMMARY:Cut off',
      'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20261340\nSUMMARY:Bad date\nEND:VEVENT\nEND:VCALENDAR',
      'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20260310\nRRULE:FREQ=\nEND:VEVENT\nEND:VCALENDAR',
      'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\nDTSTART;VALUE=DATE:20260310\nRRULE:FREQ=DAILY;COUNT=abc\nEND:VEVENT\nEND:VCALENDAR',
      '\u0000\u0001￿',
    ]) {
      test('input of ${text.length} chars', () {
        late IcsParseResult r;
        expect(() => r = parse(text), returnsNormally);
        expect(r.events.every((e) => e.date.compareTo('2026-03-01') >= 0 && e.date.compareTo('2026-03-31') <= 0), isTrue);
      });
    }

    test('one broken event does not lose the good one', () {
      final text = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:bad\nDTSTART:xx\nEND:VEVENT\n'
          'BEGIN:VEVENT\nUID:ok\nDTSTART;VALUE=DATE:20260310\nSUMMARY:Good\nEND:VEVENT\nEND:VCALENDAR\n';
      expect([for (final e in parse(text).events) e.title], ['Good']);
    });

    test('an unbounded rule over a huge range stays bounded (no hang)', () {
      final r = parse(ics(['UID:u', 'DTSTART;VALUE=DATE:20000101', 'SUMMARY:D', 'RRULE:FREQ=DAILY']), from: '2026-03-01', to: '2026-03-31');
      expect(r.events, hasLength(31));
    });
  });

  group('calendarRef', () {
    test('stable, 32 hex characters, differs per date, uid and calendar, keeps no raw id', () {
      final r = calendarRef('cal1', 'uid-secret-1', '2026-03-10');
      expect(r, calendarRef('cal1', 'uid-secret-1', '2026-03-10'));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(r), isTrue);
      expect(calendarRef('cal1', 'uid-secret-1', '2026-03-11'), isNot(r));
      expect(calendarRef('cal1', 'uid-secret-2', '2026-03-10'), isNot(r));
      expect(calendarRef('cal2', 'uid-secret-1', '2026-03-10'), isNot(r));
      expect(r.contains('secret'), isFalse);
    });

    test('a recurring event gets a different ref per occurrence, the same ones on a second parse', () {
      final text = ics(['UID:r', 'DTSTART;VALUE=DATE:20260302', 'SUMMARY:R', 'RRULE:FREQ=DAILY;COUNT=3']);
      final a = [for (final e in parse(text).events) e.ref];
      expect(a.toSet(), hasLength(3));
      expect([for (final e in parse(text).events) e.ref], a);
    });
  });

  group('plannedIcs export', () {
    PlannedCost p(String id, String title, String date, int? cents, {PlannedStatus status = PlannedStatus.open}) => PlannedCost(
          id: id,
          title: title,
          date: date,
          amount: cents,
          category: null,
          source: PlannedSource.manual,
          sourceRef: null,
          status: status,
          paidTx: null,
        );

    test('round trips through parseIcs: titles, dates, amounts; planned without amount is left out', () {
      final out = plannedIcs([p('1', 'Dentist', '2026-03-10', 8000), p('2', 'Gift, big; one', '2026-03-12', 12550), p('3', 'No amount', '2026-03-14', null)], const [],
          from: '2026-03-01', to: '2026-03-31');
      final r = parse(out);
      expect(r.events, hasLength(2));
      final byDate = {for (final e in r.events) e.date: e};
      expect(byDate['2026-03-10']!.title, startsWith('Dentist'));
      expect(byDate['2026-03-12']!.title, startsWith('Gift, big; one'));
      expect(byDate['2026-03-10']!.allDay, isTrue);
      expect(amountFromText(byDate['2026-03-10']!.title), 8000);
      expect(amountFromText(byDate['2026-03-12']!.title), 12550);
    });

    test('confirmed bill occurrences are exported, candidates are not; UIDs are stable and distinct', () {
      const gym = RecurringBill(
          id: 'rec:g', payee: 'g', label: 'Synthetic Gym', category: 'Sport & fitness', expectedAmount: 2999, nextDue: '2026-03-05', status: 'confirmed');
      final cand = RecurringBill(
          id: 'rec:c', payee: 'c', label: 'Cand', category: 'Other', expectedAmount: 999, nextDue: '2026-03-06', status: 'candidate');
      String run() => plannedIcs([p('1', 'Dentist', '2026-03-10', 8000)], [gym, cand], from: '2026-03-01', to: '2026-05-31');
      final out = run();
      final r = parse(out, to: '2026-05-31');
      expect(r.events.where((e) => e.title.startsWith('Synthetic Gym')).map((e) => e.date), ['2026-03-05', '2026-04-04', '2026-05-04']);
      expect(r.events.any((e) => e.title.startsWith('Cand')), isFalse);
      expect({for (final e in r.events) e.uid}, hasLength(r.events.length), reason: 'distinct UIDs');
      expect([for (final e in parse(run(), to: '2026-05-31').events) e.uid], [for (final e in r.events) e.uid], reason: 'stable UIDs');
    });

    test('nothing to export still parses back to an empty list', () {
      expect(parse(plannedIcs(const [], const [], from: '2026-03-01', to: '2026-03-31')).events, isEmpty);
    });

    test('dates outside [from, to] are not exported', () {
      final out = plannedIcs([p('1', 'Early', '2026-02-01', 100), p('2', 'In', '2026-03-10', 100)], const [], from: '2026-03-01', to: '2026-03-31');
      expect(parse(out, from: '2026-01-01', to: '2026-12-31').events.map((e) => e.date), ['2026-03-10']);
    });
  });
}
