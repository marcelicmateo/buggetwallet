import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'bill_history.dart';

const _dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Plan › Weekly review: the day of the week the review is due from, as a row of day chips.
class ReviewDayRow extends StatelessWidget {
  final WalletController wc;
  const ReviewDayRow({super.key, required this.wc});
  @override
  Widget build(BuildContext context) {
    final day = wc.reviewDay;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Review day', size: BwType.headingSize),
      const SizedBox(height: 4),
      Muted('Today shows the review from ${_dayNames[day - 1]} until you finish it.'),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (var i = 0; i < 7; i++)
          Semantics(
            label: _dayNames[i],
            excludeSemantics: true,
            selected: day == i + 1,
            child: ChoiceChip(
              key: ValueKey('reviewDay:${i + 1}'),
              label: Text(_dayNames[i].substring(0, 3)),
              selected: day == i + 1,
              onSelected: (_) => wc.setReviewDay(i + 1),
            ),
          ),
      ]),
    ]);
  }
}

/// Plan › Expected bills: bills found in the imports. Candidates come first (Confirm / Not a bill), then confirmed bills
/// (amount, next date, a "Paid" mark once the payment is in, Remove). Dismissed ones are not shown.
class ExpectedBillsPanel extends StatelessWidget {
  final WalletController wc;
  const ExpectedBillsPanel({super.key, required this.wc});

  static String _name(RecurringBill b) => b.label.isNotEmpty ? b.label : b.payee;

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency;
    final today = wc.today();
    final bills = wc.recurringBills();
    final candidates = bills.where((b) => b.status == 'candidate').toList();
    final confirmed = bills.where((b) => b.status == 'confirmed').toList();
    return Panel(children: [
      const SectionHead('Expected bills'),
      Explainer(wc, 'expectedBills',
          'Found in your imports. A confirmed bill is set aside from your daily money until it is paid. Rent, loan and bills in your plan are already counted.'),
      if (candidates.isEmpty && confirmed.isEmpty)
        const EmptyNote('No repeating bills found yet. They show up after a few months of imports.'),
      if (candidates.isNotEmpty) ...[
        const Heading('Looks like a monthly bill', size: BwType.headingSize),
        Rows(children: [
          for (final b in candidates)
            Padding(
              key: ValueKey('candidate:${b.id}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SplitRow(
                    start: Text(_name(b), style: const TextStyle(fontWeight: FontWeight.w500)),
                    end: Text(moneyExact(b.expectedAmount, cur),
                        textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
                Text('Next about ${shortDateOrRaw(b.nextDue)}', style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                const SizedBox(height: 4),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  OutlinedButton(
                      key: ValueKey('confirm:${b.id}'),
                      style: accentOutlined(context),
                      onPressed: () {
                        logNav('bill.confirm');
                        wc.confirmRecurring(b.id);
                      },
                      child: const Text('Confirm')),
                  TextButton(
                      key: ValueKey('dismiss:${b.id}'),
                      onPressed: () {
                        logNav('bill.dismiss');
                        wc.dismissRecurring(b.id);
                      },
                      child: const Text('Not a bill')),
                ]),
              ]),
            ),
        ]),
      ],
      if (confirmed.isNotEmpty) ...[
        const Heading('Confirmed', size: BwType.headingSize),
        Rows(children: [
          for (final b in confirmed)
            Container(
              key: ValueKey('bill:${b.id}'),
              constraints: const BoxConstraints(minHeight: touchMin),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // The amount shares the name's line (at most half the row): at large text a side-by-side amount left the column 34 dp wide.
                    SplitRow(
                        start: Text(_name(b), style: const TextStyle(fontWeight: FontWeight.w500)),
                        end: Text(moneyExact(b.expectedAmount, cur),
                            textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
                    Text('${wc.categoryTable.label(b.category)} · next ${shortDateOrRaw(b.nextDue)}',
                        style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                    if (b.coveredByPlanIn(wc.categoryTable))
                      Text('Covered by your plan', style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                    if (b.nextDue.compareTo(today) < 0)
                      const StatusLabel(good: false, text: 'Overdue')
                    else if (wc.billPaidThisPeriod(b))
                      const StatusLabel(good: true, text: 'Paid'),
                    Wrap(spacing: 4, children: [
                      TextButton(
                        key: ValueKey('skip:${b.id}'),
                        style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(48, touchMin),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            alignment: Alignment.centerLeft),
                        onPressed: () {
                          logNav('bill.skip');
                          wc.skipRecurring(b.id);
                          toast(context, 'Skipped to the next cycle');
                        },
                        child: const Text('Skip this cycle'),
                      ),
                      TextButton(
                        key: ValueKey('billHistory_${b.id}'),
                        style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(48, touchMin),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        onPressed: () => openBillHistory(context, wc, b.id),
                        child: const Text('History'),
                      ),
                    ]),
                  ]),
                ),
                IconButton(
                  tooltip: 'Remove bill',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    logNav('bill.delete');
                    wc.deleteRecurring(b.id);
                    toast(context, 'Bill removed');
                  },
                ),
              ]),
            ),
        ]),
      ],
    ]);
  }
}

/// Plan › Nudges: one switch for the phone's reminders (this device only). They never show amounts.
class NudgesPanel extends StatelessWidget {
  final WalletController wc;
  const NudgesPanel({super.key, required this.wc});
  @override
  Widget build(BuildContext context) {
    final supported = wc.nudges.supported;
    return Panel(children: [
      const SectionHead('Nudges'),
      SwitchListTile(
        key: const ValueKey('nudgesSwitch'),
        contentPadding: EdgeInsets.zero,
        value: wc.nudgesEnabled,
        onChanged: supported
            ? (on) async {
                logNav('nudges.switch', {'on': on});
                final granted = await wc.setNudges(on);
                if (on && !granted && context.mounted) toast(context, 'Notifications are blocked.');
              }
            : null,
        title: const Text('Remind me at 15:00 on weekdays and Sunday 11:00', style: TextStyle(fontSize: BwType.bodySize)),
      ),
      const Muted('Short, friendly lines. A reminder never shows amounts, shops or names. This device only.'),
      SwitchListTile(
        key: const ValueKey('headsUpSwitch'),
        contentPadding: EdgeInsets.zero,
        value: wc.headsUpNotify,
        onChanged: supported
            ? (on) async {
                logNav('headsup.switch', {'on': on});
                final granted = await wc.setHeadsUpNotify(on);
                if (on && !granted && context.mounted) toast(context, 'Notifications are blocked.');
              }
            : null,
        title: const Text('Warn me before big planned costs', style: TextStyle(fontSize: BwType.bodySize)),
      ),
      const Muted(
          'At 09:00, a few days ahead (set in Calendars). Also tells you when a return window or a warranty from your bills is about to end. The text has no amounts or names. This device only.'),
      if (!supported) const Muted('Reminders work in the phone app.'),
      if (wc.nudgesDenied)
        const StatusLabel(
            good: false, text: 'Notifications are blocked. Allow them for Budget Wallet in the system settings, then try again.'),
    ]);
  }
}
