import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';

final _log = Logger('bw.export');

/// Plan › Export: transactions (a range) and the monthly summary as CSV files through the system save dialog.
class ExportPanel extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;
  const ExportPanel({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  State<ExportPanel> createState() => _ExportPanelState();
}

class _ExportPanelState extends State<ExportPanel> {
  ExportRange _range = ExportRange.period;
  bool _busy = false;

  static const _labels = {ExportRange.period: 'This period', ExportRange.year: 'This year', ExportRange.all: 'Everything'};

  Future<void> _save(ExportFile Function() make, String what) async {
    logNav('export.pressed', {'what': what});
    final f = make();
    if (f.rows == 0) {
      toast(context, 'Nothing to export in this range');
      return;
    }
    setState(() => _busy = true);
    try {
      final uri = await widget.chooser.saveText(fileName: f.name, bytes: f.bytes, title: 'Save CSV');
      logEvent(_log, Level.INFO, 'export.saved', {'what': what, 'saved': uri != null, 'rows': f.rows, 'bytes': f.bytes.length});
      if (uri != null && mounted) toast(context, 'Saved ${f.name}');
    } catch (e, st) {
      logError(_log, 'export.saveFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) toast(context, chooserFailedMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Panel(children: [
        const SectionHead('Export'),
        const Muted('CSV files for your spreadsheet: date, amount, category, description, source and note.'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final r in ExportRange.values)
            ChoiceChip(
              key: ValueKey('range:${r.name}'),
              label: Text(_labels[r]!),
              selected: _range == r,
              onSelected: (_) => setState(() => _range = r),
            ),
        ]),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
              key: const ValueKey('exportTx'),
              style: accentOutlined(context),
              onPressed: _busy ? null : () => _save(() => widget.wc.exportTransactions(_range), 'transactions'),
              child: const Text('Export transactions (CSV)')),
          OutlinedButton(
              key: const ValueKey('exportSummary'),
              onPressed: _busy ? null : () => _save(widget.wc.exportSummary, 'summary'),
              child: const Text('Export monthly summary (CSV)')),
        ]),
        const Muted('Plain files, not encrypted.'),
      ]);
}
