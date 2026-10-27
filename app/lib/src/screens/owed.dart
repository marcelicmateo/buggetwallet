import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// The text of a refused value: core's owner-readable [ArgumentError] message.
String _problem(Object e) => e is ArgumentError ? e.message.toString() : 'Could not save. Try again.';

/// Save tab › Owed (Q8): what people owe you and what you owe, one line per open IOU, and **Add**. A tap opens the IOU sheet.
class OwedPanel extends StatefulWidget {
  final WalletController wc;
  const OwedPanel({super.key, required this.wc});
  @override
  State<OwedPanel> createState() => _OwedPanelState();
}

class _OwedPanelState extends State<OwedPanel> {
  bool showClosed = false;

  Future<void> _open(String? id) async {
    logNav(id == null ? 'iou.add' : 'iou.open');
    final r = await showSheet<String>(context, IouSheet(wc: widget.wc, iouId: id));
    if (!mounted || r == null || !r.startsWith('deleted:')) return;
    final gone = r.substring(8);
    toast(context, 'IOU deleted', actionLabel: 'Undo', onAction: () {
      try {
        widget.wc.undeleteIou(gone);
      } on ArgumentError catch (e) {
        logNav('iou.undoFailed');
        if (mounted) toast(context, _problem(e));
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.wc, builder: (context, _) => _panel(context));

  Widget _panel(BuildContext context) {
    final wc = widget.wc;
    final c = context.c;
    final cur = wc.currency;
    final open = wc.iousOpen();
    final closed = [
      for (final v in wc.iousAll())
        if (v.iou.closed) v
    ];
    final t = wc.owedTotals();
    // [named] false: the person's name is the group header above, so the line says what it is instead.
    Widget line(IouView v, {bool named = true}) {
      final i = v.iou;
      final lent = i.direction == IouDirection.lent;
      final state = i.closed ? 'settled' : (lent ? 'owes you' : 'you owe');
      final reps = v.parts.isEmpty ? '' : ' · ${v.parts.length} ${v.parts.length == 1 ? 'repayment' : 'repayments'}';
      return InkWell(
        key: ValueKey('iou:${i.id}'),
        onTap: () => _open(i.id),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: rowMin),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SplitRow(
              start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(named ? i.person : '${lent ? 'Lent' : 'Borrowed'} ${shortDateOrRaw(i.date)}',
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(named ? '$state · ${shortDateOrRaw(i.date)}$reps' : '$state$reps',
                    style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
              ]),
              end: Text(moneyExact(v.outstanding, i.currency),
                  textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500, color: lent ? c.good : c.bad)),
            ),
          ),
        ),
      );
    }

    // One line per IOU (each has its own date and repayments); a person with more than one is a group under their name.
    List<Widget> lines(List<IouView> vs) {
      final groups = <String, List<IouView>>{};
      for (final v in vs) {
        (groups[v.iou.person.trim().toLowerCase()] ??= []).add(v);
      }
      return [
        for (final e in groups.entries)
          if (e.value.length == 1)
            line(e.value.single)
          else
            Padding(
              key: ValueKey('owedPerson:${e.key}'),
              padding: const EdgeInsets.only(top: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(e.value.first.iou.person,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Padding(
                    padding: const EdgeInsets.only(left: 12), child: Column(children: [for (final v in e.value) line(v, named: false)])),
              ]),
            ),
      ];
    }

    return Panel(key: const ValueKey('owedPanel'), children: [
      SectionHead('Owed',
          trailing: TextButton.icon(
              key: const ValueKey('owedAdd'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              onPressed: () => _open(null))),
      if (open.isEmpty)
        const EmptyNote('Nothing owed. Add money you lent or borrowed to keep track of it.')
      else ...[
        // A total per currency, never added together: the wallet's own first, the others as "In USD: ...".
        for (final cc in t.currencies)
          Text(
              '${cc == cur ? '' : 'In $cc: '}People owe you ${moneyExact(t.owedToYou[cc] ?? 0, cc)} · You owe ${moneyExact(t.youOwe[cc] ?? 0, cc)}',
              key: ValueKey(cc == cur ? 'owedSummary' : 'owedSummary:$cc'),
              style: TextStyle(fontWeight: FontWeight.w600, color: cc == cur ? null : c.ink2)),
        Rows(children: lines(open)),
      ],
      if (closed.isNotEmpty) ...[
        TextButton(
            key: const ValueKey('owedShowClosed'),
            style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
            onPressed: () => setState(() => showClosed = !showClosed),
            child: Text(showClosed ? 'Hide settled' : 'Show settled (${closed.length})')),
        if (showClosed) Rows(children: lines(closed)),
      ],
    ]);
  }
}

/// One IOU (Q8): new (no [iouId]), from a payment ([tx], lent, the amount and date are the payment's), or an existing one with its
/// repayments, Close and Delete. Pops `'saved'`, `'lent'` (from a payment) or `'deleted:<id>'`.
class IouSheet extends StatefulWidget {
  final WalletController wc;
  final String? iouId;

  /// The expense that was the loan: the IOU links to it and takes its exact amount, currency and date.
  final Tx? tx;
  const IouSheet({super.key, required this.wc, this.iouId, this.tx});
  @override
  State<IouSheet> createState() => _IouSheetState();
}

class _IouSheetState extends State<IouSheet> {
  late final IouView? view = widget.iouId == null ? null : widget.wc.iouById(widget.iouId!);
  late final _person = TextEditingController(text: view?.iou.person ?? '');
  late final _amount = TextEditingController(
      text: view != null
          ? centsToFieldText(view!.iou.amount)
          : widget.tx != null
              ? centsToFieldText(widget.tx!.amount.abs())
              : '');
  late final _note = TextEditingController(text: view?.iou.note ?? '');
  final _part = TextEditingController();
  late IouDirection _direction = view?.iou.direction ?? IouDirection.lent;
  late String _date = view?.iou.date ?? widget.tx?.date ?? widget.wc.today();
  String? _error, _partError;
  String? _removedPart;

  @override
  void dispose() {
    _person.dispose();
    _amount.dispose();
    _note.dispose();
    _part.dispose();
    super.dispose();
  }

  void _save() {
    final cents = parseMoney(_amount.text);
    if (cents == null) {
      setState(() => _error = invalidAmountMessage);
      return;
    }
    try {
      final wc = widget.wc;
      if (widget.iouId == null) {
        wc.addIou(
            person: _person.text,
            direction: _direction,
            amount: cents,
            date: _date,
            note: _note.text,
            tx: widget.tx?.id,
            currency: widget.tx?.currency);
        Navigator.pop(context, widget.tx != null ? 'lent' : 'saved');
      } else {
        wc.updateIou(widget.iouId!,
            person: _person.text,
            direction: _direction,
            amount: cents,
            date: _date,
            note: _note.text,
            clearNote: _note.text.trim().isEmpty);
        Navigator.pop(context, 'saved');
      }
    } on ArgumentError catch (e) {
      setState(() => _error = _problem(e));
    }
  }

  void _addPart() {
    final cents = parseMoney(_part.text);
    if (cents == null) {
      setState(() => _partError = invalidAmountMessage);
      return;
    }
    try {
      widget.wc.addIouPart(widget.iouId!, amount: cents, date: widget.wc.today());
      _part.clear();
      setState(() {
        _partError = null;
        _removedPart = null;
      });
    } on ArgumentError catch (e) {
      setState(() => _partError = _problem(e));
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
        context: context, initialDate: parseIso(_date), firstDate: DateTime(2000), lastDate: DateTime(widget.wc.now.year + 1, 12, 31));
    if (d != null) setState(() => _date = isoDate(d));
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final cur = widget.tx?.currency ?? view?.iou.currency ?? wc.currency;
    return ListenableBuilder(
      listenable: wc,
      builder: (context, _) {
        final v = widget.iouId == null ? null : wc.iouById(widget.iouId!);
        return Column(key: const ValueKey('iouSheet'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Heading(widget.tx != null
              ? 'Lent to someone'
              : v == null
                  ? 'New IOU'
                  : 'IOU'),
          const SizedBox(height: 12),
          TextField(
              key: const ValueKey('iouPerson'),
              controller: _person,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() => _error = null),
              decoration: const InputDecoration(labelText: 'Who')),
          const SizedBox(height: 10),
          if (widget.tx == null)
            Wrap(key: const ValueKey('iouDirection'), spacing: 8, runSpacing: 8, children: [
              for (final (d, label, icon) in [
                (IouDirection.lent, 'I lent', Icons.call_made),
                (IouDirection.borrowed, 'I borrowed', Icons.call_received),
              ])
                ChoiceChip(
                    key: ValueKey('iouDirection:${d.name}'),
                    avatar: Icon(icon, size: 16),
                    label: Text(label),
                    selected: _direction == d,
                    onSelected: (_) => setState(() => _direction = d)),
            ]),
          if (widget.tx == null) const SizedBox(height: 10),
          MoneyField(
              fieldKey: const ValueKey('iouAmount'),
              controller: _amount,
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(labelText: 'Amount', suffixText: currencySymbol(cur))),
          const SizedBox(height: 10),
          DateField(key: const ValueKey('iouDate'), label: 'Date', value: _date, onPick: widget.tx == null ? _pickDate : () {}),
          const SizedBox(height: 10),
          TextField(
              key: const ValueKey('iouNote'),
              controller: _note,
              onChanged: (_) => setState(() => _error = null),
              decoration: const InputDecoration(labelText: 'Note (optional)')),
          if (widget.tx != null) ...[
            const SizedBox(height: 8),
            const Muted('This payment is then not counted as spending. It is linked to this IOU.', key: ValueKey('iouLinkNote')),
          ],
          if (_error != null) ...[const SizedBox(height: 10), StatusLabel(key: const ValueKey('iouError'), good: false, text: _error!)],
          const SizedBox(height: 12),
          FilledButton(
              key: const ValueKey('iouSave'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
              onPressed: _save,
              child: Text(widget.iouId == null ? (widget.tx != null ? 'Mark as lent' : 'Add') : 'Save')),
          if (v != null) ..._repayments(context, v, cur),
        ]);
      },
    );
  }

  List<Widget> _repayments(BuildContext context, IouView v, String cur) {
    final c = context.c;
    final wc = widget.wc;
    final lent = v.iou.direction == IouDirection.lent;
    return [
      const SizedBox(height: 18),
      const SectionHead('Paid back'),
      const SizedBox(height: 6),
      Text('${moneyExact(v.repaid, cur)} of ${moneyExact(v.iou.amount, cur)} · ${moneyExact(v.outstanding, cur)} left',
          key: const ValueKey('iouProgress'), style: const TextStyle(fontWeight: FontWeight.w600)),
      for (final p in v.parts)
        Row(key: ValueKey('iouPart:${p.id}'), children: [
          Expanded(child: Text(shortDateOrRaw(p.date), style: TextStyle(color: c.ink2))),
          Text(moneyExact(p.amount, cur), style: numStyle.copyWith(fontWeight: FontWeight.w500)),
          IconButton(
              key: ValueKey('iouPartDelete:${p.id}'),
              tooltip: 'Remove repayment',
              constraints: const BoxConstraints(minWidth: touchMin, minHeight: touchMin),
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () {
                try {
                  wc.deleteIouPart(p.id);
                  setState(() {
                    _removedPart = p.id;
                    _partError = null;
                  });
                } on ArgumentError catch (e) {
                  setState(() => _partError = _problem(e));
                }
              }),
        ]),
      if (_removedPart != null)
        Row(key: const ValueKey('iouPartUndo'), children: [
          const Expanded(child: Muted('Repayment removed.')),
          TextButton(
              onPressed: () {
                try {
                  wc.undeleteIouPart(_removedPart!);
                  setState(() => _removedPart = null);
                } on ArgumentError catch (e) {
                  setState(() => _partError = _problem(e));
                }
              },
              child: const Text('Undo')),
        ]),
      if (!v.iou.closed) ...[
        const SizedBox(height: 8),
        MoneyField(
            fieldKey: const ValueKey('iouPartAmount'),
            controller: _part,
            onChanged: (_) => setState(() => _partError = null),
            decoration: InputDecoration(
                labelText: lent ? 'They paid back' : 'You paid back',
                suffixText: currencySymbol(cur),
                errorText: _partError,
                errorMaxLines: 3)),
        const SizedBox(height: 8),
        OutlinedButton(
            key: const ValueKey('iouAddPart'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: _addPart,
            child: const Text('Add repayment')),
      ] else if (_partError != null)
        StatusLabel(good: false, text: _partError!),
      const SizedBox(height: 14),
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [
        OutlinedButton(
            key: const ValueKey('iouClose'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, touchMin)),
            onPressed: () {
              try {
                wc.closeIou(v.iou.id, closed: !v.iou.closed);
                Navigator.pop(context, 'saved');
              } on ArgumentError catch (e) {
                setState(() => _error = _problem(e));
              }
            },
            child: Text(v.iou.closed ? 'Open again' : 'Close (settled)')),
        TextButton(
            key: const ValueKey('iouDelete'),
            style: TextButton.styleFrom(foregroundColor: c.bad, minimumSize: const Size(0, touchMin)),
            onPressed: () {
              try {
                wc.deleteIou(v.iou.id);
                Navigator.pop(context, 'deleted:${v.iou.id}');
              } on ArgumentError catch (e) {
                setState(() => _error = _problem(e));
              }
            },
            child: const Text('Delete')),
      ]),
    ];
  }
}

/// "Repayment" on an income (Q8): pick the open IOU this money paid back. The payment links to it as a repayment of exactly its amount.
/// Pops `'repaid'`.
class RepaymentSheet extends StatefulWidget {
  final WalletController wc;
  final Tx tx;
  const RepaymentSheet({super.key, required this.wc, required this.tx});
  @override
  State<RepaymentSheet> createState() => _RepaymentSheetState();
}

class _RepaymentSheetState extends State<RepaymentSheet> {
  String? _error;

  void _pick(IouView v) {
    try {
      widget.wc.addIouPart(v.iou.id, amount: widget.tx.amount, date: widget.tx.date, tx: widget.tx.id);
      Navigator.pop(context, 'repaid');
    } on ArgumentError catch (e) {
      setState(() => _error = _problem(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tx;
    final options = widget.wc.repayableBy(t.amount, t.currency);
    return Column(key: const ValueKey('repaymentSheet'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Repayment'),
      const SizedBox(height: 6),
      Muted('Which IOU did ${moneyExact(t.amount, t.currency)} pay back? The payment then is not counted as income.'),
      const SizedBox(height: 10),
      if (options.isEmpty)
        const EmptyNote('No open IOU is owed at least this much. Add one in Save › Owed first.', key: ValueKey('repayNone'))
      else
        Rows(children: [
          for (final v in options)
            InkWell(
              key: ValueKey('repayPick:${v.iou.id}'),
              onTap: () => _pick(v),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: rowMin),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: SplitRow(
                    start: Text(v.iou.person,
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    end: Text('${moneyExact(v.outstanding, v.iou.currency)} left', style: numStyle),
                  ),
                ),
              ),
            ),
        ]),
      if (_error != null) ...[const SizedBox(height: 10), StatusLabel(key: const ValueKey('repayError'), good: false, text: _error!)],
    ]);
  }
}
