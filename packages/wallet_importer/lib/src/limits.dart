/// Size limits of a bank file import and the messages for files that are refused before they are read.
library;

/// Largest bank export [importBankFile] reads, in bytes (20 MiB); a bigger file is refused with [tooLargeMessage].
const maxImportBytes = 20 * 1024 * 1024;

/// Most bytes an .xlsx may unpack to, all its entries together (64 MiB): the archive's own entry sizes are summed
/// before anything is inflated (the zip decoder never inflates an entry past its stated size), so a compression bomb
/// is refused with [tooLargeMessage].
const maxXlsxUnpackedBytes = 64 * 1024 * 1024;

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
