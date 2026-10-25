import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../logging.dart';
import '../widgets/common.dart';
import 'csv_map_sheet.dart';

final _log = Logger('bw.app');

/// Choose bank files and import them: Plan › Import and the weekly review share this. Every failure is logged (type and counts
/// only, never file names or paths) and shown as a short message; the result lines are in [WalletController.lastImport].
Future<void> pickAndImport(BuildContext context, WalletController wc, FileChooser chooser) async {
  logNav('import.pick');
  final List<PlatformFile> picked;
  try {
    picked = await chooser.pickBankFiles();
  } catch (e, st) {
    logError(_log, 'import.pickerFailed', e, st, fields: {'type': e.runtimeType.toString()});
    if (context.mounted) toast(context, chooserFailedMessage);
    return;
  }
  if (picked.isEmpty) {
    logNav('import.cancelled');
    return;
  }
  final files = <(String, Uint8List)>[];
  try {
    for (final pf in picked) {
      files.add((pf.name, await pf.readAsBytes()));
    }
  } catch (e, st) {
    // describeError drops the path (it would name the bank file).
    logError(_log, 'import.openFailed', e, st, fields: {'files': picked.length, 'read': files.length});
    if (context.mounted) toast(context, "Couldn't open that file.");
    return;
  }
  // Extensions and sizes only, never file names.
  logNav('import.chosen', {
    'files': files.length,
    'exts': [for (final (n, _) in files) fileExt(n)],
    'bytes': [for (final (_, b) in files) b.length],
  });
  await wc.importFiles(files, askMapping: (need, bytes) async {
    if (!context.mounted) return null;
    return openMapColumns(context, wc, need.shape, bytes);
  });
}
