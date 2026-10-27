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
/// ([convertMinor]); null when its currency has no rate (it stays out of every sum) or the converted amount is beyond
/// [WalletSettings.maxAmount] (a rate typed wrong: the row stays foreign). Never a guessed rate.
int? homeAmount(Tx t, WalletSettings st) {
  if (t.currency == st.currency) return t.amount;
  final h = t.homeAmount ?? switch (st.fxRates[t.currency]) { final r? => convertMinor(t.amount, r.rate), null => null };
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
    t.tx.homeAmount == null ? convertMinor(t.amount, st.fxRates[t.tx.currency]!.rate) : _share(t.amount, home, t.tx.amount);

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
