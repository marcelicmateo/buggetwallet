# Budget Wallet — 10 directions × 12 screens (build spec)

Canvas: https://claude.ai/artifact/Vfy7FfEXoXVDKAJgYG4NKU (Design type)
Root folder (holds `project/`): /tmp/claude-0/-home-claude/7a1f6210-a358-5200-9862-2e86dafe0dcb/scratchpad/bw-dirs
Each direction writes 12 files: `project/dNN-<Screen>.dc.html` (NN = 01..10). The index `project/canvas.json`
already lists every board — DO NOT write or send canvas.json or Main.dc.html.

## Publish (one call per direction, after all 12 files are written)
Artifact tool, action publish:
- url: https://claude.ai/artifact/Vfy7FfEXoXVDKAJgYG4NKU
- root: /tmp/claude-0/-home-claude/7a1f6210-a358-5200-9862-2e86dafe0dcb/scratchpad/bw-dirs
- file_path: <root>/project/dNN-Welcome.dc.html (absolute)
- files: {"project/dNN-Today.dc.html":"project/dNN-Today.dc.html", ... the other 11}
No capabilities, contract, type_url, icon. If refused because the artifact changed meanwhile, publish the same
call again (up to 4 tries). Never publish index.html, SKILL.md, artifact-type/*, canvas.json or Main.dc.html.
Do NOT verify, render, screenshot or read files back.

## The 12 screens (file stems, exact)
1. `Welcome` — onboarding: app name, one-line promise ("Your money, on your devices."), short privacy line
   (stored here first, works offline, sync encrypted with a key only your devices have), buttons
   "Start a new wallet" and "Join my wallet from another device". No nav bar.
2. `Today` — app bar (mark + "Budget Wallet", pay-period chip "10 Oct – 9 Nov"); hero "Safe to spend today" 14 €;
   line "Today's allowance is 14.10 €. Spend less today and tomorrow gets more."; stats: 310 € left until payday,
   22 days to 10 Nov, 16 € plan per day; pace: 190 € of 500 € used, 45 € behind pace (status, not colour alone);
   big "Add expense" button; Payday checklist card "Move 280 € to savings" + "I moved 280 €";
   Recent: Lidl · 18 Oct · Groceries · Revolut · −23.40 € ; Bolt · 17 Oct · Transport · added · −6.80 € ;
   Salary · 10 Oct · Income · PBZ · +1,450.00 € (income in the good colour). Nav bar, Today active.
3. `AddExpense` — Today dimmed behind a bottom sheet "Add expense": amount field 65.00 € (€ AFTER the number),
   category chips (Groceries, Eating out, Transport, Shopping selected, Food delivery), Note "Jacket", Date "Today",
   impulse warning "Over 50 €: wishlist first?" + "Your rule says big buys wait 72 hours." buttons
   "Put on wishlist" (primary) and "Add expense anyway".
4. `Spending` — "Saved 110 € over the last 5 pay periods" + savings rate 2%; bar chart per pay period
   (10 May +120, 10 Jun +150, 10 Jul −180, 10 Aug +40, 10 Sep −20, 10 Oct +260 running/faded) with a 3-period
   average line; month chips Aug / Sep / Oct (selected); "October: 717 € out"; category bars with average tick:
   Rent 450 (avg 450), Groceries 160 (avg 210), Eating out 70 (avg 60), Transport 25 (avg 40),
   Bills & subscriptions 12 (avg 14); Top places: Lidl 96 €, Konzum 64 €, Wolt 38 €, Bolt 25 €. Nav: Spending.
5. `Transaction` — Spending dimmed behind a sheet: Lidl, −23.40 €, Sat 18 Oct 2026 · Revolut · Card payment;
   Category chips (Groceries selected); checkbox "Always use this for Lidl"; attached bill row
   "Receipt · 18 Oct 17:42 · 23.40 €" (marked New); buttons Save, Delete (danger, text).
6. `Wishlist` — "Can I afford it?" check: item field "Running shoes", price 89 €, verdict "Fits this month"
   (+ new daily 12 €); rule line "Anything over 50 € waits 72 hours on the wishlist first.";
   Ready to decide: Running shoes 89 € → Buy it / Skip; Cooling off: Headphones 129 € · 41 h left,
   Desk lamp 55 € · 2 d left; Decided: Smartwatch 199 € skipped; "Saved by waiting: 199 €". Nav: Wishlist.
7. `Goals` — "1,950 € put aside"; line "Each goal takes its monthly amount off the top on payday.";
   Emergency fund 1,200 € / 3,000 € · 100 € a month · Apr 2028; Yearly costs 300 € / 1,200 € · 100 € a month ·
   Jul 2027; New laptop 450 € / 1,400 € · 80 € a month · Oct 2027 (progress bars); "Extra money this month"
   card: "Salary came in 0 € above plan. Other income: 35 €." + "New goal" button. Nav: Goals.
8. `GoalEdit` — Goals dimmed behind sheet "Edit goal": Name "New laptop", Target 1,400 €, Each month 80 €,
   Put aside so far 450 €, result line "Reached in Oct 2027", buttons "Save goal" + "Delete" (danger).
9. `Plan` — "Payday plan: 500 € to spend · 16 €/day" with the breakdown Salary 1,450 € − Rent 450 € − Loan 180 €
   − Bills & subs 40 € − Savings 280 € = Spending money 500 €; segmented "Plan on salary | Plan on received";
   Numbers form (Salary per month, Rent, Loan, Bills & subs, Payday 10, Wishlist above 50 €, Wait 72 hours) +
   "Save numbers"; Weekly review card "Import bank exports" (PBZ .xls, Revolut .xlsx/.csv) + "Choose files" and the
   last result "PBZ: 12 new, 40 already here, 2 matched to expenses you added."; links to Sync and Diagnostics.
   Nav: Plan. (Tall content may be cut by the frame bottom — scrolled page; keep the top part complete.)
10. `Sync` — "Your devices": sync folder "Syncthing / BudgetWallet", last synced 2 min ago, "Sync now";
   devices: Pixel 8 (this device), ThinkPad laptop · 5 min ago; "Show wallet key" with the key masked
   "BW1-•••••-•••••-•••••" + Copy; warning "Anyone with this key can read your wallet."; back arrow, no nav
   (or nav with Plan active).
11. `Bills` (NEW feature — mark with a small "New" tag) — "Bills" with search field; "To review (2)":
   HEP electricity · e-invoice from inbox · due 28 Oct · 42.18 € ; A1 internet · PDF · 25.99 €;
   October: Lidl receipt 18 Oct 23.40 € (linked to bank ✓), Konzum receipt 15 Oct 31.20 € (linked ✓),
   Plin slip 12 Oct 18.50 € (waiting for import). Buttons "Scan bill" and "Import file". Nav: Spending.
12. `ScanBill` (NEW) — camera/viewfinder frame with a receipt and a detected QR outline (draw simple shapes),
   then "Read from fiscal QR code" fields: Shop Lidl, Date 18 Oct 2026 17:42, Total 23.40 €, JIR (read) shown as
   "JIR 3f9c…e21a", Category Groceries; note "Links to the bank row at the next import"; buttons "Save bill" and
   "Retake".

Copy rules: plain, short, second person; sentence case; NO emoji; no exclamation marks; euro sign AFTER the amount
with a non-breaking space (`14&nbsp;€`, `−23.40&nbsp;€`, `+1,450.00&nbsp;€`); dates "18 Oct". All numbers above are
made up; use only them.

## Format rules (every file)
- Skeleton exactly as the Design type: `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>…</title>
  <script src="./support.js"></script></head><body><x-dc><helmet><link …google font css2…><style>body{margin:0}</style></helmet>
  <div style="width:390px;height:844px;overflow:hidden;position:relative;…">…</div></x-dc>
  <script type="text/x-dc" data-dc-script data-props='{"accent":{"editor":"color","default":"#xxxxxx"},"$preview":{"width":390,"height":844}}'>
  class Component extends DCLogic { renderVals() { return { accent: this.props.accent ?? '#xxxxxx' }; } }</script></body></html>`
- Google Fonts only via `<link href="https://fonts.googleapis.com/css2?family=…&display=swap" rel="stylesheet">` inside `<helmet>`.
- Root fixed 390×844, overflow hidden. Inline styles for everything; `<helmet><style>` only for body margin, a/a:hover.
- Close every element, quote every attribute. No `{{ }}` expressions (only `{{accent}}` lookups). No script-built UI.
- Lists can be written out literally (preferred) — no need for sc-for.
- Icons: inline stroke SVG (aria-hidden="true"), never emoji, never icon fonts.
- Real `<button>`, `<input>` with `<label>` where relevant; icon-only buttons get aria-label. Touch targets ≥44px.
- Text contrast ≥4.5:1 (3:1 for 24px+). Status never by colour alone (icon or word).
- No fake phone status bar. Bottom nav (5 tabs: Today, Spending, Wishlist, Goals, Plan) on tab screens.
- Charts: build from divs or one small inline `<svg>` per chart; keep them readable.
- Sheets: render the underlying screen simplified and dimmed (a scrim div) with the sheet on top.
- Stay consistent across your 12 screens: one palette, one type pairing, one shape language, same nav.
- Make the direction's SIGNATURE idea visible on every screen, not only on Today.

## The 10 directions
D1 Baseline — the current app, Material 3, from the Budget Wallet design system. Roboto (+ Roboto Mono for amounts).
   Colors: bg #eef1ef, surface #ffffff, surface-2 #f6f8f7, ink #121716, ink-2 #48514e, muted #7b8582 (labels only),
   line #dde3e0, accent #2f45c8, accent-soft #e5e9fb, good #0f7a0f, bad #c23535, warn-bg #fff4dc, warn-ink #6b4a00,
   pos #2a78d6, neg #e34948, selected #dee1f9. Panels radius 14 with 1px line border, no shadow; buttons pills;
   sheets radius 28 top; chips radius 8; hero 68px/800/−2px. Page = column of panels, 16px gutter, 14px gaps.
   Signature: faithful to the shipping app (the reference point for the others).
D2 Night Shift — dark, bold, high contrast. Space Grotesk + JetBrains Mono. bg #0b0d10, surface #15181d,
   ink #f2f4f7, ink-2 #a9b0bb, accent lime #c6f432 (text on lime = #0b0d10), bad #ff6b6b, good #5ce08a.
   Square-ish radius 6, hairline borders #262b33. Signature: giant lime number, everything else recedes.
D3 Ledger — bookkeeping paper. IBM Plex Sans + IBM Plex Mono. bg #f7f5ef paper, ink #1d2433, ruled lines #d8d3c4,
   accent ink-blue #1f3fa8, red ink #b3261e for overspend, good #2e6b2e. No cards: ruled rows, right-aligned mono
   amounts in columns, double rule under totals. Signature: every screen reads like a ledger page.
D4 Swiss — strict 4-column grid, Archivo (+ Archivo Narrow), black #111 on white, one red #e3120b, greys #6b6b6b.
   No radius, thick 2px black rules, huge flush-left numerals (Today hero 120px), lots of white. Signature: typographic grid.
D5 Soft Blocks — friendly, rounded. Manrope. bg #f4f1fb, ink #221b3a, blocks in pastels (lavender #e3dcff,
   mint #d4f3e4, peach #ffe1cf, sky #d9ecff, butter #fff1b8), accent #5b3fd6, bad #c0392b. Radius 24, blocks not
   lines; each category has its own pastel; bubbly pills. Signature: colour-coded blocks per category/goal.
D6 Receipt — the app as a thermal receipt. JetBrains Mono throughout (+ Space Grotesk for one display size).
   bg #e9e6df, paper strips #fffdf7 with zig-zag/torn top and bottom edges (CSS), ink #1a1a1a, accent #0a6cff,
   bad #c62828, dashed separators. Signature: every screen is a printed slip; totals like a till receipt.
D7 Cockpit — data-dense instruments. Sora + IBM Plex Mono. bg #0f1730 navy, surface #16213f, ink #e8edf7,
   ink-2 #a3b0c9, cyan #3fd0e0, orange #ff9f43 (over/behind), good #4cd38a. Rings and gauges (SVG arcs) for
   safe-to-spend, pace, goals. Signature: gauges and dials everywhere.
D8 Calendar — time-first. DM Sans + DM Mono. bg #ffffff, ink #1c1f24, line #e6e8ec, accent teal #0f766e,
   accent-soft #ccfbf1, bad #b42318, warn #b54708. Today shows the pay period as a day grid (10 Oct–9 Nov) with
   each day's spend/allowance; other screens keep a date strip/timeline. Signature: money laid out over days.
D9 Editorial — a calm magazine. Newsreader (serif display) + Source Sans 3 (body). bg #fbfaf7, ink #1b1b1b,
   ink-2 #555, accent deep green #1d5c3a, bad #a1261d, hairline #e4e0d8. Numbers live in sentences:
   "You can spend 14 € today." Large serif headlines, generous margins, small caps labels. Signature: sentences, not widgets.
D10 Voice First — accessibility and voice. Atkinson Hyperlegible. bg #ffffff, ink #0a0a0a, accent #0047ff,
   accent-ink white, bad #b00020, good #006b2e, yellow focus #ffd400. Huge type (hero 96px, body 20px), one main
   action per screen, full-width 64px buttons, a mic button "Say it" on every tab screen, minimal secondary info
   (put the rest below the fold). Signature: one big answer, one big action, speakable.
</content>
</invoke>
