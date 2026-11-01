// HP-T2: invariants pinned from mutation testing of accounts and planned. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show bankProfiles, csvSourcePrefix;

Tx _bank(String id, String date, int amount, {String source = 'pbz', String currency = 'EUR', bool deleted = false}) =>
    Tx(id: id, source: source, date: date, amount: amount, currency: currency, deleted: deleted);
Tx _cash(String id, String date, int amount, {String? to, bool pending = false}) =>
    Tx(id: id, source: 'manual', date: date, amount: amount, manual: true, matchedTo: to, matchPending: pending);
Account _acc(String id,
        {String? source = 'pbz', String currency = 'EUR', int opening = 10000, String date = '2026-03-01', bool deleted = false}) =>
    Account(id: id, name: id, source: source, currency: currency, opening: opening, openingDate: date, deleted: deleted);

void main() {
  group('accountBalances', () {
    test('opening date is the end of that day: rows on it do not count, the day after does', () {
      final b =
          accountBalances([_acc('a')], [_bank('1', '2026-03-01', -500), _bank('2', '2026-03-02', -700), _bank('3', '2026-02-28', 900)]);
      expect(b.single.balance, 10000 - 700);
      expect(b.single.rowsCounted, 1);
      expect(b.single.lastRowDate, '2026-03-02');
    });

    test('only own source, currency and live rows; manual rows never count for a bank account', () {
      final b = accountBalances([
        _acc('a')
      ], [
        _bank('1', '2026-03-05', -100),
        _bank('2', '2026-03-05', -200, source: 'revolut'),
        _bank('3', '2026-03-05', -400, currency: 'USD'),
        _bank('4', '2026-03-05', -800, deleted: true),
        _cash('5', '2026-03-05', -1600),
      ]);
      expect(b.single.balance, 9900);
      expect(b.single.rowsCounted, 1);
    });

    test('cash counts unmatched, non-pending hand-added rows only', () {
      final b = accountBalances([
        _acc('c', source: null)
      ], [
        _cash('1', '2026-03-05', -100),
        _cash('2', '2026-03-05', -200, to: 'x'),
        _cash('3', '2026-03-05', -400, pending: true),
        _bank('4', '2026-03-05', -800),
      ]);
      expect(b.single.balance, 9900);
      expect(b.single.rowsCounted, 1);
    });

    test('lastRowDate is the latest counted date whatever the row order', () {
      final rows = [_bank('1', '2026-03-09', -1), _bank('2', '2026-03-05', -1), _bank('3', '2026-03-07', -1)];
      expect(accountBalances([_acc('a')], rows).single.lastRowDate, '2026-03-09');
      expect(accountBalances([_acc('a')], rows.reversed.toList()).single.lastRowDate, '2026-03-09');
      expect(accountBalances([_acc('a')], []).single.lastRowDate, isNull);
    });

    test('duplicates: smallest id counts, others show opening only; deleted accounts are skipped and never own', () {
      final accs = [_acc('b', opening: 500), _acc('a', opening: 100), _acc('0', deleted: true), _acc('c', opening: 7, currency: 'USD')];
      final b = accountBalances(accs, [_bank('1', '2026-03-05', -50)]);
      expect(b.map((x) => x.account.id), ['b', 'a', 'c']);
      expect(b[0].duplicateOf, 'a');
      expect(b[0].balance, 500);
      expect(b[0].rowsCounted, 0);
      expect(b[0].lastRowDate, isNull);
      expect(b[1].duplicateOf, isNull);
      expect(b[1].balance, 50);
      expect(b[2].duplicateOf, isNull);
      expect(b[2].balance, 7);
    });

    test('balanceTotals per currency, sorted keys, duplicates left out', () {
      final b = accountBalances([
        _acc('a', opening: 100),
        _acc('b', opening: 900),
        _acc('u', currency: 'USD', opening: 5, source: 'rev'),
        _acc('c', source: null, opening: 20)
      ], []);
      expect(balanceTotals(b), {'EUR': 120, 'USD': 5});
      expect(balanceTotals(b).keys.toList(), ['EUR', 'USD']);
      expect(balanceTotals([]), isEmpty);
    });
  });

  group('accountSourceLabel', () {
    test('cash, bank profiles by id, unknown ids as they are, removed CSV layouts', () {
      expect(accountSourceLabel(null), 'Cash');
      for (final p in bankProfiles) {
        expect(accountSourceLabel(p.id), p.label);
      }
      expect(accountSourceLabel('someunknownbank'), 'someunknownbank');
      expect(accountSourceLabel('${csvSourcePrefix}gone'), 'CSV file');
    });
  });

  group('checkBankBalance', () {
    final a = _acc('a');
    final rows = [
      _bank('1', '2026-03-01', -111),
      _bank('2', '2026-03-05', -200),
      _bank('3', '2026-03-10', -300),
      _bank('4', '2026-03-12', -400)
    ];

    test('counts rows after the opening up to and including the date', () {
      final c = checkBankBalance(a, rows, date: '2026-03-10', bankCents: 9500);
      expect(c.appCents, 10000 - 200 - 300);
      expect(c.rowsSince, 2);
      expect(c.since, '2026-03-01');
      expect(c.diff, 9500 - 9500);
      expect(c.matches, isTrue);
      expect(c.stored.bankCents, 9500);
      final d = checkBankBalance(a, rows, date: '2026-03-09', bankCents: 9500);
      expect(d.appCents, 9800);
      expect(d.diff, -300);
      expect(d.matches, isFalse);
    });

    test('a check dated on the opening day counts no row', () {
      final c = checkBankBalance(a, rows, date: '2026-03-01', bankCents: 10000);
      expect(c.rowsSince, 0);
      expect(c.matches, isTrue);
    });
  });

  group('balanceTrusted', () {
    final a = _acc('a', date: '2026-01-01');
    final rows = [_bank('1', '2026-02-01', -1000)];
    BankCheck chk(String date, int bank) => BankCheck(date: date, bankCents: bank, appCents: bank);

    test('opening within 35 days is trusted, 36 is not', () {
      expect(balanceTrusted(a, today: '2026-02-05', rows: rows), isTrue); // 35 days
      expect(balanceTrusted(a, today: '2026-02-06', rows: rows), isFalse); // 36 days
    });

    test('a matching recent check anchors trust; a stale, off or pre-opening check does not', () {
      expect(balanceTrusted(a, today: '2026-03-01', last: chk('2026-02-10', 9000), rows: rows), isTrue);
      expect(balanceTrusted(a, today: '2026-03-01', last: chk('2026-02-10', 9001), rows: rows), isFalse);
      expect(balanceTrusted(a, today: '2026-03-01', rows: rows), isFalse);
      // 35 days old check: trusted; 36: not
      expect(balanceTrusted(a, today: '2026-03-17', last: chk('2026-02-10', 9000), rows: rows), isTrue);
      expect(balanceTrusted(a, today: '2026-03-18', last: chk('2026-02-10', 9000), rows: rows), isFalse);
      // dated before the opening: never
      expect(balanceTrusted(a, today: '2026-01-20', last: chk('2025-12-30', 10000), rows: []), isTrue, reason: 'opening itself is recent');
      expect(balanceTrusted(a, today: '2026-03-01', last: chk('2025-12-31', 10000), rows: rows), isFalse);
    });

    test('a row deleted after the check makes it stale', () {
      expect(balanceTrusted(a, today: '2026-03-01', last: chk('2026-02-10', 9000), rows: [_bank('1', '2026-02-01', -1000, deleted: true)]),
          isFalse);
    });
  });

  group('BankCheck', () {
    test('json round trip and damaged values', () {
      const c = BankCheck(date: '2026-03-01', bankCents: 500, appCents: 700);
      expect(c.diff, -200);
      expect(BankCheck.fromJson(c.toJson())!.bankCents, 500);
      expect(BankCheck.fromJson({'date': 'x', 'bank': 1, 'app': 2}), isNull);
      expect(BankCheck.fromJson({'date': '2026-03-01', 'bank': '1', 'app': 2}), isNull);
      expect(BankCheck.fromJson({'date': '2026-03-01', 'bank': 1, 'app': 2.5}), isNull);
      expect(BankCheck.fromJson('x'), isNull);
    });
  });

  group('amountFromText', () {
    test('forms and refusals', () {
      expect(amountFromText('Dentist 80 €'), 8000);
      expect(amountFromText('€80'), 8000);
      expect(amountFromText('EUR 80,50'), 8050);
      expect(amountFromText('80.5€'), 8050);
      expect(amountFromText('1.250,00 €'), 125000);
      expect(amountFromText('1,250.00 €'), 125000);
      expect(amountFromText('1.250 €'), 125000);
      expect(amountFromText('0.250 €'), isNull);
      expect(amountFromText('1.250.00 €'), isNull);
      expect(amountFromText('Meeting 14:30 2026'), isNull);
      expect(amountFromText('0 €'), isNull);
      expect(amountFromText('-80 €'), isNull);
      expect(amountFromText('80 € or 90 €'), isNull);
      expect(amountFromText('80 € then 80 EUR'), 8000);
      expect(amountFromText('80 € refund -5 €'), 8000);
      expect(amountFromText('1234567890123 €'), isNull);
      expect(amountFromText('123456789012 €'), 12345678901200);
    });
  });

  group('isSafeCents / parseMoneyCents', () {
    test('cap is inclusive on both sides', () {
      expect(isSafeCents(maxAmountCents), isTrue);
      expect(isSafeCents(-maxAmountCents), isTrue);
      expect(isSafeCents(maxAmountCents + 1), isFalse);
      expect(isSafeCents(-maxAmountCents - 1), isFalse);
      expect(isSafeCents(0), isTrue);
    });

    test('the caps are 10^11 cents typed and 10^12 cents for a synced row; 9,000 rows at the legacy cap sum exactly', () {
      expect(maxAmountCents, 100000000000);
      expect(legacyRowCapCents, 1000000000000);
      expect(9000 * legacyRowCapCents, lessThan(9007199254740992));
      expect(90000 * maxAmountCents, lessThan(9007199254740992));
    });

    test('typed amounts', () {
      expect(parseMoneyCents('12'), 1200);
      expect(parseMoneyCents('12.5'), 1250);
      expect(parseMoneyCents('12,50'), 1250);
      expect(parseMoneyCents('1.234,56'), 123456);
      expect(parseMoneyCents('1,234.56'), 123456);
      expect(parseMoneyCents('1,234'), 123400);
      expect(parseMoneyCents(' € 7 '), 700);
      expect(parseMoneyCents('0,005'), isNull);
      expect(parseMoneyCents('-5'), isNull);
      expect(parseMoneyCents('-0'), 0);
      expect(parseMoneyCents(''), isNull);
      expect(parseMoneyCents('abc'), isNull);
      expect(parseMoneyCents('1e5'), isNull);
      expect(parseMoneyCents('${maxAmountCents ~/ 100}'), maxAmountCents);
      expect(parseMoneyCents('${maxAmountCents ~/ 100 + 1}'), isNull);
    });
  });

  group('normalizeTitle', () {
    test('folds, drops amounts and digits, collapses', () {
      expect(normalizeTitle('Zubar ČĆŽ 80 €'), 'zubar ccz');
      expect(normalizeTitle('Dentist 2026'), 'dentist');
      expect(normalizeTitle('  A--b   c  '), 'a b c');
      expect(normalizeTitle('EUR 80 Check-up'), 'check up');
      expect(normalizeTitle('12345'), '');
    });
  });

  group('upcoming', () {
    final lumen = billPayeeKey(Bill(id: 'x', payee: 'Lumen Power'))!;
    final rec = RecurringBill(
        id: 'rec:$lumen',
        payee: lumen,
        label: 'Lumen Power',
        category: 'Shopping',
        expectedAmount: 4500,
        nextDue: '2026-04-10',
        status: 'confirmed');
    PlannedCost slip(String date) => PlannedCost(
        id: 'bill:s1',
        title: 'Lumen Power',
        date: date,
        amount: 4500,
        category: 'Shopping',
        source: PlannedSource.bill,
        sourceRef: 'bill:s1');
    List<String> keys(PlannedCost p, String from, String to) => upcoming(planned: [p], bills: [rec], events: const [], from: from, to: to)
        .where((i) => i.kind == UpcomingKind.planned)
        .map((i) => i.key)
        .toList();

    test('a bill slip row is hidden where its covering occurrence is in range or the cycle was just paid, else listed', () {
      expect(keys(slip('2026-04-09'), '2026-04-01', '2026-04-30'), isEmpty, reason: 'occurrence 04-10 in range');
      expect(keys(slip('2026-04-09'), '2026-04-01', '2026-04-09'), ['p:bill:s1'], reason: 'occurrence outside the range: the row stands');
      expect(keys(slip('2026-03-11'), '2026-03-01', '2026-03-31'), isEmpty, reason: 'k = -1: the cycle just paid or skipped');
      expect(keys(slip('2026-03-11'), '2026-03-01', '2026-04-30'), isEmpty);
    });

    test('an invalid or reversed range gives nothing, whichever end is bad', () {
      const p = PlannedCost(id: 'p1', title: 'Dentist', date: '2026-04-09', amount: 100, category: 'Health');
      List<UpcomingItem> run(String from, String to) => upcoming(planned: [p], bills: const [], events: const [], from: from, to: to);
      expect(run('2026-04-01', '2026-04-30'), hasLength(1));
      expect(run('2026-04-09', '2026-04-09'), hasLength(1), reason: 'both ends inclusive');
      expect(run('', '2026-04-30'), isEmpty);
      expect(run('2026-04-01', ''), isEmpty);
      expect(run('2026-04-30', '2026-04-01'), isEmpty);
    });
  });

  group('paidCandidates', () {
    CategorizedTx row(String id, String date, int cents, {String cat = 'Health', bool deleted = false}) =>
        CategorizedTx(Tx(id: id, source: 'pbz', date: date, amount: cents, deleted: deleted), cat, BudgetKind.flex);
    PlannedCost plan(String id, {String? paidTx, String date = '2026-03-10', int? amount = 5000, String? cat = 'Health'}) =>
        PlannedCost(id: id, title: 'Dentist', date: date, amount: amount, category: cat, paidTx: paidTx);

    test('same category, live expenses within 3 days; its own paid row stays, another cost\'s paid row goes', () {
      final p = plan('p1', paidTx: 'own');
      final all = [p, plan('p2', paidTx: 'taken'), plan('p3')];
      final got = paidCandidates(
          p,
          [
            row('own', '2026-03-10', -5000),
            row('taken', '2026-03-10', -5000),
            row('zero', '2026-03-10', 0),
            row('far', '2026-03-14', -5000),
            row('edge', '2026-03-13', -5000),
            row('edge2', '2026-03-07', -5000),
            row('other', '2026-03-10', -5000, cat: 'Shopping'),
            row('income', '2026-03-10', 5000),
            row('gone', '2026-03-10', -5000, deleted: true),
            row('near', '2026-03-12', -4000),
          ],
          all);
      expect(got.map((t) => t.tx.id), ['own', 'near', 'edge2', 'edge']);
    });

    test('order: closest date, then closest amount, then date, then id; no category or no date: none', () {
      final p = plan('p1');
      final got = paidCandidates(p, [
        row('b', '2026-03-11', -4500),
        row('a', '2026-03-11', -4500),
        row('c', '2026-03-09', -4800),
        row('d', '2026-03-11', -5000),
      ], [
        p
      ]);
      expect(got.map((t) => t.tx.id), ['d', 'c', 'a', 'b']);
      expect(paidCandidates(plan('p9', cat: null), [row('a', '2026-03-10', -5000)], []), isEmpty);
      expect(paidCandidates(plan('p9', cat: ''), [row('a', '2026-03-10', -5000)], []), isEmpty);
    });
  });

  group('billOccurrences', () {
    RecurringBill bill(String due, int step, {String? endsOn}) => RecurringBill(
        id: 'rec:x',
        payee: 'x',
        label: 'X',
        category: 'Bills & subscriptions',
        expectedAmount: 1000,
        intervalDays: step,
        nextDue: due,
        endsOn: endsOn);

    test('inclusive range, skips before from, steps by interval', () {
      expect(billOccurrences(bill('2026-03-01', 10), '2026-03-11', '2026-03-31'), ['2026-03-11', '2026-03-21', '2026-03-31']);
      expect(billOccurrences(bill('2026-03-01', 10), '2026-03-12', '2026-03-30'), ['2026-03-21']);
      expect(billOccurrences(bill('2026-03-05', 7), '2026-03-05', '2026-03-05'), ['2026-03-05']);
      expect(billOccurrences(bill('2026-03-05', 7), '2026-03-06', '2026-03-11'), isEmpty);
    });

    test('interval below 1 gives nextDue once, only inside the range', () {
      expect(billOccurrences(bill('2026-03-05', 0), '2026-03-01', '2026-03-31'), ['2026-03-05']);
      expect(billOccurrences(bill('2026-03-05', 0), '2026-03-05', '2026-03-05'), ['2026-03-05']);
      expect(billOccurrences(bill('2026-03-05', 0), '2026-03-06', '2026-03-31'), isEmpty);
      expect(billOccurrences(bill('2026-03-05', 0), '2026-03-01', '2026-03-04'), isEmpty);
    });

    test('endsOn is the last due date; bad or reversed ranges are empty', () {
      expect(billOccurrences(bill('2026-03-01', 10, endsOn: '2026-03-21'), '2026-03-01', '2026-04-30'),
          ['2026-03-01', '2026-03-11', '2026-03-21']);
      expect(billOccurrences(bill('2026-03-01', 10), '2026-03-31', '2026-03-01'), isEmpty);
      expect(billOccurrences(bill('bad', 10), '2026-03-01', '2026-03-31'), isEmpty);
      expect(billOccurrences(bill('2026-03-01', 10), 'bad', '2026-03-31'), isEmpty);
    });

    test('never more than 1000 dates', () {
      expect(billOccurrences(bill('2020-01-01', 1), '2020-01-01', '2030-12-31'), hasLength(1000));
    });
  });
}
