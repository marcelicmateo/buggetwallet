# wallet_sync — notes for Claude

Pure Dart (no Flutter): the end-to-end encrypted relay sync (`SyncEngine`), its transports (`RelayTransport` over
`package:http`, `MemoryTransport` in memory for tests and the demo) and bill files on the relay (`BlobStore`). Split out of
`wallet_core` in J4 (refactor only: wire formats, logs and behaviour unchanged). Builds on `package:wallet_core`
(`WalletRepo`, change log, HLC, `vault.dart` seal/unseal, backup payload, logs); bills' cache tables (`repo_blobs.dart`),
`isBlobHash` and the vault stay in core. Protocol: `docs/context/RELAY_PROTOCOL.md`; known limits of the whole sync design:
`packages/wallet_core/CLAUDE.md` "Known limits".

**Dependency cycle, tests only:** this package depends on `wallet_core`; core has `wallet_sync` as a dev dependency so its
feature tests sync two devices through the engine (`packages/wallet_core/test/support/sim.dart`). Core's `lib/` never
imports this package (`packages/wallet_core/test/layering_test.dart`). Never add a core `lib/` import of `wallet_sync`:
put what both need in core instead. Errors here that are safe to log as text implement core's `LogSafeError`
(`SyncException`).

## Web rule (§4.8: the barrel compiles for the web)
`package:wallet_sync/wallet_sync.dart` must compile with dart2js and dart2wasm, like core's barrel: no `dart:io`,
`dart:ffi` or `package:sqlite3/sqlite3.dart` in anything it reaches (`test/web_sync_test.dart` checks the files). Should
dart:io code ever be needed, it goes in a `*_io.dart` file with a `*_web.dart` twin (core's rule).
- The sync engine and both transports are shared code (no dart:io): `RelayTransport` uses `package:http` (IOClient on
  the VM, fetch in the browser). The real relay server (`relay/`) is only a dev dependency for the end-to-end test.
- Compile check (after `dart pub get`): `tools/build.sh shell -c 'cd packages/sync && dart compile js -o /dev/null
  tool/web_smoke.dart && dart compile wasm -o ../../dist/web_smoke.wasm tool/web_smoke.dart'` (`SyncEngine` over
  `MemoryTransport` or `RelayTransport`, `BlobStore.add`). Run it whenever an import changes.

## Files
- `sync.dart` — `SyncException`, `SyncReport`, `SyncWaiting`, `SyncDevice`, `relayFingerprint(instance)` = first 8 hex as
  `xxxx-xxxx`; web-safe.
- `sync_problems.dart` — a peer file that cannot be used is skipped (the run goes on with the other files and devices)
  and quarantined: `BadFiles`, one device-local value (`localValue('syncBadFiles')`, never synced), records device,
  file, `SyncProblemReason` (`badKey`, `corrupt`, `unknownVersion`, `applyFailed`, `clockDrift` (H7, retried at
  `retryAt`); `unreadable` = I/O error, not quarantined; `deviceIdInUse` (H6) = about this device's own uploads, never a
  quarantine), size and content hash. It is read again only when its content changes, or (unknownVersion,
  applyFailed) once after `SyncEngine.build` changes (`<syncReaderVersion>.<WalletRepo.schemaVersion>+<app version
  passed to SyncEngine>`). `SyncReport.problems` lists every file not applied, also the known ones on every run
  (`SyncProblem`: short device id = first 8 characters of its id, reason, bytes, `isNew`), `badFiles` is
  their count. Database errors that are about this device (read-only, disk full, I/O, locked) stop the run instead,
  so the file is not refused for good. The quarantine is separate from the cursors: a schema upgrade reads every
  peer file again, an unchanged badKey/corrupt file stays skipped, unknownVersion/applyFailed are tried once more.
- `sync_engine.dart` — relay sync (§4.9, wire protocol `docs/context/RELAY_PROTOCOL.md`), web-safe. `SyncTransport`
  (`state`, `put`, `get`, `ack`, `putSnapshot`, `getSnapshot`, `putBlob`/`getBlob` (null on 404)/`putSnapshotBlobs`
  (api 4 declared set; there is no delete call), whose defaults act like an older relay: 404; `run` uploads the
  un-uploaded files plus every cached file a pending op references (a first connect: every live bill's) before the ops,
  and **holds** the file fields (`blob`, `blob_type`, `blob_bytes`, `deleted`) of an op whose cached file was not stored
  in this run (`_holdForBlobs`: the rest of the op and outbox goes; held parts back in the outbox, same clock); a 404
  before this device's first file is retried once after it (the relay creates a wallet only then) and the held ops go
  in a second upload of the same run; a relay without blob routes holds nothing. Failures stay queued and never stop
  the run. After an accepted snapshot PUT on a relay whose state said api ≥ 4: `putSnapshotBlobs(id, liveBlobHashes)`
  (failure logged, not retried). No snapshot while a held op waits for a file whose PUT failed this run with anything
  but `full` (507: the snapshot frees room; that file stays queued and pinned, and that snapshot's set is skipped). `SyncReport.blobsSent`/`blobsWaiting`/`blobsUnsupported` (404 on an upload for a wallet
  the relay knows = older relay), `relayApi`/`relayCollectsBlobs`; `RelayState.api`; failures are `TransportException(TransportFailure)`),
  `RelayState`/`RelayDevice`/`RelaySnapshot` (+ `fromJson`), implemented by `MemoryTransport` (`sync_memory.dart`: the
  relay's rules in memory — no gaps, never overwritten, acks grow, snapshot 422 before 409, two kept snapshots, pruning
  incl. the 90-day rule driven by `now`; no signature check; blobs: hash checked, 404 for an unknown wallet, hooks `blobs`, `blobRoutes`, `tamperBlob`,
  `api` (4; 3 = no declared sets), `declared`, `gcRuns` (GC as the relay: both kept sets, 30-day grace from the last PUT); test hooks `offline`, `corrupt`, `failGet`, `replace`, `files`,
  `calls`, `instance` (random per transport, sent once the wallet exists; null = an api-2 relay), `maxBytes` (reported
  with `storedBytes` in state once the wallet exists, not enforced; null = an older relay), `wipe()` (empty, new
  instance), `copy()`/`restore(copy)` (a relay restored from an older copy of its data folder, same instance)) and
  `RelayTransport` (`sync_relay.dart`, `package:http` + `cryptography`, api 4 (`relayApi`; api-3 relays too, `relayMinApi`), paths under `/v2/`: `wid` and the Ed25519
  key pair from `deriveKey` (`relayIdInfo`, `relaySignInfo`; `ids` = (wid, public key)); every request carries
  `X-BW-Time` (device clock + `clockOffsetMs`) and `X-BW-Sig` over `signedText` (`bw-relay-v4`, or `bw-relay-v3` once
  `signApi` fell back to 3: after a 401 that is not `clock`, health says 3, the request is sent again; method, `signedHost`
  of the URL (lower case, port only when not the default), path from `/v2/` even behind a base path, `X-BW-Covers`,
  body SHA-256, time); `PUT d/<device>/1` also sends `X-BW-Pub` and, with `createToken:` set, `X-BW-Create-Token`
  (403 `createToken` → `TransportFailure.createToken`, fatal for the run). `clockOffsetMs` lives in the transport
  (never persisted; the app builds a new transport per run, so a device whose clock is off pays one 401 `clock` retry
  per run). 401 `clock` → offset from the
  `Date` header (`parseHttpDate`, no dart:io) and one retry, never more (a second `clock` = `other`); status → failure,
  `api` above 4 → `newerApi`, below 3 → `olderApi`; a 401 that is not `clock` asks `health` once (api 2 → `olderApi`,
  above 4 → `newerApi`, 3 → v3 text and one retry, else `refused`); 404 state = empty relay, 30 s timeout; `health(base)` (returns the api) asks
  `/v2/health`, on 404 `/v1/health` to tell an older relay apart; `now:` for tests). About 1.8 ms per signature on the VM.
  Stage H (H5–H9) in the engine: `SyncEngine.run` while a run of the same engine is in progress returns that run's
  future (`sync.run.joined`); relay usage (Stage I: `RelayState.bytes`/`maxBytes`, null from an older relay or for a
  value that is not a non-negative int; `SyncReport.relayBytes`/`relayMaxBytes` from the run's state read, so the run's
  own later upload may not be in it; `test/relay_usage_test.dart`); relay instance (`RelayState.instance`, device-local `syncInstance` stored when an upload
  went through completely; another id = `SyncReport.relayChanged`: every cursor to 0 and a first connect; none stored
  yet = adopted; a run that created the wallet asks `state` once more to learn it); streams and ownership (H5b/HBb,
  RELAY_PROTOCOL.md "Device streams and ownership"; `SyncEngine.streamName/streamBase/streamEpoch`, local
  `syncStream` (current; absent = the device id), `syncStreams` (every stream this install wrote and acks as),
  `syncSending` (`{"from", "parts": {seq: fileHash}}` during an upload, each part recorded before its PUT),
  `syncForeign` (streams of other installs already reported), `syncStreamLast` (relay `last` of each stream it left),
  `syncAcked` (the acks it stored per stream)): `_move` takes a fresh stream `<id>-<n><6 random letters>` (n above
  every same-id stream known) and the next upload is the whole state from seq 1, when the relay's `last` of the current
  stream is below `syncSent` (kept as acked; its `last` recorded), above it with an extra seq that is not its own
  recorded part (fetched and hashed once; another install, or this database restored from an older file copy; no
  longer acked as), or on a 409 (same run, once; `syncSending` cleared). A left stream whose `last` grows past
  `syncStreamLast` is dropped from `syncStreams` (another install writes it; reported once). An ack on the relay below
  `syncAcked` = a rolled-back relay: `relayChanged`, every cursor 0, `syncAcked` cleared. Every stream but the current one is read like a peer's;
  acks go under the current stream and every listed stream in `syncStreams` (cursors + the current `last`); cursors of
  streams the relay no longer lists are dropped; `SyncReport.devices` lists one entry per device id. `deviceIdInUse`
  (`SyncProblem.device` = own short id, `bytes` 0 or the refused file's size) is information, reported once per move or
  newly seen same-id stream; it does not stop uploads or `caughtUp`. `clockDrift`: a file
  or snapshot whose newest op clock is more than `maxClockDrift` ahead of the repo's wall clock (`repo.clock.now()`) is
  quarantined with `BadFile.retryAt` (= newest − 1 h, JSON `u`; snapshots `retryAt`) and read again from then on, or
  after a build change. Every file is unsealed with `aadSyncFile(<stream>, seq)`, snapshots with `aadSnapshot(id)`.
  `SyncEngine(transport, key, appVersion:, now:, partBytes:).run(repo)`: reads `state`; uploads pending ops as `last + 1`
  (seq from the relay, so a failed PUT leaves no gap; a 422 keeps the outbox for the next run, a 409 moves the stream); the **first run on a
  relay** (local `syncSent` absent, or the relay's `last` for this device below it = a new or wiped relay) uploads
  `snapshotOps()` instead (the migration from the folder sync). Any upload is split into several seqs, each sealed file
  ≤ `partBytes` (default `maxPartBytes` 8 MiB; the relay refuses > 16 MiB): by op count, sealed size measured, halved
  while over; the outbox and `syncSent` change only after every part is stored, so a run that stops half-way sends it all
  again (idempotent). `MemoryTransport.maxFileBytes` (default 16 MiB) lowers the limit in tests. Cursors (`sync_cursor` table, device-local, `WalletRepo.syncCursors`):
  per other device the last seq applied; files apply strictly in order; the first file that cannot be fetched (`waiting`
  with reason null + an `unreadable` problem), is pruned without a usable snapshot, or is refused (quarantined in
  `BadFiles` under `<device>/<seq>`, fetched and hashed again each run) stops that device. The per-peer loop is `_applyPeer` (state in `_ApplyRun`, result `_PeerApplied`/`_PeerWaiting`/`_PeerRefused`/`_PeerBlocked`); its invariants are asserts (in order per device, a refused file leaves `WalletRepo.dataVersion` unchanged, records forgotten only after a complete pass). A cursor above a device's
  `last` is reset to 0 (relay lost its files). Snapshot use: when a needed file is pruned; when this device applied
  nothing yet (new device, schema-bump replay) and the snapshot id says this schema or newer (`s<schema>-<ms>-<hex>`);
  and when a blocked file is covered by the snapshot (then the device goes on after it). Latest first, then `previous`;
  covers raise the cursors. Q8 (a pruned needed file): a snapshot of this schema or newer (latest or `previous`) and
  nothing on top (the relay prunes only what every kept snapshot covers, so the files after it are still there); with
  no current one an older one, and only when the device started from empty cursors (schema-bump replay, new install)
  the device-local mark `syncWantCurrentSnapshot` = ms: for up to 30 days (`wantCurrentFor`) it writes no snapshot
  (heal snapshots excepted) and applies the next one of this schema or newer once, then clears it (also cleared when a
  current one is applied after a prune). So ops an older build skipped come back after a schema-bump replay even when
  the relay pruned their files. Known limit: a heal snapshot written while marked can be taken as the awaited one. The unblock case only for a quarantined wait (`SyncWaiting.reason` set, not a file that
  could not be fetched) and, like the new-device case, only with a snapshot of this schema or newer (latest or
  `previous`, whichever covers it). A snapshot that could not be fetched or refused to apply is remembered device-locally
  (`syncBadSnapshots` = `{"<id>": {reason (null = not fetched), bytes, hash, build, at}}`) and not downloaded again until
  the relay names another id (unknownVersion/applyFailed: once more after `build` changes; not fetched: retried after
  `snapshotRetry`, 1 h); records of ids no longer listed are dropped. It is reported in `SyncReport.problems` as a
  `SyncProblem` with `snapshot: true` and `device` '' (counts in `badFiles`, not in `caughtUp`). Acks every run (a failed ack is only logged). `caughtUp` = no waiting, no problem, every
  device applied through `last` (stored as `syncCaughtUp`, see matching): only then `runPendingMatch()` and the snapshot check: written when files not covered by
  the newest snapshot hold ≥ 500 ops (`sync_files`: ops per recorded file, own uploads included) or the newest is older
  than 7 days (none yet: 7 days since this device's first relay sync, local `syncSince`), or at once when the newest
  was written by an older schema (Q8: its id says `s<n>-` with n below ours); payload = backup format,
  covers = every listed device's cursor + own last; refused (another device was faster) is only logged. Self-heal
  (`_trackStuck`, every run): a peer seen within `stuckAfter` (24 h) whose ack for any device D (this one included)
  stays below what this device holds of D (its cursor, or its own last; same value, tracked device-locally in
  `syncPeerStuck` = `{"<peer>/<D>": [ack, sinceMs]}`) for over 24 h, while the newest snapshot does not cover the file it
  needs, makes this device (when caught up) write a snapshot at once; at most one heal snapshot per device per 24 h
  (`syncHealAt`), and a second healer skips once the first one's snapshot covers the file. `SyncReport`:
  `sent` ops, `received` fields changed, `filesRead` (snapshots count), `problems`, `caughtUp`, `waiting`, `devices`
  (short ids, `lastSeen`, `isThis`). Fatal `SyncException`s (short, no address): unreachable, refused (401), relay
  full, newer relay API, older relay API, other. Opening a database from the old folder-sync builds drops its `peer_files` table (`repo.peerFiles.dropped`).
- `blob_store.dart` — `BlobStore(repo, key, maxCacheBytes:)`: `add` (async: seal, hash = SHA-256 of the sealed bytes, cached with `uploaded` 0), `read(hash, transport:)` (cache, else
  fetch, hash checked, unsealed, cached as uploaded). 

## Tests
- Synthetic data and the multi-device sims come from core's `test/support/` (imported as
  `../../wallet_core/test/support/<file>.dart`: `sim.dart` `Net`/`Device`, `engine_spec_sim.dart`, `h_sim.dart`,
  `h_compat.dart`, `synthetic.dart`); core's own two-device feature tests use the same files.
- bill files (BlobStore, engine queues, Memory/RelayTransport blob calls):
  `test/blob_store_test.dart` (+ `blob_spec_test.dart`; real relay: `sync_relay_test.dart`).
- sync self-heal: `test/sync_self_heal_test.dart`, bill-file invariants incl. two devices, GC and the 14 → 15 migration (P14): `test/p14_blob_invariants_test.dart`.
- Sync engine: `test/sync_scenarios_test.dart`, `sync_convergence_test.dart` (random, 2-4 devices), `sync_quarantine*_test.dart`,
  `sync_read_edge_test.dart`, `sync_snapshot_use_test.dart`
  (unblock conditions, remembered snapshots), `sync_split_upload_test.dart` (uploads over one file), `sync_engine_spec_test.dart` (+ `support/engine_spec_sim.dart`, shared fake clock: snapshots,
  pruning, first connect, S1/S2), `harden_sync_test.dart` (Stage H5–H9 + HBb: relay instance incl. A → B → A, streams on 2,
  3 and 4 devices incl. a double restore with an offline peer, ownership (clone both editing, 409 then the next run,
  database restored from an older file, fresh database with a kept id, H6 id change still acks), clockDrift incl. a
  pair over an hour apart converging, internal writes with the clock behind, `clockAhead` backups, 401 → health
  (older/newer/refused), BWOP2 AAD/BWOP1/inflate cap, field-pair repair on two devices, one run at a time), `sync_relay_test.dart` (`deriveKey` vs. a hand-written HKDF, `RelayTransport` over
  `MockClient` incl. signatures checked from the protocol text, clock offset retry, older/newer API, `MemoryTransport`
  rules, end to end with the real `relay/` server on port 0 incl. a wrong signature and skewed device clocks).
- `relay_usage_test.dart`, `i3_relay_usage_test.dart` (relay usage), `h12_sync_memory_test.dart`, `h12_sync_relay_test.dart`
  (Stage H spec tests), `web_sync_test.dart` (web-safe files, `LogSafeError`).
- Run: `tools/build.sh sync` (analyze + tests) or `tools/build.sh sync <test file>`; part of `tools/build.sh test`.
