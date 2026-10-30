// HP-T2: invariants for billHistory (monthly and per-cycle), pinned from mutation testing. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _payee = 'lumen_power';

RecurringBill _bill({int interval = 30, String due = '2026-06-15', String? direction, int amount = 4500, String? lastPaid}) =>
    RecurringBill(
        id: RecurringBill.idFor(_payee),
        payee: _payee,
        label: 'LUMEN POWER',
        category: 'Bills & subscriptions',
        expectedAmount: amount,
        intervalDays: interval,
        nextDue: due,
        status: 'confirmed',
        direction: direction,
        lastPaidTx: lastPaid);

Tx _pay(String id, String date, int cents,
        {String desc = 'LUMEN POWER',
        String currency = 'EUR',
        bool deleted = false,
        bool manual = false,
        String? transferTo,
        TxKind? kind,
        String? category}) =>
    Tx(
        id: id,
        source: manual ? 'manual' : 'pbz',
        date: date,
        amount: cents,
        currency: currency,
        description: desc,
        deleted: deleted,
        manual: manual,
        transferTo: transferTo,
        kindHint: kind,
        category: category,
        note: manual ? 'LUMEN POWER' : null);

Bill _slip(String id,
        {String? date,
        String? due,
        int? total,
        String? linked,
        String currency = 'EUR',
        bool deleted = false,
        String payee = 'Lumen Power'}) =>
    Bill(id: id, payee: payee, date: date, dueDate: due, total: total, linkedTx: linked, currency: currency, deleted: deleted);

List<BillMonth> _h(List<Tx> rows,
        {List<Bill> slips = const [], String today = '2026-06-10', int months = 12, RecurringBill? b, Set<String> iou = const {}}) =>
    billHistory(b ?? _bill(), rows, slips, today: today, months: months, currency: 'EUR', iouTx: iou);

void main() {
  group('arguments and window', () {
    test('months < 1 and a bad today are refused; months 1 shows only today\'s month', () {
      expect(() => _h([], months: 0), throwsArgumentError);
      expect(() => _h([], months: -1), throwsArgumentError);
      expect(() => _h([], today: '2026-6-10'), throwsArgumentError);
      expect(_h([], months: 1).map((m) => m.month), ['2026-06']);
      expect(_h([], months: 1).single.state, BillMonthState.upcoming);
    });

    test('empty months run from the oldest payment up to the window start; payments older than the window are not listed', () {
      expect(_h([_pay('a', '2026-04-05', -4500)]).map((m) => m.month), ['2026-06', '2026-05', '2026-04']);
      expect(_h([_pay('a', '2026-04-05', -4500)], months: 2).map((m) => m.month), ['2026-06', '2026-05']);
      expect(_h([_pay('a', '2026-04-05', -4500)], months: 3).map((m) => m.month), ['2026-06', '2026-05', '2026-04']);
      expect(_h([]).map((m) => m.month), ['2026-06'], reason: 'nothing held: today only');
    });

    test('the next two months show only when they hold something; three months ahead never', () {
      final h = _h([_pay('a', '2026-08-01', -4500), _pay('b', '2026-09-01', -4500)]);
      expect(h.map((m) => m.month), ['2026-08', '2026-07'.replaceAll('07', '06')]);
      expect(h.first.state, BillMonthState.paid);
      final h2 = _h([_pay('a', '2026-07-01', -4500)]);
      expect(h2.map((m) => m.month), ['2026-07', '2026-06']);
      // a year boundary
      expect(_h([_pay('a', '2027-01-05', -4500)], today: '2026-12-10').map((m) => m.month), ['2027-01', '2026-12']);
    });
  });

  group('states and sums', () {
    test('paid: sorted payments, exact cents; billed sums slip totals, null without a total', () {
      final h = _h([
        _pay('b', '2026-06-05', -2000),
        _pay('a', '2026-06-05', -1500),
        _pay('c', '2026-06-02', -1)
      ], slips: [
        _slip('s1', date: '2026-06-01', total: 1200),
        _slip('s2', date: '2026-06-01', total: 34),
        _slip('s3', date: '2026-06-01')
      ]);
      final m = h.single;
      expect(m.payments.map((t) => t.id), ['c', 'a', 'b']);
      expect(m.paid, 3501);
      expect(m.billed, 1234);
      expect(m.state, BillMonthState.paid);
      expect(m.slips.map((s) => s.id).toSet(), {'s1', 's2', 's3'});
      expect(m.txIds, ['c', 'a', 'b']);
      expect(_h([_pay('a', '2026-06-05', -1500)], slips: [_slip('s3', date: '2026-06-01')]).single.billed, isNull);
      expect(_h([_pay('a', '2026-06-05', -1500)]).single.billed, isNull);
    });

    test('slipOnly, upcoming, missing', () {
      final h = _h([_pay('a', '2026-04-05', -4500)], slips: [_slip('s', due: '2026-05-20', total: 4500)]);
      expect(h.map((m) => (m.month, m.state)), [
        ('2026-06', BillMonthState.upcoming),
        ('2026-05', BillMonthState.slipOnly),
        ('2026-04', BillMonthState.paid),
      ]);
      final miss = _h([_pay('a', '2026-04-05', -4500)]);
      expect(miss.map((m) => m.state), [BillMonthState.upcoming, BillMonthState.missing, BillMonthState.paid]);
      expect(miss[1].paid, 0);
      expect(miss[1].paidIn, isNull);
    });

    test('a slip goes to its linked payment\'s month, else its date, else its due date; a bad date is not listed', () {
      final rows = [_pay('p', '2026-05-30', -4500)];
      final h = _h(rows, slips: [
        _slip('linked', date: '2026-06-02', linked: 'p', total: 1),
        _slip('dated', date: '2026-06-02', total: 2),
        _slip('dueOnly', due: '2026-06-03', total: 4),
        _slip('badDate', date: '2026-13-45', due: '2026-04-04', total: 8),
        _slip('none', total: 16),
        _slip('bin', date: '2026-06-02', total: 32, deleted: true),
        _slip('usd', date: '2026-06-02', total: 64, currency: 'USD'),
        _slip('other', date: '2026-06-02', total: 128, payee: 'Other Co'),
      ]);
      expect(h.firstWhere((m) => m.month == '2026-05').slips.map((s) => s.id), ['linked']);
      expect(h.firstWhere((m) => m.month == '2026-06').slips.map((s) => s.id), ['dated', 'dueOnly']);
      expect(h.firstWhere((m) => m.month == '2026-06').billed, 6);
      expect(h.firstWhere((m) => m.month == '2026-04').slips.map((s) => s.id), ['badDate'],
          reason: 'a bad date counts as absent, the due date serves');
      // the same slip twice is listed once
      final dup = _h([], slips: [_slip('s', date: '2026-06-02', total: 5), _slip('s', date: '2026-06-02', total: 5)]);
      expect(dup.single.slips, hasLength(1));
    });

    test('paidNearby: an empty month next to a month with a second payment near its edge', () {
      final h = _h([_pay('a', '2026-05-02', -4500), _pay('b', '2026-05-30', -4500)], today: '2026-07-10');
      expect(h.map((m) => (m.month, m.state)), [
        ('2026-07', BillMonthState.upcoming),
        ('2026-06', BillMonthState.paidNearby),
        ('2026-05', BillMonthState.paid),
      ]);
      expect(h[1].paidIn, '2026-05');
      // two payments but neither near the empty month's edge: missing
      final far = _h([_pay('a', '2026-05-02', -4500), _pay('b', '2026-05-10', -4500)], today: '2026-07-10');
      expect(far[1].state, BillMonthState.missing);
      // one payment: nothing spare
      final one = _h([_pay('b', '2026-05-30', -4500)], today: '2026-07-10');
      expect(one[1].state, BillMonthState.missing);
      // the edge is 3 days: 06-04 is near May? only the day before the first of month counts: 05-29 is 3 days before 06-01
      expect(_h([_pay('a', '2026-05-02', -4500), _pay('b', '2026-05-29', -4500)], today: '2026-07-10')[1].state, BillMonthState.paidNearby);
      expect(_h([_pay('a', '2026-05-02', -4500), _pay('b', '2026-05-28', -4500)], today: '2026-07-10')[1].state, BillMonthState.missing);
      // after the empty month: payments at the start of the following month
      final after = _h([_pay('a', '2026-05-02', -4500), _pay('b', '2026-05-03', -4500)], today: '2026-07-10');
      expect(after.map((m) => m.state), [BillMonthState.upcoming, BillMonthState.missing, BillMonthState.paid]);
      final next =
          _h([_pay('a', '2026-04-10', -4500), _pay('b', '2026-06-02', -4500), _pay('c', '2026-06-20', -4500)], today: '2026-07-10');
      expect(next.firstWhere((m) => m.month == '2026-05').state, BillMonthState.paidNearby);
      expect(next.firstWhere((m) => m.month == '2026-05').paidIn, '2026-06');
      expect(next.firstWhere((m) => m.month == '2026-05').state, isNot(BillMonthState.missing));
    });

    test('each spare payment covers one empty month only', () {
      final h = _h([_pay('a', '2026-04-02', -4500), _pay('b', '2026-04-29', -4500), _pay('c', '2026-01-20', -4500)], today: '2026-07-10');
      final states = {for (final m in h) m.month: m.state};
      // empty months are served oldest first: March takes April's one spare payment, May and June find none
      expect(states['2026-03'], BillMonthState.paidNearby);
      expect(states['2026-05'], BillMonthState.missing);
      expect(states['2026-06'], BillMonthState.missing);
    });
  });

  group('more edges', () {
    test('today\'s month and held months never take a neighbour\'s spare payment', () {
      final cur = _h([_pay('a', '2026-05-02', -4500), _pay('b', '2026-05-30', -4500)]);
      expect(cur.first.month, '2026-06');
      expect(cur.first.state, BillMonthState.upcoming);
      expect(cur.first.paidIn, isNull);
      final held = _h([_pay('a', '2026-04-02', -4500), _pay('b', '2026-04-30', -4500), _pay('c', '2026-05-15', -4500)]);
      final may = held.firstWhere((m) => m.month == '2026-05');
      expect(may.state, BillMonthState.paid);
      expect(may.paidIn, isNull);
    });

    test('a month after the empty one covers it only within 3 days of its last day', () {
      MapEntry<String, BillMonthState> june(String second) {
        final h = _h([_pay('a', '2026-04-10', -4500), _pay('b', '2026-06-20', -4500), _pay('c', second, -4500)], today: '2026-07-10');
        final m = h.firstWhere((m) => m.month == '2026-05');
        return MapEntry(m.paidIn ?? '', m.state);
      }

      expect(june('2026-06-03').value, BillMonthState.paidNearby);
      expect(june('2026-06-03').key, '2026-06');
      expect(june('2026-06-04').value, BillMonthState.missing);
    });

    test('one neighbour with spare payments covers several empty months', () {
      final h = _h(
          [_pay('a', '2026-04-02', -4500), _pay('b', '2026-04-15', -4500), _pay('c', '2026-04-29', -4500), _pay('d', '2026-02-10', -4500)],
          today: '2026-07-10');
      final st = {for (final m in h) m.month: m.state};
      expect(st['2026-03'], BillMonthState.paidNearby);
      expect(st['2026-05'], BillMonthState.paidNearby);
      expect(st['2026-06'], BillMonthState.missing);
    });

    test('slips: deleted, attachment, other currency, other payee and repeats are ignored in a month and in a cycle', () {
      final slips = [
        _slip('ok1', date: '2026-06-09', total: 10),
        _slip('ok1', date: '2026-06-09', total: 10),
        _slip('ok2', date: '2026-06-09', total: 5),
        _slip('bin', date: '2026-06-09', total: 100, deleted: true),
        _slip('usd', date: '2026-06-09', total: 200, currency: 'USD'),
        _slip('other', date: '2026-06-09', total: 400, payee: 'Other Co'),
        const Bill(id: 'att', source: BillSource.attachment, payee: 'Lumen Power', date: '2026-06-09', total: 800),
        const Bill(id: 'nopayee', date: '2026-06-09', total: 1600),
      ];
      expect(_h([], slips: slips).single.slips.map((s) => s.id).toList()..sort(), ['ok1', 'ok2']);
      expect(_h([], slips: slips).single.billed, 15);
      final cyc = _h([], slips: slips, b: _bill(interval: 7), months: 3);
      final c = cyc.firstWhere((m) => m.due == '2026-06-08');
      expect(c.slips.map((s) => s.id).toList()..sort(), ['ok1', 'ok2']);
      expect(c.billed, 15);
    });

    test('cycle span: the last of `months` cycles is shown, the one after it is not', () {
      final b = _bill(interval: 7); // cycle k due 06-15 - 7k
      final h = _h([_pay('in', '2026-06-01', -1000), _pay('out', '2026-05-25', -1000)], b: b, months: 3);
      expect(h.map((m) => m.due), ['2026-06-15', '2026-06-08', '2026-06-01']);
      expect(h.last.payments.map((t) => t.id), ['in']);
      expect(h.expand((m) => m.payments).map((t) => t.id), ['in'], reason: 'k = 3 is outside the span');
    });

    test('an income ignores zero rows too', () {
      final inc = _bill(direction: RecurringBill.directionIn);
      expect(_h([_pay('z', '2026-06-02', 0)], b: inc).single.payments, isEmpty);
    });
  });

  group('what counts as a payment', () {
    test('only live bank outflows of the payee in the bill\'s currency, no transfers, never by amount', () {
      final rows = [
        _pay('ok', '2026-06-02', -100),
        _pay('income', '2026-06-02', 100),
        _pay('zero', '2026-06-02', 0),
        _pay('deleted', '2026-06-02', -100, deleted: true),
        _pay('manual', '2026-06-02', -100, manual: true),
        _pay('usd', '2026-06-02', -100, currency: 'USD'),
        _pay('paired', '2026-06-02', -100, transferTo: 'x'),
        _pay('own', '2026-06-02', -100, kind: TxKind.ownTransfer),
        _pay('fx', '2026-06-02', -100, kind: TxKind.exchange),
        _pay('card', '2026-06-02', -100, kind: TxKind.card),
        _pay('xfer', '2026-06-02', -100, category: 'Internal transfer'),
        _pay('badDate', '2026-06-31', -100),
        _pay('other', '2026-06-02', -4500, desc: 'SOMEWHERE ELSE'),
      ];
      final m = _h(rows).single;
      expect(m.payments.map((t) => t.id), ['card', 'ok']);
      expect(m.paid, 200);
    });

    test('the lastPaidTx row counts under the same conditions, whatever its text; IOU payments never', () {
      final other = _pay('lp', '2026-06-02', -4500, desc: 'SOMEWHERE ELSE');
      expect(_h([other], b: _bill(lastPaid: 'lp')).single.payments.map((t) => t.id), ['lp']);
      expect(_h([_pay('lp', '2026-06-02', 4500, desc: 'SOMEWHERE ELSE')], b: _bill(lastPaid: 'lp')).single.payments, isEmpty);
      expect(_h([_pay('a', '2026-06-02', -100), _pay('b', '2026-06-03', -200)], iou: {'a'}).single.payments.map((t) => t.id), ['b']);
    });

    test('an income counts inflows, as positive cents', () {
      final inc = _bill(direction: RecurringBill.directionIn);
      final m = _h([_pay('in', '2026-06-02', 7000), _pay('out', '2026-06-02', -7000)], b: inc).single;
      expect(m.payments.map((t) => t.id), ['in']);
      expect(m.paid, 7000);
    });
  });

  group('cycle history (not monthly)', () {
    // weekly: nextDue 06-15, so cycle k is due 06-15 - 7k
    RecurringBill weekly({int amount = 1000}) => _bill(interval: 7, amount: amount);

    test('always `months` cycles, newest first, with due dates; k = -1.. only when held', () {
      final h = _h([], b: weekly(), months: 4);
      expect(h.map((m) => m.due), ['2026-06-15', '2026-06-08', '2026-06-01', '2026-05-25']);
      expect(h.map((m) => m.month), ['2026-06', '2026-06', '2026-06', '2026-05']);
      expect(h.first.state, BillMonthState.upcoming);
      expect(h.skip(1).every((m) => m.state == BillMonthState.missing), isTrue);
      final ahead =
          _h([_pay('a', '2026-06-22', -1000), _pay('b', '2026-06-29', -1000), _pay('c', '2026-07-06', -1000)], b: weekly(), months: 2);
      expect(ahead.map((m) => m.due), ['2026-06-29', '2026-06-22', '2026-06-15', '2026-06-08'], reason: 'k = -3 is not shown');
    });

    test('a payment goes to the nearest cycle; beyond the span it is left out', () {
      final h = _h([_pay('a', '2026-06-09', -1000), _pay('far', '2026-01-01', -1000)], b: weekly(), months: 3);
      expect(h.map((m) => (m.due, m.payments.length)), [('2026-06-15', 0), ('2026-06-08', 1), ('2026-06-01', 0)]);
      // 3 days from cycle 06-08 on 06-11 is 3 away from 06-08 and 4 from 06-15: k rounds to 1
      expect(_h([_pay('a', '2026-06-11', -1000)], b: weekly(), months: 3).map((m) => m.payments.length), [0, 1, 0]);
    });

    test('state: a past cycle with one payment is paid; the open one needs the threshold; parts add up', () {
      final b = weekly(amount: 1000); // threshold 900
      var h = _h([_pay('a', '2026-06-15', -1000)], b: b, months: 2);
      expect(h[0].state, BillMonthState.paid);
      h = _h([_pay('a', '2026-06-15', -899)], b: b, months: 2);
      expect(h[0].state, BillMonthState.upcoming, reason: 'below the threshold, open cycle');
      expect(h[0].paidCents, 899);
      h = _h([_pay('a', '2026-06-15', -900)], b: b, months: 2);
      expect(h[0].state, BillMonthState.paid, reason: 'at the threshold');
      h = _h([_pay('a', '2026-06-15', -500), _pay('b', '2026-06-16', -400)], b: b, months: 2);
      expect(h[0].state, BillMonthState.paid);
      expect(h[0].paid, 900);
      // a past cycle: a single small payment still counts as paid, nothing is missing
      h = _h([_pay('a', '2026-06-08', -1)], b: b, months: 3);
      expect(h[1].state, BillMonthState.paid);
      // two small parts in a past cycle that never add up
      h = _h([_pay('a', '2026-06-08', -1), _pay('b', '2026-06-09', -1)], b: b, months: 3);
      expect(h[1].state, BillMonthState.missing);
      // slip only
      h = _h([], b: b, months: 3, slips: [_slip('s', date: '2026-06-08', total: 1000)]);
      expect(h[1].state, BillMonthState.slipOnly);
      expect(h[1].billed, 1000);
      // payment present but not enough, with a slip: not slipOnly
      h = _h([_pay('a', '2026-06-15', -1)], b: b, months: 2, slips: [_slip('s', date: '2026-06-15', total: 1000)]);
      expect(h[0].state, BillMonthState.upcoming);
    });

    test('a bill with a bad nextDue falls back to the monthly view', () {
      final h =
          billHistory(_bill(interval: 7, due: 'bad'), [_pay('a', '2026-06-09', -1000)], const [], today: '2026-06-10', currency: 'EUR');
      expect(h.single.month, '2026-06');
      expect(h.single.due, isNull);
    });

    test('a range bill uses its minimum as the threshold', () {
      const b = RecurringBill(
          id: 'r',
          payee: _payee,
          label: 'L',
          category: 'Bills & subscriptions',
          expectedAmount: 1000,
          intervalDays: 7,
          nextDue: '2026-06-15',
          status: 'confirmed',
          minAmount: 600,
          maxAmount: 1200);
      expect(_h([_pay('a', '2026-06-15', -600)], b: b, months: 2)[0].state, BillMonthState.paid);
      expect(_h([_pay('a', '2026-06-15', -599)], b: b, months: 2)[0].state, BillMonthState.upcoming);
    });
  });
}
