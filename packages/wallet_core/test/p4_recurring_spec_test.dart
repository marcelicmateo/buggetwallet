// Stage P4 spec tests, pure half: period classes, detection, payment matching and parts, dueCycles / computePeriod,
// billHistory per cycle. Written from docs/context/P4_SPEC.md only. All data is SYNTHETIC (made-up payees, amounts).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

var _seq = 0;

Tx bankTx(String date, int cents,
        {String desc = 'Zorblex Club', String? id, bool deleted = false, bool manual = false, String currency = 'EUR'}) =>
    Tx(
      id: id ?? 'b-${_seq++}',
      source: manual ? 'manual' : 'pbz',
      date: date,
      amount: -cents,
      currency: currency,
      bankType: 'POS plaćanje',
      description: desc,
      deleted: deleted,
      manual: manual,
    );

CategorizedTx cat(Tx t, [String category = 'Shopping']) => CategorizedTx(t, category, kindOf(category));

/// The payee key the bank rows of [desc] get.
String keyOf(String desc) => merchantKey(bankTx('2026-01-01', 100, desc: desc));

final zorblex = keyOf('Zorblex Club');

/// Rows of [desc] starting on [first], each [gaps] days after the one before.
List<CategorizedTx> series(String first, List<int> gaps, {String desc = 'Zorblex Club', int cents = 2000, String category = 'Shopping'}) {
  var d = first;
  final out = [cat(bankTx(d, cents, desc: desc), category)];
  for (final g in gaps) {
    d = addDays(d, g);
    out.add(cat(bankTx(d, cents, desc: desc), category));
  }
  return out;
}

List<RecurringBill> detect(List<CategorizedTx> rows, String today) => detectRecurring(rows, today: today, currency: 'EUR');

RecurringBill bill(
  String nextDue,
  int cents, {
  int interval = 30,
  int? min,
  int? max,
  String? endsOn,
  bool manual = false,
  String status = 'confirmed',
  String? lastPaidTx,
  String payee = 'zorblex_club',
  String category = 'Shopping',
  String id = 'rec:zorblex_club',
}) =>
    RecurringBill(
      id: id,
      payee: payee,
      label: 'Zorblex Club',
      category: category,
      expectedAmount: cents,
      intervalDays: interval,
      nextDue: nextDue,
      status: status,
      lastPaidTx: lastPaidTx,
      minAmount: min,
      maxAmount: max,
      endsOn: endsOn,
      manual: manual,
    );

RecurringPayments plan(List<RecurringBill> bills, List<Tx> rows) => planRecurringPayments(bills, rows, currency: 'EUR');

void main() {
  test('the test payee key is what the bills below use', () => expect(zorblex, 'zorblex_club'));

  group('RecurringPeriod', () {
    test('days: 7, 14, 30, 91, 365', () {
      expect([for (final p in RecurringPeriod.values) p.days], [7, 14, 30, 91, 365]);
      expect(RecurringPeriod.values.map((p) => p.name), ['weekly', 'biweekly', 'monthly', 'quarterly', 'yearly']);
    });

    test('of: the class with the nearest days', () {
      expect(RecurringPeriod.of(7), RecurringPeriod.weekly);
      expect(RecurringPeriod.of(14), RecurringPeriod.biweekly);
      expect(RecurringPeriod.of(30), RecurringPeriod.monthly);
      expect(RecurringPeriod.of(31), RecurringPeriod.monthly);
      expect(RecurringPeriod.of(91), RecurringPeriod.quarterly);
      expect(RecurringPeriod.of(90), RecurringPeriod.quarterly);
      expect(RecurringPeriod.of(365), RecurringPeriod.yearly);
      expect(RecurringPeriod.of(366), RecurringPeriod.yearly);
    });
  });

  group('RecurringBill model', () {
    Map<String, Object?> row({Object? interval = 30, Object? min, Object? max, Object? endsOn, Object? manual}) => {
          'id': 'rec:zorblex_club',
          'payee': 'zorblex_club',
          'label': 'Zorblex Club',
          'category': 'Shopping',
          'expected_amount': 5000,
          'interval_days': interval,
          'next_due': '2026-03-10',
          'status': 'confirmed',
          'min_amount': min,
          'max_amount': max,
          'ends_on': endsOn,
          'manual': manual,
        };

    test('fromRow reads the new columns; a row without them is a plain monthly bill', () {
      final b = RecurringBill.fromRow(row(min: 4000, max: 7000, endsOn: '2026-09-10', manual: 1));
      expect((b.minAmount, b.maxAmount, b.endsOn, b.manual), (4000, 7000, '2026-09-10', true));
      final plain = RecurringBill.fromRow(row());
      expect((plain.minAmount, plain.maxAmount, plain.endsOn, plain.manual), (null, null, null, false));
      expect((plain.hasRange, plain.isLong, plain.finished), (false, false, false));
      expect(plain.reserveAmount, 5000);
    });

    test('a stored interval outside 1..400 reads as 30; 1 and 400 stay', () {
      for (final bad in [0, -5, 401, 100000]) {
        expect(RecurringBill.fromRow(row(interval: bad)).intervalDays, 30, reason: '$bad');
      }
      expect(RecurringBill.fromRow(row(interval: 1)).intervalDays, 1);
      expect(RecurringBill.fromRow(row(interval: 400)).intervalDays, 400);
    });

    test('hasRange needs 0 < min <= max <= maxAmount; an invalid pair reads as no range', () {
      expect(bill('2026-03-10', 5000, min: 4000, max: 7000).hasRange, isTrue);
      expect(bill('2026-03-10', 5000, min: 5000, max: 5000).hasRange, isTrue, reason: 'min == max');
      expect(bill('2026-03-10', 5000, min: 4000, max: WalletSettings.maxAmount).hasRange, isTrue);
      expect(bill('2026-03-10', 5000, min: 4000, max: WalletSettings.maxAmount + 1).hasRange, isFalse);
      expect(bill('2026-03-10', 5000, min: 0, max: 7000).hasRange, isFalse);
      expect(bill('2026-03-10', 5000, min: -1, max: 7000).hasRange, isFalse);
      expect(bill('2026-03-10', 5000, min: 7001, max: 7000).hasRange, isFalse);
      expect(bill('2026-03-10', 5000, min: 4000).hasRange, isFalse, reason: 'only one end');
      expect(bill('2026-03-10', 5000, max: 7000).hasRange, isFalse, reason: 'only one end');
    });

    test('reserveAmount is the highest of a range, else the expected amount; an invalid range is ignored', () {
      expect(bill('2026-03-10', 5000, min: 4000, max: 7000).reserveAmount, 7000);
      expect(bill('2026-03-10', 5000).reserveAmount, 5000);
      expect(bill('2026-03-10', 5000, min: 7001, max: 7000).reserveAmount, 5000);
    });

    test('isLong is interval > 31', () {
      expect(bill('2026-03-10', 5000, interval: 31).isLong, isFalse);
      expect(bill('2026-03-10', 5000, interval: 32).isLong, isTrue);
      expect(bill('2026-03-10', 5000, interval: 7).isLong, isFalse);
      expect(bill('2026-03-10', 5000, interval: 91).isLong, isTrue);
      expect(bill('2026-03-10', 5000, interval: 365).isLong, isTrue);
    });

    test('finished: nextDue strictly after endsOn', () {
      expect(bill('2026-05-04', 5000, endsOn: '2026-05-04').finished, isFalse, reason: 'the last due date is still a cycle');
      expect(bill('2026-05-05', 5000, endsOn: '2026-05-04').finished, isTrue);
      expect(bill('2030-01-01', 5000).finished, isFalse, reason: 'no end');
    });

    test('tolerance by period: <=7 -> 1, <=14 -> 2, <=31 -> 3, <=92 -> 7, else 10', () {
      final expected = {1: 1, 7: 1, 8: 2, 14: 2, 15: 3, 30: 3, 31: 3, 32: 7, 91: 7, 92: 7, 93: 10, 365: 10, 400: 10};
      expected.forEach((days, tol) => expect(bill('2026-03-10', 5000, interval: days).tolerance, tol, reason: '$days days'));
    });

    test('copyWith keeps the new fields', () {
      final b = bill('2026-03-10', 5000, min: 4000, max: 7000, endsOn: '2026-09-10', manual: true).copyWith(nextDue: '2026-04-09');
      expect((b.minAmount, b.maxAmount, b.endsOn, b.manual, b.nextDue), (4000, 7000, '2026-09-10', true, '2026-04-09'));
    });
  });

  group('detectRecurring: classes', () {
    test('weekly: 4 rows 7 days apart; interval 7, next due 7 days on; 3 rows are not enough', () {
      final rows = series('2026-04-29', [7, 7, 7]);
      final c = detect(rows, '2026-05-22').single;
      expect((c.intervalDays, c.nextDue, c.status, c.expectedAmount), (7, '2026-05-27', 'candidate', 2000));
      expect(detect(rows.sublist(1), '2026-05-22'), isEmpty);
    });

    test('weekly tolerance is 1 day: gaps 6 and 8 pass, 5 and 9 do not', () {
      expect(detect(series('2026-04-28', [6, 8, 7]), '2026-05-22'), hasLength(1));
      expect(detect(series('2026-04-28', [8, 6, 7]), '2026-05-22'), hasLength(1));
      expect(detect(series('2026-04-28', [5, 7, 7]), '2026-05-22'), isEmpty);
      expect(detect(series('2026-04-28', [7, 9, 7]), '2026-05-22'), isEmpty);
    });

    test('weekly lookback is 8 weeks: four old rows are not a bill any more', () {
      final rows = series('2026-02-27', [7, 7, 7]); // last row 2026-03-20
      expect(detect(rows, '2026-03-25'), hasLength(1), reason: 'fresh');
      expect(detect(rows, '2026-05-22'), isEmpty, reason: 'nine weeks after the last row');
    });

    test('biweekly: 3 rows 14 days apart; 2 rows are not enough; tolerance 2', () {
      final rows = series('2026-03-25', [14, 14]);
      final c = detect(rows, '2026-05-01').single;
      expect((c.intervalDays, c.nextDue), (14, '2026-05-06'));
      expect(detect(rows.sublist(1), '2026-05-01'), isEmpty);
      expect(detect(series('2026-03-25', [12, 16]), '2026-05-01'), hasLength(1));
      expect(detect(series('2026-03-25', [11, 14]), '2026-05-01'), isEmpty);
      expect(detect(series('2026-03-25', [14, 17]), '2026-05-01'), isEmpty);
    });

    test('quarterly: 3 rows 91 days apart; 2 rows are not enough; tolerance 7', () {
      final rows = series('2025-12-01', [91, 91]);
      final c = detect(rows, '2026-06-20').single;
      expect((c.intervalDays, c.nextDue), (91, addDays(rows.last.date, 91)));
      expect(detect(rows.sublist(1), '2026-06-20'), isEmpty);
      expect(detect(series('2025-12-01', [98, 84]), '2026-06-20'), hasLength(1));
      expect(detect(series('2025-12-01', [91, 99]), '2026-06-20'), isEmpty);
      expect(detect(series('2025-12-01', [83, 91]), '2026-06-20'), isEmpty);
    });

    test('quarterly lookback is 13 months', () {
      final rows = series('2025-02-01', [91, 91]); // last row 2025-08-02
      expect(detect(rows, '2025-09-01'), hasLength(1));
      expect(detect(rows, '2026-12-01'), isEmpty, reason: 'sixteen months after the last row');
    });

    test('yearly: 2 rows 365 days apart are enough; one is not; tolerance 10', () {
      final rows = series('2025-03-10', [365]);
      final c = detect(rows, '2026-04-01').single;
      expect((c.intervalDays, c.nextDue), (365, '2027-03-10'));
      expect(detect(rows.sublist(1), '2026-04-01'), isEmpty);
      expect(detect(series('2025-01-10', [375]), '2026-04-01'), hasLength(1));
      expect(detect(series('2025-01-10', [355]), '2026-04-01'), hasLength(1));
      expect(detect(series('2025-01-10', [376]), '2026-04-01'), isEmpty);
      expect(detect(series('2025-01-10', [354]), '2026-04-01'), isEmpty);
    });

    test('yearly lookback is 25 months: rows from three years ago are not found', () {
      final rows = series('2023-01-05', [365]); // 2023-01-05, 2024-01-05
      expect(detect(rows, '2024-02-01'), hasLength(1));
      expect(detect(rows, '2026-04-01'), isEmpty);
    });

    test('mixed gaps (7, 14, 7) fit no class', () {
      expect(detect(series('2026-04-01', [7, 14, 7]), '2026-05-10'), isEmpty);
      expect(detect(series('2026-04-01', [7, 14]), '2026-05-10'), isEmpty);
    });

    test('the monthly rule is untouched: 3 rows 30 days apart, interval 30; 2 rows no', () {
      final rows = series('2025-12-10', [30, 30]);
      final c = detect(rows, '2026-03-01').single;
      expect((c.intervalDays, c.nextDue), (30, '2026-03-10'));
      expect(detect(rows.sublist(1), '2026-03-01'), isEmpty);
      expect(detect(series('2025-12-10', [27, 33]), '2026-03-01'), hasLength(1));
      expect(detect(series('2025-12-10', [26, 30]), '2026-03-01'), isEmpty);
    });

    test('the amount band is the same for every class: 10 % of the median', () {
      List<CategorizedTx> amounts(List<int> a, List<int> gaps) {
        var d = '2025-12-01';
        final out = <CategorizedTx>[];
        for (var i = 0; i < a.length; i++) {
          if (i > 0) d = addDays(d, gaps[i - 1]);
          out.add(cat(bankTx(d, a[i])));
        }
        return out;
      }

      expect(detect(amounts([9000, 10000, 11000], [91, 91]), '2026-06-20').single.expectedAmount, 10000);
      expect(detect(amounts([10000, 10000, 11001], [91, 91]), '2026-06-20'), isEmpty);
      expect(detect(amounts([10000, 13000], [365]), '2026-12-20'), isEmpty);
      expect(detect(amounts([10000, 11000], [365]), '2026-12-20'), hasLength(1));
    });

    test('two payees are detected separately, whatever the class', () {
      final rows = [
        ...series('2026-04-29', [7, 7, 7]),
        ...series('2026-03-25', [14, 14], desc: 'Quorvant Shop')
      ];
      final c = detect(rows, '2026-05-22');
      expect({for (final b in c) b.payee: b.intervalDays}, {zorblex: 7, keyOf('Quorvant Shop'): 14});
    });

    test('inflows, deleted rows and own transfers are never found, whatever the class', () {
      final inflow = [
        for (final c in series('2026-04-29', [7, 7, 7])) cat(bankTx(c.date, -2000))
      ];
      expect(detect(inflow, '2026-05-22'), isEmpty);
      final gone = [
        for (final c in series('2026-04-29', [7, 7, 7])) cat(bankTx(c.date, 2000, deleted: true))
      ];
      expect(detect(gone, '2026-05-22'), isEmpty);
      expect(detect(series('2025-03-10', [365], category: 'Internal transfer'), '2026-04-01'), isEmpty);
    });

    test('input order does not matter', () {
      final rows = series('2025-12-01', [91, 91]);
      expect(detect(rows.reversed.toList(), '2026-06-20').map((b) => b.nextDue), detect(rows, '2026-06-20').map((b) => b.nextDue));
    });
  });

  group('planRecurringPayments: single payment', () {
    test('weekly tolerance 1: nextDue -1 and +1 pay, +2 does not', () {
      final b = bill('2026-03-10', 1000, interval: 7);
      expect(plan([b], [bankTx('2026-03-11', 1000, id: 'x')]).paidBy[b.id]?.id, 'x');
      expect(plan([b], [bankTx('2026-03-09', 1000, id: 'x')]).paidBy[b.id]?.id, 'x');
      expect(plan([b], [bankTx('2026-03-12', 1000)]).paidBy, isEmpty);
    });

    test('quarterly tolerance 7: +7 pays, +8 does not; -7 pays', () {
      final b = bill('2026-06-10', 4500, interval: 91);
      expect(plan([b], [bankTx('2026-06-17', 4500, id: 'x')]).paidBy[b.id]?.id, 'x');
      expect(plan([b], [bankTx('2026-06-03', 4500, id: 'x')]).paidBy[b.id]?.id, 'x');
      expect(plan([b], [bankTx('2026-06-18', 4500)]).paidBy, isEmpty);
    });

    test('yearly tolerance 10: +10 pays, +11 does not', () {
      final b = bill('2026-09-10', 60000, interval: 365);
      expect(plan([b], [bankTx('2026-09-20', 60000, id: 'x')]).paidBy[b.id]?.id, 'x');
      expect(plan([b], [bankTx('2026-09-21', 60000)]).paidBy, isEmpty);
    });

    test('a range pays inclusively: min and max yes; one cent under min is a part, one cent over max is nothing', () {
      final b = bill('2026-03-10', 5500, min: 4000, max: 7000);
      expect(plan([b], [bankTx('2026-03-10', 4000, id: 'lo')]).paidBy[b.id]?.id, 'lo');
      expect(plan([b], [bankTx('2026-03-10', 7000, id: 'hi')]).paidBy[b.id]?.id, 'hi');
      final under = plan([b], [bankTx('2026-03-10', 3999, id: 'u')]);
      expect(under.paidBy, isEmpty);
      expect(under.partsPaid(b.id), 3999);
      expect([for (final t in under.parts[b.id]!) t.id], ['u']);
      final over = plan([b], [bankTx('2026-03-10', 7001)]);
      expect(over.paidBy, isEmpty);
      expect(over.partsPaid(b.id), 0, reason: 'a row over the highest amount is no part');
    });

    test('with a range the 10 % band of the expected amount does not matter', () {
      final b = bill('2026-03-10', 5500, min: 4000, max: 7000);
      expect(plan([b], [bankTx('2026-03-10', 6900, id: 'x')]).paidBy[b.id]?.id, 'x', reason: 'in the range, more than 10 % off 5500');
    });

    test('an invalid stored range falls back to the 10 % band', () {
      final b = bill('2026-03-10', 5000, min: 7001, max: 7000);
      expect(plan([b], [bankTx('2026-03-10', 6000)]).paidBy, isEmpty);
      expect(plan([b], [bankTx('2026-03-10', 5400, id: 'x')]).paidBy[b.id]?.id, 'x');
    });

    test('never on amount alone: another payee with the same amount and date does not pay', () {
      final b = bill('2026-03-10', 5000);
      final p = plan([b], [bankTx('2026-03-10', 5000, desc: 'Quorvant Shop')]);
      expect(p.paidBy, isEmpty);
      expect(p.partsPaid(b.id), 0);
    });

    test('a bill with no payee never matches', () {
      final b = bill('2026-03-10', 5000, payee: '', manual: true);
      final p = plan([b], [bankTx('2026-03-10', 5000), bankTx('2026-03-10', 5000, desc: 'Quorvant Shop')]);
      expect(p.paidBy, isEmpty);
      expect(p.partsPaid(b.id), 0);
    });

    test('a manual bill with a payee is matched like any other', () {
      final b = bill('2026-03-10', 5000, manual: true, interval: 91);
      expect(plan([b], [bankTx('2026-03-12', 5000, id: 'x')]).paidBy[b.id]?.id, 'x');
    });

    test('the closest row wins, then the earliest, then the smallest id', () {
      final b = bill('2026-06-10', 4500, interval: 91);
      expect(plan([b], [bankTx('2026-06-14', 4500, id: 'far'), bankTx('2026-06-11', 4500, id: 'near')]).paidBy[b.id]?.id, 'near');
      expect(plan([b], [bankTx('2026-06-12', 4500, id: 'late'), bankTx('2026-06-08', 4500, id: 'early')]).paidBy[b.id]?.id, 'early');
      expect(plan([b], [bankTx('2026-06-10', 4500, id: 'b'), bankTx('2026-06-10', 4500, id: 'a')]).paidBy[b.id]?.id, 'a');
    });

    test('the row that paid the last cycle does not pay again; deleted, manual, other currency and inflow rows never pay', () {
      final b = bill('2026-03-10', 5000, lastPaidTx: 'old');
      expect(plan([b], [bankTx('2026-03-10', 5000, id: 'old')]).paidBy, isEmpty);
      expect(plan([b], [bankTx('2026-03-10', 5000, deleted: true)]).paidBy, isEmpty);
      expect(plan([b], [bankTx('2026-03-10', 5000, manual: true)]).paidBy, isEmpty);
      expect(plan([b], [bankTx('2026-03-10', 5000, currency: 'USD')]).paidBy, isEmpty);
      expect(plan([b], [bankTx('2026-03-10', -5000)]).paidBy, isEmpty);
    });

    test('a candidate and a dismissed bill are not matched', () {
      expect(plan([bill('2026-03-10', 5000, status: 'candidate')], [bankTx('2026-03-10', 5000)]).paidBy, isEmpty);
      expect(plan([bill('2026-03-10', 5000, status: 'dismissed')], [bankTx('2026-03-10', 5000)]).paidBy, isEmpty);
    });

    test('a single payment wins over parts: no parts are listed for a paid cycle', () {
      final b = bill('2026-03-10', 10000);
      final p = plan([b], [bankTx('2026-03-03', 3000), bankTx('2026-03-10', 10000, id: 'full')]);
      expect(p.paidBy[b.id]?.id, 'full');
      expect(p.parts[b.id] ?? const [], isEmpty);
    });
  });

  group('planRecurringPayments: parts', () {
    test('60 + 40 pays a 100 cycle; the completing row is the paying row', () {
      final b = bill('2026-03-10', 10000);
      final p = plan([b], [bankTx('2026-03-05', 6000, id: 'p1'), bankTx('2026-03-09', 4000, id: 'p2')]);
      expect(p.paidBy[b.id]?.id, 'p2');
      expect(p.parts[b.id] ?? const [], isEmpty, reason: 'parts lists unpaid cycles only');
    });

    test('rows are summed oldest first, whatever the input order', () {
      final b = bill('2026-03-10', 10000);
      final p = plan([b], [bankTx('2026-03-09', 4000, id: 'p2'), bankTx('2026-03-05', 6000, id: 'p1')]);
      expect(p.paidBy[b.id]?.id, 'p2');
    });

    test('60 alone stays open: 40 rest, the row is listed', () {
      final b = bill('2026-03-10', 10000);
      final p = plan([b], [bankTx('2026-03-05', 6000, id: 'p1')]);
      expect(p.paidBy, isEmpty);
      expect(p.partsPaid(b.id), 6000);
      expect([for (final t in p.parts[b.id]!) t.id], ['p1']);
    });

    test('threshold is the low end of the 10 % band: 9000 pays, 8999 does not', () {
      final b = bill('2026-03-10', 10000);
      final pays = plan([b], [bankTx('2026-03-05', 5000, id: 'a'), bankTx('2026-03-09', 4000, id: 'b')]);
      expect(pays.paidBy[b.id]?.id, 'b');
      final short = plan([b], [bankTx('2026-03-05', 5000, id: 'a'), bankTx('2026-03-09', 3999, id: 'b')]);
      expect(short.paidBy, isEmpty);
      expect(short.partsPaid(b.id), 8999);
    });

    test('with a range the threshold is the minimum: min pays, one cent short does not', () {
      final b = bill('2026-03-10', 5500, min: 4000, max: 7000);
      final pays = plan([b], [bankTx('2026-03-05', 2500, id: 'a'), bankTx('2026-03-09', 1500, id: 'b')]);
      expect(pays.paidBy[b.id]?.id, 'b');
      final short = plan([b], [bankTx('2026-03-05', 2500, id: 'a'), bankTx('2026-03-09', 1499, id: 'b')]);
      expect(short.paidBy, isEmpty);
      expect(short.partsPaid(b.id), 3999);
    });

    test('a part is at most the reserve amount: bigger rows are not counted', () {
      final b = bill('2026-03-10', 10000, min: 8000, max: 12000);
      final p = plan([b], [bankTx('2026-03-05', 12001, id: 'big'), bankTx('2026-03-06', 3000, id: 'p1')]);
      expect(p.partsPaid(b.id), 3000, reason: '12001 is over the highest amount');
    });

    test('another payee\'s rows are never counted', () {
      final b = bill('2026-03-10', 10000);
      final p = plan([b], [bankTx('2026-03-05', 6000, id: 'p1'), bankTx('2026-03-08', 4000, desc: 'Quorvant Shop')]);
      expect(p.paidBy, isEmpty);
      expect(p.partsPaid(b.id), 6000);
    });

    test('window: monthly parts count from nextDue - 14 (inclusive) to nextDue + 3', () {
      final b = bill('2026-03-10', 10000);
      expect(plan([b], [bankTx('2026-02-24', 6000)]).partsPaid(b.id), 6000);
      expect(plan([b], [bankTx('2026-02-23', 6000)]).partsPaid(b.id), 0);
      expect(plan([b], [bankTx('2026-03-13', 6000)]).partsPaid(b.id), 6000);
      expect(plan([b], [bankTx('2026-03-14', 6000)]).partsPaid(b.id), 0);
    });

    test('window: weekly parts count from nextDue - 5 (partsDays = interval - tolerance - 1)', () {
      final b = bill('2026-03-10', 1000, interval: 7);
      expect(plan([b], [bankTx('2026-03-05', 600)]).partsPaid(b.id), 600);
      expect(plan([b], [bankTx('2026-03-04', 600)]).partsPaid(b.id), 0);
    });

    test('window: biweekly parts count from nextDue - 11', () {
      final b = bill('2026-03-20', 1000, interval: 14);
      expect(plan([b], [bankTx('2026-03-09', 600)]).partsPaid(b.id), 600);
      expect(plan([b], [bankTx('2026-03-08', 600)]).partsPaid(b.id), 0);
    });

    test('a part on or before the last paid row never counts again', () {
      final b = bill('2026-03-10', 10000, lastPaidTx: 'last');
      final rows = [
        bankTx('2026-02-27', 6000, id: 'last'),
        bankTx('2026-02-26', 4000, id: 'before'),
        bankTx('2026-02-27', 4000, id: 'same-day'),
        bankTx('2026-02-28', 6000, id: 'after'),
      ];
      final p = plan([b], rows);
      expect(p.partsPaid(b.id), 6000, reason: 'only the row strictly after the last paid row');
      expect([for (final t in p.parts[b.id]!) t.id], ['after']);
      expect(p.paidBy, isEmpty);
    });

    test('deleted, hand-added and other-currency rows are no parts', () {
      final b = bill('2026-03-10', 10000);
      final p = plan([
        b
      ], [
        bankTx('2026-03-05', 6000, deleted: true),
        bankTx('2026-03-06', 6000, manual: true),
        bankTx('2026-03-07', 6000, currency: 'USD')
      ]);
      expect(p.partsPaid(b.id), 0);
    });

    test('quarterly bill paid in two parts: window up to nextDue - 14', () {
      final b = bill('2026-06-10', 9000, interval: 91);
      final p = plan([b], [bankTx('2026-05-27', 5000, id: 'a'), bankTx('2026-06-09', 4000, id: 'b')]);
      expect(p.paidBy[b.id]?.id, 'b');
      expect(plan([b], [bankTx('2026-05-26', 5000)]).partsPaid(b.id), 0);
    });

    test('partsPaid of an unknown bill is 0', () => expect(plan([], []).partsPaid('rec:nope'), 0));
  });

  group('dueCycles', () {
    const start = '2026-02-15', end = '2026-03-15';
    List<(String, int)> cycles(List<RecurringBill> bills, {List<CategorizedTx> txs = const [], RecurringPayments? payments}) => [
          for (final c in dueCycles(bills, txs, start, end, payments: payments)) (c.due, c.reserve),
        ];

    test('a monthly bill with no new fields: one cycle at nextDue, as dueBills', () {
      expect(cycles([bill('2026-03-05', 5000)]), [('2026-03-05', 5000)]);
      expect(cycles([bill('2026-03-15', 5000)]), isEmpty, reason: 'due on payday = next period');
      expect(cycles([bill('2026-03-14', 5000)]), [('2026-03-14', 5000)]);
      expect(cycles([bill('2026-02-01', 5000)]), [('2026-02-01', 5000)], reason: 'overdue is still due');
    });

    test('a weekly bill reserves every occurrence before payday', () {
      expect(cycles([bill('2026-03-02', 1000, interval: 7)]), [('2026-03-02', 1000), ('2026-03-09', 1000)]);
      expect(cycles([bill('2026-02-28', 1000, interval: 7)]), [('2026-02-28', 1000), ('2026-03-07', 1000), ('2026-03-14', 1000)]);
      expect(cycles([bill('2026-03-14', 1000, interval: 7)]), [('2026-03-14', 1000)]);
    });

    test('biweekly: every 14 days', () {
      expect(cycles([bill('2026-02-20', 2000, interval: 14)]), [('2026-02-20', 2000), ('2026-03-06', 2000)]);
    });

    test('a range reserves its highest amount', () {
      expect(cycles([bill('2026-03-05', 5000, min: 4000, max: 7000)]), [('2026-03-05', 7000)]);
      expect(cycles([bill('2026-03-05', 5000, min: 7001, max: 7000)]), [('2026-03-05', 5000)], reason: 'invalid range ignored');
    });

    test('instalments stop at endsOn, inclusive', () {
      expect(cycles([bill('2026-03-02', 1000, interval: 7, endsOn: '2026-03-09')]), [('2026-03-02', 1000), ('2026-03-09', 1000)]);
      expect(cycles([bill('2026-03-02', 1000, interval: 7, endsOn: '2026-03-08')]), [('2026-03-02', 1000)]);
      expect(cycles([bill('2026-03-05', 5000, endsOn: '2026-03-05')]), [('2026-03-05', 5000)]);
    });

    test('a finished bill and an unconfirmed one have no cycle', () {
      expect(cycles([bill('2026-03-05', 5000, endsOn: '2026-03-04')]), isEmpty);
      expect(cycles([bill('2026-03-05', 5000, status: 'candidate')]), isEmpty);
      expect(cycles([bill('2026-03-05', 5000, status: 'dismissed')]), isEmpty);
      expect(cycles([bill('2030-03-05', 50000, interval: 365, status: 'candidate')]), isEmpty);
    });

    test('a long bill is held in full from now on, also when due in ten months', () {
      expect(cycles([bill('2027-01-10', 60000, interval: 365)]), [('2027-01-10', 60000)]);
      expect(cycles([bill('2026-06-01', 9000, interval: 91)]), [('2026-06-01', 9000)]);
    });

    test('a long bill holds one cycle only, also when overdue or when the period is long', () {
      expect(cycles([bill('2026-01-01', 9000, interval: 91)]), [('2026-01-01', 9000)]);
      expect(cycles([bill('2026-03-01', 9000, interval: 91)]), [('2026-03-01', 9000)]);
    });

    test('a long bill with a range holds the highest amount', () {
      expect(cycles([bill('2026-08-01', 5000, interval: 91, min: 4000, max: 7000)]), [('2026-08-01', 7000)]);
    });

    test('a long bill with no endsOn problem: finished long bill holds nothing', () {
      expect(cycles([bill('2026-08-01', 9000, interval: 91, endsOn: '2026-07-31')]), isEmpty);
      expect(cycles([bill('2026-08-01', 9000, interval: 91, endsOn: '2026-08-01')]), [('2026-08-01', 9000)]);
    });

    test('parts paid reduce the first cycle only; later weekly occurrences reserve in full', () {
      final b = bill('2026-03-02', 1000, interval: 7);
      final p = plan([b], [bankTx('2026-02-28', 600, id: 'part')]);
      final cs = dueCycles([b], const [], start, end, payments: p);
      expect([for (final c in cs) (c.due, c.paid, c.reserve)], [('2026-03-02', 600, 400), ('2026-03-09', 0, 1000)]);
      expect(cs.first.bill.id, b.id);
    });

    test('parts paid reduce a long bill\'s held amount; never below zero', () {
      final b = bill('2026-03-20', 60000, interval: 365);
      final p = plan([b], [bankTx('2026-03-10', 20000, id: 'part')]);
      expect(cycles([b], payments: p), [('2026-03-20', 40000)]);
      final all = plan([b], [bankTx('2026-03-10', 60000, id: 'whole')]);
      expect(all.paidBy[b.id], isNotNull, reason: 'precondition: paid, so no parts');
    });

    test('the cycle carries the bill and the paid amount', () {
      final c = dueCycles([bill('2026-03-05', 5000)], const [], start, end).single;
      expect((c.bill.id, c.due, c.reserve, c.paid), ('rec:zorblex_club', '2026-03-05', 5000, 0));
    });

    test('the first cycle is dropped when lastPaidTx is dated in the period (as dueBills)', () {
      final paid = cat(bankTx('2026-02-20', 5000, id: 'paid'));
      expect(cycles([bill('2026-03-05', 5000, lastPaidTx: 'paid')], txs: [paid]), isEmpty);
      final before = cat(bankTx('2026-02-14', 5000, id: 'paid'));
      expect(cycles([bill('2026-03-05', 5000, lastPaidTx: 'paid')], txs: [before]), [('2026-03-05', 5000)]);
    });
  });

  group('computePeriod with P4 bills', () {
    final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
    PeriodBudget period(List<RecurringBill> bills, {List<CategorizedTx> txs = const [], List<PlannedCost> planned = const []}) =>
        computePeriod(txs, st, const [], '2026-03-01', bills: bills, planned: planned, table: CategoryTable.builtIn);

    final base = period(const []);

    test('a weekly bill reserves each occurrence before payday; dueBills lists the bill once', () {
      final p = period([bill('2026-03-02', 1000, interval: 7)]);
      expect(p.reservedBills, 2000);
      expect(p.dueBills, hasLength(1));
      expect(p.dueCycles, hasLength(2));
      expect(p.flexBudget, base.flexBudget - 2000);
    });

    test('an overdue weekly bill reserves its missed occurrence too', () {
      expect(period([bill('2026-02-28', 1000, interval: 7)]).reservedBills, 3000);
    });

    test('a yearly bill is held in full from confirmation, also when due in ten months', () {
      final p = period([bill('2027-01-10', 60000, interval: 365)]);
      expect(p.reservedBills, 60000);
      expect(p.flexBudget, base.flexBudget - 60000);
      expect(p.dueBills.single.id, 'rec:zorblex_club');
      expect(p.dueCycles.single.due, '2027-01-10');
    });

    test('a long bill in a fixed category is still reserved; a monthly one is only listed', () {
      final long = period([bill('2026-08-01', 9000, interval: 91, category: 'Bills & subscriptions')]);
      expect(long.reservedBills, 9000);
      final monthly = period([bill('2026-03-05', 9000, category: 'Bills & subscriptions')]);
      expect(monthly.reservedBills, 0);
      expect(monthly.dueBills, hasLength(1));
    });

    test('a range reserves the highest amount', () {
      expect(period([bill('2026-03-05', 5000, min: 4000, max: 7000)]).reservedBills, 7000);
    });

    test('a finished instalment bill reserves nothing and is not listed', () {
      final p = period([bill('2026-03-05', 5000, endsOn: '2026-02-05', manual: true)]);
      expect(p.reservedBills, 0);
      expect(p.dueCycles, isEmpty);
      expect(p.dueBills, isEmpty);
    });

    test('a monthly instalment behaves as monthly: one cycle, last one reserved', () {
      expect(period([bill('2026-03-05', 5000, endsOn: '2026-03-05')]).reservedBills, 5000);
    });

    test('rest of a bill paid in parts stays set aside (rows in the period)', () {
      final part = cat(bankTx('2026-02-28', 600, id: 'part'));
      final p = period([bill('2026-03-02', 1000, interval: 7)], txs: [part]);
      expect(p.reservedBills, 400 + 1000);
    });

    test('two bills add up across periods and classes', () {
      final p = period([
        bill('2026-03-02', 1000, interval: 7),
        bill('2026-03-05', 5000, id: 'rec:other', payee: 'other'),
        bill('2027-01-10', 60000, interval: 365, id: 'rec:year', payee: 'year'),
      ]);
      expect(p.reservedBills, 2000 + 5000 + 60000);
    });

    group('long bills right after a payment', () {
      for (final category in ['Shopping', 'Bills & subscriptions']) {
        test('yearly bill paid in this period ($category): the next cycle is held in full at once', () {
          final paid = cat(bankTx('2026-02-20', 60000, id: 'paid'), category);
          final p = period([bill('2027-02-20', 60000, interval: 365, lastPaidTx: 'paid', category: category)], txs: [paid]);
          expect(p.reservedBills, 60000);
          expect(p.dueCycles.single.due, '2027-02-20');
        });

        test('yearly bill whose paying row exists but refresh has not run: that cycle reserves 0 ($category)', () {
          final row = cat(bankTx('2026-03-09', 60000, id: 'row'), category);
          final p = period([bill('2026-03-10', 60000, interval: 365, category: category)], txs: [row]);
          expect(p.reservedBills, 0);
        });
      }

      test('a monthly bill paid in this period is still dropped', () {
        final paid = cat(bankTx('2026-02-20', 5000, id: 'paid'));
        expect(period([bill('2026-03-05', 5000, lastPaidTx: 'paid')], txs: [paid]).reservedBills, 0);
      });
    });

    group('a slip that covers a cycle is not reserved twice', () {
      final slipPayee = merchantKey(const Tx(id: '', source: 'bill', date: '', amount: 0, description: 'Zorblex Club'));
      PlannedCost slip(String date) => PlannedCost(
          id: 'planned:bill:s1',
          title: 'Zorblex Club',
          date: date,
          amount: 1000,
          category: 'Shopping',
          sourceRef: 's1',
          source: PlannedSource.bill);

      test('control: the slip alone is reserved', () {
        expect(period(const [], planned: [slip('2026-03-09')]).reservedPlanned, 1000);
      });

      test('a weekly bill\'s second cycle covers a slip dated on it', () {
        final p = period([bill('2026-03-02', 1000, interval: 7, payee: slipPayee)], planned: [slip('2026-03-09')]);
        expect(p.reservedBills, 2000);
        expect(p.reservedPlanned, 0);
      });

      test('a monthly bill covers a slip near its cycle', () {
        final p = period([bill('2026-03-05', 5000, payee: slipPayee)], planned: [slip('2026-03-06')]);
        expect(p.reservedBills, 5000);
        expect(p.reservedPlanned, 0);
      });

      test('a slip of another payee is reserved in addition', () {
        final p = period([bill('2026-03-05', 5000, payee: 'other_payee')], planned: [slip('2026-03-06')]);
        expect(p.reservedBills + p.reservedPlanned, 6000);
      });
    });
  });

  group('billHistory per cycle', () {
    List<BillMonth> history(RecurringBill b, List<Tx> rows, {int months = 4, String today = '2026-06-01'}) =>
        billHistory(b, rows, const <Bill>[], today: today, months: months, currency: 'EUR');

    final quarterly = bill('2026-06-10', 4500, interval: 91);

    test('a quarterly bill has one line per cycle, as many as asked, newest first', () {
      final h = history(quarterly, [bankTx('2026-03-12', 4500, id: 'q1'), bankTx('2025-12-12', 4500, id: 'q0')]);
      expect(h, hasLength(4));
      final paid = h.where((m) => m.state == BillMonthState.paid).toList();
      expect([
        for (final m in paid) m.payments.map((t) => t.id).toList()
      ], [
        ['q1'],
        ['q0']
      ], reason: 'newest first');
      expect([for (final m in paid) m.paid], [4500, 4500]);
    });

    test('the number of lines follows months', () {
      expect(history(quarterly, const [], months: 2), hasLength(2));
      expect(history(quarterly, const [], months: 6), hasLength(6));
    });

    test('quarterly lines carry due (the cycle date) and month (its YYYY-MM); monthly lines have due == null', () {
      final h = history(quarterly, [bankTx('2026-03-12', 4500, id: 'q1')]);
      for (final m in h) {
        expect(m.due, isNotNull);
        expect(m.month, m.due!.substring(0, 7));
      }
      final dues = [for (final m in h) m.due!];
      expect(dues, [...dues]..sort((a, b) => b.compareTo(a)), reason: 'newest first');
      expect(h.singleWhere((m) => m.payments.isNotEmpty).due, '2026-03-11');
      final monthly =
          billHistory(bill('2026-06-15', 4500), [bankTx('2026-05-14', 4500)], const [], today: '2026-06-10', months: 3, currency: 'EUR');
      expect(monthly.every((m) => m.due == null), isTrue);
    });

    test('a cycle paid in parts is paid when the rows reach the threshold; paidCents and txIds list the parts', () {
      final h = history(quarterly, [bankTx('2026-03-05', 3000, id: 'a'), bankTx('2026-03-10', 1100, id: 'b')]);
      final line = h.singleWhere((m) => m.payments.isNotEmpty);
      expect(line.state, BillMonthState.paid, reason: '4100 >= 4500 - 450');
      expect(line.paidCents, 4100);
      expect(line.txIds, ['a', 'b']);
    });

    test('parts one cent short are not paid', () {
      final h = history(quarterly, [bankTx('2026-03-05', 3000, id: 'a'), bankTx('2026-03-10', 1049, id: 'b')]);
      final line = h.singleWhere((m) => m.payments.isNotEmpty);
      expect(line.state, isNot(BillMonthState.paid));
      expect(line.paidCents, 4049);
    });

    test('never matched by amount alone: another payee\'s row with the same amount is no payment', () {
      final h = history(quarterly, [bankTx('2026-03-12', 4500, desc: 'Quorvant Shop')]);
      expect(h.where((m) => m.payments.isNotEmpty), isEmpty);
      expect(h.where((m) => m.state == BillMonthState.paid), isEmpty);
    });

    test('a yearly bill: one line per year', () {
      final yearly = bill('2026-09-01', 60000, interval: 365);
      final h = history(yearly, [bankTx('2025-09-03', 60000, id: 'y1')], months: 3);
      expect(h, hasLength(3));
      expect(h.where((m) => m.state == BillMonthState.paid).single.payments.single.id, 'y1');
    });

    test('monthly bills are unchanged: one line per calendar month', () {
      final h = billHistory(
          bill('2026-06-15', 4500), [bankTx('2026-05-14', 4500, id: 'm5'), bankTx('2026-04-15', 4500, id: 'm4')], const [],
          today: '2026-06-10', months: 4, currency: 'EUR');
      expect([for (final m in h) m.month], ['2026-06', '2026-05', '2026-04']);
      expect(h.firstWhere((m) => m.month == '2026-05').state, BillMonthState.paid);
    });
  });
}
