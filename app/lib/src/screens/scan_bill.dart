import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bill_inputs.dart';
import '../controller.dart';
import '../file_chooser.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'bill_sheet.dart';

/// Add expense › Scan bill, or Plan › Bills › Scan bill: opens the camera and then the sheet of the bill that was read (or says
/// it was already in the bills).
Future<void> scanBillFlow(BuildContext context, WalletController wc, {FileChooser chooser = const FileChooser()}) async {
  logNav('scan.open');
  final screen = ScanBillScreen(wc: wc);
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
    showBillImport(context, wc, r, chooser: chooser);
  }
}

/// The camera looks for the QR code of a receipt or the PDF417 barcode of a payment slip. "Take photo" opens the phone's own camera
/// app for one full-size picture (the photo stays with the bill) and reads its text; cancelling comes back here. Pops a [BillImport].
class ScanBillScreen extends StatefulWidget {
  final WalletController wc;
  const ScanBillScreen({super.key, required this.wc});
  @override
  State<ScanBillScreen> createState() => _ScanBillScreenState();
}

class _ScanBillScreenState extends State<ScanBillScreen> {
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
    Uint8List? bytes;
    String? failed;
    try {
      bytes = await widget.wc.billInputs.camera.takePhoto();
    } on BillPhotoException catch (e) {
      failed = e.code == 'permission'
          ? 'The camera is off for this app. Allow it in Android settings, or import a bill file.'
          : e.code == 'tooBig'
              ? billTooBigMessage
              : "Couldn't take the photo. Try again, or import a file.";
    } catch (_) {
      failed = "Couldn't take the photo. Try again, or import a file.";
    }
    logNav('scan.photoDone', {'result': failed != null ? 'failed' : (bytes == null ? 'cancelled' : 'ok')});
    if (!mounted) return;
    if (failed != null || bytes == null) {
      // Cancelled: back to the scanner with nothing said.
      setState(() {
        _busy = false;
        _hint = failed;
      });
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
            widget.wc.billInputs.camera.view(onCode: _onCode),
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
