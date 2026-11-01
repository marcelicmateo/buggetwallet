// The bank profile contract. One [BankProfile] per bank knows that bank's layout: how to recognise it from the
// first rows, where the columns are, and what each row means. The importer itself knows no bank.
import '../ids.dart';
import '../limits.dart';
import '../model.dart';
import 'cells.dart';

/// How many rows from the top of a sheet a profile sees in [ImportContext.head] when detecting the layout.
const headRows = 15;

/// What a profile made of one sheet row.
enum RowOutcome {
  /// A transaction ([RowResult.transaction] is set).
  transaction,

  /// Not a transaction row at all (header, footer, blank, a row without an amount): not counted.
  ignored,

  /// A transaction row deliberately left out (card hold, non-completed row): counted in [ImportBatch.skipped].
  skipped,

  /// A transaction row with an unusable value (amount or date): counted in [ImportBatch.invalid].
  invalid,
}

/// The result of [BankProfile.mapRow].
class RowResult {
  final RowOutcome outcome;
  final NormalizedTransaction? transaction;

  /// Why an [RowOutcome.invalid] row was left out, without the row number (`the amount "-12,345" has more than 2
  /// decimals …`), when the profile can say; [BankProfile.parse] puts it in [ImportBatch.problems] as `Row N: …`.
  final String? problem;
  const RowResult._(this.outcome, this.transaction, [this.problem]);
  const RowResult.ignored() : this._(RowOutcome.ignored, null);
  const RowResult.skipped() : this._(RowOutcome.skipped, null);
  const RowResult.invalid([String? problem]) : this._(RowOutcome.invalid, null, problem);
  RowResult.transaction(NormalizedTransaction tx) : this._(RowOutcome.transaction, tx);
}

/// Per-file state: what the profiles see while detecting ([head], [format], [fileName]) and what the winning profile
/// records in [prepare][BankProfile.prepare] for its [mapRow][BankProfile.mapRow] calls ([firstRow], [columns],
/// [account]). Also hands out ids, counting identical rows so re-imports never duplicate.
class ImportContext {
  ImportContext({required this.head, this.format = '', this.fileName});

  /// The first [headRows] rows of the sheet with every cell as trimmed text ([cellText]).
  factory ImportContext.of(List<List<Object>> rows, {String format = '', String? fileName}) =>
      ImportContext(head: rows.take(headRows).map((r) => r.map(cellText).toList()).toList(), format: format, fileName: fileName);

  final List<List<String>> head;

  /// The container format: `xls`, `xlsx`, `csv`, or empty when the rows did not come from a file.
  final String format;

  /// The file name as the user picked it, if known. Only for detection: it is never logged or stored.
  final String? fileName;

  /// Index of the first row that may hold a transaction; rows above it are the header block.
  int firstRow = 0;

  /// Column index by header name for profiles whose files carry a header row; -1 when the column is missing.
  final Map<String, int> columns = {};
  int column(String name) => columns[name] ?? -1;

  /// The account identifier the file header names, if the profile found one.
  String? account;

  final _seen = <String, int>{};

  /// How many identical (date, amount, description) rows came before this one in the file.
  int occurrence(String date, int amountMinor, String description, {int digits = 2}) {
    final key = '$date|${minorIdText(amountMinor, digits)}|$description';
    final n = _seen[key] ?? 0;
    _seen[key] = n + 1;
    return n;
  }

  /// The v1 id for a row ([transactionId]). Only the banks v1 knew (PBZ, Revolut) use it: their ids must stay the same.
  /// [digits]: 2 for every fiat row ([amountMinor] = v1's cents: the ids v1 gave); a crypto row passes its stored
  /// satoshis and 8 (UX-A), so 0.001 and 0.002 BTC on one day get different ids.
  String v1Id(String date, int amountMinor, String description, {int digits = 2}) =>
      transactionId(date, amountMinor, description, occurrence(date, amountMinor, description, digits: digits), digits: digits);

  /// The id for a row of a bank added after v1 ([sourceTransactionId]); [digits] = the storage digits of [amountMinor]'s
  /// currency (`storageDigitsOf`: 2 for fiat, BTC 8).
  String sourceId(String source, String date, int amountMinor, String description, {int digits = 2}) =>
      sourceTransactionId(source, date, amountMinor, description, occurrence(date, amountMinor, description, digits: digits),
          digits: digits);
}

/// Everything the importer knows about one bank's export. Stateless: per-file state lives in [ImportContext].
abstract class BankProfile {
  const BankProfile();

  /// Short stable key, also the `source` of every transaction it produces: `pbz`, `revolut`.
  String get id;

  /// The bank's name as shown to the user. The only place a bank name may reach the app from.
  String get label;

  /// Whether the file is this bank's export, judged from [ImportContext.head], [ImportContext.format] and
  /// [ImportContext.fileName]. Must not change [ctx]: every profile in the registry sees the same context.
  bool detect(ImportContext ctx);

  /// Called once per file after [detect] won: records the header row ([ImportContext.firstRow]), the column
  /// positions ([ImportContext.columns]) and the account ([ImportContext.account]) for [mapRow].
  void prepare(ImportContext ctx) {}

  /// What one sheet row means. Ids come from [ImportContext.v1Id] or [ImportContext.sourceId]; `source` is [id].
  RowResult mapRow(List<Object> row, ImportContext ctx);

  /// Runs [prepare] and [mapRow] over the sheet: rows from [ImportContext.firstRow] on, in order. A transaction whose
  /// amount (after the fee) is beyond ±[maxRowAmountMinor] is left out and counted as invalid and [ImportBatch.tooLarge].
  ImportBatch parse(List<List<Object>> rows, ImportContext ctx) {
    prepare(ctx);
    final out = <NormalizedTransaction>[];
    final invalidRows = <int>[], problems = <String>[];
    var skipped = 0, invalid = 0, tooLarge = 0;
    for (var i = ctx.firstRow; i < rows.length; i++) {
      final r = mapRow(rows[i], ctx);
      if (r.problem case final p?) problems.add('Row ${i + 1}: $p');
      switch (r.outcome) {
        case RowOutcome.transaction:
          if (r.transaction!.amountMinor.abs() > maxRowAmountMinor) {
            invalid++;
            tooLarge++;
            continue;
          }
          out.add(r.transaction!);
        case RowOutcome.skipped:
          skipped++;
        case RowOutcome.invalid:
          invalid++;
          invalidRows.add(i);
        case RowOutcome.ignored:
          break;
      }
    }
    return ImportBatch(
        source: id,
        transactions: out,
        skipped: skipped,
        invalid: invalid,
        invalidRows: invalidRows,
        tooLarge: tooLarge,
        problems: problems);
  }
}
