// Revolut account statement (.xlsx or .csv). Layout: docs/context/IMPORT_FORMATS.md.
import '../currencies.dart';
import '../model.dart';
import 'cells.dart';
import 'profile.dart';

class RevolutProfile extends BankProfile {
  const RevolutProfile();

  @override
  String get id => 'revolut';
  @override
  String get label => 'Revolut';

  static const _required = ['Started Date', 'Description', 'Amount'];
  static const _columns = ['Type', 'Product', 'Started Date', 'Description', 'Amount', 'Fee', 'State', 'Currency', 'Balance'];

  /// Type → kind. A type not listed here gives no hint.
  static const _kinds = <String, TxKind>{
    'Card Payment': TxKind.card,
    'Card Refund': TxKind.card,
    'ATM': TxKind.atm,
    'Topup': TxKind.ownTransfer, // funded from the owner's other account
    'Exchange': TxKind.exchange, // between the owner's own currency balances, inside Revolut
    'Fee': TxKind.fee,
    'Transfer': TxKind.other, // to or from other people
  };

  static int _headerRow(ImportContext ctx) => ctx.head.indexWhere((r) => _required.every(r.contains));

  /// A header row naming Started Date, Description and Amount within the first rows.
  @override
  bool detect(ImportContext ctx) => _headerRow(ctx) >= 0;

  @override
  void prepare(ImportContext ctx) {
    final h = ctx.head[_headerRow(ctx)];
    ctx.firstRow = _headerRow(ctx) + 1;
    for (final n in _columns) {
      ctx.columns[n] = h.indexOf(n);
    }
  }

  @override
  RowResult mapRow(List<Object> row, ImportContext ctx) {
    Object at(String name) {
      final c = ctx.column(name);
      return c >= 0 && c < row.length ? row[c] : '';
    }

    if (cellText(at('Started Date')).isEmpty) return const RowResult.ignored();
    if (ctx.column('State') >= 0 && cellText(at('State')) != 'COMPLETED') return const RowResult.skipped();
    // An empty Amount is not a transaction (owner decision): ignored without a count.
    if (cellText(at('Amount')).isEmpty) return const RowResult.ignored();
    // From here the row has a Started Date and an Amount: if any of it cannot be read, it is counted.
    final d = cellDate(at('Started Date'));
    final a = cellNumber(at('Amount'));
    // An empty Fee is 0; a Fee that is there but not a number would silently change the amount.
    final fee = ctx.column('Fee') >= 0 && cellText(at('Fee')).isNotEmpty ? cellNumber(at('Fee')) : 0.0;
    if (d == null || d == impossibleDate || a == null || fee == null) return const RowResult.invalid();
    final currency = cellCurrency(ctx.column('Currency') >= 0 ? at('Currency') : null);
    // The amount in the currency's stored units (fiat hundredths as always, BTC satoshis); a finer fraction is refused
    // with its reason, never rounded (UX-A).
    final (minor, amountProblem) = cellAmount(a, currency, 'amount', at('Amount'));
    final (feeMinor, feeProblem) = cellAmount(fee, currency, 'fee', ctx.column('Fee') >= 0 ? at('Fee') : '0');
    if (minor == null || feeMinor == null) return RowResult.invalid(amountProblem ?? feeProblem);
    final type = cellText(at('Type'));
    final desc = fixMojibake(cellText(at('Description')));
    final product = cellText(at('Product'));
    // Optional: the pocket's balance after the row. An empty or unreadable cell gives none; the row still imports. A
    // balance with a finer fraction than the currency is stored with is refused like the amount (never rounded).
    final balanceCell = ctx.column('Balance') >= 0 ? at('Balance') : '';
    final balanceNum = cellText(balanceCell).isEmpty ? null : cellNumber(balanceCell);
    final (balance, balanceProblem) = balanceNum == null ? (null, null) : cellAmount(balanceNum, currency, 'balance', balanceCell);
    if (balanceProblem != null) return RowResult.invalid(balanceProblem);
    // Fiat ids hash the cents (exact here, so the ids v1 gave); a crypto row its satoshis ([ImportContext.v1Id]).
    return RowResult.transaction(NormalizedTransaction(
      id: ctx.v1Id(d, minor - feeMinor, desc, digits: storageDigitsOf(currency)),
      source: id,
      date: d,
      amountMinor: minor - feeMinor,
      currency: currency,
      bankType: type,
      description: desc,
      kindHint: _kinds[type],
      account: product.isEmpty ? null : product,
      balanceAfter: balance,
    ));
  }
}
