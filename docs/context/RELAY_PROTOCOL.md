# Relay protocol, api 3 (sync redesign, DESIGN_DECISIONS §4.9; signed requests, decision 2026-10-22; Stage H)

The relay stores sealed files it cannot read. Server: `relay/`. Client: `RelayTransport` in `wallet_core`.
Both sides follow this file exactly; change it here first. Paths are `/v2/…`; health and state say `"api": 3`.

## Versions
| api | Change | Mixed versions |
|---|---|---|
| 1 | Bearer token (never deployed). | Paths `/v1/…`: a v2+ client's health check tells it apart (`olderApi`). |
| 2 | Ed25519-signed requests (`bw-relay-v2`), blobs. | — |
| 3 (Stage H, 2026-10-23) | The signed text names the host (`bw-relay-v3`, H8); state carries the relay `instance` id (H5); per-device streams `<device>-<n><tag>` (H5b); optional `--create-token` (H11); a missing file of a known device is 404 `missing`. | An api-2 app on an api-3 relay: its `GET state` (v2 signature, which the relay still checks for this one request) is answered with only `{"api":3}`, so it stops with `newerApi` ("The relay runs a newer version. Update the app."); a new wallet created by an api-2 app on an api-3 relay is refused (401, shown as "refused"). An api-3 app on an api-2 relay: the relay answers 401 to its v3 signature; on any 401 that is not `clock` the client asks `/v2/health` once and stops with `olderApi` ("Update the relay") for api 2, `newerApi` above 3, and keeps `refused` only for api 3. Nothing is uploaded or read either way, so no device diverges: each syncs again once both sides run Stage H. Otherwise a v3 relay accepts only v3 signatures. |

## Identity (client side only)
- `wid` = lowercase hex of HKDF-SHA256(ikm = wallet key bytes, salt = empty, info = `bw-relay-id-v1`, length 16) → 32 hex chars.
- Signing key: Ed25519 key pair from the 32-byte seed HKDF-SHA256(same ikm, info = `bw-relay-sign-v1`, length 32).
  `pub` = base64url without padding of the 32-byte public key (43 chars). There is no bearer token any more.

## Signed requests
Every request under `/v2/w/<wid>/` (GETs too: the state is metadata) carries:
- `X-BW-Time`: the client's time in Unix milliseconds, decimal, no sign, at most 16 digits (≤ 2^53 − 1).
- `X-BW-Sig`: base64url without padding (86 chars) of the Ed25519 signature over the UTF-8 string

  ```
  bw-relay-v3\n<METHOD>\n<host>\n<path>\n<covers>\n<body hash>\n<time>
  ```
  `<METHOD>` = `GET`, `HEAD`, `PUT` or `DELETE` (blobs only); `<host>` = the host the client addressed as its `Host` header
  carries it: lower case, `:<port>` only when the port is not the scheme's default (80/443), an IPv6 address in
  brackets (`relay.example.org`, `192.168.1.5:8787`). The relay compares it with its `--public-host` when set (behind a
  proxy such as Caddy, whose `Host` may differ), else with the request's `Host` header, lower case; a request signed for
  another relay address fails as `bad signature` (401), so a request captured at one relay does not replay at another
  that holds the same wallet. `<path>` = the request path from `/v2/` on (`/v2/w/<wid>/d/<device>/<seq>`), without query
  and without any prefix in the relay address the client was given; `<covers>` = the `X-BW-Covers` header value as sent,
  or empty when the request has none; `<body hash>` = lowercase hex SHA-256 of the body bytes (a GET or an empty body
  hashes the empty string: `e3b0c442…b855`); `<time>` = the `X-BW-Time` value as sent. `\n` is one LF; no trailing LF.
- The request that creates a wallet (the first accepted `PUT d/<device>/1`) also carries `X-BW-Pub: <pub>`. The relay
  verifies that request's signature with it and stores `pub` in `meta.json` (trust on first use). Later requests are
  verified with the stored key; their `X-BW-Pub` is ignored. Clients send `X-BW-Pub` on every `PUT d/<device>/1`.
- Create token (H11): a relay started with `--create-token` creates a wallet only when that `PUT d/<device>/1` carries
  `X-BW-Create-Token: <token>` (constant-time compare); missing or wrong → 403 `{"error":"createToken"}`, nothing created.
  Existing wallets never need it. Clients with a token configured send it on every `PUT d/<device>/1`; it is not part
  of the signed text. The client maps the 403 to `createToken` (fatal for the run; "The relay needs its create token…").

- **Creation token (Stage H, H11).** A relay started with `--create-token <file>` (or `BW_RELAY_CREATE_TOKEN(_FILE)`) lets only
  a request that would create a wallet through when it carries `X-BW-Create-Token: <token>` (the shared secret, sent as is; the
  relay compares in constant time). Missing or wrong: **403** `{"error":"createToken"}`, nothing is created. The header is
  not part of the signed text (it is a shared secret, not a request property) and is ignored for existing wallets. **Client
  contract:** send it on every `PUT d/<device>/1` when the user has entered a token (clients may send it on all seq-1 PUTs; a
  relay without the flag ignores it); a 403 `createToken` is fatal for the run ("this relay needs a create token") and must
  not be retried or logged with the token. Without the flag the relay is in development mode (creation open) and says so at
  startup. CORS allows the header name.

Checks, in this order (all before the wallet lock):
1. Route, names and method (400 / 404 / 405, below).
2. `X-BW-Time` or `X-BW-Sig` missing → 401 `unsigned`; present but malformed (or sent twice) → 400.
3. `|X-BW-Time − relay clock| > 5 min` → 401 `{"error":"clock"}`. Every relay answer has a `Date` header (relay clock).
4. Unknown wallet: GETs, acks and snapshot PUTs → 404. A `PUT d` first needs the creation token when the relay requires one
   (403 `createToken`, header check, before the 422 / 507 below so a client without the token learns nothing about
   capacity); then seq ≠ 1 → 422 and a relay already at
   `--max-wallets` → 507, both before the body is buffered (it is read and discarded, up to 2× the file limit); then
   `X-BW-Pub` missing → 401, malformed (not 43 base64url chars) → 400.
5. The body is read within the size limits and the in-flight cap (413 / 429), then hashed.
6. Signature checked with the stored key (known wallet) or `X-BW-Pub` (creation): wrong → 401 `bad signature`.
   A creation that loses a race to another creation is checked again inside the lock against the stored key (401).

Client clock: the client keeps a device-local offset (ms, in memory) added to its clock for `X-BW-Time`. On 401
`clock` it sets the offset from the answer's `Date` header and retries that request once, freshly signed; a second
`clock` (or no `Date`) fails the call. The offset is accepted only if |offset| <= 24 h; a `Date` further away (a faked
one over plain HTTP) is not used: no retry, the offset stays as it was, and the call fails as `clockSkew` ("This
device's clock and the relay's clock differ by more than a day. Check the date and time settings."). So a request
is never signed more than 24 h from the device's own clock.

Replays inside the window repeat a request exactly (same method, path, covers, body), so every mutating endpoint is
idempotent or monotonic: `PUT d` with the same bytes → 200, other bytes → 409 (never overwritten); acks only grow
(max with the stored one); a snapshot with the same id and content → 200, a replayed older snapshot either still
dominates (same covers: same genuine content, nothing more pruned) or is refused (409). A replay can refresh a device's
`lastSeen` for at most the window, which only holds back pruning.

## Names
- `wid`: `[0-9a-f]{32}`. `device`: `[A-Za-z0-9_-]{1,64}`. `seq`: decimal, no leading zeros, 1 … 2^53−1.
  Snapshot `id`: `[A-Za-z0-9_-]{1,64}`. Anything else → 400.
- Errors are JSON `{"error": "<short text>"}`. Success bodies are JSON or `application/octet-stream`.

## Endpoints
| Request | Result |
|---|---|
| `GET /v2/health` (not signed) | 200 `{"api":3}` |
| `GET /v2/w/<wid>/state` | 200 state JSON (below) |
| `PUT /v2/w/<wid>/d/<device>/<seq>` body = sealed bytes (≤ 16 MiB) | 201 stored; 200 same bytes already stored; 409 other bytes already stored for that seq (never overwritten); 422 `seq > last + 1` (no gaps on the relay); 410 `seq < first` (pruned); 413 too big |
| `GET /v2/w/<wid>/d/<device>/<seq>` | 200 bytes; 410 pruned (`seq < first`); 404 never stored; 404 `{"error":"missing"}` when the relay's own state says the file exists but it is gone from disk (damaged or restored data folder; never 500) |
| `PUT /v2/w/<wid>/ack/<device>` body `{"<peer>": seq, …}` | 204. Each ack only ever grows (max with the stored one); an ack above the peer's `last` → 422 |
| `PUT /v2/w/<wid>/snapshot/<id>` header `X-BW-Covers: {"<device>": seq, …}`, body = sealed bytes (≤ 64 MiB) | 201 when `covers` ≥ the current snapshot's covers for every device in it (a device missing from `covers` counts as 0), and ≤ each device's `last`; checked in that order: 422 beyond `last` (unknown device = `last` 0), then 409 does not dominate; same id with the same bytes and covers again = 200, same id with other content = 409; missing/invalid `X-BW-Covers` = 400 |
| `GET /v2/w/<wid>/snapshot/<id>` | 200 bytes; 404 (also `{"error":"missing"}` when a kept snapshot's file is gone from disk) |
| `HEAD` on `/v2/health` and on every `GET` endpoint | Same status and headers (including `Content-Length`) as the `GET`, no body. On wallet paths it is signed with `<METHOD>` = `HEAD` (a GET signature does not authorize a HEAD and the other way round) |
| any `OPTIONS` | CORS preflight, 204 |

`lastSeen` of a known device is set to now by any signed `PUT d/<device>/...` that reaches the seq check (200, 201, 409,
410, 422) and by every accepted ack; snapshot PUTs and refused acks do not. A new device appears only on a 201 or an
accepted ack. Clients ack on every sync run (even unchanged), which keeps `lastSeen` fresh. The `PUT d` that creates a
wallet must have seq 1 (otherwise 422 and nothing is created). Acks: values ≥ 0 (`0` allowed), non-int/negative/bad
names → 400, body over 64 KiB → 413. Unknown path → 404, wrong method on a known path → 405.

## Blobs (bill photos and PDFs, Stage B, 2026-10-22)
Sealed files that rows point to by hash (a bill's photo or PDF). Content-addressed, never pruned by the snapshot rules.
| Request | Result |
|---|---|
| `PUT /v2/w/<wid>/blob/<hash>` body = sealed bytes (≤ 16 MiB) | `<hash>` = lowercase hex SHA-256 of the body (64 chars, else 400); body hash ≠ `<hash>` → 400 `hash`; 201 stored; 200 already stored (same hash = same bytes); 404 unknown wallet (a wallet is created only by `PUT d/<device>/1`); 413 too big; 507 wallet over `--max-bytes` (blobs count) |
| `GET /v2/w/<wid>/blob/<hash>` | 200 bytes; 404 never stored or deleted (`{"error":"missing"}`) |
| `DELETE /v2/w/<wid>/blob/<hash>` (empty body) | 204, also when absent (idempotent) |

- Signed like every wallet request; `<METHOD>` in the signed text may now also be `DELETE`. CORS allowed methods become
  `GET, PUT, DELETE, OPTIONS`. A blob PUT/DELETE does not change `lastSeen`.
- Storage: `blobs/<hash>` in the wallet's folder (temp + rename). The wallet's byte count (`--max-bytes`) = files + kept
  snapshots + blobs; a blob PUT counts everything + the new blob.
- State JSON gains `"blobs": {"count": n, "bytes": b}` (clients ignore it; older clients ignore unknown keys).
- A replayed DELETE inside the 5-minute window deletes a blob that the owner re-uploaded with the very same sealed bytes
  in those minutes; clients never re-upload a deleted blob's bytes (a new photo is sealed again with a fresh nonce),
  so this cannot happen in practice. `api` stays 2: older relays answer 404 on `blob/…`, which clients report as
  "this relay can't keep bill photos yet" and keep the blob queued.

## State JSON
```json
{
  "api": 3,
  "instance": "<32 hex>",
  "devices": {
    "<device>": {"first": 1, "last": 12, "lastSeen": "2026-10-22T10:00:00Z", "acks": {"<peer>": 5}}
  },
  "snapshot": {"id": "<id>", "covers": {"<device>": 12}},
  "previous": {"id": "<id>", "covers": {"<device>": 7}}
}
```
`first` = lowest seq still stored, or `last + 1` when all were pruned. `snapshot`/`previous` are `null` when absent. A
device appears once it has stored a file or sent an ack.

`instance` (H5): random 32 hex characters per wallet, created with the wallet (or, for a wallet stored by an older
relay, at its first load, and saved at once) and kept in its `meta.json`. A wiped data folder or another relay names
another id. The client stores the id of the last run whose upload went through (device-local `syncInstance`); another
id from the relay = `relayChanged`: every cursor goes back to 0 and the run is a first connect (the whole state is
uploaded again, appended after this device's `last` there). No stored id yet (first sync, or the first sync after the
upgrade) = adopted without a first connect; a relay without `instance` (api 2) leaves the stored id as it is. The app
shows `relayFingerprint` (first 8 hex as `xxxx-xxxx`). A run whose upload created the wallet (state had no devices) asks
`state` once more, so it learns (and reports) the new instance in that run. A restored copy of the same data folder keeps its `instance`:
that case is caught by the stream rules below.

### Device streams and ownership (H5b, HBb)
A device writes its files under a relay device name, its **stream**: its device id for epoch 0 (every file written
before Stage H), else `<device id>-<n><tag>` with `n` the epoch (decimal) and `tag` six random lower-case letters
(device ids are letters and digits only, at most 48, so the name parses back and stays within 64 characters; the tag
keeps two installs, or one install after a double restore, from ever picking the same name). The current stream is
device-local (`syncStream`). Ownership rules (client side; the relay knows nothing of them):
1. Never stop syncing for a state the owner cannot fix.
2. Never write into a stream another install may be writing.
3. Read every stream not being written now as a peer, streams of this device id included (older or newer epochs, a
   clone's, the id used before an H6 id change), and ack it.
4. Ack under every stream this install has written (`syncStreams`, the old id's included), with its cursors plus its
   current stream's `last`, so nothing it wrote holds back pruning; never under one another install may be writing.

A device takes a fresh stream (epoch above every stream of its id it knows) and uploads its whole state there, from
seq 1, when the current one is not exclusively its own:
- the relay holds **fewer** of its files than it sent (`last` < `syncSent`: a restored older copy of the data folder,
  or a wiped relay): no seq is ever reused with other content; the old stream stays one it acks as;
- the relay holds **more** than it sent and the extra seqs are not its own cut-off upload (device-local
  `syncSending` records, before each PUT, the seq and a hash of the sealed part; an extra seq counts as its own only
  when the stored file hashes to it, fetched once to check): another install writes there (a copied database or key
  store, or this database restored from an older file copy); also on a fresh database whose id already has files. The
  old stream is read as a peer and no longer acked as;
- a 409 on its own next seq: the same, in the same run (once), with `syncSending` cleared.
The client reports `deviceIdInUse` once per such move (and once per newly seen stream of its id that it never wrote),
as information: the run goes on and is caught up; the next runs are normal. Clients show all streams of one device id
as one device. A cursor for a stream the relay no longer lists is dropped.

Two more guards:
- **Rolled-back relay.** A relay only ever raises acks. Each install keeps the acks it stored per stream it acks as
  (`syncAcked`); when the relay shows one lower, its data folder was restored from a copy (the instance stays the
  same), so seq numbers it hands out again may hold other content than the files read before. The run is then a first
  connect (`relayChanged`): every cursor back to 0, the stored acks cleared, the whole state uploaded (moving to a
  fresh stream when its own files went missing).
- **A left stream that grows.** For every stream it no longer writes but still acks as, an install keeps the relay
  `last` when it left it (`syncStreamLast`; on an H6 id change the old id's highest stored seq). Should that stream
  ever hold more, another install writes it (the original of a copied database): it is dropped from `syncStreams`,
  never acked as again, and reported once as `deviceIdInUse`.
Limits: abandoned streams stay until snapshots and acks cover them; a stream left to another install is no longer
acked by this one, so pruning of others' files waits for that install's acks or the 90-day rule (up to 90 days for an
orphaned one); after an H6 id change on a copied database, the copy acks as the old stream until the original's next
upload makes it grow (pruning in that window still needs a covering snapshot, so nothing is lost, the original then
starts from the snapshot); after a double restore (database and relay folder from the same moment), streams this
install made later are missing from its restored `syncStreams` and are reported once as `deviceIdInUse`; two installs
with one device id share its HLC node, so two of their writes in the same millisecond with the same counter compare
equal (the first one applied wins on each device).

## Snapshots and pruning
- The relay keeps the latest snapshot and the one before it (`previous`); an accepted snapshot moves the latest to
  `previous` and deletes the older one.
- File `seq` of device `D` is deleted when every kept snapshot (only those that exist) covers it (`covers[D] ≥ seq`) **and** every other device
  whose `lastSeen` is within 90 days has `acks[D] ≥ seq`. Checked after each accepted PUT and ack.
- A client whose next needed file is below `first` (pruned) starts from the latest snapshot (falling back to `previous`
  if the latest cannot be read), then fetches the files after its `covers`.

## Limits and CORS
- 413 body too big (the relay reads and discards up to 2× the limit first so the client sees the status); 429 more than 20 requests/s per client address (burst 100), or a body that would put the bytes one client address has
buffered across its concurrent requests over 32 MiB (`maxInFlightBytes`; a lone request is limited only by its own size
limit, so a 64 MiB snapshot still goes through); 507 relay full (wallet count over
  `--max-wallets`, default 16, or a wallet over `--max-bytes`, default 1 GiB: a `PUT d` counts files + kept snapshots, a
  snapshot PUT counts only the kept snapshots + the new one, so a nearly full wallet can still snapshot and prune).
- CORS: `Access-Control-Allow-Origin` echoes the request `Origin` only if it is in the configured list (default
  `http://127.0.0.1:8080`, `http://localhost:8080`); allowed methods `GET, PUT, DELETE, OPTIONS`; allowed headers
  `Content-Type, X-BW-Covers, X-BW-Time, X-BW-Sig, X-BW-Pub`; exposed header `Date` (the client's clock offset).

## Behind a reverse proxy (Stage H, D5)
The deployment is Caddy (HTTPS, Let's Encrypt) in front of the relay on a private network; only 443 (and 80 for the redirect and
the ACME challenge) is forwarded to the home server and the relay port is never exposed (`relay/deploy/`, docs/setup.md §5).
- `--trust-proxy` (`BW_RELAY_TRUST_PROXY=1`): the client address used for the rate limit and the in-flight byte cap is the **last**
  entry of `X-Forwarded-For` (the hop the proxy appended; earlier entries are client-supplied and ignored); a missing or
  invalid value falls back to the connection address. Without the flag the header is ignored. Addresses are still never logged.
  Only use it when the relay is reachable through that proxy alone.
- The proxy must pass `Host` and every `X-BW-*` header unchanged and must not buffer-limit below the relay's body limits
  (Caddyfile: `request_body max_size 64MiB`).
- `--public-host <name>` (`BW_RELAY_PUBLIC_HOST`, falling back to `BW_RELAY_DOMAIN`): the host the signed text must name instead of the
  request's `Host` (Stage H signed-text change; the deployment sets it from the one domain setting).
- `relay --health-check` (container HEALTHCHECK): requests `http://127.0.0.1:<port>/v2/health`, exit 0 on 200, else 1.

## Logs
Request kind, status, byte sizes, first 6 hex of `wid` and first 6 chars of `device`. Never signatures, public keys,
bodies, full ids or client addresses. The creation token never appears. A file missing on disk adds `!missing` to the kind
(`get-d!missing`).

## Threat model
Assumes the wallet key stays on the devices (only `wid`, `pub` and signatures derived from it ever leave them).
- **Network sniffer** (plain `http://` on the LAN): sees `wid`, device ids, seqs, sizes, times and the sealed bytes
  (unreadable without the key). Cannot change the relay: a captured signature is bound to its method, path, covers,
  body and time, so it cannot ack, snapshot, store or prune anything else, and a replay inside the 5 minutes repeats an
  idempotent request. The window stays 5 minutes because a client never takes a clock offset above 24 h from a `Date`
  (a faked `Date` of, say, +30 days is refused), so it never signs a request far ahead to be replayed later.
  Can still read metadata and, if the relay is ever wiped, squat the `wid` with its own key first
  (devices then get 401 `refused`: a denial of service, not a read). Over `https://` (the deployment) none of this is visible to a sniffer; the creation token also stops strangers from squatting a `wid` on a fresh relay.
- **Denial of service** (anyone who can reach the port): the relay must read a body before it can verify the signature
  (the hash covers it), so an unsigned or badly signed request still costs a read. That cost is bounded by the size
  limits, the per-address in-flight cap and the rate limit (413 / 429); the creation token (403) keeps strangers from creating wallets, and Caddy limits body size before the relay sees it.
- **Stolen relay disk**: sealed files plus `meta.json` (public key, seqs, acks, times). Nothing in it can sign or decrypt.
- **Malicious relay** (or someone controlling it): can drop, withhold, roll back or delete files and snapshots, lie in
  the state, refuse requests or replay its stored bytes to clients; it cannot read, forge or alter sealed content
  (devices reject what does not unseal with the wallet key) and cannot sign requests to another relay.
