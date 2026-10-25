// Native-only: the phone's calendars through the app's own channel `budget_wallet/calendar` (MainActivity.kt: ContentResolver on
// CalendarContract.Calendars and .Instances, read only, READ_CALENDAR only). Nothing is ever created, changed or deleted. Keep this
// file out of screens/ and widgets/.
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';

import 'calendar_source.dart';
import 'platform.dart';

final _log = Logger('bw.calendar');

const _channel = MethodChannel('budget_wallet/calendar');

/// The device calendars on Android, [NoCalendars] elsewhere.
CalendarSource defaultCalendarSource() => isAndroid ? AndroidCalendars() : const NoCalendars();

class AndroidCalendars implements CalendarSource {
  final MethodChannel _ch;
  AndroidCalendars({MethodChannel? channel}) : _ch = channel ?? _channel;

  @override
  bool get supported => true;

  @override
  Future<bool> hasPermission() async => await _ch.invokeMethod<bool>('hasPermission') ?? false;

  @override
  Future<bool> requestPermission() async {
    final granted = await _ch.invokeMethod<bool>('requestPermission') ?? false;
    logEvent(_log, Level.INFO, 'calendar.permission', {'granted': granted});
    return granted;
  }

  @override
  Future<List<DeviceCalendarInfo>> calendars() async {
    final list = await _ch.invokeListMethod<Map<Object?, Object?>>('calendars') ?? const [];
    return [
      for (final c in list)
        if (c['id'] != null && c['name'] != null) DeviceCalendarInfo('${c['id']}', '${c['name']}', account: c['account'] as String?),
    ];
  }

  @override
  Future<List<CalendarEvent>> events(Set<String> calendarIds, String from, String to) async {
    if (calendarIds.isEmpty) return const [];
    final list = await _ch.invokeListMethod<Map<Object?, Object?>>('events', {'ids': calendarIds.toList(), 'from': from, 'to': to});
    return calendarEventsFrom(list ?? const []);
  }
}

final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// The channel's events as [CalendarEvent]s; cancelled ones (`status` 2 = STATUS_CANCELED) are left out (like `STATUS:CANCELLED` in an
/// `.ics` file). An entry without id, calendar or a valid date is skipped.
List<CalendarEvent> calendarEventsFrom(Iterable<Map<Object?, Object?>> list) => [
      for (final e in list)
        if (e['status'] != 2 && e['calendarId'] != null && e['id'] != null && e['date'] is String && _isoDate.hasMatch(e['date'] as String))
          CalendarEvent(
            calendarId: '${e['calendarId']}',
            uid: '${e['id']}',
            title: (e['title'] as String?) ?? '',
            notes: e['notes'] as String?,
            date: e['date'] as String,
            allDay: e['allDay'] == true,
          ),
    ];
