# Budget Wallet — path forward (2026-10-22, from the six outside reviews)

Source: `docs/review/` — system design, system architecture, security, code architecture, feature parity, UI/UX. All six
were read in full and every "before M6" finding was re-checked against the tree on 2026-10-22 (all still open). This file
turns them into one ordered plan; `PIPELINE.md` holds the live queue, `STATUS.md` the state. Owner decisions are in §7.

## 1. What the reviews agree on

**Verdict (all six): continue on this codebase; do not restart; do not change the sync or state model.** The expensive
decisions are right and in place: offline-first with a content-blind relay, one write path feeding a per-field change log
with hybrid logical clocks, pure-Dart core, integer cents and `YYYY-MM-DD`, "suggest, the owner confirms", the Ledger
design system under contrast and overflow tests, API docs before code. The replication kernel is correct in the code read
and backed by randomised convergence tests; nobody without the key can read or change anything.

What is wrong is at the edges and almost all of it is cheap:

| Area | Wrong today | Why it matters for one owner |
|---|---|---|
| Money | Non-EUR rows summed as euros; past-payday state pours the remaining flex into "today"; negative flex makes every wish affordable; over-budget copy prints negative denominators | The daily number is wrong for days each month; the first thing a real pay period hits |
| Sync identity | No relay identity; device id inside the database; HLC unbounded | Silent op loss on relay restore/switch; a cloned install never sees its twin; one bad clock poisons every device |
| Concurrency | `categoryBudgets` / `merchantPatterns` are one map under one key | Two devices editing different budgets offline lose one |
| Crypto / storage hygiene | No AAD or domain separation on sealed files; SQLite cipher not pinned; Android backup on; debug-key fallback in release; cleartext app-wide | Not exploitable today, but each is a one-line fix that stops being one later |
| Relay | Unauthenticated wallet creation; rate limiter collapses behind a proxy; plain HTTP as the documented default | Denial of service on a LAN; the recommended deployment breaks the limiter |
| Product | Calendar-month budgets on payday periods; fixed 20 categories; narrow recurring detection; no accounts/balances, splits, reports, rules screen | Parity gaps a daily user hits in week one |
| UI flow | Over-budget state undesigned; wish named after the category; Plan ledger does not foot; toasts outlive context; add action only on Today | Trust: a ledger that does not add up |
| Process | Nothing has run on a real phone; no human has used it for a pay period | The one blind spot every review names first |

## 2. Requirements, restated after the reviews

Functional (unchanged): safe-to-spend today on a payday period with reserved future costs; bank files in (PBZ, Revolut);
bills as documents; wishlist cooling-off; weekly review; goals; encrypted multi-device sync through a self-hosted relay.

Non-functional, now explicit:
- **Correctness of money over everything**: a number shown is either exact or labelled as a guess; never negative
  allowances or denominators; foreign currency never counted as home currency.
- **No silent data loss under realistic faults**: relay restored from an old image, relay swapped, device cloned, a device
  with a wrong clock, two devices editing offline. Each must be detected and shown, or converge.
- **Platform defaults safe by default**: no OS backup of the encrypted DB, no cleartext to arbitrary hosts, no debug key.
- **Scale**: one household, 20k rows, 16 wallets per relay, 1 GiB per wallet. Nothing needs to grow; keep it simple.
- **Constraints**: one owner, agents build, owner tests at the end; Linux + Android (+ local web); no new packages
  without asking; CI manual (owner, 2026-10-21; see §7 D1).

## 3. Architecture after the changes (what moves, what stays)

```
 ┌────────────────────── holds the wallet key ──────────────────────┐      ┌──── sees ciphertext + metadata ────┐
 │ Phone ─ enc. SQLite (cipher PINNED)   device id NEXT TO KEY (H6)  │      │ Relay                               │
 │ Laptop ─ enc. SQLite, key file 0600 in a 0700 dir (H11)          │──────│  GET state → {api, instance id (H5)}│
 │ Web ─ parked (D3), still builds                                   │ TLS  │  creation token (H11)               │
 │                                                                   │ by   │  limiter per client behind proxy    │
 │ one write path ─ per-field HLC, BOUNDED (H7)                      │ def. │  files BWOP2 with AAD (H8):         │
 │ settings: one row per budget / pattern (H3)                       │      │   "bw-sync-file\n<dev>\n<seq>" …    │
 └───────────────────────────────────────────────────────────────────┘      └─────────────────────────────────────┘
```

Everything else (op log, LWW, snapshots + ack-gated pruning, blobs outside the op log, Ed25519 + TOFU, ChangeNotifier +
version cache + IndexedStack, Navigator 1.0, hand-written readers, deterministic ids) stays as built. Blob invariants
(upload-before-ack, server-side GC) are a second protocol bump and wait for after M6 (P14).

## 4. The plan: four stages, then the owner

Order rule from the reviews: **fix what the live test would trip over, then test for one pay period, then build product
on what the test surfaced.** All schema and protocol changes land in one stage (H) so devices upgrade once.

### Stage H — hardening before M6 (one schema bump → 8, one protocol doc bump; ~1 week of agent time)

| # | Item | Where | Agent |
|---|---|---|---|
| H1 | Count only `currency == settings.currency` in `computePeriod`, `monthSummary`, `periodSummaries`, category sums; return `foreignByCurrency` for a "foreign, not counted" line | `budget.dart`, `periods.dart`, `categories.dart` | core-builder A |
| H2 | Explicit `paydayPassed` period state instead of `daysLeft.clamp(1, …)`; `planDaily ≤ 0` → affordability "over budget", never "now"; core returns `overBy` so screens never print a negative allowance or denominator; `lowIncome` heuristic and payday clamp move from `plan.dart` into core | `budget.dart`, `periods.dart`, `today.dart`, `plan.dart` | core-builder A (+ ui in I1) |
| H3 | One settings row per category budget (`budget:<category>`) and per merchant pattern; migration from the maps; schema 8 | `models.dart`, `repo.dart`, `controller.dart:590` | core-builder A |
| H4 | `PbzProfile.detect` requires the full header tuple on one row; `repo.idCollision` logged when a "duplicate" id differs in amount or description; 20 MB cap on `importBankFile`; inflate cap in `XlsxReader` | `pbz.dart`, `repo.dart:740`, `importer.dart`, `xlsx_reader.dart` | core-builder A |
| H5 | Relay instance id: random id per relay (persisted in `meta.json`), returned by `GET state`, stored with the upload marker; a change = first connect (full-state upload, cursors reset). Protocol doc + threat model updated | `relay/lib/src/wallet.dart`, `sync_engine.dart:578`, `RELAY_PROTOCOL.md` | core-builder B |
| H6 | Device id per install, stored next to the key (not in the DB); `WalletRepo.open(deviceId:)`; a 409 on an own seq is surfaced as `SyncProblem.deviceIdInUse`, never retried silently | `repo.dart:128`, `sync_engine.dart:610`, key store (app, small) | core-builder B + ui-builder |
| H7 | Bounded HLC: files whose max HLC is > 1 h ahead of wall time are quarantined with reason `clockDrift`; local writes refused when the wall clock is that far behind the stored clock; shown like `clockSkew` | `hlc.dart`, `sync_problems.dart` | core-builder B |
| H8 | `BWOP2`: AAD per use (`bw-sync-file\n<device>\n<seq>`, `bw-snapshot\n<id>`, `bw-backup`, `bw-blob`, web key wrap); 256 MiB inflate cap in `unseal`; `PRAGMA cipher` pinned before `PRAGMA key`; relay host in the signed text (`bw-relay-v3`) | `vault.dart`, `local_db.dart`, `sync_relay.dart`, `signing.dart` | core-builder B |
| H9 | Field-pair repair: `planned.paid_tx` meaningful only when `status == paid` (readers); `bill.linked_tx` unique across live bills repaired when caught up like transfers and matches | `repo.dart:1387`, `sync_engine.dart` | core-builder B |
| H10 | Android: `allowBackup="false"` + `dataExtractionRules`; `network_security_config.xml` (cleartext only for private ranges / the configured relay host); release build **fails** without a keystore; `FLAG_SECURE` while the key sheet is open | `AndroidManifest.xml`, `build.gradle.kts:62`, `key_backup.dart` | devops (+ ui for the flag) |
| H11 | Relay: `--create-token` (header on the first `PUT d/<device>/1`) or wallet allow-list; `--trust-proxy`; `HEALTHCHECK`; read-only container except `/data`; `HEAD` handled; TLS as the documented default path (Caddy sidecar in the quadlet or `tailscale serve`), plain HTTP = dev mode; desktop key file: dir 0700, temp + chmod + rename | `relay_server.dart`, `bin/relay.dart`, `Containerfile.relay`, `setup.md`, `key_store_io.dart` | devops |
| H12 | `--enforce-lockfile` on every `pub get` in `build.sh` and CI; mixed-build policy ("all devices within a week") and the schema-bump replay in a release-notes template | `tools/build.sh`, `ci.yml`, `docs/` | devops |
| H13 | Tests from the reviews' gap lists: relay A→B→A, relay restored from an older image, cloned device id, future clock, concurrent budget edits, concurrent `linkBill`, schema-7 reader on schema-8 files then upgrade, zero ops on the second full round of the simulation, invariants `ack ≤ cursor ≤ last` / `covers ≤ cursors` / transfer symmetry, memory-vs-real-relay model equivalence, fixed-key fixed-nonce vectors for `seal`, decompression bomb for `unseal` and `.xlsx`, PBZ header fixture from another bank, "same month, newer template" fixture per bank, an old-build `.db`/`.bwb` fixture committed per release | `packages/*/test`, `relay/test` | test-writer |
| H14 | Docs: version table (relay api, magic, payload, reader, schema, app) into the spec; threat-model additions (clone, wrong clock, lost device); key rotation procedure (backup → new key → restore → re-point, delete the old relay wallet); blobs not in backups; web `sessionStorage` note; Dart cannot zero memory; relay metadata correlation | `TECHNICAL_SPEC.md`, `RELAY_PROTOCOL.md`, `setup.md` | lead |

Run: scouts (haiku/low) for A, B, devops and test-writer → the four builders in parallel (cap 4; ui-builder's two small
items wait for a slot) → merge order B → A → devops → tests → reviewer (session model/high) on the stage diff → fix findings
→ haiku/low full run (`test`, `desktop-test`, `perf`, `emulator screens`) → push → STATUS.

### Stage I — UI quick wins and surface hygiene (~2–3 days; no schema or protocol change)

| # | Item | Agent |
|---|---|---|
| I1 | Over-budget state on Today and Plan: "You're X € over for today. Nothing more today; tomorrow starts at Y €" (uses H2's `overBy`); first-run panels become one panel below the hero or one collapsed line after the first dismissal | ui-builder |
| I2 | Wish named from the note, or ask for a name; never the category (`sheets.dart:168`) | ui-builder |
| I3 | Plan's payday ledger lists "Set aside for coming costs −N €" so the rows produce the total | ui-builder |
| I4 | Toasts: 2.5 s, dismissed on navigation, with an action where one exists (Undo on add/delete transaction and goal, Open on wishlist) | ui-builder |
| I5 | Floating labels everywhere; the expected action is the filled button (Upcoming Confirm, Review "Looks right"); an X on phone sheets; sticky "Confirm bill" with Delete moved out of the footer | ui-builder |
| I6 | Type tokens in `theme.dart` (eyebrow, meta, body, bodyStrong, heading, hero, amount) replacing the 87 literals; nothing under 12 px but the eyebrow; 48 dp touch targets named in `layout.dart`; `MergeSemantics` on `TxTile`; search icon into the app bar; explainers collapse after the first view; compact `TxTile` (date under name) below 400 dp | ui-builder |
| I7 | Honest states: bill sheet says "stored on your relay" when a blob is evicted; backup panel says photos and PDFs are not in the backup; Plan › Sync shows relay usage against the 1 GiB limit; a synchronous write failure (`addExpense`, `saveGoal`, `setCategory`) is shown, not swallowed | ui-builder |
| I8 | Code hygiene 1–6 from the architecture review (disjoint from I1–I7 by file): importer tests assert `unknownLayoutMessage` and "contains pbz, revolut"; `platform_test.dart` guards `device_calendar_plus`; `isIsoDate()` replacing ten regexes; `openPageOrDialog` + one `DialogAppBar`; `show` lists on every `wallet_core` export, dead `BillReminder` deleted, `Kind` → `BudgetKind`; `MoneyField` + `centsToFieldText` with one validation sentence and the rounding rule in core; one verb vocabulary (`addTransaction`, `update*`, `bill`), one platform-split suffix, stage tags → doc links | core-builder (packages) + ui-builder (app) |
| I9 | Widget tests keyed on `ValueKey`s where they pin copy (326 `find.text` → keys), so I6 and later localisation do not rewrite 300 assertions; the text-scale test fails (not skips) when fonts are missing; `meetsGuideline(androidTapTargetGuideline, textContrastGuideline)` in the sweeps | test-writer |

Then: `tools/emulator.sh screens` read by eye, including one dark frame per tab; a signed APK and Linux bundle through
`ci` (owner starts it) → **the M6 build**.

### Stage M6 — the owner's live test (one full pay period, phone + laptop)

The reviews are unanimous that nothing replaces this. Checklist (added to the existing owner checks in `STATUS.md`):
- Install over the existing app on the phone; laptop joins with the key; relay on the home server over TLS (H11 path).
- Use it for the whole period: imports weekly, expenses daily, the weekly review every review day, bills as they come.
- **Write down every moment of doubt and every number that looked wrong** (date, screen, what you expected).
- Disaster drills, once each: (a) new phone with the relay alive; (b) new phone with the relay dead and a `.bwb`;
  (c) switch the phone's relay address to a second relay and back (H5 must report a reset, not lose ops);
  (d) set the laptop clock a day ahead for one sync (H7 must quarantine with `clockDrift`, nothing else changes).
- First device run of the six platform plugins (camera, OCR, share-to-app, notifications, calendar, keystore): expect
  five to fifteen findings; each is a bug fixed in the same stage with a reproducing test (owner rule).

While the owner tests, agents work only on things that do not change behaviour (Stage J) and on bug reports.

### Stage J — structure for the next year (during M6; behaviour-neutral, refactor-only)

| # | Item | Agent |
|---|---|---|
| J1 | Typed entity schema in `repo.dart`: one column list generating `CREATE TABLE`, the `_apply` type check, the snapshot writer, CSV export and a `searchable` flag (search becomes automatic); column migration generalised over `_entities × PRAGMA table_info`; `repo.dart` into `part` files per section around the one private `_write`; `_apply` reads clocks once per (entity, id) | core-builder |
| J2 | `WalletControllerDeps` record replacing the 17 mutable closures; sub-state objects exposed as `Listenable` (`SyncState` like `CalendarState`); typed memo keys; per-page view objects (`TodayView`, `UpcomingView`) so screens never receive the controller; no fourth `part` | ui-builder |
| J3 | `pdf_text.dart` into its own folder (lexer, objects, cmap, fonts, content) with its fuzz corpus; `bill_sheet.dart` into sections; `AsyncAction` mixin for the eight busy/error panels; `repo.clockStats()` behind the one raw SQL in the controller; `PickedFile` so `file_picker` types stop leaking into screens | core-builder + ui-builder |
| J4 | Mutation testing on the pure packages (`budget_invariants_test.dart` restates the formula today) | test-writer |

### Stage P — product, after M6, re-ordered by what the live test surfaced

Default order (feature-parity review §4, the system review §1.2 items 11–16, the UI review §8–9):

| # | Item | Size | Note |
|---|---|---|---|
| P1 | Custom categories: `category` entity (kind income/fixed/flex/transfer, order, optional parent), synced; the fixed 20 become seeds; merchant regex hints stay as seeds | 3 d | first parity ask |
| P2 | Light accounts: opaque account id (hash of the export's identifier) + closing balance per import; "export ends 19 Oct, balance shown" completeness check; "in the bank" line on Today | 2 d | catches a missed import |
| P3 | Category budgets on the pay period (or labelled calendar-month); Today and Spending agree on "behind pace" | 1 d | |
| P4 | Recurring: period classes (weekly, monthly, quarterly, semi-annual, annual) + per-bill amount range; hand-created expected bills | 2 d | quarterly/annual bills reserved |
| P5 | Information architecture: Today · Spending · Bills · Save (Wishlist + Goals) · Plan; Plan = payday ledger + numbers, a Settings index with one route per section (deletes the GlobalKey hunt and the counter notifiers); one save model; persistent add action on every tab | 3 d | mockup in the design-system artifact first (D6) |
| P6 | Split transactions (child rows with `parent_id`, sums checked) | 3 d | |
| P7 | Rules screen (list, edit, delete; description-contains and amount-range conditions) | 2 d | |
| P8 | Reports: net per period, one category over time vs budget, income/fixed/flex stacked per period (data exists in `periodSummaries`, `trendNet`) | 3 d | |
| P9 | Recurring income entries feeding the payday plan | 1 d | |
| P10 | "Merge from backup" on `applyRemote(resend: true)`; blobs in the backup when they fit | 1 d | |
| P11 | Decimal style setting (`12,50 €` for a Croatian user; CHF symbol); ARB/`intl` only after I9 | 1 d | |
| P12 | Column-mapping import saved as a synced setting; Erste/ZABA/OTP/RBA profiles with golden tests when synthetic exports exist | 3 d | |
| P13 | Undo on delete; Android home-screen widget with the safe-to-spend number; quick-add shortcut; "Looks right?" payday plan proposed from history after the first import | 2 d | |
| P14 | Blob invariants (upload-before-ack, never deleted by clients, server-side GC from kept snapshots) — the second protocol bump; removes `blob_outbox`/`blob_delete`/`blob_own` | 2 d | |
| P15 | HUB-3 payload hand-off to the bank app; instalments; bill paid in parts; "rest of period" strip under the hero | 2 d | the differentiator |
| P16 | Per-device signing keys enrolled by the owner (revocation) — only if a device is ever lost or shared | later | |

Not building (reviews and owner agree): net worth/investments, aggregator bank connections, multi-user in one wallet
(two wallets + one relay instead), per-currency envelopes, Wear OS, research trackers, a web storage stack beyond what exists.

## 5. Delegation (owner rule: model and effort before starting)

| Agent | Model / effort | Worktree | Stages |
|---|---|---|---|
| scout | haiku / low | no (read-only) | before every builder and test-writer |
| core-builder A (money, importer, settings) | session model / high | yes | H1–H4, I8 (packages), J1, J3, P1–P4, P6, P9 |
| core-builder B (sync, relay client, vault) | session model / high | yes | H5–H9, P10, P14 |
| devops | sonnet / medium | yes | H10–H12, TLS/quadlet, CI (D1) |
| test-writer | sonnet / medium | yes | H13, I9, J4, spec tests per P item |
| ui-builder | sonnet / high | yes (live mode) | H6/H10 app halves, I1–I8 (app), J2, J3, P5, P7, P8, P13 |
| reviewer | session model / high | no | end of every stage |
| test-watcher | haiku / low | no | the one full run per stage |

Cap 4 at once (H: A, B, devops, test-writer first; ui-builder when a slot frees). The lead merges, runs the stage
verification once, commits, pushes, updates STATUS and PIPELINE.

## 6. Trade-offs made here

| Choice | Alternative | Why this way |
|---|---|---|
| One hardening stage with one schema + protocol bump before M6 | Drip the fixes across stages | Every bump replays all devices; the owner upgrades once; M6 tests the real protocol |
| Blob invariants deferred to P14 | Fold into H8's bump | Blobs work today; the rewrite is 2 days of a second replication system; M6 feedback on bills may change the shape |
| UI quick wins (I) before M6, IA change (P5) after | Do the tab reshuffle now | Copy and footing bugs break trust on day one; tab layout is taste, and a pay period of use will settle it |
| Structure refactors (J) during M6 | Before M6 | They are behaviour-neutral, so they do not invalidate the build under test, and the owner's time is the bottleneck |
| Keep ChangeNotifier, Navigator 1.0, raw SQL, no new packages | Riverpod, go_router, drift | All reviews concur: at 12k lines with one maintainer they add concepts without removing code; the boundary to add is view objects, not a framework |
| Keep the matching auto-link, amend the rule text (D2) | Make it a one-tap confirm | `SeenBank` makes it two pieces of evidence, not amount alone; a confirm tap for every hand-added expense costs the "two taps" promise |
| Keep the build tooling (D4) | Trim to plain `flutter test` | The owner uses it daily and it is what makes stage runs reproducible; the reviewer's cost (onboarding a second contributor) is not a cost here |
| No golden tests (owner rule) | A dozen on money widgets | Structural sweeps + screenshots read by eye already catch what goldens would, without the churn |

## 7. Owner decisions needed (recommendation first)

- **D1 CI on push for lint + pure-Dart package tests** (`ubuntu-latest`, ~3 min, free minutes). Recommended: yes; the macOS
  billing concern was `release.yml`, which stays manual, as do APK, desktop and emulator jobs.
- **D2 Matching auto-link vs the "never on amount alone" rule.** Recommended: amend the rule to name this exception
  (amount + window + the adding device had not seen the bank row) and show a "matched" mark with Unlink in the row sheet.
- **D3 Web.** Recommended: park (keeps building and `web-test` runs; no new work; README says "local, parked") until M6
  shows a daily reason; then give it sync (the relay client is pure Dart and compiles to wasm).
- **D4 Tooling trim.** Recommended: keep; delete only what has not been used by the end of M6.
- **D5 TLS default path**: Caddy sidecar in the quadlet or `tailscale serve`? Recommended: `tailscale serve` as the
  documented route (zero certificates to manage), Caddy as the LAN alternative.
- **D6 Tab layout (Bills tab, Save tab, Settings index)**: mockup in the design-system artifact after M6, decide then.
- **D7 `docs/review/` is committed with this file** (code-only, no figures); say if it should stay out of git.

## 8. What to revisit as it grows

- **A second person on the relay** (household): two wallets, two keys, one relay; derive `wid` per relay (HKDF with the
  relay instance id as salt) before any relay is shared; per-device signing keys (P16) before any device is shared.
- **Relay storage past ~300 photos** (1 GiB): show usage (I7) first; raise `--max-bytes` or add blob GC (P14) when it bites.
- **Replay from empty past ~100k ops**: `_apply` clock lookup per (entity, id) (J1) before any incremental cache.
- **Search past ~200k rows**: FTS; not before.
- **A second contributor**: pub `workspace:`, CI on push (D1), the barrel `show` lists (I8) and `WalletControllerDeps` (J2)
  are the onboarding work; nothing else is needed until then.
- **Localisation**: I9 (keys, not copy) is the precondition; ARB + `intl` is a P item only once a second language exists.
- **iOS / macOS / Windows**: parked by the owner; each parked platform stays out of the README's promises until maintained.
