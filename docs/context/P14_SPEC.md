# Stage P14 spec: bill-file (blob) invariants, relay api 4 (2026-10-25)

Plan item: PATH_FORWARD P14 ("referenced from ops, upload-before-ack, never deleted by clients, server-side GC from kept snapshots — the second protocol bump; removes blob_outbox/blob_delete/blob_own"). Owner decision: do it now; the owner updates the relay together with the phones.

## Why
Today a client deletes a bill file on the relay when its bill is deleted (`DELETE …/blob/<hash>`). A device that is behind, a restore, or an undelete can then point at a file that is gone. Files that no bill references are never removed from the relay unless a client happens to delete them.

## Invariants
1. **Clients never delete blobs.** The client stops sending DELETE. An api-4 relay answers DELETE with 204 and does nothing, so older clients keep working.
2. **Upload before ops.** A bill op that references a blob is uploaded only after that blob is stored on the relay (201/200). If the blob upload fails, those ops wait (the rest of the outbox goes on). Today blobs go first but a failed upload doesn't hold the ops back: fix that.
3. **The relay collects garbage from kept snapshots.** The relay can't read the sealed snapshots, so each snapshot `PUT` declares, **covered by the request signature**, the set of blob hashes that live bills in that snapshot reference. A blob is deleted by the relay only when **all** of these hold:
   - it is in neither the latest nor the `previous` kept snapshot's declared set;
   - it was stored more than 30 days ago (`GC_GRACE`), so a file uploaded since the last snapshot is never collected;
   - both kept snapshots carry a declared set. A snapshot from an older client has none, so no GC runs.
   GC runs after an accepted snapshot PUT. It is logged with counts only, and the byte counts are updated.

## Protocol (api 4)
- `"api": 4` in health and state; a new versions-table row; mixed-version notes:
  - **api-3 relay + new client:** blob PUT/GET work and nothing is ever deleted; no GC. Fine.
  - **api-4 relay + old client:** its DELETE is ignored and its snapshots carry no set, so no GC. Fine.
- The snapshot PUT carries the set. The builder picks how (a header or a signed sidecar route) and documents it in `RELAY_PROTOCOL.md`. Whichever form it takes, the signature must cover it (signed text `bw-relay-v4` if the text changes), and the relay must refuse a set it cannot verify. Limits: at most 100,000 hashes; each must be `isBlobHash`.
- A malicious relay can still delete anything. Add a threat-model note: a client with the key could declare an empty set, and GC would then remove files older than 30 days. A file of a live bill stays in the owner's local cache and in backups (P10), so this is recoverable.

## Client (core)
- Remove the `blob_delete` and `blob_own` tables and their code (`_dropBlob` deletions, `dropOrphanBlobs`, `markBlobDeleted`, `blobDeletes`, `_deleteBlobs`).
- Replace `blob_outbox` with an `uploaded` flag on `blob_cache`, or with a set derived from "blobs referenced by live bills here, not yet confirmed on this relay". Write a local-table migration and bump `schemaVersion` to 15. Local tables only; no synced entity changes.
- A new relay (relay changed or reset) re-uploads every referenced blob held in the cache, as today.
- `_maybeSnapshot` sends the declared set: the hashes of the snapshot's live bills.
- Existing behaviour stays:
  - LRU eviction never evicts an un-uploaded blob;
  - deleting a bill keeps its file in the cache until evicted;
  - undelete brings the reference back.
- Status: `blobsDeleted` goes away; `blobsWaiting` stays.

## Relay
- `_deleteBlob` → 204 no-op. Each blob has a stored time (file mtime or an index).
- Keep the declared sets of the latest and `previous` snapshots, and persist them across restarts.
- GC as above.
- Tests: GC removes only unreferenced blobs older than the grace; a younger one stays; a snapshot without a set disables GC; DELETE is a no-op; an unverified or forged set is refused; restart keeps the sets; byte counts stay right.

## App
- Plan › Sync texts stay ("N bill files waiting to upload", "This relay can't keep bill photos yet…").
- Add one line after the relay is updated: "Old bill files are cleaned up on the relay." No new UI otherwise.
- The STATUS note tells the owner to update the relay (`tools/relay.sh` / the Caddy host image) and the phones together.

## Tests (core)
- An op waits for its blob: a failed blob PUT holds that bill op while others go up; it goes up once the blob succeeds.
- No DELETE is ever sent: deleting a bill, a re-import, and a restore all send none.
- A snapshot declares exactly the live bills' hashes.
- Migration 14 → 15 keeps the queued uploads.
- Two devices: A deletes a bill and B undeletes it before GC; the file is still there.
- `relay_sync` desktop test still green.
