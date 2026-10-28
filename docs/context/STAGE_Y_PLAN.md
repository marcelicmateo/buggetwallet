# Stages after M (owner 2026-10-28: "continue as much as you can without me")

Owner picked: **budget presets**, **web sync** (P18, un-parks web), **lost-device revocation** (P17). Built one stage
at a time in this order (presets small; web sync before device keys so the browser gets device keys too). The owner
is away: the lead decided the open points below; each is a line for the owner to overrule at M6.

Hard rules as always: money never changes without the owner's tap or on amount alone; integer cents; every write via
`WalletRepo._write`; no new packages; logs counts only; web-safe shared code.

## Stage BP — budget presets
Budgets are per category per month (`categoryBudgets`, Budget › Budgets, `suggestBudgets` = 6-month average rounded
up to 10 €). A preset fills proposals (current → suggested), accepted per row or all, never saved silently (same
pattern as Suggest / `budgetProposals`).
- Presets: **Average of last 3 / 6 / 12 months** (6 = today's Suggest); **Spend 10% less** (6-month average × 0.9);
  **Fit my plan** (the monthly flexible money of the payday plan split over the spending categories by their 6-month
  share); **50/30/20** (wants = 30 % of the monthly salary split the same way; needs and savings explained in one line,
  not budgeted per category).
- Core: pure `budgetPreset(BudgetPresetKind, txs, settings, month, {table, currency})` → `Map<String,int>`; splits use
  largest-remainder rounding to whole euros so the parts add up exactly to the total; categories with no spend get
  nothing; foreign rows out; a total of 0 or no history → empty with a reason. Tests: exact sums, rounding ties
  (deterministic by category order), no history, custom categories.
- UI: Budget › Budgets: a "Start from…" menu (presets) next to Suggest → the existing proposals dialog with a header
  naming the preset and its total; one line explaining it.

## Stage WS — web sync (P18)
**Rescoped after the scout (2026-10-28):** the browser already syncs through the relay since Stage R (sync panel, 5-min
timer, `runRelaySync`, BlobStore, device id in localStorage; relay sends CORS + `Date` on every response incl. errors).
Left: `bwk2` key wrap, CSP meta, Chrome/VM coverage of the web sync path, stale comments. One ui-builder.
The browser build (localhost only, never published) syncs through the relay like phone and laptop.
- Reuse `SyncEngine` + `RelayTransport` (web-safe already) and `BlobStore`; a sync timer while the tab is open and
  "Sync now"; device id per browser stored next to the wrapped key; Web Lock single tab (exists) means one engine.
- Key: `bwk2` = PBKDF2-SHA256 **600 000** rounds (no new package; Argon2id rejected: pure-Dart Argon2 in wasm is slow
  and the `cryptography` choice is already PBKDF2); a `bwk1` blob is re-wrapped as `bwk2` on the next unlock. The
  unwrapped key lives in memory only (as today).
- Relay CORS: the relay already takes `--origin`; setup docs say to add `http://127.0.0.1:8080` for the local web
  build. CSP meta in `web/index.html`: `default-src 'self'`, `connect-src 'self' https: http://127.0.0.1:* http://localhost:*`,
  wasm allowed (`'wasm-unsafe-eval'`).
- UI: Settings › Sync on web the same as on native (relay address, test, status, devices); join with key + relay on
  web onboarding. Logs: counts only (web memory log).
- Tests: web-test (Chrome) for the sync panel with `MemoryTransport`; a VM test that the web wiring compiles
  (dart2js + dart2wasm smoke incl. `RelayTransport`); `bwk1 → bwk2` migration; desktop/emulator unaffected.

## Stage DK — device keys and revocation (P17)
Today every device signs relay requests with one Ed25519 key derived from the wallet key: a lost phone cannot be cut
off. New (relay api 5, `RELAY_PROTOCOL.md` first):
- Each install makes its own random Ed25519 key pair (stored like the device id, next to the wallet key; never synced,
  never in backups). The relay keeps per wallet a set of enrolled device keys and revoked ones.
- **Enrolment needs an enrolled device, not just the wallet key:** a new device shows a short code + QR (its public
  key fingerprint); an existing device approves it in Settings › Sync › Devices ("Approve this device"), which signs
  the enrolment with its own device key. The wallet's first device enrols itself when it creates the wallet.
- **Migration:** existing wallets (api 4, shared key) stay open to the wallet-derived key until the owner taps
  "Require approval for new devices" (Settings › Sync); until then each upgraded device enrols itself once with the
  legacy key. After the switch the legacy key is refused except for reading `GET state` (so an old build learns it must
  update).
- **Revoke:** Settings › Sync › Devices › a device › "Remove this device" (confirm, names the device's last sync) →
  the relay refuses that key from then on (401 `revoked`, shown on that device as "This device was removed from the
  wallet"). Revoking the last device of a wallet is refused. Advice shown after a revoke: rotate the wallet key if the
  device may be in someone else's hands (existing key-rotation procedure, `TECHNICAL_SPEC.md` §9).
- Relay: api 5, `meta.json` gains `devices` (pub → {added, by, revoked}) ; old api-4 clients get `newerApi`
  ("Update the app") once the wallet requires approval; tests incl. fuzz/fault cases in `relay/test`.
- Limits to state: revocation protects the relay (future data, uploads); it cannot erase what the lost device already
  holds (its database is encrypted with the wallet key, so rotation + a new wallet key is the real cure).

## Delegation (cap 4; one feature stage at a time; Stage M, PI2a run first/alongside)
| Stage | Agents (model/effort) | Order |
|---|---|---|
| BP | scout (haiku/low) → core-builder (sonnet: small pure function) + ui-builder (sonnet/high) → reviewer → stage run | after Stage M merges |
| WS | scout → core-builder (session/high: key wrap, web engine wiring) + ui-builder (sonnet/high) + devops (sonnet/medium: CSP, relay origin docs, web-test) → reviewer → stage run (incl. web-test) | after BP |
| DK | scout → core-builder (session/high: protocol + relay + client) + ui-builder (sonnet/high) + test-writer (sonnet/medium: relay/protocol spec tests) → reviewer (twice: protocol, then merge delta) → stage run | after WS |
