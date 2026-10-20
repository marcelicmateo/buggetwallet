// Own transfers between accounts (D2): a row the bank marks as an own transfer (`kindHint == ownTransfer`) and the
// equal, opposite row in another source within 3 days become one Internal transfer, deterministically, so devices
// converge. Money is never reclassified on amount alone: two unhinted rows never pair. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const own = TxKind.ownTransfer;

Tx _row(String id, String source, String date, int amount,
        {String currency = 'EUR',
        String? transferTo,
        bool deleted = false,
        bool manual = false,
        TxKind? kind,
        String type = 'Other',
        String desc = 'synthetic'}) =>
    Tx(
        id: id,
        source: source,
        date: date,
        amount: amount,
        currency: currency,
        bankType: type,
        description: desc,
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

/// What an earlier build's amount-only rule wrote: both rows linked, through the repo's own change log (a row update,
/// its field clock and an outbox op), so the pair syncs like any other write.
void _oldBuildPair(WalletRepo r, String a, String b) {
  for (final (id, to) in [(a, b), (b, a)]) {
    final op = Op('tx', id, {'transfer_to': to}, r.clock.tick().toString());
    r.db.execute('UPDATE tx SET transfer_to = ? WHERE id = ?', [to, id]);
    r.db.execute('INSERT OR REPLACE INTO clocks(entity, id, field, hlc) VALUES(?, ?, ?, ?)', ['tx', id, 'transfer_to', op.hlc]);
    r.db.execute('INSERT INTO outbox(op) VALUES(?)', [jsonEncode(op.toJson())]);
  }
}

void main() {
  group('planTransfers', () {
    test('a hinted own transfer and the equal opposite row in another source pair, whichever side carries the hint', () {
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000, kind: own), _row('b', 'revolut', '2026-01-11', 10000)]), {'a': 'b', 'b': 'a'});
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-11', 10000, kind: own)]), {'a': 'b', 'b': 'a'});
      expect(_plan([_row('a', 'revolut', '2026-01-10', -10000, kind: own), _row('b', 'pbz', '2026-01-11', 10000, kind: own)]),
          {'a': 'b', 'b': 'a'});
      expect(planTransfers([_row('a', 'pbz', '2026-01-10', -10000, kind: own), _row('b', 'revolut', '2026-01-11', 10000)]).paired, 1);
    });

    test('two rows without a hint never pair, whatever the amounts and dates (a card payment and a friend\'s 50 €)', () {
      final card = _row('a', 'pbz', '2026-01-10', -5000, kind: TxKind.card, type: 'POS plaćanje', desc: 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB');
      final friend = _row('b', 'revolut', '2026-01-12', 5000, kind: TxKind.other, type: 'Transfer', desc: 'From A Friend');
      expect(_plan([card, friend]), isEmpty);
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000), _row('b', 'revolut', '2026-01-10', 10000)]), isEmpty,
          reason: 'same day, no hint');
      final other = _row('a', 'pbz', '2026-01-10', -10000, kind: TxKind.other);
      expect(_plan([other, _row('b', 'revolut', '2026-01-11', 10000, kind: TxKind.card)]), isEmpty,
          reason: 'hints other than ownTransfer are no evidence');
      final cz = Categorizer();
      expect(cz.categoryOf(card), 'Groceries');
      expect(cz.categoryOf(friend), isNot('Internal transfer'));
    });

    test('no pair within one source, across currencies, for unequal amounts, zero, manual or deleted rows', () {
      final a = _row('a', 'pbz', '2026-01-10', -10000, kind: own);
      expect(_plan([a, _row('b', 'pbz', '2026-01-11', 10000)]), isEmpty);
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10000, currency: 'USD')]), isEmpty);
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10001)]), isEmpty);
      expect(_plan([_row('a', 'pbz', '2026-01-10', 0, kind: own), _row('b', 'revolut', '2026-01-11', 0)]), isEmpty);
      expect(_plan([a, _row('b', 'manual', '2026-01-11', 10000, manual: true)]), isEmpty);
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10000, deleted: true)]), isEmpty);
      expect(_plan([a, _row('b', 'revolut', 'not a date', 10000)]), isEmpty);
    });

    test('3 days apart pairs (inclusive), 4 does not, in either direction of time', () {
      expect(transferDays, 3);
      final a = _row('a', 'pbz', '2026-01-10', -10000, kind: own);
      expect(_plan([a, _row('b', 'revolut', '2026-01-13', 10000)]), {'a': 'b', 'b': 'a'});
      expect(_plan([a, _row('b', 'revolut', '2026-01-14', 10000)]), isEmpty);
      expect(_plan([a, _row('b', 'revolut', '2026-01-07', 10000)]), {'a': 'b', 'b': 'a'});
      expect(_plan([a, _row('b', 'revolut', '2026-01-06', 10000)]), isEmpty);
      // Across a month end.
      expect(_plan([_row('a', 'pbz', '2026-01-31', -10000, kind: own), _row('b', 'revolut', '2026-02-03', 10000)]), {'a': 'b', 'b': 'a'});
    });

    test('ambiguity is resolved the same way whatever the input order', () {
      // One hinted outflow, two equal inflows: the closest in days wins; same distance: the earlier date; same date:
      // the smaller id.
      final closest = [
        _row('a', 'pbz', '2026-01-10', -10000, kind: own),
        _row('b2', 'revolut', '2026-01-12', 10000),
        _row('b1', 'revolut', '2026-01-11', 10000)
      ];
      expect(_plan(closest), {'a': 'b1', 'b1': 'a'});
      final earlier = [
        _row('a', 'pbz', '2026-01-10', -10000, kind: own),
        _row('b2', 'revolut', '2026-01-12', 10000),
        _row('b1', 'revolut', '2026-01-08', 10000)
      ];
      expect(_plan(earlier), {'a': 'b1', 'b1': 'a'});
      final sameDay = [
        _row('a', 'pbz', '2026-01-10', -10000, kind: own),
        _row('b2', 'revolut', '2026-01-11', 10000),
        _row('b1', 'revolut', '2026-01-11', 10000)
      ];
      expect(_plan(sameDay), {'a': 'b1', 'b1': 'a'});
      // One hinted inflow, two equal outflows: the earliest outflow (date, then id) chooses first.
      final twoOut = [
        _row('a2', 'pbz', '2026-01-12', -10000),
        _row('b', 'revolut', '2026-01-12', 10000, kind: own),
        _row('a1', 'pbz', '2026-01-10', -10000)
      ];
      expect(_plan(twoOut), {'a1': 'b', 'b': 'a1'});
      // The hint decides who may pair: an unhinted outflow in between is passed over.
      final skipUnhinted = [
        _row('a1', 'pbz', '2026-01-10', -10000),
        _row('a2', 'pbz', '2026-01-11', -10000, kind: own),
        _row('b', 'bankx', '2026-01-12', 10000),
      ];
      expect(_plan(skipUnhinted), {'a2': 'b', 'b': 'a2'});
      // Three sources, each row pairs at most once.
      final three = [
        _row('a', 'pbz', '2026-01-10', -10000, kind: own),
        _row('b', 'revolut', '2026-01-10', 10000, kind: own),
        _row('c', 'bankx', '2026-01-10', 10000),
        _row('d', 'revolut', '2026-01-10', -10000, kind: own),
      ];
      expect(_plan(three), {'a': 'b', 'b': 'a', 'd': 'c', 'c': 'd'}, reason: 'a takes the smaller id, d the one left');
      for (final rows in [closest, earlier, sameDay, twoOut, skipUnhinted, three]) {
        for (var seed = 0; seed < 5; seed++) {
          expect(_plan([...rows]..shuffle(Random(seed))), _plan(rows), reason: 'seed $seed');
        }
      }
    });

    test('applying the plan gives a state whose plan is empty; a kept pair is never re-planned', () {
      final rows = [
        _row('a', 'pbz', '2026-01-10', -10000, kind: own),
        _row('b', 'revolut', '2026-01-11', 10000),
        _row('c', 'revolut', '2026-01-10', 10000), // closer, but arrives after the pair was written
      ];
      final paired = _apply(rows.sublist(0, 2), _plan(rows.sublist(0, 2)));
      expect(_plan(paired), isEmpty);
      expect(_plan([...paired, rows[2]]), isEmpty, reason: 'a holding pair stays; the new row waits for a partner of its own');
    });

    test('a hinted own transfer needs no partner but may be one; an unhinted row is never hidden alone', () {
      final alone = _row('a', 'revolut', '2026-01-10', -10000, kind: own);
      expect(_plan([alone]), isEmpty);
      expect(Categorizer().categoryOf(alone), 'Internal transfer');
      expect(_plan([alone, _row('b', 'pbz', '2026-01-10', 10000)]), {'a': 'b', 'b': 'a'});
      final plain = _row('p', 'pbz', '2026-01-10', -10000);
      expect(_plan([plain]), isEmpty);
      expect(Categorizer().categoryOf(plain), isNot('Internal transfer'));
    });

    test('an exchange leg never anchors a pair: it stays Internal transfer by its hint, the equal PBZ row stays open', () {
      final fx = _row('a', 'revolut', '2026-01-10', -10000, kind: TxKind.exchange, type: 'Exchange');
      final inflow = _row('b', 'pbz', '2026-01-11', 10000);
      expect(_plan([fx, inflow]), isEmpty);
      expect(_plan([_row('a', 'revolut', '2026-01-10', 10000, kind: TxKind.exchange), _row('b', 'pbz', '2026-01-12', -10000)]), isEmpty);
      expect(Categorizer().categoryOf(fx), 'Internal transfer');
      expect(Categorizer().categoryOf(inflow), isNot('Internal transfer'));
      expect(_plan([fx, inflow, _row('c', 'bankx', '2026-01-10', -10000, kind: own)]), {'c': 'b', 'b': 'c'},
          reason: 'a hinted own transfer in a third source takes the inflow; the exchange leg stays alone');
    });

    test('a partner that is deleted, manual or points elsewhere reopens the row; one not here yet keeps it', () {
      final a = _row('a', 'pbz', '2026-01-10', -10000, transferTo: 'b', kind: own);
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a', deleted: true)]), {'a': null});
      expect(_plan([a, _row('b', 'manual', '2026-01-11', 10000, transferTo: 'a', manual: true)]), {'a': null});
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'z')]), {'a': null},
          reason: 'b holds to z, not here: b is kept');
      expect(_plan([a]), isEmpty, reason: 'b has not arrived: keep the link');
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a')]), isEmpty);
      expect(_plan([_row('s', 'pbz', '2026-01-10', -10000, transferTo: 's', kind: own)]), {'s': null},
          reason: 'a row linked to itself is open');
    });

    test('a pair with no hint on either side (an earlier build\'s amount-only rule) dissolves; one hinted side holds', () {
      final a = _row('a', 'pbz', '2026-01-10', -10000, transferTo: 'b');
      final b = _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a');
      expect(_plan([a, b]), {'a': null, 'b': null});
      expect(planTransfers([a, b]).reopened, 2);
      expect(planTransfers([a, b]).paired, 0);
      expect(_plan(_apply([a, b], _plan([a, b]))), isEmpty, reason: 'dissolved rows do not pair again');
      expect(_plan([a, _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a', kind: own)]), isEmpty, reason: 'the inflow is hinted');
      expect(_plan([_row('a', 'pbz', '2026-01-10', -10000, transferTo: 'b', kind: own), b]), isEmpty, reason: 'the outflow is hinted');
      expect(_plan([a]), isEmpty, reason: 'the partner has not arrived: the devices holding both decide');
      expect(openTransfers([a, b]).map((t) => t.id), ['a', 'b']);
      for (var seed = 0; seed < 3; seed++) {
        expect(_plan([b, a]..shuffle(Random(seed))), {'a': null, 'b': null});
      }
    });

    test('a dissolved row may pair with a hinted row at once', () {
      final rows = [
        _row('a', 'pbz', '2026-01-10', -10000, transferTo: 'b'),
        _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a'),
        _row('c', 'bankx', '2026-01-12', 10000, kind: own),
      ];
      expect(_plan(rows), {'a': 'c', 'c': 'a', 'b': null});
    });

    test('a reopened row takes a new partner at once', () {
      final rows = [
        _row('a', 'pbz', '2026-01-10', -10000, transferTo: 'b', kind: own),
        _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a', deleted: true),
        _row('c', 'revolut', '2026-01-12', 10000),
      ];
      expect(_plan(rows), {'a': 'c', 'c': 'a'});
    });

    test('openTransfers lists exactly the rows the plan may touch', () {
      final rows = [
        _row('a', 'pbz', '2026-01-10', -10000, transferTo: 'b', kind: own),
        _row('b', 'revolut', '2026-01-11', 10000, transferTo: 'a'),
        _row('c', 'revolut', '2026-01-12', 10000),
        _row('d', 'pbz', '2026-01-12', -10000, deleted: true),
        _row('e', 'pbz', '2026-01-20', -7000, transferTo: 'f'),
        _row('f', 'revolut', '2026-01-20', 7000, transferTo: 'e'),
      ];
      expect(openTransfers(rows).map((t) => t.id), ['c', 'e', 'f'], reason: 'the hinted pair a/b holds, the unhinted e/f is open');
    });
  });

  group('WalletRepo', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    // The PBZ side is unhinted (a bank payment the bank does not mark); the Revolut side is the bank's "Topup".
    final pbz = ImportBatch(source: 'pbz', transactions: [
      n('2026-03-02', -20000, 'Plaćanje putem direktnih kanala', 'TRANSFER TO OTHER ACCOUNT', kind: TxKind.other),
      n('2026-03-05', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', kind: TxKind.card),
    ]);
    final rev = ImportBatch(source: 'revolut', transactions: [
      n('2026-03-03', 20000, 'Topup', 'Top-Up by *0000', source: 'revolut', kind: own),
      n('2026-03-04', -1500, 'Card Payment', 'Wolt', source: 'revolut', kind: TxKind.card),
    ]);
    // No hint on either side: the same amounts two days apart, unrelated.
    final loosePbz = ImportBatch(source: 'pbz', transactions: [
      n('2026-03-02', -20000, 'Plaćanje putem direktnih kanala', 'TRANSFER TO OTHER ACCOUNT', kind: TxKind.other),
    ]);
    final looseRev = ImportBatch(source: 'revolut', transactions: [
      n('2026-03-03', 20000, 'Transfer', 'From A Friend', source: 'revolut', kind: TxKind.other),
    ]);

    Map<int, String> cats() => {for (final t in r.transactions()) t.amount: r.categorizer().categoryOf(t)};
    Map<String, String?> links() => {for (final t in r.transactions(includeHidden: true)) t.id: t.transferTo};

    test('an import pairs the hinted top-up with its PBZ side and both read as Internal transfer', () {
      expect(r.importBatch(pbz).transfers, 0);
      expect(cats()[-20000], 'Bills & one-offs');
      expect(r.importBatch(rev).transfers, 1);
      final byAmount = {for (final t in r.transactions()) t.amount: t};
      expect(byAmount[-20000]!.transferTo, byAmount[20000]!.id);
      expect(byAmount[20000]!.transferTo, byAmount[-20000]!.id);
      expect(cats(), {-20000: 'Internal transfer', 20000: 'Internal transfer', -2340: 'Groceries', -1500: 'Food delivery'});
      expect(r.transactions().where((t) => t.transferTo != null).length, 2);
    });

    test('a card payment and an unrelated equal inflow two days later stay spending on both sides', () {
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-03-02', -5000, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', kind: TxKind.card),
      ]));
      final s = r.importBatch(ImportBatch(source: 'revolut', transactions: [
        n('2026-03-04', 5000, 'Transfer', 'From A Friend', source: 'revolut', kind: TxKind.other),
      ]));
      expect(s.transfers, 0);
      expect(links().values.toSet(), {null});
      expect(cats()[-5000], 'Groceries');
      expect(cats()[5000], isNot('Internal transfer'));
      expect(r.transactions().length, 2, reason: 'nothing hidden');
    });

    test('a re-import never double-matches or writes again', () {
      r.importBatch(pbz);
      r.importBatch(rev);
      final before = r.pendingOps().length;
      expect(r.importBatch(pbz).transfers, 0);
      expect(r.importBatch(rev).transfers, 0);
      expect(r.pendingOps().length, before, reason: 'nothing to write');
      expect(dump(r, clocks: false)['tx']!.where((row) => row['transfer_to'] != null).length, 2);
      // The same for rows that never pair.
      r.importBatch(loosePbz);
      r.importBatch(looseRev);
      final again = r.pendingOps().length;
      r.importBatch(looseRev);
      r.importBatch(loosePbz);
      expect(r.pendingOps().length, again);
    });

    test('deleting one side reopens the other, which pairs again with a later hinted row', () {
      r.importBatch(pbz);
      r.importBatch(rev);
      final inflow = r.transactions().firstWhere((t) => t.amount == 20000);
      r.deleteTransaction(inflow.id);
      final outflow = r.transactions().firstWhere((t) => t.amount == -20000);
      expect(outflow.transferTo, isNull);
      expect(cats()[-20000], 'Bills & one-offs');
      final again = r.importBatch(ImportBatch(source: 'revolut', transactions: [
        n('2026-03-01', 20000, 'Topup', 'Top-Up by *0000 again', source: 'revolut', kind: own),
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

    test('a pair an earlier build made on amount alone dissolves when the plan runs; the cash entry it displaced matches again', () {
      r.addManual(date: '2026-03-02', amount: 20000, category: 'Shopping');
      r.importBatch(loosePbz);
      r.importBatch(looseRev);
      Tx entry() => r.transactions(includeHidden: true).where((t) => t.manual).single;
      final out = r.transactions().firstWhere((t) => t.amount == -20000), inn = r.transactions().firstWhere((t) => t.amount == 20000);
      expect(entry().matchedTo, out.id);
      expect(links(), {out.id: null, inn.id: null, entry().id: null});
      // The old pair arrives from another device (the clear it gets here is written through the change log, so it syncs).
      final hlc = r.clock.tick().toString();
      final changed = r.applyRemote([
        Op('tx', out.id, {'transfer_to': inn.id}, hlc),
        Op('tx', inn.id, {'transfer_to': out.id}, hlc)
      ]);
      expect(changed, 2);
      expect(links(), {out.id: null, inn.id: null, entry().id: null}, reason: 'dissolved at once');
      expect(cats()[-20000], 'Shopping', reason: 'a payment again: it carries the cash entry\'s category, as before the pairing');
      expect(cats()[20000], isNot('Internal transfer'));
      final cleared = r.pendingOps().where((o) => o.$2.fields.containsKey('transfer_to')).toList();
      expect(cleared.map((o) => (o.$2.id, o.$2.fields['transfer_to'])).toSet(), {(out.id, null), (inn.id, null)});
      expect(entry().matchedTo, out.id, reason: 'the bank row is a payment again, so the entry stays replaced by it');
      expect(entry().live, isFalse);
      final before = r.pendingOps().length;
      r.importBatch(loosePbz);
      expect(r.pendingOps().length, before, reason: 'converged: the next plan writes nothing');
    });

    test('a Revolut Exchange with an equal PBZ inflow within 3 days stays unpaired and Internal transfer', () {
      r.importBatch(ImportBatch(source: 'revolut', transactions: [
        n('2026-03-02', -10000, 'Exchange', 'Exchanged to USD', source: 'revolut', kind: TxKind.exchange),
      ]));
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-03-04', 10000, 'Ostalo', 'VAL_01.01.2026.POVRAT', kind: TxKind.other),
      ]));
      expect(s.transfers, 0);
      expect(links().values.toSet(), {null});
      expect(cats()[-10000], 'Internal transfer');
      expect(cats()[10000], isNot('Internal transfer'));
    });

    test('one source alone writes nothing even with equal opposite amounts and a hint', () {
      r.importBatch(ImportBatch(source: 'revolut', transactions: [
        n('2026-03-02', -20000, 'Transfer', 'OUT', source: 'revolut', kind: TxKind.other),
        n('2026-03-02', 20000, 'Topup', 'IN', source: 'revolut', kind: own),
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
      n('2026-03-02', -20000, 'Plaćanje putem direktnih kanala', 'TRANSFER TO OTHER ACCOUNT', kind: TxKind.other),
      n('2026-03-06', -20000, 'Plaćanje putem direktnih kanala', 'TRANSFER TO OTHER ACCOUNT', kind: TxKind.other),
      n('2026-03-05', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', kind: TxKind.card),
    ]);
    final rev = ImportBatch(source: 'revolut', transactions: [
      n('2026-03-03', 20000, 'Topup', 'Top-Up by *0000', source: 'revolut', kind: own),
      n('2026-03-04', 20000, 'Topup', 'Top-Up by *0000', source: 'revolut', kind: own),
      n('2026-03-04', -1500, 'Card Payment', 'Wolt', source: 'revolut', kind: TxKind.card),
    ]);
    final looseRev = ImportBatch(source: 'revolut', transactions: [
      n('2026-03-03', 20000, 'Transfer', 'From A Friend', source: 'revolut', kind: TxKind.other),
      n('2026-03-04', 20000, 'Transfer', 'From Another Friend', source: 'revolut', kind: TxKind.other),
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

    test('unhinted equal rows in two banks never pair, on either device, in any import order', () async {
      final a = device('a'), b = device('b');
      a.repo.importBatch(pbz);
      b.repo.importBatch(looseRev);
      await round();
      await round();
      await round();
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
      expect(links(a.repo).values.toSet(), {null});
      expect(a.repo.transactions().where((t) => a.repo.categorizer().categoryOf(t) == 'Internal transfer'), isEmpty);
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

    test('a pair an earlier build made on amount alone dissolves on every device and they converge', () async {
      // Three devices hold the same unhinted rows; `old` pairs them the way the earlier build did and syncs that.
      final a = device('a'), b = device('b'), old = device('old');
      for (final d in devices) {
        d.repo.importBatch(pbz);
        d.repo.importBatch(looseRev);
      }
      await round();
      await round();
      expect(links(a.repo).values.toSet(), {null});
      final out = old.repo.transactions().firstWhere((t) => t.amount == -20000 && t.date == '2026-03-02');
      final inn = old.repo.transactions().firstWhere((t) => t.amount == 20000 && t.date == '2026-03-03');
      _oldBuildPair(old.repo, out.id, inn.id);
      expect(old.repo.transaction(out.id)!.transferTo, inn.id);
      await round(); // old exports the pair; a and b apply it and dissolve it at once
      await round();
      await round();
      for (final d in devices) {
        expect(d.repo.transaction(out.id)!.transferTo, isNull, reason: d.name);
        expect(d.repo.transaction(inn.id)!.transferTo, isNull, reason: d.name);
        expect(d.repo.categorizer().categoryOf(d.repo.transaction(out.id)!), 'Bills & one-offs', reason: d.name);
        expect(d.repo.transactions().where((t) => d.repo.categorizer().categoryOf(t) == 'Internal transfer'), isEmpty, reason: d.name);
      }
      expect(dump(a.repo, clocks: false), dump(b.repo, clocks: false));
      expect(dump(a.repo, clocks: false), dump(old.repo, clocks: false));
      for (final d in devices) {
        expect((await d.run()).sent, 0, reason: '${d.name} has nothing more to write');
      }
      final ops = await opsInNet(net, key);
      expect(lwwDiff(a.repo, lastWriterWins(ops)), isEmpty, reason: 'the clear is a synced write, not a local fix-up');
    });
  });
}
