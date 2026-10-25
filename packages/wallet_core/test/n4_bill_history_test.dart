// Stage N4, core half: billHistory (a confirmed recurring bill's payments and slips, one line per month).
// All data is SYNTHETIC: made-up payees and amounts.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const payee = 'lumen_power';
const today = '2026-06-10';

final bill = RecurringBill(
  id: RecurringBill.idFor(payee),
  payee: payee,
  label: 'LUMEN POWER',
  category: 'Bills & subscriptions',
  expectedAmount: 4500,
  nextDue: '2026-06-15',
  status: 'confirmed',
);

Tx pay(String id, String date, int cents,
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
      note: manual ? 'LUMEN POWER' : null,
    );

Bill slip(String id,
        {String payee = 'Lumen Power',
        String? date,
        String? due,
        int? total,
        String? linked,
        String currency = 'EUR',
        bool deleted = false}) =>
    Bill(id: id, payee: payee, date: date, dueDate: due, total: total, linkedTx: linked, currency: currency, deleted: deleted);

List<BillMonth> history(List<Tx> rows, List<Bill> slips, {int months = 12, RecurringBill? b}) =>
    billHistory(b ?? bill, rows, slips, today: today, months: months, currency: 'EUR');

BillMonth monthIn(List<BillMonth> h, String ym) => h.singleWhere((m) => m.month == ym);

void main() {
  test('payee keys line up: bank text and slip payee give the same key', () {
    expect(merchantKey(pay('t', '2026-01-01', -1)), payee);
    expect(billPayeeKey(slip('s')), payee);
  });

  test('a month with a payment and a slip is paid, with exact paid and billed', () {
    final h = history([pay('t5', '2026-05-14', -4567)], [slip('s5', date: '2026-05-02', total: 4567)]);
    final may = monthIn(h, '2026-05');
    expect(may.state, BillMonthState.paid);
    expect(may.payments.map((t) => t.id), ['t5']);
    expect(may.slips.map((s) => s.id), ['s5']);
    expect(may.paid, 4567);
    expect(may.billed, 4567);
  });

  test('a slip only is slipOnly; paid is 0 and billed its total', () {
    final h = history([], [slip('s4', date: '2026-04-03', total: 4321)]);
    final apr = monthIn(h, '2026-04');
    expect(apr.state, BillMonthState.slipOnly);
    expect(apr.payments, isEmpty);
    expect(apr.paid, 0);
    expect(apr.billed, 4321);
  });

  test('a payment only is paid with billed null; a slip without a total keeps billed null', () {
    final h = history([pay('t4', '2026-04-14', -4500), pay('t5', '2026-05-14', -4501)], [slip('s5', date: '2026-05-01')]);
    expect(monthIn(h, '2026-04').billed, isNull);
    expect(monthIn(h, '2026-04').state, BillMonthState.paid);
    expect(monthIn(h, '2026-05').slips.map((s) => s.id), ['s5']);
    expect(monthIn(h, '2026-05').billed, isNull);
  });

  test('a slip with no issue date uses its due date', () {
    final h = history([], [slip('s3', due: '2026-03-20', total: 100)]);
    expect(monthIn(h, '2026-03').slips.map((s) => s.id), ['s3']);
  });

  test('a missing month in the middle is listed as missing, with nothing guessed', () {
    final h = history([pay('t2', '2026-02-14', -4500), pay('t4', '2026-04-14', -4500)], []);
    expect(h.map((m) => m.month), ['2026-06', '2026-05', '2026-04', '2026-03', '2026-02']);
    final mar = monthIn(h, '2026-03');
    expect(mar.state, BillMonthState.missing);
    expect(mar.payments, isEmpty);
    expect(mar.slips, isEmpty);
    expect(mar.paid, 0);
    expect(mar.billed, isNull);
    expect(monthIn(h, '2026-05').state, BillMonthState.missing);
  });

  test('the current month without a payment is upcoming; with one it is paid', () {
    final h = history([pay('t5', '2026-05-14', -4500)], []);
    expect(h.first.month, '2026-06');
    expect(h.first.state, BillMonthState.upcoming);
    final paid = history([pay('t6', '2026-06-09', -4500)], []);
    expect(paid.first.state, BillMonthState.paid);
    expect(paid.first.paid, 4500);
  });

  test('no rows and no slips: only the current month, upcoming', () {
    final h = history([], []);
    expect(h.map((m) => m.month), ['2026-06']);
    expect(h.single.state, BillMonthState.upcoming);
  });

  test('a slip dated next month (due ahead) adds that month; the empty months up to it are upcoming', () {
    final h = history([pay('t5', '2026-05-14', -4500)], [slip('s8', date: '2026-08-01', total: 4500)]);
    expect(h.map((m) => m.month), ['2026-08', '2026-07', '2026-06', '2026-05']);
    expect(monthIn(h, '2026-08').state, BillMonthState.slipOnly);
    expect(monthIn(h, '2026-07').state, BillMonthState.upcoming);
  });

  test('a slip linked to a payment in another month is listed in the payment\'s month', () {
    final h = history([pay('t4', '2026-04-02', -4500)], [slip('s3', date: '2026-03-28', total: 4500, linked: 't4')]);
    expect(monthIn(h, '2026-04').slips.map((s) => s.id), ['s3']);
    expect(monthIn(h, '2026-04').billed, 4500);
    expect(h.where((m) => m.month == '2026-03'), isEmpty, reason: 'the payment month is the oldest one held');
  });

  test('a slip linked to a row that is not a payment (hand-added) keeps its own date', () {
    final h = history([pay('m4', '2026-04-02', -4500, manual: true)], [slip('s3', date: '2026-03-28', total: 4500, linked: 'm4')]);
    expect(monthIn(h, '2026-03').slips.map((s) => s.id), ['s3']);
    expect(monthIn(h, '2026-03').state, BillMonthState.slipOnly);
    expect(monthIn(h, '2026-04').payments, isEmpty);
  });

  test('a slip with another payee and the same amount is not listed, even linked to a payment', () {
    final h = history([
      pay('t5', '2026-05-14', -4500)
    ], [
      slip('x1', payee: 'Other Water', date: '2026-05-14', total: 4500),
      slip('x2', payee: 'Other Water', date: '2026-05-10', total: 4500, linked: 't5'),
      slip('x3', payee: '', date: '2026-05-10', total: 4500),
    ]);
    for (final m in h) {
      expect(m.slips, isEmpty);
    }
    expect(monthIn(h, '2026-05').billed, isNull);
  });

  test('a payment at another payee with the same amount is not listed', () {
    final h = history([pay('o5', '2026-05-14', -4500, desc: 'OTHER WATER')], []);
    expect(h.expand((m) => m.payments), isEmpty);
  });

  test('foreign-currency payments and slips are left out', () {
    final h = history([
      pay('f5', '2026-05-14', -4500, currency: 'USD'),
      pay('t5', '2026-05-15', -4500)
    ], [
      slip('f5s', date: '2026-05-01', total: 4500, currency: 'USD'),
    ]);
    final may = monthIn(h, '2026-05');
    expect(may.payments.map((t) => t.id), ['t5']);
    expect(may.paid, 4500);
    expect(may.slips, isEmpty);
    final onlyForeign = history([pay('f5', '2026-05-14', -4500, currency: 'USD')], []);
    expect(onlyForeign.map((m) => m.month), ['2026-06']);
  });

  test('deleted rows and deleted slips are left out', () {
    final h = history([pay('d5', '2026-05-14', -4500, deleted: true)], [slip('d5s', date: '2026-05-01', total: 4500, deleted: true)]);
    expect(h.map((m) => m.month), ['2026-06']);
  });

  test('manual rows are not payments (a hand-added row replaced by its bank row neither)', () {
    final h = history([
      pay('m5', '2026-05-14', -4500, manual: true),
      const Tx(id: 'm4', source: 'manual', date: '2026-04-14', amount: -4500, manual: true, note: 'LUMEN POWER', matchedTo: 't4'),
    ], []);
    expect(h.expand((m) => m.payments), isEmpty);
  });

  test('own-transfer rows are not payments', () {
    final h = history([
      pay('a', '2026-05-01', -4500, transferTo: 'b'),
      pay('c', '2026-05-02', -4500, kind: TxKind.ownTransfer),
      pay('d', '2026-05-03', -4500, kind: TxKind.exchange),
      pay('e', '2026-05-04', -4500, category: 'Internal transfer'),
    ], []);
    expect(h.expand((m) => m.payments), isEmpty);
  });

  test('refunds (inflows) from the payee are not payments', () {
    final h = history([pay('r5', '2026-05-20', 1000)], []);
    expect(h.expand((m) => m.payments), isEmpty);
  });

  test('the row in lastPaidTx is listed even when its text gives another key', () {
    final b = bill.copyWith(lastPaidTx: 'lp');
    final h = history([pay('lp', '2026-05-14', -4500, desc: 'LP 77 ODD TEXT')], [], b: b);
    expect(monthIn(h, '2026-05').payments.map((t) => t.id), ['lp']);
    final foreign = history([pay('lp', '2026-05-14', -4500, desc: 'LP', currency: 'USD')], [], b: b);
    expect(foreign.expand((m) => m.payments), isEmpty);
  });

  test('the 12-month limit: months back from the newest; older rows and slips are not listed', () {
    final rows = [for (var m = 1; m <= 12; m++) pay('t$m', '2025-${m.toString().padLeft(2, '0')}-14', -4500)];
    rows.add(pay('t13', '2026-01-14', -4500));
    final h = history(rows, [slip('old', date: '2025-06-01', total: 1)]);
    expect(h.length, 12);
    expect(h.first.month, '2026-06');
    expect(h.last.month, '2025-07');
    expect(h.where((m) => m.slips.isNotEmpty), isEmpty);
    expect(history(rows, [], months: 3).map((m) => m.month), ['2026-06', '2026-05', '2026-04']);
  });

  test('months below 1 and a bad today are refused', () {
    expect(() => history([], [], months: 0), throwsArgumentError);
    expect(() => billHistory(bill, [], [], today: '2026-6-1', currency: 'EUR'), throwsArgumentError);
  });

  test('ordering: newest month first; payments by date then id; slips by date then id; paid sums exactly', () {
    final h = history([
      pay('tb', '2026-05-20', -1),
      pay('ta', '2026-05-20', -2),
      pay('tc', '2026-05-03', -4497),
      pay('tc', '2026-05-03', -4497), // the same row twice is listed once
    ], [
      slip('sb', date: '2026-05-09', total: 10),
      slip('sa', date: '2026-05-09', total: 20),
      slip('sc', date: '2026-05-01', total: 4470),
    ]);
    expect(h.map((m) => m.month), ['2026-06', '2026-05']);
    final may = monthIn(h, '2026-05');
    expect(may.payments.map((t) => t.id), ['tc', 'ta', 'tb']);
    expect(may.slips.map((s) => s.id), ['sc', 'sa', 'sb']);
    expect(may.paid, 4500);
    expect(may.billed, 4500);
  });

  test('the same inputs in another order give the same history', () {
    final rows = [pay('t2', '2026-02-14', -4500), pay('t4', '2026-04-14', -4400), pay('t5', '2026-05-14', -4600)];
    final slips = [slip('s2', date: '2026-02-01', total: 4500), slip('s4', date: '2026-04-01', total: 4400, linked: 't4')];
    String flat(List<BillMonth> h) => h
        .map((m) => '${m.month}:${m.state.name}:${m.paid}:${m.billed}:${m.payments.map((t) => t.id)}:${m.slips.map((s) => s.id)}')
        .join('|');
    expect(flat(history(rows.reversed.toList(), slips.reversed.toList())), flat(history(rows, slips)));
  });
}
