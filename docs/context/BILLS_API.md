# Bills database — API (stage B, spec DESIGN_DECISIONS §4.2 + owner decisions 2026-10-22)

Fixed by the lead so readers/core (B1), relay (B2), tests (B3) and app (B4) build in parallel. Additions are fine;
renames are not. Amounts are cents (positive = what the bill asks), dates `YYYY-MM-DD`. **Logs never carry payee, IBAN,
reference, JIR/ZKI, invoice numbers, item names, amounts, file names or hashes** — counts, sources and enum words only.
Every value read from a code, a file or a photo is a suggestion: nothing reaches money until the owner confirms the bill.

## 1. Readers (`packages/wallet_importer/lib/src/bills/`, pure Dart, web-safe, never throw)
```dart
enum BillSource { receiptQr, hub3, eInvoice, pdf, photo, manual }
class BillItem { final String name; final String? quantity; final int amount; }  // amount = line total, cents
/// payer fields of a slip (the owner's own name/address) are never read into it.
class NormalizedBill {
  final BillSource source;
  final String? externalId;   // 'jir:<uuid>' | 'zki:<hex>' | 'inv:<supplier id or IBAN>:<invoice no>' | 'hub3:<IBAN>:<model reference>:<amount>:<DESCRIPTION>' (B5a)
  final String? date, dueDate, payee, iban, reference, description;  // reference = 'HR01 1234-5678' (model + poziv na broj, normalized)
  final int? total;           // null = not found
  final String currency;      // 'EUR' default
  final List<BillItem> items; // e-invoice lines; empty otherwise
  final int unsure;           // fields guessed from free text (pdf/photo): the UI marks them
}
NormalizedBill? readFiscalQr(String payload);   // Croatian receipt QR: https://porezna.gov.hr/rn?jir=…|zki=…&datv=YYYYMMDD_HHMM&izn=<amount>
                                                 // izn: cents ('1234') or decimal ('12,34'/'12.34'); other hosts/shapes → null
NormalizedBill? readHub3(String payload);       // PDF417 'HRVHUB30' (LF or CRLF, 14 fields): currency, 15-digit amount (cents), payer ×3
                                                 // (skipped), payee name/street/city, IBAN (HR checksum checked), model, reference, purpose, description
NormalizedBill? readEInvoice(String xml);       // UBL 2.1 Invoice/CreditNote (EN 16931, HR CIUS): ID, IssueDate, DueDate (or PaymentDueDate),
                                                 // supplier name, PayeeFinancialAccount ID, PaymentID, PayableAmount (+currencyID), InvoiceLine items;
                                                 // CreditNote → null for now (counted in logs)
String? pdfText(Uint8List pdf);                  // text layer: FlateDecode streams, Tj/TJ/'/" text, ToUnicode CMaps (bfchar/bfrange),
                                                 // WinAnsi fallback, page order; encrypted/no text/over 20 MB or 5·10⁶ ops budget → null
NormalizedBill? billFromText(String text, {required BillSource source}); // pdf text or OCR text: IBAN (HR + checksum), 'HR\d\d' model +
                                                 // reference, labelled amounts (Ukupno, Za platiti, Iznos, Sveukupno, Total, 'UKUPNO EUR'),
                                                 // Rok plaćanja / Datum dospijeća / Dospijeće, Datum (računa|izdavanja), JIR/ZKI after their label,
                                                 // Croatian and ISO dates; a HUB-3 block printed as text is read like readHub3;
                                                 // two different labelled totals → total null; every guessed field counts in `unsure`
```
Synthetic fixtures only (`tools/make_fixtures.py` gains bill generators: QR payloads, HUB-3 payloads, UBL XML, small
PDFs with a text layer incl. one with a ToUnicode CMap and one compressed; never a real bill).

## 2. Data (synced entity `bill`, table `bills`, schema 7)
```dart
enum BillStatus { review, confirmed }
class Bill {
  final String id;              // 'bill:<32 hex of SHA-256(externalId)>' when externalId, else random 'b…' (devices converge per bill)
  final BillSource source; final BillStatus status;
  final String? externalId, date, dueDate, payee, iban, reference, description, category, note;
  final int? total; final String currency;
  final List<BillItem> items;   // stored as JSON text in `items` (validated: ≤ 500 items, name ≤ 200 chars, int amounts)
  final String? linkedTx;       // the payment (bank row or hand-added expense); bills are information: the row's category is never changed
  final String? warrantyUntil, returnBy;
  final String? blob, blobType; final int? blobBytes;   // blob = hex SHA-256 of the sealed file on the relay; type 'jpg'|'png'|'pdf'|'xml'
  final bool deleted;
  bool get paid => linkedTx != null;
}
```
Repo (all writes through `_write`):
```dart
List<Bill> bills({bool includeDeleted = false});
/// Adds a bill as status review (or returns the existing id for the same externalId; then only empty fields are
/// filled and nothing confirmed is overwritten). Returns (id, isNew).
(String, bool) importBill(NormalizedBill b, {BlobRef? file, bool asNew = false});   // asNew: B5a
void updateBill(String id, {String? date, String? dueDate, int? total, String? payee, String? iban, String? reference,
    String? description, String? category, String? note, List<BillItem>? items, String? warrantyUntil, String? returnBy,
    bool clearDueDate = false, bool clearWarranty = false, bool clearReturnBy = false, bool clearCategory = false});
void confirmBill(String id);           // review → confirmed; needs date and total (> 0) else ArgumentError; B5a: an unpaid bill due
                                       // from today on also needs a category (updateBill first) else ArgumentError
void linkBill(String id, String txId); // the owner picked the payment; one bill per tx (linking a tx used by another bill → ArgumentError)
void unlinkBill(String id);
void deleteBill(String id);            // also queues its blob for deletion on the relay (if no other live bill points to it)
String addExpenseFromBill(String id, {required String category}); // cash receipt: a hand-added expense (amount −total, date, payee as
                                       // description) and the link, in one write
```
**Planned cost from a bill:** a confirmed, unpaid bill with `dueDate` ≥ today and a total has one planned row
`bill:<billId>` (source `bill`, sourceRef billId, title = payee or 'Bill', amount = total, date = dueDate, category):
written by `confirmBill`/`updateBill`, closed (`markPlannedPaid` with the tx) by `linkBill`, deleted with the bill.
So a slip "to pay by the 15th" reserves money like any planned cost and shows in Upcoming.

**Auto link (deterministic, only while `syncCaughtUp`, in `_reconcile` like matching):** a confirmed unpaid bill links to a
live bank expense when the row's normalized description contains the bill's reference digits (model + poziv na broj,
≥ 6 digits), its JIR, or its invoice number (≥ 4 chars), **and** −amount == total, dated from bill date − 3 to
(dueDate ?? date) + 60. Several candidates → none (stays for the owner). Never by amount alone.
```dart
/// "Paid by this?" candidates: live expenses dated date − 3 .. (dueDate ?? date) + 30, not linked to another bill;
/// payee words found in the description first, then date distance, then amount closeness. Never filtered by amount.
List<CategorizedTx> billCandidates(Bill b, List<CategorizedTx> txs, List<Bill> all);
```

## 3. Upcoming and reminders
`UpcomingKind` gains `warranty` and `returnBy` (keys `w:<billId>`, `r:<billId>`, amount null, never counted; title =
payee or description). `upcoming(..., billsDb: List<Bill>)` lists confirmed, not deleted bills' `warrantyUntil` /
`returnBy` in range (the bill's planned row is already listed as `planned`); `UpcomingItem.billDb` holds the bill for those items. Settings (synced): `returnReminderDays`
(default 3, 0..30), `warrantyReminderDays` (default 14, 0..90).
```dart
class BillReminder { final Bill bill; final UpcomingKind kind; final String date; final int daysLeft; }
List<BillReminder> billReminders(List<Bill> bills, String today, {required int returnDays, required int warrantyDays});
```
App notifications: ids 1020..1039, channel `bills`, 09:00 on (date − days); text without payee, amount or item:
"A return window ends in 3 days" / "A warranty ends in 14 days".

## 4. Blobs (photos, PDFs; `RELAY_PROTOCOL.md` "Blobs")
```dart
class BlobRef { final String hash; final String type; final int bytes; }   // bytes = plain size
class BlobStore {                       // core, web-safe; needs the wallet key
  BlobStore(WalletRepo repo, VaultKey key);
  /// Seals [plain] (≤ 15 MiB, else ArgumentError), keeps it in the local cache, queues the upload; returns the ref.
  Future<BlobRef> add(Uint8List plain, String type);   // async: seal() is async (B1b, 2026-10-22)
  /// Plain bytes: from the cache, else fetched from [transport] (sha256(sealed) checked, unsealed with the key, cached);
  /// null when not on this device and not reachable / not on the relay.
  Future<Uint8List?> read(String hash, {SyncTransport? transport});
}
```
Device-local tables (never synced, not in backups): `blob_cache(hash, sealed, used_at, bytes)` (LRU, 200 MiB native /
50 MiB web; never evicts a hash still in `blob_outbox`), `blob_outbox(hash)`, `blob_delete(hash)`. `SyncTransport`
gains `putBlob(hash, bytes)`, `getBlob(hash)` (null on 404), `deleteBlob(hash)`; `MemoryTransport` and `RelayTransport`
implement them. `SyncEngine.run` uploads `blob_outbox` before the ops (a failed or refused blob stays queued; the run goes
on; `SyncReport.blobsWaiting`), then sends `blob_delete`. Backups (`.bwb`) carry the rows, not the blobs.
Images are downscaled by the app before `add` (longest side 2560 px, JPEG); PDFs and XML as they are.

## 5. Search and export
`searchAll(..., billsDb:)` adds `SearchResult.billsDb` (payee, description, item names folded; exact total).
No CSV for bills yet.

## 6. App (B4) entry points
Add expense › **Scan bill** (Android: `mobile_scanner` reads QR → `readFiscalQr`, PDF417 → `readHub3`; "Take photo"
keeps the frame and runs ML Kit text recognition → `billFromText(source: photo)`), Plan › **Bills** (To review /
Unpaid / Paid lists, Import bill file: pdf, xml, jpg, png → readers; Android PDFs also rendered page by page with the
platform `PdfRenderer` (own small channel, no package) and scanned for codes), **Share to app** (`receive_sharing_intent`,
Android) → To review, bill sheet (fields with "unsure" marks, items, photo/PDF on demand, Confirm, Paid by… candidates,
Add as cash expense, warranty / return-by dates, Delete), Today row "N bills to review", Spending row mark when a bill is
linked, Upcoming warranty/return entries, reminders. Linux/web: file import (PDF text, XML); photos are kept unread.

## Decisions and additions (B1b, core, 2026-10-22)
- `BlobStore.add` is async (`Future<BlobRef>`): sealing is async and the hash is over the sealed bytes.
  `BlobStore(repo, key, {maxCacheBytes = blobCacheBytesNative})` (`blobCacheBytesWeb` = 50 MiB for the web app);
  `maxBlobPlainBytes` (15 MiB), `blobTypes`, `isBlobHash`, `sha256Hex`. An empty file is an `ArgumentError` too.
- Barrel re-exports `BillItem`, `BillSource`, `NormalizedBill` from wallet_importer. Additions: `Bill.title` (payee or
  `Bill`), `Bill.confirmed`, `Bill.file` (`BlobRef?`), `Bill.unsure` (stored, column `unsure`), `WalletRepo.bill(id)`,
  `WalletRepo.billPlannedId(billId)`, `UpcomingItem.billDb` (the `Bill` of a warranty/return item; its title = payee, else
  description, else ''), `SyncReport.blobsSent`. Pure helpers: `planBillLinks`, `billLinkTokens`, `descriptionHasToken`,
  `normalizeForLink`, `billLinkWindow`, `encodeBillItems`/`decodeBillItems`.
- `importBill`: the creation op carries no `status`/`deleted` (a late import on another device never undoes a confirm or
  delete; the same bill imported on two devices before a sync: the later import's read fields win over an edit made in
  between, like tx rows). Re-import of a live bill: review → only empty fields; confirmed → only `items` (when empty) and
  the file (when none); never date, due date or total. A deleted bill read again is revived as a new review bill
  (isNew true, read values replace the old ones). Reader values that are not valid are dropped, not thrown (bad dates,
  total ≤ 0, items cut to 500 / names to 200). A file the bill does not take is dropped again (forgotten if never
  uploaded, else queued for relay deletion).
- Planned row: created only when the due date is today or later (an existing row follows edits, a cleared due date or
  total deletes it, setting it again restores it); `confirmBill`/`updateBill`/`linkBill`/`unlinkBill`/`deleteBill`/
  `addExpenseFromBill` and the auto link keep it in step; rows are soft-deleted like every planned row.
- `addExpenseFromBill` also confirms a review bill (adding it as money is the owner's check); the expense's `seen_bank`
  is set like `addManual`. `linkBill` accepts a review bill too (no planned row exists for it).
- Deleting the paying transaction makes its bill unpaid at once (planned row reopened), like a deleted match.
- Auto link tokens are compared on `normalizeForLink` text (accents folded, A–Z/0–9 only) with digit boundaries
  (`12345678` is not found inside `9123456789`): the reference as model + number and the number alone (≥ 6 digits),
  the JIR, the invoice number after `inv:<supplier>:` (≥ 4 characters). A window without a bill date uses the due date.
  Only bank rows (not hand-added, not an own transfer, same currency). It runs in `_reconcile` (caught up only) and at
  `confirmBill` (while caught up, else on the next caught-up run). A link once made is never re-planned: rows imported
  one by one link to the first candidate; two candidates in one import link none.
- `billCandidates`: date distance = the smaller distance to the bill date or due date.
- `billReminders`: windows ending from today to today + days (inclusive), like `headsUps`; the app passes a longer
  horizon to schedule notifications.
- Blobs: the relay creates a wallet only with a device's first file, so a blob refused as 404 before this device's first
  upload is retried once after the ops in the same run. Every queued blob is tried (a failure never stops the others or
  the run). Cached files of bills deleted elsewhere are purged on the next caught-up run. `MemoryTransport` hooks:
  `blobs`, `blobRoutes` (false = older relay), `tamperBlob`. `SyncTransport`'s default blob methods behave like an older
  relay (404), so other transports compile unchanged.

## Decisions and additions (B5a, review fixes, core, 2026-10-22)
- **Double reserve.** A bill that would reserve (confirmed, unpaid, total, due date from today on) needs a category:
  `confirmBill` and any `updateBill` leaving it so without one throw `ArgumentError('The bill needs a category.')` (the app
  asks; a bill in review, one without a due date, one due before today or a paid one needs none). The planned row carries
  it, so a slip in a fixed category (Bills & subscriptions, Rent, Loan) is `PlannedCost.coveredByPlan`: listed, never
  reserved on top of the payday plan. `String? suggestBillCategory(Bill b, {required List<RecurringBill> recurring,
  required List<CategorizedTx> txs})`: the confirmed recurring bill with the same payee key → its category; else the latest
  live bank expense (not hand-added, not an own transfer) whose description holds a payee word (`billPayeeWords`, the
  `billCandidates` rule) → its category; else null. Never by amount.
- **Slip of a confirmed recurring bill.** `String? billPayeeKey(Bill)` = `merchantKey` of a bank row described by the
  payee (the `RecurringBill.payee` rule; null without letters). `RecurringBill? billCoveredBy(Bill, List<RecurringBill>)`:
  a confirmed recurring bill with exactly that payee key whose cycle `nextDue + k × intervalDays` (k ≥ −1; k = −1 is the
  cycle just paid or skipped) is within ± 3 days (`recurringDays`) of the bill's due date. Decided **when read**, not
  written: the bill keeps its planned row, but `RecurringBill? plannedCoveredBy(PlannedCost, List<RecurringBill>)` (a
  `bill`-source row: payee = title, due = date) makes `computePeriod` list it in `duePlanned` without reserving it, and
  `upcoming` / `plannedIcs` leave it out (the recurring occurrence stands for that payment). So both orders (slip first or
  recurring bill first) and later changes (confirm, dismiss, delete, skip, a payment moving `nextDue`, on any device)
  give the same result with no extra writes, and an owner's skip/paid/delete of the planned row is never overwritten.
  The bill stays in Bills (unpaid, linkable, reminders); the app can show "planned by <recurring label>" with
  `billCoveredBy`. Exact key match only: a slip payee that differs from the bank text (`Synth Energy d.o.o.` vs
  `SYNTH ENERGY ZAGREB`) is not matched, and then only the category rule above prevents a double reserve.
- **HUB-3 ids per period.** `readHub3` externalId = `hub3:<IBAN>:<model reference>:<amount>:<description>` (description
  with runs of spaces made one, upper case, empty when none), so a monthly flat fee (`HR99`, no reference, same amount)
  with "03/2026" vs "04/2026" is two bills. Bills stored before B5a keep their old id (a re-scan of such a slip is a new
  bill once). For two slips that read exactly alike, `importBill(b, asNew: true)` stores a separate bill: id
  `Bill.idFor('<externalId>#<n>')`, n = the first ≥ 1 not used by a live bill (a deleted copy is revived), external id
  unchanged. Two devices adding a copy before they sync pick the same n, so their copies are one bill (later import's
  read fields win), the same rule as one slip scanned on two devices.
- **Payment deleted on another device.** `_autoLinkBills` (caught up only) first unlinks every live bill whose `linked_tx`
  is a deleted row here (through `_billWrites`: the planned row reopens while due), then plans links; the deleting device
  still unlinks at once. Covers a link made on one device while the other deleted the row.
- **Invoice tokens.** `billLinkTokens`: an invoice number of digits only needs ≥ 6 digits (like a reference: `1234`,
  `2026` never link to `KARTICA ****1234` / `PRETPLATA 2026`); a mixed one ≥ 4 characters with a letter and a digit; letters
  alone never.
- **Orphan files.** Device-local `blob_own(hash)`: files this device attached to a bill (`importBill` when the bill takes
  the file). `WalletRepo.dropOrphanBlobs()` (also run by `runPendingMatch` after a caught-up sync and by `SyncEngine.run`
  before uploading): an own hash no live bill points to (bill deleted elsewhere, or the same bill got another device's file:
  the later `blob` field wins) is forgotten when still queued (never sent) or queued for `blob_delete` when uploaded; the
  cached copy goes. A file added with `BlobStore.add` but not yet given to `importBill` is never touched. Files attached
  before B5a are not in `blob_own` (not swept).
- **`billCandidates`** skips own transfers (`transferTo` set, or a transfer-kind category).
- **`SyncReport.blobsUnsupported`** (bool): the relay answered 404 to a bill file upload for a wallet it knows (this
  device's files are on it, or the retry after this run's first file was refused again): an older relay without blob
  storage. The app shows "This relay can't keep bill photos yet. Update the relay on the home server." A 404 before this
  device's first file reached the relay is expected and does not count; no queued file gives false.

## Decisions and additions (B6, final fixes, 2026-10-22)
- **Cash expense keeps a category.** `addExpenseFromBill(id, category:)` also writes `category` to the bill when it has none
  (same `_write`), so deleting that expense later reopens a categorized planned row (reserved once, or `coveredByPlan`).
- **Edits that do not change the reserve are exempt from the category rule.** `updateBill` throws `ArgumentError('The bill
  needs a category.')` only when it changes `due_date`, `total` or `category` and leaves a reserving bill (confirmed, unpaid,
  total, due from today on) without one; a note, payee, reference, warranty/return-by edit always saves. `confirmBill` is
  unchanged. A confirmed unpaid bill with no category (confirmed before B5a, or confirmed while paid and then unlinked) keeps
  its planned row, but `PlannedCost.needsCategory` (`source` bill, category null or blank) makes `computePeriod` list it in
  `duePlanned` **without reserving it**, so no path counts it twice; the app shows "needs a category" and asks for one.
  App: `updateBill` / `setBillDates` return `bool` (false = core refused, logged `bill.edit|dates {ok: false}`); the bill sheet
  then shows "Pick the category so Budget Wallet doesn't count this bill twice." and stays open, and marks the category
  "(needed)" on a confirmed unpaid bill due from today on as well as on one in review.
- **A slip near payday is reserved where its recurring cycle is not.** `plannedCoverage(PlannedCost, recurring)` →
  `({RecurringBill bill, String? occurrence})?` (the covering cycle's date `nextDue + k × intervalDays`, k ≥ 0; null for
  k = −1, the cycle just paid or skipped). `computePeriod` leaves a bill's row out of `reservedPlanned` only when the recurring
  bill is `coveredByPlan`, the cycle is k = −1, or the occurrence is the `nextDue` this period's `dueBills` lists; otherwise
  the slip reserves (payday 11-01, slip due 10-30, recurring cycle 11-02: the slip is reserved in October, the recurring
  occurrence in November). `upcoming` and `plannedIcs` leave the row out only when the covering occurrence is in their range
  (or k = −1), so Upcoming shows the payment once per range. `plannedCoveredBy` / `billCoveredBy` are unchanged (any cycle).
- **One rule for what is set aside (B6b).** `bool plannedReserves(PlannedCost p, List<RecurringBill> recurring, Set<String>
  counted)` (`counted` = recurring occurrences the same total holds, keys `occurrenceKey(id, date)`): open, amount > 0, not
  `coveredByPlan`, not `needsCategory`, and not a slip whose covering cycle is held (bill `coveredByPlan`, cycle just
  paid/skipped, or occurrence in `counted`). `computePeriod` uses it with its `dueBills` and exposes the accepted rows as
  `PeriodBudget.reservedPlannedRows` (Σ = `reservedPlanned`). App: Today's "Coming up" = `reservedPlannedRows.length` /
  `reservedPlanned`; Upcoming's "Set aside" (`countedIn`) counts planned rows by `plannedReserves` with the bill occurrences it
  counts in the shown range (any range). "Needs a category": a red mark on the Upcoming row, a Today line per such bill row due
  this period (`plannedNeedingCategory()`) and a suffix on its heads-up line; each opens the bill sheet.
- **Bill photos.** `MainActivity` deletes everything in `cache/bill_photos` on create and at the start of each `takePhoto`
  (a picture left when Android killed the app while the camera app was open). No unit test (Kotlin).
- `asNew` copies made on two devices before they sync pick the same n and merge into one bill (documented trade-off, B5a).
- Demo data (`app/integration_test/demo_data.dart`): the water slip has Bills & subscriptions (covered by the plan), a gym
  slip in Bills & one-offs is reserved; `app/test/demo_data_test.dart` seeds it into an in-memory wallet on several days.
