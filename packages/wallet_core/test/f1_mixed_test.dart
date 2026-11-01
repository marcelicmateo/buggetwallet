// F1: old-API and new-API devices in one sync group, and incoming bad ops (FIELDS_PLAN.md "What does not change").
// Two-device sim from test/support/sim.dart. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

const _t0 = 1791590400000; // 2026-10-10 00:00 UTC

void main() {
  late Net net;
  late VaultKey key;
  var ca = _t0, cb = _t0;
  late Device a, b;

  setUp(() {
    ca = _t0;
    cb = _t0;
    net = Net();
    key = VaultKey.generate();
    a = Device('A', null, key, () => ca, net: net); // old API surface
    b = Device('B', null, key, () => cb, net: net); // new API surface (patch)
  });
  tearDown(() {
    a.close();
    b.close();
  });

  Future<void> settle() async {
    await a.run();
    await b.run();
    await a.run();
    await b.run();
  }

  Future<String> seeded() async {
    final (id, _) = a.repo.importBill(const NormalizedBill(
        source: BillSource.hub3,
        externalId: 'hub3:f1mixed',
        date: '2026-10-01',
        dueDate: '2026-10-20',
        total: 4599,
        payee: 'Synthetic Shop'));
    a.repo.updateBill(id, returnBy: '2026-11-30', returnReminderDays: 3);
    await settle();
    expect(b.repo.bill(id)!.returnBy, '2026-11-30');
    return id;
  }

  Map<String, Object?> row(Device d, String id) => Map.of(d.repo.db.select('SELECT * FROM bills WHERE id = ?', [id]).single);

  test('edits through updateBill on A and patch on B reach each other and converge', () async {
    final id = await seeded();
    ca += 1000;
    a.repo.updateBill(id, note: 'from A', warrantyReminderDays: 45, clearDueDate: true);
    cb += 2000;
    b.repo.patch('bill', id, <Col, Object?>{BillCols.payee: 'Renamed By B', BillCols.returnReminderDays: 12, BillCols.total: 5100});
    await settle();
    for (final d in [a, b]) {
      final x = d.repo.bill(id)!;
      expect((
        x.note,
        x.warrantyReminderDays,
        x.dueDate,
        x.payee,
        x.returnReminderDays,
        x.total
      ), (
        'from A',
        45,
        null,
        'Renamed By B',
        12,
        5100
      ), reason: d.name);
    }
    expect(row(a, id), row(b, id));
  });

  test('clear on A (old API) later than set on B (patch): the later HLC wins, both devices end with none', () async {
    final id = await seeded();
    cb += 1000;
    b.repo.patch('bill', id, <Col, Object?>{BillCols.returnBy: '2026-12-24', BillCols.returnReminderDays: 9});
    ca += 5000;
    a.repo.updateBill(id, clearReturnBy: true, clearReturnReminderDays: true);
    await settle();
    for (final d in [a, b]) {
      expect((d.repo.bill(id)!.returnBy, d.repo.bill(id)!.returnReminderDays), (null, null), reason: d.name);
    }
    expect(row(a, id), row(b, id));
  });

  test('set on A (old API) later than clear on B (patch): the later HLC wins, both devices end with the value', () async {
    final id = await seeded();
    cb += 1000;
    b.repo.patch('bill', id, <Col, Object?>{BillCols.returnBy: clearValue, BillCols.returnReminderDays: clearValue});
    ca += 5000;
    a.repo.updateBill(id, returnBy: '2026-12-24', returnReminderDays: 9);
    await settle();
    for (final d in [a, b]) {
      expect((d.repo.bill(id)!.returnBy, d.repo.bill(id)!.returnReminderDays), ('2026-12-24', 9), reason: d.name);
    }
    expect(row(a, id), row(b, id));
  });

  test('clear on B (patch) later than set on A (old API): the later HLC wins', () async {
    final id = await seeded();
    ca += 1000;
    a.repo.updateBill(id, returnBy: '2026-12-24');
    cb += 5000;
    b.repo.patch('bill', id, <Col, Object?>{BillCols.returnBy: clearValue});
    await settle();
    expect(a.repo.bill(id)!.returnBy, isNull);
    expect(b.repo.bill(id)!.returnBy, isNull);
  });

  test('accounts: updateAccount on A and patch on B, different fields, converge', () async {
    final id = await a.repo.addAccount(name: 'Wallet', currency: 'EUR', opening: 1000, openingDate: '2026-09-30');
    await settle();
    ca += 1000;
    await a.repo.updateAccount(id, name: 'Pocket');
    cb += 1000;
    b.repo.patch('account', id, <Col, Object?>{AccountCols.institution: 'Synthetic Bank', AccountCols.kind: AccountKind.other});
    await settle();
    for (final d in [a, b]) {
      final x = d.repo.accounts().singleWhere((e) => e.id == id);
      expect((x.name, x.institution, x.kind), ('Pocket', 'Synthetic Bank', AccountKind.other), reason: d.name);
    }
  });

  group('incoming ops with a bad value are skipped for that field only', () {
    late WalletRepo target;
    late String billId;
    late Op lastBillOp;
    setUp(() {
      target = WalletRepo.inMemory(now: () => _t0);
      final (id, _) = a.repo.importBill(const NormalizedBill(
          source: BillSource.hub3,
          externalId: 'hub3:f1bad',
          date: '2026-10-01',
          dueDate: '2026-10-20',
          total: 4599,
          payee: 'Synthetic Shop'));
      billId = id;
      ca += 1000;
      a.repo.updateBill(id, payee: 'Later Shop'); // a later HLC than the import
      final ops = a.repo.pendingOps().map((e) => e.$2).toList();
      lastBillOp = ops.last;
      target.applyRemote(ops.sublist(0, ops.length - 1));
    });
    tearDown(() => target.close());

    test('bill: wrong types and null on a non-nullable are dropped, the valid fields apply', () {
      expect(target.bill(billId)!.payee, 'Synthetic Shop');
      target.applyRemote([
        Op(
            'bill',
            billId,
            {'payee': 'Remote Shop', 'total': 'abc', 'return_reminder_days': 'x', 'due_date': 7, 'status': null, 'note': 'ok'},
            lastBillOp.hlc),
      ]);
      final x = target.bill(billId)!;
      expect((x.payee, x.note), ('Remote Shop', 'ok'));
      expect(x.total, 4599, reason: 'text in an integer column is not applied');
      expect(x.dueDate, '2026-10-20');
      expect(x.returnReminderDays, isNull);
      expect(x.status, BillStatus.review, reason: 'null on a non-nullable column is not applied');
    });

    test('account: the same', () async {
      final id = await a.repo.addAccount(name: 'Wallet', currency: 'EUR', opening: 1000, openingDate: '2026-09-30');
      ca += 1000;
      await a.repo.updateAccount(id, institution: 'Later Bank');
      final ops = a.repo.pendingOps().map((e) => e.$2).where((o) => o.entity == 'account').toList();
      target.applyRemote(ops.sublist(0, ops.length - 1));
      expect(target.accounts().single.name, 'Wallet');
      target.applyRemote([
        Op('account', id, {'name': null, 'opening': 'x', 'opening_date': 5, 'institution': 'Remote Bank'}, ops.last.hlc),
      ]);
      final x = target.accounts().single;
      expect((x.name, x.opening, x.openingDate, x.institution), ('Wallet', 1000, '2026-09-30', 'Remote Bank'));
    });

    test('an op whose every field is bad leaves no row behind', () {
      target.applyRemote([
        Op('bill', 'bill:ghost', {'total': 'abc', 'return_reminder_days': 'x'}, lastBillOp.hlc),
      ]);
      expect(target.bill('bill:ghost'), isNull);
    });
  });
}
