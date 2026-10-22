import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../bill_inputs.dart';
import '../controller.dart';
import '../file_chooser.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'bill_sheet.dart';

/// Takes the picture of the camera preview behind [key]; tests replace it.
typedef FrameGrabber = Future<Uint8List?> Function(GlobalKey key, double pixelRatio);

Future<Uint8List?> grabFrame(GlobalKey key, double pixelRatio) async {
  final boundary = key.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary) return null;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

/// Add expense › Scan bill, or Plan › Bills › Scan bill: opens the camera and then the sheet of the bill that was read (or says
/// it was already in the bills).
Future<void> scanBillFlow(BuildContext context, WalletController wc,
    {FileChooser chooser = const FileChooser(), FrameGrabber grabber = grabFrame}) async {
  logNav('scan.open');
  final screen = ScanBillScreen(wc: wc, grabber: grabber);
  final BillImport? r;
  if (MediaQuery.sizeOf(context).width >= dialogMin) {
    r = await showDialog<BillImport>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 520, height: (MediaQuery.sizeOf(ctx).height - 48).clamp(300.0, 760.0), child: screen),
      ),
    );
  } else {
    r = await Navigator.of(context).push<BillImport>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => screen));
  }
  if (r == null || !context.mounted) return;
  if (r.kind == BillImportKind.added && r.billId != null) {
    await openBill(context, wc, r.billId!, chooser: chooser);
  } else {
    toast(context, r.message);
  }
}

/// The camera looks for the QR code of a receipt or the PDF417 barcode of a payment slip. "Take photo" keeps the frame (the
/// photo stays with the bill) and reads its text. Pops a [BillImport].
class ScanBillScreen extends StatefulWidget {
  final WalletController wc;
  final FrameGrabber grabber;
  const ScanBillScreen({super.key, required this.wc, this.grabber = grabFrame});
  @override
  State<ScanBillScreen> createState() => _ScanBillScreenState();
}

class _ScanBillScreenState extends State<ScanBillScreen> {
  final _frame = GlobalKey();
  bool _busy = false;
  String? _hint;
  final _seen = <String>{};

  Future<void> _onCode(ScannedCode code) async {
    if (_busy || !_seen.add(code.raw)) return;
    setState(() {
      _busy = true;
      _hint = null;
    });
    final r = await widget.wc.importScannedCode(code);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, r);
    } else {
      setState(() {
        _busy = false;
        _hint = "That code isn't a bill I can read. Try the photo button.";
      });
    }
  }

  Future<void> _photo() async {
    if (_busy) return;
    logNav('scan.photo');
    setState(() {
      _busy = true;
      _hint = null;
    });
    final bytes = await widget.grabber(_frame, MediaQuery.devicePixelRatioOf(context));
    if (bytes == null) {
      if (mounted) {
        setState(() {
          _busy = false;
          _hint = "Couldn't take the photo. Try again, or import a file.";
        });
      }
      return;
    }
    final r = await widget.wc.importPhoto(bytes);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, r);
    } else {
      setState(() {
        _busy = false;
        _hint = r.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan bill'),
        leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Close', onPressed: () => Navigator.pop(context)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(2), child: Container(height: 2, color: c.lineStrong)),
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Stack(children: [
            RepaintBoundary(key: _frame, child: widget.wc.billInputs.camera.view(onCode: _onCode)),
            if (_busy)
              const Positioned.fill(child: ColoredBox(color: Color(0x66000000), child: Center(child: CircularProgressIndicator()))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(pagePad, 10, pagePad, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Muted('Point at the QR code on a receipt or the barcode on a payment slip. No code? Take a photo.'),
            if (_hint != null) ...[const SizedBox(height: 6), StatusLabel(key: const ValueKey('scanHint'), good: false, text: _hint!)],
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('takePhoto'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Take photo'),
              onPressed: _busy ? null : _photo,
            ),
          ]),
        ),
      ]),
    );
  }
}
