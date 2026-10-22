// Values from other devices are checked field by field before they are stored: a wrong-typed field is ignored (its
// clock is not recorded, so a later valid write still wins), the op's other fields apply, and every device makes the
// same decision. Rows stored with a bad value by an older build still load. All data is SYNTHETIC.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/sim.dart';

String _h(int millis, [String node = 'peer']) => Hlc(2000000000000 + millis, 0, node).toString();

Op _tx(String id, int at, Map<String, Object?> fields) => Op('tx', id, fields, _h(at));

const _base = {'source': 'pbz', 'date': '2026-01-10', 'amount': -500, 'description': 'Synthetic shop'};

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
  late WalletRepo r;
  setUp(() => r = WalletRepo.inMemory());
  tearDown(() => r.close());

  group('a wrong-typed field from another device', () {
    test('is ignored; the other fields of the same op apply', () {
      r.applyRemote([_tx('t', 1, _base)]);
      r.applyRemote([
        _tx('t', 2, {'amount': 'abc', 'note': 'Synthetic note', 'category': 'Cash'})
      ]);
      final t = r.transaction('t')!;
      expect((t.amount, t.note, t.category), (-500, 'Synthetic note', 'Cash'));
    });

    test('does not record its clock, so an older valid write that arrives later still wins', () {
      r.applyRemote([_tx('t', 1, _base)]);
      r.applyRemote([
        _tx('t', 9, {'amount': 12.5})
      ]);
      final clock = r.db.select("SELECT hlc FROM clocks WHERE entity = 'tx' AND id = 't' AND field = 'amount'").single['hlc'];
      expect(clock, _h(1), reason: 'the rejected field left the clock as it was');
      r.applyRemote([
        _tx('t', 5, {'amount': -700})
      ]);
      expect(r.transaction('t')!.amount, -700);
    });

    test('an op whose only known fields are all wrong-typed changes nothing and creates no row', () {
      final changed = r.applyRemote([
        Op('goal', 'g', {'target': 'lots', 'saved': 0.5}, _h(1)),
        Op('wish', 'w', {'price': 'cheap', 'deleted': 'no'}, _h(2)),
        _tx('t', 3, {'amount': 'abc', 'date': 20260110}),
      ]);
      expect(changed, 0);
      for (final table in ['tx', 'goals', 'wish']) {
        expect(r.db.select('SELECT COUNT(*) AS n FROM $table').single['n'], 0, reason: table);
      }
      expect(r.db.select('SELECT COUNT(*) AS n FROM clocks').single['n'], 0);
    });

    test('NULL in a column that cannot hold it, and lists or maps, are refused; NULL where allowed applies', () {
      r.applyRemote([
        _tx('t', 1, {..._base, 'category': 'Cash'})
      ]);
      r.applyRemote([
        _tx('t', 2, {
          'amount': null,
          'date': null,
          'description': ['x'],
          'source': {'a': 1},
          'manual': 2,
          'category': null
        })
      ]);
      final t = r.transaction('t')!;
      expect((t.amount, t.date, t.description, t.source, t.manual, t.category), (-500, '2026-01-10', 'Synthetic shop', 'pbz', false, null));
    });

    test('whole numbers sent as floats are stored as integers; flags accept true/false and 0/1', () {
      r.applyRemote([
        _tx('t', 1, {..._base, 'amount': -700.0, 'manual': 0, 'deleted': false})
      ]);
      final row = r.db.select("SELECT amount, manual, deleted FROM tx WHERE id = 't'").single;
      expect((row['amount'], row['manual'], row['deleted']), (-700, 0, 0));
      expect(row['amount'], isA<int>());
    });

    test('logged as repo.badField with the entity and field name only, never the value', () {
      final lines = _capture(() => r.applyRemote([
            _tx('t', 1, {..._base, 'amount': 'Synthetic Secret Amount', 'description': 42}),
          ]));
      final bad = lines.where((l) => l.contains('repo.badField')).toList();
      expect(bad, hasLength(2));
      expect(bad.first, contains('"entity":"tx"'));
      expect(bad.join('\n'), allOf(contains('"field":"amount"'), contains('"field":"description"')));
      expect(lines.join('\n'), isNot(contains('Synthetic')));
    });
  });

  group('rows already stored with a wrong-typed value (an older build)', () {
    test('load with defaults for the bad columns; the lists keep working', () {
      r.applyRemote([_tx('good', 1, _base)]);
      r.saveGoal(name: 'Synthetic goal', target: 1000, saved: 0, monthly: 100);
      r.addWish('Synthetic wish', 1000);
      // Written straight to the tables to stand in for a database an older build left behind.
      r.db.execute("INSERT INTO tx(id, source, date, amount, manual, deleted) VALUES('bad', 'pbz', '2026-01-11', 'abc', 'x', 0)");
      r.db.execute("INSERT INTO tx(id, source, date, amount, category, note) VALUES('frac', 'manual', '2026-01-12', 12.5, x'07', x'08')");
      r.db.execute("INSERT INTO goals(id, name, target, saved, sort) VALUES('g2', x'05', 'lots', 0.5, 'first')");
      r.db.execute(
          "INSERT INTO wish(id, name, price, added, status, decided) VALUES('w2', 'Synthetic wish 2', 'cheap', 'now', x'03', 1.5)");
      r.db.execute("INSERT INTO merchant_rules(id, category) VALUES('synthetic_shop', x'05')");

      final txs = {for (final t in r.transactions()) t.id: t};
      expect(txs.keys, containsAll(['good', 'bad', 'frac']));
      expect((txs['bad']!.amount, txs['bad']!.manual), (0, false));
      expect((txs['frac']!.amount, txs['frac']!.category, txs['frac']!.note), (0, null, null));
      final g2 = r.goals().singleWhere((g) => g.id == 'g2');
      expect((g2.name, g2.target, g2.saved, g2.sort), ('Goal', 0, 0, 0));
      final w2 = r.wishlist().singleWhere((w) => w.id == 'w2');
      expect((w2.price, w2.added, w2.status, w2.decided), (0, 0, 'waiting', null));
      expect(r.merchantRules(), isEmpty);
      expect(() => r.categorizer().categorize(txs['frac']!), returnsNormally);
    });
  });

  group('two devices', () {
    test('both refuse the same bad field from a third device and converge when a valid write follows', () async {
      final key = VaultKey.generate();
      final relay = MemoryTransport();
      final a = WalletRepo.inMemory(), b = WalletRepo.inMemory();
      addTearDown(a.close);
      addTearDown(b.close);
      Future<void> sync(WalletRepo repo) => SyncEngine(relay, key).run(repo);

      a.updateSettings({'salary': 1});
      await sync(a);
      // A third device with a bug writes a file with a newer clock than anything local: a bad amount and a good note.
      Future<void> peerFile(int n, List<Op> ops) async =>
          relay.put('peer', n, await seal(utf8.encode(jsonEncode([for (final o in ops) o.toJson()])), key));
      final now = DateTime.now().millisecondsSinceEpoch;
      await peerFile(1, [
        Op('tx', 't', {..._base, 'note': 'n0'}, Hlc(now - 1000, 0, 'peer').toString()),
        Op('tx', 't', {'amount': 'abc', 'note': 'n1'}, Hlc(now + 1000000, 0, 'peer').toString()),
      ]);
      await sync(b);
      await sync(a);
      for (final repo in [a, b]) {
        expect((repo.transaction('t')!.amount, repo.transaction('t')!.note), (-500, 'n1'));
      }
      // A valid amount with a clock older than the refused one's still applies on both, and a local edit on A syncs.
      await peerFile(2, [
        Op('tx', 't', {'amount': -900}, Hlc(now, 5, 'peer').toString())
      ]);
      a.setCategory('t', 'Cash');
      await sync(a);
      await sync(b);
      await sync(a);
      for (final repo in [a, b]) {
        expect((repo.transaction('t')!.amount, repo.transaction('t')!.category), (-900, 'Cash'));
      }
      expect(dump(a), dump(b));
    });
  });
}
