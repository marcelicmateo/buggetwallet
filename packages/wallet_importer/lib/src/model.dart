import 'limits.dart' show maxRowAmountMinor;

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

  /// Where it came from: the bank profile's id, `pbz` or `revolut`, or `csv:<shapeId>` for a mapped CSV.
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

  /// The account balance right after this row as the bank's export states it (Revolut `Balance`, a PBZ `STANJE`/`SALDO`
  /// column, a mapped CSV's balance column), in minor units; `null` when the file has none for the row. Never part of
  /// the id.
  final int? balanceAfter;

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
    this.balanceAfter,
  });

  /// The v1 fields, plus `kindHint` (enum name), `account` and `balanceAfter` only when set.
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
        if (balanceAfter != null) 'balanceAfter': balanceAfter,
      };

  @override
  String toString() => 'NormalizedTransaction($date $amountMinor $currency $description)';
}

/// The result of reading one bank file.
class ImportBatch {
  /// The bank profile's id (`pbz`, `revolut`), or `csv:<shapeId>` for a mapped CSV.
  final String source;
  final List<NormalizedTransaction> transactions;

  /// Rows deliberately left out (pending card holds, non-completed rows).
  final int skipped;

  /// Transaction rows left out because a value in them is unusable: an amount that is not a finite number or is
  /// beyond ±[maxRowAmountMinor] (after the fee), or a date that is not a real calendar day (2026-13-45, 31.02.2026).
  /// The rest of the file still imports; the app tells the user how many rows were left out.
  final int invalid;

  /// The 0-based file rows of the [invalid] ones, when the reader keeps them (a mapped CSV, `parseMappedCsv`); empty
  /// otherwise. The app says `Row ${r + 1}`.
  final List<int> invalidRows;

  /// How many of [invalid] were left out only because the amount is beyond ±[maxRowAmountMinor] (the reason the app
  /// shows: "too large").
  final int tooLarge;

  const ImportBatch(
      {required this.source,
      required this.transactions,
      this.skipped = 0,
      this.invalid = 0,
      this.invalidRows = const [],
      this.tooLarge = 0});

  /// The balance the bank states at the end of the file, per currency ([BankBalance]), from the rows'
  /// [NormalizedTransaction.balanceAfter] (completed rows only: the others are not in [transactions]).
  ///
  /// Per currency: the newest date whose last booking of the day carries a balance, and that row's balance. A date with
  /// one row has it. On a date with several rows, which one was booked last comes from the balance chain, never from a
  /// guess: the file runs oldest first when every balance is the one before plus its row's amount, newest first when
  /// every balance is the one after plus that row's amount (pairs that fit both ways or neither say nothing). When the
  /// chain does not tell (no telling pair, or pairs both ways), the currency has no balance. A day whose last row has no
  /// balance is passed over for an older one (a balance from earlier in a day is not the day's end). A currency whose
  /// rows name more than one [NormalizedTransaction.account] (a Revolut Current and Savings pocket) has none: the column
  /// is per pocket, so it cannot be compared with one account. Ordered by currency.
  List<BankBalance> get bankBalances {
    final by = <String, List<NormalizedTransaction>>{};
    for (final t in transactions) {
      (by[t.currency] ??= []).add(t);
    }
    final out = <BankBalance>[];
    for (final cur in by.keys.toList()..sort()) {
      final rows = by[cur]!;
      if (!rows.any((t) => t.balanceAfter != null)) continue;
      if ({for (final t in rows) t.account}.length > 1) continue;
      var up = 0, down = 0;
      for (var i = 1; i < rows.length; i++) {
        final p = rows[i - 1], q = rows[i];
        final pb = p.balanceAfter, qb = q.balanceAfter;
        if (pb == null || qb == null) continue;
        final oldestFirst = qb == pb + q.amountMinor, newestFirst = pb == qb + p.amountMinor;
        if (oldestFirst && !newestFirst) up++;
        if (newestFirst && !oldestFirst) down++;
      }
      final bool? oldestFirst = up > 0 && down == 0 ? true : (down > 0 && up == 0 ? false : null);
      final byDate = <String, List<NormalizedTransaction>>{};
      for (final t in rows) {
        (byDate[t.date] ??= []).add(t);
      }
      final dates = byDate.keys.toList()..sort();
      for (final d in dates.reversed) {
        final day = byDate[d]!;
        if (day.length > 1 && oldestFirst == null) break; // which row ends the day is unknown: no balance
        final end = day.length == 1 || oldestFirst! ? day.last : day.first;
        final cents = end.balanceAfter;
        if (cents == null) continue;
        out.add(BankBalance(source: source, currency: cur, date: d, cents: cents));
        break;
      }
    }
    return out;
  }
}

/// One balance a bank file states ([ImportBatch.bankBalances]): [cents] in [currency] at the end of [date] (the
/// newest booking day of the file that carries one), for the account of [source].
class BankBalance {
  final String source;
  final String currency;
  final String date;
  final int cents;
  const BankBalance({required this.source, required this.currency, required this.date, required this.cents});

  @override
  bool operator ==(Object other) =>
      other is BankBalance && other.source == source && other.currency == currency && other.date == date && other.cents == cents;

  @override
  int get hashCode => Object.hash(source, currency, date, cents);

  @override
  String toString() => 'BankBalance($source $currency $date)';
}
