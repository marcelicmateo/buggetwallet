// Stage V (VC): Settings › Sync › "Choose the right values". Two devices hold different values for the same field with the same
// clock; the app never picks one by itself. Each row names the item and the field, shows both values, and two buttons write the
// owner's choice. Logs carry counts only (the controller's `sync.conflict.resolve {keepMine}`); the values are shown, never logged.
import 'package:flutter/material.dart';

import '../conflict_text.dart';
import '../controller.dart';
import '../format.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// The row's name in the owner's words: a payment by its date and description, a setting by its plain name, anything else by its kind.
String conflictWhatText(WalletController wc, String entity, String rowId) {
  switch (entity) {
    case 'tx':
      final t = wc.wholeTxs.where((x) => x.tx.id == rowId).firstOrNull;
      if (t == null) return changeEntityWord(entity);
      final d = t.tx.description.trim();
      return d.isEmpty ? 'Payment ${shortDate(t.tx.date)}' : 'Payment ${shortDate(t.tx.date)} · $d';
    case 'setting':
      return changeSettingWord(rowId);
    default:
      return changeEntityWord(entity);
  }
}

/// A [ConflictLine] from the raw conflict: row name, field word and both values as text.
ConflictLine conflictLineOf(WalletController wc,
    {required String id, required String entity, required String rowId, required String field, Object? mine, Object? theirs}) {
  return ConflictLine(
    id: id,
    what: conflictWhatText(wc, entity, rowId),
    field: conflictFieldWord(entity, field),
    mine: conflictValueText(entity, rowId, field, mine, wc.currency),
    theirs: conflictValueText(entity, rowId, field, theirs, wc.currency),
  );
}

Future<void> openConflicts(BuildContext context, WalletController wc) {
  logNav('conflicts.open', {'count': wc.syncConflictCount});
  return openPageOrDialog<void>(context, ConflictsPage(wc: wc), width: 560, logName: 'conflicts');
}

class ConflictsPage extends StatelessWidget {
  final WalletController wc;

  /// For tests and previews: the lines and the choice, instead of the controller's.
  final List<ConflictLine> Function()? lines;
  final void Function(String id, bool keepMine)? onChoose;
  const ConflictsPage({super.key, required this.wc, this.lines, this.onChoose});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: const DialogAppBar(title: 'Choose the right values'),
        body: ListenableBuilder(
          listenable: wc,
          builder: (context, _) {
            final list = (lines ?? wc.conflictLines)();
            return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
              if (list.isEmpty)
                const EmptyNote('All settled. They sync on the next run.', key: ValueKey('conflictsDone'))
              else ...[
                const Muted('Each button keeps that device\'s value. Nothing changes until you choose.'),
                for (final l in list)
                  _ConflictRow(
                      line: l,
                      onChoose: (keepMine) => onChoose != null ? onChoose!(l.id, keepMine) : wc.resolveConflict(l.id, keepMine: keepMine)),
              ],
            ]);
          },
        ),
      );
}

class _ConflictRow extends StatelessWidget {
  final ConflictLine line;
  final void Function(bool keepMine) onChoose;
  const _ConflictRow({required this.line, required this.onChoose});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      key: ValueKey('conflict-${line.id}'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(line.what, style: const TextStyle(fontWeight: FontWeight.w600)),
        Muted('Field: ${line.field}'),
        const SizedBox(height: 8),
        _Side(label: 'This device', value: line.mine, buttonKey: ValueKey('conflictMine-${line.id}'), onTap: () => onChoose(true)),
        const SizedBox(height: 8),
        _Side(label: 'Other device', value: line.theirs, buttonKey: ValueKey('conflictTheirs-${line.id}'), onTap: () => onChoose(false)),
      ]),
    );
  }
}

class _Side extends StatelessWidget {
  final String label, value;
  final Key buttonKey;
  final VoidCallback onTap;
  const _Side({required this.label, required this.value, required this.buttonKey, required this.onTap});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(value),
        const SizedBox(height: 4),
        Align(alignment: Alignment.centerLeft, child: OutlinedButton(key: buttonKey, onPressed: onTap, child: Text(label))),
      ]);
}
