import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'planned_sheets.dart' show sourceLabel;
import 'upcoming_view.dart';

/// Opens Upcoming: a page on a phone, a dialog from [dialogMin] wide (like the weekly review).
Future<void> openUpcoming(BuildContext context, UpcomingView view) {
  return openPageOrDialog<void>(context, UpcomingScreen(view: view), width: 600, maxHeight: 800, logName: 'UpcomingScreen');
}

/// The pay period (and the next one) as a month grid with a mark per day, then a ruled list of what is coming: planned costs,
/// bills, and calendar events that have no amount yet ("Suggested 80 €": Confirm / Change / No cost). A suggestion never counts
/// until it is confirmed.
class UpcomingScreen extends StatefulWidget {
  final UpcomingView view;
  const UpcomingScreen({super.key, required this.view});
  @override
  State<UpcomingScreen> createState() => _UpcomingScreenState();
}

class _UpcomingScreenState extends State<UpcomingScreen> {
  bool _next = false;
  String? _day;

  Future<void> _add() async {
    logNav('planned.add');
    final r = await widget.view.showAddForm(context, date: _day);
    if (r == 'saved' && mounted) toast(context, 'Planned cost added');
  }

  Future<void> _open(UpcomingItem i) async {
    final bill = i.billDb;
    if (bill != null) {
      logNav('bill.openFromUpcoming');
      await widget.view.showBill(context, bill.id);
      return;
    }
    final p = i.planned;
    if (p == null) return;
    if (p.isBill) {
      // A bill's planned row is the bill: Paid, Skip and Delete belong to the bill sheet.
      logNav('bill.openFromUpcoming');
      await widget.view.showBill(context, p.sourceRef!);
      return;
    }
    logNav('planned.open');
    final r = await widget.view.showEntry(context, p);
    if (!mounted) return;
    final msg = switch (r) {
      'saved' => 'Saved',
      'paid' => 'Marked paid',
      'skipped' => 'Skipped',
      'deleted' => 'Deleted',
      _ => null,
    };
    if (msg == null) return;
    if (r == 'paid' || r == 'skipped') {
      toast(context, msg, actionLabel: 'Undo', onAction: () {
        logNav('planned.undo');
        widget.view.reopenPlanned(p);
      });
    } else {
      toast(context, msg);
    }
  }

  Future<void> _change(UpcomingItem i) async {
    logNav('planned.change');
    final r = await widget.view.showSuggestionForm(context, i);
    if (r == 'saved' && mounted) toast(context, 'Added to your plan');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.view,
      builder: (context, _) {
        final view = widget.view;
        final cur = view.currency;
        final range = view.upcomingRange(next: _next);
        final items = view.upcomingItems(range.start, range.end);
        final shown = _day == null
            ? items
            : [
                for (final i in items)
                  if (i.date == _day) i
              ];
        final counted = view.countedIn(items);
        final today = view.today();
        return Scaffold(
          appBar: DialogAppBar(
            title: 'Upcoming',
            actions: [
              IconButton(key: const ValueKey('addPlannedTop'), icon: const Icon(Icons.add), tooltip: 'Add planned cost', onPressed: _add),
            ],
          ),
          body: ListView(
              padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
              children: gapped([
                HeadingRow(
                  Heading(dateRange(range.start, addDays(range.end, 1)), size: BwType.headingSize),
                  Wrap(spacing: 6, children: [
                    ChoiceChip(
                        key: const ValueKey('periodNow'),
                        label: const Text('This period'),
                        selected: !_next,
                        onSelected: (_) => setState(() {
                              _next = false;
                              _day = null;
                            })),
                    ChoiceChip(
                        key: const ValueKey('periodNext'),
                        label: const Text('Next period'),
                        selected: _next,
                        onSelected: (_) => setState(() {
                              _next = true;
                              _day = null;
                            })),
                  ]),
                ),
                _PeriodGrid(
                  start: range.start,
                  end: range.end,
                  today: today,
                  items: items,
                  selected: _day,
                  onDay: (d) {
                    logNav('upcoming.day');
                    setState(() => _day = _day == d ? null : d);
                  },
                ),
                const _Legend(),
                Panel(children: [
                  HeadingRow(
                    Heading(_day == null ? 'Coming up' : longDateOrRaw(_day!), size: BwType.headingSize),
                    Wrap(spacing: 6, children: [
                      if (_day != null)
                        TextButton(
                            key: const ValueKey('showAll'), onPressed: () => setState(() => _day = null), child: const Text('Show all')),
                      OutlinedButton.icon(
                          key: const ValueKey('addPlanned'),
                          style: accentOutlined(context),
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Planned cost'),
                          onPressed: _add),
                    ]),
                  ),
                  if (shown.isEmpty)
                    EmptyNote(_day == null
                        ? 'Nothing planned in this period. Add a planned cost, or connect a calendar in Settings.'
                        : 'Nothing on this day.')
                  else
                    Rows(children: [
                      for (final i in shown) _UpcomingRow(view: view, item: i, today: today, onOpen: _open, onChange: _change)
                    ]),
                  if (_day == null && counted.count > 0)
                    TotalRule(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: SplitRow(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('Set aside', style: TextStyle(fontWeight: FontWeight.w600)),
                          Text('${counted.count} ${counted.count == 1 ? 'cost' : 'costs'} from today',
                              style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                        ]),
                        end: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(moneyExact(counted.total, cur), style: numStyle.copyWith(fontWeight: FontWeight.w600))),
                      ),
                    ),
                ]),
              ])),
        );
      });
}

class _Legend extends StatelessWidget {
  const _Legend();
  @override
  Widget build(BuildContext context) => Wrap(spacing: 14, runSpacing: 4, children: [
        for (final (kind, label) in const [
          (_Mark.planned, 'Planned'),
          (_Mark.bill, 'Bill'),
          (_Mark.suggestion, 'Suggested'),
          (_Mark.warranty, 'Warranty'),
          (_Mark.returnBy, 'Return by'),
        ])
          Row(mainAxisSize: MainAxisSize.min, children: [
            _MarkBox(kind),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
          ]),
      ]);
}

enum _Mark { planned, bill, suggestion, warranty, returnBy }

class _MarkBox extends StatelessWidget {
  final _Mark kind;
  const _MarkBox(this.kind);
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: switch (kind) {
          _Mark.planned => c.accent,
          _Mark.bill || _Mark.returnBy => c.ink2,
          _Mark.suggestion || _Mark.warranty => null
        },
        // Warranty and return-by are round (hollow and filled), the rest square: the shape tells them apart without colour.
        shape: kind == _Mark.warranty || kind == _Mark.returnBy ? BoxShape.circle : BoxShape.rectangle,
        border: Border.all(color: kind == _Mark.planned ? c.accent : c.ink2, width: 1.5),
      ),
    );
  }
}

const _weekdayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

/// The days from [start] to [end] (inclusive) as month grids, Monday first; a pay period that crosses a month gets two. A mark
/// per kind on each day that has something; tap a day to list just that day.
class _PeriodGrid extends StatelessWidget {
  final String start, end, today;
  final List<UpcomingItem> items;
  final String? selected;
  final ValueChanged<String> onDay;
  const _PeriodGrid({required this.start, required this.end, required this.today, required this.items, this.selected, required this.onDay});

  @override
  Widget build(BuildContext context) {
    final byDay = <String, List<UpcomingItem>>{};
    for (final i in items) {
      byDay.putIfAbsent(i.date, () => []).add(i);
    }
    final months = <String>[];
    for (var d = start; d.compareTo(end) <= 0; d = addDays(d, 1)) {
      final m = monthOf(d);
      if (months.isEmpty || months.last != m) months.add(m);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final m in months) ...[
        Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(monthLong(m), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: BwType.bodySize))),
        _MonthGrid(month: m, start: start, end: end, today: today, byDay: byDay, selected: selected, onDay: onDay),
      ],
    ]);
  }
}

class _MonthGrid extends StatelessWidget {
  final String month, start, end, today;
  final Map<String, List<UpcomingItem>> byDay;
  final String? selected;
  final ValueChanged<String> onDay;
  const _MonthGrid(
      {required this.month,
      required this.start,
      required this.end,
      required this.today,
      required this.byDay,
      required this.selected,
      required this.onDay});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final first = start.compareTo('$month-01') > 0 ? start : '$month-01';
    var last = '$month-31';
    while (monthOf(last) != month) {
      last = addDays(last, -1);
    }
    if (end.compareTo(last) < 0) last = end;
    final lead = parseIso(first).weekday - 1;
    final days = <String?>[
      for (var i = 0; i < lead; i++) null,
      for (var d = first; d.compareTo(last) <= 0; d = addDays(d, 1)) d,
    ];
    while (days.length % 7 != 0) {
      days.add(null);
    }
    return Column(children: [
      Row(children: [
        for (final l in _weekdayLetters)
          Expanded(child: Center(child: Text(l, style: TextStyle(fontSize: BwType.metaSize, color: c.muted)))),
      ]),
      for (var w = 0; w < days.length; w += 7)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final d in days.sublist(w, w + 7))
              Expanded(
                  child: d == null
                      ? const SizedBox.shrink()
                      : _DayCell(date: d, today: today, items: byDay[d] ?? const [], selected: selected == d, onTap: onDay)),
          ]),
        ),
    ]);
  }
}

class _DayCell extends StatelessWidget {
  final String date, today;
  final List<UpcomingItem> items;
  final bool selected;
  final ValueChanged<String> onTap;
  const _DayCell({required this.date, required this.today, required this.items, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final isToday = date == today;
    final kinds = <_Mark>{
      for (final i in items)
        switch (i.kind) {
          UpcomingKind.planned => _Mark.planned,
          UpcomingKind.bill => _Mark.bill,
          UpcomingKind.suggestion => _Mark.suggestion,
          UpcomingKind.warranty => _Mark.warranty,
          UpcomingKind.returnBy => _Mark.returnBy,
        },
    };
    final n = items.length;
    return Semantics(
      button: true,
      selected: selected,
      label: '${longDate(date)}${isToday ? ', today' : ''}${n == 0 ? '' : ', $n ${n == 1 ? 'item' : 'items'}'}',
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('day:$date'),
        onTap: () => onTap(date),
        child: Container(
          constraints: const BoxConstraints(minHeight: touchMin),
          margin: const EdgeInsets.all(1),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: isToday ? c.accentSoft : null,
            border: n == 0 && !selected ? null : Border.all(color: selected ? c.accent : c.line, width: selected ? 2 : 1),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('${dayOf(date)}',
                style: numStyle.copyWith(fontSize: BwType.metaSize, fontWeight: isToday ? FontWeight.w600 : FontWeight.w400)),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 10),
              child: kinds.isEmpty
                  ? null
                  : Wrap(alignment: WrapAlignment.center, spacing: 3, runSpacing: 2, children: [
                      for (final k in _Mark.values)
                        if (kinds.contains(k)) _MarkBox(k),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _UpcomingRow extends StatelessWidget {
  final UpcomingView view;
  final UpcomingItem item;
  final String today;
  final Future<void> Function(UpcomingItem) onOpen;
  final Future<void> Function(UpcomingItem) onChange;
  const _UpcomingRow({required this.view, required this.item, required this.today, required this.onOpen, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cur = view.currency;
    final i = item;
    final isSuggestion = i.kind == UpcomingKind.suggestion;
    final isBillDate = i.kind == UpcomingKind.warranty || i.kind == UpcomingKind.returnBy;
    final past = i.date.compareTo(today) < 0;
    final sub = Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(shortDateOrRaw(i.date), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
      Tag(sourceLabel(i)),
      if (past && !isSuggestion) Text('past', style: TextStyle(fontSize: BwType.metaSize, color: c.muted)),
      if ((i.planned?.coveredByPlanIn(view.categoryTable) ?? false) || (i.bill?.coveredByPlanIn(view.categoryTable) ?? false))
        Text('covered by your plan', style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
      if (i.planned?.needsCategory ?? false) StatusLabel(key: ValueKey('needsCategory:${i.key}'), good: false, text: 'Needs a category'),
    ]);
    final title =
        Text(i.title.isEmpty ? (isBillDate ? 'Bill' : 'Planned cost') : i.title, style: const TextStyle(fontWeight: FontWeight.w500));
    final head = isSuggestion || isBillDate
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 2), sub])
        : SplitRow(
            crossAxisAlignment: CrossAxisAlignment.start,
            start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 2), sub]),
            end: i.amount == null
                ? Text('No amount', textAlign: TextAlign.end, style: TextStyle(fontSize: BwType.metaSize, color: c.muted))
                : Text(moneyExact(i.amount!, cur), textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500)),
          );
    return InkWell(
      key: ValueKey('up:${i.key}'),
      onTap: i.planned == null && !isBillDate ? null : () => onOpen(i),
      child: Container(
        constraints: const BoxConstraints(minHeight: touchMin),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          head,
          if (isSuggestion) ...[
            const SizedBox(height: 4),
            Text((i.suggested ?? 0) <= 0 ? 'No amount found' : 'Suggested ${moneyExact(i.suggested!, cur)}',
                style: numStyle.copyWith(fontSize: BwType.bodySize, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Wrap(spacing: 8, runSpacing: 4, children: [
              if ((i.suggested ?? 0) > 0)
                FilledButton(
                    key: ValueKey('confirm:${i.key}'),
                    onPressed: () {
                      logNav('suggestion.confirm');
                      view.confirmSuggestion(i, amount: i.suggested!, category: i.category);
                      toast(context, 'Added to your plan');
                    },
                    child: const Text('Confirm')),
              OutlinedButton(
                  key: ValueKey('change:${i.key}'),
                  onPressed: () => onChange(i),
                  child: Text((i.suggested ?? 0) > 0 ? 'Change' : 'Add amount')),
              TextButton(
                  key: ValueKey('nocost:${i.key}'),
                  onPressed: () {
                    logNav('suggestion.dismiss');
                    view.dismissSuggestion(i);
                    toast(context, "Won't suggest it again");
                  },
                  child: const Text('No cost')),
            ]),
          ],
        ]),
      ),
    );
  }
}
