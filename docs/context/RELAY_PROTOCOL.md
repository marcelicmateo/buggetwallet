# Relay protocol v2 (sync redesign, DESIGN_DECISIONS §4.9; signed requests, decision 2026-10-22)

The relay stores sealed files it cannot read. Server: `relay/`. Client: `RelayTransport` in `wallet_core`.
Both sides follow this file exactly; change it here first. v2 replaces v1 (bearer token; never deployed): paths are
`/v2/…` and the state says `"api": 2`.

## Identity (client side only)
- `wid` = lowercase hex of HKDF-SHA256(ikm = wallet key bytes, salt = empty, info = `bw-relay-id-v1`, length 16) → 32 hex chars.
- Signing key: Ed25519 key pair from the 32-byte seed HKDF-SHA256(same ikm, info = `bw-relay-sign-v1`, length 32).
  `pub` = base64url without padding of the 32-byte public key (43 chars). There is no bearer token any more.

## Signed requests
Every request under `/v2/w/<wid>/` (GETs too: the state is metadata) carries:
- `X-BW-Time`: the client's time in Unix milliseconds, decimal, no sign, at most 16 digits (≤ 2^53 − 1).
- `X-BW-Sig`: base64url without padding (86 chars) of the Ed25519 signature over the UTF-8 string

  ```
  bw-relay-v2\n<METHOD>\n<path>\n<covers>\n<body hash>\n<time>
  ```
  `<METHOD>` = `GET` or `PUT`; `<path>` = the request path from `/v2/` on (`/v2/w/<wid>/d/<device>/<seq>`), without query
  and without any prefix in the relay address the client was given; `<covers>` = the `X-BW-Covers` header value as sent,
  or empty when the request has none; `<body hash>` = lowercase hex SHA-256 of the body bytes (a GET or an empty body
  hashes the empty string: `e3b0c442…b855`); `<time>` = the `X-BW-Time` value as sent. `\n` is one LF; no trailing LF.
- The request that creates a wallet (the first accepted `PUT d/<device>/1`) also carries `X-BW-Pub: <pub>`. The relay
  verifies that request's signature with it and stores `pub` in `meta.json` (trust on first use). Later requests are
  verified with the stored key; their `X-BW-Pub` is ignored. Clients send `X-BW-Pub` on every `PUT d/<device>/1`.

Checks, in this order (all before the wallet lock):
1. Route, names and method (400 / 404 / 405, below).
2. `X-BW-Time` or `X-BW-Sig` missing → 401 `unsigned`; present but malformed (or sent twice) → 400.
3. `|X-BW-Time − relay clock| > 5 min` → 401 `{"error":"clock"}`. Every relay answer has a `Date` header (relay clock).
4. Unknown wallet: GETs, acks and snapshot PUTs → 404. A `PUT d` with seq ≠ 1 → 422 and a relay already at
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
| `GET /v2/health` (not signed) | 200 `{"api":2}` |
| `GET /v2/w/<wid>/state` | 200 state JSON (below) |
| `PUT /v2/w/<wid>/d/<device>/<seq>` body = sealed bytes (≤ 16 MiB) | 201 stored; 200 same bytes already stored; 409 other bytes already stored for that seq (never overwritten); 422 `seq > last + 1` (no gaps on the relay); 410 `seq < first` (pruned); 413 too big |
| `GET /v2/w/<wid>/d/<device>/<seq>` | 200 bytes; 410 pruned (`seq < first`); 404 never stored |
| `PUT /v2/w/<wid>/ack/<device>` body `{"<peer>": seq, …}` | 204. Each ack only ever grows (max with the stored one); an ack above the peer's `last` → 422 |
| `PUT /v2/w/<wid>/snapshot/<id>` header `X-BW-Covers: {"<device>": seq, …}`, body = sealed bytes (≤ 64 MiB) | 201 when `covers` ≥ the current snapshot's covers for every device in it (a device missing from `covers` counts as 0), and ≤ each device's `last`; checked in that order: 422 beyond `last` (unknown device = `last` 0), then 409 does not dominate; same id with the same bytes and covers again = 200, same id with other content = 409; missing/invalid `X-BW-Covers` = 400 |
| `GET /v2/w/<wid>/snapshot/<id>` | 200 bytes; 404 |
| any `OPTIONS` | CORS preflight, 204 |

`lastSeen` of a known device is set to now by any signed `PUT d/<device>/...` that reaches the seq check (200, 201, 409,
410, 422) and by every accepted ack; snapshot PUTs and refused acks do not. A new device appears only on a 201 or an
accepted ack. Clients ack on every sync run (even unchanged), which keeps `lastSeen` fresh. The `PUT d` that creates a
wallet must have seq 1 (otherwise 422 and nothing is created). Acks: values ≥ 0 (`0` allowed), non-int/negative/bad
names → 400, body over 64 KiB → 413. Unknown path → 404, wrong method on a known path → 405.

## State JSON
```json
{
  "api": 2,
  "devices": {
    "<device>": {"first": 1, "last": 12, "lastSeen": "2026-10-22T10:00:00Z", "acks": {"<peer>": 5}}
  },
  "snapshot": {"id": "<id>", "covers": {"<device>": 12}},
  "previous": {"id": "<id>", "covers": {"<device>": 7}}
}
```
`first` = lowest seq still stored, or `last + 1` when all were pruned. `snapshot`/`previous` are `null` when absent. A
device appears once it has stored a file or sent an ack. A client refuses `api` above its own (`newerApi`: update the
app) and below it (`olderApi`: update the relay); its health check also asks `/v1/health` when `/v2/health` is 404, to
tell an old relay apart.

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
  `http://127.0.0.1:8080`, `http://localhost:8080`); allowed methods `GET, PUT, OPTIONS`; allowed headers
  `Content-Type, X-BW-Covers, X-BW-Time, X-BW-Sig, X-BW-Pub`; exposed header `Date` (the client's clock offset).

## Logs
Request kind, status, byte sizes, first 6 hex of `wid` and first 6 chars of `device`. Never signatures, public keys,
bodies, full ids or client addresses.

## Threat model
Assumes the wallet key stays on the devices (only `wid`, `pub` and signatures derived from it ever leave them).
- **Network sniffer** (plain `http://` on the LAN): sees `wid`, device ids, seqs, sizes, times and the sealed bytes
  (unreadable without the key). Cannot change the relay: a captured signature is bound to its method, path, covers,
  body and time, so it cannot ack, snapshot, store or prune anything else, and a replay inside the 5 minutes repeats an
  idempotent request. The window stays 5 minutes because a client never takes a clock offset above 24 h from a `Date`
  (a faked `Date` of, say, +30 days is refused), so it never signs a request far ahead to be replayed later.
  Can still read metadata and, if the relay is ever wiped, squat the `wid` with its own key first
  (devices then get 401 `refused`: a denial of service, not a read). The VPN hides all of this.
- **Denial of service** (anyone who can reach the port): the relay must read a body before it can verify the signature
  (the hash covers it), so an unsigned or badly signed request still costs a read. That cost is bounded by the size
  limits, the per-address in-flight cap and the rate limit (413 / 429); the VPN keeps strangers away.
- **Stolen relay disk**: sealed files plus `meta.json` (public key, seqs, acks, times). Nothing in it can sign or decrypt.
- **Malicious relay** (or someone controlling it): can drop, withhold, roll back or delete files and snapshots, lie in
  the state, refuse requests or replay its stored bytes to clients; it cannot read, forge or alter sealed content
  (devices reject what does not unseal with the wallet key) and cannot sign requests to another relay.
