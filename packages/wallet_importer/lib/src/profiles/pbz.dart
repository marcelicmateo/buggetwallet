// PBZ current account report (.xls, BIFF8). Layout: docs/context/IMPORT_FORMATS.md.
import '../model.dart';
import 'cells.dart';
import 'profile.dart';

class PbzProfile extends BankProfile {
  const PbzProfile();

  @override
  String get id => 'pbz';
  @override
  String get label => 'PBZ';

  static final _accountLabel = RegExp(r'TRANSAKCIJSKI RA', caseSensitive: false);
  static final _dmy = RegExp(r'^\d{1,2}\.\d{1,2}\.\d{4}$');
  static final _hold = RegExp(r'^REZERVACIJA', caseSensitive: false);

  /// The header block names the account (`TRANSAKCIJSKI RAČUN:`) or the column row starts with `DATUM`.
  @override
  bool detect(ImportContext ctx) => ctx.head.any((r) => r.any((c) => _accountLabel.hasMatch(c) || c == 'DATUM'));

  /// Columns are fixed (DATUM, VRSTA TRANSAKCIJE, OPIS PLAĆANJA, IZNOS, VALUTA); every row is tried, a dated first
  /// cell marks a transaction.
  @override
  RowResult mapRow(List<Object> row, ImportContext ctx) {
    if (row.length < 4) return const RowResult.ignored();
    final c0 = row[0];
    String? d;
    if (c0 is double && c0.isFinite && c0 > 30000) {
      d = serialDate(c0);
    } else if (_dmy.hasMatch(cellText(c0))) {
      d = cellDate(c0);
    }
    if (d == null) return const RowResult.ignored();
    // An empty amount is not a transaction; a dated row with an amount we cannot read is counted.
    if (cellText(row[3]).isEmpty) return const RowResult.ignored();
    final a = cellNumber(row[3]);
    if (a == null || d == impossibleDate) return const RowResult.invalid();
    final desc = cellText(row[2]);
    if (_hold.hasMatch(desc)) return const RowResult.skipped(); // card hold: the final booking arrives in a later export
    final amount = cellCents(a);
    if (amount == null) return const RowResult.invalid();
    final currency = row.length > 4 && cellText(row[4]).isNotEmpty ? cellText(row[4]) : 'EUR';
    final type = cellText(row[1]);
    return RowResult.transaction(NormalizedTransaction(
      id: ctx.v1Id(d, amount, desc),
      source: id,
      date: d,
      amountMinor: amount,
      currency: currency,
      bankType: type,
      description: desc,
    ));
  }
}
