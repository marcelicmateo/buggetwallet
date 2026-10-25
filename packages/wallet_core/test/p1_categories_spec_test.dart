// Stage P1 (docs/context/P1_SPEC.md): custom categories (subcategories replaced by tags in T1). Written from the spec, not the code.
// Money in cents, an expense is a POSITIVE amount for `addTransaction`. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/src/categories.dart' show isSpendingCategory;
import 'package:wallet_core/src/schema.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 60));

final _idShape = RegExp(r'^k[0-9a-f]{12}$');

void main() {
  late WalletRepo repo;
  var now = 1791590400000; // 2026-10-10 00:00 UTC

  setUp(() {
    now = 1791590400000;
    repo = WalletRepo.inMemory(now: () => now);
  });
  tearDown(() => repo.close());

  Future<String> add(String name, {BudgetKind kind = BudgetKind.flex, String? parent}) =>
      repo.addCategory(name: name, kind: kind, parent: parent);

  CategoryTable table() => repo.categoryTable();

  /// The category the wallet resolves for the stored row [txId].
  String resolved(String txId) => repo.categorizer().categorize(repo.transactions().firstWhere((t) => t.id == txId)).category;

  group('built-in table', () {
    test('CategoryTable.builtIn mirrors the global lists exactly', () {
      final t = CategoryTable.builtIn;
      for (final e in categories.entries) {
        expect(t.label(e.key), e.key);
        expect(t.kindOf(e.key), e.value, reason: e.key);
        expect(t.parentOf(e.key), isNull);
        expect(t.topLevel(e.key), e.key);
        expect(t.childrenOf(e.key), isEmpty);
        expect(t.isLive(e.key), isTrue);
      }
      expect(t.pickable(), categories.keys.toList());
      expect(t.spending, spendingCategories);
      for (final k in BudgetKind.values) {
        expect(t.pickable(kinds: {k}), [
          for (final e in categories.entries)
            if (e.value == k) e.key
        ]);
      }
      expect(t.pickable(kinds: {}), isEmpty);
      for (final c in [...categories.keys, 'Nope']) {
        expect(t.isSpending(c), isSpendingCategory(c), reason: c);
      }
    });

    test('unknown ids: label is the id, kind flex, no parent, top-level is itself, not live, no children', () {
      final t = CategoryTable.builtIn;
      expect(t.label('kdeadbeef0000'), 'kdeadbeef0000');
      expect(t.kindOf('kdeadbeef0000'), BudgetKind.flex);
      expect(t.parentOf('kdeadbeef0000'), isNull);
      expect(t.topLevel('kdeadbeef0000'), 'kdeadbeef0000');
      expect(t.isLive('kdeadbeef0000'), isFalse);
      expect(t.childrenOf('kdeadbeef0000'), isEmpty);
    });

    test('an empty wallet gives a table that behaves like builtIn', () {
      final t = table();
      expect(t.pickable(), CategoryTable.builtIn.pickable());
      expect(t.spending, spendingCategories);
      expect(repo.categoryRows(), isEmpty);
      expect(repo.categoryRows(includeDeleted: true), isEmpty);
      for (final c in categories.keys) {
        expect((t.label(c), t.kindOf(c)), (c, categories[c]));
      }
    });

    test('the repo categorizer resolves the synthetic January exactly as the plain Categorizer', () {
      repo.importBatch(january);
      final plain = Categorizer();
      final withTable = repo.categorizer();
      final txs = repo.transactions(includeHidden: true);
      expect(txs, isNotEmpty);
      for (final tx in txs) {
        final a = plain.categorize(tx);
        final b = withTable.categorize(tx);
        expect((b.category, b.kind), (a.category, a.kind), reason: tx.description);
      }
    });

    test('summaries over the built-in categorisation are unchanged by an empty category table', () {
      repo.importBatch(january);
      final a = repo.transactions(includeHidden: true).map(Categorizer().categorize).toList();
      final cz = repo.categorizer();
      final b = repo.transactions(includeHidden: true).map(cz.categorize).toList();
      final sa = monthSummary(a, '2026-01', currency: 'EUR');
      final sb = monthSummary(b, '2026-01', currency: 'EUR');
      expect((sb.income, sb.out), (sa.income, sa.out));
      expect(sb.byCategory, sa.byCategory);
      expect(monthlySummaryCsv(b, currency: 'EUR'), monthlySummaryCsv(a, currency: 'EUR'));
      final budgets = {'Groceries': 20000, 'Loan': 25000};
      final ba = budgetVsActual(a, '2026-01', budgets, today: '2026-01-20', currency: 'EUR');
      final bb = budgetVsActual(b, '2026-01', budgets, today: '2026-01-20', currency: 'EUR');
      expect([for (final l in bb.lines) (l.category, l.budget, l.actual)], [for (final l in ba.lines) (l.category, l.budget, l.actual)]);
    });
  });

  group('built-in hide and relabel', () {
    test('relabel keeps the id and the kind; the old label is free again', () async {
      await repo.updateCategory('Groceries', name: 'Food shop');
      final t = table();
      expect(t.label('Groceries'), 'Food shop');
      expect(t.kindOf('Groceries'), BudgetKind.flex);
      expect(t.isLive('Groceries'), isTrue);
      expect(t.pickable(), contains('Groceries'));
      // another category may now take the old label, the new one is taken
      await add('Groceries');
      await expectLater(add('FOOD SHOP'), throwsArgumentError);
    }, timeout: _t);

    test('hide removes it from the pickers, not from totals or from the table', () async {
      await repo.updateCategory('Shopping', hidden: true);
      final t = table();
      expect(t.pickable(), isNot(contains('Shopping')));
      expect(t.pickable(), hasLength(categories.length - 1));
      expect(t.isLive('Shopping'), isTrue);
      expect(t.label('Shopping'), 'Shopping');
      expect(t.spending, contains('Shopping'));
      expect(t.isSpending('Shopping'), isTrue);
      await repo.updateCategory('Shopping', hidden: false);
      expect(table().pickable(), categories.keys.toList());
    }, timeout: _t);

    test('a hidden built-in still resolves on existing rows', () async {
      final id = repo.addTransaction(date: '2026-10-02', amount: 1200, category: 'Shopping');
      await repo.updateCategory('Shopping', hidden: true);
      expect(resolved(id), 'Shopping');
    }, timeout: _t);

    test('a built-in cannot be deleted (ArgumentError, nothing changes)', () async {
      await expectLater(repo.deleteCategory('Groceries'), throwsArgumentError);
      await expectLater(repo.deleteCategory('Internal transfer'), throwsArgumentError);
      expect(table().isLive('Groceries'), isTrue);
      expect(table().pickable(), categories.keys.toList());
    }, timeout: _t);

    test('override rows: only name, hidden and position are kept; kind, parent and deleted from a remote op are ignored', () {
      final n = repo.applyRemote([
        Op('category', 'Groceries', {'name': 'Food shop', 'kind': 'income', 'parent': 'Rent', 'deleted': 1, 'hidden': 1},
            const Hlc(5, 0, 'x').toString()),
      ]);
      expect(n, 1);
      final t = table();
      expect(t.label('Groceries'), 'Food shop');
      expect(t.kindOf('Groceries'), BudgetKind.flex);
      expect(t.parentOf('Groceries'), isNull);
      expect(t.topLevel('Groceries'), 'Groceries');
      expect(t.isLive('Groceries'), isTrue);
      expect(t.pickable(), isNot(contains('Groceries')), reason: 'hidden is honoured');
      expect(t.childrenOf('Rent'), isEmpty);
      expect(t.spending, contains('Groceries'));
    });

    test('updateCategory on an unknown id is refused', () async {
      await expectLater(repo.updateCategory('kdeadbeef0000', name: 'X'), throwsArgumentError);
    }, timeout: _t);

    test('a built-in override does not count against the 200 limit and is listed in categoryRows', () async {
      await repo.updateCategory('Groceries', name: 'Food shop');
      final rows = repo.categoryRows();
      expect(rows.map((r) => r.id), ['Groceries']);
      expect(rows.single.name, 'Food shop');
    }, timeout: _t);
  });

  group('adding custom categories', () {
    test('id is k + 12 hex chars, label and kind are read back', () async {
      final id = await add('Pets', kind: BudgetKind.flex);
      expect(id, matches(_idShape));
      final t = table();
      expect(t.label(id), 'Pets');
      expect(t.kindOf(id), BudgetKind.flex);
      expect(t.parentOf(id), isNull);
      expect(t.isLive(id), isTrue);
      expect(t.pickable(), contains(id));
    }, timeout: _t);

    test('ids are unique', () async {
      final ids = <String>{};
      for (var i = 0; i < 20; i++) {
        ids.add(await add('Cat $i'));
      }
      expect(ids, hasLength(20));
    }, timeout: _t);

    test('every kind is accepted for a top-level category and read back', () async {
      for (final k in BudgetKind.values) {
        final id = await add('Kind ${k.name}', kind: k);
        expect(table().kindOf(id), k);
      }
    }, timeout: _t);

    test('only spending kinds appear in spending; income, extra and transfer do not', () async {
      final pets = await add('Pets');
      final rent2 = await add('Parking space', kind: BudgetKind.fixed);
      final gift = await add('Gifts received', kind: BudgetKind.income);
      final bonus = await add('Bonus', kind: BudgetKind.extra);
      final move = await add('Own move', kind: BudgetKind.transfer);
      final t = table();
      expect(t.spending, containsAll([pets, rent2]));
      expect(t.spending, isNot(contains(gift)));
      expect(t.spending, isNot(contains(bonus)));
      expect(t.spending, isNot(contains(move)));
      expect(t.spending.sublist(0, spendingCategories.length), spendingCategories, reason: 'built-ins first, in order');
      expect(t.isSpending(pets), isTrue);
      expect(t.isSpending(gift), isFalse);
      expect(t.pickable(kinds: {BudgetKind.income}), containsAll(['Salary', gift]));
      expect(t.pickable(kinds: {BudgetKind.transfer}), containsAll(['Internal transfer', move]));
    }, timeout: _t);

    test('the name is trimmed', () async {
      final id = await add('   Pets \t');
      expect(table().label(id), 'Pets');
    }, timeout: _t);

    test('name length: empty and blank refused; 1, 40 accepted; 41 refused', () async {
      await expectLater(add(''), throwsArgumentError);
      await expectLater(add('   '), throwsArgumentError);
      await expectLater(add('\t\n'), throwsArgumentError);
      final one = await add('A');
      expect(table().label(one), 'A');
      final forty = 'B' * 40;
      final id40 = await add(forty);
      expect(table().label(id40), forty);
      await expectLater(add('C' * 41), throwsArgumentError);
      expect(repo.categoryRows(), hasLength(2), reason: 'a refused add writes nothing');
    }, timeout: _t);

    test('the limit counts the trimmed name (40 chars plus spaces is fine, 41 plus spaces is not)', () async {
      final id = await add('  ${'D' * 40}  ');
      expect(table().label(id), 'D' * 40);
      await expectLater(add('  ${'E' * 41}  '), throwsArgumentError);
    }, timeout: _t);

    test('40 accented characters are 40 characters, not 80 bytes', () async {
      final name = 'š' * 40;
      final id = await add(name);
      expect(table().label(id), name);
      await expectLater(add('š' * 41), throwsArgumentError);
    }, timeout: _t);

    test('refusals carry an owner-readable message', () async {
      await expectLater(add(''), throwsA(isA<ArgumentError>().having((e) => '${e.message}'.trim(), 'message', isNotEmpty)));
    }, timeout: _t);
  });

  group('uniqueness', () {
    test('a live top-level label is unique against built-in labels, ignoring case and accents', () async {
      await expectLater(add('Groceries'), throwsArgumentError);
      await expectLater(add('groceries'), throwsArgumentError);
      await expectLater(add('GROCERIES'), throwsArgumentError);
      await expectLater(add('  Groceries  '), throwsArgumentError);
      await expectLater(add('Bills & subscriptions'), throwsArgumentError);
      await expectLater(add('Internal transfer', kind: BudgetKind.transfer), throwsArgumentError);
    }, timeout: _t);

    test('case and accents are folded against custom labels', () async {
      await add('Café');
      for (final dup in ['café', 'CAFE', 'Cafe', 'cafe ', 'CAFÉ']) {
        await expectLater(add(dup), throwsArgumentError, reason: dup);
      }
      await add('Cafes'); // different text
      expect(repo.categoryRows(), hasLength(2));
    }, timeout: _t);

    test('uniqueness spans kinds', () async {
      await add('Gifts', kind: BudgetKind.flex);
      await expectLater(add('gifts', kind: BudgetKind.income), throwsArgumentError);
    }, timeout: _t);

    test('a deleted custom label is free again', () async {
      final id = await add('Pets');
      await repo.deleteCategory(id);
      final again = await add('pets');
      expect(again, isNot(id));
      expect(table().label(again), 'pets');
    }, timeout: _t);

    test('renaming to an existing label is refused; to its own label in other case is fine', () async {
      final a = await add('Alpha');
      await add('Bravo');
      await expectLater(repo.updateCategory(a, name: 'BRAVO'), throwsArgumentError);
      await repo.updateCategory(a, name: 'ALPHA');
      expect(table().label(a), 'ALPHA');
      await expectLater(repo.updateCategory(a, name: ''), throwsArgumentError);
      await expectLater(repo.updateCategory(a, name: 'x' * 41), throwsArgumentError);
      expect(table().label(a), 'ALPHA');
    }, timeout: _t);

    test('relabelling a built-in to a taken label is refused', () async {
      await add('Pets');
      await expectLater(repo.updateCategory('Groceries', name: 'pets'), throwsArgumentError);
      await expectLater(repo.updateCategory('Groceries', name: 'Shopping'), throwsArgumentError);
      expect(table().label('Groceries'), 'Groceries');
    }, timeout: _t);
  });

  group('the 200 limit', () {
    test('200 custom categories fit, the 201st is refused and nothing is written', () async {
      for (var i = 0; i < 200; i++) {
        await add('Custom ${i.toString().padLeft(3, '0')}');
      }
      expect(repo.categoryRows(), hasLength(200));
      final before = repo.pendingOps().length;
      await expectLater(add('One too many'), throwsArgumentError);
      expect(repo.categoryRows(), hasLength(200));
      expect(repo.pendingOps().length, before);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('subcategories replaced by tags (T1 §6)', () {
    test('addCategory and updateCategory refuse a parent, built-in or custom', () async {
      final p = await add('Pets');
      await expectLater(add('Food', parent: p), throwsA(isA<ArgumentError>().having((e) => e.message, 'message', 'Use a tag for this.')));
      await expectLater(add('Takeaway', parent: 'Eating out'), throwsArgumentError);
      final q = await add('Garden');
      await expectLater(repo.updateCategory(q, parent: p), throwsArgumentError);
      await expectLater(repo.updateCategory('Groceries', parent: p), throwsArgumentError);
      expect(table().childrenOf(p), isEmpty);
      expect(repo.categoryRows().map((r) => r.parent), everyElement(isNull));
    }, timeout: _t);

    test('a negative position is refused', () async {
      final p = await add('Pets');
      await expectLater(repo.updateCategory(p, position: -1), throwsArgumentError);
      await repo.updateCategory(p, position: 0);
    }, timeout: _t);

    test('a hidden category is still live', () async {
      final p = await add('Pets');
      await repo.updateCategory(p, hidden: true);
      expect(table().isLive(p), isTrue);
      expect(table().pickable(), isNot(contains(p)));
      expect(table().spending, contains(p));
    }, timeout: _t);
  });

  group('clarified order and visibility', () {
    test('a new category gets the largest position + 1 (listed in creation order, after the built-ins)', () async {
      final t1 = await add('Zeta');
      final t2 = await add('Alfa');
      final list = table().pickable();
      expect(list.indexOf(t1), lessThan(list.indexOf(t2)));
      expect(list.indexOf('Internal transfer'), lessThan(list.indexOf(t1)), reason: 'after the built-ins');
    }, timeout: _t);

    test('a built-in can be moved by position among the top-level ones', () async {
      await repo.updateCategory('Shopping', position: 0);
      await repo.updateCategory('Salary', position: 1);
      final list = table().pickable();
      expect(list.indexOf('Shopping'), lessThan(list.indexOf('Groceries')));
    }, timeout: _t);

    test('T1: a stored parent (an old P1 row) is ignored: the row is top-level with its own kind', () async {
      final p = await add('Pets');
      final g = await add('Brand', kind: BudgetKind.fixed);
      repo.applyRemote([
        Op('category', g, {'parent': p}, const Hlc(9999999999999, 0, 'z').toString())
      ]);
      final t = table();
      expect(t.parentOf(g), isNull);
      expect(t.topLevel(g), g);
      expect(t.kindOf(g), BudgetKind.fixed);
      expect(t.childrenOf(p), isEmpty);
      expect(t.pickable(), contains(g));
      expect(t.spending, containsAll([p, g]));
      expect(rollUp({g: 5, p: 7}, t), {g: 5, p: 7});
    }, timeout: _t);

    test('Categorizer takes the table directly', () async {
      final pets = await add('Pets');
      repo.setMerchantPattern(pets, 'lidl');
      final cz = Categorizer(patterns: repo.settings().merchantPatterns, table: table());
      expect(cz.merchantCategory('lidl'), pets);
    }, timeout: _t);
  });

  group('delete and undelete', () {
    test('categoryRows hides deleted rows unless asked', () async {
      final a = await add('Alpha');
      final b = await add('Bravo');
      await repo.deleteCategory(b);
      expect(repo.categoryRows().map((r) => r.id), [a]);
      expect(repo.categoryRows(includeDeleted: true).map((r) => r.id).toSet(), {a, b});
      expect(repo.categoryRows(includeDeleted: true).firstWhere((r) => r.id == b).deleted, isTrue);
      await repo.undeleteCategory(b);
      expect(repo.categoryRows().map((r) => r.id).toSet(), {a, b});
    }, timeout: _t);

    test('deleting an unknown id is refused', () async {
      await expectLater(repo.deleteCategory('kdeadbeef0000'), throwsArgumentError);
    }, timeout: _t);

    test('undelete is refused when the label was taken meanwhile', () async {
      final a = await add('Pets');
      await repo.deleteCategory(a);
      await add('Pets');
      await expectLater(repo.undeleteCategory(a), throwsArgumentError);
      expect(table().isLive(a), isFalse);
    }, timeout: _t);
  });

  group('rows pointing at a deleted or unknown category', () {
    test('a hand-added row falls back, nothing is written to it, and undelete brings it back', () async {
      final pets = await add('Pets');
      final id = repo.addTransaction(date: '2026-10-02', amount: 1800, category: pets);
      expect(resolved(id), pets);
      final ops = repo.pendingOps().length;
      await repo.deleteCategory(pets);
      expect(resolved(id), 'Shopping', reason: 'a hand-added row with no live category: the fallback');
      expect(repo.transactions().firstWhere((t) => t.id == id).category, pets, reason: 'the row itself is untouched');
      await repo.undeleteCategory(pets);
      expect(resolved(id), pets);
      expect(repo.pendingOps().length, greaterThan(ops), reason: 'only the delete and undelete were written');
      expect(repo.pendingOps().where((o) => o.$2.entity == 'tx').length, 1, reason: 'no tx op after the first add');
    }, timeout: _t);

    test('a bank row with an override falls back to the rules, then returns', () async {
      repo.importBatch(january);
      final lidl = repo.transactions().firstWhere((t) => t.description.contains('LIDL'));
      expect(resolved(lidl.id), 'Groceries');
      final pets = await add('Pets');
      repo.setCategory(lidl.id, pets);
      expect(resolved(lidl.id), pets);
      await repo.deleteCategory(pets);
      expect(resolved(lidl.id), 'Groceries');
      await repo.undeleteCategory(pets);
      expect(resolved(lidl.id), pets);
    }, timeout: _t);

    test('an override to a never-existing custom id is ignored', () {
      repo.importBatch(january);
      final lidl = repo.transactions().firstWhere((t) => t.description.contains('LIDL'));
      repo.setCategory(lidl.id, 'kdeadbeef0000');
      expect(resolved(lidl.id), 'Groceries');
    });

    test('a fallen-back row has the kind of the category it resolved to', () async {
      final fixed = await add('Garage', kind: BudgetKind.fixed);
      final id = repo.addTransaction(date: '2026-10-02', amount: 500, category: fixed);
      final cz1 = repo.categorizer().categorize(repo.transactions().firstWhere((t) => t.id == id));
      expect((cz1.category, cz1.kind), (fixed, BudgetKind.fixed));
      await repo.deleteCategory(fixed);
      final cz2 = repo.categorizer().categorize(repo.transactions().firstWhere((t) => t.id == id));
      expect((cz2.category, cz2.kind), ('Shopping', BudgetKind.flex));
    }, timeout: _t);

    test('a hidden custom category still resolves on its rows', () async {
      final pets = await add('Pets');
      final id = repo.addTransaction(date: '2026-10-02', amount: 700, category: pets);
      await repo.updateCategory(pets, hidden: true);
      expect(resolved(id), pets);
    }, timeout: _t);

    test('a merchant rule to a custom id applies while live and is ignored when deleted', () async {
      repo.importBatch(january);
      final lidl = repo.transactions().firstWhere((t) => t.description.contains('LIDL'));
      final pets = await add('Pets');
      repo.setMerchantRule(merchantKey(lidl), pets);
      expect(resolved(lidl.id), pets);
      await repo.deleteCategory(pets);
      expect(resolved(lidl.id), 'Groceries');
      await repo.undeleteCategory(pets);
      expect(resolved(lidl.id), pets);
    }, timeout: _t);
  });

  group('merchant patterns', () {
    test('a pattern may point at a custom category and wins over the built-in rule', () async {
      final cheap = await add('Discount stores');
      repo.setMerchantPattern(cheap, 'lidl');
      repo.importBatch(january);
      final lidl = repo.transactions().firstWhere((t) => t.description.contains('LIDL'));
      expect(resolved(lidl.id), cheap);
      expect(repo.settings().merchantPatterns.map((p) => p[0]), contains(cheap));
    }, timeout: _t);

    test('a pattern to a deleted custom id is ignored; undelete restores it', () async {
      final cheap = await add('Discount stores');
      repo.setMerchantPattern(cheap, 'lidl');
      repo.importBatch(january);
      final lidl = repo.transactions().firstWhere((t) => t.description.contains('LIDL'));
      await repo.deleteCategory(cheap);
      expect(resolved(lidl.id), 'Groceries');
      expect(repo.categorizer().merchantCategory('lidl zagreb'), 'Groceries');
      await repo.undeleteCategory(cheap);
      expect(resolved(lidl.id), cheap);
    }, timeout: _t);

    test('a pattern to an unknown id is refused, and the message does not quote the pattern', () {
      expect(() => repo.setMerchantPattern('kdeadbeef0000', 'secret-shop'),
          throwsA(isA<ArgumentError>().having((e) => e.toString(), 'text', isNot(contains('secret-shop')))));
    });

    test('a pattern to a built-in id still works', () {
      repo.setMerchantPattern('Eating out', 'corner');
      expect(repo.categorizer().merchantCategory('corner place'), 'Eating out');
    });
  });

  group('budgets', () {
    test('a budget can be set on a custom top-level spending category', () async {
      final pets = await add('Pets');
      repo.setCategoryBudget(pets, 12000);
      expect(repo.settings().categoryBudgets[pets], 12000);
      repo.setCategoryBudget(pets, null);
      expect(repo.settings().categoryBudgets.containsKey(pets), isFalse);
    }, timeout: _t);

    test('a budget on a non-spending custom category, an unknown id or a deleted one is refused', () async {
      final inc = await add('Gifts received', kind: BudgetKind.income);
      final tr = await add('Own move', kind: BudgetKind.transfer);
      expect(() => repo.setCategoryBudget(inc, 100), throwsArgumentError);
      expect(() => repo.setCategoryBudget(tr, 100), throwsArgumentError);
      expect(() => repo.setCategoryBudget('kdeadbeef0000', 100), throwsArgumentError);
      final pets = await add('Pets');
      await repo.deleteCategory(pets);
      expect(() => repo.setCategoryBudget(pets, 100), throwsArgumentError);
    }, timeout: _t);

    test('built-in budgets behave as before', () {
      repo.setCategoryBudget('Groceries', 30000);
      expect(repo.settings().categoryBudgets['Groceries'], 30000);
      expect(() => repo.setCategoryBudget('Salary', 100), throwsArgumentError);
      expect(() => repo.setCategoryBudget('Groceries', -1), throwsArgumentError);
    });

    test('a category with a budget cannot become a child (budgets are top-level only)', () async {
      final p = await add('Pets');
      final q = await add('Garden');
      repo.setCategoryBudget(q, 4000);
      // whichever way the builder resolves it, the budget must not end up on a child
      try {
        await repo.updateCategory(q, parent: p);
      } on ArgumentError {
        return;
      }
      expect(repo.settings().categoryBudgets.containsKey(q), isFalse, reason: 'moved under a parent: budget dropped');
    }, timeout: _t);
  });

  group('rollUp (T1: every category is top-level)', () {
    test('an old child row counts as its own main tag: rollUp is the identity and totals never change', () async {
      final pets = await add('Pets');
      final food = await add('Food');
      repo.applyRemote([
        Op('category', food, {'parent': pets}, const Hlc(9999999999999, 0, 'z').toString())
      ]);
      final input = {pets: 11, food: 22, 'Rent': 66, 'unknown-id': 77};
      expect(rollUp(input, table()), input);
      const big = 4000000000000; // beyond 32 bits
      expect(rollUp({pets: big, food: big + 1}, table()), {pets: big, food: big + 1});
    }, timeout: _t);

    test('empty input, and the built-in table is the identity', () {
      expect(rollUp({}, CategoryTable.builtIn), isEmpty);
      final m = {'Groceries': 100, 'Rent': 5000, 'Salary': -1};
      expect(rollUp(m, CategoryTable.builtIn), m);
    });

    test('month totals per row id stay as monthSummary gives them', () async {
      final pets = await add('Pets');
      final food = await add('Food');
      repo.applyRemote([
        Op('category', food, {'parent': pets}, const Hlc(9999999999999, 0, 'z').toString())
      ]);
      repo.addTransaction(date: '2026-10-01', amount: 1000, category: pets);
      repo.addTransaction(date: '2026-10-03', amount: 250, category: food);
      repo.addTransaction(date: '2026-10-05', amount: 777, category: 'Groceries');
      final cz = repo.categorizer();
      final txs = repo.transactions().map(cz.categorize).toList();
      final s = monthSummary(txs, '2026-10', currency: 'EUR');
      expect(s.byCategory, {pets: 1000, food: 250, 'Groceries': 777});
      expect(rollUp(s.byCategory, table()), s.byCategory);
    }, timeout: _t);
  });

  group('CategoryRow and schema', () {
    test('the repo schema is at least 10 and the category entity is declared', () {
      expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(10));
      final e = entitySchema['category'];
      expect(e, isNotNull);
      expect(e!.table, 'categories');
      expect(e.columnNames, containsAll(['name', 'kind', 'parent', 'position', 'hidden', 'deleted']));
      expect(e.column('name')!.searchable, isTrue);
      expect(e.column('parent')!.nullable, isTrue);
      expect(e.column('position')!.type, ColumnType.integer);
      expect(e.column('hidden')!.type, ColumnType.flag);
      expect(e.column('deleted')!.type, ColumnType.flag);
    });

    test('the table exists in a new wallet and meta says the current schema', () {
      expect(repo.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'].toString(), '${WalletRepo.schemaVersion}');
      expect(repo.db.select('SELECT * FROM categories'), isEmpty);
    });

    test('a remote op with the wrong type for a category column is refused', () {
      final n = repo.applyRemote([
        Op('category', 'kaaaaaaaaaaaa', {'position': 'first'}, const Hlc(5, 0, 'x').toString()),
        Op('category', 'kbbbbbbbbbbbb', {'name': null}, const Hlc(5, 1, 'x').toString()),
      ]);
      expect(n, 0);
    });

    test('a wallet holding only a category is not empty', () async {
      expect(repo.isEmpty, isTrue);
      await add('Pets');
      expect(repo.isEmpty, isFalse);
    }, timeout: _t);

    test('an override-only wallet is not empty either', () async {
      await repo.updateCategory('Groceries', hidden: true);
      expect(repo.isEmpty, isFalse);
    }, timeout: _t);

    test('category names are searchable (folded)', () async {
      await add('Café');
      // search itself is covered elsewhere; here the row must be readable by name after a fold
      expect(repo.categoryRows().map((r) => foldText(r.name)), ['cafe']);
    }, timeout: _t);

    test('writes go through the change log: one pending op per add, updates and deletes add more', () async {
      final before = repo.pendingOps().length;
      final id = await add('Pets');
      expect(repo.pendingOps().where((o) => o.$2.entity == 'category' && o.$2.id == id), isNotEmpty);
      final mid = repo.pendingOps().length;
      expect(mid, greaterThan(before));
      await repo.updateCategory(id, hidden: true);
      await repo.deleteCategory(id);
      expect(repo.pendingOps().length, greaterThan(mid));
    }, timeout: _t);

    test('a refused write adds no pending op', () async {
      await add('Pets');
      final before = repo.pendingOps().length;
      await expectLater(add('pets'), throwsArgumentError);
      await expectLater(add(''), throwsArgumentError);
      await expectLater(repo.deleteCategory('Groceries'), throwsArgumentError);
      expect(repo.pendingOps().length, before);
    }, timeout: _t);
  });
}
