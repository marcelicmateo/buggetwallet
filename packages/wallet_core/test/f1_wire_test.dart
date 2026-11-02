// F1 (field refactor pilot, docs/context/FIELDS_PLAN.md "API fixed for F1" / "What does not change"): the wire.
// Written from the spec and from the 09d5d8e code paths (updateBill / updateAccount), not from the new code.
// The expected ops are LITERAL data: entity, id, field names, values, one op per edit. Both the old surface
// (updateBill / updateAccount named params) and the new one (repo.patch with BillCols / AccountCols) must give them.
// Assumed names (spec): BillCols.{date,dueDate,total,payee,category,note,warrantyUntil,returnBy,returnReminderDays,
// warrantyReminderDays}, AccountCols.{name,opening,openingDate,kind,source,institution}, clearValue, repo.patch.
// All data SYNTHETIC.
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart' show entitySchema, schemaSql;
import 'package:wallet_core/wallet_core.dart';

const _now = 1791590400000; // 2026-10-10 00:00 UTC

typedef _Edit = void Function(WalletRepo r, String id);
typedef _AEdit = Future<void> Function(WalletRepo r, String id);

String _norm(String sql) => sql.replaceAll(RegExp(r'\s+'), ' ').replaceAll('( ', '(').trim();

class _BillCase {
  final String name;
  final _Edit viaOld, viaPatch;
  final Map<String, Object?> wire;
  const _BillCase(this.name, this.viaOld, this.viaPatch, this.wire);
}

class _AccCase {
  final String name;
  final bool bank; // start from a bank account (pbz, institution) instead of a cash account
  final _AEdit viaOld, viaPatch;
  final Map<String, Object?> wire;
  const _AccCase(this.name, this.bank, this.viaOld, this.viaPatch, this.wire);
}

void main() {
  late WalletRepo repo;
  setUp(() => repo = WalletRepo.inMemory(now: () => _now));
  tearDown(() => repo.close());

  // A review bill; the first edit gives it values to change and to clear, so every case below changes something.
  String bill(WalletRepo r) {
    final (id, _) = r.importBill(const NormalizedBill(
        source: BillSource.hub3,
        externalId: 'hub3:f1wire',
        date: '2026-10-01',
        dueDate: '2026-10-20',
        total: 4599,
        payee: 'Synthetic Shop'));
    r.updateBill(id,
        category: 'Groceries',
        warrantyUntil: '2026-12-31',
        returnBy: '2026-11-30',
        returnReminderDays: 3,
        warrantyReminderDays: 10,
        note: 'first');
    return id;
  }

  final billCases = <_BillCase>[
    _BillCase('date', (r, id) => r.updateBill(id, date: '2026-09-15'),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.date: '2026-09-15'}), {'date': '2026-09-15'}),
    _BillCase('due date set', (r, id) => r.updateBill(id, dueDate: '2026-11-02'),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.dueDate: '2026-11-02'}), {'due_date': '2026-11-02'}),
    _BillCase('due date cleared', (r, id) => r.updateBill(id, clearDueDate: true),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.dueDate: clearValue}), {'due_date': null}),
    _BillCase('total', (r, id) => r.updateBill(id, total: 5000), (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.total: 5000}),
        {'total': 5000}),
    _BillCase('payee', (r, id) => r.updateBill(id, payee: 'Other Shop'),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.payee: 'Other Shop'}), {'payee': 'Other Shop'}),
    _BillCase('note', (r, id) => r.updateBill(id, note: 'second'), (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.note: 'second'}),
        {'note': 'second'}),
    _BillCase('category set', (r, id) => r.updateBill(id, category: 'Fuel'),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.category: 'Fuel'}), {'category': 'Fuel'}),
    _BillCase('category cleared', (r, id) => r.updateBill(id, clearCategory: true),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.category: clearValue}), {'category': null}),
    _BillCase('warranty set', (r, id) => r.updateBill(id, warrantyUntil: '2027-01-31'),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.warrantyUntil: '2027-01-31'}), {'warranty_until': '2027-01-31'}),
    _BillCase('warranty cleared', (r, id) => r.updateBill(id, clearWarranty: true),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.warrantyUntil: clearValue}), {'warranty_until': null}),
    _BillCase('return by set', (r, id) => r.updateBill(id, returnBy: '2026-12-15'),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.returnBy: '2026-12-15'}), {'return_by': '2026-12-15'}),
    _BillCase('return by cleared', (r, id) => r.updateBill(id, clearReturnBy: true),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.returnBy: clearValue}), {'return_by': null}),
    _BillCase('return reminder 7', (r, id) => r.updateBill(id, returnReminderDays: 7),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.returnReminderDays: 7}), {'return_reminder_days': 7}),
    _BillCase('return reminder at the top (30)', (r, id) => r.updateBill(id, returnReminderDays: 30),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.returnReminderDays: 30}), {'return_reminder_days': 30}),
    _BillCase('return reminder 0 is a value, not a clear', (r, id) => r.updateBill(id, returnReminderDays: 0),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.returnReminderDays: 0}), {'return_reminder_days': 0}),
    _BillCase('return reminder cleared', (r, id) => r.updateBill(id, clearReturnReminderDays: true),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.returnReminderDays: clearValue}), {'return_reminder_days': null}),
    _BillCase('warranty reminder at the top (90)', (r, id) => r.updateBill(id, warrantyReminderDays: 90),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.warrantyReminderDays: 90}), {'warranty_reminder_days': 90}),
    _BillCase('warranty reminder cleared', (r, id) => r.updateBill(id, clearWarrantyReminderDays: true),
        (r, id) => r.patch('bill', id, <Col, Object?>{BillCols.warrantyReminderDays: clearValue}), {'warranty_reminder_days': null}),
    _BillCase(
        'several fields are one op',
        (r, id) => r.updateBill(id, date: '2026-09-20', total: 1250, clearDueDate: true, returnReminderDays: 0, note: 'many'),
        (r, id) => r.patch('bill', id, <Col, Object?>{
              BillCols.date: '2026-09-20',
              BillCols.dueDate: clearValue,
              BillCols.total: 1250,
              BillCols.note: 'many',
              BillCols.returnReminderDays: 0,
            }),
        // 09d5d8e's updateBill order (date, due_date, total, …, note, …, return_reminder_days); patch keeps the map's.
        {'date': '2026-09-20', 'due_date': null, 'total': 1250, 'note': 'many', 'return_reminder_days': 0}),
  ];

  group('bill edits: the op on the wire is the one 09d5d8e sent', () {
    for (final c in billCases) {
      for (final surface in ['updateBill', 'patch']) {
        test('${c.name} via $surface', () {
          final id = bill(repo);
          final before = repo.pendingOps().length;
          (surface == 'patch' ? c.viaPatch : c.viaOld)(repo, id);
          final fresh = repo.pendingOps().skip(before).map((e) => e.$2).toList();
          expect(fresh, hasLength(1), reason: 'one op per edit');
          expect(fresh.single.entity, 'bill');
          expect(fresh.single.id, id);
          expect(fresh.single.fields, c.wire, reason: 'field names and values');
          expect(fresh.single.fields.keys.toList(), c.wire.keys.toList(), reason: 'field order on the wire');
          expect(fresh.single.toJson().keys.toSet(), {'e', 'id', 'f', 'h'});
          expect(fresh.single.hlc, isNotEmpty);
        });
      }
    }
  });

  final accCases = <_AccCase>[
    _AccCase('name', false, (r, id) => r.updateAccount(id, name: 'Pocket'),
        (r, id) async => r.patch('account', id, <Col, Object?>{AccountCols.name: 'Pocket'}), {'name': 'Pocket'}),
    _AccCase(
        'institution set',
        false,
        (r, id) => r.updateAccount(id, institution: 'Synthetic Bank'),
        (r, id) async => r.patch('account', id, <Col, Object?>{AccountCols.institution: 'Synthetic Bank'}),
        {'institution': 'Synthetic Bank'}),
    _AccCase('institution cleared', true, (r, id) => r.updateAccount(id, institution: ''),
        (r, id) async => r.patch('account', id, <Col, Object?>{AccountCols.institution: clearValue}), {'institution': null}),
    _AccCase(
        'opening and its date travel as one pair',
        false,
        (r, id) => r.updateAccount(id, opening: 2500, openingDate: '2026-09-29'),
        (r, id) async => r.patch('account', id, <Col, Object?>{AccountCols.opening: 2500, AccountCols.openingDate: '2026-09-29'}),
        {'opening': 2500, 'opening_date': '2026-09-29'}),
    _AccCase('opening alone via updateAccount: the date is written with it', false, (r, id) => r.updateAccount(id, opening: -300),
        (r, id) async => r.updateAccount(id, opening: -300), {'opening': -300, 'opening_date': '2026-09-30'}),
    _AccCase('kind only (cash to other)', false, (r, id) => r.updateAccount(id, kind: AccountKind.other),
        (r, id) async => r.patch('account', id, <Col, Object?>{AccountCols.kind: AccountKind.other}), {'kind': 'other'}),
    _AccCase(
        'kind and source given together',
        true,
        (r, id) => r.updateAccount(id, kind: AccountKind.card, source: 'revolut'),
        (r, id) async => r.patch('account', id, <Col, Object?>{AccountCols.kind: AccountKind.card, AccountCols.source: 'revolut'}),
        {'kind': 'card', 'source': 'revolut'}),
    _AccCase(
        'kind and source cleared together',
        true,
        (r, id) => r.updateAccount(id, kind: AccountKind.other, clearSource: true),
        (r, id) async => r.patch('account', id, <Col, Object?>{AccountCols.kind: AccountKind.other, AccountCols.source: clearValue}),
        {'kind': 'other', 'source': null}),
    _AccCase('source change via updateAccount: the kind is written with it', true, (r, id) => r.updateAccount(id, source: 'revolut'),
        (r, id) async => r.updateAccount(id, source: 'revolut'), {'kind': 'bank', 'source': 'revolut'}),
  ];

  group('account edits: the op on the wire is the one 09d5d8e sent', () {
    for (final c in accCases) {
      for (final surface in ['updateAccount', 'patch']) {
        test('${c.name} via $surface', () async {
          final id = c.bank
              ? await repo.addAccount(
                  name: 'Main',
                  source: 'pbz',
                  currency: 'EUR',
                  opening: 1000,
                  openingDate: '2026-09-30',
                  kind: AccountKind.bank,
                  institution: 'Old Bank')
              : await repo.addAccount(name: 'Wallet', currency: 'EUR', opening: 1000, openingDate: '2026-09-30');
          final before = repo.pendingOps().length;
          await (surface == 'patch' ? c.viaPatch : c.viaOld)(repo, id);
          final fresh = repo.pendingOps().skip(before).map((e) => e.$2).toList();
          expect(fresh, hasLength(1), reason: 'one op per edit');
          expect(fresh.single.entity, 'account');
          expect(fresh.single.id, id);
          expect(fresh.single.fields, c.wire);
          expect(fresh.single.fields.keys.toList(), c.wire.keys.toList(), reason: 'field order on the wire');
        });
      }
    }

    test('an account edit that changes nothing writes nothing (old API)', () async {
      final id = await repo.addAccount(name: 'Wallet', currency: 'EUR', opening: 1000, openingDate: '2026-09-30');
      final before = repo.pendingOps().length;
      await repo.updateAccount(id, name: 'Wallet');
      expect(repo.pendingOps().length, before);
    });
  });

  group('DDL unchanged (no schema bump)', () {
    test('schemaSql equals fixtures/schema/v21.sql and the version stays 21', () {
      expect(WalletRepo.schemaVersion, 21);
      expect(_norm(schemaSql), _norm(File('test/fixtures/schema/v21.sql').readAsStringSync()));
    });

    test('bill and account columns keep their names and order', () {
      expect(entitySchema['bill']!.columnNames, [
        'source', 'status', 'external_id', 'date', 'due_date', 'payee', 'iban', 'reference', 'description', 'category', 'note', //
        'total', 'currency', 'items', 'unsure', 'linked_tx', 'warranty_until', 'return_by', 'blob', 'blob_type', 'blob_bytes',
        'deleted', 'attached_tx', 'return_reminder_days', 'warranty_reminder_days',
      ]);
      expect(entitySchema['bill']!.table, 'bills');
      expect(entitySchema['account']!.columnNames,
          ['name', 'source', 'currency', 'opening', 'opening_date', 'deleted', 'kind', 'institution', 'match_key']);
      expect(entitySchema['account']!.table, 'accounts');
    });

    test('BillCols.all / AccountCols.all declare the same columns, each with a label', () {
      expect([for (final c in BillCols.all) c.column], entitySchema['bill']!.columnNames);
      expect([for (final c in AccountCols.all) c.column], entitySchema['account']!.columnNames);
      expect({for (final c in BillCols.all) c.entity}, {'bill'});
      expect({for (final c in AccountCols.all) c.entity}, {'account'});
      for (final c in [...BillCols.all, ...AccountCols.all]) {
        expect(c.label, isNotEmpty, reason: c.column);
      }
    });
  });
}
