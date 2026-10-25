# Plan for the owner's notes (2026-10-25) and further development

Source: the notes under STATUS › Next (written 2026-10-25 after the first live use: laptop app joined the phone's wallet over the VPN relay).
Builds on `PATH_FORWARD.md` (P5 information architecture, P7 rules, P8 reports, P9 income) and `PIPELINE.md` (cap 4 agents, scout first,
one Haiku full run and one reviewer pass per stage). Nothing here is started.

## Owner decisions needed before building
| # | Question | Why it blocks | My default |
|---|---|---|---|
| D8 | Theme: what is "heavy"? (ink contrast, ruled lines, IBM Plex Mono for all figures, dark ledger) | N1 design | Softer palette (off-white/graphite, lower contrast ink), thinner rules, mono only for amounts; keep the Ledger structure. Two mockups to pick from |
| D9 | Balance model: opening-balance entry or setting; accounts = owner-named labels mapped to bank sources | N2 schema 9 | A synced `account` entity (name, source, currency, opening cents, as-of date); balance = opening + rows since; correctable by hand |
| D10 | "Monthly bill should have all bills": scanned slips, bank payments, or both | N4 | Both, one line per month, matched by payee key |
| D11 | Which graphs first | N3 | Spending per month, category share, income vs spending, budget vs actual |
| D12 | Spending: finer categories or drill-down first | N3 | Drill-down first (no new categories), then subcategories |

## Notes → stages
| Stage | Notes it covers | Touches |
|---|---|---|
| **N0 quick fixes** (no design needed, start now) | key `0`→`O` in `VaultKey.parse` + a clearer key font; grainy laptop graph (bug, reproduce first); date + search no longer pinned on wide windows; tap the date to open a date picker (custom range) | core vault, app charts/headers |
| **N1 look and structure** | Theme softer (D8); P5 tabs Today · Spending · Bills · Save · Plan; Plan: Payday plan + Numbers merged with Edit; settings index; "join another wallet" while one exists (set the old one aside, never delete) | app only; mockup first (design-system artifact) |
| **N2 setup and balances** | Welcome screen (cash balance), accounts overview, plan defaults from imports (proposals, never silent), budget Suggest (auto-fill empty, ask per entry, Accept all) | core (schema 9, pure suggest functions) + app |
| **N3 Spending and graphs** | Range control on every graph (period, month, 3/6/12 mo, custom from–to, back/forward); more graphs; Spending drill-down (category → merchants → rows), comparisons, then subcategories; PATH_FORWARD P7 rules screen, P8 reports | core (range math, aggregates) + app charts |
| **N4 bills** | Recurring bill lists its bills (D10) | core recurring/bills + app |

Order: N0 → N1 design → (N1 UI ‖ N2 core) → N2 UI → N3 → N4. N1 and N2 are independent until N2's screens land in the new Plan.
The welcome screen needs the N1 onboarding shell; the range control (N3) reuses the date picker from N0.

## Delegation (lead = main session; model/effort per agent file; each item in its own worktree)
| # | Item | Agent | Model / effort | Worktree | Needs |
|---|---|---|---|---|---|
| 0a | Context pack: vault/key text, charts + headers, date pickers | scout | haiku / low | – | – |
| 0b | `0`→`O` in `VaultKey.parse` (+ test), nothing else | core-builder | session model / high | n0-core | 0a |
| 0c | Grainy graph repro + fix, pinned headers, date-tap picker, key font | ui-builder | sonnet / high | n0-ui | 0a |
| 0d | Review, merge, targeted tests | reviewer + lead | high | v2 | 0b, 0c |
| 1a | Two theme mockups + IA mockup (Plan merged, tabs, settings index, onboarding with balance) in the design-system artifact; owner picks | lead | – | – | D8 |
| 1b | Scout: plan.dart / settings / onboarding / controller join paths | scout | haiku / low | – | 1a chosen |
| 1c | N1 UI: theme, tabs, Plan merge, settings index, join-while-wallet | ui-builder | sonnet / high | n1-ui | 1a, 1b |
| 2a | Core API fixed by the lead (names, params) | lead | – | – | D9 |
| 2b | Accounts entity + opening balance (schema 9), plan-default and suggest pure functions, tests | core-builder | session model / high | n2-core | 2a |
| 2c | Tests from the spec: balances, transfers, foreign currency, suggest rules, schema 8→9 | test-writer | sonnet / medium | n2-tests | 2a |
| 2d | N2 UI: welcome, accounts, plan proposals, Suggest | ui-builder | sonnet / high | n2-ui | 1c, 2b |
| 3a | Range maths + aggregates (per-merchant, per-month, income vs spend), tests | core-builder | session model / high | n3-core | – |
| 3b | Charts, range control, drill-down screens | ui-builder | sonnet / high | n3-ui | 1c, 3a |
| 4a | Recurring → bills list (core + app) | core-builder then ui-builder | high / sonnet high | n4 | D10, 2b done (one schema bump at a time) |
| S | Per stage: Haiku full run (test/desktop/perf), one reviewer on the merged diff, STATUS, push; owner starts `ci` | lead, test-watcher | haiku / low | v2 | – |

At most 4 agents run at once; typical wave 1 = scout + core-builder + ui-builder; wave 2 (after D8/D9) = ui-builder (N1) + core-builder (N2) + test-writer (N2) + one cheap slot.
Rules that stay: bugs first (the grainy graph gets a test or a screenshot check), exact cents, never reclassify on amount alone, privacy (no personal figures in git),
targeted checks while developing, full suites once per stage.

## Further development (after N0–N4, in this order)
1. **M6 owner live test** continues alongside: collect findings in STATUS; each report goes before new features.
2. **Production relay:** move from the plain-http Lenovo test relay over VPN to HTTPS (Hetzner, `docs/setup.md` §6, Caddy). Then close the Lenovo's wide
   firewall range, drop the old `10.8.0.2` peer, add DDNS or retire the home relay.
3. **Money features from PATH_FORWARD:** P4 recurring classes (weekly … annual, instalments), P6 split transactions, P9 recurring income and biweekly periods,
   P10 merge from backup, P11 decimal style and localisation.
4. **Insight layer:** reports (P8), "saved by waiting", month-end review with the new graphs, forecasts of the end-of-period balance from accounts + planned costs.
5. **Quality:** perf budgets for the new graphs on a big wallet (`tools/build.sh perf`), accessibility at text scale 2.0, emulator screens for the new onboarding.
6. **Distribution:** signed release builds by manual `ci`; iPhone, Mac, Windows stay parked (owner decision).
7. **Resilience:** scheduled backups, restore drill on a second device, relay backup of its data folder, key-recovery instructions (the key is the only way in).
