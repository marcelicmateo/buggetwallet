// Native-only: the Android bill inputs through mobile_scanner (camera, QR + PDF417, bundled ML Kit: works offline),
// google_mlkit_text_recognition (Latin text on the device), receive_sharing_intent (Share to app) and the app's own small
// `budget_wallet/bills` channel (MainActivity.kt: PdfRenderer and JPEG sizing). Keep this file out of screens/ and widgets/.
// Nothing read from a picture is logged here: only the type of an error.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart' as mlkit;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:wallet_core/wallet_core.dart';

import 'bill_inputs.dart';
import 'platform.dart';

final _log = Logger('bw.bills');

/// The bill inputs of this device: Android's, or nothing elsewhere.
BillInputs defaultBillInputs() {
  if (!isAndroid) return const BillInputs.none();
  final pdf = AndroidPdfPages();
  return BillInputs(camera: AndroidBillCamera(), reader: AndroidPictureReader(), pdf: pdf, share: AndroidShareInbox());
}

CodeKind _kindOf(BarcodeFormat f) => switch (f) {
      BarcodeFormat.qrCode => CodeKind.qr,
      BarcodeFormat.pdf417 => CodeKind.pdf417,
      _ => CodeKind.other,
    };

List<ScannedCode> _codesOf(BarcodeCapture? c) => [
      for (final b in c?.barcodes ?? const <Barcode>[])
        if (b.rawValue != null) ScannedCode(_kindOf(b.format), b.rawValue!),
    ];

/// A file in the app's temp folder for the plugins that want a path; removed when [use] ends.
Future<T> _withTempFile<T>(List<int> bytes, String ext, Future<T> Function(String path) use) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/bill-${DateTime.now().microsecondsSinceEpoch}.$ext');
  await f.writeAsBytes(bytes, flush: true);
  try {
    return await use(f.path);
  } finally {
    try {
      await f.delete();
    } catch (_) {}
  }
}

Future<void> _deleteQuietly(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

String _imageExt(Uint8List b) => b.length > 3 && b[0] == 0x89 && b[1] == 0x50 ? 'png' : 'jpg';

class AndroidBillCamera implements BillCamera {
  static const _channel = MethodChannel('budget_wallet/bills');

  @override
  bool get supported => true;

  /// The system camera app takes one picture into a file in the app's cache (MainActivity.kt `takePhoto`, which asks for the camera
  /// permission first); the file is read and deleted here, whatever happens.
  @override
  Future<Uint8List?> takePhoto() async {
    String? path;
    try {
      path = await _channel.invokeMethod<String>('takePhoto');
      if (path == null) return null; // cancelled
      final file = File(path);
      if (await file.length() > maxBillImageBytes) throw const BillPhotoException('tooBig');
      return await file.readAsBytes();
    } on PlatformException catch (e) {
      logEvent(_log, Level.WARNING, 'scan.photoFailed', {'code': e.code});
      throw BillPhotoException(e.code);
    } finally {
      if (path != null) await _deleteQuietly(path);
    }
  }

  @override
  Widget view({required ValueChanged<ScannedCode> onCode}) => _CameraView(onCode: onCode);
}

class _CameraView extends StatefulWidget {
  final ValueChanged<ScannedCode> onCode;
  const _CameraView({required this.onCode});
  @override
  State<_CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<_CameraView> {
  // The camera asks for its permission when it starts, which is when the owner opens Scan bill and not before.
  final _controller = MobileScannerController(
      formats: const [BarcodeFormat.qrCode, BarcodeFormat.pdf417], detectionSpeed: DetectionSpeed.noDuplicates, facing: CameraFacing.back);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobileScanner(
        controller: _controller,
        onDetect: (c) {
          for (final code in _codesOf(c)) {
            widget.onCode(code);
          }
        },
        errorBuilder: (context, e) {
          final msg = e.errorCode == MobileScannerErrorCode.permissionDenied ? cameraOffMessage : cameraUnavailableMessage;
          logEvent(_log, Level.WARNING, 'scan.cameraFailed', {'code': e.errorCode.name});
          return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(msg, textAlign: TextAlign.center)));
        },
      );
}

class AndroidPictureReader implements PictureReader {
  @override
  bool get supported => true;

  @override
  Future<List<ScannedCode>> codes(Uint8List image) async {
    try {
      return await _withTempFile(image, _imageExt(image), (path) async {
        final controller = MobileScannerController(formats: const [BarcodeFormat.qrCode, BarcodeFormat.pdf417], autoStart: false);
        try {
          return _codesOf(await controller.analyzeImage(path, formats: const [BarcodeFormat.qrCode, BarcodeFormat.pdf417]));
        } finally {
          await controller.dispose();
        }
      });
    } catch (e, st) {
      logError(_log, 'scan.imageFailed', e, st, fields: {'type': e.runtimeType.toString()});
      return const [];
    }
  }

  @override
  Future<String?> text(Uint8List image) async {
    final recognizer = mlkit.TextRecognizer();
    try {
      return await _withTempFile(image, _imageExt(image), (path) async {
        final r = await recognizer.processImage(mlkit.InputImage.fromFilePath(path));
        return r.text.trim().isEmpty ? null : r.text;
      });
    } catch (e, st) {
      logError(_log, 'ocr.failed', e, st, fields: {'type': e.runtimeType.toString()});
      return null;
    } finally {
      await recognizer.close();
    }
  }
}

class AndroidPdfPages implements PdfPages {
  static const _channel = MethodChannel('budget_wallet/bills');

  @override
  bool get supported => true;

  @override
  Future<List<Uint8List>> render(Uint8List pdf, {int dpi = 200, int maxPages = 5}) async {
    try {
      final pages = await _channel.invokeListMethod<Uint8List>('renderPdf', {'bytes': pdf, 'dpi': dpi, 'maxPages': maxPages});
      return pages ?? const [];
    } catch (e, st) {
      logError(_log, 'pdf.renderFailed', e, st, fields: {'type': e.runtimeType.toString()});
      return const [];
    }
  }

  @override
  Future<Uint8List?> toJpeg(Uint8List image, {int maxSide = 2560}) async {
    try {
      return await _channel.invokeMethod<Uint8List>('toJpeg', {'bytes': image, 'maxSide': maxSide});
    } catch (e, st) {
      logError(_log, 'image.resizeFailed', e, st, fields: {'type': e.runtimeType.toString()});
      return null;
    }
  }
}

class AndroidShareInbox implements ShareInbox {
  @override
  bool get supported => true;

  static String _ext(SharedMediaFile f) {
    final m = (f.mimeType ?? '').toLowerCase();
    if (m.contains('pdf')) return 'pdf';
    if (m.contains('png')) return 'png';
    if (m.contains('xml')) return 'xml';
    if (m.startsWith('image/')) return 'jpg';
    final dot = f.path.lastIndexOf('.');
    return dot < 0 ? '' : f.path.substring(dot + 1).toLowerCase();
  }

  /// The size is checked before the file is read, and the plugin's copy in the app's cache folder is removed afterwards (also when
  /// reading failed): a shared bill must not stay behind as a second, unmanaged copy.
  Future<List<SharedFile>> _read(List<SharedMediaFile> list) async {
    final out = <SharedFile>[];
    final cache = (await getTemporaryDirectory()).path;
    for (final f in list) {
      if (f.type != SharedMediaType.image && f.type != SharedMediaType.file) continue;
      try {
        final ext = _ext(f);
        final file = File(f.path);
        if (await file.length() > maxBillFileBytes(ext)) {
          out.add(SharedFile(Uint8List(0), ext, tooBig: true));
        } else {
          out.add(SharedFile(await file.readAsBytes(), ext));
        }
      } catch (e, st) {
        logError(_log, 'share.readFailed', e, st, fields: {'type': e.runtimeType.toString()});
      } finally {
        if (f.path.startsWith('$cache/')) await _deleteQuietly(f.path);
      }
    }
    return out;
  }

  @override
  Future<List<SharedFile>> initial() async {
    try {
      final list = await ReceiveSharingIntent.instance.getInitialMedia();
      await ReceiveSharingIntent.instance.reset();
      return await _read(list);
    } catch (e, st) {
      logError(_log, 'share.initialFailed', e, st, fields: {'type': e.runtimeType.toString()});
      return const [];
    }
  }

  @override
  Stream<List<SharedFile>> get files => ReceiveSharingIntent.instance.getMediaStream().asyncMap((list) async {
        await ReceiveSharingIntent.instance.reset();
        return _read(list);
      });
}
