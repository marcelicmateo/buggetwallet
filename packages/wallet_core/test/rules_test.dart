// The owner's budgeting rules from BRIEF.md, encoded as tests: impulse threshold and cooling-off, internal transfers,
// the rent cash rule, extras outside daily money, categories learned from corrections, manual entries matched to
// bank rows on import, and re-imports never duplicating. All data is SYNTHETIC.
import 'dart:io';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

Tx _tx(String source, String type, String desc, int cents, {String? category}) =>
    Tx(id: 'x', source: source, date: '2026-01-10', amount: cents, bankType: type, description: desc, category: category);

void main() {
  final cz = Categorizer();

  group('impulse rule', () {
    test('defaults: over EUR 50 waits 72 hours', () {
      const st = WalletSettings();
      expect(st.impulse, 5000);
      expect(st.coolHours, 72);
      expect(WalletSettings.fromMap(const {}).impulse, 5000);
      expect(WalletSettings.fromMap(const {}).coolHours, 72);
    });

    test('threshold and cooling-off are adjustable and sync like other settings', () {
      final r = WalletRepo.inMemory();
      r.updateSettings({'impulse': 8000, 'coolHours': 24});
      expect((r.settings().impulse, r.settings().coolHours), (8000, 24));
      r.close();
    });

    test('hours left: full wait when added, zero exactly at the end, negative after', () {
      const added = 1767225600000;
      const w = WishItem(id: 'w', name: 'Synthetic', price: 9000, added: added);
      expect(w.hoursLeft(72, added), 72);
      expect(w.hoursLeft(72, added + 71 * 3600000), 1);
      expect(w.hoursLeft(72, added + 72 * 3600000), 0);
      expect(w.hoursLeft(72, added + 73 * 3600000), -1);
      expect(w.hoursLeft(24, added + 12 * 3600000), 12);
      expect(w.hoursLeft(0, added), 0);
    });

    test('wishlist: new items wait, decisions are kept, order is by time added', () async {
      final r = WalletRepo.inMemory();
      final a = r.addWish('Synthetic A', 9000);
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final b = r.addWish('Synthetic B', 6000);
      expect(r.wishlist().map((w) => (w.id, w.status)), [(a, 'waiting'), (b, 'waiting')]);
      final added = r.wishlist().first.added;
      expect((DateTime.now().millisecondsSinceEpoch - added).abs(), lessThan(60000));
      r.decideWish(a, 'skipped');
      final first = r.wishlist().first;
      expect(first.status, 'skipped');
      expect(first.decided, isNotNull);
      r.close();
    });
  });

  group('internal transfers are not spending', () {
    test('PBZ -> Revolut top-ups (and money back) and Revolut top-ups/exchanges', () {
      expect(cz.categoryOf(_tx('pbz', 'POS plaćanje', 'POS Revolut**0000* Dublin', -5000)), 'Internal transfer');
      expect(cz.categoryOf(_tx('pbz', 'Ostalo', 'Revolut Bank UAB povrat', 5000)), 'Internal transfer');
      expect(cz.categoryOf(_tx('revolut', 'Topup', 'Top-up by *0000', 5000)), 'Internal transfer');
      expect(cz.categoryOf(_tx('revolut', 'Exchange', 'Exchanged to USD', -1000)), 'Internal transfer');
      expect(cz.categoryOf(_tx('pbz', 'Ostalo', 'Isplata kredita 0000', 1000000)), 'Loan received');
      expect(kindOf('Internal transfer'), Kind.transfer);
      expect(kindOf('Loan received'), Kind.transfer);
    });

    test('a merchant rule never turns a transfer into spending', () {
      final t = _tx('pbz', 'POS plaćanje', 'POS Revolut**0000* Dublin', -5000);
      final withRule = Categorizer(merchantRules: {merchantKey(t): 'Shopping'});
      expect(withRule.categoryOf(t), 'Internal transfer');
    });

    test('both sides of a top-up are left out of month and period totals', () {
      final txs = [
        ct('2026-01-15', 150000, 'Salary'),
        ct('2026-01-16', -5000, 'Internal transfer'),
        ct('2026-01-16', 5000, 'Internal transfer'),
        ct('2026-01-17', -2000, 'Groceries'),
      ];
      final m = monthSummary(txs, '2026-01');
      expect((m.income, m.out), (150000, 2000));
      final p = periodSummaries(txs, const WalletSettings(), '2026-01-20').single;
      expect((p.income, p.out), (150000, 2000));
    });
  });

  group('rent cash rule', () {
    test('a PBZ ATM withdrawal of EUR 500 or more is rent; less is cash spending', () {
      expect(cz.categoryOf(_tx('pbz', 'Isplata ATM', 'PBZ ATM TEST', -50000)), 'Rent');
      expect(cz.categoryOf(_tx('pbz', 'Isplata ATM', 'PBZ ATM TEST', -75000)), 'Rent');
      expect(cz.categoryOf(_tx('pbz', 'Isplata ATM', 'PBZ ATM TEST', -49999)), 'Cash');
      expect(cz.categoryOf(_tx('pbz', 'Isplata ATM', 'PBZ ATM TEST', -2000)), 'Cash');
      expect(cz.categoryOf(_tx('pbz', 'Isplata u poslovnici', 'Branch', -80000)), 'Cash');
      expect(kindOf('Rent'), Kind.fixed);
      expect(kindOf('Cash'), Kind.flex);
    });

    test('rent is a fixed bill: not in safe-to-spend, shown as paid', () {
      final txs = [ct('2026-01-15', -55000, 'Rent'), ct('2026-01-16', -2000, 'Cash')];
      final p = computePeriod(txs, const WalletSettings(salary: 150000, rent: 55000, periodStart: '2026-01-15'), const [], '2026-01-16');
      expect(p.spent, 2000);
      expect(p.fixedPaid, {'Rent': 55000});
      expect(p.flexBudget, 95000);
    });
  });

  group('extras are never daily money', () {
    test('positive PBZ rows that are not salary are extras; salary type and "krive uplate" are salary', () {
      expect(cz.categoryOf(_tx('pbz', 'Ostalo', 'VAL_01.01.2026.POVRAT', 30000)), 'Extra income');
      expect(cz.categoryOf(_tx('pbz', 'Plaća/Mirovina', 'Neto plaća', 150000)), 'Salary');
      expect(cz.categoryOf(_tx('pbz', 'Ostalo', 'Povrat krive uplate', 150000)), 'Salary');
      expect(kindOf('Extra income'), Kind.extra);
    });

    test('a bonus raises income and net, but not flexible money or safe-to-spend', () {
      const st = WalletSettings(salary: 150000, rent: 50000, periodStart: '2026-01-15');
      final base = [ct('2026-01-15', 150000, 'Salary'), ct('2026-01-16', -3000, 'Groceries')];
      final bonus = [...base, ct('2026-01-17', 80000, 'Extra income')];
      final p0 = computePeriod(base, st, const [], '2026-01-18'), p1 = computePeriod(bonus, st, const [], '2026-01-18');
      expect((p1.flexBudget, p1.allowanceToday, p1.remaining), (p0.flexBudget, p0.allowanceToday, p0.remaining));
      expect(p1.extras, 80000);
      expect(periodSummaries(bonus, st, '2026-01-18').single.net - periodSummaries(base, st, '2026-01-18').single.net, 80000);
    });

    test('a salary month above plan does not raise daily money in planned mode', () {
      const st = WalletSettings(salary: 150000, periodStart: '2026-01-15');
      final p = computePeriod([ct('2026-01-15', 150000, 'Salary'), ct('2026-01-16', 40000, 'Salary')], st, const [], '2026-01-18');
      expect(p.income, 150000);
      expect(p.received, 190000);
    });
  });

  group('categories learned from corrections', () {
    test('a merchant rule applies to other visits of the same merchant (store numbers and amounts differ)', () {
      final r = WalletRepo.inMemory();
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-01-17', -2340, 'POS plaćanje', 'PBZ POS PBZ7EXAMPLE BISTRO 0012 ZAGREB'),
        n('2026-01-24', -990, 'POS plaćanje', 'PBZ POS PBZ7EXAMPLE BISTRO 0047 ZAGREB'),
      ]));
      final txs = r.transactions();
      expect(txs.map(r.categorizer().categoryOf).toSet(), {'Eating out'}, reason: 'built-in "bistro" rule');
      final first = txs.last;
      r.setMerchantRule(merchantKey(first), 'Groceries');
      expect(merchantKey(txs.first), merchantKey(first));
      expect(r.transactions().map(r.categorizer().categoryOf).toSet(), {'Groceries'});
      // A one-off correction on one row beats the rule.
      r.setCategory(first.id, 'Shopping');
      expect(r.categorizer().categoryOf(r.transaction(first.id)!), 'Shopping');
      expect(r.categorizer().categoryOf(r.transaction(txs.first.id)!), 'Groceries');
      // Clearing the correction falls back to the rule.
      r.setCategory(first.id, null);
      expect(r.categorizer().categoryOf(r.transaction(first.id)!), 'Groceries');
      r.close();
    });

    test('rules do not touch salary, extras or hand-added expenses', () {
      final salary = _tx('pbz', 'Plaća/Mirovina', 'Neto plaća', 150000);
      const manual =
          Tx(id: 'm', source: 'manual', date: '2026-01-10', amount: -500, category: 'Eating out', manual: true, note: 'Neto plaća');
      final c = Categorizer(merchantRules: {merchantKey(salary): 'Groceries', 'neto_pla_a': 'Groceries', merchantKey(manual): 'Groceries'});
      expect(c.categoryOf(salary), 'Salary');
      expect(c.categoryOf(manual), 'Eating out');
    });

    test('rule and override order: override > merchant rule > personal pattern > built-in', () {
      final t = _tx('revolut', 'Card Payment', 'Example Spar Corner', -1000);
      expect(Categorizer().categoryOf(t), 'Groceries');
      final withPattern = Categorizer(patterns: [
        ['Eating out', 'corner']
      ]);
      expect(withPattern.categoryOf(t), 'Eating out');
      final withRule = Categorizer(merchantRules: {
        merchantKey(t): 'Home & tools'
      }, patterns: [
        ['Eating out', 'corner']
      ]);
      expect(withRule.categoryOf(t), 'Home & tools');
      expect(withRule.categoryOf(_tx('revolut', 'Card Payment', 'Example Spar Corner', -1000, category: 'Shopping')), 'Shopping');
    });

    test('bad personal patterns and unknown categories are ignored, not fatal', () {
      final c = Categorizer(merchantRules: {
        'example_shop': 'Not a category'
      }, patterns: [
        ['Groceries', '(unclosed'],
        ['Not a category', 'example'],
        ['Eating out', 'shop'],
      ]);
      final t = _tx('revolut', 'Card Payment', 'Example Shop', -100);
      expect(c.categoryOf(t), 'Eating out');
      expect(c.categoryOf(_tx('revolut', 'Card Payment', 'Example Shop', -100, category: 'Not a category')), 'Eating out');
    });

    test('a rule learned on one device categorises the same merchant on another after sync', () async {
      final dir = Directory.systemTemp.createTempSync('bw-rule-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final key = VaultKey.generate();
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
      a.setMerchantRule('example_bistro_zagreb', 'Groceries');
      await FolderSync(dir.path, key).run(a);
      await FolderSync(dir.path, key).run(b);
      b.importBatch(
          ImportBatch(source: 'pbz', transactions: [n('2026-01-17', -2340, 'POS plaćanje', 'PBZ POS PBZ7EXAMPLE BISTRO ZAGREB')]));
      expect(b.categorizer().categoryOf(b.transactions().single), 'Groceries');
    });
  });

  group('manual entries matched to bank rows on import (same amount, within 3 days)', () {
    WalletRepo repoWith(List<(String, int)> manual) {
      final r = WalletRepo.inMemory();
      for (final (d, a) in manual) {
        r.addManual(date: d, amount: a, category: 'Eating out', note: 'synthetic');
      }
      return r;
    }

    ImportBatch bank(List<(String, int, String, String)> rows) =>
        ImportBatch(source: 'pbz', transactions: [for (final (d, a, t, m) in rows) n(d, a, t, m)]);

    int live(WalletRepo r) => r.transactions().length;

    test('3 days before or after: matched; 4 days: not', () {
      for (final (manualDate, matched) in [('2026-01-14', 1), ('2026-01-20', 1), ('2026-01-17', 1), ('2026-01-13', 0), ('2026-01-21', 0)]) {
        final r = repoWith([(manualDate, 2340)]);
        final s = r.importBatch(bank([('2026-01-17', -2340, 'POS plaćanje', 'POS EXAMPLE SHOP')]));
        expect(s.matched, matched, reason: manualDate);
        expect(live(r), 2 - matched, reason: manualDate);
        r.close();
      }
    });

    test('across month and year ends', () {
      final r = repoWith([('2026-12-30', 1500), ('2028-02-27', 700)]);
      final s = r.importBatch(
          bank([('2027-01-02', -1500, 'POS plaćanje', 'POS EXAMPLE A'), ('2028-03-01', -700, 'POS plaćanje', 'POS EXAMPLE B')]));
      expect(s.matched, 2);
      r.close();
    });

    test('a different amount (by one cent), an income row or a transfer is never matched', () {
      final r = repoWith([('2026-01-17', 2340), ('2026-01-17', 5000), ('2026-01-17', 3000)]);
      final s = r.importBatch(bank([
        ('2026-01-17', -2341, 'POS plaćanje', 'POS EXAMPLE SHOP'),
        ('2026-01-17', -5000, 'POS plaćanje', 'POS Revolut**0000* Dublin'), // internal transfer
        ('2026-01-17', 3000, 'Ostalo', 'Synthetic refund'), // money in
      ]));
      expect(s.matched, 0);
      expect(live(r), 6);
      r.close();
    });

    test('rent cash (a fixed bill) can be matched to a hand-entered rent', () {
      final r = WalletRepo.inMemory();
      r.addManual(date: '2026-01-15', amount: 55000, category: 'Rent');
      final s = r.importBatch(bank([('2026-01-15', -55000, 'Isplata ATM', 'PBZ ATM TEST')]));
      expect(s.matched, 1);
      r.close();
    });

    test('one bank row matches one manual entry, two bank rows match two; never more', () {
      var r = repoWith([('2026-01-17', 990), ('2026-01-18', 990)]);
      expect(r.importBatch(bank([('2026-01-17', -990, 'POS plaćanje', 'POS EXAMPLE CAFE')])).matched, 1);
      expect(live(r), 2);
      r.close();
      r = repoWith([('2026-01-17', 990)]);
      final s = r.importBatch(
          bank([('2026-01-17', -990, 'POS plaćanje', 'POS EXAMPLE CAFE'), ('2026-01-18', -990, 'POS plaćanje', 'POS EXAMPLE CAFE')]));
      expect(s.matched, 1);
      expect(live(r), 2);
      r.close();
    });

    test('the bank row takes the manual category; the manual row is hidden and counted once', () {
      final r = repoWith([('2026-01-17', 2340)]);
      r.importBatch(january);
      final cz = r.categorizer();
      final bankRow = r.transactions().firstWhere((t) => t.amount == -2340);
      expect(cz.categoryOf(bankRow), 'Eating out');
      final manual = r.transactions(includeHidden: true).firstWhere((t) => t.manual);
      expect(manual.matchedTo, bankRow.id);
      expect(manual.live, isFalse);
      final m = monthSummary(r.transactions().map(cz.categorize).toList(), '2026-01');
      expect(m.byCategory['Eating out'], 2340);
      expect(m.byCategory['Groceries'], isNull);
      r.close();
    });

    test('a deleted or already matched manual entry is not matched again; re-import changes nothing', () {
      final r = repoWith([('2026-01-17', 2340)]);
      final deleted = r.addManual(date: '2026-01-17', amount: 2340, category: 'Shopping');
      r.deleteTransaction(deleted);
      expect(r.importBatch(january).matched, 1);
      final before = r.transactions(includeHidden: true).map((t) => '${t.id}${t.matchedTo}${t.deleted}').toList();
      final again = r.importBatch(january);
      expect((again.added, again.matched, again.duplicates), (0, 0, january.transactions.length));
      expect(r.transactions(includeHidden: true).map((t) => '${t.id}${t.matchedTo}${t.deleted}').toList(), before);
      // A later export with the same row again (overlapping dates) does not match anything either.
      expect(r.importBatch(ImportBatch(source: 'pbz', transactions: [january.transactions[3]])).matched, 0);
      r.close();
    });
  });

  group('re-imports never duplicate', () {
    Future<ImportBatch> file(String name) async => importBankFile(File('../wallet_importer/test/fixtures/$name').readAsBytesSync());

    test('every synthetic fixture: second import adds nothing, also after edits and deletes', () async {
      final r = WalletRepo.inMemory();
      var total = 0;
      for (final name in ['pbz_synthetic.xls', 'revolut_synthetic.xlsx', 'revolut_synthetic.csv']) {
        final b = await file(name);
        final s = r.importBatch(b);
        expect(s.added + s.duplicates, b.transactions.length);
        total += s.added;
      }
      expect(r.transactions().length, total);
      final some = r.transactions().first.id;
      r.setCategory(some, 'Shopping');
      r.deleteTransaction(r.transactions()[1].id);
      for (final name in ['pbz_synthetic.xls', 'revolut_synthetic.xlsx', 'revolut_synthetic.csv']) {
        final s = r.importBatch(await file(name));
        expect(s.added, 0, reason: name);
      }
      expect(r.transactions(includeHidden: true).length, total);
      expect(r.transaction(some)!.category, 'Shopping');
      expect(r.transactions().length, total - 1, reason: 'a deleted row stays deleted after re-import on the same device');
      r.close();
    });

    test('an overlapping later export adds only the new rows', () {
      final r = WalletRepo.inMemory();
      r.importBatch(ImportBatch(source: 'pbz', transactions: january.transactions.sublist(0, 4)));
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: january.transactions.sublist(2)));
      expect((s.added, s.duplicates), (3, 2));
      expect(r.transactions().length, january.transactions.length);
      r.close();
    });

    test('ids from v1 (same algorithm) are recognised as already imported', () {
      final r = WalletRepo.inMemory();
      r.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-01-17', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
      ]));
      expect(r.transaction('260117hpzdpn'), isNotNull, reason: 'v1 id of this row (artifact/index.html makeIds)');
      r.close();
    });
  });
}
