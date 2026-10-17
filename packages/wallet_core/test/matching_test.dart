// planMatches: deterministic manual ↔ bank matching. All data is SYNTHETIC.
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

Tx _manual(String id, String date, int amount, {String? to, String? category = 'Eating out'}) =>
    Tx(id: id, source: 'manual', date: date, amount: amount, manual: true, matchedTo: to, category: category);
Tx _bank(String id, String date, int amount, {String? category}) =>
    Tx(id: id, source: 'pbz', date: date, amount: amount, bankType: 'POS plaćanje', description: 'POS EXAMPLE', category: category);
bool _all(Tx _) => true;

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
    final p = planMatches(
      [_manual('m1', '2026-01-17', -990), _manual('m2', '2026-01-17', -990)],
      [_bank('b3', '2026-01-19', -990), _bank('b2', '2026-01-16', -990), _bank('b1', '2026-01-18', -990)],
      _all,
    );
    expect(p.matchedTo, {'m1': 'b2', 'm2': 'b1'}); // both 1 day away: the earlier date first
    expect(p.added, 2);
    expect(p.bankCategory, {'b1': 'Eating out', 'b2': 'Eating out'});
  });

  test('a bank row with its own category keeps it; an ineligible row is never used', () {
    final p = planMatches([_manual('m1', '2026-01-17', -990)], [_bank('b1', '2026-01-17', -990, category: 'Shopping')], _all);
    expect(p.matchedTo, {'m1': 'b1'});
    expect(p.bankCategory, isEmpty);
    expect(planMatches([_manual('m1', '2026-01-17', -990)], [_bank('b1', '2026-01-17', -990)], (_) => false).isEmpty, isTrue);
  });

  test('two entries on one bank row: the smallest id keeps it, the other is unmatched or takes another row', () {
    final manual = [_manual('m2', '2026-01-17', -990, to: 'b1'), _manual('m1', '2026-01-17', -990, to: 'b1')];
    expect(planMatches(manual, [_bank('b1', '2026-01-17', -990)], _all).matchedTo, {'m2': null});
    expect(planMatches(manual, [_bank('b1', '2026-01-17', -990), _bank('b2', '2026-01-18', -990)], _all).matchedTo, {'m2': 'b2'});
  });

  test('an existing match is kept, also when its bank row has not arrived yet', () {
    expect(planMatches([_manual('m1', '2026-01-17', -990, to: 'elsewhere')], [_bank('b1', '2026-01-17', -990)], _all).isEmpty, isTrue);
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
      final p = planMatches(manual, bank, _all);
      final q = planMatches([...manual]..shuffle(r), [...bank]..shuffle(r), _all);
      expect(q.matchedTo, p.matchedTo, reason: 'case $i');
      expect(q.bankCategory, p.bankCategory, reason: 'case $i');
      final after = _applied(manual, p);
      expect(planMatches(after, bank, _all).matchedTo, isEmpty, reason: 'case $i: not idempotent');
      final targets = after.map((m) => m.matchedTo).whereType<String>().toList();
      expect(targets.toSet().length, targets.length, reason: 'case $i: one bank row per entry');
    }
  });
}
