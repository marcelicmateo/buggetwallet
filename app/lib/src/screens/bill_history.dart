import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'bill_sheet.dart';
import 'recurring_sheet.dart';

/// Opens the History of the confirmed recurring bill [billId]: a page on a phone, a dialog from [dialogMin] wide.
Future<void> openBillHistory(BuildContext context, WalletController wc, String billId) {
  logNav('bill.history', {'months': wc.billHistoryFor(billId)?.months.length ?? 0});
  return openPageOrDialog<void>(context, BillHistoryScreen(wc: wc, billId: billId), width: 560, logName: 'BillHistoryScreen');
}

/// The plain words for a month's state.
String billMonthStateText(BillMonth m) => switch (m.state) {
      BillMonthState.paid => 'Paid',
      BillMonthState.slipOnly =>
        m.slips.isNotEmpty && m.slips.every((s) => s.linkedTx != null) ? 'Bill paid (not from the bank)' : 'Bill only, not paid yet',
      BillMonthState.missing => 'Missing (no payment or bill found)',
      BillMonthState.upcoming => 'Coming up',
      BillMonthState.paidNearby => 'Paid in ${m.paidIn == null ? 'another month' : monthLong(m.paidIn!)}',
    };

/// A slip the owner has not confirmed, or one a reader was unsure about: its amount carries "(to check)".
bool slipToCheck(Bill s) => s.status == BillStatus.review || s.unsure > 0;

const _toCheck = ' (to check)';

/// One line per month of a recurring bill, newest first: the month, a state word and the exact amounts. A month with rows opens
/// to its payments (the transaction sheet) and its bills (the bill sheet). An amount is shown only when it is stored: never guessed.
class BillHistoryScreen extends StatefulWidget {
  final WalletController wc;
  final String billId;
  const BillHistoryScreen({super.key, required this.wc, required this.billId});
  @override
  State<BillHistoryScreen> createState() => _BillHistoryScreenState();
}

class _BillHistoryScreenState extends State<BillHistoryScreen> {
  final _open = <String>{};

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.wc,
      builder: (context, _) {
        final wc = widget.wc;
        final h = wc.billHistoryFor(widget.billId);
        final name = h == null ? 'History' : (h.bill.label.isNotEmpty ? h.bill.label : h.bill.payee);
        return Scaffold(
          appBar: const DialogAppBar(title: 'History'),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
            children: h == null
                ? const [EmptyNote('This bill is not in your list any more.')]
                : [
                    Heading(name, size: BwType.headingSize),
                    const SizedBox(height: 4),
                    Muted(h.months.any((m) => m.due != null)
                        ? 'Payments and bills of this payee, one payment due date at a time. Parts of a payment are listed under it. Only what is stored shows.'
                        : 'Payments and bills of this payee, a month at a time. A month shows only what is stored.'),
                    const SizedBox(height: 8),
                    Rows(children: [for (final m in h.months) _month(context, wc, h, m)]),
                  ],
          ),
        );
      });

  /// The line's id: its due date for a bill that is not monthly (a weekly bill has several in one month), else its month.
  static String _id(BillMonth m) => m.due ?? m.month;

  Widget _month(BuildContext context, WalletController wc, BillHistoryView h, BillMonth m) {
    final c = context.c;
    final cur = wc.currency;
    final expandable = m.payments.isNotEmpty || m.slips.isNotEmpty;
    final open = expandable && _open.contains(_id(m));
    // A bill that is not monthly has a line per payment due date; the parts of one are listed when it is opened.
    final due = m.due;
    final title = due == null ? monthLong(m.month) : 'Due ${longDateOrRaw(due)}';
    final inParts = due != null && m.payments.length > 1;
    final unfinished = due != null && m.payments.isNotEmpty && m.state != BillMonthState.paid;
    final (icon, color) = switch (m.state) {
      BillMonthState.paid => (Icons.check_circle_outline, c.good),
      BillMonthState.slipOnly => (
          m.slips.every((s) => s.linkedTx != null) ? Icons.check_circle_outline : Icons.receipt_long_outlined,
          c.ink2
        ),
      BillMonthState.missing => (Icons.error_outline, c.bad),
      BillMonthState.upcoming => (Icons.schedule, c.ink2),
      BillMonthState.paidNearby => (Icons.check_circle_outline, c.ink2),
    };
    final stateText = billMonthStateText(m);
    final billed = m.billed;
    final check = m.slips.any(slipToCheck) ? _toCheck : '';
    final head = Container(
      constraints: const BoxConstraints(minHeight: touchMin),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(
          child: SplitRow(
            crossAxisAlignment: CrossAxisAlignment.start,
            start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.only(top: 1, right: 5), child: Icon(icon, size: 16, color: color)),
                Flexible(child: Text(stateText, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: BwType.metaSize))),
              ]),
              if (unfinished)
                Text(billPaidText(m.paid, h.bill.reserveAmount, cur),
                    key: ValueKey('historyParts_${_id(m)}'), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
            ]),
            end: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (m.payments.isNotEmpty)
                MoneyText(moneyExact(m.paid, cur), textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500)),
              if (billed != null)
                MoneyText('Bill ${moneyExact(billed, cur)}$check',
                    textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: BwType.metaSize, color: c.ink2)),
            ]),
          ),
        ),
        if (expandable) Icon(open ? Icons.expand_less : Icons.expand_more, color: c.ink2),
      ]),
    );
    final label = [
      title,
      stateText,
      if (unfinished) 'in parts',
      if (m.payments.isNotEmpty) 'paid ${moneyExact(m.paid, cur)}',
      if (billed != null) 'bill ${moneyExact(billed, cur)}$check',
    ].join(', ');
    return Column(key: ValueKey('historyMonth_${_id(m)}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (expandable)
        Semantics(
          label: label,
          button: true,
          expanded: open,
          excludeSemantics: true,
          onTap: () => setState(() => open ? _open.remove(_id(m)) : _open.add(_id(m))),
          child: InkWell(
            key: ValueKey('historyToggle_${_id(m)}'),
            hoverColor: c.surface2,
            focusColor: c.accentSoft,
            onTap: () => setState(() => open ? _open.remove(_id(m)) : _open.add(_id(m))),
            child: head,
          ),
        )
      else
        Semantics(container: true, label: label, excludeSemantics: true, child: head),
      if (open) ...[
        for (final p in m.payments)
          if (h.rows[p.id] case final t?) _paymentRow(context, wc, t, cur, part: inParts),
        for (final s in m.slips) _slipRow(context, wc, s, cur),
      ],
    ]);
  }

  Widget _paymentRow(BuildContext context, WalletController wc, CategorizedTx t, String cur, {bool part = false}) {
    final c = context.c;
    return InkWell(
      key: ValueKey('historyPayment_${t.tx.id}'),
      hoverColor: c.surface2,
      focusColor: c.accentSoft,
      onTap: () async {
        logNav('bill.history.openTx');
        final r = await showSheet<String>(context, TxSheet(wc: wc, t: t));
        if (context.mounted) txSheetToast(context, wc, r);
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: touchMin),
        padding: const EdgeInsets.only(left: 16, top: 6, bottom: 6),
        child: SplitRow(
          start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(part ? 'Part' : 'Payment', style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
            Text(shortDateOrRaw(t.date)),
          ]),
          end: MoneyText(moneyExact(-t.amount, cur), textAlign: TextAlign.end, style: numStyle),
        ),
      ),
    );
  }

  Widget _slipRow(BuildContext context, WalletController wc, Bill s, String cur) {
    final c = context.c;
    final date = s.date ?? s.dueDate;
    return InkWell(
      key: ValueKey('historySlip_${s.id}'),
      hoverColor: c.surface2,
      focusColor: c.accentSoft,
      onTap: () => openBill(context, wc, s.id),
      child: Container(
        constraints: const BoxConstraints(minHeight: touchMin),
        padding: const EdgeInsets.only(left: 16, top: 6, bottom: 6),
        child: SplitRow(
          start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Bill', style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
            if (date != null) Text(shortDateOrRaw(date)),
          ]),
          end: s.total == null
              ? Text('No total', textAlign: TextAlign.end, style: TextStyle(fontSize: BwType.metaSize, color: c.muted))
              : MoneyText('${moneyExact(s.total!, cur)}${slipToCheck(s) ? _toCheck : ''}', textAlign: TextAlign.end, style: numStyle),
        ),
      ),
    );
  }
}
