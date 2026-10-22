# relay — notes for Claude

Pure Dart server (`dart:io` + `cryptography` for SHA-256). Stores sealed sync files it cannot read. **The wire protocol is
`docs/context/RELAY_PROTOCOL.md`: change it there first**, the client (`RelayTransport` in `wallet_core`) follows the same file.
Never put a token, key, body, full id or client address in a log line, a test fixture or a comment.

## Files
- `bin/relay.dart` — flags `--host --port --data --origin (repeatable) --max-wallets --max-bytes` (hand-parsed, no `args`),
  env `BW_RELAY_HOST/PORT/DATA/ORIGINS/MAX_WALLETS/MAX_BYTES` (flags win); usage error = exit 64; SIGINT/SIGTERM = graceful stop.
- `lib/relay.dart` — barrel. `lib/src/relay_server.dart` — `Relay({data, origins, maxWallets, maxBytes, now, log})`:
  `serve({host, port})` (port 0 for tests), `close()`, `handle(HttpRequest)`, `walletCount`. Routing, auth, body limits, the
  per-wallet async lock (`_locked`), every endpoint. `now` drives lastSeen, the 90-day rule and the rate limit.
- `lib/src/wallet.dart` — `Wallet` (devices, snapshots, byte total), `meta.json` save/load (atomic temp + rename), `prune`,
  name patterns, `writeAtomic`. `lib/src/rate_limit.dart` — token bucket (20/s, burst 100) per client address.

## Rules
- Storage: `<wid>/meta.json` (token hash, per device `last`/`lastSeen`/`acks`, kept snapshots), `<wid>/d/<device>/<seq>`,
  `<wid>/snap/<id>`. `first` is not stored: it is the lowest seq on disk, or `last + 1` when all were pruned. `last` = max of
  meta and disk, so a crash between a file and the meta loses nothing. Load deletes temp files and snapshot files the meta does
  not name; a folder without a readable meta is not a wallet (a new first PUT replaces it).
- Every wallet operation runs inside `_locked(wid, ...)`; wallet creation reserves its slot in `_wallets` before any await so
  concurrent creations cannot pass `--max-wallets`.
- Prune after every accepted PUT d / ack / snapshot (`Wallet.prune`). Files are deleted in ascending seq, so the pruned set is
  always a prefix.
- Resolutions where the protocol was silent are listed in the R2 report; the ones that matter: snapshot checks order 422 before
  409; same snapshot id again = 200 (same bytes + covers) or 409; `lastSeen` also refreshes on 200/409/410/422 of a known
  device; snapshot 507 counts only the kept snapshots, not the files they will prune.

## Test
`tools/build.sh shell -c 'cd relay && dart pub get && dart analyze --fatal-infos && dart test'` (a `relay` step in `build.sh`
comes with R7). Tests run over real HTTP on port 0 (`test/support.dart` `Harness`: temp folder, injectable clock, captured log
sink, `restart()` over the same folder). `test/bin_test.dart` starts `bin/relay.dart` as a process (slow: ~3 s per start).
