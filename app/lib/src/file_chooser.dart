import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// What the user sees when the system file chooser can't open (Linux without the xdg-desktop-portal, for one).
const chooserFailedMessage = "Can't open the file chooser on this computer.";

/// The system file choosers. The screens take one as a parameter so tests can replace it
/// (the real ones need a desktop portal or an Android activity, and can throw when that is missing).
class FileChooser {
  const FileChooser();

  /// Bank exports: spreadsheets and CSV. An empty list means the user cancelled. (On the web `PlatformFile.readAsBytes()` reads
  /// the picked file on demand, so no preload option is needed.)
  Future<List<PlatformFile>> pickBankFiles() =>
      FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['xls', 'xlsx', 'csv']);

  /// A backup file (`.bwb`). An empty list means the user cancelled.
  Future<List<PlatformFile>> pickBackupFile() => FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['bwb']);

  /// Bills: a PDF, an e-invoice (XML) or a photo. An empty list means the user cancelled.
  Future<List<PlatformFile>> pickBillFiles() =>
      FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf', 'xml', 'jpg', 'jpeg', 'png']);

  /// A calendar file (`.ics`). An empty list means the user cancelled.
  Future<List<PlatformFile>> pickCalendarFile() => FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['ics']);

  /// The save dialog: where it saved, or null when the user cancelled. In a browser this is a download and there is no
  /// cancel to see, so a finished download answers with the file name as the path.
  Future<Uri?> saveText({required String fileName, required Uint8List bytes, required String title}) =>
      _save(fileName, bytes, title, 'text/plain');

  /// The save dialog for a bill's original file (photo, PDF or e-invoice), where it cannot be shown in the app.
  Future<Uri?> saveBillFile({required String fileName, required Uint8List bytes, required String title}) =>
      _save(fileName, bytes, title, 'application/octet-stream');

  /// The same for an encrypted backup file (`.bwb`).
  Future<Uri?> saveBackup({required String fileName, required Uint8List bytes, required String title}) =>
      _save(fileName, bytes, title, 'application/octet-stream');

  Future<Uri?> _save(String fileName, Uint8List bytes, String title, String mimeType) async {
    final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mimeType, dialogTitle: title);
    return kIsWeb ? (uri ?? Uri(path: fileName)) : uri;
  }
}
