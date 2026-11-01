/// Currencies (Stage UX-A): the table ([allCurrencies], [currencyInfo], [minorDigitsOf]; the data lives in
/// `wallet_importer`, which reads amounts with it), the wallet-currency offer ([prevalentCurrency]) and the read of
/// amounts stored by builds before schema 20 ([legacyMinor]).
library;

import 'package:wallet_importer/wallet_importer.dart' show minorDigitsOf, pow10;

import 'models.dart';

export 'package:wallet_importer/wallet_importer.dart' show allCurrencies, CurrencyInfo, currencyInfo, minorDigitsOf;

/// Fewest payments [prevalentCurrency] counts before it offers anything.
const prevalentMinRows = 10;

/// Share of the counted payments (percent, by count) one other currency needs for [prevalentCurrency].
const prevalentPercent = 80;

/// The currency X ≠ [walletCurrency] that at least [prevalentPercent] % of [txs] are in, counted by number of payments
/// (never by amount), when at least [prevalentMinRows] are counted; else null. Deleted rows are not counted. Pure: the
/// app only offers "Use X as your wallet's currency?"; nothing switches on its own.
String? prevalentCurrency(Iterable<Tx> txs, String walletCurrency) {
  final counts = <String, int>{};
  var total = 0;
  for (final t in txs) {
    if (t.deleted) continue;
    total++;
    counts[t.currency] = (counts[t.currency] ?? 0) + 1;
  }
  if (total < prevalentMinRows) return null;
  for (final MapEntry(key: code, value: n) in counts.entries) {
    if (code != walletCurrency && n * 100 >= total * prevalentPercent) return code;
  }
  return null;
}

/// [stored] minor units of [currency] as written with [digits] minor digits (the tx row's `digits` column; null = the
/// two digits every build before schema 20 used for every currency) in [currency]'s own minor units
/// ([minorDigitsOf]): 100000 stored by an older build for 1,000 yen reads 1000; 1 stored for 0.01 BTC reads 1000000.
/// Fewer digits round half away from zero (an older build's yen row is always whole yen, so nothing is lost).
int legacyMinor(int stored, String currency, int? digits) {
  final from = digits ?? 2, to = minorDigitsOf(currency);
  if (from == to) return stored;
  if (to > from) return stored * pow10(to - from);
  final p = pow10(from - to), a = stored.abs();
  final q = a ~/ p + (a % p * 2 >= p ? 1 : 0);
  return stored < 0 ? -q : q;
}

/// The value the tx `digits` column gets for a row in [currency]: null for a 2-digit currency (the scale before
/// schema 20, so those rows' ops stay as they were), else its [minorDigitsOf].
int? digitsColumn(String currency) {
  final d = minorDigitsOf(currency);
  return d == 2 ? null : d;
}
