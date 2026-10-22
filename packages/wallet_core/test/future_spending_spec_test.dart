// Spec tests for "future spending" (DESIGN_DECISIONS §4.3, API: docs/context/FUTURE_SPENDING_API.md), written from the
// spec only. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

var _seq = 0;

/// A categorized bank row (expense when [cents] is negative) for the pure functions.
CategorizedTx row(String date, int cents, String desc, {String category = 'Shopping', bool deleted = false, String? id}) {
  final tx = Tx(
    id: id ?? 'syn-${_seq++}',
    source: 'pbz',
    date: date,
    amount: cents,
    bankType: 'POS plaćanje',
    description: desc,
    deleted: deleted,
  );
  return CategorizedTx(tx, category, kindOf(category));
}

RecurringBill bill(String nextDue, int cents,
        {String status = 'confirmed', String payee = 'synthetic_gym', String category = 'Sport & fitness'}) =>
    RecurringBill(
      id: RecurringBill.idFor(payee),
      payee: payee,
      label: 'Synthetic Gym',
      category: category,
      expectedAmount: cents,
      nextDue: nextDue,
      status: status,
    );

/// A planned cost for the pure functions.
PlannedCost pc(String date, int? cents,
        {String title = 'Synthetic Dentist',
        String? category = 'Health',
        PlannedStatus status = PlannedStatus.open,
        PlannedSource source = PlannedSource.manual,
        String? sourceRef,
        String? paidTx}) =>
    PlannedCost(
      id: 'pl-${_seq++}',
      title: title,
      date: date,
      amount: cents,
      category: category,
      source: source,
      sourceRef: sourceRef,
      status: status,
      paidTx: paidTx,
    );

CalendarEvent ev(String date, String title, {String uid = 'u1', String cal = 'cal1', String? notes, bool allDay = true}) =>
    CalendarEvent(calendarId: cal, uid: uid, title: title, date: date, notes: notes, allDay: allDay);

void main() {
  const today = '2026-03-01'; // period 2026-02-15 .. payday 2026-03-15 (exclusive)
  final st = WalletSettings.fromMap({'salary': 200000, 'periodStart': '2026-02-15', 'paydayDay': 15});
  final txs = [row('2026-02-20', -3000, 'Synthetic Market', category: 'Groceries')];
  int reserved(List<PlannedCost> p) => computePeriod(txs, st, const [], today, planned: p).reservedPlanned;

  group('computePeriod reservation of planned costs', () {
    test('dated today, tomorrow and the day before payday are reserved', () {
      expect(reserved([pc('2026-03-01', 1000)]), 1000, reason: 'today');
      expect(reserved([pc('2026-03-02', 1000)]), 1000, reason: 'tomorrow');
      expect(reserved([pc('2026-03-14', 1000)]), 1000, reason: 'day before payday');
    });

    test('on payday, after it and yesterday: not reserved', () {
      expect(reserved([pc('2026-03-15', 1000)]), 0, reason: 'payday is the next period');
      expect(reserved([pc('2026-03-16', 1000)]), 0);
      expect(reserved([pc('2026-02-28', 1000)]), 0, reason: 'yesterday: its day has passed');
      expect(reserved([pc('2026-02-16', 1000)]), 0);
    });

    test('no amount, paid, skipped: not reserved', () {
      expect(reserved([pc('2026-03-05', null)]), 0);
      expect(reserved([pc('2026-03-05', 1000, status: PlannedStatus.paid, paidTx: 'x')]), 0);
      expect(reserved([pc('2026-03-05', 1000, status: PlannedStatus.skipped)]), 0);
    });

    test('a deleted planned cost reserves nothing, even when the closed list is passed in', () {
      final r = WalletRepo.inMemory();
      final id = r.addPlanned(title: 'Synthetic Dentist', date: '2026-03-05', amount: 4000);
      expect(reserved(r.plannedCosts()), 4000);
      r.deletePlanned(id);
      expect(reserved(r.plannedCosts()), 0);
      expect(reserved(r.plannedCosts(includeClosed: true)), 0);
      r.close();
    });

    test('markPaid and skip through the repo stop the reservation', () {
      final r = WalletRepo.inMemory();
      final a = r.addPlanned(title: 'A', date: '2026-03-05', amount: 4000);
      final b = r.addPlanned(title: 'B', date: '2026-03-06', amount: 2500);
      expect(reserved(r.plannedCosts()), 6500);
      r.markPlannedPaid(a, 'tx-1');
      expect(reserved(r.plannedCosts()), 2500);
      r.skipPlanned(b);
      expect(reserved(r.plannedCosts()), 0);
      r.close();
    });

    test('duePlanned lists exactly the reserved rows', () {
      final inside = pc('2026-03-05', 1000, title: 'In');
      final p = computePeriod(txs, st, const [], today,
          planned: [inside, pc('2026-03-15', 1000), pc('2026-02-28', 1000), pc('2026-03-05', null)]);
      expect([for (final d in p.duePlanned) d.id], [inside.id]);
    });

    test('planned and confirmed bills together are the sum, never double', () {
      final p = computePeriod(txs, st, const [], today,
          bills: [bill('2026-03-05', 5000)], planned: [pc('2026-03-06', 3000), pc('2026-03-07', 1250)]);
      expect(p.reservedBills, 5000);
      expect(p.reservedPlanned, 4250);
      expect(p.flexBudget, 200000 - 5000 - 4250);
    });

    test('a bill in a fixed category is not reserved a second time, planned still is', () {
      final p = computePeriod(txs, st, const [], today,
          bills: [bill('2026-03-05', 5000, category: 'Rent')], planned: [pc('2026-03-06', 3000)]);
      expect(p.reservedBills, 0, reason: 'already in the fixed plan');
      expect(p.reservedPlanned, 3000);
    });

    test('with planned empty every number equals the result without the argument', () {
      List<Object?> all(PeriodBudget p) => [
            p.start,
            p.end,
            p.length,
            p.daysLeft,
            p.received,
            p.extras,
            p.income,
            p.goalMonthly,
            p.fixedPlan,
            p.flexBudget,
            p.spent,
            p.spentToday,
            p.remaining,
            p.allowanceToday,
            p.safeToday,
            p.planDaily,
            p.elapsed,
            p.reservedBills,
          ];
      final bills = [bill('2026-03-05', 5000)];
      final base = computePeriod(txs, st, const [], today, bills: bills);
      final withEmpty = computePeriod(txs, st, const [], today, bills: bills, planned: const []);
      expect(all(withEmpty), all(base));
      expect(withEmpty.reservedPlanned, 0);
      expect(withEmpty.duePlanned, isEmpty);
      expect(all(computePeriod(txs, st, const [], today, planned: const [])), all(computePeriod(txs, st, const [], today)));
    });

    test('safe to spend: a planned cost lowers the daily amount by cost / days left (spec example shape)', () {
      final base = computePeriod(txs, st, const [], today);
      final days = base.daysLeft;
      // 4 EUR a day over the days left, whole cents so the division is exact (spec: 92 EUR turns 14 EUR/day into 10 EUR/day).
      final p = computePeriod(txs, st, const [], today, planned: [pc('2026-03-10', 400 * days)]);
      expect(p.reservedPlanned, 400 * days);
      expect(base.safeToday - p.safeToday, 400);
      expect(base.flexBudget - p.flexBudget, 400 * days);
    });

    test('a cost larger than the flexible money makes the flexible budget negative, not clamped away', () {
      final p = computePeriod(txs, st, const [], today, planned: [pc('2026-03-05', 900000)]);
      expect(p.flexBudget, lessThan(0));
    });
  });

  group('planned repo and sync', () {
    late WalletRepo a, b;
    setUp(() {
      a = WalletRepo.inMemory();
      b = WalletRepo.inMemory();
    });
    tearDown(() {
      a.close();
      b.close();
    });
    void send(WalletRepo from, WalletRepo to) => to.applyRemote([for (final o in from.pendingOps()) o.$2]);

    test('addPlanned returns an id and stores the fields; open by default', () {
      final id = a.addPlanned(title: 'Synthetic Dentist', date: '2026-03-10', amount: 8000, category: 'Health');
      final p = a.plannedCosts().single;
      expect((p.id, p.title, p.date, p.amount, p.category), (id, 'Synthetic Dentist', '2026-03-10', 8000, 'Health'));
      expect((p.source, p.status, p.paidTx), (PlannedSource.manual, PlannedStatus.open, null));
    });

    test('add, update, markPaid, skip and delete reach the other device as ops', () {
      final id = a.addPlanned(title: 'Gift', date: '2026-03-10', amount: 3000);
      final id2 = a.addPlanned(title: 'Trip', date: '2026-03-12', amount: 9000);
      final id3 = a.addPlanned(title: 'Old', date: '2026-03-13', amount: 100);
      send(a, b);
      expect(b.plannedCosts(), hasLength(3));
      a.updatePlanned(id, title: 'Gift 2', date: '2026-03-11', amount: 3500, category: 'Shopping');
      a.markPlannedPaid(id2, 'tx-9');
      a.deletePlanned(id3);
      send(a, b);
      final open = b.plannedCosts();
      expect([for (final p in open) p.id], [id]);
      expect((open.single.title, open.single.date, open.single.amount, open.single.category), ('Gift 2', '2026-03-11', 3500, 'Shopping'));
      final all = {for (final p in b.plannedCosts(includeClosed: true)) p.id: p};
      expect(all[id2]!.status, PlannedStatus.paid);
      expect(all[id2]!.paidTx, 'tx-9');
      expect(all.containsKey(id3), isTrue, reason: 'deleted rows are closed: listed with includeClosed');
      a.skipPlanned(id);
      send(a, b);
      expect(b.plannedCosts(), isEmpty);
      expect(b.plannedCosts(includeClosed: true).firstWhere((p) => p.id == id).status, PlannedStatus.skipped);
    });

    test('ops delivered in reverse order give the same result', () {
      final id = a.addPlanned(title: 'Gift', date: '2026-03-10', amount: 3000);
      a.updatePlanned(id, amount: 4000);
      a.updatePlanned(id, amount: 5000);
      b.applyRemote([for (final o in a.pendingOps().reversed) o.$2]);
      expect(b.plannedCosts().single.amount, 5000);
    });

    test('applying the same ops twice changes nothing', () {
      a.addPlanned(title: 'Gift', date: '2026-03-10', amount: 3000);
      send(a, b);
      send(a, b);
      expect(b.plannedCosts(), hasLength(1));
    });

    test('a null amount is kept null (no confirmed amount)', () {
      a.addPlanned(title: 'Concert', date: '2026-03-10');
      send(a, b);
      expect(b.plannedCosts().single.amount, isNull);
    });

    test('dismissCalendarEvent stores no title and hides the event on another device', () {
      final e = ev('2026-03-10', 'Secret Meeting Name');
      a.dismissCalendarEvent(e.ref, e.date);
      for (final o in a.pendingOps()) {
        expect(o.$2.fields.toString().contains('Secret'), isFalse, reason: 'no title in the op');
      }
      final r = a.plannedCosts(includeClosed: true).single;
      expect((r.title, r.source, r.sourceRef, r.status), ('', PlannedSource.calendar, e.ref, PlannedStatus.skipped));
      expect(a.plannedCosts(), isEmpty, reason: 'closed rows are not in the default list');
      send(a, b);
      final items = upcoming(planned: b.plannedCosts(includeClosed: true), bills: const [], events: [e], from: '2026-03-01', to: '2026-03-31');
      expect(items, isEmpty);
    });
  });

  group('upcoming', () {
    const from = '2026-03-01', to = '2026-05-31';

    test('merges planned, bill occurrences and events, sorted by date then title', () {
      final planned = [
        pc('2026-03-20', 5000, title: 'Zeta'),
        pc('2026-03-20', 100, title: 'Alpha'),
        pc('2026-03-02', 700, title: 'Early'),
      ];
      final items = upcoming(
          planned: planned, bills: [bill('2026-03-10', 2999)], events: [ev('2026-03-15', 'Concert')], from: from, to: '2026-03-31');
      expect([for (final i in items) i.date], ['2026-03-02', '2026-03-10', '2026-03-15', '2026-03-20', '2026-03-20']);
      expect([for (final i in items) i.kind],
          [UpcomingKind.planned, UpcomingKind.bill, UpcomingKind.suggestion, UpcomingKind.planned, UpcomingKind.planned]);
      expect([for (final i in items.skip(3)) i.title], ['Alpha', 'Zeta']);
      expect(items[3].key.startsWith('p:'), isTrue);
      expect(items[1].key.startsWith('b:'), isTrue);
      expect(items[2].key, 'e:${ev('2026-03-15', 'Concert').ref}');
      expect(items[1].amount, 2999, reason: 'confirmed bill counts its expected amount');
      expect(items[2].amount, isNull, reason: 'a suggestion is not counted');
    });

    test('a bill repeats by its interval inside the range', () {
      final items = upcoming(planned: const [], bills: [bill('2026-03-05', 2999)], events: const [], from: from, to: to);
      expect([for (final i in items) i.date], ['2026-03-05', '2026-04-04', '2026-05-04']);
    });

    test('a candidate or dismissed bill is not listed', () {
      final items = upcoming(
          planned: const [],
          bills: [bill('2026-03-05', 2999, status: 'candidate'), bill('2026-03-06', 2999, status: 'dismissed', payee: 'other')],
          events: const [],
          from: from,
          to: to);
      expect(items, isEmpty);
    });

    test('[from, to] are both inclusive', () {
      final planned = [
        pc('2026-02-28', 1, title: 'before'),
        pc('2026-03-01', 1, title: 'first'),
        pc('2026-03-31', 1, title: 'last'),
        pc('2026-04-01', 1, title: 'after'),
      ];
      final items = upcoming(
          planned: planned,
          bills: const [],
          events: [ev('2026-03-31', 'EdgeEvent'), ev('2026-04-01', 'OutEvent', uid: 'u2')],
          from: from,
          to: '2026-03-31');
      expect({for (final i in items) i.title}, {'first', 'last', 'EdgeEvent'});
    });

    test('paid and skipped planned costs are not listed', () {
      final items = upcoming(
          planned: [
            pc('2026-03-05', 1000, status: PlannedStatus.paid),
            pc('2026-03-05', 1000, status: PlannedStatus.skipped),
            pc('2026-03-05', 1000, title: 'Open'),
          ],
          bills: const [],
          events: const [],
          from: from,
          to: to);
      expect([for (final i in items) i.title], ['Open']);
    });

    test('an event with a planned row (any status, matching ref) is not listed again', () {
      final e = ev('2026-03-10', 'Dentist 80 €');
      for (final s in PlannedStatus.values) {
        final p = pc('2026-03-10', s == PlannedStatus.open ? 8000 : null,
            title: 'Dentist', source: PlannedSource.calendar, sourceRef: e.ref, status: s);
        final items = upcoming(planned: [p], bills: const [], events: [e], from: from, to: to);
        expect(items.where((i) => i.kind == UpcomingKind.suggestion), isEmpty, reason: '$s');
      }
    });

    test('a planned row with another ref does not hide the event', () {
      final e = ev('2026-03-10', 'Dentist');
      final other = pc('2026-03-10', 8000, source: PlannedSource.calendar, sourceRef: ev('2026-03-17', 'Dentist').ref);
      final items = upcoming(planned: [other], bills: const [], events: [e], from: from, to: to);
      expect(items.where((i) => i.kind == UpcomingKind.suggestion), hasLength(1));
    });

    test('a suggestion takes its amount from the title, or from an earlier planned cost with the same normalized title', () {
      final items = upcoming(planned: const [], bills: const [], events: [ev('2026-03-10', 'Dentist 80 €')], from: from, to: to);
      expect((items.single.suggested, items.single.suggestedFrom), (8000, 'title'));

      final earlier = pc('2026-01-10', 6500, title: 'Dentist', status: PlannedStatus.paid);
      final i2 = upcoming(planned: [earlier], bills: const [], events: [ev('2026-03-10', 'dentist')], from: from, to: to);
      final s = i2.singleWhere((i) => i.kind == UpcomingKind.suggestion);
      expect((s.suggested, s.suggestedFrom), (6500, 'earlier'));
      expect(s.amount, isNull);
    });

    test('an earlier planned cost without an amount suggests nothing', () {
      final items = upcoming(
          planned: [pc('2026-01-10', null, title: 'Dentist')], bills: const [], events: [ev('2026-03-10', 'Dentist')], from: from, to: to);
      expect(items.single.suggested, isNull);
    });

    test('an event whose notes carry the amount is suggested from them', () {
      final items = upcoming(
          planned: const [], bills: const [], events: [ev('2026-03-10', 'Gift', notes: 'budget 45,00 €')], from: from, to: to);
      expect(items.single.suggested, 4500);
    });

    test('empty inputs, or from after to, give an empty list', () {
      expect(upcoming(planned: const [], bills: const [], events: const [], from: from, to: to), isEmpty);
      expect(upcoming(planned: [pc('2026-03-05', 1)], bills: const [], events: const [], from: '2026-04-01', to: '2026-03-01'), isEmpty);
    });
  });

  group('amountFromText', () {
    const cases = <String, int?>{
      '80 €': 8000,
      '€80': 8000,
      '80 EUR': 8000,
      '80,00 €': 8000,
      '1.250,00 €': 125000,
      '1,250.00 €': 125000,
      '80.5€': 8050,
      'Dentist 80 € today': 8000,
      'pay 80 € or 80,00 €': 8000, // the same amount twice is not ambiguous
      'between 50 € and 80 €': null,
      'Dentist': null,
      '': null,
      '2026': null,
      '0 €': null,
      '0,00 €': null,
      '-5 €': null,
    };
    for (final MapEntry(key: text, value: want) in cases.entries) {
      test("'$text' -> $want", () => expect(amountFromText(text), want));
    }

    test('a huge number never throws', () {
      expect(() => amountFromText('99999999999999999999999 €'), returnsNormally);
    });
  });

  group('normalizeTitle', () {
    test('folds accents and case, drops amounts and digits, single spaces', () {
      expect(normalizeTitle('Zubar ČĆŽ  80 €'), 'zubar ccz');
      expect(normalizeTitle('Dentist 2026'), 'dentist');
      expect(normalizeTitle('  Dentist   visit  '), 'dentist visit');
      expect(normalizeTitle('Dentist'), normalizeTitle('DENTIST 80,00 €'));
      expect(normalizeTitle('€80 Dentist'), 'dentist');
      expect(normalizeTitle('12345'), '');
    });
  });

  group('paidCandidates', () {
    final p = pc('2026-03-10', 8000, category: 'Health');
    List<String> ids(List<CategorizedTx> c) => [for (final x in c) x.tx.id];

    test('same category within +-3 days only, closest first', () {
      final d0 = row('2026-03-10', -8000, 'X', category: 'Health', id: 'd0');
      final dm1 = row('2026-03-09', -7000, 'X', category: 'Health', id: 'dm1');
      final dp3 = row('2026-03-13', -8000, 'X', category: 'Health', id: 'dp3');
      final dm3 = row('2026-03-07', -8000, 'X', category: 'Health', id: 'dm3');
      final dm4 = row('2026-03-06', -8000, 'X', category: 'Health', id: 'dm4');
      final dp4 = row('2026-03-14', -8000, 'X', category: 'Health', id: 'dp4');
      final c = paidCandidates(p, [dp4, dm4, dp3, dm3, dm1, d0], [p]);
      expect(ids(c).take(2), ['d0', 'dm1']);
      expect(ids(c).toSet(), {'d0', 'dm1', 'dp3', 'dm3'});
    });

    test('another category never, even with the same amount (exact money rule)', () {
      final c = paidCandidates(p, [row('2026-03-10', -8000, 'X', category: 'Groceries', id: 'g')], [p]);
      expect(c, isEmpty);
    });

    test('a transaction already paying another planned cost is excluded', () {
      final other = pc('2026-03-09', 8000, status: PlannedStatus.paid, paidTx: 'taken');
      final c = paidCandidates(
          p, [row('2026-03-10', -8000, 'X', category: 'Health', id: 'taken'), row('2026-03-11', -100, 'X', category: 'Health', id: 'free')], [p, other]);
      expect(ids(c), ['free']);
    });

    test('income, deleted rows and a planned cost without category give nothing wrong', () {
      expect(paidCandidates(p, [row('2026-03-10', 5000, 'X', category: 'Health')], [p]), isEmpty, reason: 'income');
      expect(paidCandidates(p, [row('2026-03-10', -5000, 'X', category: 'Health', deleted: true)], [p]), isEmpty, reason: 'deleted');
      final none = pc('2026-03-10', 8000, category: null);
      expect(paidCandidates(none, [row('2026-03-10', -8000, 'X', category: 'Health')], [none]), isEmpty);
    });

    test('equal distance: the amount closest to the planned amount comes first', () {
      final far = row('2026-03-11', -3000, 'X', category: 'Health', id: 'far');
      final near = row('2026-03-09', -7900, 'X', category: 'Health', id: 'near');
      expect(ids(paidCandidates(p, [far, near], [p])), ['near', 'far']);
    });
  });

  group('headsUps', () {
    final items = upcoming(
      planned: [
        pc('2026-03-04', 10000, title: 'AtThresholdInWindow'),
        pc('2026-03-04', 9999, title: 'BelowThreshold'),
        pc('2026-03-05', 50000, title: 'OutsideWindow'),
        pc('2026-03-04', null, title: 'NoAmount'),
        pc('2026-03-01', 20000, title: 'Today'),
        pc('2026-02-28', 20000, title: 'Past'),
      ],
      bills: [bill('2026-03-03', 15000)],
      events: [ev('2026-03-02', 'Suggested 500 €')],
      from: '2026-02-20',
      to: '2026-03-31',
    );

    test('threshold and window are inclusive; null amounts, suggestions and the past are ignored; bills included', () {
      final h = headsUps(items, '2026-03-01', thresholdCents: 10000, days: 3);
      expect({for (final x in h) x.item.title}, {'AtThresholdInWindow', 'Today', 'Synthetic Gym'});
      expect({for (final x in h) x.daysLeft}, {3, 0, 2});
    });

    test('days 0 means today only', () {
      final h = headsUps(items, '2026-03-01', thresholdCents: 10000, days: 0);
      expect([for (final x in h) x.item.title], ['Today']);
    });

    test('threshold 0 includes every counted item in the window', () {
      final h = headsUps(items, '2026-03-01', thresholdCents: 0, days: 3);
      expect({for (final x in h) x.item.title}, {'AtThresholdInWindow', 'BelowThreshold', 'Today', 'Synthetic Gym'});
    });
  });

  group('settings headsUpCents / headsUpDays', () {
    test('defaults are 100 EUR and 3 days; valid values are kept and survive toMap', () {
      const d = WalletSettings();
      expect((d.headsUpCents, d.headsUpDays), (10000, 3));
      final s = WalletSettings.fromMap({'headsUpCents': 25000, 'headsUpDays': 7});
      expect((s.headsUpCents, s.headsUpDays), (25000, 7));
      final r = WalletSettings.fromMap(s.toMap());
      expect((r.headsUpCents, r.headsUpDays), (25000, 7));
    });

    test('bounds are inclusive: 0..10000000 cents, 0..14 days', () {
      final lo = WalletSettings.fromMap({'headsUpCents': 0, 'headsUpDays': 0});
      expect((lo.headsUpCents, lo.headsUpDays), (0, 0));
      final hi = WalletSettings.fromMap({'headsUpCents': 10000000, 'headsUpDays': 14});
      expect((hi.headsUpCents, hi.headsUpDays), (10000000, 14));
    });

    test('invalid values fall back to the default, one setting at a time', () {
      for (final v in <Object?>[-1, 10000001, '100', 1.5, true]) {
        final s = WalletSettings.fromMap({'headsUpCents': v, 'headsUpDays': 5});
        expect((s.headsUpCents, s.headsUpDays), (10000, 5), reason: 'cents=$v');
      }
      for (final v in <Object?>[-1, 15, '3', 2.5, null]) {
        final s = WalletSettings.fromMap({'headsUpCents': 777, 'headsUpDays': v});
        expect((s.headsUpCents, s.headsUpDays), (777, 3), reason: 'days=$v');
      }
    });
  });
}
