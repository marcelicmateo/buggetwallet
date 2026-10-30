# relay — notes for Claude

Pure Dart server (`dart:io` + `cryptography` for SHA-256 and Ed25519 verification). Stores sealed sync files it cannot read. **The wire protocol is
`docs/context/RELAY_PROTOCOL.md`: change it there first**, the client (`RelayTransport` in `wallet_sync`, `packages/sync`) follows the same file.
Never put a signature, public key, body, full id or client address in a log line, a test fixture or a comment.

## Files
- `bin/relay.dart` — flags `--host --port --data --origin (repeatable) --max-wallets --max-bytes --create-token <file> --trust-proxy
  --public-host <name> --health-check` (hand-parsed, no `args`; `--trust-proxy` and `--health-check` are switches), env `BW_RELAY_HOST/PORT/DATA/ORIGINS/MAX_WALLETS/MAX_BYTES/
  CREATE_TOKEN(_FILE)/TRUST_PROXY/PUBLIC_HOST (or DOMAIN)` (flags win); usage error = exit 64; SIGINT/SIGTERM = graceful stop. `--health-check` GETs `/v2/health`
  on 127.0.0.1:port and exits 0/1 (the image's HEALTHCHECK; no `--data` needed). `relay/deploy/` = quadlets, Caddyfile, env templates (docs/setup.md §5).
- `lib/relay.dart` — barrel. `lib/src/relay_server.dart` — `Relay({data, origins, maxWallets, maxBytes, maxInFlightBytes, maxTotalInFlightBytes,
  maxOpenPerClient, maxOpen, maxDevices, minFileCost, bodyTimeout, refusalTimeout, minBodyRate, idleTimeout, now, log})` (HP-R1 defaults: 192 MiB,
  16, 512, 256, 4096, 30 s, 5 s, 8 KiB/s, 60 s; `default*` constants):
  `serve({host, port})` (port 0 for tests), `close()`, `handle(HttpRequest)`, `walletCount`. Routing, signature checks
  (`_signature`: headers (+ `X-BW-Dev`/`X-BW-WSig`, api 5) + ±5 min clock window, before any wallet lookup or body read; `_verify` after the body is read (with `X-BW-Dev` the v5 text by that device key; else v4, else v3 = `_Sig.version` 3: state then says api 3),
  with the stored key or, on creation, `X-BW-Pub`; `_verifyWallet` = `X-BW-WSig`; `_admit` (revoked / unenrolled / locked, before and inside the lock: `_lockedAs`)), body limits, the per-wallet async lock (`_locked`), every endpoint.
  `createToken` (403 `createToken` on a creating `PUT d` without `X-BW-Create-Token`; open when null, startup log says so), `trustProxy`
  (client address = last `X-Forwarded-For` hop). HEAD = GET without a body (signed as `HEAD`). A file the meta lists but the disk lacks = 404
  `missing` (kind `…!missing`), never 500. Pipeline order is protected: open-request cap (in `handle`) → rate limit → OPTIONS → path/validate → signature headers (`_signature`) → create
  token (in `_putData`, first of the unknown-wallet header checks, before the 422/507 refusals) → body caps → verify → per-wallet lock.
  Every answer carries `Date` (relay clock, exposed to CORS). Body bytes buffered per client address (`_held`, released when the
  request is answered) are capped by `maxInFlightBytes` (32 MiB → 429 when other requests of that address hold bytes;
  test hook `onHold`) and all together by `maxTotalInFlightBytes`; a declared `Content-Length` is held in full from the start and read into
  one buffer of that size (allocated at the first chunk, no copy at the end); an unknown wallet's `PUT d` with seq ≠ 1 or on a full relay is refused before buffering. `now` drives lastSeen, the 90-day rule and the rate limit.
  **Slow clients (HP-R1):** `handle` counts open requests per client address (`_enter`/`_leave`, `maxOpenPerClient`, relay-wide `maxOpen`; one more = 429
  `too many open requests` + close before any body read; `/v2/health` not counted; test hook `onOpen(open)` on every count change). Every body read
  goes through `_consume` (real-time deadline: `bodyTimeout` + 1 s per `minBodyRate` bytes kept; drained bytes add nothing): a passed deadline
  or an early stop cancels the body stream, which makes dart:io drop the connection unanswered (log `…!slow 429`); `_refuseBody` (and a body refused from the start) drains at most
  `refusalTimeout` (5 s). `_send` sets `HttpResponse.deadline` (same formula on the answer length) and guards the write with a timeout. `serve` sets
  `HttpServer.idleTimeout` (also cuts connections stuck in their headers) and `onError` on the server stream (`relay accept-error`). Stored files
  are answered by `_stored` → `_Out.file` (a `RandomAccessFile` opened inside the wallet lock, streamed in 64 KiB chunks by `_send`, closed there);
  replays compare with `_sameStored` (length first, then chunks). Client address = `clientKey` (`rate_limit.dart`: IPv4 as is, IPv4-mapped IPv6 → IPv4,
  IPv6 → its /64). New device names past `maxDevices` = 507 `too many devices` (PUT d, ack) unless `Wallet.forgetIdleDevices` frees a slot (streams with no file,
  unseen 90 days; a snapshot need not dominate a stream the relay no longer lists).
- `lib/src/signing.dart` — `signedTextV5` (api 5, ends with `devpub`), `fingerprint` (`ABCD-EFGH`, `fingerprintPattern`), `signedText` (`bw-relay-v4`, `v3: true` = the api-3 text it still accepts: method, host, path, covers, body hash, time; the host is
  `Relay(publicHost:)` when set, else the request's `Host`, lower case), `sha256OfBytes`, `decodeBase64Url` (exact
  length, no padding), `verifySignature` (Ed25519, never throws), `signatureWindow`.
- `lib/src/wallet.dart` — `apiVersion` (5), `DeviceKey`/`PendingKey`, `Wallet.keys`/`pending`/`locked`/`lockTime`/`othersTime`/`fps` (meta v3; `maxPending` 8, `pendingExpiry` 7 days, `maxActiveKeys` 16 → 409 `tooManyKeys`, `fps` = free fingerprint reservations of expired requests (`reserveFree` from `dropExpired`; newest `maxReserved` 256, oldest free dropped first; held fingerprints are their key's), `_revokeOthers` skips keys and requests newer than its signed time, `lockAfterRevoke` (lockTime ≥ now + 5 min); an api-5 creation starts locked; a v2 meta = none, unlocked; a present but unparsable `revoked` = revoked), device endpoints `_enrol`/`_putDevice`/`_revokeOthers` (`devices/others`)/`_putLock` are in relay_server.dart, not here (RELAY_PROTOCOL.md "Device keys"; log `relay keys enrolled= pending=`), `gcGrace` (30 days), `maxDeclaredBlobs`, `parseBlobSet`/`encodeBlobSet`, `Wallet` (public key `pub`, `instance` (32 random hex per wallet, kept in
  `meta.json`, made and saved at the first load of a meta without one; state JSON `instance`), devices, snapshots, byte
  total), `meta.json` save/load (atomic temp + rename; load deletes `.tmp-*` files of an interrupted meta save), `prune`,
  name patterns, `writeAtomic` (flushes the file, not the folder: dart:io cannot open a folder to fsync it; the data disk is mounted `dirsync`,
  relay/deploy/native/README.md), `Wallet.storedSize` (≥ `minFileCost`, default 4096: what a file counts toward `--max-bytes`, used for `bytes`/`blobBytes`
  everywhere, also on load and prune; tests of exact byte sums use `freshHarness(minFileCost: 1)`), `defaultMaxDevices`, `writeData` (sync file + `RelayTestHooks.afterFileWrite(wid, device, seq)`),
  `RelayTestHooks` (`Relay(hooks:)`, tests only: `afterFileWrite`, `beforeMetaSave(wid)` before a request's meta save;
  a throw = a crash or full disk there). `lib/src/rate_limit.dart` — token bucket (20/s, burst 100) per client address.

## Rules
- Storage: `<wid>/meta.json` (`v` 3 since api 5 (`keys`, `pending`, `locked`, `lockTime`), the public key `pub` stored by the creating request (trust on first use; nothing
  in it can sign), per device `last`/`lastSeen`/`acks`, kept snapshots; a meta without a valid `pub`, e.g. v1's token
  hash, is not a wallet), `<wid>/d/<device>/<seq>`,
  `<wid>/snap/<id>`, `<wid>/blobs/<sha256 hex>` (bill photos/PDFs, `PUT/GET/DELETE …/blob/<hash>` (DELETE = 204 no-op since api 4): content-addressed, hash of
  the body checked, 16 MiB, stored time = mtime set to `now` by every accepted PUT (200 too), never pruned, only collected by
  `Wallet.collectBlobs` (after a new declared set `PUT snapshot/<id>/blobs` → `<wid>/sets/<id>` = `Snap.blobSet`, loaded on
  start, deleted with its snapshot; GC only when both kept snapshots have a set and the latest covers every device’s
  `last`, never a declared or < 30-day-old blob; a stored time that cannot be set = the file rewritten, else 500, hook `touchBlob`;
  log `relay gc kept= deleted= bytes=`), no lastSeen change; counted in `Wallet.blobCount/blobBytes`, rebuilt from the folder on
  load; `--max-bytes` = `Wallet.totalBytes` = files + kept snapshots + blobs, checked by PUT d, snapshot PUT and blob PUT; state JSON `blobs`, and `bytes` (= `totalBytes`) + `maxBytes` (Stage I:
  `Wallet.stateJson(maxBytes:)`, passed by `relay_server.dart`; additive)). `first` is not stored: it is the lowest seq on disk, or `last + 1` when the device has no file left (a missing file above the lowest stays listed: 404 `missing`; `DeviceState.lost` + `Wallet.skipLost`: a lost file the latest snapshot covers answers 410 and, at `first`, is skipped like a pruned one, HP-R1b). `last` = max of
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
and `replay()` sends captured headers again). Signatures, replays, the clock window, TOFU: `test/signing_test.dart`; the api-5 spec cases: `test/dk_spec_test.dart`. Device keys (api 5: enrol, approve, revoke, lock, replays, pending cap/expiry, meta v2 → v3, restart, fuzz): `test/device_keys_test.dart` (`TestKey.headersV5`/`fp`, `Harness.sendV5`/`signV5`, `devA..devC`). Blobs: `test/blob_test.dart`; declared sets + GC + v3 compatibility: `test/blob_gc_test.dart`. `test/bin_test.dart` starts `bin/relay.dart` as a process (slow: ~3 s per start). HP-R1 (slow bodies over raw sockets, open caps,
idle headers, streamed answers, in-flight budgets, device cap, minimum file cost, IPv6 /64, `first` after a restart): `test/hp_r1_test.dart`
(`Raw` = a raw HTTP connection; waits on `onOpen`/`onHold` and socket events, never on sleeps; `Harness.start` takes every limit above).
