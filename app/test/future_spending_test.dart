// Stage F3: future spending in the app. Planned costs, the Upcoming screen (grid + list), Today's "Coming up" and heads-up
// lines, Plan › Calendars (phone calendars through a fake source, .ics files and links), heads-up notifications, Plan › Export
// and the log privacy of all of it. All data is SYNTHETIC (futureWallet: Tuesday 20 Oct 2026).
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/calendar_source.dart';
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/future_shim.dart';
import 'package:budget_wallet/src/ics_fetch.dart';
import 'package:budget_wallet/src/nudges.dart';
import 'package:budget_wallet/src/screens/calendars_panel.dart';
import 'package:budget_wallet/src/screens/export_panel.dart';
import 'package:budget_wallet/src/screens/plan.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/upcoming.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/layout.dart';
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

base class _Picked extends PlatformFile {
  @override
  final String name;
  final Uint8List data;
  _Picked(this.name, this.data);
  @override
  Uri get uri => Uri(path: name);
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => data.length;
  @override
  Future<int?> length() async => data.length;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(data);
}

class _Chooser extends FileChooser {
  List<PlatformFile> picks = [];
  final saved = <({String name, Uint8List bytes})>[];
  @override
  Future<List<PlatformFile>> pickCalendarFile() async => picks;
  @override
  Future<Uri?> saveText({required String fileName, required Uint8List bytes, required String title}) async {
    saved.add((name: fileName, bytes: bytes));
    return Uri(path: fileName);
  }
}

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
    Scaffold(body: TodayScreen(wc: wc, openPlan: () {}, clock: () => budgetToday, chooser: const FileChooser()));

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
      wc.icsFetcher = (u) async {
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

    test('bad links are refused before any request', () async {
      final wc = fw();
      var asked = 0;
      wc.icsFetcher = (u) async {
        asked++;
        return '';
      };
      expect(await wc.addIcsLink('ftp://example.org/x.ics'), contains('http'));
      expect(await wc.addIcsLink('not a link'), isNotNull);
      expect(asked, 0);
      wc.icsFetcher = (u) async => throw const IcsFetchException("Couldn't reach the link. Check the network.");
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

  group('heads-up notifications', () {
    test('turned on: scheduled at 09:00 on (date - days) with a text that has no title and no amount', () async {
      final nudges = FakeNudges();
      final wc = fw(nudges: nudges);
      wc.addPlannedCost(title: 'Annual membership', date: '2026-10-30', amount: 20000);
      expect(await wc.setHeadsUpNotify(true), isTrue);
      expect(nudges.asked, 1);
      final slots = nudges.headsUps.last;
      expect(slots.map((s) => (s.date, s.hour)), [('2026-10-27', 9)], reason: 'the insurance slot (20 Oct 09:00) has passed');
      expect(slots.single.body, 'A big planned cost is coming up in 3 days.');
      expect('${slots.single.title}${slots.single.body}', isNot(anyOf(contains('Annual'), contains('200'), contains('€'))));
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
      expect(headsUpSlots(DateTime(2026, 10, 20, 9), [('2026-10-23', 3)]), isEmpty);
      expect(headsUpSlots(now, [('2026-10-21', 3)]), isEmpty);
      expect(headsUpSlots(now, [for (var i = 0; i < 30; i++) (addDays('2026-11-01', i), 3)]), hasLength(headsUpMax));
      expect(headsUpBody(0), isNot(contains('0 days')));
    });
  });

  group('Today', () {
    tw('shows the Coming up line and a heads-up line for the big cost', (tester) async {
      final wc = fw();
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1400));
      expect(find.descendant(of: key('comingUpLine'), matching: find.text('Coming up: 2 costs before payday · 420 €')), findsOneWidget);
      final head = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('headsUp:'));
      expect(head, findsOneWidget);
      expect(find.text('Car insurance in 3 days · 340 €'), findsOneWidget);
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
      expect(find.text('Coming up: 2 costs before payday · 420 €'), findsOneWidget);
    });

    tw('tapping Coming up opens Upcoming', (tester) async {
      final wc = fw();
      await pumpApp(tester, todayOf(wc), size: const Size(400, 1400));
      await tester.tap(key('comingUpLine'));
      await tester.pumpAndSettle();
      expect(find.text('Upcoming'), findsOneWidget);
      expect(key('day:2026-10-23'), findsOneWidget);
    });
  });

  group('Upcoming', () {
    tw('the grid marks days and the list is ruled with date, title, amount and source', (tester) async {
      final wc = await withCalendar();
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
      expect(find.text('October 2026'), findsOneWidget);
      for (final d in const ['2026-10-23', '2026-10-27', '2026-10-24']) {
        expect(key('day:$d'), findsOneWidget);
      }
      final insurance = find.descendant(of: key('up:p:${wc.plannedOpen().first.id}'), matching: find.text('Car insurance'));
      expect(insurance, findsOneWidget);
      expect(find.text('340 €'), findsOneWidget);
      expect(find.text('Suggested 80 €'), findsOneWidget);
      expect(find.text('No amount found'), findsOneWidget);
      expect(find.text('Added'), findsWidgets);
      expect(find.text('Calendar'), findsWidgets);
      expect(find.text('Set aside'), findsOneWidget);
    });

    tw('tapping a day lists just that day; Show all brings the rest back', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
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
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
      final confirm = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('confirm:e:'));
      expect(confirm, findsOneWidget, reason: 'only the suggestion with an amount can be confirmed as is');
      await tester.tap(confirm);
      await tester.pump();
      expect(find.text('Suggested 80 €'), findsNothing);
      expect(wc.comingUp().count, 3);
      expect(wc.comingUp().total, 50000);
    });

    tw('No cost dismisses the suggestion', (tester) async {
      final wc = await withCalendar();
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
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
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
      final hair = find.descendant(
          of: find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('up:e:')).last,
          matching: find.text('Add amount'));
      await tester.tap(hair);
      await tester.pumpAndSettle();
      await tester.tap(key('plannedSave'));
      await tester.pump();
      expect(find.text('Enter an amount, like 80.00.'), findsOneWidget);
      await tester.enterText(key('plannedAmount'), '25');
      await tester.tap(key('plannedSave'));
      await tester.pumpAndSettle();
      expect(wc.plannedOpen().where((p) => p.title == 'Haircut' && p.amount == 2500), hasLength(1));
    });

    tw('+ Planned cost: needs a name and an amount, then the cost is in the list', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
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
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
      await tester.tap(key('up:p:${wc.plannedOpen().first.id}'));
      await tester.pumpAndSettle();
      await tester.tap(key('entryPaid'));
      await tester.pump();
      expect(find.text('Which payment was it?'), findsOneWidget);
      final pay = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('pay:'));
      expect(pay, findsOneWidget);
      await tester.tap(pay);
      await tester.pumpAndSettle();
      expect(find.text('Car insurance'), findsNothing);
      expect(wc.plannedOpen().map((p) => p.title), ['Dentist']);
    });

    tw('Paid with no matching payment says so', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
      await tester.tap(key('up:p:${wc.plannedOpen().last.id}'));
      await tester.pumpAndSettle();
      await tester.tap(key('entryPaid'));
      await tester.pump();
      expect(find.textContaining('No matching payment yet'), findsOneWidget);
    });

    tw('Skip and Delete from the entry sheet', (tester) async {
      final wc = fw();
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
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
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
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
      await pumpApp(tester, UpcomingScreen(wc: wc), size: const Size(400, 1600));
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
      chooser.picks = [_Picked('home.ics', bytesOf(fakeIcs([('u1', '2026-10-25', 'Car service 120 €')])))];
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
      wc.icsFetcher = (u) async => throw const IcsFetchException("Couldn't reach the link. Check the network.");
      await pumpApp(tester, panel(wc, _Chooser()), size: const Size(400, 1600));
      await tester.tap(key('calLink'));
      await tester.pump();
      await tester.enterText(key('calLinkField'), 'https://example.org/me.ics');
      await tester.tap(key('calLinkAdd'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't reach the link. Check the network."), findsOneWidget);
    });

    tw('the heads-up amount and days are saved, bad values are refused', (tester) async {
      final wc = fw();
      await pumpApp(tester, panel(wc, _Chooser()), size: const Size(400, 1600));
      await tester.enterText(key('headsUpDays'), '30');
      await tester.tap(key('headsUpSave'));
      await tester.pump();
      expect(find.text('Days must be from 0 to 14.'), findsOneWidget);
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
      await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: const Size(400, 6000));
      expect(find.text('CALENDARS'), findsOneWidget);
      expect(key('headsUpSwitch'), findsOneWidget);
      await tester.tap(key('headsUpSwitch'));
      await tester.pumpAndSettle();
      expect(wc.headsUpNotify, isTrue);
    });
  });

  group('Plan › Export', () {
    tw('Planned costs (.ics) saves the file', (tester) async {
      final wc = fw();
      final chooser = _Chooser();
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: ExportPanel(wc: wc, chooser: chooser))), size: const Size(400, 1200));
      await tester.tap(key('exportPlanned'));
      await tester.pumpAndSettle();
      expect(chooser.saved.single.name, 'budget-wallet-planned.ics');
      expect(utf8.decode(chooser.saved.single.bytes), contains('Car insurance'));
    });

    tw('with nothing planned it says so and saves nothing', (tester) async {
      final wc = emptyWallet();
      addTearDown(wc.dispose);
      final chooser = _Chooser();
      await pumpApp(tester, Scaffold(body: SingleChildScrollView(child: ExportPanel(wc: wc, chooser: chooser))), size: const Size(400, 1200));
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
      wc.icsFetcher = (u) async => fakeIcs([('u9', '2026-10-25', 'LinkEvent 77 €')]);
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

  group('layout', () {
    final sizes = [
      ('320 dp at text 2.0', const Size(320, 640), 2.0),
      ('360 dp', const Size(360, 800), 1.0),
      ('1280 wide', const Size(1280, 900), 1.0),
    ];
    for (final (name, size, scale) in sizes) {
      tw('$name: Today with the Coming up and heads-up lines', (tester) async {
        final errors = Errors();
        final wc = fw();
        await pumpApp(tester, todayOf(wc), size: size, textScale: scale);
        await scrollThrough(tester);
        errors.check();
      });

      tw('$name: Upcoming with planned costs, suggestions and a long title', (tester) async {
        final errors = Errors();
        final wc = await withCalendar();
        wc.addPlannedCost(title: 'A very long synthetic planned cost name that has to wrap on a narrow screen', date: '2026-10-29', amount: 123456);
        await pumpApp(tester, UpcomingScreen(wc: wc), size: size, textScale: scale);
        await scrollThrough(tester);
        errors.check();
      });

      tw('$name: the planned cost sheet and the entry sheet', (tester) async {
        final errors = Errors();
        final wc = fw();
        await pumpApp(tester, UpcomingScreen(wc: wc), size: size, textScale: scale);
        await tester.tap(key('addPlanned'));
        await tester.pumpAndSettle();
        expect(key('plannedSave'), findsOneWidget);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        await tester.tap(key('up:p:${wc.plannedOpen().first.id}'));
        await tester.pumpAndSettle();
        await tester.tap(key('entryPaid'));
        await tester.pumpAndSettle();
        errors.check();
      });

      tw('$name: Plan › Calendars with calendars, files, a link error and the heads-up fields', (tester) async {
        final errors = Errors();
        final cals = FakeCalendars(eventList: _events);
        final wc = fw(calendars: cals, nudges: FakeNudges());
        await wc.requestCalendarAccess();
        await wc.importIcsFile('a-rather-long-synthetic-calendar-file-name.ics', bytesOf(fakeIcs([('u1', '2026-10-25', 'Car service')])));
        wc.icsFetcher = (u) async => fakeIcs([('u2', '2026-10-26', 'Link event')]);
        await wc.addIcsLink('https://example.org/a/very/long/path/to/a/calendar.ics');
        wc.icsFetcher = (u) async => throw const IcsFetchException('The link took too long to answer.');
        await wc.readCalendars();
        await pumpApp(tester, Scaffold(body: PlanScreen(wc: wc)), size: size, textScale: scale);
        await scrollThrough(tester);
        errors.check();
      });
    }
  });
}
