import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../logging.dart';
import '../widgets/common.dart';
import 'accounts_panel.dart' show askBankBalance;
import 'csv_layouts_panel.dart';
import 'csv_map_sheet.dart';
import 'first_plan_sheet.dart';
import 'import_preview_sheet.dart';

final _log = Logger('bw.app');

/// Choose bank files and import them: Plan › Import and the weekly review share this. Every failure is logged (type and counts
/// only, never file names or paths) and shown as a short message; the result lines are in [WalletController.lastImport].
Future<void> pickAndImport(BuildContext context, WalletController wc, FileChooser chooser) async {
  logNav('import.pick');
  final List<PickedFile> picked;
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
      files.add((pf.name, await pf.readBytes()));
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
  final lines = await wc.importFiles(files,
      askMapping: (need, bytes) async {
        if (!context.mounted) return null;
        return openMapColumns(context, wc, need.shape, bytes);
      },
      confirmRemoval: (n) async => context.mounted && await confirmRemovePayments(context, n),
      // Q4: the owner sees what the file will do first (Settings › Import › Always show; off = files go straight in).
      confirmPreview:
          wc.importPreviewAlways ? (preview, bank) async => context.mounted ? openImportPreview(context, preview, bank) : null : null);
  // A saved layout that read the file another way replaced its earlier payments: Undo puts them back.
  final undo = lines.map((l) => l.undo).whereType<VoidCallback>().firstOrNull;
  if (undo != null && context.mounted) {
    toast(context, 'Earlier payments of that layout were read again.', actionLabel: 'Undo', onAction: undo);
  }
  // Q5: accounts the file gave no balance for: "What did the bank app show when you downloaded this file?"
  for (final built in newestPerAccount(lines.expand((l) => l.questions))) {
    if (!context.mounted) break;
    final q = wc.questionNow(built); // counted again now; none when a check as new as the file exists
    if (q != null) await askBankBalance(context, wc, q, fromImport: true);
  }
  // An import that added rows and leaves plan suggestions: "Looks right?" once per wallet.
  if (context.mounted && lines.any((l) => l.ok && l.added > 0)) await offerFirstPlan(context, wc);
}
