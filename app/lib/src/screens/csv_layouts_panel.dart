import 'package:flutter/material.dart';
import 'package:wallet_importer/wallet_importer.dart' show CsvDecimal, CsvMapping;

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// Plan › Import › Saved file layouts: the CSV column maps remembered from Map columns (P12). Rename, see the columns, delete with Undo.
/// Not shown while there is none.
class CsvLayoutsPanel extends StatelessWidget {
  final WalletController wc;
  const CsvLayoutsPanel({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final layouts = wc.csvLayouts();
    if (layouts.isEmpty) return const SizedBox.shrink();
    return Panel(key: const ValueKey('csvLayoutsPanel'), children: [
      const SectionHead('Saved file layouts'),
      const Muted(
          'A CSV that looks like one of these is read the same way, with no questions. Deleting one keeps the rows already imported.'),
      for (final e in layouts)
        RuledRow(
          key: ValueKey('csvLayout:${e.key}'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.value.name, style: const TextStyle(fontWeight: FontWeight.w500)),
            Text('${e.value.headers.isEmpty ? '' : '${e.value.headers.length} columns · '}header on row ${e.value.headerRow + 1}',
                style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
            Wrap(spacing: 8, runSpacing: 4, children: [
              TextButton(
                  key: ValueKey('csvLayoutColumns:${e.key}'),
                  onPressed: () => showSheet<void>(context, CsvLayoutColumnsSheet(mapping: e.value)),
                  child: const Text('Columns')),
              TextButton(
                  key: ValueKey('csvLayoutRename:${e.key}'),
                  onPressed: () => showSheet<bool>(context, RenameLayoutSheet(wc: wc, id: e.key, name: e.value.name)),
                  child: const Text('Rename')),
              TextButton(key: ValueKey('csvLayoutDelete:${e.key}'), onPressed: () => _delete(context, e.key), child: const Text('Delete')),
            ]),
          ]),
        ),
    ]);
  }

  void _delete(BuildContext context, String id) {
    logNav('csvLayout.delete');
    final m = wc.deleteCsvLayout(id);
    if (m == null) return;
    toast(context, 'Layout removed', actionLabel: 'Undo', onAction: () {
      try {
        wc.restoreCsvLayout(id, m);
      } on ArgumentError {
        // The layout was refused again; nothing to restore.
      }
    });
  }
}

/// What a layout reads from which column.
class CsvLayoutColumnsSheet extends StatelessWidget {
  final CsvMapping mapping;
  const CsvLayoutColumnsSheet({super.key, required this.mapping});

  String _col(int? i) {
    if (i == null) return '—';
    final h = i < mapping.headers.length ? mapping.headers[i].trim() : '';
    return h.isEmpty ? 'Column ${i + 1}' : h;
  }

  @override
  Widget build(BuildContext context) {
    final m = mapping;
    final rows = <(String, String)>[
      ('Date', '${_col(m.dateCol)} (${m.dateFormat.pattern})'),
      if (m.amountCol != null) ('Amount', _col(m.amountCol)) else ...[('Debit', _col(m.debitCol)), ('Credit', _col(m.creditCol))],
      ('Numbers', m.decimal == CsvDecimal.comma ? '1.234,56' : '1,234.56'),
      if (m.negate) ('Sign', 'Spending is shown as positive'),
      if (m.descriptionCols.isNotEmpty) ('Description', m.descriptionCols.map(_col).join(' · ')),
      ('Currency', m.currencyCol != null ? _col(m.currencyCol) : (m.currencyCode ?? 'Wallet currency')),
      if (m.skipIfEmptyCol != null) ('Skipped when empty', _col(m.skipIfEmptyCol)),
    ];
    return Column(key: const ValueKey('csvLayoutColumnsSheet'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(m.name),
      const SizedBox(height: 8),
      for (final (k, v) in rows)
        RuledRow(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SplitRow(start: Text(k, style: TextStyle(color: context.c.ink2)), end: Text(v, textAlign: TextAlign.end), maxEnd: 0.7)),
    ]);
  }
}

class RenameLayoutSheet extends StatefulWidget {
  final WalletController wc;
  final String id, name;
  const RenameLayoutSheet({super.key, required this.wc, required this.id, required this.name});
  @override
  State<RenameLayoutSheet> createState() => _RenameLayoutSheetState();
}

class _RenameLayoutSheetState extends State<RenameLayoutSheet> {
  late final _name = TextEditingController(text: widget.name);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    try {
      widget.wc.renameCsvLayout(widget.id, _name.text);
      Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Heading('Rename layout'),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('csvLayoutName'),
          controller: _name,
          autofocus: true,
          maxLength: CsvMapping.maxName,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: InputDecoration(labelText: 'Name', errorText: _error, errorMaxLines: 3, counterText: ''),
        ),
        const SizedBox(height: 14),
        FilledButton(
            key: const ValueKey('csvLayoutRenameSave'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: _save,
            child: const Text('Save')),
      ]);
}
