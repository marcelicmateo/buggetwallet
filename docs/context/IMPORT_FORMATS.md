# Bank export formats (for the importer)

Taken from the owner's real exports (2023–2026). Only the format notes are kept here; the analysis and
figures stay in the claude.ai Project (`claude/BASELINE.md`).

## Bank profiles (how the importer is organised)
One `BankProfile` per bank in `packages/wallet_importer/lib/src/profiles/` (`pbz.dart`, `revolut.dart`), tried in the
order of `bankProfiles` (Revolut, then PBZ): `detect` looks at the first 15 rows, the container format and the file
name; `mapRow` turns one row into a transaction, a skipped row (counted), an invalid row (counted) or nothing.
Each profile fills the optional hints: `kindHint` (card, atm, salary, fee, standingOrder, ownTransfer, other; null
when the export does not say) and `account` (the account the file names). Nothing reads them yet.
- PBZ: VRSTA TRANSAKCIJE → POS plaćanje = card (a "POS Revolut**" row = ownTransfer), Isplata ATM = atm, Plaća/Mirovina =
  salary, Trajni nalog = standingOrder, Naplaćene naknade / Povrat naknade / Pripisane kamate = fee, Plaćanje putem
  direktnih kanala / Isplata u poslovnici / Ostalo = other; others null. `account` = the IBAN under or after
  `TRANSAKCIJSKI RAČUN:` in the header block.
- Revolut: Type → Card Payment / Card Refund = card, ATM = atm, Topup / Exchange = ownTransfer, Fee = fee, Transfer =
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
