// P4 recurring bills beyond monthly, builder's tests (docs/context/P4_SPEC.md + lead clarifications).
// All data is SYNTHETIC: made-up payees (zorblex, quorvant) and amounts.
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/src/planned.dart' show billOccurrences;
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';

var _seq = 0;

Tx bank(String date, int cents, {String desc = 'Zorblex Utility', String? id}) => Tx(
      id: id ?? 'p4b-${_seq++}',
      source: 'pbz',
      date: date,
      amount: -cents,
      bankType: 'Trajni nalog',
      description: desc,
    );

CategorizedTx cat(Tx t, [String category = 'Shopping']) => CategorizedTx(t, category, kindOf(category));

final zorblex = merchantKey(bank('2026-01-01', 1));

RecurringBill bill(String nextDue, int cents,
        {int interval = 30, String category = 'Shopping', String? lastPaid, int? min, int? max, String? endsOn, String? payee}) =>
    RecurringBill(
      id: 'rec:${payee ?? zorblex}',
      payee: payee ?? zorblex,
      label: 'Zorblex',
      category: category,
      expectedAmount: cents,
      intervalDays: interval,
      nextDue: nextDue,
      status: 'confirmed',
      lastPaidTx: lastPaid,
      minAmount: min,
      maxAmount: max,
      endsOn: endsOn,
    );

void main() {
  group('model', () {
    test('RecurringPeriod.of: nearest class within its tolerance, else null', () {
      expect([
        for (final d in [6, 7, 8, 12, 14, 16, 27, 30, 33, 84, 91, 98, 355, 365, 375]) RecurringPeriod.of(d)
      ], [
        RecurringPeriod.weekly,
        RecurringPeriod.weekly,
        RecurringPeriod.weekly,
        RecurringPeriod.biweekly,
        RecurringPeriod.biweekly,
        RecurringPeriod.biweekly,
        RecurringPeriod.monthly,
        RecurringPeriod.monthly,
        RecurringPeriod.monthly,
        RecurringPeriod.quarterly,
        RecurringPeriod.quarterly,
        RecurringPeriod.quarterly,
        RecurringPeriod.yearly,
        RecurringPeriod.yearly,
        RecurringPeriod.yearly,
      ]);
      expect([
        for (final d in [5, 9, 11, 17, 26, 34, 60, 83, 99, 200, 354, 376]) RecurringPeriod.of(d)
      ], everyElement(isNull));
    });

    test('tolerance, isShort, isLong by interval', () {
      expect([
        for (final d in [1, 7, 8, 14, 15, 31, 32, 92, 93, 365]) RecurringBill.toleranceFor(d)
      ], [
        1,
        1,
        2,
        2,
        3,
        3,
        7,
        7,
        10,
        10
      ]);
      expect([
        for (final d in [7, 14, 26, 27, 30, 31, 32, 91])
          (bill('2026-03-01', 1, interval: d).isShort, bill('2026-03-01', 1, interval: d).isLong)
      ], [
        (true, false),
        (true, false),
        (true, false),
        (false, false),
        (false, false),
        (false, false),
        (false, true),
        (false, true),
      ]);
    });

    test('fromRow: a stored interval outside 1..400 reads as 30; an invalid range reads as none and logs once', () {
      Map<String, Object?> row(Object? interval, {Object? min, Object? max}) =>
          {'id': 'rec:x', 'expected_amount': 5000, 'interval_days': interval, 'min_amount': min, 'max_amount': max};
      expect([
        for (final i in [0, -7, 401, 'x', null, 1, 400]) RecurringBill.fromRow(row(i)).intervalDays
      ], [
        30,
        30,
        30,
        30,
        30,
        1,
        400
      ]);
      resetInvalidSettingLog();
      final sink = MemoryLogSink();
      final sub = Logger.root.onRecord.listen((r) => sink.add(formatLogRecord(r)));
      Logger.root.level = Level.ALL;
      addTearDown(sub.cancel);
      for (final (lo, hi) in [(7000, 4000), (0, 4000), (4000, null), (null, 4000), (4000, WalletSettings.maxAmount + 1)]) {
        final b = RecurringBill.fromRow(row(30, min: lo, max: hi));
        expect((b.hasRange, b.reserveAmount), (false, 5000), reason: '$lo..$hi');
      }
      final good = RecurringBill.fromRow(row(30, min: 4000, max: 7000));
      expect((good.hasRange, good.reserveAmount), (true, 7000));
      final warnings = sink.lines.where((l) => l.contains('recurring.invalid')).toList();
      expect(warnings, hasLength(1));
      expect(warnings.single, endsWith('{"field":"amount_range"}'));
    });

    test('instalmentsLeft and finished', () {
      expect(bill('2026-03-01', 100).instalmentsLeft, isNull);
      expect(bill('2026-03-01', 100, endsOn: '2026-11-26').instalmentsLeft, 10); // 03-01 + 9 × 30
      expect(bill('2026-03-01', 100, endsOn: '2026-12-25').instalmentsLeft, 10);
      expect(bill('2026-12-26', 100, endsOn: '2026-12-26').instalmentsLeft, 1);
      final done = bill('2027-01-25', 100, endsOn: '2026-12-26');
      expect((done.instalmentsLeft, done.finished, instalmentsLeft(done)), (0, true, 0));
    });
  });

  group('detection', () {
    List<CategorizedTx> series(String first, List<int> gaps, {int cents = 1500}) {
      var d = first;
      return [
        cat(bank(d, cents)),
        for (final g in gaps) cat(bank(d = addDays(d, g), cents)),
      ];
    }

    test('weekly: interval 7, next due last + 7', () {
      final b = detectRecurring(series('2026-02-08', [7, 8, 6]), today: '2026-03-01', currency: 'EUR').single;
      expect((b.intervalDays, b.nextDue, b.id), (7, '2026-03-08', 'rec:$zorblex'));
    });

    test('a weekly payee seen for longer still reads weekly (only the last 8 weeks count)', () {
      final gaps = List.filled(20, 7);
      final b = detectRecurring(series('2025-10-12', gaps), today: '2026-03-01', currency: 'EUR').single;
      expect(b.intervalDays, 7);
    });

    test('a monthly payee is never read as quarterly or yearly', () {
      final b = detectRecurring(series('2025-12-10', [30, 30]), today: '2026-03-01', currency: 'EUR').single;
      expect(b.intervalDays, 30);
    });
  });

  group('payments and parts', () {
    final b = bill('2026-03-10', 10000);

    test('partsDays and the threshold', () {
      expect([
        for (final d in [7, 14, 30, 91, 365]) partsDays(bill('2026-03-10', 1, interval: d))
      ], [
        5,
        11,
        14,
        14,
        14
      ]);
      expect(partsThreshold(b), 9000);
      expect(partsThreshold(bill('2026-03-10', 5000, min: 4000, max: 7000)), 4000);
    });

    test('one row alone never pays in parts: a full payment 4 days early counts as a part only', () {
      final p = planRecurringPayments([b], [bank('2026-03-06', 10000, id: 'x')], currency: 'EUR');
      expect(p.isEmpty, isTrue);
      expect(p.parts[b.id]?.map((t) => t.id), ['x']);
      expect(p.partsPaid(b.id), 10000);
    });

    test('a row over the reserve amount is no part; the second part completes the cycle', () {
      final p = planRecurringPayments([b], [bank('2026-02-28', 10001), bank('2026-03-01', 5000), bank('2026-03-05', 4000, id: 'c')],
          currency: 'EUR');
      expect(p.paidBy[b.id]?.id, 'c');
      expect(p.paidInParts, {b.id});
      expect(p.parts, isEmpty);
    });

    test('a bill without payee, a finished one, or one not confirmed never matches', () {
      final rows = [bank('2026-03-10', 10000)];
      const none = RecurringBill(
          id: 'rec:m0', payee: '', label: 'x', category: 'Shopping', expectedAmount: 10000, nextDue: '2026-03-10', status: 'confirmed');
      const blank = Tx(id: 'e', source: 'pbz', date: '2026-03-10', amount: -10000, description: '');
      expect(planRecurringPayments([none], [...rows, blank], currency: 'EUR').isEmpty, isTrue);
      expect(planRecurringPayments([bill('2026-03-10', 10000, endsOn: '2026-03-01')], rows, currency: 'EUR').isEmpty, isTrue);
      final candidate =
          RecurringBill(id: 'rec:$zorblex', payee: zorblex, label: 'x', category: 'Shopping', expectedAmount: 10000, nextDue: '2026-03-10');
      expect(planRecurringPayments([candidate], rows, currency: 'EUR').isEmpty, isTrue);
    });
  });

  group('dueCycles', () {
    List<DueCycle> cycles(List<RecurringBill> bills, {List<Tx> rows = const [], String start = '2026-02-15', String end = '2026-03-15'}) =>
        dueCycles(bills, [for (final t in rows) cat(t)], start, end, currency: 'EUR');

    test('a monthly bill has one cycle in a 31-day period, even when nextDue + 30 is before payday', () {
      final c = cycles([bill('2026-01-10', 5000)], start: '2026-01-10', end: '2026-02-10');
      expect([for (final x in c) x.due], ['2026-01-10']);
    });

    test('a short bill: overdue nextDue counts once, later occurrences only from the period start', () {
      final c = cycles([bill('2026-01-20', 1000, interval: 7)]);
      expect([for (final x in c) x.due], ['2026-01-20', '2026-02-17', '2026-02-24', '2026-03-03', '2026-03-10']);
    });

    test('a short bill paid in this period keeps its next cycles; an instalment plan stops at endsOn', () {
      final paid = bank('2026-02-16', 1000, id: 'p');
      final c = cycles([bill('2026-02-23', 1000, interval: 7, lastPaid: 'p', endsOn: '2026-03-02')], rows: [paid]);
      expect([for (final x in c) (x.due, x.reserve)], [('2026-02-23', 1000), ('2026-03-02', 1000)]);
    });

    test('a long bill whose paying row is here but not yet recorded reserves 0; one paid this period is held again', () {
      final yearly = bill('2026-03-01', 60000, interval: 365);
      final c = cycles([yearly], rows: [bank('2026-03-02', 60000)]).single;
      expect((c.reserve, c.paid), (0, 60000));
      final next = bill('2027-03-02', 60000, interval: 365, lastPaid: 'y');
      expect(cycles([next], rows: [bank('2026-03-02', 60000, id: 'y')]).single.reserve, 60000);
    });

    test('computePeriod: a long bill in a fixed category is reserved, a monthly one there is not', () {
      final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
      final p = computePeriod(const [], st, const [], '2026-03-01',
          bills: [
            bill('2026-12-01', 60000, interval: 365, category: 'Bills & subscriptions'),
            bill('2026-03-05', 5000, category: 'Bills & subscriptions', payee: 'quorvant'),
          ],
          table: CategoryTable.builtIn);
      expect(p.reservedBills, 60000);
      expect(p.dueCycles, hasLength(2));
      expect([for (final b in p.dueBills) b.payee], ['quorvant', zorblex]);
    });
  });

  group('upcoming and history', () {
    test('billOccurrences stop after endsOn; upcoming shows the reserve amount', () {
      final b = bill('2026-03-01', 5000, interval: 7, endsOn: '2026-03-15', min: 4000, max: 6000);
      expect(billOccurrences(b, '2026-03-01', '2026-04-30'), ['2026-03-01', '2026-03-08', '2026-03-15']);
      final up = upcoming(planned: const [], bills: [b], events: const [], from: '2026-03-01', to: '2026-04-30');
      expect([for (final i in up) i.amount], [6000, 6000, 6000]);
    });

    test('a weekly bill: one line per cycle with its due date; parts of the open cycle show as upcoming', () {
      final b = bill('2026-03-08', 2000, interval: 7);
      final rows = [bank('2026-03-01', 2000, id: 'w1'), bank('2026-03-05', 800, id: 'p1'), bank('2026-03-06', 700, id: 'p2')];
      final h = billHistory(b, rows, const [], today: '2026-03-06', months: 3, currency: 'EUR');
      expect([
        for (final m in h) (m.due, m.state, m.txIds.join(','))
      ], [
        ('2026-03-08', BillMonthState.upcoming, 'p1,p2'),
        ('2026-03-01', BillMonthState.paid, 'w1'),
        ('2026-02-22', BillMonthState.missing, ''),
      ]);
      expect(h.first.paidCents, 1500);
    });
  });

  group('repo', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory(now: () => DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch));
    tearDown(() => r.close());

    NormalizedTransaction nt(String date, int cents, {String desc = 'Zorblex Utility'}) => NormalizedTransaction(
        id: transactionId(date, -cents, desc, 0),
        source: 'pbz',
        date: date,
        amountMinor: -cents,
        currency: 'EUR',
        bankType: 'Trajni nalog',
        description: desc);

    test('a manual bill keeps its category; its payee is never detected; parts move nextDue by the interval', () {
      final id =
          r.addRecurring(label: 'Zorblex', category: 'Groceries', amount: 10000, intervalDays: 30, firstDue: '2026-03-10', payee: zorblex);
      expect(id, matches(RegExp(r'^rec:m[0-9a-f]{12}$')));
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        nt('2025-12-10', 10000),
        nt('2026-01-09', 10000),
        nt('2026-02-08', 10000),
        nt('2026-03-01', 6000),
        nt('2026-03-04', 4000),
      ]));
      r.refreshRecurring('2026-03-05');
      final bills = r.recurringBills(includeDismissed: true);
      expect(bills, hasLength(1), reason: 'no rec:<payee> candidate next to the manual bill');
      final b = bills.single;
      expect((b.category, b.nextDue, b.manual, b.status), ('Groceries', '2026-04-09', true, 'confirmed'));
      expect(r.transaction(b.lastPaidTx!)!.date, '2026-03-04');
    });

    test('addRecurring refuses a payee a live bill uses; a dismissed one frees it', () {
      r.addRecurring(label: 'A', category: 'Shopping', amount: 100, intervalDays: 7, firstDue: '2026-03-02', payee: 'quorvant');
      expect(
          () => r.addRecurring(label: 'B', category: 'Shopping', amount: 100, intervalDays: 7, firstDue: '2026-03-02', payee: 'quorvant'),
          throwsArgumentError);
      final id = r.recurringBills().single.id;
      r.dismissRecurring(id);
      expect(r.addRecurring(label: 'B', category: 'Shopping', amount: 100, intervalDays: 7, firstDue: '2026-03-02', payee: 'quorvant'),
          isNot(id));
    });

    test('updateRecurring: range must hold the amount after the edit; clearRange; nothing written when unchanged', () {
      final id = r.addRecurring(
          label: 'A', category: 'Shopping', amount: 5000, minAmount: 4000, maxAmount: 7000, intervalDays: 91, firstDue: '2026-06-01');
      expect(() => r.updateRecurring(id, amount: 8000), throwsArgumentError);
      expect(() => r.updateRecurring(id, minAmount: 6000), throwsArgumentError);
      expect(() => r.updateRecurring(id, intervalDays: 0), throwsArgumentError);
      expect(() => r.updateRecurring(id, category: 'kdeadbeef0000'), throwsArgumentError);
      expect(() => r.updateRecurring('rec:nope', label: 'x'), throwsArgumentError);
      final before = r.pendingOps().length;
      r.updateRecurring(id, label: ' A ', amount: 5000);
      expect(r.pendingOps().length, before);
      r.updateRecurring(id, amount: 8000, clearRange: true);
      final b = r.recurringBills().single;
      expect((b.expectedAmount, b.minAmount, b.maxAmount, b.hasRange), (8000, null, null, false));
    });

    test('two devices: an edit on one and a payment refresh on the other merge field by field', () async {
      final tmp = Directory.systemTemp.createTempSync('bw-p4-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final key = VaultKey.generate();
      Net();
      var now = DateTime.utc(2026, 3, 1, 12).millisecondsSinceEpoch;
      Device device(String name) => Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now += 1000);
      final a = device('a'), b = device('b');
      final id = a.repo
          .addRecurring(label: 'Zorblex', category: 'Shopping', amount: 3000, intervalDays: 30, firstDue: '2026-03-10', payee: zorblex);
      await a.run();
      await b.run();
      a.repo.updateRecurring(id, label: 'Water');
      b.repo.importBatch(ImportBatch(source: 'pbz', transactions: [nt('2026-03-11', 3000)]));
      for (final d in [b, a, b]) {
        await d.run();
      }
      for (final d in [a, b]) {
        final x = d.repo.recurringBills().single;
        expect((x.label, x.nextDue, x.manual), ('Water', '2026-04-10', true), reason: d.name);
      }
      expect(dump(a.repo), dump(b.repo));
      a.close();
      b.close();
    });
  });
}
