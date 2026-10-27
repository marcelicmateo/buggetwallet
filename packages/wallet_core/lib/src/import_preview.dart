/// Q4: what an import would do, row by row, before anything is written (`WalletRepoImport.previewImport`). Web-safe.
library;

import 'package:wallet_importer/wallet_importer.dart' show NormalizedTransaction;

/// What `importBatch` will do with one row of a batch.
enum PreviewStatus {
  /// A new row: it is written.
  fresh,

  /// This wallet already holds the row (same id, amount and description), or an earlier row of the batch took the id:
  /// nothing is written.
  duplicate,

  /// This wallet holds the id with another amount or description (an id collision): skipped, never overwritten.
  collision,

  /// The row is here but deleted, and its id is in the `revive` set: it is undeleted (counted as added).
  revivable,

  /// A new row that will replace an expense added by hand ([PreviewRow.matchedManualId]): written, and the hand-added
  /// entry stops counting (`planMatches`).
  matchesManual,

  /// The amount is beyond ±`maxAmountCents` (`isSafeCents`): never written.
  tooLarge,
}

/// One row of a batch and what the import will do with it.
class PreviewRow {
  final NormalizedTransaction tx;
  final PreviewStatus status;

  /// The hand-added entry this row will replace (for [PreviewStatus.matchesManual], or a revived row that takes one).
  final String? matchedManualId;

  /// The row on the owner's other account this one will pair with as an own transfer (`planTransfers`), or null.
  final String? transferPairId;

  const PreviewRow({required this.tx, required this.status, this.matchedManualId, this.transferPairId});

  @override
  String toString() => 'PreviewRow(${status.name})';
}

/// The preview of a whole batch: [rows] in batch order and the count of each status. Counts are disjoint by status
/// ([duplicates] here leaves out [collisions]; `ImportSummary.duplicates` counts both). [transfers] = rows with a
/// [PreviewRow.transferPairId].
class ImportPreview {
  final List<PreviewRow> rows;
  final int fresh, duplicates, collisions, revivable, matchesManual, transfers, tooLarge;

  const ImportPreview({
    required this.rows,
    required this.fresh,
    required this.duplicates,
    required this.collisions,
    required this.revivable,
    required this.matchesManual,
    required this.transfers,
    required this.tooLarge,
  });

  /// Rows that will be written: what `ImportSummary.added` will say (without a `skip` set).
  int get added => fresh + matchesManual + revivable;

  /// Counts [rows] by status.
  factory ImportPreview.of(List<PreviewRow> rows) {
    int n(PreviewStatus s) => rows.where((r) => r.status == s).length;
    return ImportPreview(
      rows: List.unmodifiable(rows),
      fresh: n(PreviewStatus.fresh),
      duplicates: n(PreviewStatus.duplicate),
      collisions: n(PreviewStatus.collision),
      revivable: n(PreviewStatus.revivable),
      matchesManual: n(PreviewStatus.matchesManual),
      transfers: rows.where((r) => r.transferPairId != null).length,
      tooLarge: n(PreviewStatus.tooLarge),
    );
  }
}
