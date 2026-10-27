/// Size limits of a bank file import and the messages for files that are refused before they are read.
library;

/// Largest bank export [importBankFile] reads, in bytes (20 MiB); a bigger file is refused with [tooLargeMessage].
const maxImportBytes = 20 * 1024 * 1024;

/// Most bytes an .xlsx may unpack to, all its entries together (64 MiB): the archive's own entry sizes are summed
/// before anything is inflated (the zip decoder never inflates an entry past its stated size), so a compression bomb
/// is refused with [tooLargeMessage].
const maxXlsxUnpackedBytes = 64 * 1024 * 1024;

/// Largest amount of one transaction row, in minor units: 1 billion in the account currency, the same single cap as
/// typed input (`WalletSettings.maxAmount` / `maxAmountCents` in wallet_core). A row beyond it, after its fee is
/// applied, is left out and counted in `ImportBatch.invalid` and `ImportBatch.tooLarge`, never imported.
///
/// Exactness bound: sums run over the whole wallet, and web numbers are exact up to 2^53 ≈ 9.007e15, so at least
/// [exactRowsAtCap] rows at this cap still sum exactly (90,000 × 10^11 = 9.0e15). Core's debug asserts in its sums catch
/// anything beyond (`test/import_limits_test.dart`).
const maxRowAmountMinor = 100000000000;

/// How many rows at [maxRowAmountMinor] are guaranteed to sum exactly (under 2^53).
const exactRowsAtCap = 90000;

/// The message for a password-protected export (an .xls with a FILEPASS record, or an Office file encrypted as a
/// whole). It is not damaged: saved again without the password, it imports.
const passwordProtectedMessage = 'This file is password-protected. Save it again without a password, then import it.';

/// The message for a file over [maxImportBytes] or an .xlsx unpacking to more than [maxXlsxUnpackedBytes].
const tooLargeMessage = 'This file is too large to import (the limit is 20 MB).';

/// A reader refusing a file for a known reason ([message] is one of the texts above, shown as is).
class FileRefused implements Exception {
  final String message;

  /// The reason as an enum word for logs.
  final String reason;
  const FileRefused(this.message, this.reason);
  @override
  String toString() => message;
}
