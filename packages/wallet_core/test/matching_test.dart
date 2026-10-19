// planMatches: deterministic manual ↔ bank matching. All data is SYNTHETIC.
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

Tx _manual(String id, String date, int amount, {String? to, String? category = 'Eating out'}) =>
    Tx(id: id, source: 'manual', date: date, amount: amount, manual: true, matchedTo: to, category: category);
Tx _bank(String id, String date, int amount, {String? category}) =>
    Tx(id: id, source: 'pbz', date: date, amount: amount, bankType: 'POS plaćanje', description: 'POS EXAMPLE', category: category);
bool _all(Tx _) => true;
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

  test('an existing match is kept, also when its bank row has not arrived yet', () {
    expect(_plan([_manual('m1', '2026-01-17', -990, to: 'elsewhere')], [_bank('b1', '2026-01-17', -990)], _all).isEmpty, isTrue);
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
      // Random first-write clocks: some bank rows came before their entries, some after.
      final written = {
        for (final t in [...manual, ...bank]) t.id: _h(r.nextInt(20), t.id)
      };
      final p = planMatches(manual, bank, _all, written);
      final q = planMatches([...manual]..shuffle(r), [...bank]..shuffle(r), _all, written);
      expect(q.matchedTo, p.matchedTo, reason: 'case $i');
      expect(q.bankCategory, p.bankCategory, reason: 'case $i');
      for (final e in p.matchedTo.entries.where((e) => e.value != null)) {
        expect(Hlc.parse(written[e.value]!).compareTo(Hlc.parse(written[e.key]!)), greaterThan(0),
            reason: 'case $i: only a bank row written after the entry');
      }
      final after = _applied(manual, p);
      expect(planMatches(after, bank, _all, written).matchedTo, isEmpty, reason: 'case $i: not idempotent');
      final targets = after.map((m) => m.matchedTo).whereType<String>().toList();
      expect(targets.toSet().length, targets.length, reason: 'case $i: one bank row per entry');
    }
  });

  test('only a bank row first written after the entry replaces it (HLC order, not dates or devices)', () {
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
      final cash = r.addManual(date: '2026-01-19', amount: 240, category: 'Eating out', note: 'synthetic cash coffee');
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
      r.close();

      t += 60000;
      r = WalletRepo.open(path, now: () => t); // the new build
      addTearDown(r.close);
      r.importBatch(pos([('2026-02-03', -700, 'POS EXAMPLE BAKERY')])); // the first import after the upgrade
      r.addManual(date: '2026-02-04', amount: 310, category: 'Eating out');
      expect(matchOps(r), isEmpty, reason: 'no match ops for old history');
      await FolderSync(dir.path, VaultKey.generate()).run(r); // and the first sync
      expect(matchOps(r), isEmpty);
      for (final id in ['m-old-1', 'm-old-2']) {
        expect(r.transaction(id)!.matchedTo, isNull, reason: id);
      }
      expect(r.transactions().where((t) => t.amount == -2340).length, 2);
    });
  });
}
