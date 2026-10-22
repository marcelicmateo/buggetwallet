# Pipeline — what the lead starts when (orchestration runbook)

The lead (main session) keeps the queue moving within a **cap of 4 agents at once** (owner, 2026-10-20): on every agent
report, read this file, mark the item, and start the next ready item only if fewer than 4 agents are running. Full test
suites stay serialized (one Haiku run per stage); builders run only targeted checks.

## Token rules (owner, 2026-10-20)
- Cap 4 concurrent agents, typically: one core (Fable), one UI (Sonnet), one or two cheap slots (Haiku watcher, devops,
  test-writer). Dependent or not-yet-needed work waits in the queue; waiting costs nothing.
- Parallel only for independent items needed in the current stage.
- test-writer only for money and sync logic; UI features get tests from the builder.
- Briefs are pointer-style: exact files, the API to match, the one allowed check; reports under 15 lines.
- Scout first (owner, 2026-10-21): before a builder or test-writer starts, a `scout` (haiku/low, read-only) returns a
  context pack (files, line ranges, APIs, tests, helpers); the lead pastes it into the brief. Builders read code by
  `grep -n` + line ranges, never whole files, build output by result line + failures, screenshots downscaled to 540 px.
  Measure with `python3 -I tools/token-usage.py` (baseline in memory: ~2.9M tokens/commit before 2026-10-21).
- One targeted check per agent at the end, one Haiku full run per stage, one reviewer pass per stage on the whole diff.
  Live-mode screenshots only for visual changes.
- Batch follow-ups into one message per agent instead of resuming it repeatedly.
- Fewer, bigger stages: each stage costs a full run and a review. CI is manual only (owner, 2026-10-21): no ci-watcher after a push.

## Procedure on each event
| Event | Do |
|---|---|
| Builder reports | Read its report. Bug outside scope → queue a fix item (test + fix, same stage). Mark the item done. Start the next item whose deps are met (table below). |
| All items of a stage done | Merge branches into `v2` in the listed order → reviewer (Fable/high) on the stage diff → fix findings → Haiku/low full run (`test`, `desktop-test`, `perf`) → `tools/emulator.sh screens` for UI stages (read the PNGs) → commit → push → STATUS.md (Done + Next) → `git worktree remove` the merged worktrees. |
| Haiku run red | Fix items first (owner rule: bugs before features), then re-run only the failing suite. |
| Owner message | Owner bug reports go before anything queued. |

Agent models: scout, ci-watcher haiku/low; test-writer, devops sonnet/medium; ui-builder sonnet/high; core-builder, reviewer Fable/high.
Each item runs in its own worktree (`.claude/worktrees/<name>`), created by the lead from the branch named in "Base".

## Stage R: sync redesign (2026-10-22, spec DESIGN_DECISIONS §4.9)
| # | Item | Agent | Depends on | Status |
|---|---|---|---|---|
| R0a | Context pack: sync engine, repo sync APIs, sync tests/sim | scout | – | done |
| R0b | Context pack: build tooling, package layout, sqlite3 packaging | scout | – | done |
| R1 | Encrypted SQLite spike (sqlite3mc on Android, Linux, web wasm) | devops | R0b | done (5606f00, merged e3794ff; sqlite3 3.7.1 + sqlite3mc hook, APK +1.4 MB) |
| R2 | Relay server `relay/` + HTTP tests (protocol: `RELAY_PROTOCOL.md`) | core-builder | R0b | done (96118c7, 93 tests; merged into v2) |
| R3 | `SyncTransport`, `MemoryTransport`, `RelayTransport`, `SyncEngine`, snapshots; deletes FolderSync, ports sim + sync tests (app compiles again in R5, based on R3) | core-builder | R0a | done (0c2687d, core 845/0 incl. R4; branch `stage-r` = R3 + v2) |
| R4 | Sync spec tests (strict order, caught-up matching, S1/S2, snapshots, pruning, first connect) | test-writer | R0a | done (f58c7f9, merged into R3, green) |
| R5 | App: Plan › Sync, join with relay, backups via save dialog, Android INTERNET/cleartext, remove folder sync | ui-builder | R3 | done (29b52e1, test green app 726; merged into stage-r) |
| R6a | Encrypted db core: `localDbKey`, `openKeyed`, `WalletRepo.open(dbKey:)`, crash-safe conversion; stuck-peer snapshot self-heal | core-builder | R1, R3 | done (9febc0a + 709e4bf heal from any caught-up device; core 867/0; merged into stage-r) |
| R6b | App: open the db only once the key is known (onboarding/web unlock), keyed open native + web wrapped VFS | ui-builder | R5, R6a | done (5eab5f2, test green app 751, web-test 9; merged into stage-r) |
| R7 | Relay container, `tools/relay.sh`, `tools/build.sh relay`, CI relay job, setup doc (desktop test through a relay moves to R7b after R5) | devops | R2 | done (990ee5d, merged; image 92 MB, full test green incl. relay 93) |
| R7b | Desktop test: two app instances syncing through `tools/relay.sh` | devops | R5, R7 | done (a161afd, desktop relay_sync green 22 s; merged) |
| R8a | Review fixes core/relay: M1 local import/delete reconcile ignores caught-up gate; M2 unblock on transient GET + older-schema snapshot; L5 refused snapshot re-downloaded each run; L6 first upload >16 MiB never syncs (split into ≤8 MiB parts); L7 relay buffers bodies for unknown wallets | core-builder | review | running |
| R8b | Review fixes app: K join merges an unopened plaintext wallet.db (set aside instead); M3 web forget deletes set-aside copies; L4 create writes key before set-aside; L8 setRelay during a sync not followed up | ui-builder | review | running |
| R | Review done (0 high, 3 medium, 5 low → R8a/b), fixes, Haiku full run, emulator, merge stage-r → v2, push, STATUS | lead | R1–R8 | running |

R6 recipe (from R1): native `sqlite3.open(path)` then `PRAGMA key = "x'<64 hex>'"` right after open; plaintext → encrypted
in place = open unkeyed + `PRAGMA rekey`. Web: `registerVirtualFileSystem(fs)` **without** `makeDefault`, open with
`vfs: 'multipleciphers-${fs.name}'`, then `PRAGMA key` (makeDefault gives "Encryption is not supported by the VFS"); after
`unregisterVirtualFileSystem` (forget) the next `IndexedDbFileSystem` needs a new `vfsName` (else "null function"); check
opening an existing unkeyed IndexedDB db via the wrapped VFS. Wrong/missing key: `PRAGMA key` succeeds, the first read
throws `SqliteException` extended code 26 "file is not a database".

## Stage W progress (2026-10-21)
- W1–W3 merged into local `v2` (925d546, 3071b53); scouts used for W2/W3 (29k + 47k tokens), builders 46k + 75k.
- Review: 2 findings. Low (wasm pin trust-on-first-use) fixed 1c7086c; medium (two tabs overwrite the wallet) → W4 running.
- Also fixed: nudge slots already past in the phone zone failed the whole schedule (c516b03).
- Done: W4 merged (40c3628), Haiku full run green, web build + localhost shots read, pushed. Next: sync redesign spec (owner decisions).

## Queue (2026-10-20)
| # | Item | Agent | Base | Depends on | Status |
|---|---|---|---|---|---|
| B1 | Commit Stage A leftovers, Haiku full run, push | lead + haiku | v2 | – | committed d632e32; run in progress |
| B2a | Adaptive layout finish + edge tests + month-chip fix | ui-builder | agent-a7db2fe… | – | done (6ebb9bc) |
| B2b | Goal contributions merge + sync quarantine + transport + edge tests | core-builder | agent-a99ad86… | – | done (804961d, core 564/0) |
| B2c | Parallel desktop tests (BW_JOBS) | devops | agent-aefe0df… | – | done (8e212c1) |
| B2e | BUG: desktop plan test typed a missing folder (test bug since 561d768) | ui-builder | agent-a7db2fe… | – | done (2759d5c) |
| B2d | `paydayDone` → `payGoals(period:)`; pass appVersion to FolderSync | lead | stage-b | B2b | done (c1dd111, app 446/0) |
| B2 | Merge B2a–e on `stage-b` (done), review (done, fixed: 6d273f4), test+desktop green on a275d29, perf step hangs (D1d), emulator running, then push | lead | stage-b → v2 | B2a–e, B1 | running |
| C1 | Ledger theme tests from spec | test-writer | ledger-tests (from 6ebb9bc) | – | done (5 files; ui-builder merges them) |
| C2 | Ledger theme build (fonts, tokens, components, screens) | ui-builder | ledger-ui (from 6ebb9bc) | – | done (cc64049, app 500/0, tests merged) |
| C3 | Merge C1 into C2, make tests pass; three widths, dark, text scale | ui-builder | ledger-ui | C1, C2 | done (in cc64049) |
| C | Merge C, review, Haiku, emulator, push, STATUS, re-sync design-system artifact | lead | v2 | C3, B2 | queued |
| D1 | Bank profiles: PBZ/Revolut as profiles, kindHint, golden no-change tests | core-builder | bank-profiles (from v2) | – | done (00c111d, importer 193/0; merged into stage-b) |
| D2 | Categorizer reads kindHint; generic own-transfer rule keyed on source (no IBANs stored) | core-builder | kind-hint (from stage-b) | D1 | done (853ea33, core 596/0); unreviewed → merged and reviewed with Stage C, not B |
| D1b | `tools/build.sh core|app|importer <test file>` runs one test file non-interactively (core-builder found `shell` ignores piped stdin) | devops | single-test (from stage-b) | – | done (6e5572f; merge into stage-b after the fix batch) |
| D1c | BUG: run pruning deleted an in-progress run dir (newest-30 rule, concurrent worktrees) | devops | prune-fix (from stage-b) | – | running |
| C3 | (follow-up) hero amount gap, margin line in NarrowPage | ui-builder | ledger-ui | – | running |
| D1d | BUG: `tools/build.sh perf` hung at startup (portal activation on the headless bus); fixed 79e1fb2 + 20-min timeout; re-run perf when idle | devops | perf-hang | – | done |
| C | Stage C merged and pushed (5b8fc13); CI all green; design system re-synced (v10); all 37 worktrees removed | lead | v2 | B2 | done |
| D2b | BUG (owner): loose own-transfer pairing → hinted-side rule, exchange kind, schema-4 rehint, hinted-first ranking | core-builder | transfer-fix | – | done (b81ac90, pushed) |
| S1 | Lagging-device cash match to an unrelated equal card payment → sync redesign (owner 2026-10-20) | – | – | – | scheduled: sync redesign |
| S2 | Damaged/late sync file double count → sync redesign (owner 2026-10-20) | – | – | – | scheduled: sync redesign |
| D1e | BUG: perf hung after "Built" because of stale build state from killed runs; perf_run now starts from a clean profile build; idle-laptop perf green (31 s, 0 missed) | lead | v2 | – | done |
| D3 | Merge v2 into master | lead | – | – | done 2026-10-20 |
| F0 | M4 Habits spec: DESIGN_DECISIONS §4.6 | lead | – | – | approved 2026-10-20 |
| F1 | M4 Habits build: core (review state, recurring detection + confirm, reservation in safe-to-spend) + UI (review card/screen, Plan expected bills + settings, Today due line, nudges) | core-builder + ui-builder | habits-core, habits-ui (from v2) | F0 | built (core 41e4fb4, UI 67c1448); reviewed → F1b |
| F1b | Review fixes: nextDue from paying row (HIGH), confirmed-bill category follows rules (coveredByPlan), streak `< 14`, status-only op fill, `skipRecurring` API + "Skip this cycle" row action | core-builder + ui-builder | habits-core, habits-ui | F1 | done (b3fd42f, d5bd283, 3ea60a3; merged into v2) |
| E0 | Spec for budget vs actual per category: DESIGN_DECISIONS §4.5 | lead | – | – | approved 2026-10-20 (monthly) |
| E1 | Budget vs actual per category (M3): core `budgetVsActual`/`suggestBudgets` + `categoryBudgets` setting; UI Plan editor, Spending bars, Today line | core-builder + ui-builder | budgets-core, budgets-ui | E0 | done (merged, full run green) |
| E2 | Top merchants (M3) | – | – | – | already built ("Top places" on Spending) |
| F | M4 Habits stage: full run green, emulator read, pushed 2bff25d; CI watching | lead | v2 | F1b | done |
| G0 | M5 Polish spec: DESIGN_DECISIONS §4.7 | lead | – | F | approved 2026-10-20 (sync-folder backups, clean CSV, search all data) |
| G1 | M5 Polish build: core (`backup.dart`, `export.dart`, `search.dart`) + UI (Plan › Backup, Export, search on Spending) + spec tests (backup round-trip, CSV exactness, amount parsing) | core-builder + ui-builder + test-writer | polish-core, polish-ui, polish-tests (from 2bff25d) | G0 | done (6d1cd3e, 3a481fd; reviewed, 4 low notes: 2 fixed, 2 noted) |
| G | M5 stage: full run green (193/770/635, desktop 14, perf ok, emulator 14 PNGs), pushed; CI watched | lead | v2 | G1 | done |
| I0 | Web version spec: DESIGN_DECISIONS §4.8 | lead | – | G | approved 2026-10-21 (localhost only, passphrase key, before sync redesign) |
| W1 | Web build plumbing: `app/web/` scaffold, Chrome in the container, `tools/build.sh web` (pinned `sqlite3.wasm`, wasm build with JS fallback), `tools/web.sh serve|shot`, `tools/build.sh web-test` | devops | worktree-agent-af1e542b8b131808b (from 87adbbd) | I0 | done (f2a970a; Chrome 156 in image +0.48 GB, wasm plumbing verified with a stub; real build waits for W2) |
| W2 | `wallet_core` compiles for the web: `CommonDatabase` + `WalletRepo.fromDatabase`, `archive` gzip, `backupBytes`/`restoreBackupBytes`, `LogSink` + `MemoryLogSink`, conditional exports for FolderSync / file backups / RotatingFileSink | core-builder | web-core (from 87adbbd) | I0 | done (3b1c936, core 789/0) |
| W3 | App web twins: `wallet_db.dart` (wasm + IndexedDB VFS), passphrase `KeyStore`, memory log + download, no nudges/sync folder on web, Backup download/upload, "Forget this browser", onboarding passphrase step | ui-builder | web-ui (from 87adbbd) | I0 (shims W2 until it lands) | done (4f953ed, shim dropped; app 700/701, flake fixed c516b03) |
| W4 | BUG (review): single-tab guard on web (Web Lock, InUseScreen) | ui-builder | worktree from 1c7086c | W3 | done (8cb218c) |
| W | Web stage: merge W2 → W1 → W3, review, Haiku full run + `web-test`, localhost screenshots, push (no CI) | lead | v2 | W1–W4 | done (full run green, pushed) |
| H1 | CI split (owner 2026-10-20): CI runs only what the laptop does not verify — signed APK, Linux release bundle + smoke, dev release publish, log to ci-logs — as separate jobs; lint/unit/desktop tests run only on demand (`workflow_dispatch` input or `[ci tests]` in the commit message) for cloud sessions without Flutter. Cause: the single `build` job ran out of runner disk (run 39492372474). | devops | ci-split (from v2) | – | done (10033a4, merged); first run watched |
| H2 | `tools/ci-status.sh --wait <sha>` must wait for the `ci` workflow run of that sha to conclude (`gh run list --workflow ci --commit`), not only for check-runs that already exist: on d46b787 it said "all green" while the ci run was still pending (only release.yml's gate had run). Batch with the next devops item. | devops | ci-log-fix | – | done (cb916c6) |
| H3 | BUG: first split run 39496288936: apk, linux, publish green, test jobs skipped, but job `log` failed in `.github/scripts/publish-log.sh` (step printed nothing; git errors swallowed by `2>/dev/null`), so ci-logs has no entry for d46b787 | devops | ci-log-fix | – | done (cb916c6, merged, pushed) |
| D4 | Merge `v2` into `master` (owner, 2026-10-21): fast-forward to 4b16240, `release.yml` builds all platforms → `dev-all` refreshed | lead | – | G | done 2026-10-21; owner flagged macOS billing → `release.yml` gate no longer runs on master pushes (tags/`[release]`/manual only) |

Merge order for B2: B2b → B2a → B2c, then B2d. C merges after B2 (ledger branches are based on B2a, so merging v2 into them
only brings packages/ and tools/ changes).

## Rules the lead keeps
- One Haiku full run per stage; targeted checks only while building (`tools/build.sh core|importer|app|lint`, one test file).
- No polling anywhere: background runs + notifications, Monitor for other processes.
- Say the model/effort choice before starting agents; cheapest that does the job.
- Bugs found by any agent are fixed in the same stage with a reproducing test.
- STATUS.md is updated at the end of every stage; this file at every queue change.
