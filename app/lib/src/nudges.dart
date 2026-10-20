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
  Future<void> cancelAll();
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
}
