// P13 §3: the phone's calendars through the app's own channel `budget_wallet/calendar` (read only; MainActivity.kt answers it).
import 'package:budget_wallet/src/calendar_source_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _ch = MethodChannel('budget_wallet/calendar');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  late Object? Function(MethodCall) answer;

  setUp(() {
    calls = [];
    answer = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_ch, (call) async {
      calls.add(call);
      return answer(call);
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_ch, null));
  });

  test('permission calls ask the channel and say true only for true', () async {
    final cal = AndroidCalendars();
    answer = (_) => true;
    expect(await cal.hasPermission(), isTrue);
    expect(await cal.requestPermission(), isTrue);
    answer = (_) => false;
    expect(await cal.hasPermission(), isFalse);
    expect(await cal.requestPermission(), isFalse);
    answer = (_) => null;
    expect(await cal.hasPermission(), isFalse);
    expect(calls.map((c) => c.method), ['hasPermission', 'requestPermission', 'hasPermission', 'requestPermission', 'hasPermission']);
  });

  test('calendars are mapped; entries without id or name are skipped', () async {
    answer = (_) => [
          {'id': '3', 'name': 'Family', 'account': 'me@example.com', 'color': 1},
          {'id': 4, 'name': 'Work'},
          {'name': 'No id'},
          {'id': '9'},
        ];
    final list = await AndroidCalendars().calendars();
    expect(list.map((c) => (c.id, c.name, c.account)), [('3', 'Family', 'me@example.com'), ('4', 'Work', null)]);
  });

  test('events: ids and range go to the channel; cancelled and bad entries are dropped', () async {
    answer = (_) => [
          {
            'id': 'e1',
            'calendarId': '3',
            'title': 'Dinner',
            'date': '2026-10-24',
            'allDay': false,
            'status': 1,
            'notes': 'n',
            'uid2445': 'uid-dinner@example.com',
            'startMinutes': 1170,
          },
          {'id': 'e2', 'calendarId': '3', 'title': 'Called off', 'date': '2026-10-24', 'status': 2},
          {'id': 'e3', 'calendarId': '3', 'title': 'Holiday', 'date': '2026-10-25', 'allDay': true},
          {'id': 'e4', 'calendarId': '3', 'title': 'Bad date', 'date': '25.10.2026'},
          {'calendarId': '3', 'title': 'No id', 'date': '2026-10-25'},
        ];
    final list = await AndroidCalendars().events({'3'}, '2026-10-20', '2026-11-20');
    // KL-A: the uid is the calendar's iCal UID (never the provider's row id, here e1/e3); '' when the calendar has none.
    expect(list.map((e) => (e.uid, e.title, e.date, e.allDay, e.startMinutes)),
        [('uid-dinner@example.com', 'Dinner', '2026-10-24', false, 1170), ('', 'Holiday', '2026-10-25', true, null)]);
    expect(list.first.notes, 'n');
    // RF5: the row id is kept only as the pre-KL uid, so old decisions on letterless titles still match (`legacyRef`).
    expect(list.map((e) => e.legacyUid), ['e1', 'e3']);
    expect(calls.single.method, 'events');
    expect(calls.single.arguments, {
      'ids': ['3'],
      'from': '2026-10-20',
      'to': '2026-11-20'
    });
  });

  test('events with no calendar ids never call the channel', () async {
    expect(await AndroidCalendars().events({}, '2026-10-20', '2026-11-20'), isEmpty);
    expect(calls, isEmpty);
  });

  test('a channel error reaches the caller (the controller logs and shows it)', () async {
    answer = (_) => throw PlatformException(code: 'failed', message: 'SecurityException');
    await expectLater(AndroidCalendars().events({'3'}, '2026-10-20', '2026-10-21'), throwsA(isA<PlatformException>()));
  });
}
