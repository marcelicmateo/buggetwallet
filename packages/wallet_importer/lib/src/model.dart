/// What kind of movement a transaction is, as far as the bank's own export says. A hint for categorisation; the
/// bank's wording stays in [NormalizedTransaction.bankType].
enum TxKind {
  /// Card payment or card refund at a merchant.
  card,

  /// Cash withdrawal.
  atm,

  /// Salary, pension or other pay the bank marks as such.
  salary,

  /// The bank's own fees, fee refunds and interest.
  fee,

  /// Standing order (recurring payment the bank runs).
  standingOrder,

  /// Money moved to or from another of the owner's accounts at a different bank (a top-up of the owner's Revolut,
  /// the card payment that funds it). Evidence for pairing the two sides across sources.
  ownTransfer,

  /// A currency conversion inside the same bank (a Revolut Exchange leg): the owner's money, not spending, but no
  /// evidence of money moving to another bank, so it never pairs across sources.
  exchange,

  /// The bank marked it as something the other kinds do not cover (bills, transfers to people, branch cash, ...).
  other,
}

/// One transaction in Budget Wallet's own format. Contract version 1 (`kindHint` and `account` are optional
/// additions; a consumer that ignores them sees the v1 shape).
class NormalizedTransaction {
  /// Deterministic id: re-importing the same row always yields the same id.
  final String id;

  /// Where it came from: the bank profile's id, `pbz` or `revolut`.
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

  /// What kind of movement the bank's export says this is, or `null` when the profile could not tell.
  final TxKind? kindHint;

  /// The account the row belongs to, as the export names it (an IBAN, a product name), or `null` when unknown.
  final String? account;

  const NormalizedTransaction({
    required this.id,
    required this.source,
    required this.date,
    required this.amountMinor,
    required this.currency,
    required this.bankType,
    required this.description,
    this.kindHint,
    this.account,
  });

  /// The v1 fields, plus `kindHint` (enum name) and `account` only when set.
  Map<String, Object?> toJson() => {
        'v': 1,
        'id': id,
        'source': source,
        'date': date,
        'amountMinor': amountMinor,
        'currency': currency,
        'bankType': bankType,
        'description': description,
        if (kindHint != null) 'kindHint': kindHint!.name,
        if (account != null) 'account': account,
      };

  @override
  String toString() => 'NormalizedTransaction($date $amountMinor $currency $description)';
}

/// The result of reading one bank file.
class ImportBatch {
  /// The bank profile's id (`pbz`, `revolut`).
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
