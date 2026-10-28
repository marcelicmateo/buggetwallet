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
| Builder reports | Read its report. Bug outside scope → queue a fix item (test + fix, same stage). Mark the item done. Start the next item whose deps are met (table below). **Review each half as it lands** (reviewer on that diff, `PATH_FORWARD.md` §5 as checklist) and send findings to the *same* builder by SendMessage (it keeps its worktree and context; no scout for fix items). If the next stage needs owner input, ask now, while the other half builds. |
| All items of a stage done | Merge branches into `v2` in the listed order → reviewer on the merged delta only (the halves were reviewed as they landed) → fix findings → lead starts `tools/build.sh stage` in the background; Haiku/low watcher reads `dist/logs/stage-summary.txt` and the failures → read the PNGs for UI stages → commit → push → STATUS.md (Done + Next) → `git worktree remove` the merged worktrees. |
| Haiku run red | Fix items first (owner rule: bugs before features), then re-run only the failing suite. |
| Owner message | Owner bug reports go before anything queued. |

Agent models: scout, ci-watcher haiku/low; test-writer, devops sonnet/medium; ui-builder sonnet/high; core-builder, reviewer Fable/high.
Each item runs in its own worktree (`.claude/worktrees/<name>`), created by the lead from the branch named in "Base".

## Stage V: sync format items before M6 (2026-10-28, plan `STAGE_V_PLAN.md`; schema 18; statement ticking dropped)
Merge order: VB → VA → VT → VU.
| # | Item | Agent | Branch | Depends on | Status |
|---|---|---|---|---|---|
| V0a | Context pack V1+V2 (vault, backup, sync quarantine, resend, sim) | scout | – | – | running |
| V0b | Context pack V3 (streak, entity schema, migrations) | scout | – | – | running |
| V0c | Context pack UI (failure texts, Settings › Sync problems, review Done) | scout | – | – | running |
| VA | V1 key id (`BWOP3`) + V2 state digest and repair | core-builder | v-sync | V0a | queued |
| VB | V3 review rows, `reviewStreak` pure (schema 18) | core-builder | v-review | V0b | queued |
| VT | Spec tests (seal vectors, digest, divergence → repair, no ping-pong, streak) | test-writer | v-tests | V0a, V0b | queued |
| VU | UI: exact key/damaged texts, otherKey + devicesDisagree in Settings › Sync | ui-builder | v-ui | V0c | queued |
| V | Merge, merge-delta review, stage run, push, STATUS | lead | v2 | all | queued |

## Stage J: deeper structure (2026-10-27, `PATH_FORWARD.md` §4 J1–J4; refactor-only, no schema/protocol change)
Owner (2026-10-27): J before the live test; `ci` (APK + Linux only) started in parallel for the owner's phone build.
Counters as delta rows (J3 second half) change the sync format: left for after M6. Merge order: J2c → J1 → J2u → J3.
| # | Item | Agent | Branch | Depends on | Status |
|---|---|---|---|---|---|
| J0w | Watch ci run 40467776375 (APK + Linux) | ci-watcher | – | – | done (all green, dev release published) |
| J0a | Context pack J1: controller closures, globals, KeyStore, sub-states, memo keys, screens taking the controller | scout | – | – | done |
| J0b | Context pack J2 core: `pdf_text.dart`, `SyncEngine.run` apply loop, fuzz corpus | scout | – | – | done |
| J1 | `WalletControllerDeps`, `KeyStore` instance, Listenable sub-states, typed memo keys, view objects, `searchRows` into `searchAll` | ui-builder | j1 | J0a | done 89e4ebb (app 1820/0, desktop onboarding/plan/screens ok; forgetBrowser also clears stale sync status) → review (0 blocking, 5 low) → eb74b06 (j2-core merged, `_dataMark` = (repo, dataVersion) + sync_reload_test; test green: app 1821) |
| J2c | `pdf_text/` folder split; per-peer apply loop out of `SyncEngine.run` with asserts | core-builder | j2-core | J0b | done 422683b (pdf/ parts, `_applyPeer` + sealed result + asserts, `clockStats`) → BUG: stale view after a peer edit below max hlc → ef3d12c `repo.dataVersion` → review (0 blocking; 1 med for app: compare (repo, dataVersion); 4 low) → 3661414 (core 2584/0) |
| J2u | Screen sub-widgets, `AsyncAction` mixin, `PickedFile`, `bill_sheet` sections, `readCalendars` | ui-builder | j2-ui | J1 | done 7553029 (14 bill-sheet sections, Today ~20 widgets, readCalendars split, AsyncAction on 6 panels, PickedFile; test green, desktop screens/plan/flows/import ok) → review (0 blocking, 2 drifts) → f466144 (app 1822/0) |
| J3 | Mutation testing on importer + core pure code (tool script, no new package); surviving mutants → invariant tests | test-writer | j3 | J2c | done (tools a3c0b9e after review: work copy, invalid count, lib-only targets; tests 94fba4d: 34 killed, 8 equivalent, 0 bugs) |
| J4 | `packages/sync` split — only if J2c shows a clean seam | core-builder | j4 | J2c | done 2026-10-27 (e3b4093 + 3df97ae + 58e0015; merged 6b2c6b7; stage green) |
| J | Merge, review, stage run, push, STATUS | lead | v2 | all | done 2026-10-27 (J1+J2 77c5edb; J3 86b0b5a, test green) |

## Stage P6: split transactions (2026-10-25, spec `P6_SPEC.md`; schema 13)
| # | Item | Agent | Branch | Depends on | Status |
|---|---|---|---|---|---|
| P6-0 | Context pack (Tx/CategorizedTx, override, tags, consumers, payment sheet, TxTile) | scout | – | – | done |
| P6-C | Core: `split` entity, validation, `Categorizer.expand`, parts in money paths, whole rows in pickers, CSV/search | core-builder | p6-core | P6-0 | done 3d368b3 → review (2 med, 2 low) → 7921834 |
| P6-T | Spec tests (pure + repo + sync) | test-writer | p6-tests | P6-0 | done 0fbf069 |
| P6-U | App: split editor, Spending tile with parts, detail lists, broken split | ui-builder | p6-ui | P6-C | done d3d0e22 → review (1 med, 7 low) → 0806964 |
| P6 | Merge, review, stage run, push, STATUS | lead | v2 | all | done 2026-10-25 (stage green incl. perf) |

## Stage P4: recurring beyond monthly (2026-10-25, spec `P4_SPEC.md`; schema 12)
| # | Item | Agent | Branch | Depends on | Status |
|---|---|---|---|---|---|
| P4-0 | Context pack (recurring model, matching, money, app panels, tests) | scout | – | – | done |
| P4-C | Core: period classes, ranges, parts, `dueCycles`, long bills held in full, `addRecurring`/`updateRecurring`, schema 12, bill history per cycle | core-builder | p4-core | P4-0 | done 206a5b9 → review (2 high, 3 med, 4 low) → 2282153 → re-review (1 med, 1 low) → 4265dcc |
| P4-T | Spec tests (pure + repo) | test-writer | p4-tests | P4-0 | done d912197 (merged via p4-core; 4 test errors fixed, 14 tests moved to lead decisions) |
| P4-U | App: Expected bills (period, range, parts, instalments, held), Add/Edit bill sheet, Mark paid, Today line, history per cycle | ui-builder | p4-ui | P4-C | done ab55718 → review (1 high, 1 med, 3 low) → bc2e963 |
| P4 | Merge, review, stage run, push, STATUS | lead | v2 | all | done 2026-10-25 (stage green except perf host overrun) |

## Stage G: foundation — structure and practices (2026-10-22, `PATH_FORWARD.md` §4; behaviour-neutral, no schema change)
Owner direction: structure and practices first. Merge order: A → ui → tests → devops.
| # | Item | Agent | Branch | Depends on | Status |
|---|---|---|---|---|---|
| G0a | Context pack: `repo.dart` entity map / `_intCols` / DDL / migration / `_apply` / snapshot / export / search; barrel exports; dates/money helpers; recurring read side | scout | – | – | done (pack in lead scratchpad) |
| G0b | Context pack: controller renames, the three page-or-dialog copies, `_plain` copies, keyboard scaffolds, app bars, gate pages, `DateTime.now()` sites, platform-split names, the four CAR 6.4/6.8 bug sites | scout | – | – | done (pack in lead scratchpad) |
| G0c | Context pack: importer copy-pinned tests, `find.text` sites by file, font-skip test, `platform_test.dart` | scout | – | – | done (pack in lead scratchpad) |
| G0d | Context pack: `build.sh pub_ready` + `pub get` sites, ci.yml jobs, gradle release block, lockfiles | scout | – | – | done (pack in lead scratchpad) |
| GA | G1 typed entity schema + generalised migration + clocks lookup + `repo.dart` parts; G2 core/importer surface | core-builder A | foundation-core | G0a | done (69565f1 + 31eb42e; core 1233/0, importer 302/0; schema.dart + repo parts, show lists, isIsoDate, ReadResult, renames) → reviewed (clean; 3 low: pdf_text `_indexOf` clamp bug, one amount cap, IBAN sample comment) → same core-builder fixing (G2b). Note: `searchRows` additive, not yet wired into `searchAll` (search automation half done → J1 follow-up) |
| GU | G3 app surface; G4 the four sweep bugs with tests | ui-builder | foundation-ui | G0b | done (c435414 + dfe8029; app 970/0; 3 files renamed to _io; 4 G4 fixes with 5 tests) → reviewed (clean; 2 LOW: waitingTotal clock, sourceSkipped log spam) → G3b b6770b1 (both fixed, tests 90/0 targeted; full app run happens in the stage run) |
| GT | G5 tests by contract (importer messages, `ValueKey`s, font test fails, `meetsGuideline`) | test-writer | foundation-tests | G0c | done (8b4f002; importer 296/0, app 996/0; 40 guideline tests all pass — no I6 targets from it; 29 keys added to lib) → reviewed (6 findings: font-size probe + contrast control + habits sweep, 3 tautologies/dropped assertions, 1 skip reason) → G5b 3f14f1e: app 1078/0, importer 296/0; font-size probe + contrast control added; 44 known I6 failures skipped with widget names (Stage I6 targets) |
| GD | G6 local CI: changed-files test selection, parallel suites, persistent container/pub cache, pre-commit hook default, enforce-lockfile, pub workspace, R8, outdated/OSV step, release-notes template (D1: nothing in GitHub CI); G7 `tools/lsp.py refs|def` over `build.sh lsp` for the scout | devops | foundation-devops | G0d | done (91acffc + 605c689; 60 s widget cap via flutter_test_config, analyze/stage/outdated commands, no-poll hook + self-test in lint, enforce-lockfile, R8 explicit (size unchanged), lsp.py ~5–9 s/call; pub workspace rejected: breaks sqlite3mc hooks + relay image) → reviewed (6: hook misses multi-line loops + false positive on --timeout, apk/linux build skip enforce-lockfile, R8 comment wrong (plugin already minifies), release-notes window, lsp.py stderr/None-length) → G6b aaf483a (all six fixed; lint green) |
| G | Merge, reviewer (checklist = `PATH_FORWARD.md` §5), Haiku full run, push, STATUS | lead | v2 | GA, GU, GT, GD | merged into v2 (1592e41 core, foundation-ui, tests e271ab1 with 4 conflicts resolved, devops 2187b5b); app wired to the renamed core (29896fc, analyze clean); stage run 2026-10-23: 2 red (goal/expense sheet tests on the old 10-billion cap → 1 billion = core's one cap; screens privacy check matched a log timestamp `:12.993` → timestamps stripped first), both fixed and re-run green; emulator screens unchanged; merge delta reviewed; pushed |

## Stage H: hardening before M6 (after G; `PATH_FORWARD.md` §4 H1–H13; one schema bump → 8, one protocol doc bump)
Merge order: B → A → devops → tests → ui.
| # | Item | Agent | Branch | Depends on | Status |
|---|---|---|---|---|---|
| H0a–d | Context packs (money paths; sync marker/409/hlc/vault/local_db/relay meta/signing; manifest/gradle/relay options/key_store_io; sim + relay + importer tests) | scout | – | G | done (packs + API contract `H-API.md` in the lead's scratchpad: wire create-token/v3 signing/instance id/404, core names per builder, app list) |
| HA | H1 currency filter, H2 paydayPassed/overBy/affordability/lowIncome/income parts, H3 per-key budgets + patterns (schema 8), H4 PBZ header/FILEPASS/idCollision/import caps | core-builder A | harden-core | H0a | done (ddffda5 importer + 50970ba core; core 1280/0, importer 315/0; currency param on sums incl. suggestBudgets/salaryPaydays, paydayPassed/overBy/overToday/overBudget/lowIncome, samePaydayDays 7, schema 8 rows `budget:<cat>` / `pattern:<16 hex>` migrated with the legacy row's clock, maxImportBytes/xlsx 64 MiB cap/passwordProtectedMessage, collisions count) → reviewed (2 medium: stale legacy map with a newer clock revives removed budgets at migration; foreign-currency recurring bills reserved from EUR money; 1 low: damaged pattern row logged with a reversible SHA-256 id; test gaps) → HAb dc37a43 (migration skips ids with any row + one transaction; recurring detection/payment per currency; damaged rows logged under the map key; test gaps; timestamps stripped in log tests; core 1288/0, importer 316/0) → HAc 9b3be86 (same id twice in one batch: first wins, later counted as collision; core 1289/0) |
| HB | H5 relay instance id + fingerprint, H6 device id per install + `deviceIdInUse`, H7 bounded HLC `clockDrift`, H8 BWOP2 AAD + inflate cap + cipher pin + `bw-relay-v3` + delete-wins table, H9 field-pair repair + re-entrancy docs | core-builder B | harden-sync | H0b | done 4786967 (core 1256/0, relay 145/0, web compile ok; streams `<id>`/`<id>-<n>`, api 3, syncReaderVersion 2) → reviewed (2 high: after a 409 the next run writes into the other install's stream; a restored database stops uploads for good; 2 medium: old relay shows "another key" instead of older/newer API, H7 guard can lock the wallet via restore/open-time migration/run; 3 low: old id blocks pruning, flagged install acks the shared stream, epoch name reuse after a double restore) → HBb b94a502 (self-healing streams `<id>-<n><6 letters>`, deviceIdInUse informational, every other stream read as a peer, acks under every stream written, owner-only clock guard with `_writeInternal`/`_asInternal`, `BackupFailure.clockAhead`, 401 → health → older/newerApi; no move on a higher-epoch same-id stream (avoids clone ping-pong, accepted); core 1263/0, relay 146/0) → re-reviewed (1 high: double restore of database + relay from one moment lets an offline peer skip reused seqs; 1 medium: id change on a copied database acks under the original's stream → early prune; 2 low; app compile arm for `clockAhead` = lead at merge; decision: owner-write clock guard on this device's own wall-clock high-water mark) → same core-builder fixing (HBc: ack-rollback detection); test-writer aligning two tests (HTc). Trial merge B → A clean; devops conflicts in relay_server.dart `_Sig` (keep method + host), test support.dart (all four fields), RELAY_PROTOCOL.md (both). Was: (session model/high; also owns relay signing.dart + wallet.dart; + H5b: test-writer found that a relay restored from an older copy loses edits made after it (seq reused with other content) → per-device stream epochs) |
| HD | H10 Android defaults + keystore fail + QR-only default, H11 relay token/trust-proxy/HEALTHCHECK/read-only/HEAD/500 + TLS path (D5) + key file umask | devops | harden-platform | H0c, D5 | done (3f7ad77; relay 158/0, signed APK ok, release without key refused, Caddy + quadlets validated; create token, trust-proxy, public-host flag (stub until HB), HEAD, 404 missing, health check, read-only; Android backup off, system CAs only, `bw/secure` channel; desktop key file 0700/temp/rename) → reviewed (2 medium: placeholder token accepted as real, Caddy error log keeps token/wid/IP on a 5xx; 6 low: token in Caddy env, 403 without body drain, firewalld step, device_* backup domains, key file modes only on write, unknown trust-proxy value = off) → HDb c7b11ff (all 8 fixed: placeholder refused, Caddy error log excluded and verified against a 502, token as podman secret, body drained, firewalld step, device_* domains, modes on read, strict trust-proxy; relay 161/0, key store 7/0) → waits for merge after HB, HA |
| HT | H12 scenario / invariant / equivalence / fault-injection / fuzz / KAT / bomb / fixture tests (from the spec, `skip: 'BUG: …'` until HA/HB land) | test-writer | harden-tests | H0d | done (57836a9; all packages green on v2 with `BUG: H<n>` skips, many lifted by run-time probes in `support/h_compat.dart`; old-build schema-7 .db/.bwb fixtures + generator; bugs found: H5b relay restore loses edits, H9 paid_tx kept after unlink / one payment two bills / no repair / run not re-entrant, relay `.tmp-*` not cleaned on load → all to B) → reviewed (2 high: old-build fixtures carry real clocks (fail after H7), Android checks skip on what they assert; 3 medium-high/medium: xlsx bombs pass without a cap, payday probe can skip forever (decided: 29..31 → 28, 0/32+ → 15), weak prune check; + boundaries, schema-7 upgrade with rows, AAD constants, fixed ids, disk-full restart, names) → HTb 8ab987d (all fixed; verified against harden-sync/-core/-platform archives; found HAc: same id twice in one batch with another amount overwrites → A fixing); → HTc f8e543a (stream lookup via `syncStream`; clone test rewritten as convergence + one informational deviceIdInUse); hard skips to lift at merge listed in the lead's `merge-H-skips.md`; emulator backup test not covered |
| HM | Merge B → A → devops → tests | lead | v2 | HA–HT | done 2026-10-23 (relay `_Sig` keeps method + host, stub publicHost dropped, schema-8 migration via `_writeInternal`, hand skips lifted, app wired: aad, currency params, per-key budget writes, clockAhead/overBudget arms; found at merge: the spec-test per-key probe could never see an extension method (fixed), app test helpers wrote whole-map budgets (fixed), delivery panel says "money used" once payday passed (→ HUa); full test green 333d6bc: importer 335, core 1440, relay 200, app 1113) |
| HU | App halves (brief `HU-brief.md` in the lead's scratchpad): lead wires the compile fixes at merge (aad in key_vault, `currency:` params, per-key budget writes); then two ui-builders in parallel: **HUa** money screens (lowIncome/clamp, Verdict.overBudget, paydayPassed/overBy/overToday, foreign "not counted") and **HUb** sync + identity + key (device id next to the key, fingerprint/relayChanged/deviceIdInUse/clockDrift/createToken texts and field, ClockBehindException, http only for private hosts, QR-first key sheet + `bw/secure`, restore a backup made with another key) | ui-builder ×2 | harden-ui-money, harden-ui-sync | merged H | HUa done 80b00b0 (Today ended/over states, startNewPeriod, delivery wording, ForeignNote on Today + Spending, Wishlist overBudget/ended, Plan lowIncome + no clamp; app 1131/0) → reviewed (MED-HIGH "On plan" while over the plan; MED core: an ended period counted the next period's rows → lead fixed in core c4296e0 + `currentPeriodStart`; MED one tap per missed payday, Plan heading prints negative money; LOW K19 second button in the main panel, pace contradiction, small overspends rounded to 0, foreign line wording; demo wallet depends on the real date) → HUab b686e8c on v2 merge fcfcb96 (all 8 fixed, fail-before verified; own period-ended panel, currentPeriodStart, no negative Plan heading, pace hidden without money, exact small overspends, foreign "spent/received", demoWallet payday 28 + demo data sweep; app 1141/0; note: `find.text` never matches a StatusLabel (rich text), static texts unaffected on v2) → merged 8050489; HUb done 353af7b (Plan › Sync fingerprint/relayChanged/deviceIdInUse/clockDrift/createToken field, central clock-behind dialog, http only for private/.local/dotless hosts (stored addresses read leniently), QR-first key screens with `bw/secure`, restore a backup made with another key, device id in the key store moved once; app 1162/0, desktop relay_sync + onboarding ok; web store and FLAG_SECURE unverified on device) → reviewed (2 medium: three catch-alls swallow ClockBehindException in imports/bills/skip, key scanner pops per code; 3 low: octal/decimal numeric hosts bypass the private rule, stored public-http address silent + token sent in clear, old-key dialog without SecureWindow; lead: sync notices stay until dismissed) → same ui-builder fixing (HUbb) |
| H13 | Docs: version table, threat model, rotation, backups/blobs, relay restore warning, metadata, limits, §8 corrections, household recipe, bill corpus location | lead | v2 | HB | drafted in `docs/TECHNICAL_SPEC.md` (§8 corrections + household recipe, §9 threat model/crypto/permissions/limits incl. rotation via "restore a backup made with another key" (HU), §10 bill corpus); version table and §11 sync limits after HB merges |
| H | Merge, reviewer, Haiku full run, emulator screens, push, STATUS | lead | v2 | HA, HB, HD, HT, HU, H13 | done 2026-10-23: whole-stage review (no code defects; fixed: date-dependent delivery test, real-relay tests for create token + public host, pre-H web key unwrap test, 5 doc statements; K19 layout call → owner checklist); stage run: desktop Plan failed twice (typed payday 45 saved 15 after the app clamp was removed → clamp restored; `sync.done` field order) + QR-first key step in plan_test, fixed and re-run green; screens read (Today over-plan honest, Plan "Nothing to spend"); Stage I note: Plan's "Spending money −87 €" ledger total stays signed |

## Stage I: UI quick wins (after H; `PATH_FORWARD.md` §4 I1–I9; no schema/protocol change)
Spec with fixed names and keys: `I-spec.md` in the lead's scratchpad (2026-10-23; resumed after a session reset, agents continue their partial worktrees). Unlink on a matched expense is NOT in
this stage (owner decision D2 pending, and it needs a synced field); the "matched" mark is read-only.
| # | Item | Agent | Branch | Depends on | Status |
|---|---|---|---|---|---|
| I0a/b | Context packs: theme/type/layout (I6, I7); states/copy/flows (I1–I5, I8) | scout ×2 | – | H | done (I0a: 40 of the 44 I6 skips = the 11 dp bottom-bar label; I0b: no undelete/relay usage in core, wish named from the category, toast 3/6 s, Add expense defaults to Groceries) |
| IC | `allowanceTomorrow`, `undeleteTransaction/Goal`, relay usage in state (`bytes`/`maxBytes`, additive) | core-builder | quickwins-core | H | done ba07f28 (core 1463/1 → the 1 = real-date test on v2, fixed ad18354; relay 201/0; extra: device-local `undo.<txId>` relinks a bill on undo) → reviewed (1 medium: undo while not caught up double-counted a matched entry / transfer pair; 2 low: §4.10 rows, loose usage test) → ICb 5c804ac (all fixed, core 1466/0 with ad18354) |
| IUa | I6 type tokens + 48 dp + grid + compact TxTile + Upcoming/Wishlist/desktop strip + delivery gate + dark toggle + explainers; I7 persistent add action | ui-builder | quickwins-ui-layout | I0a | done 7742a2b (app 1216/0, desktop layout 6/0; all 44 I6 skips lifted; keys addFab, appBarSearch, explainerInfo, themeMode, emptySection:<title>; look_panel.dart) → reviewed (1 high: theme rebuilt + lerp on every notify; 2 medium: explainers marked seen on hidden tabs, search pad under FAB; 3 low) → IUab 3495944 (all fixed, app 1223/0) → merged into v2 5fed455 (after core be1cdcd) |
| IUb | I1 over states + one setup panel; I2 wish naming; I3 set-aside ledger row; I4 toasts + Undo; I5 forms; I8 honest states | ui-builder | quickwins-ui-states | I0b, IC | done 7e85c60 (merged core 5c804ac; app 1219/0; ui_states_test 19; 1 new contrast `_known` skip (Plan dark, € suffix 3.47) → IUa/I6; no test for ledgerSetAside / real write-fail hook) → reviewed (1 high: write-failed toast hidden under phone sheets; 2 medium: Undo toast not persistent for TalkBack, every SqliteException incl. reads says "Couldn't save"; 7 low: ledger rounding misses total, −0.10 € heading, Review delete without Undo, weak last-day test, setup never re-opens, dead code) → builder looped re-sending its report, stopped; fresh ui-builder IUbb merges v2 + fixes all → d8da5a1 + 91174c1 (+ lead e54d176) |
| IT | Widget + core tests from the spec | test-writer | quickwins-tests | I0a, I0b | done 4ebd396 (65 tests in 6 files, skipped until built: core @Skip I1/I2/I8, relay `_skip`, app `_skipOver/_skipSetup/_skipLedger/_skipWish/_skipToast/_skipForms` → lift at merge; relay 205/0) |
| I | I9 dark frames + emulator screens read; merge, reviewer, full run, push, STATUS → owner starts `ci` for the M6 build | lead | v2 | IC, IUa, IUb, IT | done 2026-10-23 (merged core → layout → states (IUbb merged v2, 11 hunks) → tests; lead: write errors marked by core (`isWriteError`), explainer above CTA; merge-delta review: 1 high (I8 test tap off screen), 1 medium (disk-full write lost its mark behind a failed ROLLBACK), 2 low → fixed e4254d8; stage run red on old integration tests (category pick, setup panel, exact cents) → II 31e914e: desktop 11/11, emulator ok; final test: importer 335, core 1501, relay 206, app 1282; dark frames read) |

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
| R8a | Review fixes core/relay: M1 local import/delete reconcile ignores caught-up gate; M2 unblock on transient GET + older-schema snapshot; L5 refused snapshot re-downloaded each run; L6 first upload >16 MiB never syncs (split into ≤8 MiB parts); L7 relay buffers bodies for unknown wallets | core-builder | review | done (3b810b1, 008c6f4, 0c9f58a, 231a36d; core 882, relay 99; merged) |
| R8b | Review fixes app: K join merges an unopened plaintext wallet.db (set aside instead); M3 web forget deletes set-aside copies; L4 create writes key before set-aside; L8 setRelay during a sync not followed up | ui-builder | review | done (4d37bc3, test green app 755, web-test 9; merged) |
| R9 | Integration tests failing in the stage run (plan: StatusLabel finder; screens: backup log without the save dialog); app correct | ui-builder | full run | done (22ccb01) |
| R | Review (0 high, 3 medium, 5 low, all fixed), full run green (unit 193/882/99/755, desktop 12, web 9, perf 0 missed, emulator screens), merged into v2, pushed | lead | R1–R9 | done 2026-10-22 |

R6 recipe (from R1): native `sqlite3.open(path)` then `PRAGMA key = "x'<64 hex>'"` right after open; plaintext → encrypted
in place = open unkeyed + `PRAGMA rekey`. Web: `registerVirtualFileSystem(fs)` **without** `makeDefault`, open with
`vfs: 'multipleciphers-${fs.name}'`, then `PRAGMA key` (makeDefault gives "Encryption is not supported by the VFS"); after
`unregisterVirtualFileSystem` (forget) the next `IndexedDbFileSystem` needs a new `vfsName` (else "null function"); check
opening an existing unkeyed IndexedDB db via the wrapped VFS. Wrong/missing key: `PRAGMA key` succeeds, the first read
throws `SqliteException` extended code 26 "file is not a database".

## Stage F: future spending (2026-10-22, spec DESIGN_DECISIONS §4.3, API `FUTURE_SPENDING_API.md`)
| # | Item | Agent | Depends on | Status |
|---|---|---|---|---|
| F0 | Context pack | scout | – | done |
| F1 | Core: `planned` entity (schema 6), reservation in computePeriod, .ics parser + export, amountFromText, upcoming(), paidCandidates(), headsUps(), settings, search | core-builder | F0 | done (b150671, core 1024 incl. F2; merged) |
| F2 | Spec tests for the money logic and parser | test-writer | F0 | done (71a7d07, green in F1) |
| F3 | App: Upcoming screen, Today "Coming up" + heads-up, entry sheet, Plan › Calendars (Android calendar plugin, .ics import/link), heads-up notifications, export .ics, demo data | ui-builder | F0 (codes against the API, shims until F1) | done 2d00e82 (plugin device_calendar_plus; Android declares READ+WRITE_CALENDAR, app only reads) |
| F | Merge F1 → F2 → F3, review, full run, push | lead | F1–F3 | done: full run green (test, desktop, web, perf, screens); review: 10 findings → F4; after F4 full run green (app 853, core 1036), pushed |
| F4a | Review fixes, core: content-based calendar refs (same on every device/source), .ics parse step budget + linear unfold, dismiss keeps title | core-builder | F | done cc6955d (step budget lowered to 10⁶ by lead for slow phones) |
| F4b | Review fixes, app: Confirm keeps category, clear category, Set aside = reserved, link fetch overall timeout + no https→http, late heads-up, serialized reschedule, cancelled Android events, Paid/Skip undo | ui-builder | F | done 5b6cd76 |

## Stage S: relay hardening + docs (2026-10-22)
| # | Item | Agent | Depends on | Status |
|---|---|---|---|---|
| S1 | Relay protocol v2: signed requests (Ed25519 from the wallet key, relay keeps the public key only), replay-harmless writes, clock-skew retry; server + `RelayTransport` + protocol doc; folder backups removed | core-builder | – | done (c5944c7, cd6169d; relay 115, core 882, app 770) |
| S2 | Docs: README, docs/setup.md, docs/architecture.md, DESIGN_DECISIONS §2 diagram, wallet_core CLAUDE.md backup notes still describe Syncthing | general-purpose (sonnet/medium) | – | done (8389317, labels fixed by lead) |
| S3 | Key backup prompt (gap 7): the encrypted db and relay make the wallet key the only way back | ui-builder | – | done (b9c15a1, app 770, desktop onboarding + emulator screens ok) |
| S4 | Lead: `tools/relay.sh` health on `/v2/health`; app text for an older relay (`olderApi`) | lead | S1 | done |
| S5 | Review M1: key clipboard clear fails on Android in the background; selectable key text skips the clear; layout test scroll fixes | ui-builder | review | done (607eda2) |
| S6 | Review L3: cap the relay clock offset at 24 h; DoS note in the threat model | core-builder (sonnet) | review | done (c25e5d8, app text fc78acc) |
| S | Review (0 high, 1 medium, 4 low, all fixed), full run green (perf re-run on an idle laptop: the first run was under load), pushed | lead | S1–S6 | done 2026-10-22 |
| F0 | Future spending spec (§4.3), owner open questions: calendars, default amounts, heads-up | lead | – | done (owner answers 2026-10-22; Stage F table above) |

## Stage B: bills database (2026-10-22, spec DESIGN_DECISIONS §4.2, API `BILLS_API.md`, relay blobs in `RELAY_PROTOCOL.md`)
| # | Task | Agent (model/effort) | Depends | Status |
|---|---|---|---|---|
| B0 | Context pack; owner answers (packages mobile_scanner, ML Kit text, receive_sharing_intent; receipts, slips, PDFs first); API + protocol; `NormalizedBill` model | scout (haiku/low), lead | – | done |
| B1a | Readers in wallet_importer: fiscal QR, HUB-3, UBL e-invoice, PDF text layer, billFromText; synthetic fixtures | core-builder (opus/high) | B0 | done 31b7a5a (importer 295), merged b4ba240 |
| B1b | Core: `bill` entity (schema 7), importBill/confirm/link/delete, planned row per unpaid bill, auto link by reference, billCandidates, reminders, Upcoming warranty/returnBy, BlobStore + transport blobs + SyncEngine upload/delete, search | core-builder (opus/high) | B0 | done 6224fef (core 1177 incl. B3), merged 0e831de |
| B2 | Relay: blob PUT/GET/DELETE, byte count, state `blobs`, CORS DELETE | core-builder (sonnet/medium) | B0 | done 0368859 (relay 138), merged e49187a |
| B4 | App: Scan bill (camera, QR/PDF417, OCR), Plan › Bills, share to app, bill sheet, link, cash expense, Android PdfRenderer channel, Today row, Upcoming + reminders | ui-builder (sonnet/high) | B0 (codes against the API, shims until B1) | done b2c950f (app 918; APK 116 MB, was 60), merged ce8b53a |
| B3 | Spec tests for readers, linking, blobs | test-writer (sonnet/medium) | B0; starts when a slot frees | done 7a68973 (150 tests, compile after B1; cache test to shrink: use a small LRU limit, not 15×14 MiB) |
| B | Merge, review, full run, push | lead | B1–B4 | done: 2 reviews (3/4/3, then 2/0/3), fixes B5a–c + B6, full run green, pushed; review branch |
| B5a | Review fixes, core: category needed to reserve + suggestBillCategory, HUB-3 id per period + importBill asNew, unlink deleted tx across devices, invoice token length, orphan blobs, no transfers in candidates | core-builder (opus/high) | B | done e5d7b20, merged b39e7c3 |
| B5b | Review fixes, app: category picker, "Add as new bill", Upcoming opens the bill, size checks + share cache cleanup, pdfText in an isolate, Take photo via system camera, reminder days UI, blobs waiting in Sync | ui-builder (sonnet/high) | B | done 28f461c, merged 51b1d87; stand-ins → core running |
| B6 | Follow-up review fixes: category on cash expense, no silent reserve, slip near payday, one reserve rule (`plannedReserves`) for Today/Upcoming, needs-a-category marks, demo data, photo cache | core-builder (opus/high) | B5 | done 7f10330, merged 7a80d8f |
| B5c | APK size: arm64 + x64 only (tools, ci, release), breakdown | devops (sonnet/medium) | B | done cb261a0 + a227dc3: local 86 MB (arm64+x64), published 44 MB (arm64) |

Stage R notes: the haiku watcher stopped twice before finishing (it hands back while waiting on its own background run); the
lead ran the remaining suites with one background command. Worktrees from `isolation: "worktree"` start on `master`:
every brief must begin with `git reset --hard <base>`.

## Stage W progress (2026-10-21)
- W1–W3 merged into local `v2` (925d546, 3071b53); scouts used for W2/W3 (29k + 47k tokens), builders 46k + 75k.
- Review: 2 findings. Low (wasm pin trust-on-first-use) fixed 1c7086c; medium (two tabs overwrite the wallet) → W4 running.
- Also fixed: nudge slots already past in the phone zone failed the whole schedule (c516b03).
- Done: W4 merged (40c3628), Haiku full run green, web build + localhost shots read, pushed. Next: sync redesign spec (owner decisions).

## Stage Q progress (2026-10-27)
Plan: `STAGE_Q_PLAN.md` (Q1–Q11, waves 0–3, delegation table). Base eaa790f.
- Wave 0 done: controller split b956c4c (review clean) → 2ee1574; repo split 130e413 (review clean) → fae77a3; CLAUDE.md c227cc8. Full test on c227cc8 running.
- Wave 1 done: Q2 166000c → f129f70; core B a84be90+fc49576 (review: 2 med, 1 low fixed) → 483e66a; core C 88ddd8c+9bd7251+816fbac (review 4 + re-review 4 incl. 1 high snapshot replay, fixed) → e02bf23; core A a79376f+2f4de44 (review 8 fixed) → merged; IOU amount caps b9eaf45. Check green: importer 400, core 2528, sync 327, analyze all.
- Wave 2 done: UI Y e4f9bfe+0b0e1ae (review 2 bugs + 2 small + screenshot fixes) → 363092f; spec tests 0e2fb46 → e904bd5; UI X 264c2c5+52026ac+5efcb4e (review 8 + merge-delta 3) → 1da6bf1.
- Wave 3 done: mutation invariants bb149f6 → 2c01b45; stage run green except relay_sync desktop test (finder too broad after Q9) → fixed 3b578bb; final test + desktop import/screens/plan/relay_sync green. Stage Q done 2026-10-27.
- Wave 2 note: extension members are only visible where their library is imported; public controller methods called from tests stay on the class.

## Queue (2026-10-20)
| # | Item | Agent | Base | Depends on | Status |
|---|---|---|---|---|---|
| B1 | Commit Stage A leftovers, Haiku full run, push | lead + haiku | v2 | – | committed d632e32; run in progress |
| B2a | Adaptive layout finish + edge tests + month-chip fix | ui-builder | agent-a7db2fe… | – | done (6ebb9bc) |
| B2b | Goal contributions merge + sync quarantine + transport + edge tests | core-builder | agent-a99ad86… | – | done (804961d, core 564/0) |
| B2c | Parallel desktop tests (BW_JOBS) | devops | agent-aefe0df… | – | done (8e212c1) |
| B2e | BUG: desktop plan test typed a missing folder (test bug since 561d768) | ui-builder | agent-a7db2fe… | – | done (2759d5c) |
| B2d | `paydayDone` → `payGoals(period:)`; pass appVersion to FolderSync | lead | stage-b | B2b | done (c1dd111, app 446/0) |
| B2 | Merge B2a–e on `stage-b` (done), review (done, fixed: 6d273f4), test+desktop green on a275d29, perf step hangs (D1d), emulator running, then push | lead | stage-b → v2 | B2a–e, B1 | done |
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
- One full run per stage (`tools/build.sh stage`, Haiku reads the summary); builders end with lint + their own suite, never the full `test`.
- A `:one` run over 2 min or a suite over 5 min is a hang: stop it, fix the test; never re-run unchanged (hangs cost ~4–5 h in the first four days).
- When the UI half is the long pole, split it over two ui-builders on disjoint files from the pack.
- No polling anywhere: background runs + notifications, Monitor for other processes.
- Say the model/effort choice before starting agents; cheapest that does the job.
- Bugs found by any agent are fixed in the same stage with a reproducing test.
- STATUS.md is updated at the end of every stage; this file at every queue change.
