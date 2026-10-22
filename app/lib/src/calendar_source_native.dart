// Native-only: the phone's calendars through device_calendar_plus (Android CalendarContract). Read calls only; nothing is ever
// created, changed or deleted. Keep this file out of screens/ and widgets/.
import 'package:device_calendar_plus/device_calendar_plus.dart' hide CalendarSource;
import 'package:wallet_core/wallet_core.dart';

import 'calendar_source.dart';
import 'platform.dart';

final _log = Logger('bw.calendar');

/// The device calendars on Android, [NoCalendars] elsewhere.
CalendarSource defaultCalendarSource() => isAndroid ? AndroidCalendars() : const NoCalendars();

class AndroidCalendars implements CalendarSource {
  final DeviceCalendar _plugin;
  AndroidCalendars({DeviceCalendar? plugin}) : _plugin = plugin ?? DeviceCalendar.instance;

  @override
  bool get supported => true;

  @override
  Future<bool> hasPermission() async => await _plugin.hasPermissions() == CalendarPermissionStatus.granted;

  @override
  Future<bool> requestPermission() async {
    final granted = await _plugin.requestPermissions() == CalendarPermissionStatus.granted;
    logEvent(_log, Level.INFO, 'calendar.permission', {'granted': granted});
    return granted;
  }

  @override
  Future<List<DeviceCalendarInfo>> calendars() async => [
        for (final c in await _plugin.listCalendars())
          if (!c.hidden) DeviceCalendarInfo(c.id, c.name, account: c.accountName),
      ];

  @override
  Future<List<CalendarEvent>> events(Set<String> calendarIds, String from, String to) async {
    if (calendarIds.isEmpty) return const [];
    final start = parseIso(from);
    final end = parseIso(addDays(to, 1));
    final list = await _plugin.listEvents(DateTime(start.year, start.month, start.day), DateTime(end.year, end.month, end.day),
        calendarIds: calendarIds.toList());
    return calendarEventsFrom(list);
  }
}

/// The plugin's events as [CalendarEvent]s; cancelled ones are left out (like `STATUS:CANCELLED` in an `.ics` file).
List<CalendarEvent> calendarEventsFrom(Iterable<Event> list) => [
      for (final e in list)
        if (e.status != EventStatus.canceled)
          CalendarEvent(
            calendarId: e.calendarId,
            uid: e.eventId,
            title: e.title,
            notes: e.description,
            date: isoDate(e.startDate),
            allDay: e.isAllDay,
          ),
    ];
