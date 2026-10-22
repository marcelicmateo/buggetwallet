// Native-only: the phone's reminders through flutter_local_notifications (keep this file out of screens/ and widgets/).
// Android only for now; everywhere else [defaultNudgePlatform] gives [NoNudges], which does nothing and never fails.
// Reminders are scheduled one by one for the next days with `inexactAllowWhileIdle`: no exact-alarm permission is needed,
// the system may move one by a few minutes. The app schedules again on start and resume, so the list never runs out.
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:wallet_core/wallet_core.dart';

import 'nudges.dart';
import 'platform.dart';

final _log = Logger('bw.nudges');

/// The reminders for this device: the Android plugin on Android, nothing elsewhere.
NudgePlatform defaultNudgePlatform() => isAndroid ? AndroidNudges() : const NoNudges();

/// Android reminders. [plugin] and [zoneName] are replaced in tests.
class AndroidNudges implements NudgePlatform {
  static const _tzChannel = MethodChannel('budget_wallet/timezone');

  final FlutterLocalNotificationsPlugin Function() _plugin;
  final Future<String> Function() _zoneName;
  FlutterLocalNotificationsPlugin? _p;
  bool _ready = false;

  AndroidNudges({FlutterLocalNotificationsPlugin Function()? plugin, Future<String> Function()? zoneName})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin.new,
        _zoneName = zoneName ?? _nativeZoneName;

  static Future<String> _nativeZoneName() async => await _tzChannel.invokeMethod<String>('getTimeZone') ?? 'UTC';

  @override
  bool get supported => true;

  Future<FlutterLocalNotificationsPlugin> _init() async {
    final p = _p ??= _plugin();
    if (_ready) return p;
    tzdata.initializeTimeZones(); // latest_all: Android names zones by link too (Europe/Zagreb), which the smaller sets lack
    var zone = 'UTC';
    try {
      zone = await _zoneName();
      tz.setLocalLocation(tz.getLocation(zone));
    } catch (e, st) {
      // Reminders then follow UTC; the zone name is not logged (it says where the owner lives).
      logError(_log, 'nudges.zoneFailed', e, st);
      tz.setLocalLocation(tz.UTC);
    }
    await p.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    _ready = true;
    return p;
  }

  @override
  Future<bool> requestPermission() async {
    final p = await _init();
    final android = p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission() ?? false;
    logEvent(_log, Level.INFO, 'nudges.permission', {'granted': granted});
    return granted;
  }

  @override
  Future<int> schedule(List<NudgeSlot> slots) async {
    final p = await _init();
    await p.cancelAll();
    const details = NotificationDetails(
        android: AndroidNotificationDetails('nudges', 'Reminders',
            channelDescription: 'Short, friendly reminders. They never show amounts.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority));
    final now = tz.TZDateTime.now(tz.local);
    var n = 0;
    for (final s in slots) {
      final d = parseIso(s.date);
      final at = tz.TZDateTime(tz.local, d.year, d.month, d.day, s.hour, s.minute);
      if (!at.isAfter(now)) continue; // the plugin throws on a past time, which would drop every later slot
      await p.zonedSchedule(
        id: n,
        title: s.title,
        body: s.body,
        scheduledDate: at,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
      n++;
    }
    return n;
  }

  @override
  Future<void> cancelAll() async {
    await (await _init()).cancelAll(); // also clears what an earlier run scheduled
  }

  @override
  Future<int> scheduleHeadsUps(List<NudgeSlot> slots) async {
    final p = await _init();
    await cancelHeadsUps();
    const details = NotificationDetails(
        android: AndroidNotificationDetails('headsup', 'Big costs coming up',
            channelDescription: 'A heads-up a few days before a big planned cost. It never shows amounts or names.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority));
    final now = tz.TZDateTime.now(tz.local);
    var n = 0;
    for (final s in slots.take(headsUpMax)) {
      final d = parseIso(s.date);
      final at = tz.TZDateTime(tz.local, d.year, d.month, d.day, s.hour, s.minute);
      if (!at.isAfter(now)) continue;
      await p.zonedSchedule(
        id: headsUpFirstId + n,
        title: s.title,
        body: s.body,
        scheduledDate: at,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
      n++;
    }
    return n;
  }

  @override
  Future<void> cancelHeadsUps() async {
    final p = await _init();
    for (var i = 0; i < headsUpMax; i++) {
      await p.cancel(id: headsUpFirstId + i);
    }
  }

  @override
  Future<int> scheduleBillReminders(List<NudgeSlot> slots) async {
    final p = await _init();
    await cancelBillReminders();
    const details = NotificationDetails(
        android: AndroidNotificationDetails('bills', 'Returns and warranties',
            channelDescription: 'A reminder before a return window or a warranty ends. It never shows names or amounts.',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority));
    final now = tz.TZDateTime.now(tz.local);
    var n = 0;
    for (final s in slots.take(billMax)) {
      final d = parseIso(s.date);
      final at = tz.TZDateTime(tz.local, d.year, d.month, d.day, s.hour, s.minute);
      if (!at.isAfter(now)) continue;
      await p.zonedSchedule(
        id: billFirstId + n,
        title: s.title,
        body: s.body,
        scheduledDate: at,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
      n++;
    }
    return n;
  }

  @override
  Future<void> cancelBillReminders() async {
    final p = await _init();
    for (var i = 0; i < billMax; i++) {
      await p.cancel(id: billFirstId + i);
    }
  }
}
