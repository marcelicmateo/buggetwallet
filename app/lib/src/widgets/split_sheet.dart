// The split editor (stage P6, spec docs/context/P6_SPEC.md §6): one payment cut into parts, each with an amount, a main tag, extra tags
// and a note. Save stays off until the parts add up to the payment exactly; core checks everything again and its `ArgumentError`
// text is shown if it still refuses. The arithmetic here is only "payment minus the parts typed" for the running line.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import 'category_picker.dart';
import 'common.dart';
import 'tag_picker.dart';

/// One part being edited. The controllers and the tag set live as long as the part does.
class _PartDraft {
  final TextEditingController amount;
  final TextEditingController note;
  String category;
  Set<String> tags;
  _PartDraft({required int cents, required this.category, Set<String>? tags, String? note})
      : amount = TextEditingController(text: cents == 0 ? '' : centsToFieldText(cents)),
        note = TextEditingController(text: note ?? ''),
        tags = {...?tags};
  void dispose() {
    amount.dispose();
    note.dispose();
  }
}

/// The split editor of [row]'s payment. Pops 'split' (saved) or 'splitRemoved'.
class SplitSheet extends StatefulWidget {
  final WalletController wc;

  /// The payment as one row (its own main tag and tags pre-fill the first part).
  final CategorizedTx row;

  /// The main tag and tags picked on the payment sheet and not saved: the first part of a new split starts with them
  /// (null: the payment's own).
  final String? firstCategory;
  final Set<String>? firstTags;
  const SplitSheet({super.key, required this.wc, required this.row, this.firstCategory, this.firstTags});
  @override
  State<SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<SplitSheet> {
  late final Tx tx = widget.row.tx;

  /// The stored split (valid or not), or null when the payment has none.
  late final List<SplitPart>? stored = widget.wc.storedSplit(tx.id);
  late final List<String> mainIds = widget.wc.recommendedMainFor(tx);
  late final List<_PartDraft> parts = _initial();
  String? error;

  /// Removed parts: their controllers are disposed with the sheet (the field is still mounted when the part leaves the list).
  final List<_PartDraft> _removed = [];

  /// 1 for money in, -1 for money out: the field holds a plain amount, the part gets the payment's sign.
  late final int sign = tx.amount < 0 ? -1 : 1;
  int get total => tx.amount.abs();

  List<_PartDraft> _initial() {
    final s = stored;
    if (s != null && s.isNotEmpty) {
      return [for (final p in s) _PartDraft(cents: p.amount.abs(), category: p.category, tags: p.tags.toSet(), note: p.note)];
    }
    final cat = widget.firstCategory ?? widget.row.category;
    return [
      _PartDraft(cents: total, category: cat, tags: widget.firstTags ?? widget.row.tags.toSet()),
      _PartDraft(cents: 0, category: cat),
    ];
  }

  @override
  void dispose() {
    for (final p in [...parts, ..._removed]) {
      p.dispose();
    }
    super.dispose();
  }

  /// The cents typed in a part; null when empty, not a number or zero.
  int? _cents(_PartDraft p) {
    final v = parseMoney(p.amount.text);
    return v == null || v == 0 ? null : v;
  }

  int get _sum => parts.fold(0, (a, p) => a + (_cents(p) ?? 0));
  int get _left => total - _sum;

  /// Why Save is off, or null when it is on.
  String? get _reason {
    if (parts.any((p) => _cents(p) == null)) return 'Every part needs an amount.';
    final cur = tx.currency;
    if (_left > 0) return 'Add ${money(_left, cur, decimals: 2)} to a part to save.';
    if (_left < 0) return 'Take ${money(-_left, cur, decimals: 2)} off the parts to save.';
    return null;
  }

  void _save() {
    final list = [
      for (final p in parts)
        SplitPart(
            amount: sign * (_cents(p) ?? 0),
            category: p.category,
            tags: p.tags.toList(),
            note: p.note.text.trim().isEmpty ? null : p.note.text.trim())
    ];
    try {
      widget.wc.saveSplit(tx, list);
    } on ArgumentError catch (e) {
      setState(() => error = e.message?.toString() ?? 'Could not save the split.');
      return;
    }
    Navigator.pop(context, 'split');
  }

  void _remove() {
    widget.wc.removeSplitOf(tx);
    Navigator.pop(context, 'splitRemoved');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cur = tx.currency;
    final left = _left;
    final reason = _reason;
    final leftText = left < 0 ? 'Over by ${money(-left, cur, decimals: 2)}' : 'Left to split: ${money(left, cur, decimals: 2)}';
    return Column(key: const ValueKey('splitSheet'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Split payment'),
      const SizedBox(height: 6),
      Text('${merchantName(tx)} · ${money(total, cur, decimals: 2)}', style: numStyle.copyWith(fontSize: BwType.bodySize)),
      const SizedBox(height: 4),
      const Muted('Cut the payment into parts. They must add up to the whole amount.'),
      const SizedBox(height: 10),
      for (var i = 0; i < parts.length; i++)
        KeyedSubtree(
          key: ObjectKey(parts[i]),
          child: Container(
            key: ValueKey('splitPart:$i'),
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.lineStrong))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              HeadingRow(
                  Text('Part ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  parts.length > SplitPart.minParts
                      ? IconButton(
                          key: ValueKey('splitPartRemove:$i'),
                          tooltip: 'Remove part ${i + 1}',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _removed.add(parts.removeAt(i))))
                      : const SizedBox.shrink()),
              MoneyField(
                  controller: parts[i].amount,
                  fieldKey: ValueKey('splitAmount:$i'),
                  decoration: InputDecoration(labelText: 'Amount', suffixText: cur),
                  onChanged: (_) => setState(() => error = null)),
              const SizedBox(height: 10),
              MainTagPicker(
                  dropdown: true,
                  table: widget.wc.categoryTable,
                  ids: mainIds,
                  selected: parts[i].category,
                  fieldKey: ValueKey('splitCategory:$i'),
                  onPick: (v) => setState(() => parts[i].category = v)),
              const SizedBox(height: 8),
              ExtraTagsEditor(wc: widget.wc, initial: parts[i].tags, onChanged: (on, _) => parts[i].tags = on),
              const SizedBox(height: 8),
              TextField(
                  key: ValueKey('splitNote:$i'),
                  controller: parts[i].note,
                  maxLength: SplitPart.maxNote,
                  buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                  decoration: const InputDecoration(labelText: 'Note')),
            ]),
          ),
        ),
      if (parts.length < SplitPart.maxParts)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              key: const ValueKey('splitAddPart'),
              style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add part'),
              onPressed: () => setState(() => parts.add(_PartDraft(cents: 0, category: widget.firstCategory ?? widget.row.category)))),
        ),
      const SizedBox(height: 6),
      const DoubleRule(),
      const SizedBox(height: 6),
      Text(leftText,
          key: const ValueKey('splitLeft'),
          textAlign: TextAlign.end,
          style: numStyle.copyWith(fontSize: BwType.bodySize, fontWeight: FontWeight.w600, color: left == 0 ? c.good : c.ink)),
      if (reason != null || error != null)
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error ?? reason!,
                key: const ValueKey('splitReason'),
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: BwType.metaSize, color: error != null ? c.bad : c.ink2))),
      const SizedBox(height: 10),
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [
        FilledButton(key: const ValueKey('splitSave'), onPressed: reason == null ? _save : null, child: const Text('Save split')),
        if (stored != null)
          TextButton(
              key: const ValueKey('splitRemove'),
              style: TextButton.styleFrom(foregroundColor: c.bad, minimumSize: const Size(0, touchMin)),
              onPressed: _remove,
              child: const Text('Remove split')),
      ]),
    ]);
  }
}
