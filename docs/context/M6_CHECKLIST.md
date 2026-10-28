# M6 owner checklist

One ordered list for the live test. It replaces the "Owner checks after ..." lists in `STATUS.md`.
Do it in order. Tick as you go. Write down every doubt: date, screen, what you expected.
Tabs: Today, Budget, Bills, Save, Settings. Settings has the sections (Accounts, Rules, Sync, Backup and export, ...).

## 0. Before you start
- [ ] Update the phone, the laptop and the relay together (schema 18) -> every device opens with all its data.
- [ ] Do not leave one device on an older build for long -> an old build can miss newer data.
- [ ] Have the wallet key saved in your password manager (Settings > Sync > Show wallet key) -> you can read it back.
- [ ] Settings > Backup and export > Back up now first -> a `.bwb` file is saved.
- [ ] Relay on the Raspberry Pi is up (setup pending: model, OS, name, router forward 80/443, SSD) -> Settings > Sync > Test connection says OK.
- [ ] Uninstall any old APK built before the signing fix, once -> later updates install in place.

## 1. First run on a fresh install
- [ ] Start a new wallet -> "Save your wallet key" sheet opens.
- [ ] Type the last 4 wrong, then right -> wrong is refused, right is accepted.
- [ ] Tap "Later" -> the sheet closes, a key row stays on Today.
- [ ] Copy key, paste in the password manager, come back after 60 s -> the clipboard is empty.
- [ ] Type the key with a zero for the letter O -> it is still read.
- [ ] Show wallet key shows the QR first -> a screenshot is blocked, the recent-apps picture is blank.
- [ ] After the wallet is made the "Set up my wallet" guide starts -> it walks you through.
- [ ] In the guide, import a real bank file -> the preview sheet shows.
- [ ] In the guide, add accounts and cash (try Skip on the cash question in one wallet) -> Today shows "Held" when you add cash.
- [ ] In the guide, set the payday plan, confirm or reject bills ("Not a bill"), pick payee tags (then Undo one), set budgets -> each step saves.
- [ ] Finish the guide -> "Done" screen, then Today.
- [ ] Start again and close it half-way -> Today shows "Finish setting up"; tap it and continue.
- [ ] Settings > Set up my wallet again -> the guide runs again without losing data.
- [ ] Try the guide at large text size -> nothing is cut off.
- [ ] Join an existing wallet on the laptop (key + relay address) -> it asks for the create token only when making a new wallet on the relay.
- [ ] Try to join while a wallet is already there (Settings > Sync > Join another wallet...) -> it first asks you to confirm the key; Cancel works at every step.
- [ ] Complete a real join -> the old wallet is set aside on this device, not deleted.

## 2. Daily use
- [ ] Today shows safe-to-spend, the pay-period line and recent payments -> the numbers look right to you.
- [ ] Add expense on a fresh wallet -> it waits for a category.
- [ ] Add expense: type "lunch" -> chips appear under the note; tap one; the payee list shows while typing.
- [ ] Type "1.500" as an expense with the 1.234,50 number style on -> it becomes 1500.
- [ ] Spend past today's money, then past the plan -> two sentences, no negative figure.
- [ ] The add button never covers the last rows (Today, Budget, search results).
- [ ] Open a bank payment, pick a main tag and two extra tags, create a new tag -> Save keeps them; close with X -> nothing saved.
- [ ] Remove a tag that came from a rule -> it goes from that payment only.
- [ ] Use "Also tag every payment from ..." -> the other payments from that payee get the tag.
- [ ] Open a store payment > Split...: two parts -> "Left to split" counts down; Save stays off until 0.00.
- [ ] Split: the payment shows once with its parts under it; the category view shows each part.
- [ ] Remove split, then Undo -> parts come back with tags and notes.
- [ ] Split with 5+ parts at large text -> the editor still fits.
- [ ] Mark an expense "Lent to someone" -> it leaves the budget totals but stays in the list marked "lent".
- [ ] Set the same main tag by hand on 3 payments of one payee -> "Always put X in Y?" -> Make rule -> Undo.
- [ ] Delete an expense and a goal -> an Undo toast shows (also from the weekly review).
- [ ] Search: use filter chips (Amount with 1.234,50), bold matches, and the search button on Today's Recent panel.
- [ ] Search by a word, by an amount, by a tag, by your own category name -> matching rows appear.
- [ ] Search then delete a row -> Undo brings it back.
- [ ] Pay in another currency with no rate set -> "Other currencies, not counted: ... spent" on Today and Budget.
- [ ] Settings > Accounts > Currencies: set a rate (e.g. 0,9240) -> totals change, the "not counted" line goes; payment shows both amounts; Remove, then Undo.
- [ ] After a payday you have not started -> Today shows "Left this pay period" and "Start new period"; one tap starts it, even after missed months.
- [ ] A bill would overdraw a checked account -> Today shows a red "goes below zero" line.
- [ ] Expected income: confirm a suggested side income or add one -> Today says "Expected income ... (counts when it lands)" and safe-to-spend does not move; after import the plan shows "Extra income received".
- [ ] Weekly review on your review day -> finish it; the Done screen shows the streak and what waiting saved.
- [ ] Do a big buy -> you can name the wish and tap "Open".
- [ ] With storage full, save something -> "Couldn't save. Nothing was changed." over the sheet.
- [ ] Set the phone clock back 2 h and add an expense -> the clock dialog shows; set it right again.
- [ ] Turn on large text and dark mode -> Today, stat strip and sheets still look right.

## 3. Bank import
- [ ] Settings > Import: choose a PBZ file -> the preview sheet shows; Skip one row; Cancel once; then import.
- [ ] After a PBZ import, "What did the bank app show?" -> type a wrong number -> "Off by ..." -> Correct balance fixes it.
- [ ] Import a Revolut file -> "matches the bank" shows.
- [ ] Import the same file again -> nothing new.
- [ ] Import a CSV from another bank: Map columns, fix a shown problem, Save & import -> rows arrive.
- [ ] Import the same CSV again -> nothing new.
- [ ] Settings > Import > Saved file layouts: rename one, delete one, Undo -> works.
- [ ] After import, Settings > Accounts: balance and its "as of" date are right; Correct balance; Delete, then Undo.
- [ ] After import, the suggestions list: Accept one, "Not now" another -> only accepted ones apply.
- [ ] An own transfer between two accounts -> it does not count as spending or income.
- [ ] Attach a receipt to a hand-added expense, then import the bank file -> the receipt is now on the bank row.

## 4. Budget
- [ ] Budget tab starts with the payday plan -> lines add up to the total.
- [ ] Edit plan: change a field, Save; again, Cancel -> saved, then not saved.
- [ ] The plan shows loan payments left and "On payday: about X" with a chart; tap the chart -> a tooltip shows.
- [ ] Settings > Budgets per category > Suggest with some fields filled -> you are asked before any number you typed changes.
- [ ] Suggest on empty fields -> they fill; nothing saved until you accept.
- [ ] Settings > Categories: add your own category; add an expense in it -> it shows in the picker and in "Where it goes"; rename and hide a built-in one. (Finer groups are tags now, not subcategories.)
- [ ] Rename and hide a built-in category -> it changes everywhere.
- [ ] Add your own fixed category, fill its line in the plan -> today's amount drops; delete it and read the warning.
- [ ] Settings > Rules: add a "description contains" rule with a range, Preview, Save -> Preview count is right.
- [ ] A range with no text -> refused.
- [ ] Edit a rule -> Preview count updates. Delete a payee rule, then Undo.
- [ ] "Make a rule..." from a bank payment -> the rule is made.
- [ ] Insights: per pay period numbers and a main tag against its budget.
- [ ] Insights: Tags with its drill-down; the `#tag` chips on rows.
- [ ] Tap the date on a chart or range -> a date picker for a custom range opens.
- [ ] Charts in dark mode: spending bars a deeper blue, legend under the saved/lost chart, rounded bar tops, amber "Went out" on Income vs spending.

## 5. Bills
- [ ] Bills tab: Coming up first, then slips to review, Expected bills, the bills list.
- [ ] Top line shows "Bills and subscriptions: X a month · Y a year".
- [ ] Add bill: a yearly bill (e.g. insurance) -> Today shows "... held until paid" and safe-to-spend drops by the full amount.
- [ ] Add a bill with "The amount changes" (from-to) -> it sets aside the top of the range.
- [ ] Add a monthly bill with 12 instalments -> "12 payments left"; Edit, rename, Save -> the count stays.
- [ ] A bill with no payee: Mark paid, then Undo.
- [ ] The add-bill sheet fits at phone width with range and instalments on.
- [ ] The bank's standing orders appear as candidates -> Confirm the true ones, "Not a bill" the rest.
- [ ] Scan bill: a shop receipt QR, then a payment slip barcode -> fields fill.
- [ ] Scan bill: Take photo of a receipt with no code -> the camera app opens; fields marked "Unsure".
- [ ] Deny the camera once -> a hint shows.
- [ ] Share a PDF from email and a photo from the gallery into the app (closed and open) -> a slip is made.
- [ ] Confirm a slip -> it asks for a category; a utility covered by your plan says "covered by your plan".
- [ ] "Confirm bill" stays in view on the sheet.
- [ ] The confirmed bill shows in Coming up and lowers safe-to-spend.
- [ ] "Paid by..." a bank row -> the receipt mark shows on that row in the list.
- [ ] Scan the same slip next month -> "Add as new bill" is offered.
- [ ] A bill with an IBAN: Pay -> copy the IBAN and amount; Copy all.
- [ ] Set a return-by date -> a 09:00 reminder comes, with no payee or amount in it.
- [ ] Open a payment > Attach photo or PDF: take a photo (allow, then once refuse); pick a PDF; open it -> it opens.
- [ ] Remove an attachment, then Undo -> it returns. The button goes away at 5 files.
- [ ] Open the photo or PDF on the laptop after a sync -> it opens.
- [ ] Scan a bill with a photo, sync, delete the bill -> the file still opens on the other device until it syncs; Undo -> the photo is back.
- [ ] Add a planned cost (Coming up "+") -> safe-to-spend drops by it.
- [ ] Planned cost: Paid -> pick the payment -> Undo; Skip -> Undo.
- [ ] Today's "Due by payday" and "N bills to review" open the Bills tab.

## 6. Save
- [ ] Save tab shows goals above the wishlist.
- [ ] Add a goal and a wish; edit; delete and Undo.
- [ ] Owed: add an IOU, add a repayment, Close it, Delete it, Undo -> each works.
- [ ] Link a payment to an IOU -> only a payment with the exact same amount can be linked.
- [ ] Close an IOU with money still owed -> it counts as forgiven; the lent payment never becomes spending.

## 7. Settings
- [ ] Settings is one page with every section; the held-money and expected-income lines on Today jump to their section.
- [ ] On the laptop (wide window) Settings has two panes.
- [ ] Accounts: add cash and a bank account; Currencies is inside it.
- [ ] Main tags and tags: add, rename, delete -> rows and chips follow.
- [ ] Calendars and reminders: Allow calendar access (Android asks read only) -> events show as suggestions in Coming up.
- [ ] Confirm one calendar event (Today drops); "No cost" another (gone on the other device after sync).
- [ ] Add an `.ics` file and an `.ics` link; break the link -> "Showing what was saved"; an `http://` link shows a warning.
- [ ] A cancelled phone event is not suggested.
- [ ] Month: start a new pay month -> works as in Today.
- [ ] Look: Dark switches at once and stays after a restart.
- [ ] Look: the 1.234,50 number style changes amounts everywhere.
- [ ] Look: softer colours in sun and in dark mode; text is easy on the eyes.
- [ ] On the laptop: check the chart is not grainy; the rail at 1280 and 1920 wide (search, period badge, no top bar); the phone in landscape has no top bar.

## 8. Sync between phone and laptop
- [ ] Settings > Sync: relay address `https://<name>` -> Save address -> Test connection -> Sync now -> "Up to date"; the fingerprint shows under the address.
- [ ] Type a public `http://` address -> refused with an https hint (a home address still works).
- [ ] Sync shows "X of Y used".
- [ ] Laptop joins with the key and the same address -> it sees the phone's data.
- [ ] Add an expense on one device -> it shows on the other.
- [ ] Sync phone and laptop as usual -> nothing new appears; Sync shows no "different values" line.
- [ ] Change the same payment on both before syncing -> after sync both show the later change (no question asked). "Choose the right ones" in Settings > Sync appears only if data was damaged; it should never show in normal use.
- [ ] Settings > Sync > Recent changes after a sync -> it lists what came in.
- [ ] After a sync from the laptop, numbers update on the phone without reopening.
- [ ] Finish a weekly review on the phone and another on the laptop days later before syncing -> the streak counts both.
- [ ] Add the same slip as a new bill on two devices before syncing -> you get one bill.
- [ ] Use the bill sheet, import and backup buttons -> they show busy while working.

## 9. Backup, restore, merge, export
- [ ] Back up now -> a `.bwb` file is saved through the Android file dialog.
- [ ] Restore into an empty wallet -> all data returns.
- [ ] Restore with another wallet's key -> "made with another wallet key"; use "Restore a backup made with another key...".
- [ ] Cut a `.bwb` in half and restore -> "damaged".
- [ ] Merge a backup...: read the preview; Cancel changes nothing; merge; merge the same file again -> "Nothing new".
- [ ] Export spending as CSV and open it in a spreadsheet -> Croatian letters are right.
- [ ] Export planned costs (.ics) -> opens in the phone's calendar.

## 10. Android only
- [ ] Add the "Safe to spend today" widget -> it matches Today; tap opens the app.
- [ ] After midnight the widget says "Open the app to update" until you open the app.
- [ ] Long-press the app icon > Add expense, app closed and app open -> the sheet opens; the app does not restart.
- [ ] Settings > Calendars and reminders: Nudges on, allow notifications (Android 13 asks) -> one comes about 15:00 with no amounts (battery saver may delay it).
- [ ] Heads-up on -> a notification at 09:00 before a cost of 100 or more, with no amount.
- [ ] Camera: scan, photo, deny and allow -> as in Bills.
- [ ] FLAG_SECURE: Show wallet key blocks screenshots and the recent-apps thumbnail is blank.
- [ ] TalkBack: the Undo toast stays until handled.
- [ ] Install the new APK over the old app -> data stays.
- [ ] Seal a 15 MiB PDF as an attachment -> note how long it takes.

## 11. Disaster drills (once each)
- [ ] (a) New phone, relay alive: install, join with the key and address -> all data comes back.
- [ ] (b) New phone, relay dead: install, make a new wallet, "Restore a backup made with another key..." with the `.bwb` -> data comes back.
- [ ] (c) Switch the relay address to a second relay and back -> the app reports a reset, then recovers.
- [ ] (d) Laptop clock a day ahead for one sync -> the sync is held back with a clock problem; set the clock right and it recovers.
- [ ] Key rotation once: back up, clear app storage, new wallet, restore with the old key -> works.

## 12. Send logs
- [ ] Settings > Diagnostics > Save logs... -> one file is saved.
- [ ] Send the file to Claude (it goes in `~/.local/share/budget-wallet/device-logs/`).

## Known limits you might hit
- Search does not match merchant-rule names, only the cleaned description, note and category.
- An older import with a huge amount (over 1,000,000,000.00) still syncs, but a new one is refused.
- A payment that was partly a loan cannot be linked to an IOU; add the IOU without a payment.
- The red "below zero" warning counts only bills last paid from that account.
- The bank balance from a file is missing when one app account holds several bank accounts or Revolut pockets of one currency.
- Two calendar events with the same name on one day show as one; renaming one suggests it again.
- A planned cost holds money until Paid, Skipped or its day passes.
- A slip whose payee is written differently from the bank text is not matched to its expected bill.
- Upcoming "Set aside" leaves out an overdue bill that Today still reserves.
- Photos are not in `.bwb` backups; they stay on the relay.
- A device on an old build (before 2026-10-20) can re-create paired transfers; update all together.
- A device off for over 30 days after the others upgraded may miss IOUs until they are edited again.
- A device can get stuck on a damaged sync file in rare cases (see core notes).
