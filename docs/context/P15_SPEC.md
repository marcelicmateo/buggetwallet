# Stage P15 spec: other currencies in the budget (2026-10-25)

Plan item: PATH_FORWARD P15. Owner decision (`NEXT_DECISIONS.md`): a foreign-currency payment counts in the budget with the bank's EUR amount when the export has one, else an owner-set rate per currency; both amounts shown.

**Finding:** no export the importer reads carries a home-currency amount (Revolut's synthetic fixture and `IMPORT_FORMATS.md` have Amount, Fee and Currency only). The bank-amount half needs the real Revolut header line from the owner (asked together with P12's bank headers). P15 builds the rate half and leaves a hook for the bank amount.

Rules: exact cents for a given rate (one rounding rule, half away from zero, applied once per row); never a guessed rate; a currency without a rate stays out of every sum exactly as today; `transactionId` and import ids never change; whole-payment paths (matching, transfers, accounts, recurring matching) keep the row's own currency and amount.

## 1. Settings (synced, per key like `budget:<cat>`)
- `fx:<CODE>` (`CODE` = ISO 4217, not the wallet currency): `{rate: int, date: 'YYYY-MM-DD', home: <wallet currency it was set against>}` where `rate` = home minor units per **1,000,000** minor units of `CODE`, i.e. `home = round(amount × rate / 1_000_000)`. Example: 1 USD = 0.9240 € → `rate: 924000` (100 USD cents → 92.40 € = 9240 cents). Currencies with no minor unit (JPY) are not special-cased: amounts are stored as the importer gives them. Valid: 1 ≤ rate ≤ 10^8 (at most 100 home units per foreign unit) and `home` present; else the row is dropped (`settings.invalid`, key `fx`). A row whose `home` is not the wallet currency counts nowhere (`WalletSettings.fxStale`). A converted amount beyond `WalletSettings.maxAmount` leaves the row foreign.
- `WalletSettings.fxRates` (`Map<String, FxRate>`); `WalletSettings.fxStale` (rates set against another wallet currency); repo `setFxRate(code, rate, {date})` (date = today unless given, never after today; Undo passes the old date) / `removeFxRate(code)` (stale rows too); refuses the wallet currency and bad codes. `computePeriod(matchRows:)` takes the raw list for bill and income matching.

## 2. Core (pure)
- `int? homeAmount(Tx t, WalletSettings st)`: the row's amount in the wallet currency: own currency → `t.amount`; a rate → `round half away from zero(t.amount × rate / 1e6)`; later a bank amount (hook: `Tx.homeAmount` field, unused now); else null.
- `List<CategorizedTx> inHomeCurrency(List<CategorizedTx> txs, WalletSettings st)`: every row with a rate becomes a row in the wallet currency (`tx` copy with `currency = st.currency`, `amount` = home amount; P6 parts converted per part, the parts' sum kept equal to the converted whole by giving the rounding remainder to the last part), carrying `original: (amount, currency)` on `CategorizedTx` (`originalAmount`, `originalCurrency`, null when not converted). Rows without a rate are unchanged (so they stay foreign).
- Money paths then run unchanged on that list; `foreignByCurrency` only lists currencies without a rate. Identity: no rates → the list is identical.

## 3. App
- The controller's expanded list for sums (`wc.txs`) = `inHomeCurrency(expanded, settings)`; the whole-payment list stays raw.
- **Plan › Currencies** (`currenciesPanel`, shown when any row is in another currency or a rate exists): one row per foreign currency seen: "USD — 1 $ = 0.9240 €, set 25 Oct" with Edit / Remove, or "Not counted — Set a rate" (`fxSet:<CODE>`); the rate is typed as "1 USD = [0.9240] EUR" (up to 6 decimals, the style's decimal separator).
- Rows: a converted payment shows the home amount with the original under it: "−92.40 €" / "100.00 $ at 0.9240" (`txOriginal`).
- `ForeignNote` keeps its text for currencies without a rate and adds "Set a rate in Plan › Currencies" as a tap.

## 4. Tests
- Rounding: half away from zero both signs; 1 minor unit; max amount × max rate fits in 64-bit; parts sum to the converted whole.
- A currency with a rate counts in computePeriod / monthSummary / budgets / insights at the converted amount; without a rate exactly as today; the wallet currency is never converted.
- Whole-payment paths unchanged (matching, accounts, recurring matching, transfers).
- Settings validation; two devices set different rates offline → last writer wins per currency.
- App: panel, set/edit/remove with the comma style, row shows both amounts, ForeignNote only for currencies without a rate.
