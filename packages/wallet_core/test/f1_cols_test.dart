// F1 (FIELDS_PLAN.md "API fixed for F1"): the Col kinds (problem, lenient read, encode, DDL), repo.patch (one op,
// clearValue, refusals write nothing, the same op as updateBill / updateAccount) and the done check: a test-only
// entity whose new column is one Col line gets DDL, the sync type check, snapshot, search and patch validation.
// All data SYNTHETIC.
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart' show addTestEntity, ColumnDef, ColumnType, EntityDef, entitySchema, schemaSql;
import 'package:wallet_core/wallet_core.dart';

const _now = 1791590400000; // 2026-10-10 00:00 UTC

enum _Size { small, large }

/// The done check's test-only entity. [colour] is "the new field": this one line is all it takes.
abstract final class _GadgetCols {
  static const entity = 'gadget';
  static const name = TextCol(entity, 'name', label: 'Name', searchable: true, maxLength: 20);
  static const price = MoneyCol(entity, 'price', label: 'Price', nullable: true, searchable: true);
  static const size = EnumCol(entity, 'size', label: 'Size', values: _Size.values, defaultValue: _Size.small, wire: {_Size.large: 'L'});
  static const deleted = FlagCol(entity, 'deleted', label: 'Deleted');
  static const colour = TextCol(entity, 'colour', label: 'Colour', nullable: true, searchable: true, maxLength: 12);
  static const all = <Col>[name, price, size, deleted, colour];
}

String _hlc(int counter) => Hlc(_now, counter, 'peer').toString();

Matcher _refused(String text) => throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', text));

void main() {
  group('Col kinds', () {
    test('TextCol', () {
      const c = TextCol('x', 'note', label: 'Note', nullable: true, maxLength: 3);
      expect(c.def.ddl, 'note TEXT');
      expect(const TextCol('x', 'cur', label: 'C', defaultValue: 'EUR').ddl, "cur TEXT NOT NULL DEFAULT 'EUR'");
      expect(const TextCol('x', 'name', label: 'N').ddl, "name TEXT NOT NULL DEFAULT ''");
      expect((c.problem('abc'), c.problem('abcd'), c.problem('ščž'), c.problem(null)), (null, 'Limited to 3 characters.', null, null));
      expect(const TextCol('x', 'name', label: 'N').problem(null), 'Needs a value.');
      expect((c.read({'note': 'a'}), c.read({'note': 5}), c.read(const {})), ('a', null, null));
      expect(const TextCol('x', 'cur', label: 'C', defaultValue: 'EUR').read({'cur': 7}), 'EUR');
      expect(c.encode('a'), 'a');
      expect((c.column, c.entity, c.type, c.toString()), ('note', 'x', ColumnType.text, 'x.note'));
    });

    test('DateCol', () {
      const c = DateCol('x', 'due', label: 'Due', nullable: true);
      const opening = DateCol('x', 'on', label: 'On', notAfterToday: true);
      expect((c.ddl, opening.ddl), ('due TEXT', "on TEXT NOT NULL DEFAULT ''"));
      expect(c.problem('2026-02-29'), 'Not a real date (YYYY-MM-DD).');
      expect((c.problem('2028-02-29'), c.problem(null)), (null, null));
      expect(opening.problem('2026-10-11', today: '2026-10-10'), 'Cannot be in the future.');
      expect((opening.problem('2026-10-10', today: '2026-10-10'), opening.problem(null)), (null, 'Needs a value.'));
      expect((c.read({'due': '2026-13-01'}), c.read({'due': 3}), c.read({'due': '2026-01-31'})), (null, null, '2026-01-31'));
    });

    test('IntCol', () {
      const c = IntCol('x', 'days', label: 'Days', nullable: true, min: 0, max: 30, unit: 'days before');
      expect((c.ddl, const IntCol('x', 'n', label: 'N', defaultValue: 30).ddl), ('days INTEGER', 'n INTEGER NOT NULL DEFAULT 30'));
      expect((c.problem(-1), c.problem(31), c.problem(0), c.problem(30)), ('0 to 30 days before.', '0 to 30 days before.', null, null));
      expect(const IntCol('x', 'n', label: 'N', min: 1).problem(0), 'At least 1.');
      expect(const IntCol('x', 'n', label: 'N', max: 9).problem(10), 'At most 9.');
      expect((c.read({'days': 31}), c.read({'days': '3'}), c.read({'days': 3})), (null, null, 3));
      expect(const IntCol('x', 'n', label: 'N', defaultValue: 0).read({'n': 'junk'}), 0);
    });

    test('MoneyCol', () {
      const c = MoneyCol('x', 'total', label: 'Total', nullable: true, positive: true);
      const o = MoneyCol('x', 'opening', label: 'Opening', defaultValue: 0);
      expect((c.ddl, o.ddl), ('total INTEGER', 'opening INTEGER NOT NULL DEFAULT 0'));
      expect((c.cap, c.currencyCol), (WalletSettings.maxAmount, 'currency'));
      expect((c.problem(0), c.problem(-5), c.problem(1)), ('Must be more than zero.', 'Must be more than zero.', null));
      expect((o.problem(-WalletSettings.maxAmount), o.problem(WalletSettings.maxAmount + 1)), (null, 'Over the allowed amount.'));
      // The smallest int: abs() of it is itself, so both bounds are checked.
      expect(o.problem(-9223372036854775807 - 1), 'Over the allowed amount.');
      expect((o.read({'opening': 'x'}), c.read({'total': 'x'}), c.read({'total': 12})), (0, null, 12));
    });

    test('FlagCol', () {
      const c = FlagCol('x', 'deleted', label: 'Deleted');
      expect(c.ddl, 'deleted INTEGER NOT NULL DEFAULT 0');
      expect(c.ddl, const ColumnDef.flag('deleted').ddl);
      expect((c.encode(true), c.encode(false)), (1, 0));
      expect((c.read({'deleted': 1}), c.read({'deleted': 0}), c.read({'deleted': 'x'})), (true, false, false));
      expect(c.problem(null), 'Needs a value.');
    });

    test('EnumCol: wire names, unknown words read as the default', () {
      const c = _GadgetCols.size;
      expect(c.ddl, "size TEXT NOT NULL DEFAULT 'small'");
      expect((c.encode(_Size.large), c.encode(_Size.small)), ('L', 'small'));
      expect((c.read({'size': 'L'}), c.read({'size': 'large'}), c.read({'size': 2})), (_Size.large, _Size.small, _Size.small));
      expect(AccountCols.kind.read({'kind': 'martian'}), isNull);
      expect(c.accepts('L'), isFalse);
      expect(c.accepts(_Size.large), isTrue);
    });

    test('RefCol and JsonCol', () {
      const r = RefCol('x', 'tx', label: 'Payment', target: 'tx', nullable: true);
      expect((r.ddl, r.problem(''), r.problem('t1'), r.target), ('tx TEXT', 'Needs an id.', null, 'tx'));
      expect(BillCols.items.ddl, "items TEXT NOT NULL DEFAULT '[]'");
      expect(BillCols.items.problem('[{'), 'Not valid JSON.');
      expect(BillCols.items.problem('[]'), isNull);
      expect(BillCols.items.problem('{"a":1}'), 'Too many items or a name too long.');
      final tooMany = jsonEncode([for (var i = 0; i <= maxBillItems; i++) const BillItem(name: 'x', amount: 1).toJson()]);
      expect(BillCols.items.problem(tooMany), 'Too many items or a name too long.');
    });

    test('bill and account schemas are their Col lists, in table order', () {
      expect(entitySchema['bill']!.columns, same(BillCols.all));
      expect(entitySchema['account']!.columns, same(AccountCols.all));
      for (final c in [...BillCols.all, ...AccountCols.all]) {
        expect(c.label, isNotEmpty, reason: '$c');
        expect(c.entity, anyOf(BillCols.entity, AccountCols.entity));
      }
      expect(BillCols.total.cap, maxAmountCents);
      expect(AccountCols.opening.cap, maxAmountCents);
    });

    test('models read through their Cols; model[col] reads any column', () {
      final b = Bill.fromRow({'id': 'b1', 'source': 'nope', 'status': 'confirmed', 'items': 'damaged', 'return_reminder_days': 99});
      expect((b.source, b.status, b.items.length, b.returnReminderDays, b.currency),
          (BillSource.manual, BillStatus.confirmed, 0, null, 'EUR'));
      expect((b[BillCols.status], b[BillCols.deleted], b[BillCols.unsure]), (BillStatus.confirmed, false, 0));
      final made = Bill(id: 'b2', items: const [BillItem(name: 'Bread', amount: 120)], returnBy: '2026-11-01');
      expect((made.items.single.name, made.returnBy, made[BillCols.returnBy]), ('Bread', '2026-11-01', '2026-11-01'));
      final a = Account(id: 'a', name: 'Main', source: 'pbz', currency: 'EUR', opening: 5, openingDate: '2026-01-01');
      expect((a.kind, a[AccountCols.kind], a.isCash, a.countsRows), (AccountKind.bank, null, false, true));
    });

    test('a typed field is decoded once; the row is a read-only copy', () {
      final source = <String, Object?>{'id': 'b1', 'date': '2026-01-05', 'items': '[{"name":"Bread","amount":120}]'};
      final b = Bill.fromRow(source);
      source['date'] = '2026-02-02';
      expect(b.date, '2026-01-05', reason: 'copied, not a view of the caller map');
      expect(identical(b.items, b.items), isTrue, reason: 'the item list is decoded once, not per read');
      expect(() => b.row['date'] = '2026-03-03', throwsUnsupportedError);
    });
  });

  group('patch', () {
    late WalletRepo repo;
    late String billId;
    setUp(() {
      repo = WalletRepo.inMemory(now: () => _now);
      billId = repo
          .importBill(const NormalizedBill(source: BillSource.hub3, externalId: 'hub3:f1cols', total: 4599, payee: 'Synthetic Shop'))
          .$1;
    });
    tearDown(() => repo.close());

    List<Op> ops() => [for (final (_, o) in repo.pendingOps()) o];
    Object state() => [
          for (final t in ['outbox', 'bills', 'accounts', 'planned', 'clocks']) repo.db.select('SELECT * FROM $t').map(Map.of).toList()
        ];

    test('several fields: one op, one clock, in the order given; clearValue and null set none', () {
      final before = ops().length;
      repo.patch(BillCols.entity, billId, {
        BillCols.note: 'n',
        BillCols.returnBy: '2026-11-30',
        BillCols.payee: clearValue,
        BillCols.returnReminderDays: 5,
        BillCols.iban: null,
      });
      final fresh = ops().skip(before).toList();
      expect(fresh, hasLength(1));
      expect(fresh.single.fields, {'note': 'n', 'return_by': '2026-11-30', 'payee': null, 'return_reminder_days': 5, 'iban': null});
      expect(fresh.single.fields.keys, ['note', 'return_by', 'payee', 'return_reminder_days', 'iban']);
      final b = repo.bill(billId)!;
      expect((b.note, b.returnBy, b.payee, b.returnReminderDays), ('n', '2026-11-30', null, 5));
    });

    test('a bad value anywhere: ArgumentError "<label>: <reason>", nothing written', () {
      final before = state();
      expect(() => repo.patch('bill', billId, {BillCols.note: 'ok', BillCols.dueDate: '2026-02-30'}),
          _refused('Due date: Not a real date (YYYY-MM-DD).'));
      expect(() => repo.patch('bill', billId, {BillCols.total: 0}), _refused('Total: Must be more than zero.'));
      expect(() => repo.patch('bill', billId, {BillCols.returnReminderDays: 31}), _refused('Return reminder: 0 to 30 days before.'));
      expect(() => repo.patch('bill', billId, {BillCols.note: 5}), _refused('Note: wrong kind of value.'));
      expect(() => repo.patch('bill', billId, {AccountCols.name: 'x'}), _refused('Name: not a field of this bill.'));
      expect(() => repo.patch('bill', billId, {BillCols.status: BillStatus.confirmed}),
          _refused('Status: changed by its own action, not edited.'));
      expect(() => repo.patch('bill', billId, {BillCols.deleted: true}), _refused('Deleted: changed by its own action, not edited.'));
      expect(() => repo.patch('bill', 'nope', {BillCols.note: 'x'}), _refused('No such bill.'));
      expect(() => repo.patch('nope', billId, {BillCols.note: 'x'}), _refused('Unknown entity.'));
      expect(state(), before);
    });

    test('the bill rules hold: a reserving edit needs a category', () {
      repo.patch('bill', billId, {BillCols.dueDate: '2026-10-20'});
      repo.db.execute("UPDATE bills SET status = 'confirmed' WHERE id = ?", [billId]);
      expect(() => repo.patch('bill', billId, {BillCols.total: 5000}), _refused('The bill needs a category.'));
      repo.patch('bill', billId, {BillCols.total: 5000, BillCols.category: 'Groceries'});
      expect(repo.plannedCosts().single.amount, 5000);
      repo.patch('bill', billId, {BillCols.note: 'no category rule for a note'});
    });

    test('a confirmed bill keeps its total and date: clearing one is refused, nothing written', () {
      repo.patch('bill', billId, {BillCols.date: '2026-10-01', BillCols.dueDate: '2026-10-20', BillCols.category: 'Groceries'});
      repo.confirmBill(billId);
      expect(repo.plannedCosts().single.amount, 4599, reason: 'reserved');
      final before = state();
      for (final clear in [clearValue, null]) {
        expect(() => repo.patch('bill', billId, {BillCols.total: clear}), _refused('Total: needed on a confirmed bill.'));
        expect(() => repo.patch('bill', billId, {BillCols.note: 'n', BillCols.date: clear}), _refused('Date: needed on a confirmed bill.'));
      }
      expect(state(), before);
      repo.updateBill(billId, clearDueDate: true, total: 1); // the due date may go (its planned row with it)
      expect(repo.plannedCosts(), isEmpty);
      // A bill in review may still drop them.
      final (other, _) =
          repo.importBill(const NormalizedBill(source: BillSource.hub3, externalId: 'hub3:f1cols2', total: 100, date: '2026-10-01'));
      repo.patch('bill', other, {BillCols.total: clearValue, BillCols.date: clearValue});
      expect((repo.bill(other)!.total, repo.bill(other)!.date), (null, null));
    });

    test('the same op as updateBill / updateAccount for the same edit', () async {
      final other = WalletRepo.inMemory(now: () => _now, deviceId: repo.deviceId);
      addTearDown(other.close);
      other.importBill(const NormalizedBill(source: BillSource.hub3, externalId: 'hub3:f1cols', total: 4599, payee: 'Synthetic Shop'));
      repo.updateBill(billId, total: 100, note: 'x', clearDueDate: true, warrantyUntil: '2027-01-01', returnReminderDays: 3);
      other.patch('bill', billId, {
        BillCols.dueDate: clearValue,
        BillCols.total: 100,
        BillCols.note: 'x',
        BillCols.warrantyUntil: '2027-01-01',
        BillCols.returnReminderDays: 3,
      });
      final a = await repo.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 1, openingDate: '2026-10-01');
      final a2 = await other.addAccount(name: 'Bank', source: 'pbz', currency: 'EUR', opening: 1, openingDate: '2026-10-01');
      await repo.updateAccount(a, name: ' Main ', opening: 7, clearSource: true, kind: AccountKind.other, institution: '  ');
      other.patch('account', a2, {
        AccountCols.name: ' Main ',
        AccountCols.opening: 7,
        AccountCols.source: clearValue,
        AccountCols.kind: AccountKind.other,
        AccountCols.institution: '  ',
      });
      String wire(WalletRepo r) => jsonEncode([
            for (final o in [for (final (_, o) in r.pendingOps()) o])
              if (o.entity == 'bill') o.toJson()
          ]);
      expect(wire(other), wire(repo));
      Map<String, Object?> lastAccount(WalletRepo r) =>
          [for (final (_, o) in r.pendingOps()) o].lastWhere((o) => o.entity == 'account').fields;
      expect(lastAccount(other), lastAccount(repo));
      expect(lastAccount(repo), {'name': 'Main', 'opening': 7, 'opening_date': '2026-10-01', 'kind': 'other', 'source': null});
    });

    test('account rules and texts', () async {
      final a = await repo.addAccount(name: 'Cash', currency: 'EUR', opening: 0, openingDate: '2026-10-01');
      final before = state();
      expect(() => repo.patch('account', a, {AccountCols.name: '  '}), _refused('Give the account a name.'));
      expect(() => repo.patch('account', a, {AccountCols.name: 'x' * 61}), _refused('Name: Limited to 60 characters.'));
      expect(() => repo.patch('account', a, {AccountCols.openingDate: '2026-10-11'}), _refused('Opening date: Cannot be in the future.'));
      expect(() => repo.patch('account', a, {AccountCols.opening: clearValue}), _refused('Opening balance: Needs a value.'));
      expect(() => repo.patch('account', a, {AccountCols.currency: 'USD'}), throwsArgumentError);
      expect(() => repo.patch('account', a, {AccountCols.source: 'pbz'}),
          _refused('Only a bank, card or savings account can import bank files.'));
      expect(() => repo.patch('account', 'nope', {AccountCols.name: 'x'}), _refused('No such account.'));
      expect(state(), before);
      final n = repo.pendingOps().length;
      repo.patch('account', a, {AccountCols.name: 'Cash'}); // unchanged: no write
      expect(repo.pendingOps().length, n);
    });
  });

  group('done check: a test-only entity', () {
    setUpAll(() => addTestEntity(_GadgetCols.entity, const EntityDef('gadgets', _GadgetCols.all)));

    test('one Col line gives DDL, sync type check, snapshot, search and patch validation', () {
      expect(
          schemaSql,
          contains('CREATE TABLE IF NOT EXISTS gadgets(id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT \'\', price INTEGER, '
              "size TEXT NOT NULL DEFAULT 'small', deleted INTEGER NOT NULL DEFAULT 0, colour TEXT);"));
      final repo = WalletRepo.inMemory(now: () => _now);
      addTearDown(repo.close);
      // Sync: the wrong-typed colour is skipped (no clock), the rest applies.
      repo.applyRemote([
        Op('gadget', 'g1', {'name': 'Lamp', 'colour': 7, 'price': 1500, 'size': 'L'}, _hlc(1))
      ]);
      expect(Map.of(repo.db.select('SELECT * FROM gadgets').single),
          {'id': 'g1', 'name': 'Lamp', 'price': 1500, 'size': 'L', 'deleted': 0, 'colour': null});
      expect(repo.db.select("SELECT field FROM clocks WHERE entity = 'gadget'").map((r) => r['field']), isNot(contains('colour')));
      repo.applyRemote([
        Op('gadget', 'g1', {'price': WalletSettings.maxAmount + 1}, _hlc(2))
      ]); // over the MoneyCol cap
      expect(repo.db.select('SELECT price FROM gadgets').single['price'], 1500);
      // Patch: validated by the new line, written as one op.
      expect(() => repo.patch('gadget', 'g1', {_GadgetCols.colour: 'x' * 13}), _refused('Colour: Limited to 12 characters.'));
      expect(() => repo.patch('gadget', 'g2', {_GadgetCols.colour: 'teal'}), _refused('No such row.'));
      repo.patch('gadget', 'g1', {_GadgetCols.colour: 'Teal', _GadgetCols.size: _Size.small});
      expect(repo.pendingOps().last.$2.fields, {'colour': 'Teal', 'size': 'small'});
      // Snapshot (and so backups) carry it.
      expect(repo.snapshotOps().where((o) => o.entity == 'gadget').expand((o) => o.fields.keys), containsAll(['name', 'colour']));
      // Search looks at it.
      final rows = repo.db.select('SELECT * FROM gadgets').map(Map.of).toList();
      expect(searchableColumns('gadget'), ['name', 'price', 'colour']);
      expect(searchRows('gadget', 'teal', rows).map((r) => r['id']), ['g1']);
      expect(searchRows('gadget', '15', rows).map((r) => r['id']), ['g1']);
      // A row model reads it generically.
      expect(_GadgetCols.colour.read(rows.single), 'Teal');
    });

    test('an existing table gains the new column on open', () {
      const without = EntityDef('gadgets', [_GadgetCols.name, _GadgetCols.price, _GadgetCols.size, _GadgetCols.deleted]);
      addTestEntity(_GadgetCols.entity, without);
      final db = sqlite3.openInMemory();
      WalletRepo.fromDatabase(db, file: false, now: () => _now); // an older build: no colour yet
      List<Object?> columns() => db.select('PRAGMA table_info(gadgets)').map((r) => r['name']).toList();
      expect(columns(), isNot(contains('colour')));
      addTestEntity(_GadgetCols.entity, const EntityDef('gadgets', _GadgetCols.all));
      final repo = WalletRepo.fromDatabase(db, file: false, now: () => _now);
      addTearDown(repo.close);
      expect(columns(), contains('colour'));
      expect(() => addTestEntity('bill', const EntityDef('bills', [])), throwsArgumentError);
    });
  });
}
