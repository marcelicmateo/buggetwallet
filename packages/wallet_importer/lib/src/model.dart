/// One transaction in Budget Wallet's own format. Contract version 1.
class NormalizedTransaction {
  /// Deterministic id: re-importing the same row always yields the same id.
  final String id;

  /// Where it came from: `pbz` or `revolut`.
  final String source;

  /// Booking date, `YYYY-MM-DD`.
  final String date;

  /// Signed amount in minor units (cents). Negative = money out.
  final int amountMinor;

  /// ISO 4217 code, e.g. `EUR`.
  final String currency;

  /// The bank's own transaction type, kept for categorisation.
  final String bankType;

  /// The bank's description text.
  final String description;

  const NormalizedTransaction({
    required this.id,
    required this.source,
    required this.date,
    required this.amountMinor,
    required this.currency,
    required this.bankType,
    required this.description,
  });

  Map<String, Object?> toJson() => {
        'v': 1,
        'id': id,
        'source': source,
        'date': date,
        'amountMinor': amountMinor,
        'currency': currency,
        'bankType': bankType,
        'description': description,
      };

  @override
  String toString() => 'NormalizedTransaction($date $amountMinor $currency $description)';
}

/// The result of reading one bank file.
class ImportBatch {
  final String source;
  final List<NormalizedTransaction> transactions;

  /// Rows deliberately left out (pending card holds, non-completed rows).
  final int skipped;

  /// Transaction rows left out because a value in them is unusable: an amount that is not a finite number or is
  /// beyond ±10 billion, or a date that is not a real calendar day (2026-13-45, 31.02.2026).
  /// The rest of the file still imports; the app tells the user how many rows were left out.
  final int invalid;

  const ImportBatch({required this.source, required this.transactions, this.skipped = 0, this.invalid = 0});
}
