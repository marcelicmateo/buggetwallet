import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// "Calendar", "Bill" or "Added": where a planned cost came from; "Warranty" and "Return by" for a bill's dates.
String sourceLabel(UpcomingItem i) => switch (i.kind) {
      UpcomingKind.bill => 'Bill',
      UpcomingKind.suggestion => 'Calendar',
      UpcomingKind.warranty => 'Warranty',
      UpcomingKind.returnBy => 'Return by',
      UpcomingKind.planned => switch (i.planned?.source) {
          PlannedSource.calendar => 'Calendar',
          PlannedSource.bill => 'Bill',
          _ => 'Added',
        },
    };

/// The "+ Planned cost" sheet. Also used to change an existing planned cost ([edit]) and to confirm a calendar suggestion with
/// another amount, title or date ([suggestion]). Pops `'saved'`.
class PlannedFormSheet extends StatefulWidget {
  final WalletController wc;
  final PlannedCost? edit;
  final UpcomingItem? suggestion;

  /// The date a new cost starts on (the day picked in the grid, else today).
  final String? date;
  const PlannedFormSheet({super.key, required this.wc, this.edit, this.suggestion, this.date});
  @override
  State<PlannedFormSheet> createState() => _PlannedFormSheetState();
}

class _PlannedFormSheetState extends State<PlannedFormSheet> {
  late final TextEditingController _title = TextEditingController(text: widget.edit?.title ?? widget.suggestion?.title ?? '');
  late final TextEditingController _amount = TextEditingController(text: _initialAmount());
  late String _date = widget.edit?.date ?? widget.suggestion?.date ?? widget.date ?? widget.wc.today();
  late String? _category = widget.edit?.category ?? widget.suggestion?.category;
  String? _error;

  String _initialAmount() {
    final a = widget.edit?.amount ?? widget.suggestion?.suggested;
    return a == null ? '' : (a / 100).toStringAsFixed(2);
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    final amount = parseMoney(_amount.text);
    if (title.isEmpty) {
      setState(() => _error = 'Give it a name, like "Car insurance".');
      return;
    }
    if (amount == null || amount <= 0) {
      setState(() => _error = invalidAmountMessage);
      return;
    }
    final wc = widget.wc;
    if (widget.edit != null) {
      wc.updatePlanned(widget.edit!.id, title: title, date: _date, amount: amount, category: _category, clearCategory: _category == null);
    } else if (widget.suggestion != null) {
      wc.confirmSuggestion(widget.suggestion!, amount: amount, title: title, date: _date, category: _category);
    } else {
      wc.addPlannedCost(title: title, date: _date, amount: amount, category: _category);
    }
    Navigator.pop(context, 'saved');
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.wc.currency;
    final editing = widget.edit != null;
    final today = widget.wc.today();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(editing ? 'Change planned cost' : 'Planned cost'),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('plannedTitle'),
        controller: _title,
        autofocus: !editing,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'What', hintText: 'Car insurance'),
      ),
      const SizedBox(height: 12),
      MoneyField(
        fieldKey: const ValueKey('plannedAmount'),
        controller: _amount,
        style: numStyle.copyWith(fontSize: 24, fontWeight: FontWeight.w500),
        decoration: InputDecoration(labelText: 'Amount', suffixText: currencySymbol(cur), hintText: '0.00'),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton.icon(
          key: const ValueKey('plannedDate'),
          icon: const Icon(Icons.event, size: 18),
          label: Text(longDateOrRaw(_date)),
          onPressed: () async {
            final d = await showDatePicker(
                context: context,
                initialDate: parseIso(_date),
                firstDate: parseIso(addDays(today, -60)),
                lastDate: parseIso(addDays(today, 730)));
            if (d != null) setState(() => _date = isoDate(d));
          },
        ),
      ]),
      const SizedBox(height: 12),
      DropdownButtonFormField<String?>(
        key: const ValueKey('plannedCategory'),
        isExpanded: true,
        initialValue: _category,
        decoration: const InputDecoration(labelText: 'Category', helperText: 'Used to find the payment later.'),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('No category')),
          for (final c in spendingCategories) DropdownMenuItem<String?>(value: c, child: Text(c)),
        ],
        onChanged: (v) => setState(() => _category = v),
      ),
      if (_error != null) ...[const SizedBox(height: 10), StatusLabel(good: false, text: _error!)],
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('plannedSave'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: Text(editing ? 'Save' : (widget.suggestion != null ? 'Add to my plan' : 'Add planned cost'))),
      const SizedBox(height: 8),
      const Muted('It is set aside from your daily money until it is paid or its day has passed.', size: 12.5),
    ]);
  }
}

/// One planned cost: Edit, Paid (pick the payment), Skip, Delete. Pops `'saved'`, `'paid'`, `'skipped'` or `'deleted'`.
class PlannedEntrySheet extends StatefulWidget {
  final WalletController wc;
  final PlannedCost planned;
  const PlannedEntrySheet({super.key, required this.wc, required this.planned});
  @override
  State<PlannedEntrySheet> createState() => _PlannedEntrySheetState();
}

class _PlannedEntrySheetState extends State<PlannedEntrySheet> {
  bool _paying = false;

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final p = widget.planned;
    final cur = wc.currency;
    final candidates = _paying ? wc.paidCandidatesFor(p) : const <CategorizedTx>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(p.title.isEmpty ? 'Planned cost' : p.title),
      const SizedBox(height: 6),
      Text(p.amount == null ? 'No amount yet' : moneyExact(p.amount!, cur),
          textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: 26, fontWeight: FontWeight.w500)),
      const SizedBox(height: 6),
      const DoubleRule(),
      const SizedBox(height: 6),
      Muted(
          '${longDateOrRaw(p.date)} · ${p.category ?? 'No category'} · ${p.source == PlannedSource.calendar ? 'From a calendar' : 'Added by you'}'),
      const SizedBox(height: 14),
      if (!_paying)
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
              key: const ValueKey('entryEdit'),
              onPressed: () async {
                logNav('planned.edit');
                final r = await showSheet<String>(context, PlannedFormSheet(wc: wc, edit: p));
                if (r == 'saved' && context.mounted) Navigator.pop(context, 'saved');
              },
              child: const Text('Change')),
          OutlinedButton(
              key: const ValueKey('entryPaid'),
              style: accentOutlined(context),
              onPressed: () {
                logNav('planned.paidOpen');
                setState(() => _paying = true);
              },
              child: const Text('Paid')),
          OutlinedButton(
              key: const ValueKey('entrySkip'),
              onPressed: () {
                logNav('planned.skip');
                wc.skipPlanned(p);
                Navigator.pop(context, 'skipped');
              },
              child: const Text('Skip')),
          TextButton(
              key: const ValueKey('entryDelete'),
              onPressed: () {
                logNav('planned.delete');
                wc.deletePlanned(p);
                Navigator.pop(context, 'deleted');
              },
              child: const Text('Delete')),
        ])
      else ...[
        const Heading('Which payment was it?', size: 15),
        const SizedBox(height: 4),
        if (candidates.isEmpty)
          const Muted('No matching payment yet. Import your bank file, then come back.', size: 13.5)
        else ...[
          const Muted('Payments in the same category within 3 days. Tap the one that paid it.'),
          Rows(children: [
            for (final t in candidates)
              InkWell(
                key: ValueKey('pay:${t.tx.id}'),
                onTap: () {
                  logNav('planned.paid');
                  wc.markPlannedPaid(p, t.tx);
                  Navigator.pop(context, 'paid');
                },
                child: Container(
                  constraints: const BoxConstraints(minHeight: touchMin),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: SplitRow(
                    start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(merchantName(t.tx), style: const TextStyle(fontWeight: FontWeight.w500)),
                      Text(shortDateOrRaw(t.date), style: TextStyle(fontSize: 12.5, color: context.c.ink2)),
                    ]),
                    end: Text(moneyExact(-t.amount, cur), textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500)),
                  ),
                ),
              ),
          ]),
        ],
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => setState(() => _paying = false), child: const Text('Back'))),
      ],
    ]);
  }
}
