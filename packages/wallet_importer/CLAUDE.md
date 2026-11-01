# wallet_importer — notes for Claude

Pure Dart. **The only code that knows bank formats.** Turns PBZ .xls, Revolut .xlsx/.csv into
`NormalizedTransaction`s (contract v1 + optional `kindHint`/`account`). The app and `wallet_core` never see bank files.

## Files
- `importer.dart` — `importBankFile(bytes, {fileName})`: detects the container format, reads the rows, then tries
  each profile in `bankProfiles` (`parseRows`); the first `detect` wins, none → `ImportException(unknownLayoutMessage)`.
  Refused before reading (`limits.dart`, `importer.refused {reason, bytes}`): over `maxImportBytes` (20 MiB) and an .xlsx
  whose entries' stated sizes sum past `maxXlsxUnpackedBytes` (64 MiB; archive 4.5 never inflates an entry past its
  stated size) → `tooLargeMessage`; an .xls with FILEPASS in the workbook globals or an OLE2 file with an
  `EncryptedPackage` stream (a protected .xlsx) → `passwordProtectedMessage`. Readers throw `FileRefused` for these.
- `profiles/profile.dart` — the contract: `BankProfile` (`id`, `label`, `detect(ctx)`, `prepare(ctx)`, `mapRow(row, ctx)`,
  `parse`), `ImportContext` (first `headRows` rows as text, format, file name; per-file `firstRow`, `columns`, `account`;
  `v1Id` / `sourceId` with the occurrence counter), `RowResult` / `RowOutcome` (transaction, ignored, skipped, invalid).
- `profiles/pbz.dart`, `profiles/revolut.dart` — one file per bank. `profiles/registry.dart` — `bankProfiles` in
  detection order (Revolut first: its header row is specific; PBZ needs the whole header `PbzProfile.header` — DATUM,
  VRSTA TRANSAKCIJE, OPIS PLAĆANJA, IZNOS, VALUTA — on one row of the head from column A, trimmed, any case,
  mojibake repaired) and `bankLabels()`.

- `csv_generic.dart` + `csv_mapping.dart` + `text_codec.dart` — any other CSV by the owner's column mapping (P12,
  rules in `docs/context/IMPORT_FORMATS.md`): an unknown CSV throws `NeedsMapping(shape)`; `csvShape`, `CsvMapping`
  (JSON for the synced `csvmap:<shapeId>` setting), `guessMapping`, `mappingProblems`, `previewMapping`,
  `matchCsvMapping`, `parseMappedCsv` (source `csv:<shapeId>`, `sourceTransactionId`, exact cents). Windows-1250 and
  SHA-256 are pure Dart (`text_codec.dart`). Tests: `test/csv_mapping_test.dart`, fixtures `test/fixtures/generic/`
  (`make_fixtures.py <dir> generic`).
- `profiles/cells.dart` — cell helpers every profile uses: `cellText`, `cellDate`, `cellNumber`, `cellCents`,
  `serialDate`/`excelDate`, `jsRound` (v1's Math.round), `fixMojibake`.
- `xls_reader.dart` (own BIFF8 reader), `xlsx_reader.dart` (`archive` + `xml`), `csv_reader.dart`. `grid.dart` —
  `sparseRows`: cells → rows without a dense grid, capped at `maxSheetCells` (bigger = ImportException).
- Stage Q: `limits.dart` `maxRowAmountMinor` (10^11, the same single cap as typed input; 90,000 rows at it sum under
  2^53, `exactRowsAtCap`): a row beyond it after the fee is invalid and counted in `ImportBatch.tooLarge` (profiles in
  `BankProfile.parse`, mapped CSV as a "too large" problem). `NormalizedTransaction.balanceAfter` (optional, never in the
  id, `toJson` only when set): Revolut `Balance`, PBZ `STANJE`/`SALDO` when the header row has it (detection unchanged),
  `CsvMapping.balanceCol` (JSON `balance`, old layouts read as none; `guessMapping` fills it from the balance header).
  `ImportBatch.bankBalances` (`BankBalance`): per currency, the newest day whose end-of-day row has a balance; with
  several rows that day, the file's direction comes from the balance chain (`bal[i] == bal[i-1] + amount[i]`), and no
  balance when the chain does not tell; none for a currency mixing two `account`s (Revolut pockets). Tests:
  `test/q_balance_import_test.dart`.
- `currencies.dart` — UX-A: `CurrencyInfo`, `allCurrencies` (circulating ISO 4217 + BTC), `currencyInfo`, `minorDigitsOf`
  (ISO; unknown → 2), `storageDigitsOf` (fiat 2, crypto its own: BTC 8), `displayDigitsOf`, `pow10` (re-exported by core).
  `amountMinor` is at storage digits: fiat in hundredths as always (1000 yen = 100000), BTC in satoshis. Every reader
  refuses an amount/fee/balance with non-zero digits past that scale, per row, never rounded: `cellAmount` /
  `cellMinor` (profiles), CSV `_cents`, e-invoice `decimalCents(digits:)`; the reason (`decimalsProblem`, e.g. "the
  third decimal of KWD is not supported") is in `ImportBatch.problems` as `Row N: …` (+ `invalidRows`). Currency cells
  are upper-cased first (`cellCurrency`). Ids: fiat rows hash the cents (v1's ids for every exact amount), crypto rows
  their satoshis (`transactionId(…, digits: 8)`), CSV ids use `minorIdText`. Tests: `test/ux_a_importer_test.dart`, `test/ux_a_digits_test.dart`.
- `model.dart` — `NormalizedTransaction`, `TxKind`, `ImportBatch`. `ids.dart` — `transactionId` (v1),
  `sourceTransactionId` (banks added after v1); `fnv1a36`, `formatCents` are internal (tests import `src/ids.dart`).
- `bills/` — bill readers (`docs/context/BILLS_API.md` §1), all pure Dart, web-safe, never throw: `model.dart`
  (`NormalizedBill`, `BillItem`, `BillSource`), `codes.dart` (`readFiscalQr`, `readHub3`), `einvoice.dart` (`readEInvoice`,
  UBL 2.1), `pdf_text.dart` (`pdfText`: own minimal PDF text-layer reader; its header lists what is and isn't supported; the
  code is in `part` files under `pdf/`: bytes, lexer, objects, filters, cmap, fonts, encodings, content),
  `text_bill.dart` (`billFromText`: labelled fields only, conservative money); each reader has a `…Result` twin returning
  `ReadResult` (`read_result.dart`: the value or a `ReadFailure` reason) and the nullable one is its `.value`; external ids per `BILLS_API.md` §1 (HUB-3:
  `hub3:<IBAN>:<model reference>:<amount>:<DESCRIPTION>`, so monthly flat-fee slips differ), `common.dart` (IBAN mod-97, references,
  exact cents, dates). Logger `bw.importer.bills`: event words, counts, sizes, reason words (`test/bills_log_test.dart`).
- `log.dart` — `logImporter`: same line shape as wallet_core's `logEvent` (loggers `bw.importer[.xls|.xlsx|.csv]`).
  Formats, sizes, counts, profile ids and timings only — never cell contents or file names (`test/importer_log_test.dart`).

## Rules
- `transactionId` must stay identical to v1 (date + FNV-1a of date|amount|description + occurrence index):
  re-imports must never duplicate, across v1 and v2. Changing it is a breaking change. PBZ and Revolut use
  `ctx.v1Id`; a new bank uses `ctx.sourceId` (hashes the profile id in) so it cannot collide with them.
- A contract change (new field on `NormalizedTransaction`) is additive and optional. `kindHint` and `account` are
  hints from what the export itself says; nothing in core or the app reads them yet.
- Bank names reach the app only through `BankProfile.label` (the unknown-layout message is built from the labels).
- Adding a bank: one `profiles/<bank>.dart`, add it to `bankProfiles`, document the layout in
  `docs/context/IMPORT_FORMATS.md`, add a synthetic fixture (`tools/make_fixtures.py`) and its golden file.
- `test/fixtures/golden/*.json` are the pre-refactor outputs (captured at d632e32); `test/profiles_test.dart` holds
  the importer to them. Regenerate only for a deliberate contract change, and say so in the commit.

## Tests
- `test/importer_test.dart`, `test/v1_golden_test.dart` (v1 id vectors), `test/profiles_test.dart` (golden files,
  detect, hints), `*_edge_test.dart`, `importer_fuzz_test.dart`, `bills_test.dart` (fixtures + edges), `pdf_text_test.dart` (pdfText fixtures, edges, fuzz), `bills_spec_test.dart`
  (from the spec), `bills_log_test.dart`. Bill fixtures: `test/fixtures/bills/` (`make_fixtures.py <dir> bills` needs no
  extra Python modules). Fixtures in `test/fixtures/` — **synthetic only**,
  generated by `tools/make_fixtures.py`. Never add a real export, even trimmed or anonymised.
- Run: `tools/build.sh importer` (this package), `tools/build.sh test` (everything) from the repo root.
