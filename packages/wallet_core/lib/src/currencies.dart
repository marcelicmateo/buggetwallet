/// Currencies (Stage UX-A): the table ([allCurrencies], [currencyInfo]; the data lives in `wallet_importer`, which
/// reads amounts with it) and the wallet-currency offer ([prevalentCurrency]).
///
/// Storage rule (owner, 2026-11-01): amounts are stored at [storageDigitsOf] — hundredths for every fiat currency,
/// exactly as every build before schema 20 (1,000 yen = 100000), and a crypto currency's own digits (BTC: satoshis).
/// No stored amount is ever read differently. [minorDigitsOf] (ISO) and [displayDigitsOf] are for showing and typing.
library;

import 'models.dart';

export 'package:wallet_importer/wallet_importer.dart'
    show allCurrencies, CurrencyInfo, currencyInfo, displayDigitsOf, minorDigitsOf, storageDigitsOf;

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
