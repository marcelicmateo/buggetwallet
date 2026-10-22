# Budget Wallet — path forward (2026-10-22, from the six outside reviews)

Source: `docs/review/` — system design (SDR), system architecture (SAR), security (SEC), code architecture (CAR), feature
parity (FPR), UI/UX (UXR). All six were read in full; every "before M6" finding was re-checked against the tree on
2026-10-22 (all still open). **Every KEEP and every CHANGE from the six reviews is in this plan**: §4 places each change in
a stage, §5 lists what is protected, §10 is the index from review finding to plan item. `PIPELINE.md` holds the live
queue, `STATUS.md` the state. Owner decisions are in §8.

Owner direction (2026-10-22): structure and practices first, then hardening, then the live test.

## 1. What the reviews agree on

**Verdict (all six): continue on this codebase; do not restart; do not change the sync or state model.** The expensive
decisions are right and in place: offline-first with a content-blind relay, one write path feeding a per-field change log
with hybrid logical clocks, pure-Dart core, integer cents and `YYYY-MM-DD`, "suggest, the owner confirms", the Ledger
design system under contrast and overflow tests, API docs before code. The replication kernel is correct in the code read
and backed by randomised convergence tests; nobody without the key can read or change anything.

What is wrong is at the edges:

| Area | Wrong today | Why it matters for one owner |
|---|---|---|
| Money | Non-EUR rows summed as euros; past-payday state pours the remaining flex into "today"; negative flex makes every wish affordable; over-budget copy prints negative denominators | The daily number is wrong for days each month |
| Sync identity | No relay identity; device id inside the database; HLC unbounded | Silent op loss on relay restore/switch; a cloned install never sees its twin; one bad clock poisons every device |
| Concurrency | `categoryBudgets` / `merchantPatterns` are one map under one key; status + link field pairs can split | Two devices editing different budgets offline lose one |
| Crypto / storage hygiene | No AAD on sealed files; SQLite cipher not pinned; Android backup on; debug-key fallback; cleartext app-wide | Not exploitable today; each is a one-line fix that stops being one later |
| Relay | Unauthenticated wallet creation; limiter collapses behind a proxy; plain HTTP as the documented default | Denial of service on a LAN; the recommended deployment breaks the limiter |
| Code surface | Three hand-kept schema copies; a 2,343-line controller with 17 closure seams; seven cents formatters, ten date regexes; tests pin copy (adding a bank broke ten tests) | A second contributor, or a fourth builder in parallel, trips on surface, not design |
| Product | Calendar-month budgets on payday periods; fixed 20 categories; monthly-only recurring; no accounts, splits, reports, rules screen | Parity gaps a daily user hits in week one |
| UI flow | Over-budget state undesigned; wish named after the category; Plan ledger does not foot; toasts outlive context; add action only on Today | A ledger that does not add up |
| Process | Nothing has run on a real phone; no human has used it for a pay period; CI manual | The blind spot every review names first |

## 2. Requirements, restated after the reviews

Functional (unchanged): safe-to-spend today on a payday period with reserved future costs; bank files in; bills as documents;
wishlist cooling-off; weekly review; goals; encrypted multi-device sync through a self-hosted relay.

Non-functional, now explicit:
- **Money is exact or labelled as a guess.** Never a negative allowance or denominator; foreign currency never counted as home.
- **No silent loss under realistic faults**: relay restored or swapped, device cloned, wrong clock, offline concurrent edits.
- **Safe platform defaults**: no OS backup of the DB, no cleartext to arbitrary hosts, no debug key in a release.
- **Behaviour pinned by contract, not copy**: tests on keys and exported messages, so a change to wording or a new bank does
  not rewrite assertions.
- **Scale**: one household, 20k rows, 16 wallets, 1 GiB per wallet. Nothing needs to grow.
- **Constraints**: one owner; agents build; owner tests at the end; Linux + Android (+ local web); no new packages without
  asking; no golden tests (owner rule); CI on push only with the owner's yes (D1).

## 3. Architecture after the changes

```
 ┌────────────────────── holds the wallet key ──────────────────────┐      ┌──── sees ciphertext + metadata ────┐
 │ Phone ─ enc. SQLite (cipher PINNED, H8)  device id NEXT TO KEY (H6)│      │ Relay                               │
 │ Laptop ─ enc. SQLite, key file 0600 in a 0700 dir (H11)           │──────│  GET state → {api, instance id (H5)}│
 │ Web ─ parked (D3), still builds                                    │ TLS  │  creation token, trust-proxy (H11)  │
 │ one write path ─ typed entity schema (G1) ─ per-field HLC, BOUNDED │ by   │  files BWOP2 with AAD (H8)          │
 │ (H7) ─ settings one row per budget / pattern (H3)                  │ def. │  blobs: client never deletes (P14)  │
 │ controller ─ deps record, sub-states, per-page view objects (J2)   │      │                                     │
 └────────────────────────────────────────────────────────────────────┘      └─────────────────────────────────────┘
```

Everything else stays as built: op log + LWW + HLC, snapshots + ack-gated pruning, blobs outside the op log, Ed25519 + TOFU,
ChangeNotifier + version cache + IndexedStack, Navigator 1.0, raw SQL, hand-written readers, deterministic ids (§5).

## 4. The plan: G → H → I → M6 → J → P

Order: **structure and practices that make every later change smaller (G) → fix what the live test would trip over (H)
→ UI trust fixes (I) → one pay period of real use (M6) → the deeper restructuring that is best designed after use (J) →
product on what the test surfaced (P).** All schema and protocol changes land in H so devices upgrade once.

### Stage G — foundation: structure and practices (~3–4 days; behaviour-neutral, no schema change)

| # | Item | Source | Agent |
|---|---|---|---|
| G1 | **Typed entity schema**: one column list per entity (name, type, nullable, searchable) generating `CREATE TABLE`, the `_apply` type check, the snapshot writer, CSV export and search registration (search becomes automatic); column migration generalised over `_entities × PRAGMA table_info` (today only `tx`); `_apply` reads `clocks` once per (entity, id); `repo.dart` split into `part` files per section around the one private `_write` | SDR 2.2, 6; CAR 3.1, 6.6, 7.7 | core-builder A |
| G2 | **Core/importer surface**: `show` lists on every `wallet_core` export, in-file helpers private, delete `BillReminder`/`billReminders`, `Kind` → `BudgetKind`, drop `formatCents`/`fnv1a36` from the importer barrel; one verb vocabulary (`addManual` → `addTransaction`, `saveGoal` stays an upsert and says so, one blob scheme, `updateSettings` typed); `isIsoDate()` in `dates.dart` replacing ten regex copies and three `ArgumentError` copies; `parseMoney` rounding rule moved beside `amountFromText`; `plannedIsBill` becomes a kind on the upcoming item in core; recurring read side derives `last_paid` from the payment; importer readers return a reason (enum) instead of bare null; the 33 stage tags in comments → doc links | CAR 6.1, 6.3, 6.4, 6.5, 7.2, 7.4, 7.6; SDR 5.5; SAR §4 | core-builder A |
| G3 | **App surface**: controller renames follow the repo (`edit*` → `update*`, `billById` → `bill`, one spelling of planned/bill); `openPageOrDialog` + one `DialogAppBar` replacing three copies and five app bars; `MoneyField` + `centsToFieldText` with one validation sentence replacing seven `_plain` copies and ten keyboard scaffolds; named 44/48/52 → one 48 dp constant in `layout.dart`; ruled list row from `common.dart` in the four screens that re-inline it; one gate-page scaffold; `gapped()` once; refusal copy owned by one layer; six raw `DateTime.now()` → the injected clock; one platform-split suffix (`_io`/`_web`), `notifier.dart` → `nudge_platform_io.dart`; needlessly public app classes made private; the 1,500-cent "typical order" literal out of a string | CAR 6.1, 6.3, 6.7, 7.3, 7.5, 7.6; SDR 5.2, 5.5 | ui-builder |
| G4 | **Small bugs found by the sweep** (each with a test): `CalendarKind.values.byName` on unknown JSON sits outside the try; `headsUpChain` stays rejected forever after one throw; swallowed catches at `scan_bill.dart:90` and `controller_future.dart:283`; `platform_test.dart` misses `device_calendar_plus` and `calendar_source_native.dart` (and a header explaining the allow-list) | CAR 5, 6.4, 6.6, 6.8 | ui-builder |
| G5 | **Tests pinned by contract**: importer tests assert `unknownLayoutMessage` or a stable fragment, registry test says "contains pbz, revolut"; widget tests on `ValueKey`s where they pin copy (326 `find.text` → keys); the text-scale test fails (not skips) when fonts are missing; `meetsGuideline(androidTapTargetGuideline, textContrastGuideline)` in the sweeps | CAR 2.2, 7.1; SDR 5.8, 7 | test-writer |
| G6 | **Practices**: CI on every push for lint + importer/core/relay tests + app widget tests on `ubuntu-latest` (D1; APK, desktop, emulator, release stay manual); `--enforce-lockfile` on every `pub get` in `build.sh` and CI; pub `workspace:` in a root pubspec replacing the hand-rolled staleness check in `build.sh pub_ready`; R8/minify configured explicitly; `dart pub outdated`/OSV advisories as a CI step once on push; release-notes template with the schema-bump replay and the "all devices within a week" policy; `dist/` kept out of review snapshots | SDR 7, 8, 10.2; SEC 9, 10; SAR 8 | devops |

Merge order: A → ui → tests → devops; reviewer; one Haiku full run. G changes no behaviour, so the stage is judged by the
suites staying green and the diff reading smaller.

### Stage H — hardening before M6 (one schema bump → 8, one protocol doc bump; ~1 week)

| # | Item | Source | Agent |
|---|---|---|---|
| H1 | Count only `currency == settings.currency` in `computePeriod`, `monthSummary`, `periodSummaries`, category sums; return `foreignByCurrency` for a "foreign, not counted" line | SDR 3.2; FPR 3.7 | core-builder A |
| H2 | Explicit `paydayPassed` state instead of `daysLeft.clamp(1, …)`; `planDaily ≤ 0` → affordability "over budget", never "now"; core returns `overBy` so no screen prints a negative allowance or denominator; `lowIncome` heuristic and the payday clamp move from `plan.dart` into core; `incomeMode == 'received'` waits for all salary parts within `_samePaydayDays` | SDR 3.2, 3.3, 5.5; UXR 1, 4; FPR 3.1 | core-builder A |
| H3 | One settings row per category budget (`budget:<category>`) and per merchant pattern; migration from the maps; schema 8 | SDR 6, 9.2; SAR §4; SEC — | core-builder A |
| H4 | `PbzProfile.detect` requires the full header tuple on one row; `FILEPASS` detected ("password-protected", not "damaged"); `repo.idCollision` logged when a "duplicate" id differs in amount or description; 20 MB cap on `importBankFile`; inflate cap in `XlsxReader` | SDR 4.1, 4.2; SEC 15 | core-builder A |
| H5 | Relay instance id: random id per relay (persisted in `meta.json`), returned by `GET state`, stored with the upload marker; a change = first connect; the app shows a relay fingerprint on first connect and keeps it | SDR 2.6, 9.3, 10.4; SAR 2, 10.9; SEC 1 | core-builder B |
| H6 | Device id per install, stored next to the key (not in the DB); `WalletRepo.open(deviceId:)`; a 409 on an own seq is surfaced as `SyncProblem.deviceIdInUse`, never retried silently | SDR 9.3; SEC 2 | core-builder B + ui |
| H7 | Bounded HLC: files whose max HLC is > 1 h ahead of wall time quarantined with reason `clockDrift`; local writes refused when the wall clock is that far behind the stored clock; shown like `clockSkew` | SDR 9.3; SEC 3 | core-builder B |
| H8 | `BWOP2`: AAD per use (`bw-sync-file\n<device>\n<seq>`, `bw-snapshot\n<id>`, `bw-backup`, `bw-blob`, web key wrap); 256 MiB inflate cap in `unseal`; `PRAGMA cipher` pinned before `PRAGMA key`; relay host in the signed text (`bw-relay-v3`); delete-wins vs edit-wins decided per entity and written down | SDR 9.4, 9.5, 10.3, 10.4; SAR 2; SEC 9, 10, 14 | core-builder B |
| H9 | Field-pair repair: `planned.paid_tx` meaningful only when `status == paid`; `bill.linked_tx` unique across live bills repaired when caught up like transfers and matches; `SyncEngine.run` re-entrancy and `clockOffsetMs` sharing documented | SDR 9.2; SAR §4, 11.2; SEC 6; CAR 6.8 | core-builder B |
| H10 | Android: `allowBackup="false"` + `dataExtractionRules`; `network_security_config.xml` (cleartext only for private ranges / the configured relay host); release build **fails** without a keystore; `FLAG_SECURE` while the key sheet is open; "show QR only" as the default transfer path; `WRITE_CALENDAR` plugin replacement scoped (open question → P13); camera temp dir verified app-private | SDR 5.7, 9.4; SEC 2, 5, 7, 12, 19, §7, §9 | devops + ui |
| H11 | Relay: `--create-token` (header on the first `PUT d/<device>/1`) or wallet allow-list; `--trust-proxy`; `HEALTHCHECK`; read-only container except `/data`; `HEAD` handled; missing file for a known device → diagnosable status, not 500; TLS as the documented default (D5), plain HTTP = dev mode; desktop key file: dir 0700, temp + chmod + rename | SDR 2.6, 9.6; SEC 4, 7, 8, 11, §5 | devops |
| H12 | Tests written from the spec: relay A→B→A; relay restored from an older image; cloned device id; future clock; two concurrent sync runs; concurrent budget edits; concurrent `linkBill`; device back after 90 days; schema-7 reader on schema-8 files then upgrade; zero ops on the second full round; invariants `ack ≤ cursor ≤ last`, `covers ≤ cursors`, transfer symmetry, bill payment uniqueness; property test "no live device left behind a prune"; memory-vs-real-relay model equivalence; relay fault injection (between `writeAtomic` and `saveMeta`, disk full, truncated files); protocol fuzz "4xx never 5xx, state unchanged"; fixed-key fixed-nonce `seal` vectors + nonce uniqueness; decompression bomb for `unseal` and `.xlsx`; PBZ header from another bank; "same month, newer template" fixture per bank; right-aligned PDF amount column; past-payday state; Android backup/restore on the emulator; old-build `.db`/`.bwb` fixture committed per release | SDR 2.4, 4.1, 7, 9.1, 9.8, 10.4; SAR 11; SEC 11 | test-writer |
| H13 | Docs: version table (relay api, magic, payload, reader, schema, app) in the spec; threat model + clone, wrong-clock, lost-device adversaries; key rotation procedure; blobs not in backups; "restore the relay from an old copy" named as the one dangerous operation; relay metadata correlation and per-relay `wid` if ever shared; web `sessionStorage`; Dart cannot zero memory; evicted blobs and web as stated limits; spec §8 table corrections (matching, currency, YNAB cell); the two-wallet household recipe; §9 clipboard note; an anonymised real-bill corpus kept outside the repo | SDR 2.1, 3.4, 9.3, 9.4; SAR 2, 3, 8, 11.4; SEC 6, 13, 16, 17, §4; FPR 2, 3.11 | lead |

Run: scouts → A, B, devops, test-writer in parallel (cap 4; ui-builder's halves of H6/H10 when a slot frees) → merge
B → A → devops → tests → ui → reviewer → fixes → Haiku full run + emulator screens → push → STATUS.

### Stage I — UI quick wins (~3 days; no schema or protocol change)

| # | Item | Source | Agent |
|---|---|---|---|
| I1 | Over-budget state on Today and Plan: "You're X € over for today. Nothing more today; tomorrow starts at Y €" (H2's `overBy`); never a negative allowance, budget or denominator; first-run panels become one panel below the hero or one collapsed line after the first dismissal | UXR 1, 4, 6 | ui-builder |
| I2 | Wish named from the note, or ask; never the category; "On the wishlist" toast gets Open | UXR 1, 4 | ui-builder |
| I3 | Plan's payday ledger lists "Set aside for coming costs −N €" so the rows produce the total | UXR 1, 4 | ui-builder |
| I4 | Toasts: 2.5 s, dismissed on navigation, with an action where one exists; Undo on delete transaction and delete goal | UXR 1, 5, 9.4; SDR 5.6; FPR table | ui-builder |
| I5 | Floating labels everywhere; the expected action is the filled button (Upcoming Confirm, Review "Looks right"); an X on phone sheets; sticky "Confirm bill" with Delete out of the footer; text-field-styled date picker in the bill sheet; default category = last used or none with the CTA disabled; the explainer above the CTA or behind an info icon | UXR 2.5, 4 | ui-builder |
| I6 | Type tokens in `theme.dart` (eyebrow, meta, body, bodyStrong, heading, hero, amount) replacing the literals; nothing under 12 px but the eyebrow; 48 dp targets; `MergeSemantics` on `TxTile`; an 8 dp grid rule for section head, eyebrow, first line; search icon into the app bar; explainers show once then collapse; compact `TxTile` (date under name) below 400 dp; Upcoming grid without borders on empty days, "Planned by you" instead of "Added"; Wishlist empty sections collapse to one line; desktop top strip holds title, search and period chip; delivery-hour panel gated on a setting or detected merchants; manual dark-mode toggle | UXR 2.2, 2.3, 4, 5, 7; SDR 5.4, 5.6 | ui-builder |
| I7 | Persistent add action on every tab (FAB at radius 3 in ink, or "+" in every app bar); the touch equivalent of Ctrl+N | UXR 4, 8, 9.8; SDR 5.6 | ui-builder |
| I8 | Honest states: bill sheet says "stored on your relay" when a blob is evicted; backup panel says photos and PDFs are not in the backup; Plan › Sync shows relay usage against the 1 GiB limit; a synchronous write failure is shown, not swallowed; "matched" mark with Unlink on a hand-added expense (D2) | SDR 2.1, 5.1; SAR 6, 11.5; SEC 16 | ui-builder |
| I9 | One dark frame per tab in the designer walk, read by eye; `tools/emulator.sh screens` read | UXR 5, 9.13 | lead + test-watcher |

Then a signed APK and Linux bundle through `ci` (owner starts it) → **the M6 build**.

### Stage M6 — the owner's live test (one full pay period, phone + laptop)

- Install over the existing app; laptop joins with the key; relay on the home server over TLS (H11 path).
- Use it for the whole period: imports weekly, expenses daily, the weekly review every review day, bills as they come.
- **Write down every moment of doubt and every number that looked wrong** (date, screen, expected).
- Disaster drills, once each: (a) new phone, relay alive; (b) new phone, relay dead, `.bwb`; (c) relay address switched to
  a second relay and back (H5 must report a reset); (d) laptop clock a day ahead for one sync (H7 quarantines `clockDrift`).
- First device run of the six plugins (camera, OCR, share-to-app, notifications, calendar, keystore): expect five to
  fifteen findings; each fixed in the same stage with a reproducing test. Measure sealing a 15 MiB PDF on the phone.
- Existing per-stage owner checks in `STATUS.md` stay.

While the owner tests, agents work only on Stage J (behaviour-neutral) and on bug reports.

### Stage J — deeper structure, designed after use (during M6; refactor-only)

| # | Item | Source | Agent |
|---|---|---|---|
| J1 | `WalletControllerDeps` record replacing the 17 mutable closures and four module globals; `KeyStore` an instance behind `default*()`; sub-state objects exposed as `Listenable` (`SyncState` like `CalendarState`); typed memo keys (no `'search$query'` prefix collisions); per-page view objects (`TodayView`, `UpcomingView`) so screens never receive the controller; `forgetBrowser` resets one object; no fourth `part`; `repo.clockStats()` behind the one raw SQL | SDR 5.1, 5.3, 10.5; CAR 3.2, 4, 6.7, 7.8, 7.9 | ui-builder |
| J2 | `pdf_text.dart` into its own folder (lexer, objects, cmap, fonts, content) with its fuzz corpus; `bill_sheet.dart` into sections; `TodayScreen.build`/`SearchScreen`/`PlanScreen`/`BillsPanel` into sub-widgets; `readCalendars` nesting; `AsyncAction` mixin for the eight busy/error panels; `PickedFile(name, readBytes)` so `file_picker` and `path_provider` types stop leaking into screens; the per-peer apply loop extracted from `SyncEngine.run` with a precise return type and the invariants as asserts | CAR 3.3, 6.2, 7.8, 7.9, 7.10; SDR 5.3, 10.6 | core-builder + ui-builder |
| J3 | Mutation testing on the pure packages (invariant tests that restate the formula); counters as delta rows wherever a counter exists (streak, "saved by waiting") | SDR 7, 10.3 | test-writer + core-builder |
| J4 | `packages/sync` split out of core (engine, relay client, vault) — only if J2 shows the seam is clean | SDR 10.2 | core-builder |

### Stage P — product, after M6, re-ordered by what the live test surfaced

| # | Item | Source | Size |
|---|---|---|---|
| P1 | Custom categories: `category` entity (kind income/fixed/flex/transfer, order, optional parent), synced; the fixed 20 and the merchant regexes become seeds | FPR 3.4; SDR 3.3 | 3 d |
| P2 | Light accounts: opaque account id + closing balance per import (PBZ running balance, Revolut `Balance`); completeness check ("export ends 19 Oct"); "in the bank" line on Today; transfer pairing without hints where the balance proves it | FPR 3.2 | 2 d |
| P3 | Category budgets on the pay period (or labelled calendar-month); Today and Spending agree on pace | SDR 3.3; FPR 3.6 | 1 d |
| P4 | Recurring: period classes (weekly … annual) + amount range; hand-created expected bills; instalments; a bill paid in parts | SDR 3.3; FPR 3.5 | 2 d |
| P5 | Information architecture: Today · Spending · Bills · Save (Wishlist + Goals) · Plan; Plan = payday ledger + numbers; Settings index with one route per section (deletes the GlobalKey hunt and the counter notifiers); one save model; two-pane settings on desktop; receipt glyph for Bills; mockup first (D6) | UXR 4, 7, 8, 9.9–10; SDR 5.2, 5.6 | 3 d |
| P6 | Split transactions (child rows with `parent_id`, sums checked) | FPR 3.4 | 3 d |
| P7 | Rules screen (list, edit, delete; description-contains and amount-range conditions) | FPR 3.4 | 2 d |
| P8 | Reports: net per period, one category vs budget over time, income/fixed/flex per period; "saved by waiting" + streak on the review's Done screen | FPR 3.6, 3.9 | 3 d |
| P9 | Recurring income entries feeding the payday plan; period lengths other than monthly (biweekly) | FPR 3.1, 3.8 | 1 d |
| P10 | "Merge from backup" on `applyRemote(resend: true)`; blobs in the backup when they fit | SDR 9.7; SEC 16 | 1 d |
| P11 | Decimal style setting (`12,50 €`; CHF symbol); then `flutter_localizations` + ARB (after G5) | SDR 5.6; UXR 6 | 1 d |
| P12 | Column-mapping import as a synced setting; generic CSV; Erste/ZABA/OTP/RBA profiles with golden tests when synthetic exports exist; CAMT.053 only for a business case; import from another app (CSV) | FPR 3.3; SDR 10.6 | 3 d |
| P13 | Android home-screen widget; quick-add shortcut; "Looks right?" payday plan proposed from history after the first import; replace the calendar plugin that forces `WRITE_CALENDAR` | FPR 3.10, 3.12; SEC 9 | 2 d |
| P14 | Blob invariants: referenced from ops, upload-before-ack, never deleted by clients, server-side GC from kept snapshots — the second protocol bump; removes `blob_outbox`/`blob_delete`/`blob_own` | SDR 2.6, 10.4; SAR 10.6 | 2 d |
| P15 | Currency conversion at import (Revolut counter-amount, else an owner-entered rate per currency); budget in EUR, show both | FPR 3.7 | 2 d |
| P16 | HUB-3 payload hand-off to the bank app; "rest of period" strip under the hero; attachments on transactions; loan amortisation from `loan` + `loanEnd` | FPR 3.1, 3.5; SDR 3.4 | 2 d |
| P17 | Per-device signing keys enrolled by the owner (revocation); per-relay `wid` — only when a device or relay is shared | SEC 6, 17; SAR 10.3 | later |
| P18 | Web: sync through the relay client (pure Dart, wasm), PBKDF2 600k or Argon2id under `bwk2`, key in memory only, CSP meta — only if D3 un-parks web; `go_router` with `StatefulShellRoute` only if web becomes first-class | SDR 2.6, 5.2, 5.7; SEC 13, 9 | D3 |

Not building (reviews and owner agree): net worth/investments, aggregator bank connections, multi-user in one wallet (two
wallets + one relay), per-currency envelopes, Wear OS, research trackers, incremental derived-value caching, FTS, Riverpod,
drift, mockito, golden tests.

## 5. KEEP register — protected in every review

The reviewer agent checks a stage diff against this list; a change to any item needs an owner decision.

| # | Keep | Source |
|---|---|---|
| K1 | Offline-first; content-blind relay holding only sealed per-device sequences, snapshots and blobs | SDR 2.1; SAR 10.1 |
| K2 | One private write path `WalletRepo._write`: local apply + per-field clock + outbox in one transaction; sync, snapshot, backup, restore are "replay ops" | SDR 2.2; CAR 8 |
| K3 | Derived values computed at read, cached per `dataVersion`; nothing derived is persisted | SDR 2.3 |
| K4 | Deterministic ids for discovered things (`rec:`, `calendar:`, `bill:`, tx hash + occurrence), per-source salt, v1-compatible | SDR 2.4, 4.2; SAR 10.5 |
| K5 | Single-owner, many devices; one wallet key with HKDF children; household = a second wallet | SDR 2.5; SAR 10.3; FPR 3.11 |
| K6 | Payday-period safe-to-spend with reserved costs as the primary number; integer cents; UTC `YYYY-MM-DD` compared lexically | SDR 3.1, 3.3; FPR 3.1 |
| K7 | Transfer pairing requires a bank hint (never amount alone); matching keeps `SeenBank` as second evidence (D2) | SDR 3.3 |
| K8 | Goal contributions as delta rows; delete + concurrent edit → deleted with the edit; creation ops carry no status | SDR 9.1; SAR §4 |
| K9 | Per-field LWW with HLC; snapshots + ack-gated pruning with the written no-loss argument; strict per-peer order; content-hashed quarantine; stuck-peer heal | SDR 9.1; SAR 5, 10.2, 10.4 |
| K10 | XChaCha20-Poly1305 with a 24-byte random nonce, HKDF-SHA256 with versioned infos, Ed25519 request signatures over method/path/covers/body hash/time, TOFU on creation, relay path rebuilt from validated segments | SDR 9.4; SEC 3 |
| K11 | SQLite + `sqlite3mc` + raw SQL + entity map; no ORM; keyed open first, rekey with temp + rename | SDR 6, 9.5; SAR 10.7 |
| K12 | Relay pipeline order (limit → OPTIONS → validate → headers → body caps → verify → per-wallet mutex), files win over meta, six-char ids in logs, two-stage container, non-root | SDR 9.6; SEC 5 |
| K13 | `.bwb` = sealed op set with original clocks; restore is a merge | SDR 9.7 |
| K14 | Hand-written BIFF8, PDF text, RRULE and UBL readers with caps, never-throw shells and fuzz corpora; `wallet_importer` Flutter-free and wasm-clean | SDR 4.1; SEC 8 |
| K15 | Stateless `BankProfile` with `ImportContext`; per-key validated settings ("bad value falls back, logged by key only") | CAR 2.3, 8 |
| K16 | Package boundaries enforced by pubspec, the web-compile proof and the plugin regex test; app imports only the two barrels; constructor seams and real in-memory repos in tests, no mocks | CAR 5, 8; SDR 5.3 |
| K17 | One `ChangeNotifier`, version cache, `IndexedStack`; Navigator 1.0; `Shortcuts`/`Actions`; adaptive layout 600/1024 with `showSheet` choosing sheet or dialog; share-to-app via `ACTION_SEND` | SDR 5.1, 5.2, 10.5 |
| K18 | Ledger design system: 17 colour tokens per brightness under a contrast test, Plex Sans + Plex Mono tabular amounts (sign in front, symbol after, U+2212), ruled Panel/SectionHead/TotalRule/DoubleRule/TxTile/StatusLabel, hatch for over budget, shape-coded Upcoming marks, charts | UXR 2, 10; SDR 5.4 |
| K19 | Today's order hero → sentence → stat strip → pace → "what changes it" → one button; inline impulse interception; wishlist affordability in days; "Unsure" marks on guessed fields; Confirm/Change/No cost; weekly review's four ruled steps and promise line; amount-free notifications; key confirmation by last four | UXR 3, 4, 10; SDR 5.6; FPR 3.9, 5 |
| K20 | Structural sweeps at 320 dp × text scale 2.0 with real fonts; integration harness asserting no merchant, amount or key in the app log; log-privacy tests per package as a merge gate | SDR 5.8, 7; SEC 7, 12 |
| K21 | Spec tests written from the API document before the implementation; property tests with brute-force oracles; the 2–4 device random convergence test; fuzz tests in isolates | SDR 7, 8; CAR 8 |
| K22 | Pinned Flutter, pinned `sqlite3.wasm` hash, committed app and relay lockfiles, reproducible Podman builds, one signing key outside the repo | SDR 7; SEC 10 |
| K23 | `SyncEngine.run` as one linear method with numbered phases | CAR 3.3 |
| K24 | Zero TODOs, catch discipline (log or rethrow), strict analyzer with infos fatal | CAR 1, 8 |
| K25 | File import as the primary path (no aggregator); bills as documents (fiscal QR, HUB-3, UBL, OCR, sealed storage, warranty/return dates); calendar events as planned costs | FPR 3.3, 3.5, 5 |
| K26 | The agent pipeline: API doc → scout → builders in worktrees → spec tests → reviewer → fixes with reproducing tests → one full run per stage | SDR 8 |

## 6. Delegation (owner rule: model and effort before starting)

| Agent | Model / effort | Worktree | Stages |
|---|---|---|---|
| scout | haiku / low | no | before every builder and test-writer |
| core-builder A (schema, money, importer, settings) | session model / high | yes | G1, G2, H1–H4, J3, P1–P4, P6, P9, P15 |
| core-builder B (sync, relay client, vault) | session model / high | yes | H5–H9, J2 (engine), J4, P10, P14 |
| devops | sonnet / medium | yes | G6, H10–H11, TLS/quadlet, CI |
| test-writer | sonnet / medium | yes | G5, H12, J3, spec tests per P item |
| ui-builder | sonnet / high | yes (live mode) | G3, G4, H6/H10 app halves, I1–I8, J1, J2 (app), P5, P7, P8, P13 |
| reviewer | session model / high | no | end of every stage, with §5 as its checklist |
| test-watcher | haiku / low | no | the one full run per stage |

Cap 4 at once. G: A, ui, tests, devops. H: A, B, devops, tests, then ui. I: ui alone plus the watcher.

## 7. Trade-offs made here

| Choice | Alternative | Why this way |
|---|---|---|
| G (structure + practices) before H | H first, structure during M6 | Owner direction. G1 makes H3/H6 one-entry changes, G5 stops copy-pinned tests breaking under every later stage, G6 catches regressions on push. Cost: the M6 build is ~4 days later |
| J (controller deps, view objects, splits) after M6 | In G | J1 touches `controller.dart` and every screen — the same files H and I builders edit in parallel; and view objects are best cut once a pay period says which screens stay (P5 moves whole tabs) |
| One hardening stage with one schema + protocol bump | Drip the fixes | Every bump replays all devices; the owner upgrades once; M6 tests the real protocol |
| Blob invariants deferred to P14 | Fold into H8 | Blobs work today; a 2-day rewrite of a second replication system; M6 feedback on bills may change its shape |
| UI quick wins (I) before M6, IA change (P5) after | Reshuffle tabs now | Copy and footing bugs break trust on day one; tab layout is taste a period of use will settle |
| Keep ChangeNotifier, Navigator 1.0, raw SQL, no new packages | Riverpod, go_router, drift | All reviews concur: at 12k lines with one maintainer they add concepts without removing code; the boundary to add is view objects (J1) |
| Keep the matching auto-link, amend the rule (D2) | One-tap confirm | `SeenBank` is a second piece of evidence; a confirm per hand-added expense breaks the "two taps" promise |
| Keep the build tooling (D4) | Trim to plain `flutter test` | The owner uses it daily; the reviewer's cost (a second contributor) does not exist. `workspace:` (G6) removes the one hand-rolled part |
| No golden tests (owner rule) | A dozen on money widgets | Sweeps + screenshots read by eye catch the same without churn |
| 140-column format stays | 80/100 as SDR 10.2 suggests | Repo-wide reformat for no behaviour; the reviewer's objection was line counts in the spec |

## 8. Owner decisions needed (recommendation first)

- **D1 CI on push for lint + package tests + widget tests** (`ubuntu-latest`, minutes, free). Recommended: yes; the macOS
  billing concern was `release.yml`, which stays manual with APK, desktop and emulator jobs. Needed before G6.
- **D2 Matching auto-link vs "never on amount alone".** Recommended: amend the rule to name this exception (amount +
  window + the adding device had not seen the bank row) and show a "matched" mark with Unlink (I8).
- **D3 Web.** Recommended: park (keeps building and `web-test` runs; README says "local, parked"); P18 only if M6 shows a
  daily reason.
- **D4 Tooling trim.** Recommended: keep; delete what has not been used by the end of M6.
- **D5 TLS default path**: `tailscale serve` (no certificates to manage) as the documented route, Caddy sidecar as the LAN
  alternative. Needed before H11.
- **D6 Tab layout (Bills tab, Save tab, Settings index)**: mockup in the design-system artifact after M6, decide then.
- **D7 `docs/review/` committed** (code-only, no figures); say if it should stay out of git.

## 9. What to revisit as it grows

- A second person on the relay: two wallets, one relay; per-relay `wid` and per-device keys (P17) before any sharing.
- Relay storage past ~300 photos (1 GiB): usage shown (I8) first; raise `--max-bytes` or blob GC (P14) when it bites.
- Replay from empty past ~100k ops: the per-(entity, id) clock lookup (G1) before any incremental cache.
- Search past ~200k rows: FTS; not before.
- A second contributor: `workspace:` and CI on push (G6), barrel `show` lists (G2), `WalletControllerDeps` (J1).
- Localisation: G5 is the precondition; ARB + `intl` (P11) only once a second language exists.
- iOS / macOS / Windows: parked; out of the README's promises until maintained.

## 10. Coverage index — every review finding → plan item

- **SDR §1.2 action list** 1 H1 · 2 H2 · 3 H3 · 4 H10 · 5 H4 · 6 H5 · 7 H6 · 8 H7 · 9 H8 · 10 H11 · 11 P3 · 12 P1, P4 · 13 P5, I7 ·
  14 P10 · 15 P11, G5 · 16 D2, I8 · 17 G6, D4 · 18 G1 · 19 J1, J2, I6 · 20 H12, G5, J3.
- **SDR §2** 2.1 H13, I8 · 2.2 G1 · 2.3 keep (K3) · 2.4 H12 · 2.5 K5 · 2.6 H11, H5, P14, D3/P18. **§3** 3.2 H1, H2 · 3.3 P3, D2,
  P4, H2, P1 · 3.4 P6, P15, P8, P2, P9, P16, I4, P13. **§4** 4.1 H4, H12, H13 · 4.2 H4. **§5** 5.1 J1, I8 · 5.2 G3, P5, P18 ·
  5.3 J2, J1 · 5.4 I6 · 5.5 G2, H2, J2, G3 · 5.6 P5, P11, G5, I4, I6 · 5.7 H10, P13, P18 · 5.8 G5. **§6** G1, H12 (fixture),
  H3, keep (FTS). **§7** J3, G6, D4, H12, M6, H13 (corpus). **§8** G6, D4, M6. **§9** 9.1 H12 · 9.2 H3, H9 · 9.3 H5, H6, H7,
  H13/P17 · 9.4 H8, H13, M6 (perf), H11, H10, P18 · 9.5 H8, H10 · 9.6 H11 · 9.7 P10, I8 · 9.8 H12. **§10** 10.2 G6, J4 ·
  10.3 G1, H8, J3 · 10.4 H8, H5, H6, H7, H3, P14, H11, H12 · 10.5 J1, P5, G5, P11 · 10.6 H12, P12, J2 · 10.7 not building.
- **SAR** §2 H8, H5, H13 · §3 H13, H12 · §4 H3, H9, G2 (recurring read side) · §5 K9 · §6 I8 · §7 H5, H6, H7, H12 · §8 H13,
  H11, G6, M6 · §10 K1, K9 + H3, K5 + H13/P17, K9, K4, P14, K11 + H8, D3, H5 + H11, H11 · §11 H13, H12, H3, H13, I8, M6, G6.
- **SEC** 1 H5 · 2 H6, H10 · 3 H7 · 4 H11 · 5 H10 · 6 H13, P17 · 7 H11, H10 · 8 H11 · 9 H8 · 10 H8 · 11 H11 · 12 H10 · 13 P18 ·
  14 H8 · 15 H4 · 16 P10, I8 · 17 H13 · 18 none · 19 H10 · §5 H11 · §6 H9, H12 · §7 H10 · §9 G6 (R8), P18 (CSP), P13 ·
  §10 G6 · §11 H12 (1–7).
- **CAR** 2.2 G5 · 3.1 G1 · 3.2 J1 · 3.3 J2 · 4 J1 · 5 G4 · 6.1 G3, G2 · 6.2 J2 · 6.3 G2, G3 · 6.4 G4, G2 · 6.5 G2, G3 ·
  6.6 G1, J2, G4 · 6.7 G3, G2, J1 · 6.8 G4, H9 · 7.1 G5, G4 · 7.2 G2 · 7.3 G3 · 7.4 G2 · 7.5 G3 · 7.6 G2, G3 · 7.7 G1 · 7.8 J2, J1 ·
  7.9 J1, J2 · 7.10 J2 · §8 K2, K15, K16, K21, K23, K24.
- **FPR** §4 rows 1 H1 · 2 H2 · 3 P1 · 4 P2 · 5 P3 · 6 P4 · 7 P6 · 8 P7 · 9 P8 · 10 P9 · 11 P12 · 12 I4, P13. §3.1 P16, I1,
  P9 · 3.2 P2 · 3.3 P12 · 3.4 P1, P7, P6 · 3.5 P4, P16 · 3.6 P3, P8 · 3.7 H1, P15 · 3.8 P9 · 3.9 P8, P5 · 3.10 P13 · 3.11 H13 ·
  3.12 P13 · §2 corrections H13 · §5 K6, K25, K19 · §6 not building.
- **UXR** §1 1 I1 · 2 I1 · 3 I2 · 4 I3 · 5 I4. §2 2.2 I6 · 2.3 I6 · 2.4 P5 · 2.5 I5. §4 Today I1, I7, I6 · Add expense I5, I2 ·
  Upcoming I6, I5 · Spending I6 · Wishlist I5, I6 · Goals I5 · Plan I3, P5 · Bill sheet I5 · Review I5. §5 I6, I4, I9.
  §6 I1, I6, P11, G5. §7 I6, P5. §8 P5, I7. §9 1 I1 · 2 I2 · 3 I3 · 4 I4 · 5 I5 · 6 I6 · 7 I6 · 8 I7 · 9 P5 · 10 P5 · 11 I6 ·
  12 I5 · 13 I9. §10 K18, K19, K20.
- Corrections to the reviews: `.claude/agents/*.md` and the per-package `CLAUDE.md` files are in git (SDR §7 says not);
  no `pubspec.yaml` exists at the root yet (G6 adds it).
