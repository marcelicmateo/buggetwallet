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
  final String? externalId;   // 'jir:<uuid>' | 'zki:<hex>' | 'inv:<supplier id or IBAN>:<invoice no>' | 'hub3:<IBAN>:<model reference>:<amount>'
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
(String, bool) importBill(NormalizedBill b, {BlobRef? file});
void updateBill(String id, {String? date, String? dueDate, int? total, String? payee, String? iban, String? reference,
    String? description, String? category, String? note, List<BillItem>? items, String? warrantyUntil, String? returnBy,
    bool clearDueDate = false, bool clearWarranty = false, bool clearReturnBy = false, bool clearCategory = false});
void confirmBill(String id);           // review → confirmed; needs date and total (> 0) else ArgumentError
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
`returnBy` in range (the bill's planned row is already listed as `planned`). Settings (synced): `returnReminderDays`
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
  BlobRef add(Uint8List plain, String type);
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
