// PBZ current account report (.xls, BIFF8). Layout: docs/context/IMPORT_FORMATS.md.
import '../currencies.dart';
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
  static final _iban = RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]{6,30}$');

  /// VRSTA TRANSAKCIJE → kind. Types the bank marks but the enum does not cover are [TxKind.other]; a type not
  /// listed here gives no hint.
  static const _kinds = <String, TxKind>{
    'POS plaćanje': TxKind.card,
    'Isplata ATM': TxKind.atm,
    'Plaća/Mirovina': TxKind.salary,
    'Trajni nalog': TxKind.standingOrder,
    'Naplaćene naknade': TxKind.fee,
    'Povrat naknade': TxKind.fee,
    'Pripisane kamate': TxKind.fee,
    'Plaćanje putem direktnih kanala': TxKind.other,
    'Isplata u poslovnici': TxKind.other,
    'Ostalo': TxKind.other,
  };

  /// The column header row, from the first column: mapRow reads the columns by position.
  static const header = ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'];

  /// One row of the first [headRows] holds the whole column [header] from its first cell (trimmed, any case, a
  /// mis-decoded `Ć` repaired). A lone `DATUM` cell or the account label alone is not enough: another bank's export
  /// can have either.
  @override
  bool detect(ImportContext ctx) => ctx.head.any((r) {
        if (r.length < header.length) return false;
        for (var i = 0; i < header.length; i++) {
          if (fixMojibake(r[i]).toUpperCase() != header[i]) return false;
        }
        return true;
      });

  /// An optional balance column after the fixed ones, used only when the header row names it (`STANJE` or `SALDO`).
  static const balanceHeaders = ['STANJE', 'SALDO'];

  /// Columns are fixed (DATUM, VRSTA TRANSAKCIJE, OPIS PLAĆANJA, IZNOS, VALUTA); every row is tried, a dated first
  /// cell marks a transaction. A [balanceHeaders] column in the header row, after the fixed ones, gives each row's
  /// balance. The IBAN is the cell under or after the `TRANSAKCIJSKI RAČUN:` label.
  @override
  void prepare(ImportContext ctx) {
    ctx.columns['balance'] = -1;
    for (final r in ctx.head) {
      if (r.length < header.length) continue;
      var match = true;
      for (var i = 0; i < header.length && match; i++) {
        match = fixMojibake(r[i]).toUpperCase() == header[i];
      }
      if (!match) continue;
      for (var c = header.length; c < r.length; c++) {
        if (balanceHeaders.contains(r[c].toUpperCase())) {
          ctx.columns['balance'] = c;
          break;
        }
      }
      break;
    }
    for (var r = 0; r < ctx.head.length; r++) {
      final row = ctx.head[r];
      for (var c = 0; c < row.length; c++) {
        if (!_accountLabel.hasMatch(row[c])) continue;
        final below = r + 1 < ctx.head.length && c < ctx.head[r + 1].length ? ctx.head[r + 1][c] : '';
        final after = row.skip(c + 1).firstWhere((v) => v.isNotEmpty, orElse: () => '');
        final found = [below, after].where(_iban.hasMatch);
        ctx.account = found.isEmpty ? null : found.first;
        return;
      }
    }
  }

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
    // The amount in the currency's own minor units; the id keeps v1's cents (`amount`).
    final digits = minorDigitsOf(currency);
    final minor = cellMinor(a, digits);
    if (minor == null) return const RowResult.invalid();
    final type = cellText(row[1]);
    final bc = ctx.column('balance');
    final balanceNum = bc >= 0 && bc < row.length && cellText(row[bc]).isNotEmpty ? cellNumber(row[bc]) : null;
    return RowResult.transaction(NormalizedTransaction(
      id: ctx.v1Id(d, amount, desc),
      source: id,
      date: d,
      amountMinor: minor,
      currency: currency,
      bankType: type,
      description: desc,
      kindHint: _kind(type, desc),
      account: ctx.account,
      balanceAfter: balanceNum == null ? null : cellMinor(balanceNum, digits),
    ));
  }

  /// A card payment to the owner's own Revolut ("POS Revolut**xxxx* Dublin") is a transfer between own accounts.
  static TxKind? _kind(String type, String desc) {
    final k = _kinds[type];
    if (k == TxKind.card && desc.toLowerCase().contains('revolut')) return TxKind.ownTransfer;
    return k;
  }
}
