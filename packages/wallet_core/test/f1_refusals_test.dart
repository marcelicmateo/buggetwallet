// F1: repo.patch refusals per Col kind, and lenient reads of damaged stored rows (FIELDS_PLAN.md "API fixed for F1").
// A bad value throws ArgumentError('<label>: <problem>') and writes NOTHING (outbox, rows, clocks), also when mixed
// with valid values in the same patch. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _now = 1791590400000; // 2026-10-10 00:00 UTC

class _Bad {
  final String name;
  final String entity;
  final Col col;
  final Object? value;
  const _Bad(this.name, this.entity, this.col, this.value);
}

void main() {
  late WalletRepo repo;
  late String billId, accId;

  setUp(() async {
    repo = WalletRepo.inMemory(now: () => _now);
    final (id, _) = repo.importBill(const NormalizedBill(
        source: BillSource.hub3,
        externalId: 'hub3:f1ref',
        date: '2026-10-01',
        dueDate: '2026-10-20',
        total: 4599,
        payee: 'Synthetic Shop'));
    billId = id;
    accId = await repo.addAccount(name: 'Wallet', currency: 'EUR', opening: 1000, openingDate: '2026-09-30');
  });
  tearDown(() => repo.close());

  Object snapshot() => [
        for (final t in ['outbox', 'bills', 'accounts', 'planned', 'clocks']) repo.db.select('SELECT * FROM $t').map(Map.of).toList(),
      ];

  String idOf(String entity) => entity == 'bill' ? billId : accId;
  final longText = 'x' * (Account.maxName + 1);

  final bad = <_Bad>[
    // DateCol
    const _Bad('date: day 30 of February', 'bill', BillCols.date, '2026-02-30'),
    const _Bad('date: month 13', 'bill', BillCols.date, '2026-13-01'),
    const _Bad('date: not zero padded', 'bill', BillCols.date, '2026-1-5'),
    const _Bad('date: empty text', 'bill', BillCols.date, ''),
    const _Bad('date: a number', 'bill', BillCols.date, 20261001),
    const _Bad('due date: words', 'bill', BillCols.dueDate, 'tomorrow'),
    const _Bad('warranty until: month 0', 'bill', BillCols.warrantyUntil, '2026-00-10'),
    const _Bad('return by: day-first', 'bill', BillCols.returnBy, '10.11.2026'),
    const _Bad('opening date: day 31 of November', 'account', AccountCols.openingDate, '2026-11-31'),
    const _Bad('opening date: after today', 'account', AccountCols.openingDate, '2026-12-01'),
    // IntCol
    const _Bad('return reminder: above 30', 'bill', BillCols.returnReminderDays, 31),
    const _Bad('return reminder: below 0', 'bill', BillCols.returnReminderDays, -1),
    const _Bad('return reminder: text', 'bill', BillCols.returnReminderDays, '7'),
    const _Bad('return reminder: fraction', 'bill', BillCols.returnReminderDays, 3.5),
    const _Bad('warranty reminder: above 90', 'bill', BillCols.warrantyReminderDays, 91),
    const _Bad('warranty reminder: below 0', 'bill', BillCols.warrantyReminderDays, -1),
    // MoneyCol
    const _Bad('total: over the cap', 'bill', BillCols.total, WalletSettings.maxAmount + 1),
    const _Bad('total: text', 'bill', BillCols.total, '45.99'),
    const _Bad('total: fraction', 'bill', BillCols.total, 45.99),
    const _Bad('total: bool', 'bill', BillCols.total, true),
    const _Bad('opening: over the cap', 'account', AccountCols.opening, WalletSettings.maxAmount + 1),
    const _Bad('opening: below minus the cap', 'account', AccountCols.opening, -WalletSettings.maxAmount - 1),
    const _Bad('opening: text', 'account', AccountCols.opening, 'x'),
    // EnumCol
    const _Bad('kind: unknown wire name', 'account', AccountCols.kind, 'martian'),
    const _Bad('kind: a number', 'account', AccountCols.kind, 3),
    const _Bad('status: unknown wire name', 'bill', BillCols.status, 'martian'),
    const _Bad('status: a number', 'bill', BillCols.status, 7),
    // TextCol
    const _Bad('payee: a number', 'bill', BillCols.payee, 5),
    const _Bad('note: a list', 'bill', BillCols.note, ['a']),
    _Bad('name: too long', 'account', AccountCols.name, longText),
    const _Bad('name: a number', 'account', AccountCols.name, 5),
    _Bad('institution: too long', 'account', AccountCols.institution, longText),
    // non-nullable: null and clearValue
    const _Bad('name: null', 'account', AccountCols.name, null),
    const _Bad('name: clearValue', 'account', AccountCols.name, clearValue),
    const _Bad('opening: clearValue', 'account', AccountCols.opening, clearValue),
    const _Bad('opening date: clearValue', 'account', AccountCols.openingDate, clearValue),
    const _Bad('status: null', 'bill', BillCols.status, null),
    const _Bad('status: clearValue', 'bill', BillCols.status, clearValue),
  ];

  Matcher refusedNaming(Col c) => throwsA(isA<ArgumentError>().having((e) => e.toString(), 'message', contains(c.label)));

  group('a bad value is refused, naming the label, and nothing is written', () {
    for (final b in bad) {
      test(b.name, () {
        expect(b.col.label, isNotEmpty);
        final before = snapshot();
        expect(() => repo.patch(b.entity, idOf(b.entity), <Col, Object?>{b.col: b.value}), refusedNaming(b.col));
        expect(snapshot(), before);
      });

      test('${b.name} (between two valid values)', () {
        final candidates = b.entity == 'bill'
            ? <MapEntry<Col, Object?>>[
                const MapEntry(BillCols.note, 'fine'),
                const MapEntry(BillCols.category, 'Groceries'),
                const MapEntry(BillCols.payee, 'Fine'),
              ]
            : <MapEntry<Col, Object?>>[
                const MapEntry(AccountCols.institution, 'Fine'),
                const MapEntry(AccountCols.name, 'Fine'),
                const MapEntry(AccountCols.opening, 1234),
              ];
        final valid = candidates.where((e) => e.key != b.col).take(2).toList();
        final values = <Col, Object?>{valid[0].key: valid[0].value, b.col: b.value, valid[1].key: valid[1].value};
        final before = snapshot();
        expect(() => repo.patch(b.entity, idOf(b.entity), values), refusedNaming(b.col));
        expect(snapshot(), before, reason: 'the valid values are not written either');
      });
    }
  });

  group('boundaries that are fine', () {
    test('the edge values of each range are accepted and written', () {
      repo.patch('bill', billId, <Col, Object?>{
        BillCols.returnReminderDays: 0,
        BillCols.warrantyReminderDays: 90,
        BillCols.total: WalletSettings.maxAmount,
      });
      final x = repo.bill(billId)!;
      expect((x.returnReminderDays, x.warrantyReminderDays, x.total), (0, 90, WalletSettings.maxAmount));
    });

    test('an account opening may be negative, up to the cap either way', () {
      repo.patch('account', accId, <Col, Object?>{AccountCols.opening: -WalletSettings.maxAmount});
      expect(repo.accounts().single.opening, -WalletSettings.maxAmount);
    });

    test('clearValue on nullable columns writes null', () {
      repo.patch('bill', billId, <Col, Object?>{BillCols.dueDate: clearValue, BillCols.payee: clearValue});
      final x = repo.bill(billId)!;
      expect((x.dueDate, x.payee), (null, null));
    });
  });

  group('account rules stay with the account hook', () {
    test('a source on a cash account is refused and nothing is written', () {
      final before = snapshot();
      expect(() => repo.patch('account', accId, <Col, Object?>{AccountCols.source: 'pbz'}), throwsArgumentError);
      expect(snapshot(), before);
    });

    test('an unknown bank source is refused and nothing is written', () async {
      final bank = await repo.addAccount(
          name: 'Main', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-09-30', kind: AccountKind.bank);
      final before = snapshot();
      expect(() => repo.patch('account', bank, <Col, Object?>{AccountCols.source: 'nosuchbank'}), throwsArgumentError);
      expect(snapshot(), before);
    });
  });

  group('reads are lenient: damaged stored values read as none / default, the lists still load', () {
    test('bill: junk in return_reminder_days, warranty_reminder_days and total', () {
      repo.db.execute("UPDATE bills SET return_reminder_days = 'x', warranty_reminder_days = 99, total = 'junk' WHERE id = ?", [billId]);
      final x = repo.bill(billId)!;
      expect(x.returnReminderDays, isNull);
      expect(x.warrantyReminderDays, isNull);
      expect(x.total, isNull);
      expect(repo.bills().map((b) => b.id), contains(billId));
      expect(x[BillCols.returnReminderDays], isNull, reason: 'the generic read agrees');
    });

    test('bill: unknown status', () {
      repo.db.execute("UPDATE bills SET status = 'martian' WHERE id = ?", [billId]);
      expect(repo.bills().map((b) => b.id), contains(billId));
      expect(repo.bill(billId), isNotNull);
    });

    test('account: unknown kind falls back to the one the source implies (none: cash)', () {
      repo.db.execute("UPDATE accounts SET kind = 'martian' WHERE id = ?", [accId]);
      expect(repo.accounts().single.kind, AccountKind.cash);
    });

    test('account: junk in opening and opening_date does not stop the list', () {
      repo.db.execute("UPDATE accounts SET opening = 'x', opening_date = 5 WHERE id = ?", [accId]);
      expect(repo.accounts().map((a) => a.id), contains(accId));
    });

    test('Col.read of a row map: a bad value is null / default, never throws', () {
      expect(BillCols.returnReminderDays.read({'return_reminder_days': 'x'}), isNull);
      expect(BillCols.returnReminderDays.read({'return_reminder_days': 99}), isNull);
      expect(BillCols.returnReminderDays.read({'return_reminder_days': 12}), 12);
      expect(BillCols.dueDate.read({'due_date': '2026-02-30'}), isNull);
      expect(BillCols.dueDate.read({'due_date': '2026-11-02'}), '2026-11-02');
      expect(BillCols.total.read({'total': 'junk'}), isNull);
      expect(AccountCols.kind.read({'kind': 'martian'}), isNull);
      expect(AccountCols.kind.read({'kind': 'crypto'}), AccountKind.crypto);
      expect(BillCols.dueDate.read(const {}), isNull);
    });
  });
}
