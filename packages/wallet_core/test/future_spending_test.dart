// Future spending (§4.3, docs/context/FUTURE_SPENDING_API.md): implementation tests beyond the spec tests. All data
// is SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

var _seq = 0;

CategorizedTx row(String date, int cents, {String category = 'Health', String? id, bool manual = false, String? matchedTo}) {
  final tx = Tx(
      id: id ?? 't${_seq++}',
      source: manual ? 'manual' : 'pbz',
      date: date,
      amount: cents,
      bankType: 'POS',
      description: 'Synthetic shop',
      manual: manual,
      matchedTo: matchedTo);
  return CategorizedTx(tx, category, kindOf(category));
}

PlannedCost pc(String date, int? cents,
        {String title = 'Synthetic Dentist',
        String? category = 'Health',
        PlannedStatus status = PlannedStatus.open,
        String? sourceRef,
        String? paidTx,
        bool deleted = false}) =>
    PlannedCost(
        id: 'p${_seq++}',
        title: title,
        date: date,
        amount: cents,
        category: category,
        sourceRef: sourceRef,
        status: status,
        paidTx: paidTx,
        deleted: deleted);

RecurringBill bill(String nextDue, int cents, {String category = 'Sport & fitness', int interval = 30, String payee = 'syn_gym'}) =>
    RecurringBill(
        id: RecurringBill.idFor(payee),
        payee: payee,
        label: 'Synthetic Gym',
        category: category,
        expectedAmount: cents,
        intervalDays: interval,
        nextDue: nextDue,
        status: 'confirmed');

CalendarEvent ev(String date, String title, {String uid = 'u1', String? notes}) =>
    CalendarEvent(calendarId: 'c1', uid: uid, title: title, date: date, notes: notes);

String vcal(List<String> body) => ['BEGIN:VCALENDAR', 'VERSION:2.0', ...body, 'END:VCALENDAR', ''].join('\r\n');

IcsParseResult parse(String text, {String from = '2026-03-01', String to = '2026-03-31', DateTime Function(DateTime)? toLocal}) =>
    parseIcs(text, calendarId: 'c1', from: from, to: to, toLocal: toLocal);

List<String> dates(IcsParseResult r) => [for (final e in r.events) e.date];

void main() {
  group('amountFromText edge cases', () {
    const cases = <String, int?>{
      '1 250,00 €': 125000,
      '1.250 €': 125000,
      '1,250 €': 125000,
      'EUR 80': 8000,
      'eur80,5': 8050,
      '80 eura': 8000,
      '€ 1.250,50': 125050,
      'Dentist at 14:30, 2026': null,
      'Room 2 80 €': 8000,
      '1.250.00 €': null,
      '0.250 €': null,
      '80 €, then -80 €': 8000,
      '12 Europa': null,
      '80 euros later': null,
      'x80€y': 8000,
    };
    for (final MapEntry(key: text, value: want) in cases.entries) {
      test("'$text' -> $want", () => expect(amountFromText(text), want));
    }
  });

  group('normalizeTitle', () {
    test('punctuation and the euro sign go, letters stay', () {
      expect(normalizeTitle('Đuro: dentist (80 €)!'), 'duro dentist');
      expect(normalizeTitle(''), '');
      expect(normalizeTitle('EUR 80 Gym'), 'gym');
    });
  });

  group('parseIcs details', () {
    test('TZID keeps the wall date; UTC uses toLocal when given, else the UTC date', () {
      final late = vcal(['BEGIN:VEVENT', 'UID:a', 'DTSTART:20260310T233000Z', 'SUMMARY:Late', 'END:VEVENT']);
      expect(dates(parse(late)), ['2026-03-10']);
      expect(dates(parse(late, toLocal: (t) => t.add(const Duration(hours: 1)))), ['2026-03-11']);
      final tz = vcal(['BEGIN:VEVENT', 'UID:a', 'DTSTART;TZID="Europe/Zagreb":20260310T000500', 'SUMMARY:Early', 'END:VEVENT']);
      expect(dates(parse(tz, toLocal: (t) => t.subtract(const Duration(hours: 5)))), ['2026-03-10'], reason: 'wall time, no conversion');
    });

    test('a VALARM inside the event does not override its fields; VTIMEZONE is ignored', () {
      final text = vcal([
        'BEGIN:VTIMEZONE', 'TZID:Europe/Zagreb', 'BEGIN:STANDARD', 'DTSTART:19701025T030000', 'END:STANDARD', 'END:VTIMEZONE', //
        'BEGIN:VEVENT', 'UID:a', 'DTSTART;VALUE=DATE:20260310', 'SUMMARY:Main',
        'BEGIN:VALARM', 'DESCRIPTION:Reminder', 'TRIGGER:-PT15M', 'END:VALARM', 'END:VEVENT',
      ]);
      final e = parse(text).events.single;
      expect((e.title, e.notes, e.date), ('Main', null, '2026-03-10'));
    });

    test('EXDATE with several values and several lines; RDATE adds dates', () {
      final text = vcal([
        'BEGIN:VEVENT', 'UID:a', 'DTSTART;VALUE=DATE:20260302', 'RRULE:FREQ=DAILY;COUNT=6', //
        'EXDATE;VALUE=DATE:20260303,20260304', 'EXDATE;VALUE=DATE:20260306', 'RDATE;VALUE=DATE:20260320', 'SUMMARY:S', 'END:VEVENT',
      ]);
      expect(dates(parse(text)), ['2026-03-02', '2026-03-05', '2026-03-07', '2026-03-20']);
    });

    test('RECURRENCE-ID moves one occurrence; a cancelled override drops it', () {
      final text = vcal([
        'BEGIN:VEVENT', 'UID:a', 'DTSTART;VALUE=DATE:20260302', 'RRULE:FREQ=WEEKLY;COUNT=3', 'SUMMARY:Gym', 'END:VEVENT', //
        'BEGIN:VEVENT', 'UID:a', 'RECURRENCE-ID;VALUE=DATE:20260309', 'DTSTART;VALUE=DATE:20260310', 'SUMMARY:Gym moved', 'END:VEVENT',
        'BEGIN:VEVENT', 'UID:a', 'RECURRENCE-ID;VALUE=DATE:20260316', 'DTSTART;VALUE=DATE:20260316', 'STATUS:CANCELLED', 'SUMMARY:x',
        'END:VEVENT',
      ]);
      final r = parse(text);
      expect([for (final e in r.events) '${e.date} ${e.title}'], ['2026-03-02 Gym', '2026-03-10 Gym moved']);
    });

    test('a cancelled event is dropped', () {
      expect(parse(vcal(['BEGIN:VEVENT', 'UID:a', 'DTSTART;VALUE=DATE:20260310', 'STATUS:CANCELLED', 'END:VEVENT'])).events, isEmpty);
    });

    List<String> rule(String start, String rrule, {String from = '2026-03-01', String to = '2026-03-31'}) => dates(
        parse(vcal(['BEGIN:VEVENT', 'UID:r', 'DTSTART;VALUE=DATE:$start', 'RRULE:$rrule', 'SUMMARY:R', 'END:VEVENT']), from: from, to: to));

    test('more rules: weekdays, last day of the month, every Monday, yearly BYMONTH, UNTIL as UTC date-time', () {
      expect(rule('20260302', 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR', to: '2026-03-08').length, 5);
      expect(rule('20260302', 'FREQ=DAILY;BYDAY=SA,SU', to: '2026-03-15'),
          ['2026-03-02', '2026-03-07', '2026-03-08', '2026-03-14', '2026-03-15'],
          reason: 'DTSTART is always the first occurrence');
      expect(rule('20260131', 'FREQ=MONTHLY;BYMONTHDAY=-1', from: '2026-01-01', to: '2026-04-30'),
          ['2026-01-31', '2026-02-28', '2026-03-31', '2026-04-30']);
      expect(rule('20260302', 'FREQ=MONTHLY;BYDAY=MO'), ['2026-03-02', '2026-03-09', '2026-03-16', '2026-03-23', '2026-03-30']);
      expect(rule('20240229', 'FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29', from: '2024-01-01', to: '2029-01-01'), ['2024-02-29', '2028-02-29']);
      expect(rule('20260302', 'FREQ=DAILY;UNTIL=20260304T225959Z'), ['2026-03-02', '2026-03-03', '2026-03-04']);
      expect(rule('20260302', 'FREQ=MONTHLY;INTERVAL=2', from: '2026-01-01', to: '2026-12-31'),
          ['2026-03-02', '2026-05-02', '2026-07-02', '2026-09-02', '2026-11-02']);
      expect(rule('20260310', 'FREQ=YEARLY;INTERVAL=2', from: '2026-01-01', to: '2031-12-31'), ['2026-03-10', '2028-03-10', '2030-03-10']);
    });

    test('unsupported parts give the first occurrence and count once per event', () {
      for (final r in ['FREQ=MONTHLY;BYSETPOS=-1;BYDAY=MO,TU', 'FREQ=YEARLY;BYDAY=1SU', 'FREQ=WEEKLY;BYDAY=2MO', 'FREQ=DAILY;INTERVAL=0']) {
        final res = parse(vcal(['BEGIN:VEVENT', 'UID:r', 'DTSTART;VALUE=DATE:20260302', 'RRULE:$r', 'SUMMARY:R', 'END:VEVENT']));
        expect(dates(res), ['2026-03-02'], reason: r);
        expect(res.unsupported, 1, reason: r);
      }
    });

    test('an event without DTSTART is counted and dropped; a missing UID still gives distinct refs', () {
      final res = parse(vcal([
        'BEGIN:VEVENT', 'SUMMARY:No start', 'END:VEVENT', //
        'BEGIN:VEVENT', 'DTSTART;VALUE=DATE:20260310', 'SUMMARY:A', 'END:VEVENT',
        'BEGIN:VEVENT', 'DTSTART;VALUE=DATE:20260310', 'SUMMARY:B', 'END:VEVENT',
      ]));
      expect(res.unsupported, 1);
      expect({for (final e in res.events) e.ref}, hasLength(2));
    });

    test('a bad range gives nothing', () {
      final text = vcal(['BEGIN:VEVENT', 'UID:a', 'DTSTART;VALUE=DATE:20260310', 'END:VEVENT']);
      expect(parse(text, from: '2026-04-01', to: '2026-03-01').events, isEmpty);
      expect(parse(text, from: 'x', to: '2026-03-31').events, isEmpty);
    });

    test('a big file parses quickly', () {
      final body = <String>[
        for (var i = 0; i < 3000; i++) ...[
          'BEGIN:VEVENT', 'UID:e$i', 'DTSTART:2026${(1 + i % 12).toString().padLeft(2, '0')}10T090000', //
          if (i % 3 == 0) 'RRULE:FREQ=WEEKLY;BYDAY=MO,TH', 'SUMMARY:Event $i', 'END:VEVENT',
        ],
      ];
      final sw = Stopwatch()..start();
      final res = parse(vcal(body), from: '2026-01-01', to: '2026-12-31');
      expect(res.events.length, greaterThan(3000));
      expect(sw.elapsedMilliseconds, lessThan(5000));
    });

    test('the parser and the export log no titles', () {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      addTearDown(() async {
        await sub.cancel();
        Logger.root.level = was;
      });
      parse(vcal(['BEGIN:VEVENT', 'UID:SecretUid', 'DTSTART;VALUE=DATE:20260310', 'SUMMARY:SecretTitle 80 €', 'END:VEVENT']));
      plannedIcs([pc('2026-03-10', 8000, title: 'SecretTitle')], const [], from: '2026-03-01', to: '2026-03-31');
      final r = WalletRepo.inMemory();
      final id = r.addPlanned(title: 'SecretTitle', date: '2026-03-10', amount: 8123, category: 'Health');
      r.markPlannedPaid(id, 'SecretTx');
      r.close();
      expect(lines, isNotEmpty);
      for (final l in lines) {
        expect(l.contains('Secret') || l.contains('8123') || l.contains('80'), isFalse, reason: l);
      }
    });
  });

  group('plannedIcs format', () {
    test('CRLF, lines of at most 75 octets, escaped text, one VEVENT per open or paid cost with an amount', () {
      const long = 'Very long synthetic planned cost title with čćžšđ letters, commas; and more words to fold it';
      final out = plannedIcs([
        pc('2026-03-10', 125050, title: long),
        pc('2026-03-11', 100, status: PlannedStatus.paid),
        pc('2026-03-12', 100, status: PlannedStatus.skipped),
        pc('2026-03-13', 100, deleted: true),
      ], const [], from: '2026-03-01', to: '2026-03-31');
      expect(out.contains('\n') && !out.replaceAll('\r\n', '').contains('\n'), isTrue);
      for (final l in out.split('\r\n')) {
        expect(l.codeUnits.isEmpty || l.length <= 75, isTrue);
      }
      expect(RegExp('BEGIN:VEVENT').allMatches(out).length, 2);
      final e = parse(out).events.first;
      expect(e.title, '$long · 1.250,50 €');
      expect(amountFromText(e.title), 125050);
    });
  });

  group('upcoming details', () {
    test('an overdue bill shows from its next occurrence; an interval below 1 gives one date', () {
      expect([
        for (final i
            in upcoming(planned: const [], bills: [bill('2026-02-20', 100)], events: const [], from: '2026-03-01', to: '2026-04-30'))
          i.date
      ], [
        '2026-03-22',
        '2026-04-21'
      ]);
      expect([
        for (final i in upcoming(
            planned: const [], bills: [bill('2026-03-05', 100, interval: 0)], events: const [], from: '2026-03-01', to: '2026-04-30'))
          i.date
      ], [
        '2026-03-05'
      ]);
    });

    test('bill keys are unique per occurrence; a covered bill is listed with its bill', () {
      final items = upcoming(
          planned: const [], bills: [bill('2026-03-01', 50000, category: 'Rent')], events: const [], from: '2026-03-01', to: '2026-04-30');
      expect({for (final i in items) i.key}, hasLength(3));
      expect(items.every((i) => i.bill!.coveredByPlan && i.amount == 50000), isTrue);
    });

    test('earlier suggestion: the latest one before the event, never a later one; deleted and skipped never; category suggested', () {
      final planned = [
        pc('2026-01-10', 6000, title: 'Dentist', category: 'Health'),
        pc('2026-02-10', 6500, title: 'DENTIST 2026', category: 'Health', status: PlannedStatus.paid),
        pc('2026-02-20', 9900, title: 'Dentist', status: PlannedStatus.skipped),
        pc('2026-02-25', 9900, title: 'Dentist', deleted: true),
        pc('2026-04-10', 7000, title: 'Dentist'),
      ];
      final s = upcoming(planned: planned, bills: const [], events: [ev('2026-03-10', 'dentist')], from: '2026-03-01', to: '2026-03-31')
          .singleWhere((i) => i.kind == UpcomingKind.suggestion);
      expect((s.suggested, s.suggestedFrom, s.category), (6500, 'earlier', 'Health'));
    });

    test('a title amount wins over an earlier one; the same event twice is listed once', () {
      final e = ev('2026-03-10', 'Dentist 80 €');
      final items = upcoming(
          planned: [pc('2026-01-10', 6000, title: 'Dentist')], bills: const [], events: [e, e], from: '2026-03-01', to: '2026-03-31');
      expect(items.single.suggested, 8000);
      expect(items.single.suggestedFrom, 'title');
    });
  });

  group('paidCandidates details', () {
    test('a hand entry replaced by a bank row is not offered; a tie in date and amount goes by id', () {
      final p = pc('2026-03-10', 8000);
      final replaced = row('2026-03-10', -8000, id: 'm1', manual: true, matchedTo: 'b1');
      final c = paidCandidates(p, [row('2026-03-10', -8000, id: 'b2'), replaced, row('2026-03-10', -8000, id: 'b1')], [p]);
      expect([for (final x in c) x.tx.id], ['b1', 'b2']);
    });

    test('a planned cost without an amount still gets same-category candidates, by date only', () {
      final p = pc('2026-03-10', null);
      final c = paidCandidates(p, [row('2026-03-12', -100, id: 'far'), row('2026-03-11', -99999, id: 'near')], [p]);
      expect([for (final x in c) x.tx.id], ['near', 'far']);
    });
  });

  group('headsUps details', () {
    test('negative days or a bad date give nothing', () {
      final items = upcoming(planned: [pc('2026-03-02', 50000)], bills: const [], events: const [], from: '2026-03-01', to: '2026-03-31');
      expect(headsUps(items, '2026-03-01', thresholdCents: 0, days: -1), isEmpty);
      expect(headsUps(items, 'today', thresholdCents: 0, days: 3), isEmpty);
      expect(headsUps(items, '2026-03-01', thresholdCents: 50000, days: 1).single.daysLeft, 1);
    });
  });

  group('computePeriod with bills and planned costs', () {
    const today = '2026-03-01';
    final st = WalletSettings.fromMap({'salary': 200000, 'rent': 50000, 'periodStart': '2026-02-15', 'paydayDay': 15});

    test('a bill and a planned cost reserve once each, never twice; no category is reserved', () {
      final p = computePeriod(const [], st, const [], today,
          bills: [bill('2026-03-05', 2999)],
          planned: [pc('2026-03-05', 1000, category: 'Groceries'), pc('2026-03-06', 500, category: null)]);
      expect((p.reservedBills, p.reservedPlanned), (2999, 1500));
      expect(p.flexBudget, 200000 - 50000 - 2999 - 1500);
      expect(p.remaining, p.flexBudget);
    });

    test('a planned cost in a fixed category is listed but never reserved (already in the fixed plan)', () {
      final rent = pc('2026-03-05', 50000, title: 'Rent', category: 'Rent');
      expect(rent.coveredByPlan, isTrue);
      expect(pc('2026-03-05', 1, category: null).coveredByPlan, isFalse);
      final p = computePeriod(const [], st, const [], today, planned: [rent, pc('2026-03-06', 700, category: 'Loan')]);
      expect(p.reservedPlanned, 0);
      expect(p.duePlanned, hasLength(2));
      expect(p.flexBudget, computePeriod(const [], st, const [], today).flexBudget);
      final items = upcoming(planned: [rent], bills: const [], events: const [], from: today, to: '2026-03-31');
      expect(items.single.amount, 50000);
      expect(headsUps(items, today, thresholdCents: 10000, days: 7).single.item.planned, rent);
    });

    test('a damaged non-positive amount reserves nothing', () {
      final p = computePeriod(const [], st, const [], today, planned: [pc('2026-03-05', -1000), pc('2026-03-05', 0)]);
      expect(p.reservedPlanned, 0);
    });

    test('the paying row counts as spent only once it is marked: while open, spending and reservation both count (until its date)', () {
      final txs = [row('2026-03-01', -4000, category: 'Shopping', id: 'pay')];
      final open = computePeriod(txs, st, const [], today, planned: [pc('2026-03-03', 4000, category: 'Shopping')]);
      final paid = computePeriod(txs, st, const [], today,
          planned: [pc('2026-03-03', 4000, category: 'Shopping', status: PlannedStatus.paid, paidTx: 'pay')]);
      expect(open.reservedPlanned, 4000);
      expect(paid.reservedPlanned, 0);
      expect(paid.spent, 4000);
    });
  });

  group('repo', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('bad input is an ArgumentError and writes nothing', () {
      expect(() => r.addPlanned(title: 'x', date: '2026-02-30'), throwsArgumentError);
      expect(() => r.addPlanned(title: 'x', date: '2026-03-01', amount: 0), throwsArgumentError);
      expect(() => r.addPlanned(title: 'x', date: '2026-03-01', amount: -5), throwsArgumentError);
      expect(() => r.updatePlanned('nope', title: 'y'), throwsArgumentError);
      expect(() => r.markPlannedPaid('nope', 't'), throwsArgumentError);
      expect(() => r.skipPlanned('nope'), throwsArgumentError);
      expect(() => r.deletePlanned('nope'), throwsArgumentError);
      expect(() => r.dismissCalendarEvent('', '2026-03-01'), throwsArgumentError);
      expect(r.pendingOps(), isEmpty);
      expect(r.isEmpty, isTrue);
    });

    test('update clears amount and category on request; reopen undoes paid', () {
      final id = r.addPlanned(title: 'Gift', date: '2026-03-10', amount: 3000, category: 'Shopping');
      r.updatePlanned(id, clearAmount: true, clearCategory: true);
      expect((r.plannedCosts().single.amount, r.plannedCosts().single.category), (null, null));
      r.markPlannedPaid(id, 'tx1');
      expect(r.plannedCosts(), isEmpty);
      r.reopenPlanned(id);
      final p = r.plannedCosts().single;
      expect((p.status, p.paidTx), (PlannedStatus.open, null));
      expect(r.isEmpty, isFalse);
    });

    test('a calendar row uses the ref as id: confirm after dismiss reopens it; dismiss after confirm keeps the title', () {
      final e = ev('2026-03-10', 'Concert');
      r.dismissCalendarEvent(e.ref, e.date);
      final id = r.addPlanned(title: 'Concert', date: e.date, amount: 4500, source: PlannedSource.calendar, sourceRef: e.ref);
      expect(id, 'calendar:${e.ref}');
      expect(r.plannedCosts(includeClosed: true), hasLength(1));
      expect(r.plannedCosts().single.amount, 4500);
      r.dismissCalendarEvent(e.ref, e.date);
      final row = r.plannedCosts(includeClosed: true).single;
      expect((row.title, row.status, row.amount), ('Concert', PlannedStatus.skipped, 4500));
    });

    test('searchAll finds planned costs by title, category and exact amount, never deleted ones', () {
      final a = pc('2026-03-10', 4550, title: 'Synthetic Đuro gift', category: 'Shopping');
      final gone = pc('2026-03-10', 4550, title: 'Gone', deleted: true);
      SearchResult s(String q) => searchAll(q, txs: const [], goals: const [], wishlist: const [], bills: const [], planned: [a, gone]);
      expect(s('djuro').planned, [a]);
      expect(s('shop').planned, [a]);
      expect(s('45,50').planned, [a]);
      expect(s('45').planned, isEmpty);
      expect(s('gone').isEmpty, isTrue);
    });

    test('an existing schema-5 database gets the planned table and replays the relay once', () {
      final tmp = Directory.systemTemp.createTempSync('bw-planned-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/w.db';
      final old = WalletRepo.open(path);
      old.setSyncCursor('dev', 3);
      old.db.execute("UPDATE meta SET value = '5' WHERE key = 'schema'");
      old.db.execute('DROP TABLE planned');
      old.close();
      final up = WalletRepo.open(path);
      expect(up.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
      expect(up.syncCursors(), isEmpty);
      expect(up.plannedCosts(), isEmpty);
      up.addPlanned(title: 'x', date: '2026-03-01', amount: 1);
      expect(up.plannedCosts(), hasLength(1));
      up.close();
    });
  });

  group('two devices over the relay', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
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
      tmp = Directory.systemTemp.createTempSync('bw-planned-');
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

    test('both devices confirm the same event offline: one row, the later edit wins; a dismiss elsewhere hides it everywhere', () async {
      final a = device('a'), b = device('b');
      final e = ev('2026-03-10', 'Synthetic concert');
      a.repo.addPlanned(title: 'Concert', date: e.date, amount: 4000, source: PlannedSource.calendar, sourceRef: e.ref);
      now += 5000;
      b.repo.addPlanned(title: 'Concert', date: e.date, amount: 4500, source: PlannedSource.calendar, sourceRef: e.ref);
      await round();
      await round();
      for (final d in [a, b]) {
        expect(d.repo.plannedCosts(includeClosed: true), hasLength(1));
        expect(d.repo.plannedCosts().single.amount, 4500);
      }
      expect(dump(a.repo, clocks: false)['planned'], dump(b.repo, clocks: false)['planned']);

      final f = ev('2026-03-12', 'Synthetic other');
      b.repo.dismissCalendarEvent(f.ref, f.date);
      final id = a.repo.addPlanned(title: 'Manual', date: '2026-03-11', amount: 700, category: 'Health');
      await round();
      await round();
      final items = upcoming(
          planned: a.repo.plannedCosts(includeClosed: true), bills: const [], events: [e, f], from: '2026-03-01', to: '2026-03-31');
      expect([for (final i in items) i.kind], [UpcomingKind.planned, UpcomingKind.planned]);
      b.repo.markPlannedPaid(id, 'some-tx');
      await round();
      await round();
      expect(a.repo.plannedCosts().map((p) => p.id), isNot(contains(id)));
      final st = WalletSettings.fromMap({'salary': 100000, 'periodStart': '2026-02-15', 'paydayDay': 15});
      final pa = computePeriod(const [], st, const [], '2026-03-01', planned: a.repo.plannedCosts());
      final pb = computePeriod(const [], st, const [], '2026-03-01', planned: b.repo.plannedCosts());
      expect((pa.reservedPlanned, pb.reservedPlanned), (4500, 4500));
    });
  });
}
