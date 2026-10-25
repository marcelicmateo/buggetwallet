# Stage P12 spec: import any CSV by column mapping (2026-10-25)

Plan item: PATH_FORWARD P12. Owner decisions (`NEXT_DECISIONS.md`): a generic CSV import with a column mapping that is remembered, plus Erste / ZABA / OTP profiles. **The bank profiles wait for the owner's header lines** (only the first line of each export, never rows); until then the mapping covers those banks. Importing from another app's CSV is the same mapping.

Rules: exact cents; never guess money silently. Every mapping choice is the owner's, shown on a preview before anything is written. PBZ and Revolut parsing and ids are unchanged (the golden tests pin them). No new packages.

## 1. Importer (`wallet_importer`, pure)
- `CsvShape csvShape(Uint8List bytes)`. It works out:
  - **Encoding:** UTF-8; if UTF-8 is malformed, Windows-1250 (a pure-Dart table for Croatian bank exports). Recorded in `encoding`.
  - **Delimiter:** `;`, `,` or tab, chosen by the most consistent field count over the first 15 rows.
  - **Header row:** the first row whose cells are mostly non-numeric text. The owner can change it.
  - **Columns and samples:** `headers` and up to 5 `samples` rows, for the app preview only (never logged).
  - **Shape id:** `shapeId` = the first 16 hex characters of SHA-256 over the folded header names joined with `|`.
  - Caps: `maxImportBytes`, and a refusal for more than 200 columns.
- `CsvMapping`:
  - `name` (the owner's label, 1–30 characters);
  - `headerRow`;
  - `date: (col, format)`, where `format` is one of `dd.mm.yyyy`, `d.m.yyyy`, `yyyy-mm-dd`, `dd/mm/yyyy`, `mm/dd/yyyy`, `dd-mm-yyyy` (a trailing time is ignored);
  - `amount`: either `(col)` with a sign, or `(debitCol, creditCol)`;
  - `decimal`: `comma` or `point`;
  - `negate`: for exports whose spending is positive;
  - `description`: a column, or several joined with " · ";
  - `currency`: a column, or a fixed code (default: the wallet currency);
  - optional `skipIfEmpty` column.
- Mapping helpers:
  - `List<String> mappingProblems(CsvShape, CsvMapping)` gives owner-readable texts, for example "Row 4: the date 31.02.2026 is not a date", "Row 7: no amount".
  - `CsvMapping? guessMapping(CsvShape)` suggests a starting mapping from header names (Datum/Date, Iznos/Amount/Duguje/Potražuje/Debit/Credit, Opis/Description/Primatelj, Valuta/Currency). Every guess is shown and must be accepted by the owner.
- `ImportBatch parseMappedCsv(Uint8List bytes, CsvMapping m, {String? fileName})`:
  - The source is `csv:<shapeId>`.
  - Ids come from `sourceTransactionId(source, date, amountMinor, description)` with the occurrence counter. The same file imported twice gives the same ids; two files of one shape never collide on different rows.
  - A row that fails is counted `invalid` with its row number, never guessed.
  - Amounts use exact decimal parsing (no doubles) at 2 decimals; a third decimal is invalid.
- `importBankFile` stays as it is for PBZ and Revolut. An unrecognised CSV throws `NeedsMapping(shape)` (a subtype of `ImportException`, so old callers still show a message). The message text changes to "This file isn't one I know yet. Map its columns once and it's remembered."

## 2. Core
- A synced per-key setting `csvmap:<shapeId>` holding the `CsvMapping` JSON (prefix `csvMapPrefix`).
  - `WalletSettings.csvMappings` holds them; a bad row is dropped (`settings.invalid`, key `csvmap`).
  - `repo.setCsvMapping(shapeId, mapping)` and `removeCsvMapping(shapeId)`.
- `addAccount(source:)` also accepts a `csv:<shapeId>` with a live mapping, labelled with the mapping's name.
- Import goes through `importBatch` as today (`source = csv:<shapeId>`).

## 3. App
- `importFiles`:
  - A recognised bank file goes as today.
  - A CSV whose shape has a saved mapping is imported with it.
  - A `NeedsMapping` file opens the **Map columns** sheet (`csvMapSheet`):
    - pickers for each role (`csvMap:date`, `csvMap:amount`, `csvMap:debit`, `csvMap:credit`, `csvMap:description`, `csvMap:currency`), the date format, the decimal style, "Spending is shown as positive", the header row and a name;
    - the problems and a preview of the first 5 parsed rows (date, description, signed amount in the wallet's number style);
    - Save & import, which only works with zero problems in the preview rows; Cancel imports nothing.
- The result line uses the mapping's name ("Erste (CSV): 42 new, 3 already here").
- Plan › Import has a "Saved file layouts" list: rename, delete with Undo, and see the columns.
- The ImportLine bank label comes from the profile label or the mapping name, not the hard-coded PBZ/Revolut switch (`controller.dart:1868`).
- Logs carry counts, the encoding, the delimiter and `mapped: true` only. Never headers, samples, names or file names.

## 4. Tests (synthetic fixtures from `tools/make_fixtures.py`, a new "generic" section)
- Shapes: UTF-8 with a BOM, Windows-1250 (č ć š ž đ), `;` and `,` and tab, quoted fields with delimiters inside, a header on row 3, a ragged last row.
- Amounts:
  - single signed column, debit/credit columns, `negate`;
  - decimal comma, thousands dots (`1.234,56`), point style;
  - a third decimal is invalid, an empty cell is invalid.
- Dates: each format, invalid dates, a trailing time.
- Ids: stable across two imports, the occurrence counter for twin rows, and different from PBZ/Revolut ids.
- Mapping problems and the guesses for Croatian and English headers.
- PBZ and Revolut goldens unchanged.
- App: an unknown CSV opens the sheet; the preview; Save & import writes the setting and the rows; a second file of the same shape imports with no sheet; the saved layouts list; layout at 360 dp and text scale 2.0.
