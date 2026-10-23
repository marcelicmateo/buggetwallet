// ignore_for_file: avoid_dynamic_calls
// Stage H12 / H4 (id collisions): a "duplicate" id that arrives with another amount or description is still a duplicate
// (the first row stays, nothing is overwritten) but is counted and logged without any content, so a hash collision or
// a bank that changed a row is visible. Re-importing the same file never counts. Written from the Stage H spec;
// `ImportSummary.collisions` and the `repo.idCollision` log event skip with `BUG: H4` until the build has them.
// All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

const _t = Timeout(Duration(seconds: 30));

NormalizedTransaction _same(NormalizedTransaction t, {int? cents, String? desc}) => NormalizedTransaction(
      id: t.id,
      source: t.source,
      date: t.date,
      amountMinor: cents ?? t.amountMinor,
      currency: t.currency,
      bankType: t.bankType,
      description: desc ?? t.description,
    );

int? _collisions(ImportSummary s) {
  try {
    return (s as dynamic).collisions as int;
  } on NoSuchMethodError {
    return null;
  }
}

void main() {
  final probe = () {
    final r = WalletRepo.inMemory();
    try {
      return _collisions(r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-01-12', -100, 'x', 'probe')]))) != null;
    } finally {
      r.close();
    }
  }();
  final skip = probe ? null : 'BUG: H4 - ImportSummary.collisions / repo.idCollision log';

  late WalletRepo r;
  late NormalizedTransaction first;
  setUp(() {
    r = WalletRepo.inMemory();
    first = n('2026-01-12', -2340, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB');
    r.importBatch(ImportBatch(source: 'pbz', transactions: [first]));
  });
  tearDown(() => r.close());

  group('a known id with other content', () {
    test('another amount: still a duplicate, the first row is kept, one collision is counted', () {
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: [_same(first, cents: -2350)]));
      expect((s.added, s.duplicates), (0, 1));
      expect(_collisions(s), 1);
      final row = r.transactions().single;
      expect((row.amount, row.description), (-2340, first.description), reason: 'no overwrite');
    }, skip: skip, timeout: _t);

    test('another description: counted as well', () {
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: [_same(first, desc: 'PBZ POS PBZ7LIDL OTHER TOWN')]));
      expect((s.added, s.duplicates, _collisions(s)), (0, 1, 1));
      expect(r.transactions().single.description, first.description);
    }, skip: skip, timeout: _t);

    test('both different, several in one batch: every one is counted once', () {
      final other = n('2026-01-13', -500, 'POS plaćanje', 'POS SYNTH SHOP');
      r.importBatch(ImportBatch(source: 'pbz', transactions: [other]));
      final s =
          r.importBatch(ImportBatch(source: 'pbz', transactions: [_same(first, cents: -1, desc: 'x'), _same(other, cents: -2), first]));
      expect((s.added, s.duplicates, _collisions(s)), (0, 3, 2), reason: 'the third is an exact repeat: no collision');
    }, skip: skip, timeout: _t);

    test('the same id twice inside one batch with other content: the first wins, the second is the collision', () {
      final fresh = n('2026-01-14', -700, 'POS plaćanje', 'POS SYNTH CAFE');
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: [fresh, _same(fresh, cents: -701)]));
      expect(s.added, 1);
      expect(_collisions(s), 1);
      expect(r.transactions().firstWhere((t) => t.id == fresh.id).amount, -700);
    },
        skip:
            'BUG: H4 - the same id twice in ONE batch with another amount is imported twice (added 2) and the second overwrites the first',
        timeout: _t);

    test('the collision event carries a count only: no amount, description, id or date', () {
      final lines = <String>[];
      final saved = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen((rec) => lines.add(formatLogRecord(rec)));
      addTearDown(() {
        Logger.root.level = saved;
        sub.cancel();
      });
      r.importBatch(ImportBatch(source: 'pbz', transactions: [_same(first, cents: -2350)]));
      final hit = lines.where((l) => l.contains('idCollision')).toList();
      expect(hit, hasLength(1));
      for (final secret in ['2350', '2340', 'LIDL', 'ZAGREB', first.id, '2026-01-12']) {
        expect(hit.single, isNot(contains(secret)), reason: secret);
      }
    }, skip: skip, timeout: _t);
  });

  group('no false alarm', () {
    test('importing the same file again, and a row identical to a known one, counts nothing', () {
      final batch = ImportBatch(
          source: 'pbz',
          transactions: [first, for (var i = 0; i < 30; i++) n('2026-01-${10 + i % 15}', -100 - i, 'POS plaćanje', 'POS SYNTH $i')]);
      r.importBatch(batch);
      final again = r.importBatch(batch);
      expect(again.added, 0);
      expect(again.duplicates, batch.transactions.length);
      expect(_collisions(again) ?? 0, 0);
    }, timeout: _t);

    test('equal rows on the same day get occurrence ids and are not collisions', () {
      final a = n('2026-01-15', -1000, 'POS plaćanje', 'POS SYNTH TWIN');
      final b = n('2026-01-15', -1000, 'POS plaćanje', 'POS SYNTH TWIN', occ: 1);
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: [a, b]));
      expect(s.added, 2);
      expect(_collisions(s) ?? 0, 0);
    }, timeout: _t);
  });
}
