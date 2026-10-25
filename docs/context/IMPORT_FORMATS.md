# Bank export formats (for the importer)

Taken from the owner's real exports (2023–2026). Only the format notes are kept here; the analysis and
figures stay in the claude.ai Project (`claude/BASELINE.md`).

## Bank profiles (how the importer is organised)
One `BankProfile` per bank in `packages/wallet_importer/lib/src/profiles/` (`pbz.dart`, `revolut.dart`), tried in the
order of `bankProfiles` (Revolut, then PBZ): `detect` looks at the first 15 rows, the container format and the file
name; `mapRow` turns one row into a transaction, a skipped row (counted), an invalid row (counted) or nothing.
Each profile fills the optional hints: `kindHint` (card, atm, salary, fee, standingOrder, ownTransfer, exchange, other; null
when the export does not say) and `account` (the account the file names). Nothing reads them yet.
- PBZ: VRSTA TRANSAKCIJE → POS plaćanje = card (a "POS Revolut**" row = ownTransfer), Isplata ATM = atm, Plaća/Mirovina =
  salary, Trajni nalog = standingOrder, Naplaćene naknade / Povrat naknade / Pripisane kamate = fee, Plaćanje putem
  direktnih kanala / Isplata u poslovnici / Ostalo = other; others null. `account` = the IBAN under or after
  `TRANSAKCIJSKI RAČUN:` in the header block.
- Revolut: Type → Card Payment / Card Refund = card, ATM = atm, Topup = ownTransfer, Exchange = exchange, Fee = fee, Transfer =
  other; others null. `account` = Product.
- Ids: PBZ and Revolut keep the v1 `transactionId`. A bank added later uses `sourceTransactionId` (profile id hashed in).

## PBZ (current account)
- Real .xls (Excel 97 / BIFF8). v1 reads it with SheetJS; v2 has its own BIFF8 reader.
- Header block of ~8 rows (account IBAN, OD/DO dates), then rows: DATUM (Excel serial date), VRSTA TRANSAKCIJE, OPIS PLAĆANJA, IZNOS (signed), VALUTA.
- VRSTA TRANSAKCIJE → meaning:
  - Plaća/Mirovina — salary ("Neto plaća" / "MJESECNI OBRACUN" / "Plaća za mjesec"), per diem ("Isplata dnevnice"), Regres / Božićnica bonuses.
  - POS plaćanje — card payment.
  - Isplata ATM — cash withdrawal.
  - Trajni nalog — standing order (loan: "Naplata kredita").
  - Plaćanje putem direktnih kanala — bills / transfers.
  - Naplaćene naknade / Povrat naknade / Pripisane kamate — fees, fee refunds, interest.
  - Ostalo — tax refunds ("VAL_…POVRAT"), loan disbursements ("ISPLATA KREDITA"), variable pay, account fees.
  - Isplata u poslovnici — branch cash.
  - #WithPay uplata/isplata.
- "POS Revolut**xxxx* Dublin" = top-up of the owner's own Revolut → internal transfer, not spending.
- A large monthly ATM withdrawal early in the month = rent paid in cash (threshold is a setting).
- A duplicated salary followed by "Povrat krive uplate" (reversal) → exclude both as a pair.

## Revolut
- .xlsx (one sheet) or .csv, columns: Type, Product, Started Date, Completed Date, Description, Amount, Fee, Currency, State, Balance.
- Use Started Date; keep State = COMPLETED only (drop REVERTED / PENDING); amount = Amount − Fee.
- Type: Card Payment (spending), Topup "Top-up by *NNNN" (= from PBZ, internal), Transfer "Revolut Bank UAB" (to/from people), Exchange, Card Refund.
- Merchant names can have broken UTF-8 (e.g. "GraÅ¡o") → re-decode latin1 → utf8.
- Only Product = Current is used (no Savings / Pockets). Revolut is a pure spending card, funded from PBZ.
- CSV ids vs v1: SheetJS (v1) converts descriptions that look like values (`TRUE` → "true", `00123` → "123",
  `1e3` → "1000", `12/01/2026` → a serial) and keeps `"Shop"X` as is; v2 keeps the text as written (and reads
  `"Shop"X` as `ShopX`). Such rows get different ids across v1 and v2. Not seen in real Revolut descriptions.

## Any other CSV: column mapping (P12, `csv_generic.dart`, `csv_mapping.dart`)
- A CSV no profile recognises throws `NeedsMapping(shape)` (an `ImportException`; message "This file isn't one I know
  yet. Map its columns once and it's remembered."). An .xls/.xlsx no profile knows keeps `unknownLayoutMessage`; so do a
  CSV without a header row of 2+ columns, a NUL byte in the first 4 KB (UTF-16, binary) and prose with a comma.
- `csvShape(bytes, {headerRow})`: encoding UTF-8, else Windows-1250 (pure-Dart table, `text_codec.dart`); delimiter
  `;`, tab or `,` = the most consistent field count (≥ 2) over the first 15 rows (tie: wider rows, then that order);
  header row = the first of those rows with ≥ 2 (and half the usual count of) filled cells, most of them text, followed
  by a row with ≥ 2 filled cells. Rows are 0-based indexes into the rows `readCsv` returns (blank lines are not rows);
  texts say `Row ${i + 1}`. Shape id = first 16 hex of SHA-256 over the header names (trimmed, lower case, spaces
  collapsed) joined with `|`. Caps: `maxImportBytes`, more than 200 columns refused (`tooManyColumnsMessage`).
- `CsvMapping` JSON (setting `csvmap:<shapeId>`): `{"v":1, "name", "headerRow", "date": {"col", "format"},
  "amount": {"col"} | {"debit", "credit"}, "decimal": "comma"|"point", "negate", "description": [cols],
  "currency"?: {"col"} | {"code"}, "skipIfEmpty"?: col, "headers": [names]}`. Date formats `dd.mm.yyyy` (a trailing dot
  allowed), `d.m.yyyy`, `yyyy-mm-dd`, `dd/mm/yyyy` and `mm/dd/yyyy` (1–2 digit day/month), `dd-mm-yyyy`; a time after a
  space or `T` is ignored; years 1900–2199.
- Amounts: exact (no doubles), at most 2 decimals (a third is invalid, never rounded), thousands marks of the other kind
  in groups of three, spaces, a leading `+`, `-` or `−`. Comma style: `1.234,56`, `1.234` = 1234.00, `12.30` invalid;
  point style: `1,234.56`, `12,30` invalid. Debit/credit: exactly one non-zero (both = invalid, both empty = invalid);
  a debit is money out and a credit money in whatever sign is written. `negate` flips the result. Currency column: ISO
  code (any case) or `€`; empty or other = invalid; no column = the fixed code, else the wallet's currency.
- Rows: all cells empty = not counted; an empty `skipIfEmpty` cell = skipped; anything that fails = invalid (counted,
  index in `ImportBatch.invalidRows`). Source `csv:<shapeId>`, ids `sourceTransactionId(source, …)` with the occurrence
  counter, `bankType` empty, no `kindHint`. A layout whose `headers` differ from the file's = `layoutMismatchMessage`.
- `guessMapping(shape)` reads header names (Croatian and English; balance columns never the amount) and the samples
  (date format, decimal style); `mappingProblems` / `previewMapping` check the 5 sample rows. Logs: counts, encoding,
  delimiter word and `mapped: true` only; repo logs say `source: csv` (`sourceLogKey`).
