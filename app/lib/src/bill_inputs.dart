// Where bills come from on the phone, behind small interfaces so the app and its tests never touch a plugin directly (same idea
// as CalendarSource and NudgePlatform): the live camera, code and text reading from a picture, PDF pages and the Share intent.
// Only Android has them; everywhere else [BillInputs.none] says "not supported" and never fails. No dart:io and no plugin here.
// Privacy: nothing read from a picture, a code or a file is logged by the implementations; the controller logs counts only.
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// What kind of code was read.
enum CodeKind { qr, pdf417, other }

/// One code read from the camera or a picture. [raw] is its text; it is a suggestion for a reader, never logged.
class ScannedCode {
  final CodeKind kind;
  final String raw;
  const ScannedCode(this.kind, this.raw);
}

/// The live camera view that looks for codes.
abstract class BillCamera {
  /// False where there is no camera view we can use (everything but Android).
  bool get supported;

  /// The preview. [onCode] is called for every code seen (the caller ignores repeats). A refused permission or a missing camera
  /// is shown inside the view as a short plain message.
  Widget view({required ValueChanged<ScannedCode> onCode});
}

/// Codes and text read from a picture (JPEG or PNG bytes).
abstract class PictureReader {
  bool get supported;

  /// The QR and PDF417 codes in the picture; empty when none (or when reading fails).
  Future<List<ScannedCode>> codes(Uint8List image);

  /// The text on the picture; null when none or reading fails.
  Future<String?> text(Uint8List image);
}

/// PDF pages and picture sizes, through the platform's own renderer (Android `PdfRenderer`, `BitmapFactory`).
abstract class PdfPages {
  bool get supported;

  /// Up to [maxPages] pages as PNG bytes at [dpi]; empty when the file cannot be rendered (encrypted, damaged).
  Future<List<Uint8List>> render(Uint8List pdf, {int dpi = 200, int maxPages = 5});

  /// The picture as a JPEG whose longest side is at most [maxSide]; null when it cannot be read.
  Future<Uint8List?> toJpeg(Uint8List image, {int maxSide = 2560});
}

/// A file somebody shared to the app (a PDF or a picture).
class SharedFile {
  final Uint8List bytes;

  /// Lower case extension without the dot (`pdf`, `jpg`, `png`, `xml`).
  final String ext;
  const SharedFile(this.bytes, this.ext);
}

/// Share to app (Android): files shared while the app was closed ([initial]) and while it runs ([files]).
abstract class ShareInbox {
  bool get supported;
  Future<List<SharedFile>> initial();
  Stream<List<SharedFile>> get files;
}

/// Where none of it exists: does nothing and never fails.
class NoBillInputs implements BillCamera, PictureReader, PdfPages, ShareInbox {
  const NoBillInputs();
  @override
  bool get supported => false;
  @override
  Widget view({required ValueChanged<ScannedCode> onCode}) => const SizedBox.shrink();
  @override
  Future<List<ScannedCode>> codes(Uint8List image) async => const [];
  @override
  Future<String?> text(Uint8List image) async => null;
  @override
  Future<List<Uint8List>> render(Uint8List pdf, {int dpi = 200, int maxPages = 5}) async => const [];
  @override
  Future<Uint8List?> toJpeg(Uint8List image, {int maxSide = 2560}) async => null;
  @override
  Future<List<SharedFile>> initial() async => const [];
  @override
  Stream<List<SharedFile>> get files => const Stream.empty();
}

/// The four inputs of this device, handed to the controller together.
class BillInputs {
  final BillCamera camera;
  final PictureReader reader;
  final PdfPages pdf;
  final ShareInbox share;
  const BillInputs({required this.camera, required this.reader, required this.pdf, required this.share});
  const BillInputs.none()
      : camera = const NoBillInputs(),
        reader = const NoBillInputs(),
        pdf = const NoBillInputs(),
        share = const NoBillInputs();
}
