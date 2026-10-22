// The phone's calendars behind one small interface, so the app and its tests never touch the plugin directly (same idea as
// NudgePlatform). Read-only. Calendar names, ids and event titles stay on this device and are never logged.
import 'package:wallet_core/wallet_core.dart' show CalendarEvent;

/// One calendar of the phone's calendar app (any account that syncs to the device).
class DeviceCalendarInfo {
  /// Device-local id (never synced, never logged).
  final String id;
  final String name;

  /// The account it belongs to (an email address or the like), shown as a hint only.
  final String? account;
  const DeviceCalendarInfo(this.id, this.name, {this.account});
}

abstract class CalendarSource {
  /// False where the system has no calendar provider we can read (everything but Android): Plan then offers `.ics` only.
  bool get supported;

  /// Is calendar access allowed right now (no dialog)?
  Future<bool> hasPermission();

  /// Asks the system (the dialog appears the first time). True when allowed.
  Future<bool> requestPermission();

  Future<List<DeviceCalendarInfo>> calendars();

  /// Every occurrence in [from]..[to] (inclusive `YYYY-MM-DD`) of the calendars with these ids; recurring events are already
  /// expanded by the system.
  Future<List<CalendarEvent>> events(Set<String> calendarIds, String from, String to);
}

/// Where there is no calendar provider; does nothing and never fails.
class NoCalendars implements CalendarSource {
  const NoCalendars();
  @override
  bool get supported => false;
  @override
  Future<bool> hasPermission() async => false;
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<List<DeviceCalendarInfo>> calendars() async => const [];
  @override
  Future<List<CalendarEvent>> events(Set<String> calendarIds, String from, String to) async => const [];
}
