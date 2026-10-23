// H4: a known id arriving with another amount or description is an id collision: skipped, counted and logged with
// the count only. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

NormalizedTransaction _same(NormalizedTransaction t, {int? amount, String? description}) => NormalizedTransaction(
      id: t.id,
      source: t.source,
      date: t.date,
      amountMinor: amount ?? t.amountMinor,
      currency: t.currency,
      bankType: t.bankType,
      description: description ?? t.description,
    );

void main() {
  late WalletRepo r;
  late List<String> lines;
  setUp(() {
    r = WalletRepo.inMemory();
    r.importBatch(january);
    lines = [];
    final was = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((l) => lines.add(formatLogRecord(l)));
    addTearDown(() async {
      await sub.cancel();
      Logger.root.level = was;
      r.close();
    });
  });

  test('the same rows again are plain duplicates: no collision, nothing logged', () {
    final s = r.importBatch(january);
    expect((s.added, s.duplicates, s.collisions), (0, january.transactions.length, 0));
    expect(lines.where((l) => l.contains('repo.idCollision')), isEmpty);
  });

  test('another amount or description under a known id: counted, logged with the count only, the stored row kept', () {
    final t = january.transactions;
    final batch = ImportBatch(source: 'pbz', transactions: [
      _same(t[3], amount: -9876),
      _same(t[4], description: 'Synthetic other text'),
      t[5],
      n('2026-01-25', -1111, 'POS plaćanje', 'Synthetic new row'),
    ]);
    final before = r.transactions().firstWhere((x) => x.id == t[3].id);
    final s = r.importBatch(batch);
    expect((s.added, s.duplicates, s.collisions), (1, 3, 2));
    final after = r.transactions().firstWhere((x) => x.id == t[3].id);
    expect((after.amount, after.description), (before.amount, before.description));
    final logged = lines.where((l) => l.contains('repo.idCollision')).toList();
    expect(logged, [endsWith('WARNING bw.repo repo.idCollision {"source":"pbz","count":2}')]);
    // Without the time prefixes: a time can hold the digits of an amount.
    final text = lines.join('\n').replaceAll(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+[+-]\d\d:\d\d ', multiLine: true), '');
    for (final secret in ['9876', '98.76', 'Synthetic other text', t[3].id, t[4].id, t[3].description]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
    expect(text, contains('"collisions":2'));
  });
}
