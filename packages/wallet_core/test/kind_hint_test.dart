// The importer's kindHint decides a bank row's category before the description rules (D2). Stored once by
// importBatch as `kind_hint`; `account` is never stored. All data is SYNTHETIC.
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

Tx _tx(String source, String type, String desc, int amount, {TxKind? kind, String? category, String? transferTo}) => Tx(
    id: 't$amount',
    source: source,
    date: '2026-01-10',
    amount: amount,
    bankType: type,
    description: desc,
    category: category,
    kindHint: kind,
    transferTo: transferTo);

NormalizedTransaction _hinted(String date, int cents, String type, String desc, TxKind? kind, {String source = 'pbz', String? account}) =>
    NormalizedTransaction(
        id: transactionId(date, cents, desc, 0),
        source: source,
        date: date,
        amountMinor: cents,
        currency: 'EUR',
        bankType: type,
        description: desc,
        kindHint: kind,
        account: account);

void main() {
  final cz = Categorizer();

  group('kindHint precedence', () {
    test('salary: every employer payment is Salary, whatever the bank type or text says', () {
      // Without the hint these rows are Extra income (pbz), To people (revolut) and Shopping (unknown source).
      expect(cz.categoryOf(_tx('pbz', 'Ostalo', 'Payment from Example Employer', 120000)), 'Extra income');
      expect(cz.categoryOf(_tx('pbz', 'Ostalo', 'Payment from Example Employer', 120000, kind: TxKind.salary)), 'Salary');
      expect(cz.categoryOf(_tx('revolut', 'Transfer', 'Example Employer Ltd', 120000, kind: TxKind.salary)), 'Salary');
      expect(cz.categoryOf(_tx('bankx', 'CREDIT', 'Example Employer', 120000, kind: TxKind.salary)), 'Salary');
    });

    test('atm: Rent at or above the rent cash threshold, else Cash, on any bank', () {
      expect(cz.categoryOf(_tx('revolut', 'ATM', 'ATM Example Street', -50000)), 'Shopping', reason: 'no hint: the old Revolut rule');
      expect(cz.categoryOf(_tx('revolut', 'ATM', 'ATM Example Street', -50000, kind: TxKind.atm)), 'Rent');
      expect(cz.categoryOf(_tx('revolut', 'ATM', 'ATM Example Street', -49999, kind: TxKind.atm)), 'Cash');
      expect(cz.categoryOf(_tx('bankx', 'CASH', 'Cash machine', -50001, kind: TxKind.atm)), 'Rent');
      expect(cz.categoryOf(_tx('bankx', 'CASH', 'Cash machine', -100, kind: TxKind.atm)), 'Cash');
      expect(cz.categoryOf(_tx('bankx', 'CASH', 'Cash deposit', 50000, kind: TxKind.atm)), 'Cash', reason: 'money in is never rent');
    });

    test('atm threshold edges follow the setting; 0 means never rent', () {
      final low = Categorizer(rentCashThreshold: 30000);
      expect(low.categoryOf(_tx('revolut', 'ATM', 'ATM', -30000, kind: TxKind.atm)), 'Rent');
      expect(low.categoryOf(_tx('revolut', 'ATM', 'ATM', -29999, kind: TxKind.atm)), 'Cash');
      final never = Categorizer(rentCashThreshold: 0);
      expect(never.categoryOf(_tx('revolut', 'ATM', 'ATM', -500000, kind: TxKind.atm)), 'Cash');
      expect(never.categoryOf(_tx('pbz', 'Isplata ATM', 'ATM', -500000)), 'Cash', reason: 'the old PBZ rule reads the same setting');
    });

    test('fee: Bank fees (the existing fee category), also for a bank whose fee rows said nothing before', () {
      expect(cz.categoryOf(_tx('revolut', 'Fee', 'Plan fee', -299)), 'Shopping', reason: 'no hint');
      expect(cz.categoryOf(_tx('revolut', 'Fee', 'Plan fee', -299, kind: TxKind.fee)), 'Bank fees');
      expect(cz.categoryOf(_tx('revolut', 'Fee', 'Fee refund', 299, kind: TxKind.fee)), 'Bank fees');
      expect(cz.categoryOf(_tx('pbz', 'Pripisane kamate', 'Interest', 12, kind: TxKind.fee)), 'Bank fees');
    });

    test('ownTransfer: Internal transfer without any text rule', () {
      expect(cz.categoryOf(_tx('pbz', 'Plaćanje putem direktnih kanala', 'To my other account', -10000)), 'Bills & one-offs');
      expect(cz.categoryOf(_tx('pbz', 'Plaćanje putem direktnih kanala', 'To my other account', -10000, kind: TxKind.ownTransfer)),
          'Internal transfer');
      expect(cz.categoryOf(_tx('bankx', 'XFER', 'Savings pot', 10000, kind: TxKind.ownTransfer)), 'Internal transfer');
      expect(kindOf(cz.categoryOf(_tx('bankx', 'XFER', 'Savings pot', 10000, kind: TxKind.ownTransfer))), Kind.transfer);
      expect(cz.categoryOf(_tx('revolut', 'Exchange', 'Exchanged to USD', -10000, kind: TxKind.exchange)), 'Internal transfer');
      expect(cz.categoryOf(_tx('bankx', 'FX', 'Exchanged to USD', -10000, kind: TxKind.exchange)), 'Internal transfer',
          reason: 'exchange: Internal transfer by the hint alone, without any text rule');
    });

    test('standingOrder keeps the pattern-based category: it says how, not what', () {
      expect(cz.categoryOf(_tx('pbz', 'Trajni nalog', 'Naplata kredita 0000', -25000, kind: TxKind.standingOrder)), 'Loan');
      expect(cz.categoryOf(_tx('revolut', 'Standing order', 'Netflix', -1299, kind: TxKind.standingOrder)), 'Bills & subscriptions');
      expect(cz.categoryOf(_tx('revolut', 'Standing order', 'Example Landlord', -50000, kind: TxKind.standingOrder)), 'Shopping');
      expect(cz.categoryOf(_tx('revolut', 'Standing order', 'Example Landlord', -50000)), 'Shopping', reason: 'same as without the hint');
    });

    test('card, other and no hint: the description rules as before', () {
      for (final k in [TxKind.card, TxKind.other, null]) {
        expect(cz.categoryOf(_tx('pbz', 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA', -2340, kind: k)), 'Groceries', reason: '$k');
        expect(cz.categoryOf(_tx('pbz', 'POS plaćanje', 'POS UNKNOWN SHOP', -2340, kind: k)), 'Shopping', reason: '$k');
        expect(cz.categoryOf(_tx('revolut', 'Card Payment', 'Wolt', -1500, kind: k)), 'Food delivery', reason: '$k');
        expect(cz.categoryOf(_tx('revolut', 'Transfer', 'Some Person', -1500, kind: k)), 'To people', reason: '$k');
        expect(cz.categoryOf(_tx('pbz', 'Isplata ATM', 'ATM', -55000, kind: k)), 'Rent', reason: '$k: the PBZ type rule still works');
      }
    });

    test('merchant patterns (user and built-in) still decide card rows', () {
      final withPattern = Categorizer(patterns: [
        ['Eating out', 'corner spot']
      ]);
      expect(withPattern.categoryOf(_tx('revolut', 'Card Payment', 'Corner Spot 12', -800, kind: TxKind.card)), 'Eating out');
      expect(withPattern.categoryOf(_tx('revolut', 'Card Payment', 'Decathlon', -800, kind: TxKind.card)), 'Sport & fitness');
    });

    test('the user override and per-merchant rules keep their place around the hint', () {
      // Override first.
      expect(cz.categoryOf(_tx('revolut', 'Fee', 'Plan fee', -299, kind: TxKind.fee, category: 'Shopping')), 'Shopping');
      expect(cz.categoryOf(_tx('revolut', 'ATM', 'ATM', -60000, kind: TxKind.atm, category: 'Cash')), 'Cash');
      // Per-merchant rule: applies to flex/fixed results (a hinted Cash row), not to income or transfers.
      final cash = _tx('revolut', 'ATM', 'ATM Example', -1000, kind: TxKind.atm);
      final ruled = Categorizer(merchantRules: {merchantKey(cash): 'Shopping'});
      expect(ruled.categoryOf(cash), 'Shopping');
      final pay = _tx('revolut', 'Transfer', 'ATM Example', 1000, kind: TxKind.salary);
      expect(Categorizer(merchantRules: {merchantKey(pay): 'Shopping'}).categoryOf(pay), 'Salary');
      final own = _tx('revolut', 'Transfer', 'ATM Example', 1000, kind: TxKind.ownTransfer);
      expect(Categorizer(merchantRules: {merchantKey(own): 'Shopping'}).categoryOf(own), 'Internal transfer');
    });

    test('a paired transfer (transferTo) wins over the hint and the text; the user override still wins over it', () {
      expect(cz.categoryOf(_tx('pbz', 'POS plaćanje', 'PBZ POS PBZ7LIDL', -2340, kind: TxKind.card, transferTo: 'other')),
          'Internal transfer');
      expect(cz.categoryOf(_tx('revolut', 'Transfer', 'Someone', 2340, kind: TxKind.salary, transferTo: 'other')), 'Internal transfer');
      expect(cz.categoryOf(_tx('revolut', 'Transfer', 'Someone', 2340, transferTo: 'other', category: 'Extra income')), 'Extra income');
    });

    test('the existing fixture categorizes as before (no hints)', () {
      expect(january.transactions.map((t) => t.kindHint).toSet(), {null});
      final cats = [
        for (final x in january.transactions)
          cz.categoryOf(Tx.fromRow({
            'id': x.id,
            'source': x.source,
            'date': x.date,
            'amount': x.amountMinor,
            'bank_type': x.bankType,
            'description': x.description
          }))
      ];
      expect(cats, ['Salary', 'Rent', 'Internal transfer', 'Groceries', 'Loan', 'Bank fees', 'Extra income']);
    });
  });

  group('kind_hint storage', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('importBatch stores the hint name; account is never stored', () {
      r.importBatch(ImportBatch(source: 'revolut', transactions: [
        _hinted('2026-02-01', -299, 'Fee', 'Plan fee', TxKind.fee, source: 'revolut', account: 'LT00 0000 0000 0000 0000'),
        _hinted('2026-02-02', -1500, 'Card Payment', 'Wolt', TxKind.card, source: 'revolut', account: 'LT00 0000 0000 0000 0000'),
        _hinted('2026-02-03', -2000, 'Odd', 'Unknown row', null, source: 'revolut'),
      ]));
      final byAmount = {for (final t in r.transactions()) t.amount: t};
      expect(byAmount[-299]!.kindHint, TxKind.fee);
      expect(byAmount[-1500]!.kindHint, TxKind.card);
      expect(byAmount[-2000]!.kindHint, isNull);
      expect(r.db.select('SELECT kind_hint FROM tx WHERE amount = -299').first['kind_hint'], 'fee');
      final cols = {for (final c in r.db.select('PRAGMA table_info(tx)')) c['name'] as String};
      expect(cols, isNot(contains('account')));
      final everything = r.db.select('SELECT * FROM tx').map((row) => row.values.join(' ')).join(' ');
      expect(everything, isNot(contains('LT00')));
      final ops = r.pendingOps().map((o) => o.$2.fields.keys).expand((k) => k).toSet();
      expect(ops, isNot(contains('account')));
      expect(ops, contains('kind_hint'));
      expect(r.categorizer().categoryOf(byAmount[-299]!), 'Bank fees');
    });

    test('a re-import does not rewrite the hint; a hint from a newer importer reads as null', () {
      final batch =
          ImportBatch(source: 'revolut', transactions: [_hinted('2026-02-01', -299, 'Fee', 'Plan fee', TxKind.fee, source: 'revolut')]);
      r.importBatch(batch);
      final before = r.pendingOps().length;
      r.importBatch(batch);
      expect(r.pendingOps().length, before);
      r.db.execute("UPDATE tx SET kind_hint = 'teleport'");
      expect(r.transactions().single.kindHint, isNull);
      expect(r.categorizer().categoryOf(r.transactions().single), 'Shopping', reason: 'falls back to the text rules');
    });

    test('the hint syncs as text; a wrong-typed value is refused with its clock', () {
      final hlc = const Hlc(1700000000000, 0, 'peerdevice').toString();
      r.applyRemote([
        Op('tx', 'x1', {'source': 'revolut', 'date': '2026-02-01', 'amount': -299, 'kind_hint': 'fee'}, hlc),
        Op('tx', 'x2', {'source': 'revolut', 'date': '2026-02-01', 'amount': -300, 'kind_hint': 7}, hlc),
      ]);
      expect(r.transaction('x1')!.kindHint, TxKind.fee);
      expect(r.transaction('x2')!.kindHint, isNull);
      expect(r.db.select("SELECT 1 FROM clocks WHERE id = 'x2' AND field = 'kind_hint'"), isEmpty);
    });
  });

  group('schema', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('bw-kind-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a database from the previous build gains kind_hint and transfer_to and replays peer files once', () {
      final path = '${tmp.path}/old.db';
      final r = WalletRepo.open(path);
      r.importBatch(january);
      r.markPeerFile('peer', '0000000001.bwop');
      r.close();
      final db = sqlite3.open(path);
      db.execute('ALTER TABLE tx DROP COLUMN kind_hint');
      db.execute('ALTER TABLE tx DROP COLUMN transfer_to');
      db.execute("UPDATE meta SET value = '2' WHERE key = 'schema'");
      db.close();
      final again = WalletRepo.open(path);
      addTearDown(again.close);
      final cols = {for (final c in again.db.select('PRAGMA table_info(tx)')) c['name'] as String};
      expect(cols, containsAll(entityTables['tx']!.$2));
      expect(again.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
      expect(bookkeeping(again)['peer_files'], 0, reason: 'the older build dropped kind_hint from the ops it read');
      expect(again.transactions().length, january.transactions.length);
      expect(again.transactions().map((t) => t.kindHint).toSet(), {null});
    });
  });
}
