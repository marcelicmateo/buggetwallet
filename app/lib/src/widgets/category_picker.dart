// Main tag pickers (P1, T1): the ids a picker offers come from core's `CategoryTable.pickable`; the order for one payment is core's
// `recommendedMainTags` (the payee's tags first). A main tag already chosen stays in the list even when it was hidden or removed since,
// so the field never loses its value. T1 replaced subcategories by tags, so the list is flat.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

/// How many main tags a picker shows before "More…".
const int mainTagTop = 20;

/// The ids a picker offers: `table.pickable(kinds:)`, plus [current] (a hidden or removed one) at the end.
List<String> pickerIds(CategoryTable t, {Set<BudgetKind>? kinds, String? current, Iterable<String> except = const []}) {
  final ids = [
    for (final c in t.pickable(kinds: kinds))
      if (!except.contains(c)) c
  ];
  if (current != null && !ids.contains(current)) ids.add(current);
  return ids;
}

/// The text of [id] in a picker: its label, with a note when it is not offered any more.
String pickerLabel(CategoryTable t, String id) {
  final base = t.label(id);
  if (!t.isLive(id) && t.isCustom(id)) return '$base (removed)';
  if (t.isHidden(id)) return '$base (hidden)';
  return base;
}

/// Menu items for a dropdown: [noneLabel] first when given (value null), then every offered main tag (key `pick:<id>`).
List<DropdownMenuItem<String?>> categoryMenuItems(CategoryTable t,
    {Set<BudgetKind>? kinds, String? current, String? noneLabel, Iterable<String> except = const []}) {
  return [
    if (noneLabel != null) DropdownMenuItem<String?>(value: null, child: Text(noneLabel)),
    for (final id in pickerIds(t, kinds: kinds, current: current, except: except))
      DropdownMenuItem<String?>(
        value: id,
        child: Text(pickerLabel(t, id), key: ValueKey('pick:$id'), overflow: TextOverflow.ellipsis),
      ),
  ];
}

/// Choice chips for a plain list of main tags (key `cat:<id>`).
List<Widget> categoryChips(CategoryTable t,
    {required Set<BudgetKind> kinds, required String? selected, required ValueChanged<String> onPick, Iterable<String> except = const []}) {
  return [
    for (final id in pickerIds(t, kinds: kinds, current: selected, except: except))
      ChoiceChip(
        key: ValueKey('cat:$id'),
        label: Text(pickerLabel(t, id)),
        selected: id == selected,
        onSelected: (_) => onPick(id),
      ),
  ];
}

const _moreValue = '\u0000more';

/// The main tag picker of a transaction sheet, the add-expense sheet and the review: [ids] are already in recommended order
/// (`wc.recommendedMainFor`); the first [mainTagTop] show, a "More…" entry (`mainTagMore`) opens the rest. The chosen one is always
/// shown. [dropdown]: a menu (key `txCategory`, items `pick:<id>`), else choice chips (`cat:<id>`).
class MainTagPicker extends StatefulWidget {
  final CategoryTable table;
  final List<String> ids;
  final String? selected;
  final ValueChanged<String> onPick;
  final bool dropdown;

  /// The field label of the dropdown form.
  final String label;
  const MainTagPicker(
      {super.key,
      required this.table,
      required this.ids,
      required this.selected,
      required this.onPick,
      this.dropdown = false,
      this.label = 'Main tag'});
  @override
  State<MainTagPicker> createState() => _MainTagPickerState();
}

class _MainTagPickerState extends State<MainTagPicker> {
  bool _all = false;

  /// What shows now: the top ones (or all), with the selected one in front when it is not among them.
  List<String> get _shown {
    final base = _all ? widget.ids : widget.ids.take(mainTagTop).toList();
    final s = widget.selected;
    return s == null || base.contains(s) ? base : [...base, s];
  }

  bool get _hasMore => !_all && widget.ids.length > mainTagTop;

  @override
  Widget build(BuildContext context) {
    final t = widget.table;
    if (widget.dropdown) {
      return InputDecorator(
        decoration: InputDecoration(labelText: widget.label),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: const ValueKey('txCategory'),
            isExpanded: true,
            isDense: true,
            value: widget.selected,
            items: [
              for (final id in _shown)
                DropdownMenuItem<String>(
                    value: id, child: Text(pickerLabel(t, id), key: ValueKey('pick:$id'), overflow: TextOverflow.ellipsis)),
              if (_hasMore) const DropdownMenuItem<String>(value: _moreValue, child: Text('More…', key: ValueKey('mainTagMore'))),
            ],
            onChanged: (v) {
              if (v == null) return;
              if (v == _moreValue) {
                setState(() => _all = true);
              } else {
                widget.onPick(v);
              }
            },
          ),
        ),
      );
    }
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final id in _shown)
        ChoiceChip(
          key: ValueKey('cat:$id'),
          label: Text(pickerLabel(t, id)),
          selected: id == widget.selected,
          onSelected: (_) => widget.onPick(id),
        ),
      if (_hasMore)
        ActionChip(key: const ValueKey('mainTagMore'), label: const Text('More…'), onPressed: () => setState(() => _all = true)),
    ]);
  }
}
