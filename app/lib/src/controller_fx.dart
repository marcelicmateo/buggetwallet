// Other currencies in the budget (P15, spec docs/context/P15_SPEC.md §3). A `part` of controller.dart so it can use the cache and
// `_changed`. The conversion itself is core's (`inHomeCurrency`, called in `reload`); this file lists the currencies and sets rates.
//
// Privacy: logs carry the action only, never a rate or an amount.
part of 'controller.dart';

final _fxLog = Logger('bw.fx');

/// One currency other than the wallet's, seen in the rows or holding a rate: the Plan › Currencies row.
class FxCurrency {
  final String code;

  /// The owner's rate; null = rows in this currency are not counted.
  final FxRate? rate;

  /// A rate left from another wallet currency (core's `fxStale`): not used; [FxRate.home] says which.
  final FxRate? stale;

  /// How many payments are in this currency.
  final int rows;
  const FxCurrency(this.code, this.rate, this.rows, {this.stale});
}

extension FxDb on WalletController {
  /// A row per currency other than the wallet's that appears in the payments or has a rate, by code. Cached per data version.
  List<FxCurrency> fxCurrencies() => _cached('fxCurrencies', () {
        final seen = <String, int>{};
        for (final t in wholeTxs) {
          if (t.tx.currency != currency) seen[t.tx.currency] = (seen[t.tx.currency] ?? 0) + 1;
        }
        final codes = {...seen.keys, ...settings.fxRates.keys, ...settings.fxStale.keys}.toList()..sort();
        return [for (final c in codes) FxCurrency(c, settings.fxRates[c], seen[c] ?? 0, stale: settings.fxStale[c])];
      });

  /// Opens Plan at Currencies (from a "not counted" note).
  void openCurrencies() {
    logEvent(_fxLog, Level.INFO, 'fx.open');
    openTab(4, via: 'foreignNote');
    currenciesRequest.value++;
  }

  /// Sets the rate of [code] ([rate] = wallet minor units per 1,000,000 minor units). An [ArgumentError] carries core's text.
  void setFxRate(String code, int rate) {
    repo.setFxRate(code, rate);
    logEvent(_fxLog, Level.INFO, 'fx.set');
    _changed();
  }

  /// Removes the rate of [code]; its payments stop counting.
  void removeFxRate(String code) {
    repo.removeFxRate(code);
    logEvent(_fxLog, Level.INFO, 'fx.remove');
    _changed();
  }
}
