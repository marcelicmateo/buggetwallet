// Stage P6 spec tests, repo half: setSplit validation, read model through the repo, broken splits, whole-payment paths,
// manual entry matched to a bank row, CSV, search, schema 12 -> 13, backup, two devices. Written from
// docs/context/P6_SPEC.md only. SYNTHETIC data.
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:wallet_core/src/schema.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';
import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 30));

SplitPart _p(int amount, [String category = 'Groceries', List<String> tags = const [], String? note]) =>
    SplitPart(amount: amount, category: category, tags: tags, note: note);

List<String> _rec(List<SplitPart>? parts) =>
    [for (final p in parts ?? const <SplitPart>[]) '${p.amount}|${p.category}|${p.tags.join(',')}|${p.note ?? ''}'];

List<int> _amts(List<SplitPart>? parts) => [for (final p in parts ?? const <SplitPart>[]) p.amount];

String _hlc(int n) => Hlc(9999999999000 + n, 0, 'z').toString();

void main() {
  late WalletRepo r;
  var now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
  setUp(() {
    now = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
    r = WalletRepo.inMemory(now: () => now);
  });
  tearDown(() => r.close());

  /// A hand-added expense of [cents] (positive); the stored amount is -cents.
  String manual(String date, int cents, {String category = 'Shopping', String currency = 'EUR'}) =>
      r.addTransaction(date: date, amount: cents, category: category, currency: currency);

  /// A bank row; returns its id.
  String bank(String date, int cents, String desc, {String type = 'POS plaćanje'}) {
    final row = n(date, cents, type, desc);
    r.importBatch(ImportBatch(source: 'pbz', transactions: [row]));
    return row.id;
  }

  List<CategorizedTx> expanded() {
    final c = r.categorizer();
    return [for (final t in r.transactions()) ...c.expand(t)];
  }

  List<CategorizedTx> whole() {
    final c = r.categorizer();
    return [for (final t in r.transactions()) c.categorize(t)];
  }

  List<CategorizedTx> rowsOf(String id) => expanded().where((x) => x.tx.id == id).toList();

  void refused(String id, List<SplitPart> parts, {String? why}) {
    final before = r.pendingOps().length;
    expect(() => r.setSplit(id, parts), throwsArgumentError, reason: why);
    expect(r.pendingOps().length, before, reason: 'nothing written: ${why ?? ''}');
  }

  group('validation', () {
    late String id;
    setUp(() => id = manual('2026-03-12', 10000));

    test('2 parts summing exactly are saved; splitOf returns them in order', () {
      r.setSplit(id, [_p(-6000, 'Groceries', const [], 'milk'), _p(-4000, 'Shopping')]);
      expect(_rec(r.splitOf(id)), ['-6000|Groceries||milk', '-4000|Shopping||']);
      expect(r.splits().keys, [id]);
    });

    test('1 part and 0 parts are refused', () {
      refused(id, [_p(-10000)], why: 'one part');
      refused(id, const [], why: 'no parts');
    });

    test('20 parts are saved, 21 are refused', () {
      r.setSplit(id, [for (var i = 0; i < 20; i++) _p(-500)]);
      expect(r.splitOf(id), hasLength(20));
      final big = manual('2026-03-12', 10500);
      refused(big, [for (var i = 0; i < 21; i++) _p(-500)], why: '21 parts');
    });

    test('one cent short and one cent over are refused', () {
      refused(id, [_p(-5000), _p(-4999)], why: 'short');
      refused(id, [_p(-5000), _p(-5001)], why: 'over');
      r.setSplit(id, [_p(-5000), _p(-5000)]);
    });

    test('a part of the wrong sign is refused even when the sum matches', () {
      refused(id, [_p(-12000), _p(2000)], why: 'sign');
    });

    test('a zero part is refused', () {
      refused(id, [_p(-10000), _p(0)], why: 'zero');
    });

    test('an income payment splits into positive parts only', () {
      final inc = bank('2026-03-10', 20000, 'Neto plaća', type: 'Plaća/Mirovina');
      refused(inc, [_p(-5000, 'Salary'), _p(25000, 'Salary')], why: 'negative part of income');
      r.setSplit(inc, [_p(15000, 'Salary'), _p(5000, 'Extra income')]);
      expect(r.splitOf(inc), hasLength(2));
    });

    test('a transfer payment cannot be split (category and transferTo)', () {
      final tr = manual('2026-03-12', 3000, category: 'Internal transfer');
      refused(tr, [_p(-1000), _p(-2000)], why: 'transfer category');
      final paired = manual('2026-03-12', 3000);
      r.applyRemote([
        Op('tx', paired, {'transfer_to': 'other-row'}, _hlc(1))
      ]);
      refused(paired, [_p(-1000), _p(-2000)], why: 'transferTo set');
    });

    test('a part in a transfer category is refused', () {
      refused(id, [_p(-6000), _p(-4000, 'Internal transfer')]);
    });

    test('an unknown or deleted category is refused', () async {
      refused(id, [_p(-6000), _p(-4000, 'No such category')], why: 'unknown');
      final k = await r.addCategory(name: 'Pets', kind: BudgetKind.flex);
      r.setSplit(id, [_p(-6000), _p(-4000, k)]);
      await r.deleteCategory(k);
      final id2 = manual('2026-03-13', 10000);
      refused(id2, [_p(-6000), _p(-4000, k)], why: 'deleted');
    });

    test('a deleted or unknown tag is refused; the same tag in two parts is fine', () async {
      final a = await r.addTag('Trip'), b = await r.addTag('Gift');
      refused(
          id,
          [
            _p(-6000, 'Groceries', ['nope']),
            _p(-4000)
          ],
          why: 'unknown tag');
      r.setSplit(id, [
        _p(-6000, 'Groceries', [a, b]),
        _p(-4000, 'Shopping', [a])
      ]);
      await r.deleteTag(b);
      final id2 = manual('2026-03-13', 10000);
      refused(
          id2,
          [
            _p(-6000, 'Groceries', [b]),
            _p(-4000)
          ],
          why: 'deleted tag');
    });

    test('a repeated tag inside one part is refused', () async {
      final a = await r.addTag('Trip');
      refused(id, [
        _p(-6000, 'Groceries', [a, a]),
        _p(-4000)
      ]);
    });

    test('20 tags in a part are saved, 21 are refused', () async {
      final tags = [for (var i = 0; i < 21; i++) await r.addTag('Tag number $i')];
      refused(id, [_p(-6000, 'Groceries', tags), _p(-4000)], why: '21 tags');
      r.setSplit(id, [_p(-6000, 'Groceries', tags.take(20).toList()), _p(-4000)]);
      expect(r.splitOf(id)!.first.tags, hasLength(20));
    });

    test('a note of 200 characters is saved, 201 is refused; notes are trimmed, blank = null', () {
      refused(id, [_p(-6000, 'Groceries', const [], 'x' * 201), _p(-4000)], why: '201');
      r.setSplit(id, [_p(-6000, 'Groceries', const [], 'x' * 200), _p(-4000, 'Shopping', const [], '   ')]);
      expect(r.splitOf(id)![0].note, 'x' * 200);
      expect(r.splitOf(id)![1].note, isNull);
      r.setSplit(id, [_p(-6000, 'Groceries', const [], '  bread  '), _p(-4000)]);
      expect(r.splitOf(id)![0].note, 'bread');
    });

    test('an unknown, deleted or missing payment is refused', () {
      refused('nope', [_p(-6000), _p(-4000)], why: 'unknown');
      r.deleteTransaction(id);
      refused(id, [_p(-6000), _p(-4000)], why: 'deleted');
    });

    test('a payment in another currency can be split (the parts are in its currency)', () {
      final usd = manual('2026-03-12', 10000, currency: 'USD');
      r.setSplit(usd, [_p(-6000), _p(-4000)]);
      expect(r.splitOf(usd), hasLength(2));
    });

    test('setSplit replaces the whole split; removeSplit removes it; setSplit again undeletes', () {
      r.setSplit(id, [_p(-6000), _p(-4000, 'Shopping')]);
      r.setSplit(id, [_p(-1000), _p(-9000, 'Cash')]);
      expect(_amts(r.splitOf(id)), [-1000, -9000]);
      r.removeSplit(id);
      expect(r.splitOf(id), isNull);
      expect(r.splits(), isEmpty);
      r.setSplit(id, [_p(-2500), _p(-7500)]);
      expect(_amts(r.splitOf(id)), [-2500, -7500]);
    });

    test('a refused edit leaves the earlier split in place', () {
      r.setSplit(id, [_p(-6000), _p(-4000, 'Shopping')]);
      expect(() => r.setSplit(id, [_p(-6000), _p(-3000)]), throwsArgumentError);
      expect(_amts(r.splitOf(id)), [-6000, -4000]);
    });

    test('deleteTransaction leaves the split alone; the undelete brings it back', () {
      r.setSplit(id, [_p(-6000), _p(-4000, 'Shopping')]);
      r.deleteTransaction(id);
      expect(r.splitOf(id), hasLength(2));
      expect(r.categorizer().expand(r.transaction(id)!), hasLength(1), reason: 'a deleted payment is one dead row, not parts');
      expect(rowsOf(id), isEmpty, reason: 'transactions() leaves deleted rows out');
      r.undeleteTransaction(id);
      expect(rowsOf(id), hasLength(2));
    });

    test('the write is logged as ops: one split op, no other entity', () {
      final before = r.pendingOps().length;
      r.setSplit(id, [_p(-6000), _p(-4000, 'Shopping')]);
      final ops = r.pendingOps().skip(before).map((x) => x.$2).toList();
      expect(ops, isNotEmpty);
      expect(ops.map((o) => o.entity).toSet(), {'split'});
      expect(ops.every((o) => o.id == id), isTrue);
    });
  });

  group('read model through the repo', () {
    test('expand: parts in stored order, part fields, tx is the payment', () async {
      final a = await r.addTag('Trip');
      final id = manual('2026-03-12', 10000);
      r.setSplit(id, [
        _p(-6000, 'Groceries', [a], 'milk'),
        _p(-4000, 'Shopping')
      ]);
      final rows = rowsOf(id);
      expect(rows.map((x) => (x.amount, x.category, x.part, x.parts, x.partNote, x.splitBroken)),
          [(-6000, 'Groceries', 0, 2, 'milk', false), (-4000, 'Shopping', 1, 2, null, false)]);
      expect(rows.every((x) => x.tx.id == id && x.tx.amount == -10000), isTrue);
      expect(rows[0].tags, [a]);
      expect(rows[1].tags, isEmpty);
    });

    test('part tags are the part own list only: the payment tag links do not apply to parts', () async {
      final a = await r.addTag('Trip'), b = await r.addTag('Gift');
      final id = manual('2026-03-12', 10000);
      await r.setTxTag(id, b, true);
      r.setSplit(id, [
        _p(-6000, 'Groceries', [a]),
        _p(-4000)
      ]);
      final rows = rowsOf(id);
      expect(rows[0].tags, [a]);
      expect(rows[1].tags, isEmpty);
      final w = r.categorizer().categorize(r.transactions().firstWhere((t) => t.id == id));
      expect(w.tags, [b], reason: 'categorize (whole payment) is unchanged');
      expect(w.amount, -10000);
    });

    test('a hand-added amount edited after the split: counted whole, splitBroken; fixing the split heals it', () {
      final id = manual('2026-03-12', 10000);
      r.setSplit(id, [_p(-6000), _p(-4000, 'Shopping')]);
      r.applyRemote([
        Op('tx', id, {'amount': -12000}, _hlc(2))
      ]);
      final rows = rowsOf(id);
      expect(rows, hasLength(1));
      expect((rows.single.amount, rows.single.splitBroken, rows.single.part, rows.single.parts), (-12000, true, null, 0));
      expect(monthSummary(expanded(), '2026-03', currency: 'EUR').out, 12000);
      expect(r.splitOf(id), hasLength(2), reason: 'the stored split is kept (live, not valid)');
      r.setSplit(id, [_p(-7000), _p(-5000, 'Shopping')]);
      expect(rowsOf(id), hasLength(2));
      expect(rowsOf(id).every((x) => !x.splitBroken), isTrue);
    });

    test('an unreadable stored split is ignored: whole payment, splitBroken', () {
      final id = manual('2026-03-12', 10000);
      r.applyRemote([
        Op('split', id, {'parts': 'this is not json', 'deleted': 0}, _hlc(3))
      ]);
      final rows = rowsOf(id);
      expect(rows, hasLength(1));
      expect((rows.single.amount, rows.single.splitBroken), (-10000, true));
    });

    test('a part whose category is gone falls back to the payment automatic category; a dead tag is dropped', () async {
      final id = bank('2026-03-12', -10000, 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB');
      final k = await r.addCategory(name: 'Pets', kind: BudgetKind.flex);
      final tag = await r.addTag('Trip');
      r.setSplit(id, [
        _p(-6000, k, [tag]),
        _p(-4000, 'Shopping')
      ]);
      expect(rowsOf(id)[0].category, k);
      await r.deleteCategory(k);
      await r.deleteTag(tag);
      final rows = rowsOf(id);
      expect(rows[0].category, 'Groceries', reason: 'the payment own automatic category');
      expect(rows[0].tags, isEmpty);
      expect(rows[0].splitBroken, isFalse);
      expect(rows[1].category, 'Shopping');
    });

    test('a bank payment can be split and counts as its parts', () {
      final id = bank('2026-03-12', -10000, 'ZORBLEX MARKET');
      r.setSplit(id, [_p(-6000), _p(-4000, 'Shopping')]);
      final s = monthSummary(expanded(), '2026-03', currency: 'EUR');
      expect(s.out, 10000);
      expect(s.byCategory, {'Groceries': 6000, 'Shopping': 4000});
    });
  });

  group('totals', () {
    test('category and tag totals equal the parts; the payment is never counted with them', () async {
      final a = await r.addTag('Trip');
      final id = manual('2026-03-12', 10000);
      manual('2026-03-13', 2500, category: 'Groceries');
      r.setSplit(id, [
        _p(-6000, 'Groceries', [a]),
        _p(-4000, 'Shopping')
      ]);
      final txs = expanded();
      final s = monthSummary(txs, '2026-03', currency: 'EUR');
      expect(s.out, 12500);
      expect(s.byCategory, {'Groceries': 8500, 'Shopping': 4000});
      final range = DateRange(start: '2026-03-01', end: '2026-03-31');
      expect(categoryShare(txs, range, currency: 'EUR').total, 12500);
      final tags = tagShare(txs, range, currency: 'EUR');
      expect(tags.slices.map((x) => (x.tag, x.spent)), [(a, 6000)]);
      expect(tags.untaggedSpent, 6500);
      final bva = budgetVsActual(txs, '2026-03', {'Groceries': 10000}, today: '2026-03-15', currency: 'EUR', table: r.categoryTable());
      expect(bva.lines.firstWhere((l) => l.category == 'Groceries').actual, 8500);
    });

    test('safe to spend: a Rent part is fixed, a Groceries part is flex', () {
      final id = manual('2026-03-12', 10000);
      r.setSplit(id, [_p(-4000, 'Rent'), _p(-6000, 'Groceries')]);
      const st = WalletSettings(salary: 200000, paydayDay: 10, periodStart: '2026-03-10');
      final p = computePeriod(expanded(), st, const [], '2026-03-15', table: r.categoryTable());
      expect(p.spent, 6000);
      expect(p.fixedPaid['Rent'], 4000);
      final pw = computePeriod(whole(), st, const [], '2026-03-15', table: r.categoryTable());
      expect(pw.spent, 10000, reason: 'the whole payment (Shopping override) is flex');
    });
  });

  group('identity without splits', () {
    void seed(WalletRepo x) {
      x.importBatch(ImportBatch(source: 'pbz', transactions: [
        n('2026-03-02', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
        n('2026-03-05', -25000, 'Trajni nalog', 'Naplata kredita 0000000000'),
        n('2026-03-10', 150000, 'Plaća/Mirovina', 'Neto plaća za 02/2026'),
        n('2026-03-12', -9000, 'POS plaćanje', 'ZORBLEX MARKET'),
        n('2026-03-14', -1999, 'POS plaćanje', 'QUORVANT SHOP'),
      ]));
    }

    String key(WalletRepo x) {
      final c = x.categorizer();
      final rows = [for (final t in x.transactions()) ...c.expand(t)];
      final s = monthSummary(rows, '2026-03', currency: 'EUR');
      final p = computePeriod(
          rows, const WalletSettings(salary: 150000, paydayDay: 10, periodStart: '2026-03-10', rent: 25000), const [], '2026-03-14',
          table: x.categoryTable());
      final range = DateRange(start: '2026-03-01', end: '2026-03-31');
      final b = budgetVsActual(rows, '2026-03', {'Groceries': 5000}, today: '2026-03-14', currency: 'EUR');
      return [
        s.income,
        s.out,
        s.byCategory,
        p.spent,
        p.remaining,
        p.fixedPaid,
        p.allowanceToday,
        categoryShare(rows, range, currency: 'EUR').slices,
        b.lines.map((l) => (l.category, l.actual, l.remaining)).toList(),
        transactionsCsv(rows),
        monthlySummaryCsv(rows, currency: 'EUR'),
      ].join('|');
    }

    test('expand equals categorize for every row of a wallet without splits', () {
      seed(r);
      final c = r.categorizer();
      for (final t in r.transactions()) {
        final e = c.expand(t);
        final w = c.categorize(t);
        expect(e, hasLength(1));
        expect((e.single.category, e.single.amount, e.single.tags, e.single.part, e.single.splitBroken),
            (w.category, w.amount, w.tags, null, false));
      }
    });

    test('a wallet that had a split removed gives exactly the results of one that never had one', () {
      final other = WalletRepo.inMemory(now: () => now);
      addTearDown(other.close);
      seed(r);
      seed(other);
      final target = r.transactions().firstWhere((t) => t.amount == -9000).id;
      r.setSplit(target, [_p(-5000), _p(-4000, 'Shopping')]);
      expect(key(r), isNot(key(other)), reason: 'the split changes the totals (sanity)');
      r.removeSplit(target);
      expect(key(r), key(other));
    });

    test('a split on one payment leaves every other row alone', () {
      seed(r);
      final before = {for (final x in whole()) x.tx.id: (x.category, x.amount)};
      final target = r.transactions().firstWhere((t) => t.amount == -9000).id;
      r.setSplit(target, [_p(-5000), _p(-4000, 'Shopping')]);
      for (final x in expanded()) {
        if (x.tx.id == target) continue;
        expect((x.category, x.amount), before[x.tx.id]);
      }
    });
  });

  group('whole-payment paths are unaffected', () {
    test('detectRecurring sees the whole payments, split or not', () {
      final ids = [
        bank('2026-01-05', -3000, 'ZORBLEX CLUB 2026'),
        bank('2026-02-05', -3000, 'ZORBLEX CLUB 2026'),
        bank('2026-03-05', -3000, 'ZORBLEX CLUB 2026'),
      ];
      final before = detectRecurring(whole(), today: '2026-03-20', currency: 'EUR');
      expect(before, hasLength(1), reason: 'sanity: it is detected');
      r.setSplit(ids[1], [_p(-1000, 'Bills & subscriptions'), _p(-2000, 'Shopping')]);
      final after = detectRecurring(whole(), today: '2026-03-20', currency: 'EUR');
      expect(after.map((b) => (b.id, b.expectedAmount, b.nextDue, b.category)),
          before.map((b) => (b.id, b.expectedAmount, b.nextDue, b.category)));
    });

    test('accountBalances count the whole payment amount', () async {
      await r.addAccount(name: 'Main', source: 'pbz', currency: 'EUR', opening: 100000, openingDate: '2026-01-01');
      final id = bank('2026-03-05', -3000, 'ZORBLEX CLUB');
      bank('2026-03-06', 5000, 'REFUND SYNTH', type: 'Ostalo');
      final before = accountBalances(r.accounts(), r.transactions()).single.balance;
      expect(before, 102000);
      r.setSplit(id, [_p(-1000), _p(-2000, 'Shopping')]);
      expect(accountBalances(r.accounts(), r.transactions()).single.balance, before);
    });

    test('a manual entry with a split matched to a bank row keeps the split and counts once', () {
      final m = manual('2026-03-10', 5000);
      r.setSplit(m, [_p(-3000), _p(-2000, 'Shopping')]);
      final res = r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-03-11', -5000, 'POS plaćanje', 'ZORBLEX SHOP')]));
      expect(res.matched, 1);
      final s = monthSummary(expanded(), '2026-03', currency: 'EUR');
      expect(s.out, 5000, reason: 'entry and bank row count once');
      expect(s.byCategory, {'Groceries': 3000, 'Shopping': 2000}, reason: 'the split follows the entry onto the bank row');
    });
  });

  group('CSV and search', () {
    test('transactionsCsv has one line per part and one per unsplit payment', () {
      final id = manual('2026-03-12', 10000);
      manual('2026-03-13', 1250);
      r.setSplit(id, [_p(-6000, 'Groceries', const [], 'milk'), _p(-4000, 'Shopping')]);
      final lines = transactionsCsv(expanded()).trim().split('\n');
      expect(lines, hasLength(4));
      expect(lines[1], startsWith('2026-03-12,-60.00,Groceries,'));
      expect(lines[1], endsWith(',milk'));
      expect(lines[2], startsWith('2026-03-12,-40.00,Shopping,'));
      expect(lines[3], startsWith('2026-03-13,-12.50,Shopping,'));
    });

    SearchResult search(String q) =>
        searchAll(q, txs: expanded(), goals: const [], wishlist: const [], bills: const [], table: r.categoryTable(), tags: r.tagTable());

    test('a part note finds the payment once; a payment text match with two parts is still one result', () async {
      final id = bank('2026-03-12', -10000, 'ZORBLEX MARKET');
      r.setSplit(id, [_p(-6000, 'Groceries', const [], 'quorvantnote'), _p(-4000, 'Shopping')]);
      final byNote = search('quorvantnote');
      expect(byNote.txs.map((x) => x.tx.id), [id]);
      expect(search('zorblex').txs.map((x) => x.tx.id), [id], reason: 'both parts match the description: one payment');
      expect(search('nothing-like-this').txs, isEmpty);
    });

    test('a part tag finds the payment once', () async {
      final tag = await r.addTag('Zorbtrip');
      final id = manual('2026-03-12', 10000);
      r.setSplit(id, [
        _p(-6000, 'Groceries', [tag]),
        _p(-4000)
      ]);
      expect(search('zorbtrip').txs.map((x) => x.tx.id), [id]);
    });
  });

  group('schema 13', () {
    test('schema version is 13 and the split entity is declared', () {
      expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(13)); // P9 made it 14
      final e = entitySchema['split']!;
      expect(e.table, 'tx_splits');
      expect(e.columnNames, containsAll(['parts', 'deleted']));
      expect(e.column('parts')!.type, ColumnType.text);
      expect(e.column('deleted')!.type, ColumnType.flag);
      expect(entityTables['split']!.$1, 'tx_splits');
    });

    test('a schema 12 database opens: table added, old rows untouched, meta says 13', () {
      final tmp = Directory.systemTemp.createTempSync('bw-p6-schema-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/old.db';
      final w = WalletRepo.open(path, now: () => now);
      final id = w.addTransaction(date: '2026-03-12', amount: 4200, category: 'Groceries');
      w.close();
      final db = sqlite3.open(path);
      db.execute('DROP TABLE tx_splits');
      db.execute("UPDATE meta SET value = '12' WHERE key = 'schema'");
      db.close();
      final o = WalletRepo.open(path, now: () => now);
      addTearDown(o.close);
      expect(o.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'].toString(), '${WalletRepo.schemaVersion}');
      expect(o.db.select('SELECT COUNT(*) AS c FROM tx_splits').first['c'], 0);
      expect(o.transactions().single.id, id);
      o.setSplit(id, [_p(-2000), _p(-2200, 'Shopping')]);
      expect(o.splitOf(id), hasLength(2));
    });
  });

  group('backup', () {
    test('a live split and a removed split survive a backup round trip with every clock', () async {
      final key = VaultKey.generate();
      final a = manual('2026-03-12', 10000), b = manual('2026-03-13', 3000);
      r.setSplit(a, [_p(-6000, 'Groceries', const [], 'milk'), _p(-4000, 'Shopping')]);
      r.setSplit(b, [_p(-1000), _p(-2000)]);
      r.removeSplit(b);
      final file = await backupBytes(r, key);
      final fresh = WalletRepo.inMemory(now: () => now);
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, file, key);
      expect(_rec(fresh.splitOf(a)), _rec(r.splitOf(a)));
      expect(fresh.splitOf(b), isNull);
      expect(fresh.splits().keys, [a]);
      final sel = [
        for (final row in r.db.select('SELECT * FROM tx_splits ORDER BY id')) Map<String, Object?>.from(row),
      ];
      expect([for (final row in fresh.db.select('SELECT * FROM tx_splits ORDER BY id')) Map<String, Object?>.from(row)], sel);
    });
  });

  group('two devices', () {
    late Directory tmp;
    late VaultKey key;
    late Net net;
    var clock = 0;
    final devices = <Device>[];
    Device device(String name) {
      final d = Device(name, Directory('${tmp.path}/$name')..createSync(), key, () => clock);
      devices.add(d);
      return d;
    }

    Future<void> syncAll(List<Device> ds) async {
      for (var round = 0; round < 2; round++) {
        for (final d in ds) {
          d.deliver(net, Random(round));
          await d.run();
          d.upload(net);
        }
      }
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bw-p6-dev-');
      key = VaultKey.generate();
      net = Net();
      clock = DateTime.utc(2026, 3, 15, 12).millisecondsSinceEpoch;
    });
    tearDown(() {
      for (final d in devices) {
        d.close();
      }
      devices.clear();
      tmp.deleteSync(recursive: true);
    });

    Future<(Device, Device, String)> pair() async {
      final a = device('a'), b = device('b');
      final id = a.repo.addTransaction(date: '2026-03-12', amount: 10000, category: 'Shopping');
      await syncAll([a, b]);
      expect(b.repo.transactions().map((t) => t.id), contains(id));
      return (a, b, id);
    }

    test('a split made on one device reaches the other', () async {
      final (a, b, id) = await pair();
      clock += 1000;
      a.repo.setSplit(id, [_p(-6000, 'Groceries', const [], 'milk'), _p(-4000, 'Shopping')]);
      await syncAll([a, b]);
      expect(_rec(b.repo.splitOf(id)), _rec(a.repo.splitOf(id)));
      expect(b.repo.splitOf(id), hasLength(2));
    }, timeout: _t);

    test('both devices split the same payment offline: one whole split wins, never a mix', () async {
      final (a, b, id) = await pair();
      clock += 1000;
      a.repo.setSplit(id, [_p(-6000, 'Groceries'), _p(-4000, 'Shopping')]);
      clock += 1000;
      b.repo.setSplit(id, [_p(-1000, 'Cash'), _p(-2000, 'Bank fees'), _p(-7000, 'Eating out')]);
      await syncAll([a, b]);
      final winner = _rec(b.repo.splitOf(id));
      expect(_rec(a.repo.splitOf(id)), winner);
      final amounts = b.repo.splitOf(id)!.map((p) => p.amount);
      expect(amounts, [-1000, -2000, -7000], reason: 'the later split wins whole');
      expect(amounts.fold<int>(0, (s, x) => s + x), -10000);
      for (final d in [a, b]) {
        expect(rowsSum(d.repo, id), -10000, reason: d.name);
        expect(d.repo.categorizer().expand(d.repo.transactions().firstWhere((t) => t.id == id)).every((x) => !x.splitBroken), isTrue);
      }
    }, timeout: _t);

    test('split on one device, remove on the other: the later write wins on both', () async {
      final (a, b, id) = await pair();
      clock += 1000;
      a.repo.setSplit(id, [_p(-6000), _p(-4000, 'Shopping')]);
      await syncAll([a, b]);
      // remove is later than a re-split: the removal wins
      clock += 1000;
      a.repo.setSplit(id, [_p(-5000), _p(-5000, 'Shopping')]);
      clock += 1000;
      b.repo.removeSplit(id);
      await syncAll([a, b]);
      expect(a.repo.splitOf(id), isNull);
      expect(b.repo.splitOf(id), isNull);
      // a split later than the removal wins
      clock += 1000;
      b.repo.removeSplit(id);
      clock += 1000;
      a.repo.setSplit(id, [_p(-2500), _p(-7500, 'Shopping')]);
      await syncAll([a, b]);
      expect(_amts(a.repo.splitOf(id)), [-2500, -7500]);
      expect(_rec(b.repo.splitOf(id)), _rec(a.repo.splitOf(id)));
    }, timeout: _t);

    test('a split on one device and a hand-added amount edit on the other: broken, counted whole on both', () async {
      final (a, b, id) = await pair();
      clock += 1000;
      a.repo.setSplit(id, [_p(-6000), _p(-4000, 'Shopping')]);
      final edit = Op('tx', id, {'amount': -12000}, _hlc(9));
      b.repo.applyRemote([edit]);
      a.repo.applyRemote([edit]);
      await syncAll([a, b]);
      for (final d in [a, b]) {
        final rows = d.repo.categorizer().expand(d.repo.transactions().firstWhere((t) => t.id == id));
        expect(rows, hasLength(1), reason: d.name);
        expect((rows.single.amount, rows.single.splitBroken), (-12000, true), reason: d.name);
        expect(monthSummary([for (final t in d.repo.transactions()) ...d.repo.categorizer().expand(t)], '2026-03', currency: 'EUR').out,
            12000);
      }
    }, timeout: _t);

    test('the split op can arrive before the payment row: no crash, then it resolves', () async {
      final (a, b, id) = await pair();
      clock += 1000;
      a.repo.setSplit(id, [_p(-6000), _p(-4000, 'Shopping')]);
      final fresh = WalletRepo.inMemory(now: () => clock);
      addTearDown(fresh.close);
      final ops = a.repo.snapshotOps();
      fresh.applyRemote([
        for (final o in ops)
          if (o.entity == 'split') o
      ]);
      expect(fresh.transactions(), isEmpty);
      fresh.applyRemote([
        for (final o in ops)
          if (o.entity == 'tx') o
      ]);
      expect(fresh.categorizer().expand(fresh.transactions().single), hasLength(2));
      expect(b.repo.transactions(), hasLength(1));
    }, timeout: _t);
  });
}

/// The sum of the expanded amounts of payment [id].
int rowsSum(WalletRepo x, String id) {
  final c = x.categorizer();
  return c.expand(x.transactions().firstWhere((t) => t.id == id)).fold<int>(0, (s, e) => s + e.amount);
}
