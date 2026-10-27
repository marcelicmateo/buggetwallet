// Q3 overflow guard (docs/context/STAGE_Q_PLAN.md): one amount cap for typed, imported and synced amounts, and sums
// that stay under 2^53. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

const _twoTo53 = 9007199254740992;

String _h(int millis, [String node = 'peer']) => Hlc(2000000000000 + millis, 0, node).toString();

List<String> _capture(void Function() body) {
  final lines = <String>[];
  final was = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
  try {
    body();
  } finally {
    sub.cancel();
    Logger.root.level = was;
  }
  return lines;
}

void main() {
  group('isSafeCents', () {
    test('the cap ±1', () {
      expect(maxAmountCents, WalletSettings.maxAmount);
      expect(isSafeCents(maxAmountCents), isTrue);
      expect(isSafeCents(-maxAmountCents), isTrue);
      expect(isSafeCents(maxAmountCents + 1), isFalse);
      expect(isSafeCents(-maxAmountCents - 1), isFalse);
      expect(isSafeCents(0), isTrue);
    });

    test('the importer refuses rows at the same cap', () {
      expect(maxRowAmountMinor, maxAmountCents);
    });

    test('worst case: 90,000 rows at the cap sum under 2^53 (the real limits)', () {
      expect(exactRowsAtCap * maxAmountCents, lessThan(_twoTo53));
      expect(exactRowsAtCap * maxRowAmountMinor, lessThan(_twoTo53));
    });
  });

  group('budget sums', () {
    const st = WalletSettings(salary: 200000, periodStart: '2026-01-15');
    List<CategorizedTx> rows(int count) => [for (var i = 0; i < count; i++) ct('2026-01-20', -maxAmountCents, 'Groceries')];

    test('90,000 rows at the cap still compute exactly', () {
      final p = computePeriod(rows(exactRowsAtCap), st, const [], '2026-01-20', table: CategoryTable.builtIn);
      expect(p.spent, exactRowsAtCap * maxAmountCents);
    });

    test('a sum past 2^53 trips the debug assert instead of losing cents', () {
      expect(() => computePeriod(rows(exactRowsAtCap + 100), st, const [], '2026-01-20', table: CategoryTable.builtIn),
          throwsA(isA<AssertionError>()));
    });
  });

  group('repo', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory(now: () => 2000000000000 + 1000000));
    tearDown(() => r.close());

    test('addTransaction: at the cap is written, one cent over is an ArgumentError and writes nothing', () {
      final id = r.addTransaction(date: '2026-01-10', amount: maxAmountCents, category: 'Groceries');
      expect(r.transaction(id)!.amount, -maxAmountCents);
      final before = r.transactions().length;
      expect(() => r.addTransaction(date: '2026-01-10', amount: maxAmountCents + 1, category: 'Groceries'), throwsArgumentError);
      expect(() => r.addTransaction(date: '2026-01-10', amount: -maxAmountCents - 1, category: 'Groceries'), throwsArgumentError);
      expect(r.transactions().length, before);
    });

    test('importBatch skips over-cap rows and counts them, apart from duplicates', () {
      final atCap = n('2026-01-10', -maxAmountCents, 'Ostalo', 'Synthetic big');
      final over = n('2026-01-11', -maxAmountCents - 1, 'Ostalo', 'Synthetic over');
      final overIn = n('2026-01-11', maxAmountCents + 1, 'Ostalo', 'Synthetic over in');
      final small = n('2026-01-12', -100, 'Ostalo', 'Synthetic small');
      late ImportSummary s;
      final lines = _capture(() => s = r.importBatch(ImportBatch(source: 'pbz', transactions: [atCap, over, overIn, small])));
      expect(s.added, 2);
      expect(s.tooLarge, 2);
      expect(s.duplicates, 0);
      expect(r.transaction(over.id), isNull);
      expect(r.transaction(overIn.id), isNull);
      expect(r.transaction(atCap.id)!.amount, -maxAmountCents);
      final log = lines.where((l) => l.contains('repo.tooLarge')).single;
      expect(log, contains('"count":2'));
      expect(log, isNot(contains('Synthetic')));
      // A re-import: the two written rows are duplicates, the over-cap ones are still too large.
      final again = r.importBatch(ImportBatch(source: 'pbz', transactions: [atCap, over, overIn, small]));
      expect((again.added, again.duplicates, again.tooLarge), (0, 2, 2));
    });

    test('an empty batch: nothing written, nothing too large', () {
      final s = r.importBatch(const ImportBatch(source: 'pbz', transactions: []));
      expect((s.added, s.duplicates, s.tooLarge, s.skippedByOwner), (0, 0, 0, 0));
    });

    // Review fix 8: rows an older build imported (up to 10^12) still apply; beyond that they are quarantined.
    test('a synced row amount over the legacy cap is quarantined like a wrong-typed field; at it, it applies', () {
      const base = {'source': 'pbz', 'date': '2026-01-10', 'amount': -500, 'description': 'Synthetic shop'};
      r.applyRemote([Op('tx', 't', base, _h(1))]);
      final lines = _capture(() => r.applyRemote([
            Op('tx', 't', {'amount': -legacyRowCapCents - 1, 'note': 'Synthetic note'}, _h(2))
          ]));
      final t = r.transaction('t')!;
      expect((t.amount, t.note), (-500, 'Synthetic note'));
      final bad = lines.where((l) => l.contains('repo.badField')).single;
      expect(bad, contains('"entity":"tx"'));
      expect(bad, contains('"field":"amount"'));
      expect(bad, isNot(contains('$legacyRowCapCents')));
      // Its clock was not recorded: a valid write with an older clock still wins (above the local cap: an old import).
      r.applyRemote([
        Op('tx', 't', {'amount': -legacyRowCapCents}, _h(2))
      ]);
      expect(r.transaction('t')!.amount, -legacyRowCapCents);
      // A whole float over the cap too.
      r.applyRemote([
        Op('tx', 't', {'amount': (legacyRowCapCents + 1).toDouble()}, _h(3))
      ]);
      expect(r.transaction('t')!.amount, -legacyRowCapCents);
      // The smallest int (whose abs() is itself) is refused too.
      r.applyRemote([
        Op('tx', 't', {'amount': -9223372036854775808}, _h(4))
      ]);
      expect(r.transaction('t')!.amount, -legacyRowCapCents);
    });

    test('9,000 rows at the legacy cap still sum under 2^53', () {
      expect(9000 * legacyRowCapCents, lessThan(_twoTo53));
    });

    test('other row-amount columns are capped; goals keep their own clamping; non-amount integers are not capped', () {
      // A goal is clamped when read (goalTotal), so a goal above the row cap is kept as it is.
      r.applyRemote([
        Op('goal', 'g', {'name': 'Synthetic goal', 'target': Goal.maxSaved, 'saved': Goal.maxSaved, 'monthly': 0, 'deleted': 0}, _h(1))
      ]);
      expect(r.goals().single.target, Goal.maxSaved);
      // Review fix 2: a goal's monthly is summed in computePeriod, so it takes the one cap.
      r.applyRemote([
        Op('goal', 'g', {'monthly': maxAmountCents + 1}, _h(2))
      ]);
      expect(r.goals().single.monthly, 0);
      r.applyRemote([
        Op('goal', 'g', {'monthly': maxAmountCents}, _h(2))
      ]);
      expect(r.goals().single.monthly, maxAmountCents);
      // A planned cost's amount is a row amount.
      r.applyRemote([
        Op('planned', 'p1',
            {'title': 'Synthetic', 'date': '2026-01-20', 'amount': maxAmountCents + 1, 'source': 'manual', 'status': 'open'}, _h(3))
      ]);
      expect(r.plannedCosts().single.amount, isNull);
      // A wish's `added` (milliseconds) is not an amount: far above the cap and still applied.
      r.applyRemote([
        Op('wish', 'w1', {'name': 'Synthetic wish', 'price': 100, 'added': 2000000000000, 'status': 'waiting', 'deleted': 0}, _h(4))
      ]);
      expect(r.wishlist().single.price, 100);
    });
  });
}
