// Reminder texts and the schedule (pure Dart, no plugin). SYNTHETIC dates only.
import 'package:budget_wallet/src/nudges.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no reminder line carries a digit, a money sign or a bank/merchant word', () {
    for (final l in nudgeLines) {
      expect(l, isNot(matches(RegExp(r'[0-9€$£]'))), reason: l);
      expect(l.toLowerCase(), isNot(matches(RegExp(r'eur|euro|kuna|pbz|revolut|lidl|konzum|wolt|salary|rent|loan'))), reason: l);
      expect(l.length, lessThan(80), reason: 'short enough for a lock screen');
    }
    expect(nudgeLines.length, greaterThanOrEqualTo(12));
    expect(nudgeLines.toSet().length, nudgeLines.length, reason: 'no duplicates');
  });

  test('the same day always gets the same line, the next day another one', () {
    expect(nudgeFor('2026-10-20'), nudgeFor('2026-10-20'));
    for (var i = 0; i < 60; i++) {
      final d = DateTime.utc(2026, 10, 1).add(Duration(days: i));
      final a = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final n = d.add(const Duration(days: 1));
      final b = '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
      expect(nudgeFor(a), isNot(nudgeFor(b)), reason: '$a / $b');
    }
  });

  test('slots: 15:00 on weekdays, 11:00 on Sunday, none on Saturday, a passed time today is skipped', () {
    // Tuesday 20 Oct 2026, 09:00: today 15:00 still to come.
    final s = nudgeSlots(DateTime(2026, 10, 20, 9), days: 7);
    expect([for (final x in s) x.date], ['2026-10-20', '2026-10-21', '2026-10-22', '2026-10-23', '2026-10-25', '2026-10-26']);
    expect({
      for (final x in s)
        if (DateTime.parse(x.date).weekday != DateTime.sunday) x.hour
    }, {
      15
    });
    expect(s.firstWhere((x) => x.date == '2026-10-25').hour, 11);
    expect(s.every((x) => x.minute == 0), isTrue);
    // After 15:00 today is skipped.
    expect(nudgeSlots(DateTime(2026, 10, 20, 15, 30), days: 2).map((x) => x.date), ['2026-10-21']);
    // Sunday 12:00: Sunday's 11:00 has passed.
    expect(nudgeSlots(DateTime(2026, 10, 25, 12), days: 2).map((x) => x.date), ['2026-10-26']);
  });

  test('every slot is a plain title and one of the lines: no digits', () {
    final s = nudgeSlots(DateTime(2026, 10, 20, 9));
    expect(s.length, greaterThan(18));
    for (final x in s) {
      expect(x.title, nudgeTitle);
      expect(nudgeLines, contains(x.body));
      expect(x.title + x.body, isNot(matches(RegExp(r'[0-9]'))));
    }
  });

  test('NoNudges does nothing and never fails', () async {
    const n = NoNudges();
    expect(n.supported, isFalse);
    expect(await n.requestPermission(), isFalse);
    expect(await n.schedule(nudgeSlots(DateTime(2026, 10, 20))), 0);
    await n.cancelAll();
  });
}
