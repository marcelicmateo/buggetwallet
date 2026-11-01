/// P15: other currencies in the budget by an owner-set rate (`WalletSettings.fxRates`). Pure: nothing is written.
library;

import 'package:wallet_importer/wallet_importer.dart' show pow10;

import 'currencies.dart' show storageDigitsOf;
import 'models.dart';

/// 2^53 − 1: the largest whole number a web number holds exactly.
const _maxExact = 9007199254740991;

/// [amount] minor units of another currency in wallet-currency minor units at [rate] ([FxRate.rate]: home units per
/// [FxRate.scale] foreign units): `amount × rate / 1,000,000 × 10^(toDigits − fromDigits)`, rounded half away from zero,
/// exactly. [fromDigits] / [toDigits]: the storage digits of the foreign and the wallet currency (`storageDigitsOf`: 2
/// for fiat, so 1,000 yen (100000) at 6500 is 650 cents; BTC 8: 0.01 BTC (1000000) at 50,000 EUR is 50000 cents). With equal digits and a rate up to [FxRate.maxRate] the product is split
/// (`amount = q × scale + r`), so no step goes past 2^53 for any amount up to `WalletSettings.maxAmount`: the same
/// result on the VM and on the web; anything else (other digits, a crypto rate) is computed with BigInt.
int convertMinor(int amount, int rate, {int fromDigits = 2, int toDigits = 2}) {
  const s = FxRate.scale;
  final a = amount.abs();
  final int whole;
  if (fromDigits == toDigits && rate <= FxRate.maxRate) {
    final q = a ~/ s, r = a % s;
    final frac = r * rate; // < 10^6 × 10^9
    whole = q * rate + frac ~/ s + (frac % s * 2 >= s ? 1 : 0);
  } else {
    final up = toDigits > fromDigits ? pow10(toDigits - fromDigits) : 1, down = fromDigits > toDigits ? pow10(fromDigits - toDigits) : 1;
    final n = BigInt.from(a) * BigInt.from(rate) * BigInt.from(up), d = BigInt.from(s) * BigInt.from(down);
    var q = n ~/ d;
    if ((n % d) * BigInt.two >= d) q += BigInt.one;
    // Capped at 2^53 − 1 (exact on the web too); [homeAmount] refuses anything past `WalletSettings.maxAmount` anyway.
    whole = q > BigInt.from(_maxExact) ? _maxExact : q.toInt();
  }
  return amount < 0 ? -whole : whole;
}

/// [t]'s amount in the wallet currency ([WalletSettings.currency]): its own amount when it is in that currency, the
/// bank's amount when the export gave one ([Tx.homeAmount], P15 hook), else converted at the owner's rate
/// ([convertMinor]); null when its currency has no rate (it stays out of every sum) or the converted amount is beyond
/// [WalletSettings.maxAmount] (a rate typed wrong: the row stays foreign). Never a guessed rate.
int? homeAmount(Tx t, WalletSettings st) {
  if (t.currency == st.currency) return t.amount;
  final h = t.homeAmount ?? switch (st.fxRates[t.currency]) { final r? => _rowHome(t.amount, r.rate, t.currency, st), null => null };
  return h == null || h.abs() > WalletSettings.maxAmount ? null : h;
}

/// [txs] (an expanded list, `Categorizer.expandAll`) with every row whose currency has a rate as a row in the wallet
/// currency: [Tx.inCurrency] with the [homeAmount] (same id), the original amount and currency in
/// [CategorizedTx.originalAmount] / [CategorizedTx.originalCurrency]. The parts of a split payment are converted one by
/// one (at the rate, or for a bank amount ([Tx.homeAmount]) its proportional share, both half away from zero); when
/// every earlier part of the payment is in [txs], the last part takes the remainder (converted whole − the others), so
/// the parts add up to the converted whole exactly; otherwise (a filtered list) each part is converted on its own. The
/// parts share one converted [CategorizedTx.whole]. Rows in the wallet currency or without a [homeAmount] are kept as
/// they are. Nothing to convert (no rates) → [txs] itself.
///
/// Money paths (computePeriod, monthSummary, budgets, insights, CSV summary) run on this list; whole-payment paths
/// (matching, transfers, accounts, recurring detection and matching (`computePeriod(matchRows:)`), bills) keep the raw rows.
List<CategorizedTx> inHomeCurrency(List<CategorizedTx> txs, WalletSettings st) {
  if (!txs.any((t) => t.tx.currency != st.currency && homeAmount(t.tx, st) != null)) return txs;
  // Per split payment: its earlier parts present (by index) and their converted sum.
  final seen = <String, Set<int>>{}, others = <String, int>{};
  for (final t in txs) {
    if (!t.isPart || t.part! + 1 >= t.parts || t.tx.currency == st.currency) continue;
    final home = homeAmount(t.tx, st);
    if (home == null || !(seen[t.tx.id] ??= {}).add(t.part!)) continue;
    others[t.tx.id] = (others[t.tx.id] ?? 0) + _partHome(t, st, home);
  }
  final wholes = <String, CategorizedTx>{};
  return [
    for (final t in txs)
      if (t.tx.currency == st.currency) t else if (homeAmount(t.tx, st) case final home?) _convert(t, st, home, seen, others, wholes) else t
  ];
}

/// Part [t] of a payment worth [home] in the wallet currency, converted on its own.
int _partHome(CategorizedTx t, WalletSettings st, int home) =>
    t.tx.homeAmount == null ? _rowHome(t.amount, st.fxRates[t.tx.currency]!.rate, t.tx.currency, st) : _share(t.amount, home, t.tx.amount);

/// [amount] stored units of [currency] at [rate] in the wallet currency's stored units (`storageDigitsOf`: fiat ↔ fiat
/// is the same scale, so exactly the math before schema 20; BTC ↔ fiat scales by 10^6).
int _rowHome(int amount, int rate, String currency, WalletSettings st) =>
    convertMinor(amount, rate, fromDigits: storageDigitsOf(currency), toDigits: storageDigitsOf(st.currency));

/// [t] (not in the wallet currency, worth [home]) converted. [wholes]: the converted whole of each split payment met so far.
CategorizedTx _convert(
    CategorizedTx t, WalletSettings st, int home, Map<String, Set<int>> seen, Map<String, int> others, Map<String, CategorizedTx> wholes) {
  final tx = t.tx.inCurrency(st.currency, home);
  if (!t.isPart) return t.converted(tx);
  final w = wholes[t.tx.id] ??= (t.whole ?? CategorizedTx(t.tx, t.category, t.kind, iou: t.iou)).converted(tx);
  final last = t.part! + 1 >= t.parts;
  final amount = last && (seen[t.tx.id]?.length ?? 0) == t.parts - 1 ? home - (others[t.tx.id] ?? 0) : _partHome(t, st, home);
  return t.converted(w.tx, amount: amount, whole: w);
}

/// [part] × [home] / [whole], half away from zero, exactly (BigInt: the product can pass 2^63); 0 for a zero [whole].
int _share(int part, int home, int whole) {
  if (whole == 0) return 0;
  final p = BigInt.from(part) * BigInt.from(home), d = BigInt.from(whole);
  final pa = p.abs(), da = d.abs();
  var q = pa ~/ da;
  if ((pa % da) * BigInt.two >= da) q += BigInt.one;
  return (p.isNegative != d.isNegative ? -q : q).toInt();
}
