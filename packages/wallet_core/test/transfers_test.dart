// Own transfers between accounts (D2): an outflow in one source matched by an equal inflow in another within 3 days
// becomes an Internal transfer on both sides, deterministically, so devices converge. All data is SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

Tx _row(String id, String source, String date, int amount,
        {String currency = 'EUR', String? transferTo, bool deleted = false, bool manual = false, TxKind? kind}) =>
    Tx(
        id: id,
        source: source,
        date: date,
        amount: amount,
        currency: currency,
        bankType: 'Other',
        description: 'synthetic',
        transferTo: transferTo,
        deleted: deleted,
        manual: manual,
        kindHint: kind);

Map<String, String?> _plan(List<Tx> rows) => planTransfers(rows).transferTo;

/// Rows after applying [plan] to [rows] (what the repo would store).
List<Tx> _apply(List<Tx> rows, Map<String, String?> plan) => [
      for (final t in rows)
        plan.containsKey(t.id)
            ? _row(t.id, t.source, t.date, t.amount,
                currency: t.currency, transferTo: plan[t.id], deleted: t.deleted, manual: t.manual, kind: t.kindHint)
            : t
    ];

void main() {
  group('planTransfers', () {
    test('an outflow in one source and the equal inflow in another pair, both ways round', () {
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-11', 10000)]), {'a': 'b', 'b': 'a'});
      expect(_plan([_row('a', 'revolut', '2026-01-10', -10000), _row('b', 'pbz', '2026-01-11', 10000)]), {'a': 'b', 'b': 'a'});
      expect(planTransfers([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-11', 10000)]).paired, 1);
    });

    test('no pair within one source, across currencies, for unequal amounts, zero, manual or deleted rows', () {
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'pbz', '2026-01-11', 10000)]), isEmpty);
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-11', 10000, currency: 'USD')]), isEmpty);
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-11', 10001)]), isEmpty);
      expect(_plan([_row('a', 'pbz', '2026-01-10', 0), _row('b', 'revolut', '2026-01-11', 0)]), isEmpty);
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'manual', '2026-01-11', 10000, manual: true)]), isEmpty);
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-11', 10000, deleted: true)]), isEmpty);
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', 'not a date', 10000)]), isEmpty);
    });

    test('3 days apart pairs (inclusive), 4 does not, in either direction of time', () {
      expect(transferDays, 3);
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-13', 10000)]), {'a': 'b', 'b': 'a'});
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-14', 10000)]), isEmpty);
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-07', 10000)]), {'a': 'b', 'b': 'a'});
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-06', 10000)]), isEmpty);
      // Across a month end.
      expect(_plan([_row('a', 'pbz', '2026-01-31', -10000), _row('b', 'revolut', '2026-02-03', 10000)]), {'a': 'b', 'b': 'a'});
    });

    test('ambiguity is resolved the same way whatever the input order', () {
      // One outflow, two inflows: the closest in days wins; same distance: the earlier date; same date: the smaller id.
      final closest = [
        _row('a', 'pbz', '2026-01-10', -10000),
        _row('b2', 'revolut', '2026-01-12', 10000),
        _row('b1', 'revolut', '2026-01-11', 10000)
      ];
      expect(_plan(closest), {'a': 'b1', 'b1': 'a'});
      final earlier = [
        _row('a', 'pbz', '2026-01-10', -10000),
        _row('b2', 'revolut', '2026-01-12', 10000),
        _row('b1', 'revolut', '2026-01-08', 10000)
      ];
      expect(_plan(earlier), {'a': 'b1', 'b1': 'a'});
      final sameDay = [
        _row('a', 'pbz', '2026-01-10', -10000),
        _row('b2', 'revolut', '2026-01-11', 10000),
        _row('b1', 'revolut', '2026-01-11', 10000)
      ];
      expect(_plan(sameDay), {'a': 'b1', 'b1': 'a'});
      // Two outflows, one inflow: the earliest outflow (date, then id) chooses first.
      final twoOut = [
        _row('a2', 'pbz', '2026-01-12', -10000),
        _row('b', 'revolut', '2026-01-12', 10000),
        _row('a1', 'pbz', '2026-01-10', -10000)
      ];
      expect(_plan(twoOut), {'a1': 'b', 'b': 'a1'});
      // Three sources, each row pairs at most once.
      final three = [
        _row('a', 'pbz', '2026-01-10', -10000),
        _row('b', 'revolut', '2026-01-10', 10000),
        _row('c', 'bankx', '2026-01-10', 10000),
        _row('d', 'revolut', '2026-01-10', -10000),
      ];
      expect(_plan(three), {'a': 'b', 'b': 'a', 'd': 'c', 'c': 'd'}, reason: 'a takes the smaller id, d the one left');
      for (final rows in [closest, earlier, sameDay, twoOut, three]) {
        for (var seed = 0; seed < 5; seed++) {
          expect(_plan([...rows]..shuffle(Random(seed))), _plan(rows), reason: 'seed $seed');
        }
      }
    });

    test('applying the plan gives a state whose plan is empty; a kept pair is never re-planned', () {
      final rows = [
        _row('a', 'pbz', '2026-01-10', -10000),
        _row('b', 'revolut', '2026-01-11', 10000),
        _row('c', 'revolut', '2026-01-10', 10000), // closer, but arrives after the pair was written
      ];
      final paired = _apply(rows.sublist(0, 2), _plan(rows.sublist(0, 2)));
      expect(_plan(paired), isEmpty);
      expect(_plan([...paired, rows[2]]), isEmpty, reason: 'a holding pair stays; the new row waits for a partner of its own');
    });

    test('a hinted own transfer needs no partner but may be one', () {
      final alone = _row('a', 'revolut', '2026-01-10', -10000, kind: TxKind.ownTransfer);
      expect(_plan([alone]), isEmpty);
      expect(Categorizer().categoryOf(alone), 'Internal transfer');
      expect(_plan([alone, _row('b', 'pbz', '2026-01-10', 10000)]), {'a': 'b', 'b': 'a'});
    });

    test('a partner that is deleted, manual or points elsewhere reopens the row; one not here yet keeps it', () {
      final a = _row('a', 'pbz', '2026-01-10', -10000, transferTo: 'b');
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a', deleted: true)]), {'a': null});
      expect(_plan([a, _row('b', 'manual', '2026-01-11', 10000, transferTo: 'a', manual: true)]), {'a': null});
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'z')]), {'a': null},
          reason: 'b holds to z, not here: b is kept');
      expect(_plan([a]), isEmpty, reason: 'b has not arrived: keep the link');
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a')]), isEmpty);
      expect(_plan([_row('s', 'pbz', '2026-01-10', -10000, transferTo: 's')]), {'s': null}, reason: 'a row linked to itself is open');
    });

    test('a reopened row takes a new partner at once', () {
      final rows = [
        _row('a', 'pbz', '2026-01-10', -10000, transferTo: 'b'),
        _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a', deleted: true),
        _row('c', 'revolut', '2026-01-12', 10000),
      ];
      expect(_plan(rows), {'a': 'c', 'c': 'a'});
    });

    test('openTransfers lists exactly the rows the plan may touch', () {
      final rows = [
        _row('a', 'pbz', '2026-01-10', -10000, transferTo: 'b'),
        _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a'),
        _row('c', 'revolut', '2026-01-12', 10000),
        _row('d', 'pbz', '2026-01-12', -10000, deleted: true),
      ];
      expect(openTransfers(rows).map((t) => t.id), ['c']);
    });
  });

  group('WalletRepo', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    final pbz = ImportBatch(source: 'pbz', transactions: [
      n('2026-03-02', -20000, 'Plaćanje putem direktnih kanala', 'TRANSFER TO OTHER ACCOUNT'),
      n('2026-03-05', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
    ]);
    final rev = ImportBatch(source: 'revolut', transactions: [
      n('2026-03-03', 20000, 'Transfer', 'From Example Account', source: 'revolut'),
      n('2026-03-04', -1500, 'Card Payment', 'Wolt', source: 'revolut'),
    ]);

    Map<int, String> cats() => {for (final t in r.transactions()) t.amount: r.categorizer().categoryOf(t)};

    test('an import pairs the two sides and both read as Internal transfer', () {
      expect(r.importBatch(pbz).transfers, 0);
      expect(cats()[-20000], 'Bills & one-offs');
      expect(r.importBatch(rev).transfers, 1);
      final byAmount = {for (final t in r.transactions()) t.amount: t};
      expect(byAmount[-20000]!.transferTo, byAmount[20000]!.id);
      expect(byAmount[20000]!.transferTo, byAmount[-20000]!.id);
      expect(cats(), {-20000: 'Internal transfer', 20000: 'Internal transfer', -2340: 'Groceries', -1500: 'Food delivery'});
      expect(r.transactions().where((t) => t.transferTo != null).length, 2);
    });

    test('a re-import never double-matches or writes again', () {
      r.importBatch(pbz);
      r.importBatch(rev);
      final before = r.pendingOps().length;
      expect(r.importBatch(pbz).transfers, 0);
      expect(r.importBatch(rev).transfers, 0);
      expect(r.pendingOps().length, before, reason: 'nothing to write');
      expect(dump(r, clocks: false)['tx']!.where((row) => row['transfer_to'] != null).length, 2);
    });

    test('deleting one side reopens the other, which pairs again with a later row', () {
      r.importBatch(pbz);
      r.importBatch(rev);
      final inflow = r.transactions().firstWhere((t) => t.amount == 20000);
      r.deleteTransaction(inflow.id);
      final outflow = r.transactions().firstWhere((t) => t.amount == -20000);
      expect(outflow.transferTo, isNull);
      expect(cats()[-20000], 'Bills & one-offs');
      final again = r.importBatch(ImportBatch(source: 'revolut', transactions: [
        n('2026-03-01', 20000, 'Transfer', 'From Example Account again', source: 'revolut'),
      ]));
      expect(again.transfers, 1);
      expect(cats()[-20000], 'Internal transfer');
      expect(r.transactions().firstWhere((t) => t.amount == -20000).transferTo, isNot(inflow.id));
    });

    test('the user override still wins; a paired row is not a cash entry\'s payment', () {
      r.importBatch(pbz);
      r.importBatch(rev);
      final outflow = r.transactions().firstWhere((t) => t.amount == -20000);
      r.setCategory(outflow.id, 'To people');
      expect(cats()[-20000], 'To people');
      r.setCategory(outflow.id, null);
      // A hand-added 200.00 expense next to the pair: the paired row is a transfer, so the entry keeps counting.
      r.addManual(date: '2026-03-02', amount: 20000, category: 'Shopping');
      final other = WalletRepo.inMemory();
      addTearDown(other.close);
      other.addManual(date: '2026-03-02', amount: 20000, category: 'Shopping');
      other.importBatch(pbz);
      Tx entry() => other.transactions(includeHidden: true).where((t) => t.manual).single;
      expect(entry().matchedTo, isNotNull, reason: 'unpaired, the row is a payment');
      expect(entry().live, isFalse);
      other.importBatch(rev);
      expect(entry().matchedTo, isNull, reason: 'paired: the entry counts again instead of vanishing with the transfer');
      expect(entry().live, isTrue);
    });

    test('one source alone writes nothing even with equal opposite amounts', () {
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-03-02', -20000, 'Ostalo', 'OUT'),
        n('2026-03-02', 20000, 'Ostalo', 'IN'),
      ]));
      expect(r.transactions().where((t) => t.transferTo != null), isEmpty);
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var now = 1767225600000;
    final devices = <Device>[];

    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => now);
      devices.add(d);
      return d;
    }

    Future<void> round() async {
      for (final d in devices) {
        now += 1000;
        d.deliver(net, Random(1));
        await d.run();
        d.upload(net);
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-transfers-');
      key = VaultKey.generate();
      net = Net();
      devices.clear();
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      tmp.deleteSync(recursive: true);
    });

    final pbz = ImportBatch(source: 'pbz', transactions: [
      n('2026-03-02', -20000, 'Plaćanje putem direktnih kanala', 'TRANSFER TO OTHER ACCOUNT'),
      n('2026-03-06', -20000, 'Plaćanje putem direktnih kanala', 'TRANSFER TO OTHER ACCOUNT'),
      n('2026-03-05', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
    ]);
    final rev = ImportBatch(source: 'revolut', transactions: [
      n('2026-03-03', 20000, 'Transfer', 'From Example Account', source: 'revolut'),
      n('2026-03-04', 20000, 'Transfer', 'From Example Account', source: 'revolut'),
      n('2026-03-04', -1500, 'Card Payment', 'Wolt', source: 'revolut'),
    ]);

    Map<String, String?> links(WalletRepo r) => {for (final t in r.transactions(includeHidden: true)) t.id: t.transferTo};

    test('each device imports one bank: both pair the same rows after sync and then write nothing more', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(pbz);
      b.repo.importBatch(rev);
      expect(links(a.repo).values.toSet(), {null});
      await round();
      await round();
      await round();
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
      final la = links(a.repo);
      expect(la.values.where((v) => v != null).length, 4, reason: 'two pairs');
      for (final e in la.entries) {
        if (e.value != null) expect(la[e.value], e.key, reason: 'links are mutual');
      }
      expect(a.repo.transactions().where((t) => a.repo.categorizer().categoryOf(t) == 'Internal transfer').length, 4);
      final quiet = await a.run();
      expect(quiet.sent, 0, reason: 'a converged device has nothing to write');
      expect((await b.run()).sent, 0);
    });

    test('both devices import both banks offline: the same pairs, no rewrite war', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(pbz);
      a.repo.importBatch(rev);
      b.repo.importBatch(rev);
      b.repo.importBatch(pbz);
      expect(links(a.repo), links(b.repo), reason: 'deterministic: same rows, same pairs, in any import order');
      await round();
      await round();
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
      expect((await a.run()).sent, 0);
      expect((await b.run()).sent, 0);
    });

    test('a delete on one device reopens the partner on both', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(pbz);
      a.repo.importBatch(rev);
      await round();
      await round();
      final inflow = b.repo.transactions().firstWhere((t) => t.amount == 20000 && t.date == '2026-03-03');
      final partner = inflow.transferTo!;
      b.repo.deleteTransaction(inflow.id);
      await round();
      await round();
      expect(a.repo.transaction(partner)!.transferTo, isNull);
      expect(b.repo.transaction(partner)!.transferTo, isNull);
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
      final ops = await opsInNet(net, key);
      expect(lwwDiff(a.repo, lastWriterWins(ops)), isEmpty);
    });
  });
}
