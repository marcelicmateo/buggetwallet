// Category pickers (P1): the ids a picker offers come from core's `CategoryTable.pickable`; subcategories sit indented under their
// parent. A category already chosen stays in the list even when it was hidden or removed since, so the field never loses its value.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

/// How far a subcategory is indented in a menu.
const double categoryIndent = 18;

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
  if (t.isHidden(id) || (t.parentOf(id) != null && t.isHidden(t.parentOf(id)!))) return '$base (hidden)';
  return base;
}

/// Menu items for a dropdown: [noneLabel] first when given (value null), then every offered category, a child indented under
/// its parent (key `pick:<id>`).
List<DropdownMenuItem<String?>> categoryMenuItems(CategoryTable t,
    {Set<BudgetKind>? kinds, String? current, String? noneLabel, Iterable<String> except = const []}) {
  return [
    if (noneLabel != null) DropdownMenuItem<String?>(value: null, child: Text(noneLabel)),
    for (final id in pickerIds(t, kinds: kinds, current: current, except: except))
      DropdownMenuItem<String?>(
        value: id,
        child: Padding(
          key: ValueKey('pick:$id'),
          padding: EdgeInsets.only(left: t.parentOf(id) == null ? 0 : categoryIndent),
          child: Text(pickerLabel(t, id), overflow: TextOverflow.ellipsis),
        ),
      ),
  ];
}

/// [categoryMenuItems] for a field that always has a value (no "none" entry).
List<DropdownMenuItem<String>> categoryValueItems(CategoryTable t, {Set<BudgetKind>? kinds, required String current}) => [
      for (final i in categoryMenuItems(t, kinds: kinds, current: current)) DropdownMenuItem<String>(value: i.value!, child: i.child),
    ];

/// Choice chips for the add-expense sheet: a main category, then its subcategories marked "↳" (key `cat:<id>`).
List<Widget> categoryChips(CategoryTable t,
    {required Set<BudgetKind> kinds, required String? selected, required ValueChanged<String> onPick, Iterable<String> except = const []}) {
  return [
    for (final id in pickerIds(t, kinds: kinds, current: selected, except: except))
      ChoiceChip(
        key: ValueKey('cat:$id'),
        label: Text(t.parentOf(id) == null ? pickerLabel(t, id) : '↳ ${pickerLabel(t, id)}'),
        tooltip: t.parentOf(id) == null ? null : '${t.label(id)}, in ${t.label(t.parentOf(id)!)}',
        selected: id == selected,
        onSelected: (_) => onPick(id),
      ),
  ];
}
