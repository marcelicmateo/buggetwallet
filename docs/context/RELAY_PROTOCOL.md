# Relay protocol v1 (sync redesign, DESIGN_DECISIONS §4.9)

The relay stores sealed files it cannot read. Server: `relay/`. Client: `RelayTransport` in `wallet_core`.
Both sides follow this file exactly; change it here first.

## Identity (client side only)
- `wid` = lowercase hex of HKDF-SHA256(ikm = wallet key bytes, salt = empty, info = `bw-relay-id-v1`, length 16) → 32 hex chars.
- `token` = base64url without padding of HKDF-SHA256(same ikm, info = `bw-relay-auth-v1`, length 32) → 43 chars.
- Every request under `/v1/w/<wid>/` sends `Authorization: Bearer <token>`.
- The relay stores SHA-256(token) per wallet, set by the request that creates the wallet (the first `PUT d/...`), and
  compares in constant time. Known wallet + wrong or missing token → 401. Unknown wallet: `GET state` → 404
  (the client treats it as an empty relay), other GETs → 404, `PUT ack`/`PUT snapshot` → 404.

## Names
- `wid`: `[0-9a-f]{32}`. `device`: `[A-Za-z0-9_-]{1,64}`. `seq`: decimal, no leading zeros, 1 … 2^53−1.
  Snapshot `id`: `[A-Za-z0-9_-]{1,64}`. Anything else → 400.
- Errors are JSON `{"error": "<short text>"}`. Success bodies are JSON or `application/octet-stream`.

## Endpoints
| Request | Result |
|---|---|
| `GET /v1/health` (no auth) | 200 `{"api":1}` |
| `GET /v1/w/<wid>/state` | 200 state JSON (below) |
| `PUT /v1/w/<wid>/d/<device>/<seq>` body = sealed bytes (≤ 16 MiB) | 201 stored; 200 same bytes already stored; 409 other bytes already stored for that seq (never overwritten); 422 `seq > last + 1` (no gaps on the relay); 410 `seq < first` (pruned); 413 too big |
| `GET /v1/w/<wid>/d/<device>/<seq>` | 200 bytes; 410 pruned (`seq < first`); 404 never stored |
| `PUT /v1/w/<wid>/ack/<device>` body `{"<peer>": seq, …}` | 204. Each ack only ever grows (max with the stored one); an ack above the peer's `last` → 422 |
| `PUT /v1/w/<wid>/snapshot/<id>` header `X-BW-Covers: {"<device>": seq, …}`, body = sealed bytes (≤ 64 MiB) | 201 when `covers` ≥ the current snapshot's covers for every device in it, and ≤ each device's `last`; else 409 (does not dominate) / 422 (beyond `last`) |
| `GET /v1/w/<wid>/snapshot/<id>` | 200 bytes; 404 |
| any `OPTIONS` | CORS preflight, 204 |

A `PUT d/...` from `device` and a `PUT ack/<device>` set that device's `lastSeen` to now. Clients ack on every sync run
(even unchanged), which keeps `lastSeen` fresh.

## State JSON
```json
{
  "api": 1,
  "devices": {
    "<device>": {"first": 1, "last": 12, "lastSeen": "2026-10-22T10:00:00Z", "acks": {"<peer>": 5}}
  },
  "snapshot": {"id": "<id>", "covers": {"<device>": 12}},
  "previous": {"id": "<id>", "covers": {"<device>": 7}}
}
```
`first` = lowest seq still stored, or `last + 1` when all were pruned. `snapshot`/`previous` are `null` when absent. A
device appears once it has stored a file or sent an ack.

## Snapshots and pruning
- The relay keeps the latest snapshot and the one before it (`previous`); an accepted snapshot moves the latest to
  `previous` and deletes the older one.
- File `seq` of device `D` is deleted when every kept snapshot covers it (`covers[D] ≥ seq`) **and** every other device
  whose `lastSeen` is within 90 days has `acks[D] ≥ seq`. Checked after each accepted PUT.
- A client whose next needed file is below `first` (pruned) starts from the latest snapshot (falling back to `previous`
  if the latest cannot be read), then fetches the files after its `covers`.

## Limits and CORS
- 413 body too big; 429 more than 20 requests/s per client address (burst 100); 507 relay full (wallet count over
  `--max-wallets`, default 16, or a wallet over `--max-bytes`, default 1 GiB).
- CORS: `Access-Control-Allow-Origin` echoes the request `Origin` only if it is in the configured list (default
  `http://127.0.0.1:8080`, `http://localhost:8080`); allowed methods `GET, PUT, OPTIONS`; allowed headers
  `Authorization, Content-Type, X-BW-Covers`.

## Logs
Request kind, status, byte sizes, first 6 hex of `wid` and first 6 chars of `device`. Never tokens, bodies, full ids or
client addresses.
