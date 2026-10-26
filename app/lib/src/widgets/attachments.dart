// P16b: the photos and PDFs attached to one payment, listed on the payment sheet. "Attach photo or PDF" takes a photo
// (where there is a camera) or picks a file; a row opens the file, Remove has an Undo. Logs: counts and enum words only.
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../bill_inputs.dart';
import '../controller.dart';
import '../file_chooser.dart';
import '../layout.dart';
import '../logging.dart';
import '../screens/bill_sheet.dart';
import '../theme.dart';
import 'common.dart';
import 'sheets.dart' show showSheet;

final _log = Logger('bw.bills');

/// "340 KB", "1.2 MB".
String attachmentSize(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil().clamp(1, 1023)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class AttachmentsSection extends StatefulWidget {
  final WalletController wc;
  final String txId;
  final FileChooser chooser;
  const AttachmentsSection({super.key, required this.wc, required this.txId, this.chooser = const FileChooser()});
  @override
  State<AttachmentsSection> createState() => _AttachmentsSectionState();
}

class _AttachmentsSectionState extends State<AttachmentsSection> {
  bool busy = false;

  /// The last result in plain words (shown inside the sheet: a snack bar would sit behind it), and the removed file it can bring back.
  String? note;
  String? undoId;

  List<Bill> get items => widget.wc.attachments(widget.txId);

  void _say(String msg, {String? undo}) {
    if (!mounted) return;
    setState(() {
      note = msg;
      undoId = undo;
    });
  }

  Future<void> _add() async {
    if (busy) return;
    setState(() => busy = true); // before the chooser opens: a second tap must not open a second one
    try {
      var how = 'file';
      if (widget.wc.billInputs.camera.supported) {
        logNav('attach.choose');
        final r = await showSheet<String>(context, const _AttachChooser());
        if (r == null || !mounted) return;
        how = r;
      }
      if (how == 'camera') {
        await _fromCamera();
      } else {
        await _fromFile();
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _fromCamera() async {
    logNav('attach.camera');
    Uint8List? bytes;
    try {
      bytes = await widget.wc.billInputs.camera.takePhoto();
    } on BillPhotoException catch (e) {
      logNav('attach.photoDone', {'result': 'failed', 'code': e.code});
      _say(photoFailureMessage(e.code));
      return;
    } catch (e, st) {
      logError(_log, 'attach.photoFailed', e, st, fields: {'type': e.runtimeType.toString()});
      _say(photoFailedMessage);
      return;
    }
    if (bytes == null) {
      logNav('attach.photoDone', {'result': 'cancelled'});
      return;
    }
    await _store(bytes, 'jpg');
  }

  Future<void> _fromFile() async {
    logNav('attach.pick');
    final List<PlatformFile> picked;
    try {
      picked = await widget.chooser.pickAttachmentFiles();
    } catch (e, st) {
      logError(_log, 'attach.pickerFailed', e, st, fields: {'type': e.runtimeType.toString()});
      _say(chooserFailedMessage);
      return;
    }
    if (picked.isEmpty) {
      logNav('attach.cancelled');
      return;
    }
    final pf = picked.first;
    final ext = fileExt(pf.name);
    Uint8List? bytes;
    try {
      // The size is asked before the file is read: a huge file is never loaded into memory.
      final size = await pf.length();
      if (size != null && size > maxBillFileBytes(ext)) {
        _say(attachMessage(AttachResult.tooBig)!);
        return;
      }
      bytes = await pf.readAsBytes();
    } catch (e, st) {
      logError(_log, 'attach.openFailed', e, st, fields: {'type': e.runtimeType.toString()});
      _say("Couldn't open that file.");
      return;
    }
    await _store(bytes, ext);
  }

  Future<void> _store(Uint8List bytes, String ext) async {
    final r = await widget.wc.attachFile(widget.txId, bytes, ext);
    if (!mounted) return;
    final msg = attachMessage(r);
    if (msg != null) {
      _say(msg);
    } else {
      // A new file replaces an old note (and its Undo); a cancelled Attach leaves them alone.
      setState(() => note = undoId = null);
    }
  }

  void _remove(Bill a) {
    logNav('attach.remove');
    widget.wc.removeAttachment(a.id);
    _say('Attachment removed', undo: a.id);
  }

  void _undo() {
    final id = undoId;
    if (id == null) return;
    logNav('attach.undo');
    if (widget.wc.restoreAttachment(id)) {
      setState(() => note = undoId = null);
    } else {
      _say(attachMessage(AttachResult.full)!);
    }
  }

  void _open(Bill a) {
    logNav('attach.open', {'type': a.blobType});
    Navigator.of(context).push<void>(
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => BillFileScreen(wc: widget.wc, bill: a, chooser: widget.chooser)));
  }

  @override
  Widget build(BuildContext context) {
    final list = items;
    final full = list.length >= maxAttachmentsPerTx;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < list.length; i++) _row(context, list[i], i + 1),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
              Text(note!, key: const ValueKey('attachNote'), style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
              if (undoId != null)
                TextButton(
                    key: const ValueKey('attachUndo'),
                    style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
                    onPressed: _undo,
                    child: const Text('Undo')),
            ]),
          ),
        if (full)
          const Padding(
              padding: EdgeInsets.only(top: 4), child: Muted('5 attachments, the most a payment can hold', key: ValueKey('attachFull')))
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                key: const ValueKey('attachAdd'),
                style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
                icon: const Icon(Icons.attach_file, size: 18),
                label: const Text('Attach photo or PDF'),
                onPressed: busy ? null : _add),
          ),
      ]),
    );
  }

  Widget _row(BuildContext context, Bill a, int n) {
    final pdf = a.blobType == 'pdf';
    final label = '${pdf ? 'PDF' : 'Photo'} $n';
    final size = a.blobBytes == null || a.blobBytes == 0 ? '' : ' · ${attachmentSize(a.blobBytes!)}';
    return RuledRow(
      child: Row(children: [
        Expanded(
          child: InkWell(
            key: ValueKey('attachRow:${a.id}'),
            onTap: () => _open(a),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: touchMin),
              child: Row(children: [
                Icon(pdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined, size: 18, color: context.c.ink2),
                const SizedBox(width: 8),
                Expanded(child: Text('$label$size', style: const TextStyle(fontSize: BwType.bodySize))),
              ]),
            ),
          ),
        ),
        IconButton(
            key: ValueKey('attachRemove:${a.id}'),
            tooltip: 'Remove $label',
            constraints: const BoxConstraints(minWidth: touchMin, minHeight: touchMin),
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: () => _remove(a)),
      ]),
    );
  }
}

/// Take a photo or pick a file.
class _AttachChooser extends StatelessWidget {
  const _AttachChooser();
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const Heading('Attach'),
        const SizedBox(height: 8),
        ListTile(
            key: const ValueKey('attachCamera'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take photo'),
            onTap: () => Navigator.pop(context, 'camera')),
        ListTile(
            key: const ValueKey('attachPick'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('Pick a file'),
            onTap: () => Navigator.pop(context, 'file')),
      ]);
}
