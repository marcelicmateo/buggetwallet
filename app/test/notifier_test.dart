// The Android reminders through the plugin's method channel (mocked): permission, scheduling without exact alarms, and the
// text that leaves the app. SYNTHETIC; no device.
import 'package:budget_wallet/src/notifier.dart';
import 'package:budget_wallet/src/nudges.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  var permission = true;

  setUp(() {
    calls = [];
    permission = true;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'initialize' => true,
        'requestNotificationsPermission' => permission,
        _ => null,
      };
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null));

  AndroidNudges make() => AndroidNudges(zoneName: () async => 'Europe/Zagreb');

  test('on Android the real platform is the plugin one, elsewhere nothing', () {
    expect(defaultNudgePlatform().supported, isTrue, reason: 'flutter test reports Android');
    expect(const NoNudges().supported, isFalse);
  });

  test('permission: asks the system once and passes its answer on', () async {
    final n = make();
    expect(await n.requestPermission(), isTrue);
    permission = false;
    expect(await make().requestPermission(), isFalse);
    expect(calls.where((c) => c.method == 'requestNotificationsPermission').length, 2);
  });

  test('schedule: clears the old ones, then one inexact notification per slot, with the plain text only', () async {
    final slots = nudgeSlots(DateTime.now(), days: 10);
    final n = await make().schedule(slots);
    expect(n, slots.length);
    expect(calls.map((c) => c.method).first, 'initialize');
    expect(calls.indexWhere((c) => c.method == 'cancelAll'), lessThan(calls.indexWhere((c) => c.method == 'zonedSchedule')));
    final sched = calls.where((c) => c.method == 'zonedSchedule').toList();
    expect(sched.length, slots.length);
    for (final (i, c) in sched.indexed) {
      final a = Map<String, Object?>.from(c.arguments as Map);
      expect(a['title'], nudgeTitle);
      expect(a['body'], slots[i].body);
      expect(a['body'].toString(), isNot(matches(RegExp(r'[0-9€]'))));
      expect(a['timeZoneName'], 'Europe/Zagreb');
      final spec = Map<String, Object?>.from(a['platformSpecifics'] as Map);
      expect(spec['scheduleMode'], 'inexactAllowWhileIdle', reason: 'no exact-alarm permission');
    }
  });

  test('cancelAll goes to the plugin, also in a fresh run that scheduled nothing yet', () async {
    await make().cancelAll();
    expect(calls.map((c) => c.method), contains('cancelAll'));
  });

  test('an unknown time zone falls back to UTC and still schedules', () async {
    final n = AndroidNudges(zoneName: () async => 'Nowhere/Atlantis');
    expect(await n.schedule(nudgeSlots(DateTime.now(), days: 3)), greaterThan(0));
  });
}
