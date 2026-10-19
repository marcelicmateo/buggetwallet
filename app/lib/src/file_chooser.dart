import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// What the user sees when the system file chooser can't open (Linux without the xdg-desktop-portal, for one).
const chooserFailedMessage = "Can't open the file chooser on this computer.";

/// The system file and folder choosers. The screens take one as a parameter so tests can replace it
/// (the real ones need a desktop portal or an Android activity, and can throw when that is missing).
class FileChooser {
  const FileChooser();

  /// Bank exports: spreadsheets and CSV. An empty list means the user cancelled.
  Future<List<PlatformFile>> pickBankFiles() =>
      FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['xls', 'xlsx', 'csv']);

  /// A folder path, or null when the user cancelled.
  Future<String?> pickFolder({required String title}) => FilePicker.getDirectoryPath(dialogTitle: title);

  /// The save dialog: where it saved, or null when the user cancelled.
  Future<Uri?> saveText({required String fileName, required Uint8List bytes, required String title}) =>
      FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: 'text/plain', dialogTitle: title);
}
