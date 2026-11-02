// Stage T1 (core builder): tags (schema 11): TagTable, tagsOf, suggestions, totals, the repo API, CSV and search, two
// devices and backup. All data is SYNTHETIC.
library;

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/sim.dart';

const _t = Timeout(Duration(seconds: 30));

/// 2026-10-10 12:00 UTC.
const _noon = 1791633600000;

var _seq = 0;
Tx _tx(String date, int cents, {String desc = 'SYNTH SHOP', String? id, String currency = 'EUR', String source = 'pbz'}) =>
    Tx(id: id ?? 'r${_seq++}', source: source, date: date, amount: cents, currency: currency, description: desc);

CategorizedTx _ct(Tx t, String category, {List<String> tags = const []}) => CategorizedTx(t, category, kindOf(category), tags: tags);

NormalizedTransaction _bank(String date, int cents, String desc) => NormalizedTransaction(
    id: transactionId(date, cents, desc, 0),
    source: 'pbz',
    date: date,
    amountMinor: cents,
    currency: 'EUR',
    description: desc,
    bankType: 'POS plaćanje');

void main() {
  group('TagTable', () {
    test('order, duplicates, resolve, pickable', () {
      final t = TagTable.from(const [
        TagRow(id: 't00000000000b', name: 'Trip', position: 1),
        TagRow(id: 't00000000000a', name: 'trip', position: 5),
        TagRow(id: 't00000000000c', name: 'Gifts', position: 0),
        TagRow(id: 't00000000000d', name: 'Old', deleted: true),
        TagRow(id: 't00000000000e', name: 'Quiet', hidden: true),
        TagRow(id: 't00000000000f', name: ''),
      ]);
      expect(t.duplicateOf('t00000000000b'), 't00000000000a', reason: 'smallest id wins');
      expect(t.resolve('t00000000000b'), 't00000000000a');
      expect(t.resolve('t00000000000d'), isNull);
      expect(t.resolve('t00000000000f'), isNull, reason: 'no name yet: not live');
      expect(t.resolve('nope'), isNull);
      expect(t.pickable(), ['t00000000000c', 't00000000000a']);
      expect(t.ids, ['t00000000000c', 't00000000000a', 't00000000000e']);
      expect((t.label('t00000000000c'), t.label('nope')), ('Gifts', 'nope'));
      expect(t.isLive('t00000000000e'), isTrue);
    });
  });

  group('tagsOf', () {
    final table = TagTable.from(const [
      TagRow(id: 'ta', name: 'A', position: 0),
      TagRow(id: 'tb', name: 'B', position: 1),
      TagRow(id: 'tc', name: 'C', position: 2),
      TagRow(id: 'tdup', name: 'a', position: 9),
      TagRow(id: 'tdead', name: 'Dead', deleted: true),
    ]);

    test('rule tags on every row of the payee, links add and remove, in table order, resolved', () {
      final x = _tx('2026-09-01', -100, desc: 'SYNTH CAFE');
      final y = _tx('2026-09-02', -200, desc: 'SYNTH CAFE');
      final z = _tx('2026-09-03', -300, desc: 'OTHER PLACE');
      final rules = {
        merchantKey(x): {'tc', 'tdead'}
      };
      final links = {
        x.id: {'tc': false, 'tdup': true},
        z.id: {'tb': true, 'tdead': true},
      };
      List<String> of(Tx t) => tagsOf(t, tags: table, ruleTags: rules, links: links);
      expect(of(x), ['ta'], reason: 'off removes the rule tag on this row only; a duplicate counts as its original');
      expect(of(y), ['tc']);
      expect(of(z), ['tb']);
      expect(() => of(z).add('x'), throwsUnsupportedError);
    });

    test('a hand-added row without a note has no payee: no rule tags', () {
      const m = Tx(id: 'm1', source: 'manual', date: '2026-09-01', amount: -100, description: '', category: 'Groceries', manual: true);
      expect(
          tagsOf(m, tags: table, ruleTags: {
            merchantKey(m): {'ta'}
          }, links: const {}),
          isEmpty);
      expect(
          tagsOf(m, tags: table, ruleTags: const {}, links: {
            'm1': {'tb': true}
          }),
          ['tb']);
    });
  });

  group('suggestions and order', () {
    final tags = TagTable.from(const [
      TagRow(id: 'ta', name: 'Alpha', position: 0),
      TagRow(id: 'tb', name: 'Bravo', position: 1),
      TagRow(id: 'tc', name: 'Charlie', position: 2),
      TagRow(id: 'th', name: 'Hidden', position: 3, hidden: true),
    ]);

    test('suggestTags: at least 2 other rows of the payee, ordered by count, recency, label; excludes on and off', () {
      final me = _tx('2026-09-10', -100, desc: 'SYNTH CAFE');
      final history = [
        _ct(me, 'Eating out', tags: const ['tc']),
        _ct(_tx('2026-09-01', -100, desc: 'SYNTH CAFE'), 'Eating out', tags: const ['ta', 'tb', 'tc', 'th']),
        _ct(_tx('2026-09-02', -100, desc: 'SYNTH CAFE'), 'Eating out', tags: const ['ta', 'tb', 'tc', 'th']),
        _ct(_tx('2026-09-05', -100, desc: 'SYNTH CAFE'), 'Eating out', tags: const ['tb']),
        _ct(_tx('2026-09-06', -100, desc: 'OTHER'), 'Eating out', tags: const ['ta', 'ta']),
        _ct(_tx('2026-09-07', -100, desc: 'OTHER'), 'Eating out', tags: const ['ta']),
      ];
      expect(suggestTags(me, history, tags), ['tb', 'ta']);
      expect(suggestTags(me, history, tags, off: {'tb'}), ['ta']);
      expect(suggestTags(me, history, tags, limit: 1), ['tb']);
      final lone = _tx('2026-09-11', -100, desc: 'SYNTH CAFE');
      expect(suggestTags(lone, history.sublist(1, 3), tags), ['ta', 'tb', 'tc'], reason: 'same count and date: by label');
    });

    test('recommendedMainTags: payee first by count, then overall, then table order; recommendedTags the same', () {
      final me = _tx('2026-09-10', -100, desc: 'SYNTH CAFE');
      final history = [
        _ct(_tx('2026-09-01', -100, desc: 'SYNTH CAFE'), 'Shopping', tags: const ['tc']),
        _ct(_tx('2026-09-02', -100, desc: 'OTHER'), 'Groceries', tags: const ['tb']),
        _ct(_tx('2026-09-03', -100, desc: 'OTHER'), 'Groceries', tags: const ['tb']),
        _ct(_tx('2026-09-04', -100, desc: 'OTHER'), 'Salary'),
      ];
      final main = recommendedMainTags(me, history, CategoryTable.builtIn, kinds: {BudgetKind.flex});
      expect(main.take(2), ['Shopping', 'Groceries']);
      expect(main.sublist(2), [
        for (final c in flexCategories)
          if (c != 'Shopping' && c != 'Groceries') c
      ]);
      expect(recommendedTags(me, history, tags), ['tc', 'tb', 'ta']);
    });
  });

  group('totals', () {
    final r = DateRange(start: '2026-09-01', end: '2026-09-30');
    final rows = [
      _ct(_tx('2026-09-01', -1000), 'Groceries', tags: const ['ta', 'tb']),
      _ct(_tx('2026-09-02', -500), 'Eating out', tags: const ['ta']),
      _ct(_tx('2026-09-03', 200), 'Groceries', tags: const ['ta']), // a refund
      _ct(_tx('2026-09-04', -700), 'Groceries'),
      _ct(_tx('2026-09-05', -900, currency: 'USD'), 'Groceries', tags: const ['ta']),
      _ct(_tx('2026-09-06', -800), 'Internal transfer', tags: const ['ta']),
      _ct(_tx('2026-09-07', 5000), 'Salary', tags: const ['tb']),
      _ct(_tx('2026-08-31', -300), 'Groceries', tags: const ['tb']),
    ];

    test('tagShare overlaps, equals rowsForTag, skips other currencies, transfers and income; untaggedSpent', () {
      final s = tagShare(rows, r, currency: 'EUR');
      expect([for (final x in s.slices) (x.tag, x.spent, x.count)], [('ta', 1300, 3), ('tb', 1000, 1)]);
      expect(s.untaggedSpent, 700);
      for (final x in s.slices) {
        expect(-rowsForTag(x.tag, rows, r, currency: 'EUR').fold<int>(0, (a, t) => a + t.amount), x.spent);
      }
      expect(rowsForTag('ta', rows, r, currency: 'EUR').map((t) => t.date), ['2026-09-03', '2026-09-02', '2026-09-01']);
      final trend = tagTrend('tb', rows, DateRange(start: '2026-08-01', end: '2026-09-30'), today: '2026-10-10', currency: 'EUR');
      expect([for (final b in trend) (b.month, b.spent)], [('2026-08', 300), ('2026-09', 1000)]);
    });

    test('CSV tags column and search by tag label', () {
      final tags = TagTable.from(const [TagRow(id: 'ta', name: 'Trip; Rome', position: 0), TagRow(id: 'tb', name: 'Work', position: 1)]);
      final csv = transactionsCsv(rows.sublist(0, 2), tags: tags).split('\n');
      expect(csv.first, transactionsCsvTagsHeader);
      expect(csv[1], '2026-09-01,-10.00,Groceries,Trip; Rome; Work,SYNTH SHOP,pbz,');
      expect(transactionsCsv(rows.sublist(0, 1)).split('\n').first, transactionsCsvHeader);
      final hit = searchAll('work', txs: rows, goals: const [], wishlist: const [], bills: const [], tags: tags);
      expect(hit.txs.map((t) => t.date), ['2026-09-07', '2026-09-01', '2026-08-31']);
      expect(searchAll('work', txs: rows, goals: const [], wishlist: const [], bills: const []).txs, isEmpty);
    });
  });

  group('repo', () {
    late WalletRepo repo;
    setUp(() => repo = WalletRepo.inMemory());
    tearDown(() => repo.close());

    test('addTag: id shape, name rules, clash with a main tag, case and accents', () async {
      final id = await repo.addTag('  Putovanje  ');
      expect(id, matches(RegExp(r'^t[0-9a-f]{12}$')));
      expect(repo.tags().single.name, 'Putovanje');
      await expectLater(repo.addTag(''), throwsArgumentError);
      await expectLater(repo.addTag('x' * 41), throwsArgumentError);
      await repo.addTag('č' * 40);
      await expectLater(repo.addTag('PUTOVANJE'), throwsArgumentError);
      await expectLater(repo.addTag('groceries'), throwsArgumentError);
      final pets = await repo.addCategory(name: 'Pets', kind: BudgetKind.flex);
      await expectLater(repo.addTag('pets'), throwsArgumentError);
      await repo.deleteCategory(pets);
      await repo.addTag('pets');
      final before = repo.pendingOps().length;
      await expectLater(repo.addTag('Putovanje'), throwsArgumentError);
      expect(repo.pendingOps().length, before);
    }, timeout: _t);

    test('update, delete, undelete; the 500 limit', () async {
      final a = await repo.addTag('A');
      final b = await repo.addTag('B');
      expect(repo.tagTable().pickable(), [a, b]);
      await repo.updateTag(b, position: 0);
      await repo.updateTag(a, hidden: true, name: 'A2');
      expect(repo.tagTable().pickable(), [b]);
      expect(repo.tagTable().label(a), 'A2');
      await expectLater(repo.updateTag(a, name: 'b'), throwsArgumentError);
      await expectLater(repo.updateTag('t000000000000', name: 'Z'), throwsArgumentError);
      await repo.deleteTag(b);
      expect(repo.tags().map((r) => r.id), [a]);
      expect(repo.tags(includeDeleted: true), hasLength(2));
      final b2 = await repo.addTag('B');
      await expectLater(repo.undeleteTag(b), throwsArgumentError, reason: 'name taken meanwhile');
      await repo.deleteTag(b2);
      await repo.undeleteTag(b);
      expect(repo.tagTable().isLive(b), isTrue);
      for (var i = repo.tags().length; i < TagRow.maxLive; i++) {
        await repo.addTag('T$i');
      }
      await expectLater(repo.addTag('One more'), throwsArgumentError);
      await expectLater(repo.undeleteTag(b2), throwsArgumentError);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('setTxTag, setRuleTag and the categorizer fill CategorizedTx.tags; deleted tags drop and come back', () async {
      repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        _bank('2026-09-01', -1000, 'SYNTH CAFE'),
        _bank('2026-09-02', -2000, 'SYNTH CAFE'),
        _bank('2026-09-03', -3000, 'SYNTH MARKET'),
      ]));
      final rows = repo.transactions();
      final cafe1 = rows.firstWhere((t) => t.amount == -1000), cafe2 = rows.firstWhere((t) => t.amount == -2000);
      final market = rows.firstWhere((t) => t.amount == -3000);
      final trip = await repo.addTag('Trip'), work = await repo.addTag('Work');
      Map<String, List<String>> tags() => {for (final c in repo.transactions().map(repo.categorizer().categorize)) c.tx.id: c.tags};

      await repo.setRuleTag(merchantKey(cafe1), work, true);
      expect(repo.ruleTags(), {
        merchantKey(cafe1): {work}
      });
      expect(tags(), {
        cafe1.id: [work],
        cafe2.id: [work],
        market.id: <String>[]
      });

      final ops = repo.pendingOps().length;
      await repo.setTxTag(cafe1.id, work, true); // a rule already gives it: no-op
      expect(repo.pendingOps().length, ops);
      await repo.setTxTag(cafe1.id, work, false);
      await repo.setTxTag(market.id, trip, true);
      await repo.setTxTag(market.id, work, false); // neither link nor rule: an off link all the same (E6d, Project "Skip")
      expect(repo.db.select('SELECT state FROM tx_tags WHERE id = ?', ['${market.id}|$work']), [
        {'state': 'off'}
      ]);
      expect(tags(), {
        cafe1.id: <String>[],
        cafe2.id: [work],
        market.id: [trip]
      });
      await repo.setTxTag(cafe1.id, work, true); // was off: written again
      expect(repo.db.select('SELECT state FROM tx_tags WHERE id = ?', ['${cafe1.id}|$work']).single['state'], 'on');
      expect(tags()[cafe1.id], [work]);

      await repo.deleteTag(work);
      expect(tags(), {
        cafe1.id: <String>[],
        cafe2.id: <String>[],
        market.id: [trip]
      });
      await repo.undeleteTag(work);
      expect(tags()[cafe2.id], [work]);

      await repo.setRuleTag(merchantKey(cafe1), work, false);
      expect(repo.ruleTags(), isEmpty);
      expect(tags()[cafe2.id], isEmpty);
      await expectLater(repo.setTxTag('nope', trip, true), throwsArgumentError);
      await expectLater(repo.setTxTag(cafe1.id, 't000000000000', true), throwsArgumentError);
      await expectLater(repo.setRuleTag('', trip, true), throwsArgumentError);
      expect(repo.categorizer(withTags: false).categorize(cafe1).tags, isEmpty);
    }, timeout: _t);

    test('a wallet holding only a tag, a link or a rule tag is not empty', () async {
      final g = await repo.addTag('Trip');
      expect(repo.isEmpty, isFalse);
      final r2 = WalletRepo.inMemory();
      addTearDown(r2.close);
      final id = r2.addTransaction(date: '2026-09-01', amount: 100, category: 'Groceries');
      expect(r2.isEmpty, isFalse);
      expect(g, isNotEmpty);
      expect(id, isNotEmpty);
    }, timeout: _t);

    test('logs carry no tag names', () async {
      final sink = MemoryLogSink();
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((r) => sink.add(formatLogRecord(r)));
      addTearDown(() {
        sub.cancel();
        Logger.root.level = was;
      });
      final g = await repo.addTag('Synthsecret');
      await repo.updateTag(g, name: 'Synthsecret two');
      await repo.setRuleTag('synth_payee', g, true);
      for (final l in sink.lines) {
        expect(l, isNot(contains('Synthsecret')));
        expect(l, isNot(contains(g)));
        expect(l, isNot(contains('synth_payee')));
      }
    }, timeout: _t);
  });

  test('schema 10 -> 11: a schema 10 database gains the tag tables on open and takes tags', () async {
    final dir = Directory.systemTemp.createTempSync('bw_t1_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/w.db';
    var r = WalletRepo.open(path);
    final id = r.addTransaction(date: '2026-09-01', amount: 100, category: 'Groceries');
    for (final t in ['tags', 'tx_tags', 'rule_tags']) {
      r.db.execute('DROP TABLE $t');
    }
    r.db.execute("UPDATE meta SET value = '10' WHERE key = 'schema'");
    r.close();
    r = WalletRepo.open(path);
    addTearDown(r.close);
    expect(WalletRepo.schemaVersion, greaterThanOrEqualTo(11)); // P4 made it 12
    expect(r.db.select("SELECT value FROM meta WHERE key = 'schema'").first['value'], '${WalletRepo.schemaVersion}');
    expect(r.tags(includeDeleted: true), isEmpty);
    expect(r.ruleTags(), isEmpty);
    expect(r.tagLinks(), isEmpty);
    final g = await r.addTag('Trip');
    await r.setTxTag(id, g, true);
    expect(r.transactions().map(r.categorizer().categorize).single.tags, [g]);
  }, timeout: _t);

  group('two devices and backup', () {
    late VaultKey key;
    late Net net;
    var clock = _noon;
    setUp(() {
      key = VaultKey.generate();
      net = Net();
      clock = _noon;
    });

    Future<void> settle(List<Device> ds) async {
      for (var i = 0; i < 3; i++) {
        for (final d in ds) {
          clock += 1000;
          d.deliver(net, Random(1));
          await d.run();
        }
      }
    }

    test('the same name added offline on two devices merges into one tag in totals', () async {
      final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
      addTearDown(a.close);
      addTearDown(b.close);
      final id = a.repo.addTransaction(date: '2026-09-01', amount: 1000, category: 'Groceries', note: 'synth');
      await settle([a, b]);
      final x = await a.repo.addTag('Trip');
      final y = await b.repo.addTag('trip');
      await a.repo.setTxTag(id, x, true);
      await b.repo.setTxTag(id, y, true);
      await settle([a, b]);
      expect(dump(a.repo)['tags'], dump(b.repo)['tags']);
      expect(dump(a.repo)['tx_tags'], dump(b.repo)['tx_tags']);
      final keep = x.compareTo(y) < 0 ? x : y;
      for (final d in [a, b]) {
        final rows = d.repo.transactions().map(d.repo.categorizer().categorize).toList();
        expect(rows.single.tags, [keep]);
        final s = tagShare(rows, DateRange(start: '2026-09-01', end: '2026-09-30'), currency: 'EUR');
        expect([for (final x in s.slices) (x.tag, x.spent)], [(keep, 1000)]);
        expect(d.repo.tagTable().pickable(), [keep]);
      }
    }, timeout: _t);

    test('the same link edited offline on two devices: the later write wins; a late third device agrees', () async {
      final a = Device('A', null, key, () => clock), b = Device('B', null, key, () => clock);
      addTearDown(a.close);
      addTearDown(b.close);
      final id = a.repo.addTransaction(date: '2026-09-01', amount: 1000, category: 'Groceries');
      final g = await a.repo.addTag('Trip');
      await a.repo.setTxTag(id, g, true);
      await settle([a, b]);
      await a.repo.setTxTag(id, g, false);
      clock += 5000;
      await b.repo.setTxTag(id, g, false);
      await b.repo.setTxTag(id, g, true);
      await settle([a, b]);
      final c = Device('C', null, key, () => clock);
      addTearDown(c.close);
      await settle([a, b, c]);
      for (final d in [a, b, c]) {
        expect(
            d.repo.tagLinks(),
            {
              id: {g: true}
            },
            reason: d.name);
      }
      expect(dump(c.repo, clocks: false)['tx_tags'], dump(a.repo, clocks: false)['tx_tags']);
    }, timeout: _t);

    test('backup round trip keeps tags, links and rule tags', () async {
      final a = Device('A', null, key, () => clock);
      addTearDown(a.close);
      final id = a.repo.addTransaction(date: '2026-09-01', amount: 1000, category: 'Groceries');
      final g = await a.repo.addTag('Trip');
      final gone = await a.repo.addTag('Gone');
      await a.repo.setTxTag(id, g, true);
      await a.repo.setRuleTag('synth_payee', gone, true);
      await a.repo.deleteTag(gone);
      final file = await backupBytes(a.repo, key);
      final fresh = WalletRepo.inMemory();
      addTearDown(fresh.close);
      await restoreBackupBytes(fresh, file, key);
      for (final t in ['tags', 'tx_tags', 'rule_tags']) {
        expect(dump(fresh)[t], dump(a.repo)[t], reason: t);
      }
    }, timeout: _t);
  });
}
