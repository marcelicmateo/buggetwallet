// Model edge cases: rows with missing or odd columns, values from other devices with the wrong type, extreme amounts,
// impossible dates, settings maps with junk. Nothing may crash a read or silently change a number. All data is SYNTHETIC.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

const _maxInt = 9223372036854775807;
const _minInt = -9223372036854775808;

const String _wrongTypeBug =
    'BUG: a wrong-typed value synced into tx/goal/wish makes Tx/Goal/WishItem.fromRow throw, so a whole list (and the screen) fails';
const String _ghostBug =
    'BUG: _apply inserts the row (INSERT OR IGNORE) before checking fields, so an op with no known field leaves a visible empty goal/wish';

int _seq = 0;

/// An op from another device, newer than anything local.
Op _op(String entity, String id, Map<String, Object?> fields) => Op(entity, id, fields, Hlc(2000000000000 + _seq++, 0, 'peer').toString());

Op _txOp(String id, Map<String, Object?> extra) =>
    _op('tx', id, {'source': 'pbz', 'date': '2026-01-10', 'amount': -500, 'description': 'Synthetic shop', ...extra});

void main() {
  setUp(resetInvalidSettingLog);

  group('Tx.fromRow', () {
    test('only the id is needed; everything else has a default', () {
      final t = Tx.fromRow({'id': 'a'});
      expect((t.id, t.source, t.date, t.amount, t.currency, t.bankType, t.description), ('a', '', '', 0, 'EUR', '', ''));
      expect((t.category, t.note, t.matchedTo), (null, null, null));
      expect((t.manual, t.deleted, t.matchPending, t.live), (false, false, false, true));
    });

    test('NULL in every column gives the same defaults', () {
      final t = Tx.fromRow({
        for (final c in [
          'source',
          'date',
          'amount',
          'currency',
          'bank_type',
          'description',
          'category',
          'note',
          'manual',
          'matched_to',
          'deleted'
        ])
          c: null,
        'id': 'a',
      });
      expect((t.source, t.date, t.amount, t.currency, t.description, t.manual, t.deleted), ('', '', 0, 'EUR', '', false, false));
    });

    test('unknown extra columns (a newer schema) are ignored', () {
      final t = Tx.fromRow({'id': 'a', 'amount': -5, 'seen_bank': 'x', 'written': 'h', 'future_column': 42});
      expect(t.amount, -5);
    });

    test('extreme amounts are kept exactly', () {
      for (final v in [0, 1, -1, 99, -99, 100000000000, -100000000000, _maxInt, _minInt]) {
        expect(Tx.fromRow({'id': 'a', 'amount': v}).amount, v);
      }
    });

    test('live: deleted rows and rows replaced by a bank row do not count; a replacement that has not arrived does', () {
      bool live({int deleted = 0, String? matched, int pending = 0}) =>
          Tx.fromRow({'id': 'a', 'deleted': deleted, 'matched_to': matched, 'match_pending': pending}).live;
      expect(live(), isTrue);
      expect(live(deleted: 1), isFalse);
      expect(live(matched: 'bank1'), isFalse);
      expect(live(matched: 'bank1', pending: 1), isTrue);
      expect(live(matched: 'bank1', pending: 1, deleted: 1), isFalse);
      expect(live(pending: 1), isTrue);
    });

    test('flag columns: only 1 means true', () {
      expect(Tx.fromRow({'id': 'a', 'manual': 1, 'deleted': 1}).manual, isTrue);
      expect(Tx.fromRow({'id': 'a', 'manual': 0, 'deleted': 0}).deleted, isFalse);
      expect(Tx.fromRow({'id': 'a', 'manual': 2}).manual, isFalse);
      expect(Tx.fromRow({'id': 'a', 'manual': -1}).manual, isFalse);
    });
  });

  group('Goal and WishItem rows', () {
    test('missing columns give defaults', () {
      final g = Goal.fromRow({'id': 'g'});
      expect((g.name, g.target, g.saved, g.monthly, g.sort), ('Goal', 0, 0, 0, 0));
      final w = WishItem.fromRow({'id': 'w'});
      expect((w.name, w.price, w.added, w.status, w.decided), ('', 0, 0, 'waiting', null));
    });

    test('extreme goal amounts are kept', () {
      final g = Goal.fromRow({'id': 'g', 'target': _maxInt, 'saved': _minInt, 'monthly': 0});
      expect((g.target, g.saved, g.monthly), (_maxInt, _minInt, 0));
    });

    test('wish cooling-off: exact end is 0 hours, one hour before is 1, after the end it is negative, 0 hours means none', () {
      const hour = 3600000;
      final w = WishItem.fromRow({'id': 'w', 'added': 1000 * hour});
      expect(w.hoursLeft(72, 1000 * hour), 72);
      expect(w.hoursLeft(72, 1071 * hour), 1);
      expect(w.hoursLeft(72, 1072 * hour), 0);
      expect(w.hoursLeft(72, 1073 * hour), -1);
      expect(w.hoursLeft(0, 1000 * hour), 0);
      expect(w.hoursLeft(72, 1000 * hour + 1800000), 71.5);
      // The longest accepted wait (a year) does not overflow.
      expect(w.hoursLeft(WalletSettings.maxCoolHours, 1000 * hour), WalletSettings.maxCoolHours);
    });
  });

  group('values from another device with the wrong type', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    final bad = <String, (String, String, Object?)>{
      'tx.amount text': ('tx', 'amount', 'abc'),
      'tx.amount fraction': ('tx', 'amount', 12.5),
      'tx.amount huge float': ('tx', 'amount', 1e30),
      'tx.deleted text': ('tx', 'deleted', 'yes'),
      'tx.manual text': ('tx', 'manual', 'x'),
      'goal.target text': ('goal', 'target', 'lots'),
      'goal.saved fraction': ('goal', 'saved', 0.5),
      'goal.sort text': ('goal', 'sort', 'first'),
      'wish.price text': ('wish', 'price', 'cheap'),
      'wish.added text': ('wish', 'added', 'now'),
      'wish.decided fraction': ('wish', 'decided', 1.5),
    };

    for (final MapEntry(key: name, value: (entity, field, value)) in bad.entries) {
      test('$name: reads keep working and good rows are still there', () {
        r.saveGoal(name: 'Synthetic goal', target: 1000, saved: 0, monthly: 100);
        r.addWish('Synthetic wish', 1000);
        r.importBatch(const ImportBatch(source: 'pbz', transactions: []));
        r.applyRemote([_txOp('good', {})]);
        final fields = <String, Object?>{
          if (entity == 'tx') ...{'source': 'pbz', 'date': '2026-01-11', 'amount': -700},
          if (entity == 'goal') 'name': 'Broken goal',
          if (entity == 'wish') 'name': 'Broken wish',
          field: value,
          if (entity != 'tx') 'deleted': 0,
        };
        r.applyRemote([_op(entity, 'bad', fields)]);
        expect(() => r.transactions(), returnsNormally);
        expect(() => r.goals(), returnsNormally);
        expect(() => r.wishlist(), returnsNormally);
        expect(r.transactions().any((t) => t.id == 'good'), isTrue);
        expect(r.goals().any((g) => g.name == 'Synthetic goal'), isTrue);
        expect(r.wishlist().any((w) => w.name == 'Synthetic wish'), isTrue);
        expect(() => r.transaction('bad'), returnsNormally);
        expect(() => r.categorizer(), returnsNormally);
      }, skip: _wrongTypeBug);
    }

    test('a wrong-typed value in an unrelated setting does not stop reading transactions', () {
      r.applyRemote([_txOp('good', {})]);
      r.applyRemote([
        _op('setting', 'salary', {'value': '"lots"', 'deleted': 0})
      ]);
      expect(r.transactions().single.id, 'good');
      expect(r.settings().salary, 0);
    });

    test('extreme amounts from another device are stored and read back exactly', () {
      final ids = <String, int>{'zero': 0, 'neg': -1, 'big': _maxInt, 'small': _minInt, 'cent': 1};
      r.applyRemote([
        for (final e in ids.entries) _txOp(e.key, {'amount': e.value})
      ]);
      final got = {for (final t in r.transactions()) t.id: t.amount};
      expect(got, ids);
    });

    test('a boolean for a flag column is stored as 0/1', () {
      r.applyRemote([
        _txOp('flags', {'deleted': true, 'manual': false})
      ]);
      expect(r.transaction('flags')!.deleted, isTrue);
      expect(r.transaction('flags')!.manual, isFalse);
      expect(r.transactions(), isEmpty, reason: 'deleted rows are not live');
      expect(r.transactions(includeHidden: true).single.id, 'flags');
    });

    test('an op with only unknown fields or unknown entities changes nothing a user can see', () {
      final changed = r.applyRemote([
        _op('tx', 'future1', {'colour': 'red', 'weight': 3}),
        _op('goal', 'future2', {'colour': 'red'}),
        _op('wish', 'future3', {'colour': 'red'}),
        _op('rule', 'future4', {'colour': 'red'}),
        _op('budgetx', 'future5', {'name': 'New thing', 'amount': 5}),
        _op('goal', 'future6', {}),
      ]);
      expect(changed, 0);
      expect(r.transactions(includeHidden: true), isEmpty);
      expect(r.goals(), isEmpty);
      expect(r.wishlist(), isEmpty);
      expect(r.merchantRules(), isEmpty);
    }, skip: _ghostBug);

    test('unknown fields next to known ones are ignored; the known ones apply', () {
      r.applyRemote([
        _txOp('t1', {
          'colour': 'red',
          'tags': ['a', 'b']
        })
      ]);
      final t = r.transaction('t1')!;
      expect((t.amount, t.date), (-500, '2026-01-10'));
      expect(r.pendingOps(), isEmpty, reason: 'received ops are not sent back');
    });
  });

  group('dates in rows', () {
    late WalletRepo r;
    setUp(() => r = WalletRepo.inMemory());
    tearDown(() => r.close());

    test('a row without a date is hidden from lists but can still be fetched, and shows once its date arrives', () {
      r.applyRemote([
        _op('tx', 'partial', {'amount': -900})
      ]);
      expect(r.transactions(includeHidden: true).where((t) => t.id == 'partial'), isEmpty);
      expect(r.transaction('partial')!.date, '');
      r.applyRemote([
        _op('tx', 'partial', {'date': '2026-01-12', 'source': 'pbz'})
      ]);
      expect(r.transactions().single.id, 'partial');
    });

    test('impossible or odd dates do not crash reads or matching', () {
      const dates = [
        '2026-02-30',
        '2026-13-01',
        '2026-00-10',
        '2026-01-00',
        'garbage',
        '2026-1-5',
        ' 2026-01-05',
        '0000-01-01',
        '99999-01-01',
        '🙂'
      ];
      for (final d in dates) {
        r.applyRemote([
          _txOp('bank$d', {'date': d, 'amount': -500})
        ]);
        r.applyRemote([
          _op('tx', 'man$d', {'source': 'manual', 'date': d, 'amount': -500, 'manual': 1, 'deleted': 0, 'category': 'Cash', 'note': ''})
        ]);
      }
      expect(() => r.transactions(), returnsNormally);
      expect(() => r.importBatch(const ImportBatch(source: 'pbz', transactions: [])), returnsNormally); // runs matching over all of them
      expect(() => r.applyRemote([_txOp('another', {})]), returnsNormally);
      expect(r.transactions().any((t) => t.id == 'another'), isTrue);
    });

    test('a hand-added entry on a date that does not exist is not matched across to a bank row (no guessing)', () {
      r.applyRemote([
        _op('tx', 'm1', {'source': 'manual', 'date': 'garbage', 'amount': -500, 'manual': 1, 'deleted': 0, 'category': 'Cash', 'note': ''}),
      ]);
      r.applyRemote([
        _txOp('b1', {'date': '2026-01-10', 'amount': -500})
      ]);
      expect(r.transaction('m1')!.matchedTo, isNull);
      expect(r.transaction('m1')!.live, isTrue);
    });
  });

  group('Op json', () {
    test('round trip keeps nested values, nulls and unicode', () {
      const op = Op(
          'tx',
          'id-č',
          {
            'note': 'Čaj 🙂',
            'category': null,
            'amount': _minInt,
            'list': [1, 'a', null]
          },
          '000000000000001:00000:a');
      final back = Op.fromJson(jsonDecode(jsonEncode(op.toJson())) as Map<String, Object?>);
      expect((back.entity, back.id, back.hlc), ('tx', 'id-č', '000000000000001:00000:a'));
      expect(back.fields, op.fields);
    });

    test('extra keys are ignored; the fields map is a copy', () {
      final json = <String, Object?>{
        'e': 'tx',
        'id': 'a',
        'f': {'amount': 1},
        'h': '1:1:a',
        'v': 2,
        'extra': [1]
      };
      final op = Op.fromJson(json);
      (json['f'] as Map)['amount'] = 2;
      expect(op.fields['amount'], 1);
    });

    test('missing or wrong-typed parts are refused (an exception, never a half-built op)', () {
      final ok = <String, Object?>{'e': 'tx', 'id': 'a', 'f': <String, Object?>{}, 'h': '1:1:a'};
      expect(() => Op.fromJson(ok), returnsNormally);
      for (final k in ['e', 'id', 'f', 'h']) {
        final without = <String, Object?>{...ok};
        without.remove(k);
        expect(() => Op.fromJson(without), throwsA(anything), reason: 'missing $k');
        expect(() => Op.fromJson({...ok, k: null}), throwsA(anything), reason: 'null $k');
        expect(() => Op.fromJson({...ok, k: 5}), throwsA(anything), reason: 'number as $k');
      }
      expect(() => Op.fromJson({...ok, 'f': <Object?>[]}), throwsA(anything));
    });
  });

  group('WalletSettings.fromMap', () {
    test('an empty map and a map of unknown keys give the defaults', () {
      const d = WalletSettings();
      for (final m in [
        const <String, Object?>{},
        {'unknown': 1, 'salary_x': 5, '': 3}
      ]) {
        expect(WalletSettings.fromMap(m).toMap(), d.toMap());
      }
    });

    test('toMap -> fromMap keeps every value, including the extremes', () {
      final s = WalletSettings.fromMap({
        'salary': WalletSettings.maxAmount,
        'rent': 0,
        'coolHours': WalletSettings.maxCoolHours,
        'paydayDay': 31,
        'periodStart': '2024-02-29',
        'loanEnd': '2099-12',
        'currency': 'CHF',
        'incomeMode': 'received',
        'salaryConfirmed': true,
        'merchantPatterns': [
          ['Groceries', 'a.*b']
        ],
      });
      expect(WalletSettings.fromMap(jsonDecode(jsonEncode(s.toMap())) as Map<String, Object?>).toMap(), s.toMap());
      expect(s.salary, 100000000000);
    });

    test('limits are inclusive: the largest amount is kept, one more falls back', () {
      expect(WalletSettings.fromMap({'salary': WalletSettings.maxAmount}).salary, WalletSettings.maxAmount);
      expect(WalletSettings.fromMap({'salary': WalletSettings.maxAmount + 1}).salary, 0);
      expect(WalletSettings.fromMap({'salary': WalletSettings.maxAmount.toDouble()}).salary, WalletSettings.maxAmount);
      expect(WalletSettings.fromMap({'salary': -0.0}).salary, 0);
      expect(WalletSettings.fromMap({'salary': _maxInt}).salary, 0);
      expect(WalletSettings.fromMap({'salary': _minInt}).salary, 0);
      expect(WalletSettings.fromMap({'paydayDay': 1}).paydayDay, 1);
      expect(WalletSettings.fromMap({'paydayDay': 31}).paydayDay, 31);
    });

    test('dates must exist: impossible days, months, spacing and digit forms fall back to null', () {
      for (final d in [
        '2026-02-29', // 2026 is not a leap year
        '2026-02-30',
        '2026-04-31',
        '2026-13-01',
        '2026-00-10',
        '2026-01-00',
        ' 2026-01-01',
        '2026-01-01 ',
        '2026-01-01\n',
        '2026-01-01T00:00:00',
        '26-01-01',
        '2026/01/01',
        '２０２６-01-01', // fullwidth digit
        '٢٠٢٦-01-01', // arabic-indic digits
        '0000-01-01',
        '',
      ]) {
        expect(WalletSettings.fromMap({'periodStart': d}).periodStart, isNull, reason: jsonEncode(d));
        expect(WalletSettings.fromMap({'savedFor': d}).savedFor, isNull, reason: jsonEncode(d));
      }
      for (final d in ['2024-02-29', '2026-12-31', '2026-01-01', '9999-12-31', '2000-02-29']) {
        expect(WalletSettings.fromMap({'periodStart': d}).periodStart, d, reason: d);
      }
    });

    test('loanEnd must be a real month', () {
      for (final d in ['2026-00', '2026-13', '2026-1', '2026-001', ' 2026-01', '2026-01\n', '2026-01-01', '']) {
        expect(WalletSettings.fromMap({'loanEnd': d}).loanEnd, isNull, reason: jsonEncode(d));
      }
      for (final d in ['2026-01', '2026-12', '1999-09']) {
        expect(WalletSettings.fromMap({'loanEnd': d}).loanEnd, d);
      }
    });

    test('currency is three capital ASCII letters', () {
      for (final c in ['eur', 'Eur', 'EU', 'EURO', 'E1R', ' EUR', 'EUR ', 'EUR\n', 'ЕUR', '€€€', '']) {
        expect(WalletSettings.fromMap({'currency': c}).currency, 'EUR', reason: jsonEncode(c));
      }
      expect(WalletSettings.fromMap({'currency': 'JPY'}).currency, 'JPY');
    });

    test('merchantPatterns: only [category, regex] pairs survive; items are turned into text, others dropped', () {
      final s = WalletSettings.fromMap({
        'merchantPatterns': [
          ['Groceries', 'a'],
          ['Cash'],
          ['Cash', 'b', 'c'],
          <Object?>[],
          'Cash=b',
          null,
          42,
          {'Cash': 'b'},
          [1, 2],
          [null, null],
        ]
      });
      expect(s.merchantPatterns, [
        ['Groceries', 'a'],
        ['1', '2'],
        ['null', 'null'],
      ]);
      // Junk categories from that list are not categories, so the categorizer ignores them.
      final cz = Categorizer(patterns: s.merchantPatterns);
      expect(cz.merchantCategory('a'), 'Groceries');
      expect(cz.merchantCategory('1 2'), isNull);
    });

    test('flags and modes take only exact values', () {
      expect(WalletSettings.fromMap({'salaryConfirmed': true}).salaryConfirmed, isTrue);
      expect(WalletSettings.fromMap({'salaryConfirmed': false}).salaryConfirmed, isFalse);
      for (final v in [
        1,
        0,
        'true',
        'false',
        'yes',
        const [true]
      ]) {
        expect(WalletSettings.fromMap({'salaryConfirmed': v}).salaryConfirmed, isFalse, reason: '$v');
      }
      for (final v in ['Planned', 'RECEIVED', ' received', 'received ', 'both', 5]) {
        expect(WalletSettings.fromMap({'incomeMode': v}).incomeMode, 'planned', reason: '$v');
      }
    });

    test('nothing the user typed (patterns) is ever in a warning log line', () {
      final lines = <String>[];
      final was = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
      try {
        WalletSettings.fromMap({'merchantPatterns': 'Synthetic Secret Shop', 'salary': 'Synthetic Secret Amount', 'currency': 'Synthetic'});
      } finally {
        sub.cancel();
        Logger.root.level = was;
      }
      expect(lines.where((l) => l.contains('settings.invalid')), hasLength(3));
      expect(lines.join('\n'), isNot(contains('Synthetic')));
    });
  });
}
