import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/import_problems.dart';
import '../widgets/sheets.dart';

/// Opens the import preview (Q4) for one file. Returns the ids the owner chose to leave out (Skip), or null on Cancel or close:
/// nothing is written then. Logs `importPreview.open` with counts only, never descriptions.
Future<Set<String>?> openImportPreview(BuildContext context, ImportPreview preview, String bank,
    {List<String> problems = const [], int invalid = 0}) {
  logNav('importPreview.open', {'rows': preview.rows.length, 'fresh': preview.fresh, 'dupes': preview.duplicates, 'invalid': invalid});
  return showSheet<Set<String>>(context, ImportPreviewSheet(preview: preview, bank: bank, problems: problems, invalid: invalid));
}

/// "N new · M already here · K match expenses you added · T transfers" and the rows behind each count. Each new row has a Skip
/// toggle. **Import** pops the skip set, **Cancel** pops null.
class ImportPreviewSheet extends StatefulWidget {
  final ImportPreview preview;
  final String bank;

  /// Why rows were left out of the file (core's `ImportBatch.problems`) and how many were.
  final List<String> problems;
  final int invalid;
  const ImportPreviewSheet({super.key, required this.preview, required this.bank, this.problems = const [], this.invalid = 0});
  @override
  State<ImportPreviewSheet> createState() => _ImportPreviewSheetState();
}

class _ImportPreviewSheetState extends State<ImportPreviewSheet> {
  final Set<String> skip = {};
  final Set<PreviewStatus> open = {};
  final Map<PreviewStatus, int> shown = {};
  static const _page = 50;

  static const _titles = {
    PreviewStatus.fresh: 'New',
    PreviewStatus.matchesManual: 'Match expenses you added',
    PreviewStatus.revivable: 'Read again',
    PreviewStatus.duplicate: 'Already here',
    PreviewStatus.collision: 'Same id, other amount: left out',
    PreviewStatus.tooLarge: 'Too large: left out',
  };

  bool _canSkip(PreviewStatus s) => s == PreviewStatus.fresh || s == PreviewStatus.matchesManual || s == PreviewStatus.revivable;

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    final c = context.c;
    int left(PreviewStatus s) => p.rows.where((r) => r.status == s && !skip.contains(r.tx.id)).length;
    final nFresh = left(PreviewStatus.fresh);
    final nMatch = left(PreviewStatus.matchesManual);
    final nRead = left(PreviewStatus.revivable);
    // Transfers are pairs (a row and the row of the owner's other account it pairs with), counted once, only for rows that will be written.
    final pairs = <String>{
      for (final r in p.rows)
        if ((r.status == PreviewStatus.fresh || r.status == PreviewStatus.revivable) &&
            r.transferPairId != null &&
            !skip.contains(r.tx.id) &&
            !skip.contains(r.transferPairId))
          ([r.tx.id, r.transferPairId!]..sort()).join('|'),
    };
    final parts = [
      '$nFresh new',
      if (nRead > 0) '$nRead read again',
      if (p.duplicates > 0) '${p.duplicates} already here',
      if (nMatch > 0) '$nMatch match expenses you added',
      if (pairs.isNotEmpty) '${pairs.length} ${pairs.length == 1 ? 'transfer' : 'transfers'}',
      if (p.collisions > 0) '${p.collisions} clash${p.collisions == 1 ? '' : 'es'}',
      if (p.tooLarge > 0) '${p.tooLarge} too large',
      if (skip.isNotEmpty) '${skip.length} skipped',
    ];
    final summary = parts.join(' · ');
    final cur = p.rows.isEmpty ? 'EUR' : p.rows.first.tx.currency;
    return Column(key: const ValueKey('importPreview'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Check before importing'),
      const SizedBox(height: 4),
      Muted('${widget.bank} · ${p.rows.length} ${p.rows.length == 1 ? 'row' : 'rows'} in the file. Nothing is saved until you tap Import.'),
      const SizedBox(height: 10),
      Text(summary, key: const ValueKey('importPreviewSummary'), style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      if (widget.problems.isNotEmpty || widget.invalid > 0) ...[
        ImportProblems(problems: widget.problems, invalid: widget.invalid),
        const SizedBox(height: 8),
      ],
      for (final s in _titles.keys) ..._group(context, s, cur),
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('importPreviewImport'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: () {
            logNav('importPreview.import', {'skipped': skip.length});
            Navigator.pop(context, Set<String>.of(skip));
          },
          child: Text(nFresh + nMatch + left(PreviewStatus.revivable) == 0
              ? 'Import'
              : 'Import ${nFresh + nMatch + left(PreviewStatus.revivable)}')),
      const SizedBox(height: 8),
      TextButton(
          key: const ValueKey('importPreviewCancel'),
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin), foregroundColor: c.ink2),
          onPressed: () {
            logNav('importPreview.cancel');
            Navigator.pop(context);
          },
          child: const Text('Cancel')),
    ]);
  }

  List<Widget> _group(BuildContext context, PreviewStatus s, String cur) {
    final rows = widget.preview.rows.where((r) => r.status == s).toList();
    if (rows.isEmpty) return const [];
    final isOpen = open.contains(s);
    final n = (shown[s] ?? _page).clamp(0, rows.length);
    return [
      InkWell(
        key: ValueKey('previewGroup:${s.name}'),
        onTap: () => setState(() => isOpen ? open.remove(s) : open.add(s)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: touchMin),
          child: Row(children: [
            Icon(isOpen ? Icons.expand_less : Icons.expand_more, size: 20),
            const SizedBox(width: 6),
            Expanded(child: Text('${_titles[s]} · ${rows.length}', style: const TextStyle(fontWeight: FontWeight.w500))),
          ]),
        ),
      ),
      if (isOpen) ...[
        for (final r in rows.take(n)) _row(context, r),
        if (rows.length > n)
          TextButton(
              key: ValueKey('previewMore:${s.name}'),
              onPressed: () => setState(() => shown[s] = n + _page),
              child: Text('Show more (${rows.length - n} left)')),
      ],
      Divider(height: 1, color: context.c.line),
    ];
  }

  Widget _row(BuildContext context, PreviewRow r) {
    final c = context.c;
    final t = r.tx;
    final skipped = skip.contains(t.id);
    return Padding(
      key: ValueKey('previewRow:${t.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SplitRow(
            start: Text(t.description.isEmpty ? '(no description)' : t.description,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(decoration: skipped ? TextDecoration.lineThrough : null)),
            end: Text(moneyExactSigned(t.amountMinor, t.currency),
                textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
        Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(shortDateOrRaw(t.date), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
          if (r.transferPairId != null) const Tag('own transfer'),
          if (r.status == PreviewStatus.matchesManual) const Tag('replaces your entry'),
          if (_canSkip(r.status))
            TextButton.icon(
                key: ValueKey('previewSkip:${t.id}'),
                style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
                icon: Icon(skipped ? Icons.undo : Icons.block, size: 16),
                label: Text(skipped ? 'Skipped. Undo' : 'Skip'),
                onPressed: () => setState(() => skipped ? skip.remove(t.id) : skip.add(t.id))),
        ]),
      ]),
    );
  }
}
