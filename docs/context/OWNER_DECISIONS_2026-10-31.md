# Owner decisions, 2026-10-30/31 (grill: every open question for further development)

Source of truth for these answers; PIPELINE.md holds the work they create. No personal figures here.

## Money and pay periods
- **Payday rule C** (replaces the RX7d 7-day early rule, which double-counted early salaries): a start within 7 days
  (`samePaydayDays`) of an expected payday belongs to it (late first, then early); otherwise the old rule (payday of the
  month after the start's month). Feb's pay on 2 Mar → period to 31 Mar. Built: RX7e (core, merged a4c9b41).
- **Saved start after the salary row** (salary 10 Oct, start set to 12 Oct): the salary day wins; the salary stays in the
  period it was paid in.
- **One stored period start**: accepted. Past reports group by salary dates; no history of starts (no schema change).
- **First start without a salary**: the app no longer saves today; the first period starts at the last expected payday
  before today (app change, queued).
- **D2 cash match**: the "never on amount alone" rule names this one exception (hand-added expense ↔ bank row: same
  amount, ±3 days, the adding device had not seen the row); matched rows show a mark and an **Unlink** action (queued).
- **Past periods**: spend heatmap, exact amount on tap, no within/over verdict (owner 2026-10-30, built RX7).
- **Report wording**: "Salary late" while the payday passed without a salary; "N days left" counted from the report's
  own period end (queued).

## Relay, hosting, M6
- **Pi**: not set up yet. Away-from-home sync during M6 keeps using the Lenovo test relay over VPN. Pi details come later.
- **CG-NAT**: unknown → the Pi setup starts with a check (router WAN IP vs public IP); Hetzner stays the fallback.
- **Quadlets**: drop (relay/deploy `*.container`, `.network`, `.env.example`, their setup.md parts). Local test relay
  (`tools/relay.sh`, `dev/Containerfile.relay`) and the native Pi path stay.
- **M6 drills**: all four (new phone relay alive; new phone relay dead + `.bwb`; switch relay and back; clock a day
  ahead) **plus** the key-rotation drill (back up, clear, new wallet, restore with the old key).
- **Device approval**: one-time prompt for existing wallets in Settings › Sync ("Require approval for new devices?"
  Turn on / Not now) (queued).

## What gets built
- **RX8**: build all (tag detail dashboard, 4 columns on desktop, layout tests, screenshots).
- **ZC zoomable graphs**: right after RX8. Label "budget share 112 €" for pro-rated week/day budgets is OK.
- **During M6**: features continue; owner bug reports always go first.
- **Web**: supported, local only (kept tested with web-test, never published).

## Known limits: all to be fixed (stage KL)
- Upcoming "Set aside" must equal Today's reserved total (overdue expected bill included).
- Planned cost closes itself only when exactly one bank row has the same category, the exact planned amount and a date
  within ±3 days; toast with Undo; otherwise "Paid by this?" as now.
- Search also finds merchant-rule names.
- Slip payee spelled differently: "Belongs to bill…" picker on the slip; the spelling is remembered as an alias of the
  bill's payee (exact, no similar-name guessing).
- Calendar: identify events by the calendar's own id (.ics UID / Android event id) plus start time; name + date only
  when a source has no id (a rename keeps its decision; same-name events stay separate).
- Old 20 Oct dev build re-pairing transfers: already impossible (relay api 5 refuses it); removed from the limits.
- Two offline devices "Add as new" the same slip: two bills (copy id must include the device).
- Stuck on a damaged sync file: the stuck device asks the author to resend its state; if the author is gone, Settings ›
  Sync offers "Skip damaged file" with a warning.

## Repo, tools, process
- Repo stays **private**. `docs/review/` stays.
- **Ruflo**: compare token use per commit against the saved baseline (`tools/token-usage.py`), then the owner decides.
- **Worktrees**: remove the ones fully merged into v2 (checked one by one); keep and list any with unmerged commits.
- **Perf**: accepted as is (60 Hz budgets), no rerun now.
- **Design-system artifact**: re-sync now with the Paper Tiles tokens and dash kit.
- **Tooling trim now**: remove `tools/install-hooks.sh` (never installed), the quadlet files, the `ci-watcher` agent
  (`tools/ci-status.sh` does the job), and history lines of deleted desktop tests (tmpchart, designer_walk, theme_shots).
