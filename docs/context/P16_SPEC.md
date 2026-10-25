# Stage P16 spec: pay a slip, loan left, payment attachments (2026-10-25)

Plan item: PATH_FORWARD P16. Owner decisions (`NEXT_DECISIONS.md`):
- **"Pay"** copies the IBAN, amount and reference. Nothing is sent automatically.
- **Attachments on any payment** are stored like bill files.

Lead decisions after the scout:
- The "rest of period" strip is **dropped**: Today already shows days left, plan per day, the pace bar and ahead/behind.
- The loan has no interest data, so "amortisation" becomes an exact "payments left" line.

## P16a: Pay + loan (now, on v2)
### Pay (app)
- The bill sheet gets a **Pay** button (`billPay`) when the bill has an IBAN and an amount and isn't paid yet. It opens the Pay sheet (`paySheet`).
- **Rows**, each with a Copy button (`payCopy:<field>`):
  - Payee;
  - IBAN (grouped in 4s on screen, copied without spaces);
  - Amount (in the bank-app format "12,50", no currency sign, no grouping);
  - Model and reference, as stored (e.g. "HR01 1234-5678");
  - Description.
- "Copy all" copies the five lines together.
- A toast says "Copied". The clipboard is cleared after 60 s if it still holds our text: the `copyKeyBackup` pattern (`clipboardWrite`/`clipboardRead`, cleared again on resume).
- A note: "Paste these into your bank app. Nothing is sent from here."
- The bill isn't marked paid by this. The bank row still links it as today.
- Logs: `bill.payCopy {field}` only.

### Loan left (core + app)
- Core, pure: `LoanLeft? loanLeft(WalletSettings st, String today)` returns `{int payments, int cents, String endMonth}` when `loan > 0` and `loanEnd` is set and not past.
  - `payments` = the months from the current month to `loanEnd` inclusive. The current month counts only if this month's payment hasn't happened yet; use the plan's paydays: count the months whose payday date is ≥ today.
  - `cents = payments × loan`.
  - null otherwise.
  - Tests: boundaries (the month of loanEnd, a past end, payday today).
- Plan ledger: under the Loan line, "12 payments left · 3,600 € at this rate" (`ledgerLoanLeft`).

## P16b: attachments (after P14 is merged)
- An attachment is a **bill row** with `source: 'attachment'`, linked to the payment (`linkedTx`), with the file in `blob`/`blobType`/`blobBytes`, `total = |amount|`, status confirmed and paid.
  - It never reserves money, never appears in Bills' To review / Unpaid / Paid lists, and never joins matching or reminders.
  - It is listed only on its payment.
  - Up to 5 per payment.
- Because it is a live bill referencing the file, it rides on P14's invariants with no extra code: upload before ops, never deleted by clients, kept in the snapshot's declared set, and included in backups up to 16 MB.
- **App:** the payment sheet has an "Attach photo or PDF" button (camera on Android, or a file pick) with the same size checks as bills. The attachments are listed (open with `BillFileScreen`; remove with Undo).
- **Tests:**
  - an attachment never shows in the bill lists and never reserves money;
  - it appears in the snapshot's declared set;
  - it goes into a backup;
  - removing it and then Undo restores it;
  - two devices attach to the same payment.
