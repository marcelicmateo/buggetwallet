// HP-T2: auto-link invariants (billLinkTokens, descriptionHasToken, planBillLinks), pinned from mutation testing.
// Never by amount alone: a link needs a token in the bank text AND the exact amount. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

Bill _b(String id,
        {String? ref,
        String? ext,
        int? total = 4599,
        String? date = '2026-03-10',
        String? due,
        String currency = 'EUR',
        BillStatus status = BillStatus.confirmed,
        String? linked,
        bool deleted = false,
        BillSource source = BillSource.manual}) =>
    Bill(
        id: id,
        reference: ref,
        externalId: ext,
        total: total,
        date: date,
        dueDate: due,
        currency: currency,
        status: status,
        linkedTx: linked,
        deleted: deleted,
        source: source);

Tx _t(String id, String date, int cents, String desc,
        {String currency = 'EUR', bool manual = false, bool deleted = false, String? transferTo}) =>
    Tx(
        id: id,
        source: manual ? 'manual' : 'pbz',
        date: date,
        amount: cents,
        currency: currency,
        description: desc,
        manual: manual,
        deleted: deleted,
        transferTo: transferTo);

void main() {
  group('billLinkTokens', () {
    test('reference: at least 6 digits; with an HR model both the model form and the bare number', () {
      expect(billLinkTokens(_b('a', ref: 'HR00 1234567')), ['HR001234567', '1234567']);
      expect(billLinkTokens(_b('a', ref: 'hr99 12-34-56')), ['HR99123456', '123456']);
      expect(billLinkTokens(_b('a', ref: '123456')), ['123456']);
      expect(billLinkTokens(_b('a', ref: 'HR00 12345')), isEmpty);
      expect(billLinkTokens(_b('a', ref: '12345')), isEmpty);
      expect(billLinkTokens(_b('a', ref: 'abcdef')), isEmpty);
      expect(billLinkTokens(_b('a')), isEmpty);
    });

    test('JIR: at least 6 normalized characters', () {
      expect(billLinkTokens(_b('a', ext: 'jir:ab-cd-12')), ['ABCD12']);
      expect(billLinkTokens(_b('a', ext: 'jir:ABC12')), isEmpty);
      expect(billLinkTokens(_b('a', ext: 'jir:ABC123')), ['ABC123']);
      expect(billLinkTokens(_b('a', ext: 'jir:')), isEmpty);
    });

    test('invoice number: digits only needs 6, mixed needs 4 with a letter and a digit, letters alone never', () {
      expect(billLinkTokens(_b('a', ext: 'inv:issuer:123456')), ['123456']);
      expect(billLinkTokens(_b('a', ext: 'inv:issuer:12345')), isEmpty);
      expect(billLinkTokens(_b('a', ext: 'inv:issuer:2026')), isEmpty);
      expect(billLinkTokens(_b('a', ext: 'inv:issuer:AB-12')), ['AB12']);
      expect(billLinkTokens(_b('a', ext: 'inv:issuer:AB1')), isEmpty);
      expect(billLinkTokens(_b('a', ext: 'inv:issuer:ABCDEF')), isEmpty);
      expect(billLinkTokens(_b('a', ext: 'inv:issuer:A123')), ['A123']);
      expect(billLinkTokens(_b('a', ext: 'inv:12345678')), isEmpty, reason: 'no issuer part: nothing to read');
      expect(billLinkTokens(_b('a', ext: 'inv:iss:')), isEmpty);
      expect(billLinkTokens(_b('a', ext: 'hub3:123456')), isEmpty);
    });
  });

  group('descriptionHasToken', () {
    test('digit tokens do not run into more digits; letters around are fine; accents and case fold', () {
      expect(descriptionHasToken('PLACANJE 12345678 RACUN', '12345678'), isTrue);
      expect(descriptionHasToken('9123456789', '12345678'), isFalse);
      expect(descriptionHasToken('123456789', '12345678'), isFalse);
      expect(descriptionHasToken('x12345678y', '12345678'), isTrue);
      expect(descriptionHasToken('9123456789 and 12345678', '12345678'), isTrue, reason: 'a later clean occurrence counts');
      expect(descriptionHasToken('ref abc123456x', 'ABC123456'), isTrue);
      expect(descriptionHasToken('ref abc1234567', 'ABC123456'), isFalse);
      expect(descriptionHasToken('Račun-AB12', 'AB12'), isTrue);
      expect(descriptionHasToken('1234', ''), isFalse);
      expect(descriptionHasToken('', '1234'), isFalse);
      expect(descriptionHasToken('123456', '123456'), isTrue, reason: 'token is the whole text');
    });
  });

  group('planBillLinks', () {
    final bill = _b('b1', ref: '1234567');
    final row = _t('t1', '2026-03-12', -4599, 'RACUN 1234567 LUMEN');

    test('token and exact amount link; either alone does not', () {
      expect(planBillLinks([bill], [row]), {'b1': 't1'});
      expect(planBillLinks([bill], [_t('t1', '2026-03-12', -4599, 'LUMEN POWER')]), isEmpty, reason: 'amount alone');
      expect(planBillLinks([bill], [_t('t1', '2026-03-12', -4598, 'RACUN 1234567')]), isEmpty);
      expect(planBillLinks([bill], [_t('t1', '2026-03-12', -4600, 'RACUN 1234567')]), isEmpty);
      expect(planBillLinks([bill], [_t('t1', '2026-03-12', 4599, 'RACUN 1234567')]), isEmpty, reason: 'income');
      expect(planBillLinks([_b('b1')], [row]), isEmpty, reason: 'a bill without tokens never links');
    });

    test('the window is date - 3 .. (due ?? date) + 60, inclusive', () {
      List<String> hits(Bill b, String date) => planBillLinks([b], [_t('t', date, -4599, 'R 1234567')]).values.toList();
      final plain = _b('b1', ref: '1234567', date: '2026-03-10');
      expect(hits(plain, '2026-03-07'), ['t']);
      expect(hits(plain, '2026-03-06'), isEmpty);
      expect(hits(plain, '2026-05-09'), ['t']);
      expect(hits(plain, '2026-05-10'), isEmpty);
      final dueB = _b('b1', ref: '1234567', date: '2026-03-10', due: '2026-03-20');
      expect(hits(dueB, '2026-03-07'), ['t']);
      expect(hits(dueB, '2026-03-06'), isEmpty);
      expect(hits(dueB, '2026-05-19'), ['t']);
      expect(hits(dueB, '2026-05-20'), isEmpty);
      final onlyDue = _b('b1', ref: '1234567', date: null, due: '2026-03-20');
      expect(hits(onlyDue, '2026-03-17'), ['t']);
      expect(hits(onlyDue, '2026-03-16'), isEmpty);
      expect(hits(_b('b1', ref: '1234567', date: null), '2026-03-10'), isEmpty, reason: 'no date: no window');
      expect(hits(_b('b1', ref: '1234567', date: 'bad'), '2026-03-10'), isEmpty);
    });

    test('only confirmed, unpaid, live bills with a positive total; attachments never', () {
      for (final b in [
        _b('b1', ref: '1234567', status: BillStatus.review),
        _b('b1', ref: '1234567', linked: 'other'),
        _b('b1', ref: '1234567', deleted: true),
        _b('b1', ref: '1234567', total: null),
        _b('b1', ref: '1234567', total: 0),
        _b('b1', ref: '1234567', total: -4599),
        _b('b1', ref: '1234567', source: BillSource.attachment),
      ]) {
        expect(planBillLinks([b], [row, _t('t2', '2026-03-12', 4599, 'RACUN 1234567')]), isEmpty, reason: '$b');
      }
    });

    test('rows that cannot pay: hand-added, deleted, paired transfers, other currency', () {
      for (final r in [
        _t('t1', '2026-03-12', -4599, 'RACUN 1234567', manual: true),
        _t('t1', '2026-03-12', -4599, 'RACUN 1234567', deleted: true),
        _t('t1', '2026-03-12', -4599, 'RACUN 1234567', transferTo: 'x'),
        _t('t1', '2026-03-12', -4599, 'RACUN 1234567', currency: 'USD'),
      ]) {
        expect(planBillLinks([bill], [r]), isEmpty);
      }
      expect(planBillLinks([_b('b1', ref: '1234567', currency: 'USD')], [_t('t1', '2026-03-12', -4599, 'R 1234567', currency: 'USD')]),
          {'b1': 't1'});
    });

    test('ambiguity links nothing: two rows for a bill, or one row for two bills; a row taken by another bill is out', () {
      final r2 = _t('t2', '2026-03-13', -4599, 'RACUN 1234567 AGAIN');
      expect(planBillLinks([bill], [row, r2]), isEmpty);
      final other = _b('b2', ref: '1234567');
      expect(planBillLinks([bill, other], [row]), isEmpty);
      expect(planBillLinks([bill, _b('b9', ref: '7654321', linked: 't1')], [row]), isEmpty, reason: 't1 already pays b9');
      expect(planBillLinks([bill, _b('b9', ref: '7654321', linked: 't2')], [row, r2]), {'b1': 't1'});
      // a deleted bill's or an attachment's link does not take the row
      expect(planBillLinks([bill, _b('b9', linked: 't1', deleted: true)], [row]), {'b1': 't1'});
      expect(planBillLinks([bill, _b('b9', linked: 't1', source: BillSource.attachment)], [row]), {'b1': 't1'});
      // two bills, two rows: each links its own
      final bill2 = _b('b2', ref: '7654321', total: 100);
      expect(planBillLinks([bill, bill2], [row, _t('t3', '2026-03-12', -100, 'REF 7654321')]), {'b1': 't1', 'b2': 't3'});
    });
  });

  group('billCandidates', () {
    CategorizedTx row(String id, String date, int cents, String desc,
            {BudgetKind kind = BudgetKind.flex, bool deleted = false, bool manual = false, String? transferTo}) =>
        CategorizedTx(
            Tx(
                id: id,
                source: manual ? 'manual' : 'pbz',
                date: date,
                amount: cents,
                description: desc,
                deleted: deleted,
                manual: manual,
                transferTo: transferTo),
            'Shopping',
            kind);
    final slip = Bill(id: 'b1', payee: 'Lumen Power', date: '2026-03-10', dueDate: '2026-03-20', total: 4500);

    test('window date - 3 .. due + 30 inclusive; only live, non-transfer expenses', () {
      List<String> ids(List<CategorizedTx> rows, [Bill? b]) => billCandidates(b ?? slip, rows, [b ?? slip]).map((t) => t.tx.id).toList();
      expect(
          ids([
            row('a', '2026-03-07', -100, 'x'),
            row('b', '2026-03-06', -100, 'x'),
            row('c', '2026-04-19', -100, 'x'),
            row('d', '2026-04-20', -100, 'x')
          ]),
          ['a', 'c']);
      expect(
          ids([
            row('in', '2026-03-10', 100, 'x'),
            row('zero', '2026-03-10', 0, 'x'),
            row('gone', '2026-03-10', -100, 'x', deleted: true),
            row('hand', '2026-03-10', -100, 'x', manual: true), // a hand-added expense may be what the slip paid
            row('pair', '2026-03-10', -100, 'x', transferTo: 'z'),
            row('xfer', '2026-03-10', -100, 'x', kind: BudgetKind.transfer),
            row('ok', '2026-03-10', -100, 'x'),
          ]),
          ['hand', 'ok']);
      expect(billCandidates(Bill(id: 'n', total: 100), [row('a', '2026-03-10', -100, 'x')], const []), isEmpty, reason: 'no date: none');
      expect(
          billCandidates(Bill(id: 'n', date: '2026-03-10', source: BillSource.attachment), [row('a', '2026-03-10', -100, 'x')], const []),
          isEmpty);
    });

    test('rows paid to another bill are out, its own is not', () {
      final other = Bill(id: 'b2', linkedTx: 'a');
      final mine = Bill(id: 'b1', payee: 'Lumen Power', date: '2026-03-10', total: 4500, linkedTx: 'a');
      final rows = [row('a', '2026-03-10', -4500, 'x'), row('b', '2026-03-10', -4500, 'x')];
      expect(billCandidates(slip, rows, [slip, other]).map((t) => t.tx.id), ['b']);
      expect(billCandidates(mine, rows, [mine]).map((t) => t.tx.id), ['a', 'b']);
      expect(billCandidates(slip, rows, [slip, Bill(id: 'b2', linkedTx: 'a', deleted: true)]).map((t) => t.tx.id), ['a', 'b']);
    });

    test('order: payee word first (3+ letters only), then closest date, closest amount, date, id', () {
      final rows = [
        row('z', '2026-03-10', -4500, 'SOMEWHERE'),
        row('n1', '2026-03-14', -4500, 'LUMEN POWER D.O.O.'),
        row('n2', '2026-03-12', -4000, 'lumen'),
        row('n3', '2026-03-12', -4400, 'LUMEN'),
        row('n4', '2026-03-12', -4400, 'LUMEN POWER'),
      ];
      expect(billCandidates(slip, rows, [slip]).map((t) => t.tx.id), ['n3', 'n4', 'n2', 'n1', 'z']);
      // two-letter words never name a payee
      final tiny = Bill(id: 'b3', payee: 'AB CD', date: '2026-03-10', total: 100);
      expect(billCandidates(tiny, [row('a', '2026-03-10', -100, 'xx'), row('b', '2026-03-13', -100, 'AB CD')], [tiny]).map((t) => t.tx.id),
          ['a', 'b']);
      final three = Bill(id: 'b4', payee: 'ABC', date: '2026-03-10', total: 100);
      expect(
          billCandidates(three, [row('a', '2026-03-10', -100, 'xx'), row('b', '2026-03-13', -100, 'my abc shop')], [three])
              .map((t) => t.tx.id),
          ['b', 'a']);
    });
  });

  group('plannedCoverage', () {
    final key = billPayeeKey(Bill(id: 'x', payee: 'Lumen Power'))!;
    RecurringBill rec({int interval = 30, String status = 'confirmed', String? direction, String? payee, String due = '2026-04-10'}) =>
        RecurringBill(
            id: 'rec:$key',
            payee: payee ?? key,
            label: 'Lumen Power',
            category: 'Shopping',
            expectedAmount: 4500,
            intervalDays: interval,
            nextDue: due,
            status: status,
            direction: direction);
    PlannedCost plan(String date, {String title = 'Lumen Power', PlannedSource source = PlannedSource.bill}) =>
        PlannedCost(id: 'bill:s', title: title, date: date, amount: 4500, category: 'Shopping', source: source, sourceRef: 'bill:s');
    String? occ(PlannedCost p, RecurringBill r) {
      final c = plannedCoverage(p, [r]);
      return c == null ? 'none' : (c.occurrence ?? 'paid');
    }

    test('cycles nextDue + k * interval for k >= -1, within the tolerance (3 days monthly)', () {
      expect(occ(plan('2026-04-10'), rec()), '2026-04-10');
      expect(occ(plan('2026-04-13'), rec()), '2026-04-10');
      expect(occ(plan('2026-04-14'), rec()), 'none');
      expect(occ(plan('2026-04-07'), rec()), '2026-04-10');
      expect(occ(plan('2026-04-06'), rec()), 'none');
      expect(occ(plan('2026-05-10'), rec()), '2026-05-10');
      expect(occ(plan('2026-06-12'), rec()), '2026-06-09');
      // k = -1 is the cycle just paid or skipped: covered, no occurrence
      expect(occ(plan('2026-03-11'), rec()), 'paid');
      expect(occ(plan('2026-03-08'), rec()), 'paid');
      expect(occ(plan('2026-03-07'), rec()), 'none');
      // k = -2 is too old
      expect(occ(plan('2026-02-09'), rec()), 'none');
    });

    test('an interval below 1 covers nextDue only', () {
      expect(occ(plan('2026-04-11'), rec(interval: 0)), '2026-04-10');
      expect(occ(plan('2026-04-09'), rec(interval: 0)), '2026-04-10');
      expect(occ(plan('2026-04-12'), rec(interval: 0)), 'none');
      expect(occ(plan('2026-05-10'), rec(interval: 0)), 'none');
      expect(occ(plan('2026-03-11'), rec(interval: 0)), 'none');
      expect(occ(plan('2026-04-08'), rec(interval: 0)), 'none');
    });

    test('only confirmed bills of the same payee; not an income; manual or title-less rows never', () {
      expect(occ(plan('2026-04-10'), rec(status: 'candidate')), 'none');
      expect(occ(plan('2026-04-10'), rec(status: 'dismissed')), 'none');
      expect(occ(plan('2026-04-10'), rec(direction: 'in')), 'none');
      expect(occ(plan('2026-04-10'), rec(payee: 'other_co')), 'none');
      expect(occ(plan('2026-04-10', source: PlannedSource.manual), rec()), 'none');
      expect(occ(plan('2026-04-10', title: 'Bill'), rec()), 'none');
      expect(occ(plan('bad'), rec()), 'none');
      expect(occ(plan('2026-04-10'), rec(due: 'bad')), 'none');
      expect(plannedCoverage(plan('2026-04-10'), const []), isNull);
    });
  });

  group('suggestBillCategory', () {
    CategorizedTx row(String id, String date, int cents, String desc, String cat,
            {bool manual = false, BudgetKind kind = BudgetKind.flex}) =>
        CategorizedTx(
            Tx(id: id, source: manual ? 'manual' : 'pbz', date: date, amount: cents, description: desc, manual: manual), cat, kind);
    final slip = Bill(id: 'b1', payee: 'Lumen Power', date: '2026-03-10', total: 4500);

    test('the latest named bank expense gives its category (date, then id); hand-added, income and transfers never', () {
      expect(
          suggestBillCategory(slip, recurring: const [], txs: [
            row('a', '2026-01-10', -100, 'LUMEN POWER', 'Eating out'),
            row('b', '2026-02-10', -100, 'LUMEN POWER', 'Shopping'),
            row('c', '2026-02-10', -100, 'LUMEN POWER', 'Groceries'),
            row('d', '2026-03-30', -100, 'LUMEN POWER', 'Cash', manual: true),
            row('e', '2026-03-30', 100, 'LUMEN POWER', 'Cash'),
            row('f', '2026-03-30', -100, 'LUMEN POWER', 'Cash', kind: BudgetKind.transfer),
            row('g', '2026-03-30', -100, 'SOMEWHERE', 'Cash'),
          ]),
          'Groceries');
      expect(
          suggestBillCategory(slip,
              recurring: const [],
              txs: [row('b', '2026-02-10', -100, 'LUMEN POWER', 'Shopping'), row('a', '2026-02-10', -100, 'LUMEN POWER', 'Eating out')]),
          'Shopping');
      expect(suggestBillCategory(slip, recurring: const [], txs: const []), isNull);
      expect(suggestBillCategory(Bill(id: 'n'), recurring: const [], txs: [row('a', '2026-01-10', -100, 'x', 'Shopping')]), isNull);
    });
  });
}
