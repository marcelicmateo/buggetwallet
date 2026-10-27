// Q4 import preview (docs/context/STAGE_Q_PLAN.md): previewImport says, row by row, what importBatch then does, and
// writes nothing. importBatch(skip:) leaves the owner's skipped rows out. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/synthetic.dart';

const _lidl = 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB';
const _now = 2000000000000 + 1000000;

String _h(int millis, [String node = 'peer']) => Hlc(2000000000000 + millis, 0, node).toString();

/// Everything a preview must leave as it was: rows, clocks, outbox, meta (device-local values too), the data version.
(int, int, int, String, int) _state(WalletRepo r) => (
      r.db.select('SELECT COUNT(*) AS n FROM tx').single['n'] as int,
      r.db.select('SELECT COUNT(*) AS n FROM clocks').single['n'] as int,
      r.pendingOps().length,
      [for (final m in r.db.select('SELECT key, value FROM meta ORDER BY key')) '${m['key']}=${m['value']}'].join(';'),
      r.dataVersion,
    );

/// Previews [b], imports it, and checks that the import did exactly what the preview said.
(ImportPreview, ImportSummary) _predicted(WalletRepo r, ImportBatch b, {Set<String> revive = const {}}) {
  final before = _state(r);
  final p = r.previewImport(b, revive: revive);
  expect(_state(r), before, reason: 'the preview writes nothing');
  final s = r.importBatch(b, revive: revive);
  expect(s.added, p.added, reason: 'added');
  expect(s.duplicates, p.duplicates + p.collisions, reason: 'duplicates');
  expect(s.collisions, p.collisions, reason: 'collisions');
  expect(s.tooLarge, p.tooLarge, reason: 'too large');
  final entries = [
    for (final t in r.transactions(includeHidden: true))
      if (t.manual && !t.deleted) t
  ];
  for (final row in p.rows) {
    final id = row.tx.id;
    final stored = r.transaction(id);
    switch (row.status) {
      case PreviewStatus.fresh || PreviewStatus.matchesManual || PreviewStatus.revivable:
        expect(stored, isNotNull, reason: '$id written');
        expect(stored!.deleted, isFalse);
        final pointing = [
          for (final e in entries)
            if (e.matchedTo == id) e.id
        ];
        expect(pointing.firstOrNull, row.matchedManualId, reason: 'match of $id');
        if (row.status == PreviewStatus.fresh) expect(row.matchedManualId, isNull);
        if (row.status == PreviewStatus.matchesManual) expect(row.matchedManualId, isNotNull);
        expect(stored.transferTo, row.transferPairId, reason: 'transfer of $id');
      case PreviewStatus.tooLarge:
        expect(stored, isNull);
      case PreviewStatus.duplicate || PreviewStatus.collision:
        break;
    }
  }
  return (p, s);
}

void main() {
  late WalletRepo r;
  setUp(() => r = WalletRepo.inMemory(now: () => _now));
  tearDown(() => r.close());

  test('statuses: fresh, duplicate, collision, too large; the counts', () {
    r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-01-10', -1000, 'Ostalo', 'Synthetic a')]));
    final known = n('2026-01-10', -1000, 'Ostalo', 'Synthetic a');
    final collide = NormalizedTransaction(
        id: known.id,
        source: 'pbz',
        date: '2026-01-10',
        amountMinor: -999,
        currency: 'EUR',
        bankType: 'Ostalo',
        description: 'Synthetic a');
    final fresh = n('2026-01-11', -200, 'Ostalo', 'Synthetic b');
    final big = n('2026-01-12', -maxAmountCents - 1, 'Ostalo', 'Synthetic big');
    final (p, _) = _predicted(r, ImportBatch(source: 'pbz', transactions: [known, collide, fresh, fresh, big]));
    expect(p.rows.map((x) => x.status), [
      PreviewStatus.duplicate,
      PreviewStatus.collision,
      PreviewStatus.fresh,
      PreviewStatus.duplicate, // the second row with the same id: the first wins
      PreviewStatus.tooLarge,
    ]);
    expect((p.fresh, p.duplicates, p.collisions, p.tooLarge, p.matchesManual, p.transfers, p.revivable), (1, 2, 1, 1, 0, 0, 0));
  });

  test('an empty batch previews as nothing', () {
    final p = r.previewImport(const ImportBatch(source: 'pbz', transactions: []));
    expect(p.rows, isEmpty);
    expect(p.added, 0);
  });

  test('a bank row that replaces an expense added by hand: matchesManual, and the import matches it', () {
    final cash = r.addTransaction(date: '2026-01-17', amount: 2340, category: 'Groceries');
    final row = n('2026-01-18', -2340, 'POS plaćanje', _lidl, kind: TxKind.card);
    final other = n('2026-01-18', -999, 'POS plaćanje', _lidl, kind: TxKind.card);
    final (p, s) = _predicted(r, ImportBatch(source: 'pbz', transactions: [row, other]));
    expect(p.rows.first.status, PreviewStatus.matchesManual);
    expect(p.rows.first.matchedManualId, cash);
    expect(p.rows.last.status, PreviewStatus.fresh);
    expect(p.matchesManual, 1);
    expect(s.matched, 1);
    expect(r.transaction(cash)!.matchedTo, row.id);
  });

  test('a row the wallet already held when the entry was added never matches it (preview agrees)', () {
    r.importBatch(ImportBatch(source: 'pbz', transactions: [n('2026-01-18', -2340, 'POS plaćanje', _lidl, kind: TxKind.card)]));
    final cash = r.addTransaction(date: '2026-01-17', amount: 2340, category: 'Groceries');
    final (p, _) =
        _predicted(r, ImportBatch(source: 'pbz', transactions: [n('2026-01-25', -100, 'POS plaćanje', _lidl, kind: TxKind.card)]));
    expect(p.matchesManual, 0);
    expect(r.transaction(cash)!.matchedTo, isNull);
  });

  test('an own transfer: transferPairId names the other account\'s row, and the import pairs them', () {
    final topup = n('2026-01-16', 5000, 'Topup', 'Top-up by *0000', source: 'revolut', kind: TxKind.ownTransfer);
    r.importBatch(ImportBatch(source: 'revolut', transactions: [topup]));
    final pay = n('2026-01-16', -5000, 'POS plaćanje', 'POS Revolut**0000* Dublin', kind: TxKind.ownTransfer);
    final (p, s) = _predicted(r, ImportBatch(source: 'pbz', transactions: [pay]));
    expect(p.rows.single.transferPairId, topup.id);
    expect(p.transfers, 1);
    expect(s.transfers, 1);
  });

  test('a paired row is a transfer, so it never replaces a hand-added expense (preview agrees)', () {
    final topup = n('2026-01-16', 5000, 'Topup', 'Top-up by *0000', source: 'revolut', kind: TxKind.ownTransfer);
    r.importBatch(ImportBatch(source: 'revolut', transactions: [topup]));
    final cash = r.addTransaction(date: '2026-01-16', amount: 5000, category: 'Shopping');
    final pay = n('2026-01-16', -5000, 'POS plaćanje', 'POS Revolut**0000* Dublin', kind: TxKind.ownTransfer);
    final (p, _) = _predicted(r, ImportBatch(source: 'pbz', transactions: [pay]));
    expect(p.rows.single.status, PreviewStatus.fresh);
    expect(p.rows.single.transferPairId, topup.id);
    expect(r.transaction(cash)!.matchedTo, isNull);
  });

  test('a row an entry already points at (matched on another device before the row arrived here)', () {
    final row = n('2026-01-18', -2340, 'POS plaćanje', _lidl, kind: TxKind.card);
    r.applyRemote([
      Op(
          'tx',
          'mpeer',
          {
            'source': 'manual',
            'date': '2026-01-17',
            'amount': -2340,
            'currency': 'EUR',
            'category': 'Groceries',
            'manual': 1,
            'deleted': 0,
            'matched_to': row.id,
          },
          _h(1))
    ]);
    final (p, _) = _predicted(r, ImportBatch(source: 'pbz', transactions: [row]));
    expect(p.rows.single.status, PreviewStatus.matchesManual);
    expect(p.rows.single.matchedManualId, 'mpeer');
  });

  // Review fix 6: the preview must equal the import while not caught up too.
  test('not caught up: an entry already pointing at a batch row still shows as its match', () {
    r.setLocalValue(WalletRepo.caughtUpKey, '0');
    final row = n('2026-01-18', -2340, 'POS plaćanje', _lidl, kind: TxKind.card);
    r.applyRemote([
      Op(
          'tx',
          'mpeer',
          {
            'source': 'manual',
            'date': '2026-01-17',
            'amount': -2340,
            'currency': 'EUR',
            'category': 'Groceries',
            'manual': 1,
            'deleted': 0,
            'matched_to': row.id,
          },
          _h(1))
    ], match: false);
    final (p, _) = _predicted(r, ImportBatch(source: 'pbz', transactions: [row]));
    expect(p.rows.single.status, PreviewStatus.matchesManual);
    expect(p.rows.single.matchedManualId, 'mpeer');
  });

  test('a revived row keeps its stored transfer link; the preview says so', () {
    final topup = n('2026-01-16', 5000, 'Topup', 'Top-up by *0000', source: 'revolut', kind: TxKind.ownTransfer);
    final pay = n('2026-01-16', -5000, 'POS plaćanje', 'POS Revolut**0000* Dublin', kind: TxKind.ownTransfer);
    r.importBatch(ImportBatch(source: 'revolut', transactions: [topup]));
    r.importBatch(ImportBatch(source: 'pbz', transactions: [pay]));
    r.setLocalValue(WalletRepo.caughtUpKey, '0'); // the delete then leaves the links to the next caught-up run
    r.deleteTransaction(pay.id);
    final (p, _) = _predicted(r, ImportBatch(source: 'pbz', transactions: [pay]), revive: {pay.id});
    expect(p.rows.single.status, PreviewStatus.revivable);
  });

  test('revive: a deleted row in the revive set is revivable and comes back; without it, a duplicate', () {
    final a = n('2026-01-10', -1000, 'Ostalo', 'Synthetic a');
    r.importBatch(ImportBatch(source: 'pbz', transactions: [a]));
    r.deleteTransaction(a.id);
    final batch = ImportBatch(source: 'pbz', transactions: [a]);
    final plain = r.previewImport(batch);
    expect(plain.rows.single.status, PreviewStatus.duplicate);
    final (p, s) = _predicted(r, batch, revive: {a.id});
    expect(p.rows.single.status, PreviewStatus.revivable);
    expect(s.added, 1);
    expect(r.transaction(a.id)!.deleted, isFalse);
  });

  test('a revived row can replace a hand-added expense; the preview says so', () {
    final row = n('2026-01-18', -2340, 'POS plaćanje', _lidl, kind: TxKind.card);
    r.importBatch(ImportBatch(source: 'pbz', transactions: [row]));
    r.deleteTransaction(row.id);
    // Added while the row was deleted elsewhere: a device that never held it (another node's entry).
    r.applyRemote([
      Op(
          'tx',
          'mpeer',
          {
            'source': 'manual',
            'date': '2026-01-17',
            'amount': -2340,
            'currency': 'EUR',
            'category': 'Groceries',
            'manual': 1,
            'deleted': 0,
            'seen_bank': '[]',
          },
          _h(5))
    ]);
    final (p, _) = _predicted(r, ImportBatch(source: 'pbz', transactions: [row]), revive: {row.id});
    expect(p.rows.single.status, PreviewStatus.revivable);
    expect(p.rows.single.matchedManualId, 'mpeer');
  });

  test('not caught up with sync: no matches or pairs predicted, and the import makes none', () {
    r.setLocalValue(WalletRepo.caughtUpKey, '0');
    final cash = r.addTransaction(date: '2026-01-17', amount: 2340, category: 'Groceries');
    final (p, s) =
        _predicted(r, ImportBatch(source: 'pbz', transactions: [n('2026-01-18', -2340, 'POS plaćanje', _lidl, kind: TxKind.card)]));
    expect(p.rows.single.status, PreviewStatus.fresh);
    expect(s.matched, 0);
    expect(r.transaction(cash)!.matchedTo, isNull);
  });

  test('a history batch: every prediction holds (mixed rows, matches, a transfer)', () {
    final topup = n('2026-02-03', 2000, 'Topup', 'Top-up by *0000', source: 'revolut', kind: TxKind.ownTransfer);
    r.importBatch(ImportBatch(source: 'revolut', transactions: [topup]));
    final e1 = r.addTransaction(date: '2026-02-01', amount: 1500, category: 'Groceries');
    final e2 = r.addTransaction(date: '2026-02-10', amount: 700, category: 'Eating out');
    r.addTransaction(date: '2026-02-20', amount: 4321, category: 'Shopping'); // no bank row for it
    final rows = [
      ...january.transactions,
      n('2026-02-02', -1500, 'POS plaćanje', _lidl, kind: TxKind.card),
      n('2026-02-02', -1500, 'POS plaćanje', _lidl, kind: TxKind.card, occ: 1),
      n('2026-02-03', -2000, 'POS plaćanje', 'POS Revolut**0000* Dublin', kind: TxKind.ownTransfer),
      n('2026-02-12', -700, 'POS plaćanje', _lidl, kind: TxKind.card),
    ];
    final (p, _) = _predicted(r, ImportBatch(source: 'pbz', transactions: rows));
    expect(p.matchesManual, 2);
    expect({
      for (final x in p.rows)
        if (x.matchedManualId != null) x.matchedManualId
    }, {
      e1,
      e2
    });
    expect(p.transfers, 1);
    // A second preview of the same batch: everything is a duplicate now.
    final again = r.previewImport(ImportBatch(source: 'pbz', transactions: rows));
    expect(again.duplicates, rows.length);
  });

  group('importBatch(skip:)', () {
    test('skipped ids are not written at all and are counted apart', () {
      final a = n('2026-01-10', -1000, 'Ostalo', 'Synthetic a'), b = n('2026-01-11', -200, 'Ostalo', 'Synthetic b');
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: [a, b]), skip: {b.id});
      expect((s.added, s.duplicates, s.skippedByOwner), (1, 0, 1));
      expect(r.transaction(b.id), isNull);
      expect(r.db.select("SELECT 1 FROM clocks WHERE entity = 'tx' AND id = ?", [b.id]), isEmpty);
      // Imported later without the skip, it comes in as new.
      final later = r.importBatch(ImportBatch(source: 'pbz', transactions: [a, b]));
      expect((later.added, later.duplicates), (1, 1));
    });

    test('a skipped row never matches a hand-added expense', () {
      final cash = r.addTransaction(date: '2026-01-17', amount: 2340, category: 'Groceries');
      final row = n('2026-01-18', -2340, 'POS plaćanje', _lidl, kind: TxKind.card);
      final s = r.importBatch(ImportBatch(source: 'pbz', transactions: [row]), skip: {row.id});
      expect(s.matched, 0);
      expect(r.transaction(cash)!.matchedTo, isNull);
    });
  });
}
