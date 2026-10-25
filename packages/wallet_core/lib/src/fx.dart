/// P15: other currencies in the budget by an owner-set rate (`WalletSettings.fxRates`). Pure: nothing is written.
library;

import 'models.dart';

/// [amount] minor units of another currency in wallet-currency minor units at [rate] ([FxRate.rate], per
/// [FxRate.scale]): `amount × rate / 1,000,000`, rounded half away from zero, exactly. The product is split
/// (`amount = q × scale + r`), so no step goes past 2^53 for any amount up to `WalletSettings.maxAmount` and any rate up
/// to [FxRate.maxRate]: the same result on the VM and on the web.
int convertMinor(int amount, int rate) {
  const s = FxRate.scale;
  final a = amount.abs();
  final q = a ~/ s, r = a % s;
  final frac = r * rate; // < 10^6 × 10^9
  final whole = q * rate + frac ~/ s + (frac % s * 2 >= s ? 1 : 0);
  return amount < 0 ? -whole : whole;
}

/// [t]'s amount in the wallet currency ([WalletSettings.currency]): its own amount when it is in that currency, the
/// bank's amount when the export gave one ([Tx.homeAmount], P15 hook), else converted at the owner's rate
/// ([convertMinor]); null when its currency has no rate (it stays out of every sum). Never a guessed rate.
int? homeAmount(Tx t, WalletSettings st) {
  if (t.currency == st.currency) return t.amount;
  if (t.homeAmount case final int h) return h;
  final r = st.fxRates[t.currency];
  return r == null ? null : convertMinor(t.amount, r.rate);
}

/// [txs] (an expanded list, `Categorizer.expandAll`) with every row whose currency has a rate as a row in the wallet
/// currency: [Tx.inCurrency] with the [homeAmount] (same id), the original amount and currency in
/// [CategorizedTx.originalAmount] / [CategorizedTx.originalCurrency]. The parts of a split payment are converted one by
/// one and its last part takes the rounding remainder (converted whole − the other parts in [txs]), so the parts add up
/// to the converted whole exactly; the parts share one converted [CategorizedTx.whole]. A split payment the bank gave a
/// home amount for ([Tx.homeAmount]) keeps its parts in their own currency (how the bank's amount divides is not known),
/// so they stay out of the sums. Rows in the wallet currency or without a rate are kept as they are. Nothing to convert
/// (no rates) → [txs] itself.
///
/// Money paths (computePeriod, monthSummary, budgets, insights, CSV summary) run on this list; whole-payment paths
/// (matching, transfers, accounts, recurring detection and matching, bills) keep the raw rows.
List<CategorizedTx> inHomeCurrency(List<CategorizedTx> txs, WalletSettings st) {
  if (!txs.any((t) => t.tx.currency != st.currency && homeAmount(t.tx, st) != null)) return txs;
  // Per split payment: the converted sum of its parts other than the last.
  final others = <String, int>{};
  for (final t in txs) {
    if (!t.isPart || t.part! + 1 >= t.parts) continue;
    if (_partRate(t, st) case final int r) others[t.tx.id] = (others[t.tx.id] ?? 0) + convertMinor(t.amount, r);
  }
  final wholes = <String, CategorizedTx>{};
  return [for (final t in txs) _convert(t, st, others, wholes) ?? t];
}

/// The rate a part of [t]'s payment is converted at; null when its parts are not converted.
int? _partRate(CategorizedTx t, WalletSettings st) =>
    t.tx.currency == st.currency || t.tx.homeAmount != null ? null : st.fxRates[t.tx.currency]?.rate;

/// [t] converted, or null when it stays as it is. [wholes]: the converted whole of each split payment met so far.
CategorizedTx? _convert(CategorizedTx t, WalletSettings st, Map<String, int> others, Map<String, CategorizedTx> wholes) {
  if (t.tx.currency == st.currency) return null;
  if (!t.isPart) {
    final home = homeAmount(t.tx, st);
    return home == null ? null : t.converted(t.tx.inCurrency(st.currency, home));
  }
  final rate = _partRate(t, st);
  if (rate == null) return null;
  final w = wholes[t.tx.id] ??= (t.whole ?? CategorizedTx(t.tx, t.category, t.kind)).converted(
    t.tx.inCurrency(st.currency, convertMinor(t.tx.amount, rate)),
  );
  final amount = t.part! + 1 < t.parts ? convertMinor(t.amount, rate) : w.tx.amount - (others[t.tx.id] ?? 0);
  return t.converted(w.tx, amount: amount, whole: w);
}
