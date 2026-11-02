// All data here is synthetic.

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/synthetic.dart';

void main() {
  group('categories', () {
    final cz = Categorizer();
    String cat(NormalizedTransaction t) => cz
        .categoryOf(Tx(id: t.id, source: t.source, date: t.date, amount: t.amountMinor, bankType: t.bankType, description: t.description));
    test('PBZ rules', () {
      expect(january.transactions.map(cat).toList(),
          ['Salary', 'Rent', 'Internal transfer', 'Groceries', 'Loan', 'Bank fees', 'Extra income']);
    });
    test('user patterns win over built-in rules', () {
      const t = Tx(id: 'x', source: 'revolut', date: '2026-01-01', amount: -100, bankType: 'Card Payment', description: 'Corner Spot');
      expect(Categorizer().categoryOf(t), 'Shopping');
      expect(
          Categorizer(patterns: [
            ['Eating out', 'corner']
          ]).categoryOf(t),
          'Eating out');
    });
    test('merchant key matches v1', () {
      const t =
          Tx(id: 'x', source: 'pbz', date: '2026-01-01', amount: -100, bankType: 'POS plaćanje', description: 'PBZ POS PBZ7BAUHAUS ZADAR');
      expect(merchantKey(t), 'bauhaus_zadar');
    });
  });

  group('repo', () {
    test('import is idempotent', () {
      final r = WalletRepo.inMemory();
      expect(r.importBatch(january).added, 7);
      final again = r.importBatch(january);
      expect(again.added, 0);
      expect(again.duplicates, 7);
      expect(r.transactions().length, 7);
    });

    test('hand-added expense is matched by the bank row and keeps its category', () {
      final r = WalletRepo.inMemory();
      r.addTransaction(date: '2026-01-16', amount: 2340, category: 'Eating out', note: 'lunch');
      final s = r.importBatch(january);
      expect(s.matched, 1);
      final live = r.transactions();
      expect(live.length, 7); // manual row hidden
      final bank = live.firstWhere((t) => t.amount == -2340);
      expect(r.categorizer().categoryOf(bank), 'Eating out');
    });

    test('settings and goals round-trip', () {
      final r = WalletRepo.inMemory();
      r.updateSettings({'salary': 150000, 'salaryConfirmed': true});
      r.setMerchantPattern('Groceries', 'corner');

      expect(r.settings().salary, 150000);
      expect(r.settings().salaryConfirmed, isTrue);
      expect(r.settings().merchantPatterns.first, ['Groceries', 'corner']);
      final g = r.saveGoal(name: 'Emergency', target: 300000, saved: 0, monthly: 10000);
      r.payGoals(period: '2026-01-15');
      expect(r.goals().single.saved, 10000);
      r.deleteGoal(g);
      expect(r.goals(), isEmpty);
    });
  });

  group('budget', () {
    test('payday period: budget, rollover, days left', () {
      final r = WalletRepo.inMemory();
      r.importBatch(january);
      const st = WalletSettings(salary: 150000, rent: 55000, loan: 25000, subs: 0, periodStart: '2026-01-15');
      final cz = r.categorizer();
      final txs = r.transactions().map(cz.categorize).toList();
      final p = computePeriod(txs, st, const [Goal(id: 'g', name: 'g', monthly: 10000)], '2026-01-20', table: CategoryTable.builtIn);
      expect(p.end, '2026-02-15');
      expect(p.length, 31);
      expect(p.daysLeft, 26);
      expect(p.flexBudget, 60000);
      expect(p.spent, 2373);
      expect(p.remaining, 57627);
      expect(p.fixedPaid['Rent'], 55000);
      expect(affordability(5000, p).verdict, Verdict.now);
      expect(affordability(56000, p).verdict, Verdict.tight);
      expect(affordability(70000, p).verdict, Verdict.later);
    });

    test('month summary ignores internal transfers', () {
      final r = WalletRepo.inMemory();
      r.importBatch(january);
      final cz = r.categorizer();
      final s = monthSummary(r.transactions().map(cz.categorize).toList(), '2026-01', currency: 'EUR');
      expect(s.income, 180000);
      expect(s.out, 82373);
    });

    test('dates', () {
      expect(nextPayday('2026-01-31', 31), '2026-02-28');
      expect(monthsEnding('2026-02', 3), ['2025-12', '2026-01', '2026-02']);
    });
  });

  group('vault', () {
    test('key text round-trip and typo detection', () async {
      final k = VaultKey.generate();
      final text = await k.toText();
      expect(text, startsWith('BW1-'));
      final back = await VaultKey.parse(text.toLowerCase().replaceAll('-', ' '));
      expect(back.bytes, k.bytes);
      final typo = text.substring(0, 6) + (text[6] == 'A' ? 'B' : 'A') + text.substring(7);
      expect(() => VaultKey.parse(typo), throwsA(isA<VaultException>()));
    });

    test('seal/unseal and tamper detection', () async {
      final k = VaultKey.generate();
      final box = await seal([1, 2, 3], k, aad: aadBackup);
      expect(await unseal(box, k, aad: aadBackup), [1, 2, 3]);
      box[box.length - 1] ^= 1;
      expect(() => unseal(box, k, aad: aadBackup), throwsA(isA<VaultException>()));
      expect(() => unseal(box, VaultKey.generate(), aad: aadBackup), throwsA(isA<VaultException>()));
    });
  });

  group('sync', () {
    late MemoryTransport relay;
    setUp(() => relay = MemoryTransport());

    test('two devices converge, last edit wins per field', () async {
      var t = 1000;
      final a = WalletRepo.inMemory(now: () => t);
      final b = WalletRepo.inMemory(now: () => t);
      final key = VaultKey.generate();
      final sa = SyncEngine(relay, key), sb = SyncEngine(relay, key);

      a.importBatch(january);
      a.updateSettings({'salary': 150000});
      expect((await sa.run(a)).sent, greaterThan(0));
      final rb = await sb.run(b);
      expect(rb.filesRead, 1);
      expect(b.transactions().length, 7);
      expect(b.settings().salary, 150000);

      final lidl = a.transactions().firstWhere((x) => x.amount == -2340).id;
      t = 2000;
      a.setCategory(lidl, 'Shopping');
      t = 3000;
      b.setCategory(lidl, 'Eating out'); // later edit
      b.updateSettings({'rent': 55000});
      await sa.run(a);
      await sb.run(b);
      await sa.run(a);
      await sb.run(b);
      expect(a.transaction(lidl)!.category, 'Eating out');
      expect(b.transaction(lidl)!.category, 'Eating out');
      expect(a.settings().rent, 55000);
      expect(a.settings().salary, 150000);
    });

    test('files sealed with a different key are refused (otherKey) and hold up that device; nothing applies', () async {
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
      a.updateSettings({'salary': 1});
      await SyncEngine(relay, VaultKey.generate()).run(a);
      final r = await SyncEngine(relay, VaultKey.generate()).run(b);
      expect(r.problems.single.reason, SyncProblemReason.otherKey);
      expect(r.waiting.single.reason, SyncProblemReason.otherKey);
      expect(r.caughtUp, isFalse);
      expect(b.settings().salary, isNot(1));
    });

    test('an unreachable relay is a SyncException and keeps the outbox', () async {
      final a = WalletRepo.inMemory();
      a.updateSettings({'salary': 1});
      relay.offline = true;
      await expectLater(SyncEngine(relay, VaultKey.generate()).run(a), throwsA(isA<SyncException>()));
      expect(a.pendingOps(), isNotEmpty);
    });
  });
}
