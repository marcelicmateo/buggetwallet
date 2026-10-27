import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// What the user sees when the system file chooser can't open (Linux without the xdg-desktop-portal, for one).
const chooserFailedMessage = "Can't open the file chooser on this computer.";

/// A file the user picked: its name and a way to read it. The screens use this, so only this file knows `file_picker`.
/// File names stay out of logs (see the callers: extensions and sizes only).
class PickedFile {
  /// [length] answers the size without reading the file (null when unknown); the bill and attachment screens ask it first, so a
  /// huge file is never loaded into memory.
  const PickedFile(this.name, this.readBytes, {Future<int?> Function()? length}) : _length = length;

  /// Wraps what the system chooser returned.
  PickedFile.fromPlatform(PlatformFile f) : this(f.name, f.readAsBytes, length: f.length);

  final String name;
  final Future<Uint8List> Function() readBytes;
  final Future<int?> Function()? _length;

  /// The size in bytes, or null when it is not known without reading the file.
  Future<int?> length() async => _length == null ? null : await _length();
}

/// The system file choosers. The screens take one as a parameter so tests can replace it
/// (the real ones need a desktop portal or an Android activity, and can throw when that is missing).
class FileChooser {
  const FileChooser();

  /// Bank exports: spreadsheets and CSV. An empty list means the user cancelled. (On the web `PickedFile.readBytes()` reads
  /// the picked file on demand, so no preload option is needed.)
  Future<List<PickedFile>> pickBankFiles() => _pick(type: FileType.custom, allowedExtensions: const ['xls', 'xlsx', 'csv']);

  /// A backup file (`.bwb`). An empty list means the user cancelled.
  Future<List<PickedFile>> pickBackupFile() => _pick(type: FileType.custom, allowedExtensions: const ['bwb']);

  /// Bills: a PDF, an e-invoice (XML) or a photo. An empty list means the user cancelled.
  Future<List<PickedFile>> pickBillFiles() => _pick(type: FileType.custom, allowedExtensions: const ['pdf', 'xml', 'jpg', 'jpeg', 'png']);

  /// A photo or PDF to attach to a payment (no e-invoice XML). An empty list means the user cancelled.
  Future<List<PickedFile>> pickAttachmentFiles() => _pick(type: FileType.custom, allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png']);

  /// A calendar file (`.ics`). An empty list means the user cancelled.
  Future<List<PickedFile>> pickCalendarFile() => _pick(type: FileType.custom, allowedExtensions: const ['ics']);

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

  Future<List<PickedFile>> _pick({required FileType type, required List<String> allowedExtensions}) async {
    final r = await FilePicker.pickFiles(type: type, allowedExtensions: allowedExtensions);
    return [for (final f in r) PickedFile.fromPlatform(f)];
  }

  Future<Uri?> _save(String fileName, Uint8List bytes, String title, String mimeType) async {
    final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mimeType, dialogTitle: title);
    return kIsWeb ? (uri ?? Uri(path: fileName)) : uri;
  }
}
