// Nudges: short, funny, encouraging reminders. The words never carry amounts, merchants, names or any other wallet data,
// because a notification shows on the lock screen. No dart:io and no plugin here (the scheduling is in notifier.dart).
import 'package:wallet_core/wallet_core.dart';

/// The lines. Keep them free of digits, money words and brand names (`test/nudges_test.dart` checks).
const nudgeLines = [
  'Delivery apps are plotting. Your kitchen believes in you.',
  'Your future self just sent a thank-you note.',
  'The wallet is calm. Keep it that way.',
  'A small pause now, a big smile at payday.',
  'Cooking tonight? Your fridge is ready for its big moment.',
  'The impulse will pass. Your budget will stay.',
  'Tiny choices, tidy wallet. You are doing great.',
  'Coffee at home tastes like savings.',
  'The wishlist can wait. Good things keep.',
  'Be kind to your budget. It has been good to you.',
  'One sensible choice today beats a hundred plans.',
  'Your wallet says thanks for the quiet day.',
  'Snack drawer, you are the hero now.',
  'Pat on the back for keeping track. Go on.',
];

/// The line for [date] (`YYYY-MM-DD`): the same day always gets the same line, neighbouring days differ.
String nudgeFor(String date) {
  final d = parseIso(date);
  final day = DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(2026)).inDays;
  return nudgeLines[day % nudgeLines.length];
}

const nudgeTitle = 'Budget Wallet';

/// One notification to show: [date] at [hour]:[minute] local time.
class NudgeSlot {
  final String date;
  final int hour, minute;
  final String title, body;
  const NudgeSlot(this.date, this.hour, this.minute, this.title, this.body);
}

/// The next [days] days of reminders from [now]: 15:00 on weekdays, 11:00 on Sunday, none on Saturday. A time that has
/// already passed today is left out.
List<NudgeSlot> nudgeSlots(DateTime now, {int days = 28}) {
  final today = isoDate(now);
  final out = <NudgeSlot>[];
  for (var i = 0; i < days; i++) {
    final date = addDays(today, i);
    final wd = parseIso(date).weekday;
    if (wd == DateTime.saturday) continue;
    final hour = wd == DateTime.sunday ? 11 : 15;
    if (i == 0 && now.hour >= hour) continue;
    out.add(NudgeSlot(date, hour, 0, nudgeTitle, nudgeFor(date)));
  }
  return out;
}

/// The reminders of the phone, behind one small interface so the app and its tests don't touch the plugin directly.
abstract class NudgePlatform {
  /// False where the app cannot show reminders (desktop): the switch in Plan is then off and says so.
  bool get supported;

  /// Asks the system for permission to show notifications (Android 13 and later asks the user). True when allowed.
  Future<bool> requestPermission();

  /// Replaces every scheduled reminder with [slots]; returns how many were scheduled.
  Future<int> schedule(List<NudgeSlot> slots);

  /// Cancels every scheduled notification of the app, heads-ups included (the controller schedules those again after it).
  Future<void> cancelAll();

  /// Heads-ups before big planned costs: their own channel and ids ([headsUpFirstId] ..), so they never replace the reminders.
  /// Replaces the earlier heads-ups with [slots] (at most [headsUpMax]); returns how many were scheduled.
  Future<int> scheduleHeadsUps(List<NudgeSlot> slots);
  Future<void> cancelHeadsUps();

  /// Return-window and warranty reminders of the bills database: channel `bills`, ids [billFirstId] .. Replaces the earlier ones
  /// with [slots] (at most [billMax]); returns how many were scheduled.
  Future<int> scheduleBillReminders(List<NudgeSlot> slots);
  Future<void> cancelBillReminders();
}

/// Notification ids 1000..1019 belong to heads-ups; reminders use 0..27.
const headsUpFirstId = 1000;
const headsUpMax = 20;

/// The heads-up text for a planned cost [daysLeft] days away. No amount, no title: it shows on the lock screen.
String headsUpBody(int daysLeft) => switch (daysLeft) {
      0 => 'A big planned cost is due today.',
      1 => 'A big planned cost is coming up tomorrow.',
      _ => 'A big planned cost is coming up in $daysLeft days.',
    };

/// The heads-up notifications for [items] (date and days ahead of each): 09:00 local on (date - [days]); when that moment has
/// already passed, at the next 09:00 still ahead, as long as that is on or before the cost's date (none otherwise). The text
/// says how many days are left at the time of the notification. [now] decides what is already past.
List<NudgeSlot> headsUpSlots(DateTime now, Iterable<(String date, int days)> items) {
  final today = isoDate(now);
  final nextNine = now.hour < 9 ? today : addDays(today, 1);
  final out = <NudgeSlot>[];
  for (final (date, days) in items) {
    var at = addDays(date, -days);
    if (at.compareTo(nextNine) < 0) at = nextNine;
    if (at.compareTo(date) > 0) continue;
    out.add(NudgeSlot(at, 9, 0, nudgeTitle, headsUpBody(daysBetween(at, date))));
  }
  out.sort((a, b) => a.date.compareTo(b.date));
  return out.take(headsUpMax).toList();
}

/// Notification ids 1020..1039 belong to bill reminders (return windows and warranties).
const billFirstId = 1020;
const billMax = 20;

/// The reminder text for a return window or a warranty [daysLeft] days from ending. No payee, amount or item: it shows on the
/// lock screen.
String billReminderBody({required bool warranty, required int daysLeft}) {
  final what = warranty ? 'A warranty' : 'A return window';
  return switch (daysLeft) {
    0 => '$what ends today',
    1 => '$what ends tomorrow',
    _ => '$what ends in $daysLeft days',
  };
}

/// The bill reminders for [items] (end date, warranty or return window, days ahead): 09:00 local on (date - days); when that has
/// already passed, the next 09:00 still ahead as long as it is on or before the end date (none otherwise). Same rule as
/// [headsUpSlots]. At most [billMax], earliest first.
List<NudgeSlot> billReminderSlots(DateTime now, Iterable<(String date, bool warranty, int days)> items) {
  final today = isoDate(now);
  final nextNine = now.hour < 9 ? today : addDays(today, 1);
  final out = <NudgeSlot>[];
  for (final (date, warranty, days) in items) {
    var at = addDays(date, -days);
    if (at.compareTo(nextNine) < 0) at = nextNine;
    if (at.compareTo(date) > 0) continue;
    out.add(NudgeSlot(at, 9, 0, nudgeTitle, billReminderBody(warranty: warranty, daysLeft: daysBetween(at, date))));
  }
  out.sort((a, b) => a.date.compareTo(b.date));
  return out.take(billMax).toList();
}

/// Where reminders are not available: does nothing and never fails.
class NoNudges implements NudgePlatform {
  const NoNudges();
  @override
  bool get supported => false;
  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<int> schedule(List<NudgeSlot> slots) async => 0;
  @override
  Future<void> cancelAll() async {}
  @override
  Future<int> scheduleHeadsUps(List<NudgeSlot> slots) async => 0;
  @override
  Future<void> cancelHeadsUps() async {}
  @override
  Future<int> scheduleBillReminders(List<NudgeSlot> slots) async => 0;
  @override
  Future<void> cancelBillReminders() async {}
}
