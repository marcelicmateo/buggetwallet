import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart' show Logger, logError;
import 'package:wallet_importer/wallet_importer.dart'
    show CsvDecimal, CsvMapping, CsvShape, ImportException, csvShape, layoutMismatchMessage, matchCsvLayout;

import '../controller.dart';
import '../file_chooser.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'csv_map_sheet.dart';

/// Plan › Import › Saved file layouts: the CSV column maps remembered from Map columns (P12). Rename, see the columns, delete with Undo.
/// Not shown while there is none.
class CsvLayoutsPanel extends StatelessWidget {
  final WalletController wc;
  final FileChooser chooser;
  const CsvLayoutsPanel({super.key, required this.wc, this.chooser = const FileChooser()});

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
                  key: ValueKey('csvLayoutEdit:${e.key}'),
                  onPressed: () => editCsvLayout(context, wc, chooser, e.key),
                  child: const Text('Change')),
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

/// The question before a layout that imported [n] payments is read another way: they are removed (Undo is offered after).
Future<bool> confirmRemovePayments(BuildContext context, int n) async =>
    await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              key: const ValueKey('csvEditConfirm'),
              title: const Text('Remove its payments?'),
              content: Text("This layout was used for $n ${n == 1 ? 'payment' : 'payments'}. They'll be removed; "
                  'import the file again to read them the new way.'),
              actions: [
                TextButton(key: const ValueKey('csvEditCancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(
                    key: const ValueKey('csvEditConfirmYes'),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Remove and save')),
              ],
            )) ==
    true;

/// Changes how a saved layout reads: pick a file of the same shape, adjust the columns in the Map columns sheet, save. When payments
/// were imported with the layout and the change affects reading, ask first: they are removed (Undo brings them back) and the file is
/// imported again to read them the new way.
Future<void> editCsvLayout(BuildContext context, WalletController wc, FileChooser chooser, String id) async {
  logNav('csvLayout.editOpen');
  final old = wc.settings.csvMappings[id];
  if (old == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
  void say(String m, {String? label, VoidCallback? action}) =>
      toastOn(messenger, m, wide: wide, accessible: accessible, actionLabel: label, onAction: action);
  final List<PickedFile> picked;
  try {
    picked = await chooser.pickBankFiles();
  } catch (e, st) {
    logError(Logger('bw.import'), 'csvLayout.pickFailed', e, st, fields: {'type': e.runtimeType.toString()});
    say(chooserFailedMessage);
    return;
  }
  if (picked.isEmpty) return;
  final Uint8List bytes;
  final CsvShape shape;
  try {
    bytes = await picked.first.readBytes();
    final first = csvShape(bytes);
    final match = matchCsvLayout(bytes, first, {id: old});
    if (match == null) {
      say(layoutMismatchMessage);
      return;
    }
    shape = csvShape(bytes, headerRow: match.headerRow);
  } on ImportException catch (e) {
    say(e.message);
    return;
  } catch (e, st) {
    logError(Logger('bw.import'), 'csvLayout.openFailed', e, st, fields: {'type': e.runtimeType.toString()});
    say("Couldn't open that file.");
    return;
  }
  if (!context.mounted) return;
  final choice = await openMapColumns(context, wc, shape, bytes, editing: old);
  if (choice == null) return;
  var removed = const <String>[];
  try {
    removed = wc.saveCsvLayout(id, choice.mapping);
  } on ArgumentError catch (e) {
    final n = wc.csvRowsFor(id);
    if (n == 0) {
      say(e.message.toString());
      return;
    }
    if (!context.mounted) return;
    final ok = await confirmRemovePayments(context, n);
    if (ok != true) return;
    try {
      removed = wc.saveCsvLayout(id, choice.mapping, force: true);
    } on ArgumentError catch (e2) {
      say(e2.message.toString());
      return;
    }
  }
  if (removed.isEmpty) {
    say('Layout saved');
    return;
  }
  final count = removed.length;
  say('Layout saved. $count ${count == 1 ? 'payment' : 'payments'} removed: import the file again.', label: 'Undo', action: () {
    try {
      wc.undoCsvLayoutEdit(id, old, removed);
    } on ArgumentError catch (e) {
      say(e.message.toString());
    }
  });
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
