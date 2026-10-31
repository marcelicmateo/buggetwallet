// Stage F3: future spending in the app. Planned costs, the Upcoming screen (grid + list), Today's "Coming up" and heads-up
// lines, Plan › Calendars (phone calendars through a fake source, .ics files and links), heads-up notifications, Plan › Export
// and the log privacy of all of it. All data is SYNTHETIC (futureWallet: Tuesday 20 Oct 2026).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:budget_wallet/src/calendar_source.dart';
import 'package:budget_wallet/src/calendar_source_io.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/ics_fetch.dart';
import 'package:budget_wallet/src/nudges.dart';
import 'package:budget_wallet/src/screens/calendars_panel.dart';
import 'package:budget_wallet/src/screens/export_panel.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/screens/upcoming.dart';
import 'package:budget_wallet/src/screens/upcoming_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/plan_page.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

WalletController fw({FakeNudges? nudges, FakeCalendars? calendars}) {
  final wc = futureWallet(nudges: nudges, calendars: calendars);
  addTearDown(wc.dispose);
  return wc;
}

/// A widget test that lets the controller's 3 s sync debounce run out before it ends (no timer may be pending).
void tw(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
      await body(tester);
      await tester.pump(const Duration(seconds: 4));
    });

class _Picked extends PickedFile {
  _Picked(String name, Uint8List data) : super(name, () async => data, length: () async => data.length);
}

class _Chooser extends FileChooser {
  List<PickedFile> picks = [];
  final saved = <({String name, Uint8List bytes})>[];
  @override
  Future<List<PickedFile>> pickCalendarFile() async => picks;
  @override
  Future<Uri?> saveText({required String fileName, required Uint8List bytes, required String title}) async {
    saved.add((name: fileName, bytes: bytes));
    return Uri(path: fileName);
  }
}

class _RealHttp extends HttpOverrides {}

Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

const _events = [
  CalendarEvent(calendarId: 'c1', uid: 'e1', title: 'Birthday party 80 €', date: '2026-10-24'),
  CalendarEvent(calendarId: 'c1', uid: 'e2', title: 'Haircut', date: '2026-10-26'),
  CalendarEvent(calendarId: 'c2', uid: 'e3', title: 'Work lunch', date: '2026-10-28'),
];

/// A wallet whose phone calendar c1 is switched on and read.
Future<WalletController> withCalendar({FakeNudges? nudges}) async {
  final cals = FakeCalendars(granted: true, eventList: _events);
  final wc = fw(nudges: nudges, calendars: cals);
  await wc.requestCalendarAccess();
  await wc.setCalendarOn('c1', true);
  return wc;
}

Widget todayOf(WalletController wc) =>
    Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday, chooser: const FileChooser()));

String eur(String s) => s.replaceAll(' €', '\u00A0€');

Finder key(String k) => find.byKey(ValueKey(k));

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  group('planned costs in the controller', () {
    test('the test wallet has a pay period that holds both planned costs', () {
      final wc = fw();
      expect(wc.period().end.compareTo('2026-10-28'), greaterThan(0));
    });

    test('comingUp counts the planned costs with an amount before payday', () {
      final wc = fw();
      final c = wc.comingUp();
      expect(c.count, 2);
      expect(c.total, 42000);
    });

    test('a planned cost without a title is shown nowhere and one added by hand counts at once', () {
      final wc = fw();
      wc.addPlannedCost(title: ' Gift ', date: '2026-10-25', amount: 5000, category: 'Shopping');
      expect(wc.comingUp().count, 3);
      expect(wc.comingUp().total, 47000);
      expect(wc.plannedOpen().map((p) => p.title), contains('Gift'), reason: 'the title is trimmed');
    });

    test('a calendar event with an amount in its title is a suggestion that does not count until confirmed', () async {
      final wc = await withCalendar();
      final r = wc.upcomingRange();
      final s = wc.upcomingItems(r.start, r.end).where((i) => i.kind == UpcomingKind.suggestion).toList();
      expect(s.map((i) => i.title), ['Birthday party 80 €', 'Haircut']);
      expect(s.first.suggested, 8000);
      expect(s.last.suggested, isNull);
      expect(wc.comingUp().count, 2, reason: 'suggestions never count');
      wc.confirmSuggestion(s.first, amount: 8000);
      expect(wc.comingUp().count, 3);
      expect(wc.comingUp().total, 50000);
      final again = wc.upcomingItems(r.start, r.end);
      expect(again.where((i) => i.kind == UpcomingKind.suggestion).map((i) => i.title), ['Haircut'], reason: 'listed once, as planned');
      expect(wc.plannedOpen().firstWhere((p) => p.date == '2026-10-24').source, PlannedSource.calendar);
    });

    test('"No cost" stores no title and the event never comes back, also after a new read', () async {
      final wc = await withCalendar();
      final r = wc.upcomingRange();
      final hair = wc.upcomingItems(r.start, r.end).firstWhere((i) => i.title == 'Haircut');
      wc.dismissSuggestion(hair);
      await wc.readCalendars();
      expect(wc.upcomingItems(r.start, r.end).where((i) => i.title == 'Haircut'), isEmpty);
      expect(wc.plannedEverything().where((p) => p.title == 'Haircut'), isEmpty);
      expect(wc.plannedEverything().where((p) => p.status == PlannedStatus.skipped && p.title.isEmpty), hasLength(1));
    });

    test('Paid offers payments of the same category within 3 days, never by amount, and takes the cost out of the plan', () {
      final wc = fw();
      final insurance = wc.plannedOpen().firstWhere((p) => p.title == 'Car insurance');
      final c = wc.paidCandidatesFor(insurance);
      expect(c, hasLength(1));
      expect(c.single.date, '2026-10-22');
      expect(wc.paidCandidatesFor(wc.plannedOpen().firstWhere((p) => p.title == 'Dentist')), isEmpty);
      wc.markPlannedPaid(insurance, c.single.tx);
      expect(wc.comingUp().count, 1);
      expect(wc.plannedOpen().map((p) => p.title), ['Dentist']);
    });

    test('Skip and Delete take a cost out of the plan', () {
      final wc = fw();
      wc.skipPlanned(wc.plannedOpen().first);
      expect(wc.comingUp().count, 1);
      wc.deletePlanned(wc.plannedOpen().first);
      expect(wc.comingUp().count, 0);
    });

    test('a bill-sized planned cost shows as a heads-up 3 days ahead; small ones and suggestions do not', () async {
      final wc = await withCalendar();
      expect(wc.headsUpCents, 10000);
      expect(wc.headsUpDays, 3);
      final h = wc.headsUpLines();
      expect(h.map((x) => x.item.title), ['Car insurance']);
      expect(h.single.daysLeft, 3);
      wc.saveHeadsUp(cents: 5000, days: 7);
      expect(wc.headsUpLines().map((x) => x.item.title), ['Car insurance', 'Dentist']);
    });

    test('planned export holds the costs with an amount and nothing else', () {
      final wc = fw();
      final f = wc.exportPlannedIcs();
      final text = utf8.decode(f.bytes);
      expect(f.name, 'budget-wallet-planned.ics');
      expect(f.rows, 2);
      expect(text, contains('Car insurance'));
      expect(text, contains('BEGIN:VCALENDAR'));
      expect(emptyWallet().exportPlannedIcs().rows, 0);
    });

    test('search finds planned costs by name', () {
      final wc = fw();
      expect(wc.searchPlanned('insur').map((p) => p.title), ['Car insurance']);
      expect(wc.searchPlanned('x'), isEmpty);
    });
  });

  group('calendars in the controller', () {
    test('permission refused: nothing is listed and the refusal is remembered', () async {
      final cals = FakeCalendars(allow: false);
      final wc = fw(calendars: cals);
      await wc.checkCalendarAccess();
      expect(wc.cal.permission, isFalse);
      expect(await wc.requestCalendarAccess(), isFalse);
      expect(wc.cal.denied, isTrue);
      expect(wc.calendarEntries(), isEmpty);
    });

    test('permission granted: the phone calendars are listed, off until chosen', () async {
      final cals = FakeCalendars();
      final wc = fw(calendars: cals);
      expect(await wc.requestCalendarAccess(), isTrue);
      expect(wc.calendarEntries().map((e) => (e.name, e.on)), [('Family', false), ('Work', false)]);
      await wc.setCalendarOn('c2', true);
      expect(wc.calendarEntries().map((e) => e.on), [false, true]);
      expect(cals.reads, 1);
    });

    test('a failing phone read leaves the app working', () async {
      final cals = FakeCalendars(granted: true, failWith: StateError('provider gone'), eventList: _events);
      final wc = fw(calendars: cals);
      await wc.setCalendarOn('c1', true);
      expect(wc.cal.events, isEmpty);
      expect(lines.join('\n'), contains('calendar.deviceReadFailed'));
    });

    test('an .ics file is kept on the device and its events become suggestions', () async {
      final wc = fw();
      final ics = fakeIcs([('u1', '2026-10-25', 'Car service 120 €'), ('u2', '2026-10-30', 'Dentist check')]);
      expect(await wc.importIcsFile('family.ics', bytesOf(ics)), isNull);
      expect(wc.calendarEntries().single.name, 'family');
      final r = wc.upcomingRange();
      final s = wc.upcomingItems(r.start, r.end).where((i) => i.kind == UpcomingKind.suggestion).toList();
      expect(s.map((i) => i.suggested), [12000, null]);
    });

    test('a file that is not a calendar is refused with a message and saves nothing', () async {
      final wc = fw();
      final msg = await wc.importIcsFile('notes.ics', bytesOf('just some text'));
      expect(msg, contains("doesn't look like a calendar"));
      expect(wc.calendarEntries(), isEmpty);
    });

    test('a file over 2 MB is refused with a clear message', () async {
      final wc = fw();
      final msg = await wc.importIcsFile('big.ics', Uint8List(icsMaxBytes + 1));
      expect(msg, contains('2 MB'));
      expect(wc.calendarEntries(), isEmpty);
    });

    test('an .ics link is fetched, kept, and read again; when the refresh fails the saved copy is used and the entry says so', () async {
      final wc = fw();
      var fail = false;
      wc.seams.icsFetcher = (u) async {
        if (fail) throw const IcsFetchException('The link took too long to answer.');
        return fakeIcs([('u1', '2026-10-25', 'Car service 120 €')]);
      };
      expect(await wc.addIcsLink('webcal://example.org/me.ics'), isNull);
      expect(wc.cal.events, hasLength(1));
      fail = true;
      await wc.readCalendars(trigger: 'resume');
      expect(wc.cal.events, hasLength(1), reason: 'the saved copy is still used');
      final e = wc.calendarEntries().single;
      expect(e.kind, CalendarKind.link);
      expect(e.error, allOf(contains("Couldn't refresh"), contains('Showing what was saved')));
    });

    test('a fresh link text that cannot be saved is still read this time; the entry says the refresh failed', () async {
      final wc = fw();
      var closeDuringFetch = false;
      wc.seams.icsFetcher = (u) async {
        if (closeDuringFetch) wc.repo.close(); // the save of the fresh copy then throws
        return fakeIcs([(closeDuringFetch ? 'u2' : 'u1', '2026-10-25', 'Car service 120 €')]);
      };
      expect(await wc.addIcsLink('webcal://example.org/me.ics'), isNull);
      final id = wc.calendarEntries().single.id;
      closeDuringFetch = true;
      await wc.readCalendars(trigger: 'resume');
      expect(wc.cal.events.single.uid, 'u2', reason: 'the fresh text is read even though keeping it failed');
      expect(wc.cal.errorFor(id), allOf(contains("Couldn't refresh"), contains('Showing what was saved')));
    });

    test('bad links are refused before any request', () async {
      final wc = fw();
      var asked = 0;
      wc.seams.icsFetcher = (u) async {
        asked++;
        return '';
      };
      expect(await wc.addIcsLink('ftp://example.org/x.ics'), contains('http'));
      expect(await wc.addIcsLink('not a link'), isNotNull);
      expect(asked, 0);
      wc.seams.icsFetcher = (u) async => throw const IcsFetchException("Couldn't reach the link. Check the network.");
      expect(await wc.addIcsLink('https://example.org/x.ics'), contains("Couldn't reach"));
      expect(wc.calendarEntries(), isEmpty);
    });

    test('removing a calendar forgets its events', () async {
      final wc = fw();
      await wc.importIcsFile('a.ics', bytesOf(fakeIcs([('u1', '2026-10-25', 'Car service')])));
      expect(wc.cal.events, hasLength(1));
      wc.removeCalendarSource(wc.calendarEntries().single.id);
      await Future<void>.delayed(Duration.zero);
      expect(wc.calendarEntries(), isEmpty);
      expect(wc.cal.events, isEmpty);
    });
  });

  group('G4: bad saved values and a failing plugin', () {
    test('a calendar source with an unknown kind is skipped and logged (a count, no text); the others still load', () {
      final wc = fw();
      wc.repo.setLocalValue(
          'icsSources',
          jsonEncode([
            {'id': 'a', 'name': 'Synthetic cloud', 'kind': 'cloud'},
            {'id': 'b', 'name': 'Synthetic file', 'kind': 'file'},
          ]));
      late List<CalendarEntry> entries;
      expect(() => entries = wc.calendarEntries(), returnsNormally);
      expect([for (final e in entries) e.id], ['b']);
      wc.calendarEntries();
      wc.calendarEntries();
      final skipped = lines.where((l) => l.contains('calendar.sourceSkipped')).toList();
      expect(skipped.length, 1, reason: 'logged once, not on every read');
      expect(skipped.join(), allOf(isNot(contains('Synthetic')), isNot(contains('cloud'))));
    });

    test('a saved list that is not JSON gives an empty list and logs only the key', () {
      final wc = fw();
      wc.repo.setLocalValue('calendarsOn', '{not json SYNTHETIC-SECRET');
      wc.repo.setLocalValue('icsSources', '[1,');
      expect(wc.calendarEntries(), isEmpty);
      final bad = lines.where((l) => l.contains('localList.invalid')).toList();
      expect(bad.length, greaterThanOrEqualTo(2));
      expect(bad.join(), allOf(contains('calendarsOn'), contains('icsSources'), isNot(contains('SYNTHETIC-SECRET'))));
    });

    test('one failing heads-up run does not stop the next one', () async {
      final nudges = FakeNudges();
      final wc = fw(nudges: nudges);
      wc.addPlannedCost(title: 'Annual membership', date: '2026-10-30', amount: 20000);
      await wc.setHeadsUpNotify(true);
      nudges.headsUps.clear();
      nudges.headsUpFailures = 1;
      await wc.rescheduleHeadsUps(); // throws inside the plugin: logged, not rethrown
      await wc.rescheduleHeadsUps();
      expect(nudges.headsUps, isNotEmpty, reason: 'the second call ran');
      await wc.rescheduleHeadsUps();
      expect(nudges.headsUps.length, greaterThanOrEqualTo(2));
    });

    test('a failing run that is not caught inside (the chain itself) is logged and the chain recovers', () async {
      final nudges = FakeNudges();
      final wc = fw(nudges: nudges);
      wc.cal.headsUpChain = Future<void>.error(StateError('synthetic'))..ignore();
      await wc.setHeadsUpNotify(true);
      expect(nudges.headsUps, isNotEmpty);
      expect(lines.where((l) => l.contains('headsup.chainFailed')), isNotEmpty);
    });
  });

  group('heads-up notifications', () {
    test('turned on: scheduled at 09:00 on (date - days) with a text that has no title and no amount', () async {
      final nudges = FakeNudges();
      final wc = fw(nudges: nudges);
      wc.addPlannedCost(title: 'Annual membership', date: '2026-10-30', amount: 20000);
      expect(await wc.setHeadsUpNotify(true), isTrue);
      expect(nudges.asked, 1);
      final slots = nudges.headsUps.last;
      expect(slots.map((s) => (s.date, s.hour)), [('2026-10-21', 9), ('2026-10-27', 9)],
          reason: 'the insurance slot (20 Oct 09:00) has passed: it moves to the next 09:00');
      expect(slots.first.body, 'A big planned cost is coming up in 2 days.');
      expect(slots.last.body, 'A big planned cost is coming up in 3 days.');
      for (final s in slots) {
        expect('${s.title}${s.body}', isNot(anyOf(contains('Annual'), contains('Car'), contains('200'), contains('€'))));
      }
    });

    test('rescheduled when a planned cost changes, and cancelled when the switch goes off', () async {
      final nudges = FakeNudges();
      final wc = fw(nudges: nudges);
      await wc.setHeadsUpNotify(true);
      final before = nudges.headsUps.length;
      wc.addPlannedCost(title: 'Tyres', date: '2026-11-05', amount: 30000);
      await Future<void>.delayed(Duration.zero);
      expect(nudges.headsUps.length, greaterThan(before));
      expect(nudges.headsUps.last.map((s) => s.date), contains('2026-11-02'));
      await wc.setHeadsUpNotify(false);
      expect(nudges.headsUpCancelled, greaterThan(0));
      expect(wc.headsUpNotify, isFalse);
    });

    test('the system refusing notifications keeps the switch off and schedules nothing', () async {
      final nudges = FakeNudges(allow: false);
      final wc = fw(nudges: nudges);
      expect(await wc.setHeadsUpNotify(true), isFalse);
      expect(wc.headsUpNotify, isFalse);
      expect(nudges.headsUps, isEmpty);
    });

    test('nothing is scheduled where notifications are not available', () async {
      final nudges = FakeNudges(canShow: false);
      final wc = fw(nudges: nudges);
      await wc.rescheduleHeadsUps();
      expect(nudges.headsUps, isEmpty);
    });

    test('the slots are a pure function: past days and the 20 limit', () {
      final now = DateTime(2026, 10, 20, 8);
      expect(headsUpSlots(now, [('2026-10-23', 3)]).map((s) => s.date), ['2026-10-20'], reason: 'today 09:00 is still ahead at 08:00');
      expect(headsUpSlots(DateTime(2026, 10, 20, 9), [('2026-10-23', 3)]).map((s) => s.date), ['2026-10-21'],
          reason: 'its day has passed: the next 09:00 ahead, still before the cost');
      expect(headsUpSlots(now, [('2026-10-21', 3)]).map((s) => s.date), ['2026-10-20']);
      expect(headsUpSlots(DateTime(2026, 10, 20, 9), [('2026-10-20', 3)]), isEmpty, reason: 'the cost is today and 09:00 has gone');
      expect(headsUpSlots(DateTime(2026, 10, 20, 12), [('2026-10-21', 3)]).single.body, headsUpBody(0));
      expect(headsUpSlots(now, [for (var i = 0; i < 30; i++) (addDays('2026-11-01', i), 3)]), hasLength(headsUpMax));
      expect(headsUpBody(0), isNot(contains('0 days')));
    });
  });

  group('Today', () {
    tw('shows the Before payday tile and a heads-up tile for the big cost', (tester) async {
      final wc = fw();
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1400));
      final tile = key('comingUpLine');
      expect(find.descendant(of: tile, matching: find.text('BEFORE PAYDAY')), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text(eur('420 €'))), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text('2 costs')), findsOneWidget);
      final head = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('headsUp:'));
      expect(head, findsOneWidget);
      expect(find.descendant(of: head, matching: find.text('CAR INSURANCE')), findsOneWidget);
      expect(find.descendant(of: head, matching: find.text(eur('340 €'))), findsOneWidget);
      expect(find.descendant(of: head, matching: find.text('In 3 days')), findsOneWidget);
    });

    tw('has neither line without planned costs', (tester) async {
      final wc = habitsWallet();
      addTearDown(wc.dispose);
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1400));
      expect(key('comingUpLine'), findsNothing);
    });

    tw('a calendar event without an amount is mentioned, but not counted', (tester) async {
      final wc = await withCalendar();
      await wc.setCalendarOn('c1', false);
      await wc.setCalendarOn('c1', true);
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1400));
      expect(find.descendant(of: key('comingUpLine'), matching: find.text(eur('420 €'))), findsOneWidget);
    });

    tw('tapping Coming up opens Upcoming', (tester) async {
      final wc = fw();
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1400));
      await tester.tap(key('comingUpLine'));
      await tester.pumpAndSettle();
      expect(key('periodNow'), findsOneWidget);
      expect(key('day:2026-10-23'), findsOneWidget);
    });
  });

  group('Upcoming', () {
    tw('the grid marks days and the list is ruled with date, title, amount and source', (tester) async {
      final wc = await withCalendar();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      expect(find.text('October 2026'), findsOneWidget);
      for (final d in const ['2026-10-23', '2026-10-27', '2026-10-24']) {
        expect(key('day:$d'), findsOneWidget);
      }
      final insurance = find.descendant(of: key('up:p:${wc.plannedOpen().first.id}'), matching: find.text('Car insurance'));
      expect(insurance, findsOneWidget);
      expect(find.text(eur('340 €')), findsOneWidget);
      expect(find.text(eur('Suggested 80 €')), findsOneWidget);
      expect(find.text('No amount found'), findsOneWidget);
      expect(find.text('Planned by you'), findsWidgets);
      expect(find.text('Calendar'), findsWidgets);
      expect(find.text('Set aside'), findsOneWidget);
    });

    tw('tapping a day lists just that day; Show all brings the rest back', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      await tester.tap(key('day:2026-10-23'));
      await tester.pump();
      expect(find.text('Car insurance'), findsOneWidget);
      expect(find.text('Dentist'), findsNothing);
      await tester.tap(key('showAll'));
      await tester.pump();
      expect(find.text('Dentist'), findsOneWidget);
    });

    tw('Confirm turns a suggestion into a planned cost that counts', (tester) async {
      final wc = await withCalendar();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      final confirm = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('confirm:e:'));
      expect(confirm, findsOneWidget, reason: 'only the suggestion with an amount can be confirmed as is');
      await tester.tap(confirm);
      await tester.pump();
      expect(find.text(eur('Suggested 80 €')), findsNothing);
      expect(wc.comingUp().count, 3);
      expect(wc.comingUp().total, 50000);
    });

    tw('No cost dismisses the suggestion', (tester) async {
      final wc = await withCalendar();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      final no = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('nocost:e:'));
      expect(no, findsNWidgets(2));
      await tester.tap(no.first);
      await tester.pump();
      expect(find.text('Birthday party 80 €'), findsNothing);
      expect(find.text('Haircut'), findsOneWidget);
      expect(wc.comingUp().count, 2);
    });

    tw('Change on a suggestion without an amount asks for one, then adds it to the plan', (tester) async {
      final wc = await withCalendar();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      final hair = find.descendant(
          of: find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('up:e:')).last,
          matching: find.text('Add amount'));
      await tester.tap(hair);
      await tester.pumpAndSettle();
      await tester.tap(key('plannedSave'));
      await tester.pump();
      expect(find.textContaining('Enter an amount, like 12.50.'), findsOneWidget);
      await tester.enterText(key('plannedAmount'), '25');
      await tester.tap(key('plannedSave'));
      await tester.pumpAndSettle();
      expect(wc.plannedOpen().where((p) => p.title == 'Haircut' && p.amount == 2500), hasLength(1));
    });

    tw('+ Planned cost: needs a name and an amount, then the cost is in the list', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      await tester.tap(key('addPlanned'));
      await tester.pumpAndSettle();
      await tester.tap(key('plannedSave'));
      await tester.pump();
      expect(find.textContaining('Give it a name'), findsOneWidget);
      await tester.enterText(key('plannedTitle'), 'Tyres');
      await tester.enterText(key('plannedAmount'), '30,50');
      await tester.tap(key('plannedSave'));
      await tester.pumpAndSettle();
      expect(find.text('Tyres'), findsOneWidget);
      expect(wc.plannedOpen().firstWhere((p) => p.title == 'Tyres').amount, 3050);
    });

    tw('the entry sheet: Paid lists the matching payments and picking one takes the cost out', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      await tester.tap(key('up:p:${wc.plannedOpen().first.id}'));
      await tester.pumpAndSettle();
      await tester.tap(key('entryPaid'));
      await tester.pump();
      expect(key('paidWhich'), findsOneWidget);
      final pay = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('pay:'));
      expect(pay, findsOneWidget);
      await tester.tap(pay);
      await tester.pumpAndSettle();
      expect(find.text('Car insurance'), findsNothing);
      expect(wc.plannedOpen().map((p) => p.title), ['Dentist']);
    });

    tw('Paid with no matching payment says so', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      await tester.tap(key('up:p:${wc.plannedOpen().last.id}'));
      await tester.pumpAndSettle();
      await tester.tap(key('entryPaid'));
      await tester.pump();
      expect(find.textContaining('No matching payment yet'), findsOneWidget);
    });

    tw('Skip and Delete from the entry sheet', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      await tester.tap(key('up:p:${wc.plannedOpen().first.id}'));
      await tester.pumpAndSettle();
      await tester.tap(key('entrySkip'));
      await tester.pumpAndSettle();
      expect(find.text('Car insurance'), findsNothing);
      await tester.tap(key('up:p:${wc.plannedOpen().first.id}'));
      await tester.pumpAndSettle();
      await tester.tap(key('entryDelete'));
      await tester.pumpAndSettle();
      expect(find.text('Dentist'), findsNothing);
      expect(find.textContaining('Nothing planned in this period'), findsOneWidget);
    });

    tw('Change edits the amount', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      await tester.tap(key('up:p:${wc.plannedOpen().first.id}'));
      await tester.pumpAndSettle();
      await tester.tap(key('entryEdit'));
      await tester.pumpAndSettle();
      await tester.enterText(key('plannedAmount'), '355');
      await tester.tap(key('plannedSave'));
      await tester.pumpAndSettle();
      expect(wc.plannedOpen().firstWhere((p) => p.title == 'Car insurance').amount, 35500);
    });

    tw('the next period link shows the days after payday', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      final next = wc.upcomingRange(next: true);
      await tester.tap(key('periodNext'));
      await tester.pump();
      expect(key('day:${next.start}'), findsOneWidget);
      expect(key('day:2026-10-23'), findsNothing);
      expect(find.textContaining('Nothing planned in this period'), findsOneWidget);
    });
  });

  group('Plan › Calendars', () {
    Widget panel(WalletController wc, FileChooser chooser) =>
        Scaffold(body: SingleChildScrollView(child: CalendarsPanel(wc: wc, chooser: chooser)));

    tw('refused permission: says how to allow it, lists nothing', (tester) async {
      final wc = fw(calendars: FakeCalendars(allow: false));
      await pumpApp(tester, panel(wc, _Chooser()), size: const Size(400, 1600));
      await tester.tap(key('calAllow'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Calendar access was refused'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
    });

    tw('granted permission: switches per calendar; switching one on reads it', (tester) async {
      final cals = FakeCalendars(eventList: _events);
      final wc = fw(calendars: cals);
      await pumpApp(tester, panel(wc, _Chooser()), size: const Size(400, 1600));
      await tester.tap(key('calAllow'));
      await tester.pumpAndSettle();
      expect(find.text('Family'), findsOneWidget);
      expect(find.text('me@example.com'), findsOneWidget);
      await tester.tap(key('cal:c1'));
      await tester.pumpAndSettle();
      expect(wc.cal.events, hasLength(2));
      expect(find.textContaining('Read 2 events'), findsOneWidget);
    });

    tw('without a phone calendar source only files and links are offered', (tester) async {
      final wc = fw();
      await pumpApp(tester, panel(wc, _Chooser()), size: const Size(400, 1600));
      expect(key('calAllow'), findsNothing);
      expect(key('calImport'), findsOneWidget);
    });

    tw('importing a good file adds it; a broken one shows a message', (tester) async {
      final wc = fw();
      final chooser = _Chooser();
      await pumpApp(tester, panel(wc, chooser), size: const Size(400, 1600));
      chooser.picks = [_Picked('broken.ics', bytesOf('hello'))];
      await tester.tap(key('calImport'));
      await tester.pumpAndSettle();
      expect(find.textContaining("doesn't look like a calendar"), findsOneWidget);
      chooser.picks = [
        _Picked('home.ics', bytesOf(fakeIcs([('u1', '2026-10-25', 'Car service 120 €')])))
      ];
      await tester.tap(key('calImport'));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(find.textContaining("doesn't look like a calendar"), findsNothing);
      await tester.tap(find.byTooltip('Remove calendar'));
      await tester.pumpAndSettle();
      expect(find.text('home'), findsNothing);
    });

    tw('a link that cannot be fetched shows the reason', (tester) async {
      final wc = fw();
      wc.seams.icsFetcher = (u) async => throw const IcsFetchException("Couldn't reach the link. Check the network.");
      await pumpApp(tester, panel(wc, _Chooser()), size: const Size(400, 1600));
      await tester.tap(key('calLink'));
      await tester.pump();
      await tester.enterText(key('calLinkField'), 'https://example.org/me.ics');
      await tester.tap(key('calLinkAdd'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't reach the link"), findsOneWidget);
    });

    tw('the heads-up amount and days are saved, bad values are refused', (tester) async {
      final wc = fw();
      await pumpApp(tester, panel(wc, _Chooser()), size: const Size(400, 1600));
      await tester.enterText(key('headsUpDays'), '30');
      await tester.tap(key('headsUpSave'));
      await tester.pump();
      expect(find.textContaining('Days must be from 0 to 14.'), findsOneWidget);
      expect(wc.headsUpDays, 3);
      await tester.enterText(key('headsUpDays'), '5');
      await tester.enterText(key('headsUpCents'), '250,50');
      await tester.tap(key('headsUpSave'));
      await tester.pump();
      expect(wc.headsUpDays, 5);
      expect(wc.headsUpCents, 25050);
    });

    tw('Plan lists Calendars and the heads-up switch next to Nudges', (tester) async {
      final wc = fw(nudges: FakeNudges());
      await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: const Size(400, 8500));
      expect(key('calImport'), findsOneWidget);
      expect(key('headsUpSwitch'), findsOneWidget);
      await tester.ensureVisible(key('headsUpSwitch'));
      await tester.pump();
      await tester.tap(key('headsUpSwitch'));
      await tester.pumpAndSettle();
      expect(wc.headsUpNotify, isTrue);
    });
  });

  group('Plan › Export', () {
    tw('Planned costs (.ics) saves the file', (tester) async {
      final wc = fw();
      final chooser = _Chooser();
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: ExportPanel(wc: wc, chooser: chooser))),
          size: const Size(400, 1200));
      await tester.tap(key('exportPlanned'));
      await tester.pumpAndSettle();
      expect(chooser.saved.single.name, 'budget-wallet-planned.ics');
      expect(utf8.decode(chooser.saved.single.bytes), contains('Car insurance'));
    });

    tw('with nothing planned it says so and saves nothing', (tester) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      final chooser = _Chooser();
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: ExportPanel(wc: wc, chooser: chooser))),
          size: const Size(400, 1200));
      await tester.tap(key('exportPlanned'));
      await tester.pump();
      expect(find.text('No planned costs with an amount to export'), findsOneWidget);
      expect(chooser.saved, isEmpty);
    });
  });

  group('logs', () {
    test('count what happened and never a title, an amount, a calendar name, a link or a file name', () async {
      final nudges = FakeNudges();
      final cals = FakeCalendars(granted: true, eventList: _events, calendarList: const [DeviceCalendarInfo('c1', 'SecretFamilyCal')]);
      final wc = fw(nudges: nudges, calendars: cals);
      wc.addPlannedCost(title: 'SecretTitle', date: '2026-10-25', amount: 12345);
      await wc.requestCalendarAccess();
      await wc.setCalendarOn('c1', true);
      wc.seams.icsFetcher = (u) async => fakeIcs([('u9', '2026-10-25', 'LinkEvent 77 €')]);
      await wc.addIcsLink('https://secret.example.org/private-token.ics');
      await wc.importIcsFile('private-file-name.ics', bytesOf(fakeIcs([('u1', '2026-10-26', 'FileEvent')])));
      await wc.importIcsFile('bad-name.ics', bytesOf('nope'));
      final r = wc.upcomingRange();
      final s = wc.upcomingItems(r.start, r.end).firstWhere((i) => i.kind == UpcomingKind.suggestion);
      wc.confirmSuggestion(s, amount: 4321);
      wc.dismissSuggestion(wc.upcomingItems(r.start, r.end).firstWhere((i) => i.kind == UpcomingKind.suggestion));
      wc.skipPlanned(wc.plannedOpen().first);
      await wc.setHeadsUpNotify(true);
      wc.saveHeadsUp(cents: 12300, days: 4);
      wc.exportPlannedIcs();
      final all = lines.join('\n');
      expect(all, contains('planned.add'));
      expect(all, contains('calendar.read'));
      expect(all, contains('headsup.scheduled'));
      for (final secret in const [
        'SecretTitle',
        'SecretFamilyCal',
        'Birthday',
        'Haircut',
        'LinkEvent',
        'FileEvent',
        'secret.example',
        'private-token',
        'private-file-name',
        'bad-name',
        '12345',
        '4321',
        '12300',
        '123.00',
      ]) {
        expect(all, isNot(contains(secret)), reason: 'logs must not contain $secret');
      }
      final read = lines.where((l) => l.contains('calendar.read')).last;
      expect(read, allOf(contains('calendars'), contains('events'), contains('unsupported')));
    });
  });

  group('F4b review fixes', () {
    Map<Object?, Object?> phoneEvent(String id, String title, int? status) =>
        {'id': id, 'calendarId': 'c1', 'title': title, 'date': '2026-10-24', 'allDay': false, 'status': status};

    /// Runs [body] with a real HttpClient (flutter_test replaces it with one that always answers 400).
    Future<T> realHttp<T>(Future<T> Function() body) => HttpOverrides.runWithHttpOverrides(body, _RealHttp());

    Future<HttpServer> serve(Future<void> Function(HttpRequest r) handler) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) => handler(r).catchError((_) {}));
      return server;
    }

    Future<WalletController> rentWallet() async {
      final cals =
          FakeCalendars(granted: true, eventList: const [CalendarEvent(calendarId: 'c1', uid: 'r1', title: 'Rent', date: '2026-10-26')]);
      final wc = fw(calendars: cals);
      wc.addPlannedCost(title: 'Rent', date: '2026-10-02', amount: 50000, category: 'Rent');
      await wc.requestCalendarAccess();
      await wc.setCalendarOn('c1', true);
      return wc;
    }

    test('a suggestion with an earlier cost of the same name keeps its category: covered by the plan, not reserved twice', () async {
      final wc = await rentWallet();
      final r = wc.upcomingRange();
      final s = wc.upcomingItems(r.start, r.end).singleWhere((i) => i.kind == UpcomingKind.suggestion);
      expect((s.suggested, s.suggestedFrom, s.category), (50000, 'earlier', 'Rent'));
      final reservedBefore = wc.period().reservedPlanned;
      wc.confirmSuggestion(s, amount: s.suggested!, category: s.category);
      final stored = wc.plannedOpen().singleWhere((p) => p.source == PlannedSource.calendar);
      expect(stored.category, 'Rent');
      expect(stored.coveredByPlan, isTrue);
      expect(wc.period().reservedPlanned, reservedBefore, reason: 'rent is in the fixed plan already');
    });

    tw('tapping Confirm on that suggestion passes the category on', (tester) async {
      final wc = await rentWallet();
      final reservedBefore = wc.period().reservedPlanned;
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      final confirm = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('confirm:e:'));
      await tester.tap(confirm);
      await tester.pump();
      final stored = wc.plannedOpen().singleWhere((p) => p.source == PlannedSource.calendar);
      expect(stored.category, 'Rent');
      expect(wc.period().reservedPlanned, reservedBefore);
    });

    test('updatePlanned: clearCategory removes the category, null alone leaves it', () {
      final wc = fw();
      final id = wc.plannedOpen().firstWhere((p) => p.title == 'Dentist').id;
      wc.updatePlanned(id, title: 'Dentist');
      expect(wc.plannedOpen().firstWhere((p) => p.id == id).category, 'Health & care');
      wc.updatePlanned(id, clearCategory: true);
      expect(wc.plannedOpen().firstWhere((p) => p.id == id).category, isNull);
    });

    tw('the change sheet: choosing "No category" really removes the category', (tester) async {
      final wc = fw();
      final id = wc.plannedOpen().firstWhere((p) => p.title == 'Dentist').id;
      await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
      await tester.ensureVisible(key('up:p:$id'));
      await tester.tap(find.descendant(of: key('up:p:$id'), matching: find.text('Dentist')));
      await tester.pumpAndSettle();
      await tester.tap(key('entryEdit'));
      await tester.pumpAndSettle();
      await tester.tap(key('plannedCategory'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No category').last);
      await tester.pumpAndSettle();
      await tester.tap(key('plannedSave'));
      await tester.pumpAndSettle();
      expect(wc.plannedOpen().firstWhere((p) => p.id == id).category, isNull);
    });

    group('Set aside', () {
      WalletController withBills() {
        final wc = fw();
        wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
          for (final d in const ['2026-07-27', '2026-08-27', '2026-09-27']) syntheticTx(d, -1299, 'POS plaćanje', 'POS NETFLIX.COM'),
          for (final d in const ['2026-07-25', '2026-08-25', '2026-09-25']) syntheticTx(d, -2999, 'POS plaćanje', 'POS SYNTHGYM ZAGREB'),
        ]));
        wc.reload();
        wc.refreshRecurring();
        for (final b in wc.recurringBills()) {
          wc.confirmRecurring(b.id);
        }
        return wc;
      }

      test('equals what the period reserves: a bill in a fixed category is not counted, a flexible one is', () {
        final wc = withBills();
        final bills = wc.recurringBills();
        expect(bills.where((b) => b.coveredByPlan), hasLength(1));
        expect(bills.where((b) => !b.coveredByPlan), hasLength(1));
        final r = wc.upcomingRange();
        final items = wc.upcomingItems(wc.today(), r.end);
        expect(items.where((i) => i.kind == UpcomingKind.bill), hasLength(2));
        final p = wc.period();
        expect(p.reservedBills, 2999);
        expect(wc.setAside(items).total, 2999 + 42000);
        expect(wc.setAside(items).count, 3);
      });
    });

    group('link fetch', () {
      test('one overall timeout: a server that sends a byte now and then cannot hold it open', () async {
        final server = await serve((r) async {
          r.response.statusCode = 200;
          for (var i = 0; i < 200; i++) {
            r.response.write('x');
            await r.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          await r.response.close();
        });
        final watch = Stopwatch()..start();
        await realHttp(() async {
          await expectLater(fetchIcs(Uri.parse('http://127.0.0.1:${server.port}/slow.ics'), timeout: const Duration(milliseconds: 500)),
              throwsA(isA<IcsFetchException>().having((e) => e.message, 'message', contains('too long'))));
        });
        expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      });

      test('redirects are followed (a few), and a loop is refused', () async {
        final server = await serve((r) async {
          switch (r.uri.path) {
            case '/a':
              r.response
                ..statusCode = 302
                ..headers.set('location', '/b');
            case '/b':
              r.response
                ..statusCode = 200
                ..write(fakeIcs([('u1', '2026-10-25', 'Hop')]));
            default:
              r.response
                ..statusCode = 301
                ..headers.set('location', '/loop');
          }
          await r.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';
        await realHttp(() async {
          expect(await fetchIcs(Uri.parse('$base/a')), contains('SUMMARY:Hop'));
          await expectLater(fetchIcs(Uri.parse('$base/loop')),
              throwsA(isA<IcsFetchException>().having((e) => e.message, 'message', contains('too many times'))));
        });
      });

      test('a redirect from https to http is refused, other steps are fine', () {
        final https = Uri.parse('https://example.org/a.ics');
        expect(() => resolveRedirect(https, 'http://example.org/b.ics'), throwsA(isA<IcsFetchException>()));
        expect(() => resolveRedirect(https, 'ftp://example.org/b.ics'), throwsA(isA<IcsFetchException>()));
        expect(resolveRedirect(https, '/b.ics').toString(), 'https://example.org/b.ics');
        expect(resolveRedirect(Uri.parse('http://example.org/a.ics'), 'https://example.org/b.ics').scheme, 'https');
        expect(resolveRedirect(Uri.parse('http://example.org/a.ics'), 'http://other.org/b.ics').host, 'other.org');
      });

      test('a link that fails in a way nobody expected still leaves reading switched off', () async {
        final wc = fw();
        wc.seams.icsFetcher = (u) async => fakeIcs([('u2', '2026-10-26', 'Link event')]);
        await wc.addIcsLink('https://example.org/a.ics');
        wc.seams.icsFetcher = (u) async => throw StateError('boom');
        await wc.readCalendars();
        expect(wc.cal.reading, isFalse);
        expect(wc.calendarEntries().single.error, contains('Showing what was saved'));
        await wc.readCalendars();
        expect(wc.cal.events.map((e) => e.title), ['Link event'], reason: 'the later read still runs');
      });
    });

    tw('Plan › Calendars warns under an http:// link, not under https://, at 320 dp x2.0', (tester) async {
      await withErrors((errors) async {
        final wc = fw();
        await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: CalendarsPanel(wc: wc))),
            size: const Size(320, 900), textScale: 2.0);
        await tester.ensureVisible(key('calLink'));
        await tester.tap(key('calLink'));
        await tester.pump();
        expect(key('calLinkInsecure'), findsNothing);
        await tester.enterText(key('calLinkField'), 'https://example.org/a.ics');
        await tester.pump();
        expect(key('calLinkInsecure'), findsNothing);
        await tester.enterText(key('calLinkField'), ' HTTP://example.org/a.ics');
        await tester.pump();
        expect(key('calLinkInsecure'), findsOneWidget);
        expect(find.textContaining("This link isn't encrypted", findRichText: true), findsOneWidget);
        expect(find.byIcon(Icons.error_outline), findsWidgets, reason: 'icon plus text');
        errors.check();
      });
    });

    tw('a saved http:// link keeps its warning in the list', (tester) async {
      await withErrors((errors) async {
        final wc = fw();
        wc.seams.icsFetcher = (u) async => fakeIcs([('u2', '2026-10-26', 'Link event')]);
        expect(await wc.addIcsLink('http://example.org/a.ics'), isNull, reason: 'accepted, with a warning');
        expect(wc.calendarEntries().single.insecure, isTrue);
        await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: CalendarsPanel(wc: wc))),
            size: const Size(320, 900), textScale: 2.0);
        expect(find.textContaining("This link isn't encrypted", findRichText: true), findsOneWidget);
        errors.check();
      });
    });

    test('a cost added for tomorrow with a 3 day heads-up still gets a notification (the next 09:00)', () async {
      final nudges = FakeNudges();
      final wc = fw(nudges: nudges);
      wc.addPlannedCost(title: 'New tyres', date: '2026-10-21', amount: 30000);
      await wc.setHeadsUpNotify(true);
      final slots = nudges.headsUps.last;
      expect(slots.firstWhere((s) => s.date == '2026-10-21').body, headsUpBody(0));
    });

    test('two heads-up reschedules at once run one after the other (no stale notifications)', () async {
      final nudges = FakeNudges()..headsUpDelay = const Duration(milliseconds: 30);
      final wc = fw(nudges: nudges);
      wc.repo.setLocalValue('headsUpNotify', '1');
      await Future.wait([wc.rescheduleHeadsUps(), wc.rescheduleHeadsUps(), wc.rescheduleHeadsUps()]);
      expect(nudges.headsUps, hasLength(3));
      expect(nudges.headsUpMostRunning, 1, reason: 'never two calls inside the platform at the same time');
      wc.addPlannedCost(title: 'Tyres', date: '2026-11-05', amount: 30000);
      await Future.wait([wc.rescheduleHeadsUps(), wc.rescheduleHeadsUps()]);
      expect(nudges.headsUps.last.map((s) => s.date), contains('2026-11-02'));
      expect(nudges.headsUpMostRunning, 1);
    });

    test('cancelled phone events are not suggested; others are', () {
      final list = calendarEventsFrom([
        phoneEvent('e1', 'Dinner', 1),
        phoneEvent('e2', 'Called off', 2),
        phoneEvent('e3', 'Maybe', 0),
        phoneEvent('e4', 'No status', null),
      ]);
      expect(list.map((e) => e.title), ['Dinner', 'Maybe', 'No status']);
      expect(list.first.date, '2026-10-24');
    });

    group('Undo after Paid and Skip', () {
      Finder snack(String text) => find.descendant(of: find.byType(SnackBar), matching: find.text(text));

      tw('Skip: "Skipped" with Undo; Undo puts the cost back in the plan', (tester) async {
        final wc = fw();
        final id = wc.plannedOpen().firstWhere((p) => p.title == 'Car insurance').id;
        await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
        await tester.ensureVisible(key('up:p:$id'));
        await tester.tap(find.descendant(of: key('up:p:$id'), matching: find.text('Car insurance')));
        await tester.pumpAndSettle();
        await tester.tap(key('entrySkip'));
        await tester.pumpAndSettle();
        expect(snack('Skipped'), findsOneWidget);
        expect(wc.comingUp().count, 1);
        await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
        await tester.pumpAndSettle();
        expect(wc.comingUp().count, 2);
        expect(wc.plannedOpen().map((p) => p.title), contains('Car insurance'));
      });

      tw('Paid: "Marked paid" with Undo; Undo opens the cost again and forgets the payment', (tester) async {
        final wc = fw();
        final p = wc.plannedOpen().firstWhere((p) => p.title == 'Car insurance');
        final tx = wc.paidCandidatesFor(p).single.tx;
        await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
        await tester.ensureVisible(key('up:p:${p.id}'));
        await tester.tap(find.descendant(of: key('up:p:${p.id}'), matching: find.text('Car insurance')));
        await tester.pumpAndSettle();
        await tester.tap(key('entryPaid'));
        await tester.pumpAndSettle();
        await tester.tap(key('pay:${tx.id}'));
        await tester.pumpAndSettle();
        expect(snack('Marked paid'), findsOneWidget);
        expect(wc.plannedOpen().map((x) => x.title), isNot(contains('Car insurance')));
        await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
        await tester.pumpAndSettle();
        final back = wc.plannedOpen().firstWhere((x) => x.title == 'Car insurance');
        expect(back.paidTx, isNull);
        expect(back.status, PlannedStatus.open);
        expect(wc.paidCandidatesFor(back), hasLength(1), reason: 'the payment can be picked again');
      });

      tw('Delete has no Undo', (tester) async {
        final wc = fw();
        final id = wc.plannedOpen().firstWhere((p) => p.title == 'Dentist').id;
        await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: const Size(400, 1600));
        await tester.ensureVisible(key('up:p:$id'));
        await tester.tap(find.descendant(of: key('up:p:$id'), matching: find.text('Dentist')));
        await tester.pumpAndSettle();
        await tester.tap(key('entryDelete'));
        await tester.pumpAndSettle();
        expect(snack('Deleted'), findsOneWidget);
        expect(find.widgetWithText(SnackBarAction, 'Undo'), findsNothing);
      });

      test('reopenPlanned is logged without any text', () {
        final wc = fw();
        final p = wc.plannedOpen().first;
        wc.skipPlanned(p);
        wc.reopenPlanned(p);
        expect(lines.where((l) => l.contains('bw.planned') && l.contains('planned.reopen')), hasLength(1));
        expect(lines.join('\n'), isNot(contains(p.title)));
      });
    });
  });

  group('layout', () {
    final sizes = [
      ('320 dp at text 2.0', const Size(320, 640), 2.0),
      ('360 dp', const Size(360, 800), 1.0),
      ('1280 wide', const Size(1280, 900), 1.0),
    ];
    for (final (name, size, scale) in sizes) {
      tw('$name: Today with the Coming up and heads-up lines', (tester) async {
        await withErrors((errors) async {
          final wc = fw();
          await pumpApp(tester, todayOf(wc), size: size, textScale: scale);
          await scrollThrough(tester);
          errors.check();
        });
      });

      tw('$name: Upcoming with planned costs, suggestions and a long title', (tester) async {
        await withErrors((errors) async {
          final wc = await withCalendar();
          wc.addPlannedCost(
              title: 'A very long synthetic planned cost name that has to wrap on a narrow screen', date: '2026-10-29', amount: 123456);
          await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: size, textScale: scale);
          await scrollThrough(tester);
          errors.check();
        });
      });

      tw('$name: the planned cost sheet and the entry sheet', (tester) async {
        final wc = fw();
        await pumpApp(tester, UpcomingScreen(view: UpcomingView(wc)), size: size, textScale: scale);
        await tester.tap(key('addPlannedTop'));
        await tester.pumpAndSettle();
        expect(key('plannedSave'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'the planned cost sheet');
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();
        await tester.dragUntilVisible(key('up:p:${wc.plannedOpen().first.id}'), find.byType(ListView), const Offset(0, -200));
        await tester.ensureVisible(key('up:p:${wc.plannedOpen().first.id}'));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(of: key('up:p:${wc.plannedOpen().first.id}'), matching: find.text('Car insurance')));
        await tester.pumpAndSettle();
        await tester.tap(key('entryPaid'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'the entry sheet');
      });

      tw('$name: Plan › Calendars with calendars, files, a link error and the heads-up fields', (tester) async {
        await withErrors((errors) async {
          final cals = FakeCalendars(eventList: _events);
          final wc = fw(calendars: cals, nudges: FakeNudges());
          await wc.requestCalendarAccess();
          await wc.importIcsFile('a-rather-long-synthetic-calendar-file-name.ics', bytesOf(fakeIcs([('u1', '2026-10-25', 'Car service')])));
          wc.seams.icsFetcher = (u) async => fakeIcs([('u2', '2026-10-26', 'Link event')]);
          await wc.addIcsLink('https://example.org/a/very/long/path/to/a/calendar.ics');
          wc.seams.icsFetcher = (u) async => throw const IcsFetchException('The link took too long to answer.');
          await wc.readCalendars();
          await pumpApp(tester, Scaffold(body: PlanPage(wc: wc)), size: size, textScale: scale);
          await scrollThrough(tester);
          errors.check();
        });
      });
    }
  });
}
