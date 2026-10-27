// planMatches: deterministic manual ↔ bank matching. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

Tx _manual(String id, String date, int amount, {String? to, String? category = 'Eating out'}) =>
    Tx(id: id, source: 'manual', date: date, amount: amount, manual: true, matchedTo: to, category: category);
Tx _bank(String id, String date, int amount, {String? category}) =>
    Tx(id: id, source: 'pbz', date: date, amount: amount, bankType: 'POS plaćanje', description: 'POS EXAMPLE', category: category);
bool _all(Tx _) => true;

extension on Tx {
  Tx asManual() => Tx(id: id, source: 'manual', date: date, amount: amount, manual: true);
}

String _h(int millis, [String node = 'n']) => Hlc(millis, 0, node).toString();

/// First-write clocks: every manual entry before every bank row (the usual order: added by hand, then imported).
Map<String, String> _later(List<Tx> manual, List<Tx> bank) => {
      for (final (i, m) in manual.indexed) m.id: _h(100 + i),
      for (final (i, b) in bank.indexed) b.id: _h(1000 + i),
    };
MatchPlan _plan(List<Tx> manual, List<Tx> bank, [bool Function(Tx) eligible = _all]) =>
    planMatches(manual, bank, eligible, _later(manual, bank));

List<Tx> _applied(List<Tx> manual, MatchPlan p) => [
      for (final m in manual)
        p.matchedTo.containsKey(m.id)
            ? Tx(
                id: m.id,
                source: m.source,
                date: m.date,
                amount: m.amount,
                manual: true,
                matchedTo: p.matchedTo[m.id],
                category: m.category)
            : m
    ];

void main() {
  test('closest day wins, then earliest date, then smallest id; one bank row per entry', () {
    final p = _plan(
      [_manual('m1', '2026-01-17', -990), _manual('m2', '2026-01-17', -990)],
      [_bank('b3', '2026-01-19', -990), _bank('b2', '2026-01-16', -990), _bank('b1', '2026-01-18', -990)],
      _all,
    );
    expect(p.matchedTo, {'m1': 'b2', 'm2': 'b1'}); // both 1 day away: the earlier date first
    expect(p.added, 2);
    expect(p.bankCategory, {'b1': 'Eating out', 'b2': 'Eating out'});
  });

  test('a bank row with its own category keeps it; an ineligible row is never used', () {
    final p = _plan([_manual('m1', '2026-01-17', -990)], [_bank('b1', '2026-01-17', -990, category: 'Shopping')], _all);
    expect(p.matchedTo, {'m1': 'b1'});
    expect(p.bankCategory, isEmpty);
    expect(_plan([_manual('m1', '2026-01-17', -990)], [_bank('b1', '2026-01-17', -990)], (_) => false).isEmpty, isTrue);
  });

  test('two entries on one bank row: the smallest id keeps it, the other is unmatched or takes another row', () {
    final manual = [_manual('m2', '2026-01-17', -990, to: 'b1'), _manual('m1', '2026-01-17', -990, to: 'b1')];
    expect(_plan(manual, [_bank('b1', '2026-01-17', -990)], _all).matchedTo, {'m2': null});
    expect(_plan(manual, [_bank('b1', '2026-01-17', -990), _bank('b2', '2026-01-18', -990)], _all).matchedTo, {'m2': 'b2'});
  });

  test('an existing match is kept while its bank row is there', () {
    expect(_plan([_manual('m1', '2026-01-17', -990, to: 'b1')], [_bank('b1', '2026-01-17', -990)], _all).isEmpty, isTrue);
    // Even when that row is no longer eligible or its amount differs (a category or rule changed): still the same pair.
    expect(_plan([_manual('m1', '2026-01-17', -990, to: 'b1')], [_bank('b1', '2026-01-17', -990)], (_) => false).isEmpty, isTrue);
  });

  test('a match whose bank row was deleted (or is not a bank row) is open again, and may take a later bank row', () {
    const gone = Tx(id: 'b1', source: 'pbz', date: '2026-01-17', amount: -990, description: 'POS EXAMPLE', deleted: true);
    for (final bank in [
      [gone], // deleted
      [_bank('b1', '2026-01-17', -990).asManual()], // not a bank row
    ]) {
      expect(_plan([_manual('m1', '2026-01-17', -990, to: 'b1')], bank, _all).matchedTo, {'m1': null}, reason: '$bank');
    }
    expect(_plan([_manual('m1', '2026-01-17', -990, to: 'b1')], [gone, _bank('b2', '2026-01-18', -990)], _all).matchedTo, {'m1': 'b2'});
  });

  test('a match whose bank row has not arrived yet is kept (no unmatch while its sync file is missing)', () {
    expect(_plan([_manual('m1', '2026-01-17', -990, to: 'b1')], [], _all).isEmpty, isTrue);
    // Nor does it take another row meanwhile, and the row it points at stays taken.
    final p = _plan([_manual('m1', '2026-01-17', -990, to: 'b1'), _manual('m2', '2026-01-17', -990, to: 'b1')],
        [_bank('b2', '2026-01-18', -990)], _all);
    expect(p.matchedTo, {'m2': 'b2'}, reason: 'two entries on one row: the second is open, even while the row is missing');
  });

  test('property: the plan does not depend on row order, and applying it gives an empty plan', () {
    final r = Random(fuzzSeed(31));
    for (var i = 0; i < fuzzIterations(300); i++) {
      String date() => addDays('2026-01-10', r.nextInt(12));
      int amount() => -[990, 1500, 2340][r.nextInt(3)];
      final bank = [for (var b = 0; b < r.nextInt(6); b++) _bank('b$b', date(), amount())];
      final manual = [
        for (var m = 0; m < r.nextInt(6); m++)
          _manual('m$m', date(), amount(), to: r.nextInt(4) == 0 && bank.isNotEmpty ? bank[r.nextInt(bank.length)].id : null)
      ];
      // Random first-write clocks on three devices: some bank rows came before their entries, some after.
      final written = {
        for (final t in [...manual, ...bank]) t.id: _h(r.nextInt(20), 'n${r.nextInt(3)}')
      };
      // Some entries record what their device held (any subset of the bank rows), the others are from older builds.
      final seen = {
        for (final m in manual)
          if (r.nextBool())
            m.id: SeenBank.encode([
              for (final b in bank)
                if (r.nextBool()) written[b.id]!
            ])
      };
      final p = planMatches(manual, bank, _all, written, seenBank: seen);
      final q = planMatches([...manual]..shuffle(r), [...bank]..shuffle(r), _all, written, seenBank: seen);
      expect(q.matchedTo, p.matchedTo, reason: 'case $i');
      expect(q.bankCategory, p.bankCategory, reason: 'case $i');
      for (final e in p.matchedTo.entries.where((e) => e.value != null)) {
        expect(SeenBank.of(written[e.key]!, seen[e.key]).unseen(written[e.value]!), isTrue,
            reason: 'case $i: only a bank row the entry\'s device did not hold');
      }
      final after = _applied(manual, p);
      expect(planMatches(after, bank, _all, written, seenBank: seen).matchedTo, isEmpty, reason: 'case $i: not idempotent');
      final targets = after.map((m) => m.matchedTo).whereType<String>().toList();
      expect(targets.toSet().length, targets.length, reason: 'case $i: one bank row per entry');
    }
  });

  test('an entry without seen_bank (older builds): only a bank row first written after it replaces it (HLC order)', () {
    final m = _manual('m1', '2026-01-19', -240);
    final before = _bank('b-before', '2026-01-17', -240), after = _bank('b-after', '2026-01-20', -240);
    // b-before was in the wallet before the entry was added; b-after was imported after it.
    final w = {'b-before': _h(50, 'laptop'), 'm1': _h(60, 'phone'), 'b-after': _h(70, 'laptop')};
    expect(planMatches([m], [before], _all, w).isEmpty, isTrue, reason: 'already in the wallet when the entry was added');
    expect(planMatches([m], [before, after], _all, w).matchedTo, {'m1': 'b-after'});
    // Same millisecond on two devices: the HLC (node breaks the tie) still orders them, the same on every device.
    expect(planMatches([m], [before], _all, {'m1': _h(60, 'a'), 'b-before': _h(60, 'b')}).matchedTo, {'m1': 'b-before'});
    expect(planMatches([m], [before], _all, {'m1': _h(60, 'b'), 'b-before': _h(60, 'a')}).isEmpty, isTrue);
    // No first-write clock (a row known only from a partial op): never matched.
    expect(planMatches([m], [after], _all, {'b-after': _h(70)}).isEmpty, isTrue);
    expect(planMatches([m], [after], _all, {'m1': _h(60)}).isEmpty, isTrue);
  });

  test('with seen_bank: a bank row replaces the entry iff the adding device did not hold it, whenever it was written', () {
    final m = _manual('m1', '2026-01-19', -240);
    final sat = _bank('b-sat', '2026-01-17', -240), mon = _bank('b-mon', '2026-01-19', -240);
    // Laptop imported both before the phone added the entry (19:00 vs 09:00 / 10:00), but the phone held only Saturday's.
    final w = {'b-sat': _h(50, 'laptop'), 'b-mon': _h(55, 'laptop'), 'm1': _h(90, 'phone')};
    final heldSat = SeenBank.encode([_h(50, 'laptop'), _h(40, 'phone')]);
    expect(planMatches([m], [sat], _all, w, seenBank: {'m1': heldSat}).isEmpty, isTrue, reason: 'on the phone already: cash');
    expect(planMatches([m], [sat, mon], _all, w, seenBank: {'m1': heldSat}).matchedTo, {'m1': 'b-mon'});
    // Held nothing (or nothing from the laptop): either row may be the one; the closest day wins.
    expect(planMatches([m], [sat, mon], _all, w, seenBank: {'m1': '[]'}).matchedTo, {'m1': 'b-mon'});
    expect(
        planMatches([m], [sat], _all, w,
            seenBank: {
              'm1': SeenBank.encode([_h(40, 'phone')])
            }).matchedTo,
        {'m1': 'b-sat'});
    // Held both: neither (the HLC fallback would say the same here; it differs when rows were not yet on the phone).
    final heldBoth = SeenBank.encode([_h(50, 'laptop'), _h(55, 'laptop')]);
    expect(planMatches([m], [sat, mon], _all, w, seenBank: {'m1': heldBoth}).isEmpty, isTrue);
    expect(planMatches([m], [sat, mon], _all, w).isEmpty, isTrue, reason: 'no seen_bank: both written before the entry');
    // A damaged value falls back to the entry's own clock, the same on every device.
    expect(planMatches([m], [sat, mon], _all, w, seenBank: {'m1': 'not json'}).isEmpty, isTrue);
    expect(planMatches([m], [sat, mon], _all, w, seenBank: {'m1': '["x"]'}).isEmpty, isTrue);
  });

  test('SeenBank.encode keeps the highest clock per device, in a stable order', () {
    final v = SeenBank.encode([_h(5, 'b'), _h(9, 'a'), _h(7, 'b'), _h(3, 'a'), '000000000000007:123456:b']);
    expect(jsonDecode(v), ['000000000000007:123456:b', _h(9, 'a')]);
    expect(SeenBank.encode([]), '[]');
  });

  group('repo: hand-added expenses are matched only by bank rows imported after them', () {
    ImportBatch pos(List<(String, int, String)> rows) =>
        ImportBatch(source: 'pbz', transactions: [for (final (d, a, m) in rows) n(d, a, 'POS plaćanje', m)]);
    List<Op> matchOps(WalletRepo r) => [
          for (final (_, op) in r.pendingOps())
            if (op.fields.containsKey('matched_to')) op
        ];

    test('a cash coffee added on Monday is not swallowed by the card payment of the same amount imported on Saturday', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      r.importBatch(pos([('2026-01-17', -240, 'POS EXAMPLE CAFE')])); // Saturday, already in the wallet
      final cash = r.addTransaction(date: '2026-01-19', amount: 240, category: 'Eating out', note: 'synthetic cash coffee');
      expect(r.transaction(cash)!.matchedTo, isNull);
      expect(r.transactions().where((t) => t.amount == -240).length, 2, reason: 'two coffees: both count');
      // An overlapping export brings Saturday's row again: still known, still not this entry's row.
      final again = r.importBatch(pos([('2026-01-17', -240, 'POS EXAMPLE CAFE'), ('2026-01-19', -5000, 'POS EXAMPLE SHOP')]));
      expect(again.matched, 0);
      expect(r.transaction(cash)!.matchedTo, isNull);
      expect(matchOps(r), isEmpty);
      // A same-amount payment first imported after the entry (here: the coffee was paid by card after all) replaces it.
      final later = r.importBatch(pos([('2026-01-20', -240, 'POS EXAMPLE CAFE TWO')]));
      expect(later.matched, 1);
      expect(r.transactions().where((t) => t.amount == -240).length, 2);
      expect(r.transaction(cash)!.matchedTo, isNotNull);
    });

    test('after an upgrade, old unmatched entries are not matched to bank history (no match ops synced)', () async {
      final dir = Directory.systemTemp.createTempSync('bw-match-');
      final relay = MemoryTransport();
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/wallet.db';
      var t = 1767225600000;
      var r = WalletRepo.open(path, now: () => t);
      r.importBatch(january); // history
      r.markExported(r.pendingOps().last.$1);
      // Cash entries an earlier build stored unmatched, next to same-amount bank rows already there (written later).
      t += 60000;
      r.applyRemote([
        Op(
            'tx',
            'm-old-1',
            {'source': 'manual', 'date': '2026-01-17', 'amount': -2340, 'category': 'Eating out', 'manual': 1, 'deleted': 0},
            Hlc(t, 0, 'old-device').toString()),
        Op('tx', 'm-old-2', {'source': 'manual', 'date': '2026-01-16', 'amount': -5000, 'category': 'Shopping', 'manual': 1, 'deleted': 0},
            Hlc(t, 1, 'old-device').toString()),
      ]);
      r.db.execute('ALTER TABLE tx DROP COLUMN seen_bank'); // the earlier build's table had no such column
      r.close();

      t += 60000;
      r = WalletRepo.open(path, now: () => t); // the new build
      addTearDown(r.close);
      expect(r.transaction('m-old-1')!.matchedTo, isNull);
      expect(r.db.select("SELECT seen_bank FROM tx WHERE id = 'm-old-1'").single['seen_bank'], isNull, reason: 'column added');
      r.importBatch(pos([('2026-02-03', -700, 'POS EXAMPLE BAKERY')])); // the first import after the upgrade
      r.addTransaction(date: '2026-02-04', amount: 310, category: 'Eating out');
      expect(matchOps(r), isEmpty, reason: 'no match ops for old history');
      await SyncEngine(relay, VaultKey.generate()).run(r); // and the first sync
      expect(matchOps(r), isEmpty);
      for (final id in ['m-old-1', 'm-old-2']) {
        expect(r.transaction(id)!.matchedTo, isNull, reason: id);
      }
      expect(r.transactions().where((t) => t.amount == -2340).length, 2);
    });

    test('an entry from an older build (no seen_bank) keeps the old rule: only a bank row written after it', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      const t = 1767225600000;
      Op bankOp(String id, String date, int millis) => Op(
          'tx',
          id,
          {'source': 'pbz', 'date': date, 'amount': -2340, 'bank_type': 'POS plaćanje', 'description': 'POS EXAMPLE $id', 'manual': 0},
          Hlc(millis, 0, 'laptop').toString());
      r.applyRemote([
        Op('tx', 'm-old', {'source': 'manual', 'date': '2026-01-17', 'amount': -2340, 'category': 'Eating out', 'manual': 1, 'deleted': 0},
            const Hlc(t, 0, 'old-phone').toString()),
      ]);
      r.applyRemote([bankOp('b-before', '2026-01-17', t - 1000)]); // imported elsewhere before the entry
      expect(r.transaction('m-old')!.matchedTo, isNull);
      r.applyRemote([bankOp('b-after', '2026-01-18', t + 1000)]);
      expect(r.transaction('m-old')!.matchedTo, 'b-after');
    });

    test('addTransaction records the bank rows this device holds, per device, in the same op as the entry', () {
      final r = WalletRepo.inMemory(now: () => 1767225600000 + 5000);
      addTearDown(r.close);
      final none = r.addTransaction(date: '2026-01-10', amount: 100, category: 'Eating out');
      r.applyRemote([
        Op('tx', 'b-peer', {'source': 'pbz', 'date': '2026-01-11', 'amount': -500, 'description': 'POS EXAMPLE', 'manual': 0},
            const Hlc(1767225600000, 0, 'peer').toString()),
      ]);
      r.importBatch(january);
      final m = r.addTransaction(date: '2026-01-20', amount: 100, category: 'Eating out');
      final ops = {for (final (_, op) in r.pendingOps()) op.id: op};
      expect(ops[none]!.fields['seen_bank'], '[]');
      final own = r.db.select("SELECT MAX(hlc) AS h FROM clocks WHERE field = 'amount' AND id != ? AND id != ?", [m, none]).single['h'];
      expect(jsonDecode(ops[m]!.fields['seen_bank'] as String), unorderedEquals([own, const Hlc(1767225600000, 0, 'peer').toString()]));
      expect(ops[m]!.fields['amount'], -100, reason: 'one op: entry and seen_bank sync together');
    });
  });

  group('repo: deleting the bank row that replaced a hand-added expense', () {
    List<Tx> spending(WalletRepo r) => r.transactions().where((t) => t.amount == -2340).toList();

    test('the hand-added expense counts again, and a later bank row can replace it', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final m = r.addTransaction(date: '2026-01-17', amount: 2340, category: 'Eating out', note: 'synthetic');
      expect(r.importBatch(january).matched, 1);
      final bank = r.transaction(m)!.matchedTo!;
      r.deleteTransaction(bank);
      expect(r.transaction(m)!.matchedTo, isNull);
      expect(spending(r).map((t) => t.id), [m], reason: 'the expense still counts, once');
      final cz = r.categorizer();
      expect(monthSummary(r.transactions().map(cz.categorize).toList(), '2026-01', currency: 'EUR').byCategory['Eating out'], 2340);
      // Re-importing the same export does not bring the deleted row back, nor match it.
      expect(r.importBatch(january).matched, 0);
      expect(spending(r).map((t) => t.id), [m]);
      // A corrected export with the payment on another day (a new row, imported now) replaces the entry.
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-01-18', -2340, 'POS plaćanje', 'POS EXAMPLE CORRECTED')]));
      expect(s.matched, 1);
      expect(spending(r).single.manual, isFalse);
    });

    test('a match to a bank row that has not arrived yet is kept; the row then counts once, and deleting it reopens the entry', () {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      const t = 1767225600000;
      r.applyRemote([
        Op('tx', 'm-peer', {'source': 'manual', 'date': '2026-01-17', 'amount': -2340, 'manual': 1, 'matched_to': 'b-late', 'deleted': 0},
            const Hlc(t, 0, 'peer').toString()),
      ]);
      expect(r.transaction('m-peer')!.matchedTo, 'b-late', reason: 'the peer holds that row: no unmatch op to fight it');
      expect(r.pendingOps(), isEmpty);
      expect(spending(r).map((t) => t.id), ['m-peer'], reason: 'until its row arrives, the entry counts');
      expect(r.transaction('m-peer')!.matchPending, isTrue);
      r.applyRemote([
        Op(
            'tx',
            'b-late',
            {
              'source': 'pbz',
              'date': '2026-01-17',
              'amount': -2340,
              'bank_type': 'POS plaćanje',
              'description': 'POS EXAMPLE',
              'manual': 0
            },
            const Hlc(t - 1000, 0, 'peer').toString()),
      ]);
      expect(spending(r).map((t) => t.id), ['b-late'], reason: 'one expense');
      expect(r.pendingOps(), isEmpty);
      r.applyRemote([
        Op('tx', 'b-late', {'deleted': 1}, const Hlc(t + 1000, 0, 'peer').toString())
      ]);
      expect(r.transaction('m-peer')!.matchedTo, isNull, reason: 'its bank row was deleted: the expense counts again');
      expect(spending(r).map((t) => t.id), ['m-peer']);
    });

    test('deleted on another device: after sync the expense counts again on both, same state', () async {
      final dir = Directory.systemTemp.createTempSync('bw-match-del-');
      final relay = MemoryTransport();
      addTearDown(() => dir.deleteSync(recursive: true));
      final key = VaultKey.generate();
      var t = 1767225600000;
      final phone = WalletRepo.inMemory(now: () => t), laptop = WalletRepo.inMemory(now: () => t);
      addTearDown(phone.close);
      addTearDown(laptop.close);
      Future<void> sync() async {
        for (var i = 0; i < 2; i++) {
          await SyncEngine(relay, key).run(phone);
          await SyncEngine(relay, key).run(laptop);
        }
      }

      final m = phone.addTransaction(date: '2026-01-17', amount: 2340, category: 'Eating out', note: 'synthetic');
      t += 1000;
      laptop.importBatch(january);
      await sync();
      final bank = phone.transaction(m)!.matchedTo;
      expect(bank, isNotNull);
      expect(laptop.transaction(m)!.matchedTo, bank);
      t += 1000;
      laptop.deleteTransaction(bank!);
      await sync();
      for (final r in [phone, laptop]) {
        expect(r.transaction(m)!.matchedTo, isNull);
        expect(spending(r).map((t) => t.id), [m]);
      }
      expect(dump(phone, clocks: false), dump(laptop, clocks: false));
      expect(phone.pendingOps(), isEmpty);
      expect(laptop.pendingOps(), isEmpty);
    });
  });

  test('openEntries: unmatched, matched to a deleted row, or second on a shared row', () {
    final manual = [
      _manual('m1', '2026-01-10', -100),
      _manual('m2', '2026-01-14', -100, to: 'b-live'), // keeps its match
      _manual('m3', '2026-01-14', -100, to: 'b-live'), // second entry on the same row
      _manual('m4', '2026-07-01', -100, to: 'b-gone'), // its row was deleted
      _manual('m5', '2026-07-01', -100, to: 'b-late'), // its row has not arrived: keeps its match
    ];
    expect(openEntries(manual, {'b-gone'}).map((m) => m.id), ['m1', 'm3', 'm4']);
    expect(openEntries([manual[1], manual[4]], {}), isEmpty);
  });

  group('matching cost', () {
    /// `repo.match` perf events (one per matching run) logged while [body] runs.
    Future<List<Map<String, Object?>>> matchRuns(Future<void> Function() body) async {
      final runs = <Map<String, Object?>>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) {
        if (r.object case LogEvent(event: 'repo.match', :final fields)) runs.add(fields);
      });
      try {
        await body();
      } finally {
        await sub.cancel();
        Logger.root.level = was;
      }
      return runs;
    }

    test('a new device reading many sync files matches once per sync run, not once per file', () async {
      final dir = Directory.systemTemp.createTempSync('bw-match-sync-');
      final relay = MemoryTransport();
      addTearDown(() => dir.deleteSync(recursive: true));
      final key = VaultKey.generate();
      var t = 1767225600000;
      final a = WalletRepo.inMemory(now: () => t), b = WalletRepo.inMemory(now: () => t);
      addTearDown(a.close);
      addTearDown(b.close);
      const files = 40;
      for (var i = 0; i < files; i++) {
        t += 1000;
        final day = addDays('2026-01-01', i);
        // One sync file per step: a hand-added expense, then (next file) the bank row that replaces it.
        if (i.isEven) {
          a.addTransaction(date: day, amount: 1000 + i, category: 'Eating out');
        } else {
          a.importBatch(ImportBatch(source: 'pbz', transactions: [n(day, -(1000 + i - 1), 'POS plaćanje', 'POS EXAMPLE $i')]));
        }
        await SyncEngine(relay, key).run(a);
      }
      late SyncReport rep;
      final runs = await matchRuns(() async => rep = await SyncEngine(relay, key).run(b));
      expect(rep.filesRead, files);
      expect(runs, hasLength(1), reason: 'one matching run for the whole sync');
      expect(b.transactions().where((t) => t.manual), isEmpty, reason: 'every entry matched by its bank row');
      expect(b.transactions().length, files ~/ 2);
      // Nothing new: no matching at all.
      expect(await matchRuns(() => SyncEngine(relay, key).run(b)), isEmpty);
    });

    test('a large wallet loads only the bank rows that could replace an open entry', () async {
      final r = WalletRepo.inMemory();
      addTearDown(r.close);
      final rnd = Random(fuzzSeed(5));
      // Two years of synthetic history, many rows with the amounts of the entries below.
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (var i = 0; i < 4000; i++)
          n(addDays('2025-01-01', i * 730 ~/ 4000), -[240, 990, 2340, 100 + rnd.nextInt(9000)][i % 4], 'POS plaćanje', 'POS EXAMPLE $i'),
      ]));
      // 200 hand-added expenses among that history that no bank row replaced (cash): they stay open for good.
      for (var i = 0; i < 200; i++) {
        r.addTransaction(date: addDays('2025-01-01', i * 3), amount: [240, 990, 2340][i % 3], category: 'Eating out');
      }
      final m = r.addTransaction(date: '2026-12-30', amount: 990, category: 'Eating out');
      late ImportSummary s;
      final runs = await matchRuns(() async {
        s = r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-12-31', -990, 'POS plaćanje', 'POS EXAMPLE NEW')]));
      });
      expect(s.matched, 1);
      expect(r.transaction(m)!.matchedTo, isNotNull);
      final run = runs.single;
      expect(run['open'], 201);
      expect(run['bank'], 1, reason: 'history rows were in the wallet before the entries: not loaded');
      expect(run['ms'] as int, lessThan(2000), reason: 'rough bound on a shared machine');
      expect(r.transactions(includeHidden: true).where((t) => t.manual && t.matchedTo != null).length, 1);
    });
  });
}
