# relay — notes for Claude

Pure Dart server (`dart:io` + `cryptography` for SHA-256 and Ed25519 verification). Stores sealed sync files it cannot read. **The wire protocol is
`docs/context/RELAY_PROTOCOL.md`: change it there first**, the client (`RelayTransport` in `wallet_core`) follows the same file.
Never put a signature, public key, body, full id or client address in a log line, a test fixture or a comment.

## Files
- `bin/relay.dart` — flags `--host --port --data --origin (repeatable) --max-wallets --max-bytes --create-token <file> --trust-proxy
  --public-host <name> --health-check` (hand-parsed, no `args`; the last two are switches), env `BW_RELAY_HOST/PORT/DATA/ORIGINS/MAX_WALLETS/MAX_BYTES/
  CREATE_TOKEN(_FILE)/TRUST_PROXY/PUBLIC_HOST (or DOMAIN)` (flags win); usage error = exit 64; SIGINT/SIGTERM = graceful stop. `--health-check` GETs `/v2/health`
  on 127.0.0.1:port and exits 0/1 (the image's HEALTHCHECK; no `--data` needed). `relay/deploy/` = quadlets, Caddyfile, env templates (docs/setup.md §5).
- `lib/relay.dart` — barrel. `lib/src/relay_server.dart` — `Relay({data, origins, maxWallets, maxBytes, maxInFlightBytes, now, log})`:
  `serve({host, port})` (port 0 for tests), `close()`, `handle(HttpRequest)`, `walletCount`. Routing, signature checks
  (`_signature`: headers + ±5 min clock window, before any wallet lookup or body read; `_verify` after the body is read,
  with the stored key or, on creation, `X-BW-Pub`), body limits, the per-wallet async lock (`_locked`), every endpoint.
  `createToken` (403 `createToken` on a creating `PUT d` without `X-BW-Create-Token`; open when null, startup log says so), `trustProxy`
  (client address = last `X-Forwarded-For` hop). HEAD = GET without a body (signed as `HEAD`). A file the meta lists but the disk lacks = 404
  `missing` (kind `…!missing`), never 500. Pipeline order is protected: limit → OPTIONS → path/validate → signature headers (`_signature`) → create
  token (in `_putData`, first of the unknown-wallet header checks, before the 422/507 refusals) → body caps → verify → per-wallet lock.
  Every answer carries `Date` (relay clock, exposed to CORS). Body bytes buffered per client address (`_held`, released when the
  request is answered) are capped by `maxInFlightBytes` (32 MiB → 429 when other requests of that address hold bytes;
  test hook `onHold`); an unknown wallet's `PUT d` with seq ≠ 1 or on a full relay is refused before buffering. `now` drives lastSeen, the 90-day rule and the rate limit.
- `lib/src/signing.dart` — `signedText` (`bw-relay-v3`: method, host, path, covers, body hash, time; the host is
  `Relay(publicHost:)` when set, else the request's `Host`, lower case), `sha256OfBytes`, `decodeBase64Url` (exact
  length, no padding), `verifySignature` (Ed25519, never throws), `signatureWindow`.
- `lib/src/wallet.dart` — `apiVersion` (3), `Wallet` (public key `pub`, `instance` (32 random hex per wallet, kept in
  `meta.json`, made and saved at the first load of a meta without one; state JSON `instance`), devices, snapshots, byte
  total), `meta.json` save/load (atomic temp + rename; load deletes `.tmp-*` files of an interrupted meta save), `prune`,
  name patterns, `writeAtomic`, `writeData` (sync file + `RelayTestHooks.afterFileWrite(wid, device, seq)`),
  `RelayTestHooks` (`Relay(hooks:)`, tests only: `afterFileWrite`, `beforeMetaSave(wid)` before a request's meta save;
  a throw = a crash or full disk there). `lib/src/rate_limit.dart` — token bucket (20/s, burst 100) per client address.

## Rules
- Storage: `<wid>/meta.json` (`v` 2, the public key `pub` stored by the creating request (trust on first use; nothing
  in it can sign), per device `last`/`lastSeen`/`acks`, kept snapshots; a meta without a valid `pub`, e.g. v1's token
  hash, is not a wallet), `<wid>/d/<device>/<seq>`,
  `<wid>/snap/<id>`, `<wid>/blobs/<sha256 hex>` (bill photos/PDFs, `PUT/GET/DELETE …/blob/<hash>`: content-addressed, hash of
  the body checked, 16 MiB, never pruned, no lastSeen change; counted in `Wallet.blobCount/blobBytes`, rebuilt from the folder on
  load; `--max-bytes` = `Wallet.totalBytes` = files + kept snapshots + blobs, checked by PUT d, snapshot PUT and blob PUT; state JSON `blobs`). `first` is not stored: it is the lowest seq on disk, or `last + 1` when all were pruned. `last` = max of
  meta and disk, so a crash between a file and the meta loses nothing. Load deletes temp files and snapshot files the meta does
  not name; a folder without a readable meta is not a wallet (a new first PUT replaces it).
- Every wallet operation runs inside `_locked(wid, ...)`; wallet creation reserves its slot in `_wallets` before any await so
  concurrent creations cannot pass `--max-wallets`.
- Replays inside the signature window must stay harmless: every mutating endpoint is idempotent or monotonic (PUT d
  never overwrites, acks only grow, a snapshot must dominate). Keep it so for any new endpoint, and sign anything new a
  request carries (a new header goes into the signed text in RELAY_PROTOCOL.md first).
- Prune after every accepted PUT d / ack / snapshot (`Wallet.prune`). Files are deleted in ascending seq, so the pruned set is
  always a prefix.
- Resolutions where the protocol was silent are listed in the R2 report; the ones that matter: snapshot checks order 422 before
  409; same snapshot id again = 200 (same bytes + covers) or 409; `lastSeen` also refreshes on 200/409/410/422 of a known
  device; snapshot 507 counts only the kept snapshots, not the files they will prune.

## Test
`tools/build.sh shell -c 'cd relay && dart pub get && dart analyze --fatal-infos && dart test'` (a `relay` step in `build.sh`
comes with R7). Tests run over real HTTP on port 0 (`test/support.dart` `Harness`: temp folder, injectable clock, captured log
sink, `restart()` over the same folder; requests are signed with the synthetic `keyA`/`keyB` (`TestKey`, written from the
protocol text, not from `signing.dart`), `key: null` = unsigned, `skew` shifts `X-BW-Time`, `sign()` returns the headers
and `replay()` sends captured headers again). Signatures, replays, the clock window, TOFU: `test/signing_test.dart`. Blobs: `test/blob_test.dart`. `test/bin_test.dart` starts `bin/relay.dart` as a process (slow: ~3 s per start).
