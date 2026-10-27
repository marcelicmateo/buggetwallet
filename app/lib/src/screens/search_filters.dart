// The filter chips under the search field (Q7): Amount, Date, Category, Has attachment, Split, Uncategorised. A chip shows its value and
// clears with its X; Amount, Date and Category open a small sheet. The filter itself is core's `SearchFilter`; the narrowing is core's.
//
// Privacy: logs carry how many kinds of filter are on, never an amount, a date or a tag.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../widgets/charts.dart' show RangePicker;
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'rules_panel.dart' show rangeText;

/// [f] with some parts replaced. A record wraps a value that may be set back to null.
SearchFilter editFilter(SearchFilter f,
    {({int? min, int? max})? amount,
    ({String? from, String? to})? dates,
    Set<String>? categories,
    ({bool? v})? attachment,
    ({bool? v})? split,
    bool? uncategorised}) {
  return SearchFilter(
    minCents: amount != null ? amount.min : f.minCents,
    maxCents: amount != null ? amount.max : f.maxCents,
    from: dates != null ? dates.from : f.from,
    to: dates != null ? dates.to : f.to,
    categories: categories ?? f.categories,
    hasAttachment: attachment != null ? attachment.v : f.hasAttachment,
    split: split != null ? split.v : f.split,
    uncategorised: uncategorised ?? f.uncategorised,
  );
}

/// How many kinds of filter are on (for logs).
int filterKinds(SearchFilter f) => [
      f.minCents != null || f.maxCents != null,
      f.from != null || f.to != null,
      f.categories.isNotEmpty,
      f.hasAttachment != null,
      f.split != null,
      f.uncategorised
    ].where((b) => b).length;

/// The chip row. On a phone it scrolls sideways (one line, so the results keep the room); on wider windows it wraps.
class SearchFilterBar extends StatelessWidget {
  final WalletController wc;
  final SearchFilter filter;
  final ValueChanged<SearchFilter> onChanged;
  final RangePicker picker;
  const SearchFilterBar({super.key, required this.wc, required this.filter, required this.onChanged, required this.picker});

  void _set(SearchFilter f) {
    logNav('search.filter', {'kinds': filterKinds(f)});
    onChanged(f);
  }

  Future<void> _amount(BuildContext context) async {
    final r =
        await showSheet<({int? min, int? max})>(context, _AmountSheet(min: filter.minCents, max: filter.maxCents, currency: wc.currency));
    if (r != null) _set(editFilter(filter, amount: r));
  }

  Future<void> _dates(BuildContext context) async {
    final now = wc.now;
    final first = DateTime(now.year - 6, 1, 1), last = DateTime(now.year, now.month + 1, 0);
    DateTime clamp(String? iso, DateTime or) {
      final d = iso == null ? or : (DateTime.tryParse(iso) ?? or);
      return d.isBefore(first) ? first : (d.isAfter(last) ? last : d);
    }

    final initial = DateTimeRange(start: clamp(filter.from, DateTime(now.year, now.month, 1)), end: clamp(filter.to, now));
    final r = await picker(context, initial, first, last);
    if (r != null) _set(editFilter(filter, dates: (from: isoDate(r.start), to: isoDate(r.end))));
  }

  Future<void> _categories(BuildContext context) async {
    final r = await showSheet<Set<String>>(context, _CategorySheet(table: wc.categoryTable, selected: filter.categories));
    if (r != null) _set(editFilter(filter, categories: r));
  }

  String get _amountLabel =>
      filter.minCents == null && filter.maxCents == null ? 'Amount' : rangeText(filter.minCents, filter.maxCents, wc.currency);

  String get _dateLabel {
    final a = filter.from, b = filter.to;
    if (a == null && b == null) return 'Date';
    if (a != null && b != null) return '${shortDateOrRaw(a)} – ${shortDateOrRaw(b)}';
    return a != null ? 'From ${shortDateOrRaw(a)}' : 'Until ${shortDateOrRaw(b!)}';
  }

  String get _categoryLabel {
    final n = filter.categories.length;
    if (n == 0) return 'Category';
    return n == 1 ? wc.categoryTable.label(filter.categories.first) : '$n categories';
  }

  Widget _chip(BuildContext context, String key, String label, bool on, VoidCallback onTap, {VoidCallback? onClear}) {
    // InputChip keeps its plain label style when selected (only ChoiceChip swaps it): on the accent fill the label takes the on-accent ink.
    final onAccent = Theme.of(context).colorScheme.onPrimary;
    return InputChip(
      key: ValueKey(key),
      label: Text(label),
      labelStyle: on ? TextStyle(color: onAccent, fontWeight: FontWeight.w600) : null,
      selected: on,
      showCheckmark: onClear == null,
      onPressed: onTap,
      onDeleted: on && onClear != null ? onClear : null,
      deleteIcon: const Icon(Icons.close, size: 18),
      deleteIconColor: onAccent,
      deleteButtonTooltipMessage: 'Clear $label',
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = filter;
    final chips = <Widget>[
      _chip(context, 'filterAmount', _amountLabel, f.minCents != null || f.maxCents != null, () => _amount(context),
          onClear: () => _set(editFilter(f, amount: (min: null, max: null)))),
      _chip(context, 'filterDate', _dateLabel, f.from != null || f.to != null, () => _dates(context),
          onClear: () => _set(editFilter(f, dates: (from: null, to: null)))),
      _chip(context, 'filterCategory', _categoryLabel, f.categories.isNotEmpty, () => _categories(context),
          onClear: () => _set(editFilter(f, categories: const {}))),
      _chip(context, 'filterAttachment', 'Has attachment', f.hasAttachment == true,
          () => _set(editFilter(f, attachment: (v: f.hasAttachment == true ? null : true)))),
      _chip(context, 'filterSplit', 'Split', f.split == true, () => _set(editFilter(f, split: (v: f.split == true ? null : true)))),
      _chip(context, 'filterUncategorised', 'Uncategorised', f.uncategorised, () => _set(editFilter(f, uncategorised: !f.uncategorised))),
    ];
    if (layoutOf(context) == LayoutSize.compact) {
      return SingleChildScrollView(
        key: const ValueKey('filterBar'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: pagePad),
        child: Row(children: [for (final c in chips) Padding(padding: const EdgeInsets.only(right: 8), child: c)]),
      );
    }
    return Padding(
      key: const ValueKey('filterBar'),
      padding: const EdgeInsets.symmetric(horizontal: pagePad),
      child: Wrap(spacing: 8, runSpacing: 4, children: chips),
    );
  }
}

/// Smallest and largest amount, both optional. Pops `(min:, max:)`; blank fields clear the chip.
class _AmountSheet extends StatefulWidget {
  final int? min, max;
  final String currency;
  const _AmountSheet({required this.min, required this.max, required this.currency});
  @override
  State<_AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<_AmountSheet> {
  late final _min = TextEditingController(text: widget.min == null ? '' : centsToFieldText(widget.min!));
  late final _max = TextEditingController(text: widget.max == null ? '' : centsToFieldText(widget.max!));
  String? _error;

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _apply() {
    int? read(TextEditingController c) => c.text.trim().isEmpty ? null : parseMoney(c.text);
    final lo = read(_min), hi = read(_max);
    if ((_min.text.trim().isNotEmpty && lo == null) || (_max.text.trim().isNotEmpty && hi == null)) {
      setState(() => _error = invalidAmountMessage);
      return;
    }
    if (lo != null && hi != null && lo > hi) {
      setState(() => _error = 'The smallest amount is above the largest.');
      return;
    }
    Navigator.pop(context, (min: lo, max: hi));
  }

  @override
  Widget build(BuildContext context) {
    final sym = currencySymbol(widget.currency);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Amount'),
      const SizedBox(height: 4),
      const Muted('Payments from this much to this much, whatever their sign.'),
      const SizedBox(height: 12),
      MoneyField(
          controller: _min,
          fieldKey: const ValueKey('filterMin'),
          autofocus: true,
          decoration: InputDecoration(labelText: 'From', suffixText: sym, hintText: amountHint)),
      const SizedBox(height: 12),
      MoneyField(
          controller: _max,
          fieldKey: const ValueKey('filterMax'),
          decoration: InputDecoration(labelText: 'Up to', suffixText: sym, hintText: amountHint)),
      if (_error != null) ...[const SizedBox(height: 8), StatusLabel(good: false, text: _error!)],
      const SizedBox(height: 14),
      FilledButton(key: const ValueKey('filterAmountApply'), onPressed: _apply, child: const Text('Apply')),
    ]);
  }
}

/// Main tags to keep in the results. Pops the chosen set (empty = no filter).
class _CategorySheet extends StatefulWidget {
  final CategoryTable table;
  final Set<String> selected;
  const _CategorySheet({required this.table, required this.selected});
  @override
  State<_CategorySheet> createState() => _CategorySheetState();
}

class _CategorySheetState extends State<_CategorySheet> {
  late final Set<String> _on = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final ids = [
      for (final id in widget.table.pickable())
        if (id.isNotEmpty) id
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Category'),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final id in ids)
          FilterChip(
            key: ValueKey('filterCat:$id'),
            label: Text(widget.table.label(id)),
            labelStyle: _on.contains(id) ? TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontWeight: FontWeight.w600) : null,
            selected: _on.contains(id),
            onSelected: (v) => setState(() => v ? _on.add(id) : _on.remove(id)),
          ),
      ]),
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('filterCategoryApply'), onPressed: () => Navigator.pop(context, {..._on}), child: const Text('Apply')),
    ]);
  }
}
