import 'calendar_source.dart';

/// No device calendars in the browser (`.ics` files only).
CalendarSource defaultCalendarSource() => const NoCalendars();
