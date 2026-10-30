import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart';
import '../widgets/sheets.dart';
import 'bill_history.dart';
import 'recurring_sheet.dart';

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

/// Bills › Expected bills (a paper tile): bills found in the imports and bills added by hand. Candidates come first (Confirm / Not a
/// bill), then confirmed bills: amount, how often, ONE state chip (Paid, Overdue, a date, Held) and Edit, Mark paid or Skip, History,
/// Remove. A long bill (less often than monthly) is held in full until paid (the Held chip); a range says what it sets aside; a bill
/// paid in parts says how much is paid. Dismissed ones are not shown. [trailing] (the Bills tab: Scan and Add bill) sits in the label
/// row; without it the tile is followed by a "+ Bill" tile of its own.
class ExpectedBillsPanel extends StatelessWidget {
  final WalletController wc;
  final Widget? trailing;
  const ExpectedBillsPanel({super.key, required this.wc, this.trailing});

  static String _name(RecurringBill b) => b.label.isNotEmpty ? b.label : b.payee;

  static final _tight = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      minimumSize: const Size(48, touchMin),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      alignment: Alignment.centerLeft);

  /// A small grey line, with an icon when it states something about the money (so the state is not colour alone).
  static Widget _meta(BuildContext context, String text, {IconData? icon, Key? key}) {
    final style = TextStyle(fontSize: BwType.metaSize, color: context.c.ink2);
    if (icon == null) return Text(text, key: key, style: style);
    return Row(key: key, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 1, right: 5), child: Icon(icon, size: 14, color: context.c.ink2)),
      Flexible(child: Text(text, style: style)),
    ]);
  }

  Future<void> _markPaid(BuildContext context, RecurringBill b) async {
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    final old = b.nextDue;
    logNav('bill.markPaid');
    await wc.skipRecurring(b.id);
    // Refused (the clock is behind): the due date did not move, so there is nothing to undo.
    if (wc.recurringBills().where((x) => x.id == b.id).firstOrNull?.nextDue == old) return;
    toastOn(messenger, 'Marked paid',
        wide: wide, accessible: accessible, actionLabel: 'Undo', onAction: () => wc.restoreRecurringDue(b.id, old));
  }

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency;
    final today = wc.today();
    final bills = wc.expectedBills(); // never an income (P9): those are in ExpectedIncomePanel
    final candidates = bills.where((b) => b.status == 'candidate').toList();
    final confirmed = bills.where((b) => b.status == 'confirmed').toList();
    final allMonthly = candidates.every((b) => RecurringPeriod.of(b.intervalDays) == RecurringPeriod.monthly);
    const label = TileLabel('Expected bills');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Tile(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          HeadingRow(
              label,
              Wrap(alignment: WrapAlignment.end, children: [
                TileInfo(
                    key: const ValueKey('expectedInfo'),
                    onTap: () => showInfoSheet(context, 'Expected bills',
                        'Found in your imports, or added by you. A confirmed bill is set aside from your daily money until it is paid. A bill that comes less often than monthly is set aside in full. Rent, loan and bills in your plan are already counted.')),
                if (trailing != null) trailing!,
              ])),
          if (candidates.isEmpty && confirmed.isEmpty)
            const Padding(
                padding: EdgeInsets.only(top: 8),
                child: EmptyNote('No repeating bills found yet. They show up after a few months of imports.')),
          if (candidates.isNotEmpty) ...[
            const SizedBox(height: 8),
            Heading(allMonthly ? 'Looks like a monthly bill' : 'Looks like a repeating bill', size: BwType.headingSize),
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
                    Text(
                        RecurringPeriod.of(b.intervalDays) == RecurringPeriod.monthly
                            ? 'Next about ${shortDateOrRaw(b.nextDue)}'
                            : '${billPeriodText(b.intervalDays)[0].toUpperCase()}${billPeriodText(b.intervalDays).substring(1)} · next about ${shortDateOrRaw(b.nextDue)}',
                        style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
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
                      TextButton(
                          key: ValueKey('recurringEdit:${b.id}'),
                          onPressed: () => openRecurringForm(context, wc, edit: b),
                          child: const Text('Edit')),
                    ]),
                  ]),
                ),
            ]),
          ],
          if (confirmed.isNotEmpty) ...[
            if (candidates.isNotEmpty) const Heading('Confirmed', size: BwType.headingSize),
            Rows(children: [
              for (final b in confirmed) _confirmedRow(context, b, cur, today),
            ]),
          ],
        ]),
      ),
      if (trailing == null) ...[
        const SizedBox(height: 10),
        AddTile(key: const ValueKey('addRecurring'), label: 'Bill', onTap: () => openRecurringForm(context, wc)),
      ],
    ]);
  }

  /// The one state a bill shows: All paid, Overdue, Paid (a monthly or shorter bill whose payment is in), Held (a long bill) or the
  /// date it is due. The date also lives in the chip, so the grey line says "next …" only for the other states.
  StateChip _chip(RecurringBill b, String today) {
    if (b.finished) return const StateChip.onPace(text: 'All paid');
    if (b.nextDue.compareTo(today) < 0) return const StateChip.over(text: 'Overdue');
    if (!b.isShort && !b.isLong && wc.billPaidThisPeriod(b)) return const StateChip.onPace(text: 'Paid');
    if (b.isLong) return StateChip.held(key: ValueKey('billHeld:${b.id}'));
    return StateChip.date(shortDateOrRaw(b.nextDue));
  }

  Widget _confirmedRow(BuildContext context, RecurringBill b, String cur, String today) {
    final parts = wc.billPartsPaid(b);
    final range = billRangeText(b, cur);
    final instalments = billInstalmentText(b);
    final monthly = RecurringPeriod.of(b.intervalDays) == RecurringPeriod.monthly;
    final markPaid = parts > 0 || b.payee.isEmpty;
    final chip = _chip(b, today);
    final dateInChip = chip.state == DashState.date;
    final heldInChip = chip.state == DashState.held;
    return Container(
      key: ValueKey('bill:${b.id}'),
      constraints: const BoxConstraints(minHeight: touchMin),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // The amount shares the name's line (at most half the row): at large text a side-by-side amount left the column 34 dp wide.
            SplitRow(
                start: Text(_name(b), style: const TextStyle(fontWeight: FontWeight.w500)),
                end: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(moneyExact(b.reserveAmount, cur), style: numStyle.copyWith(fontWeight: FontWeight.w500)))),
            _meta(
                context,
                [
                  wc.categoryTable.label(b.category),
                  if (!monthly) billPeriodText(b.intervalDays),
                  if (!dateInChip && !b.finished) 'next ${shortDateOrRaw(b.nextDue)}',
                ].join(' · ')),
            if (range != null) _meta(context, range, key: ValueKey('billRange:${b.id}')),
            if (instalments != null) _meta(context, instalments, key: ValueKey('billInstalments:${b.id}')),
            if (parts > 0)
              _meta(context, billPaidText(parts, b.reserveAmount, cur), icon: Icons.timelapse, key: ValueKey('billParts:${b.id}')),
            if (b.isLong && !b.finished && !heldInChip)
              _meta(context, 'Held in full until paid', icon: Icons.lock_outline, key: ValueKey('billHeld:${b.id}')),
            if (b.coveredByPlanIn(wc.categoryTable) && !b.isLong) _meta(context, 'Covered by your plan'),
            Padding(padding: const EdgeInsets.only(top: 4), child: chip),
            Wrap(spacing: 4, children: [
              if (markPaid)
                TextButton(
                  key: ValueKey('recurringMarkPaid:${b.id}'),
                  style: _tight,
                  onPressed: () => _markPaid(context, b),
                  child: const Text('Mark paid'),
                )
              else
                TextButton(
                  key: ValueKey('skip:${b.id}'),
                  style: _tight,
                  onPressed: () {
                    logNav('bill.skip');
                    wc.skipRecurring(b.id);
                    toast(context, 'Skipped to the next cycle');
                  },
                  child: const Text('Skip this cycle'),
                ),
              TextButton(
                key: ValueKey('recurringEdit:${b.id}'),
                style: _tight,
                onPressed: () => openRecurringForm(context, wc, edit: b),
                child: const Text('Edit'),
              ),
              TextButton(
                key: ValueKey('billHistory_${b.id}'),
                style: _tight,
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
    );
  }
}

/// Plan › Expected income (P9): regular money in besides the salary (a side job, rent received), found in the imports or added by
/// hand. Candidates first (Confirm / Not regular), then confirmed incomes (how often, amount or range, next date, Edit, Delete with
/// Undo). It is shown as expected; it counts toward the spending money only once it lands (Payday plan lines).
class ExpectedIncomePanel extends StatelessWidget {
  final WalletController wc;
  const ExpectedIncomePanel({super.key, required this.wc});

  static String _name(RecurringBill b) => b.label.isNotEmpty ? b.label : b.payee.replaceAll('_', ' ');

  static String _period(RecurringBill b) {
    final t = billPeriodText(b.intervalDays);
    return '${t[0].toUpperCase()}${t.substring(1)}';
  }

  static int _shown(RecurringBill b) => b.hasRange ? b.minAmount! : b.expectedAmount;

  void _delete(BuildContext context, RecurringBill b) {
    logNav('income.delete');
    wc.deleteRecurring(b.id);
    toast(context, 'Income removed', actionLabel: 'Undo', onAction: () => wc.undeleteRecurring(b.id));
  }

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency;
    final today = wc.today();
    final incomes = wc.expectedIncomes();
    final candidates = incomes.where((b) => b.status == 'candidate').toList();
    final confirmed = incomes.where((b) => b.status == 'confirmed').toList();
    return Panel(key: const ValueKey('expectedIncomePanel'), children: [
      const SectionHead('Expected income'),
      Explainer(wc, 'expectedIncome',
          'Regular money that comes in besides your salary. It is shown as expected. It counts toward your spending money only once it lands.'),
      if (candidates.isEmpty && confirmed.isEmpty)
        const EmptyNote('No regular income found yet. Add one, or it shows up after a few months of imports.'),
      if (candidates.isNotEmpty) ...[
        const Heading('Looks like regular income', size: BwType.headingSize),
        Rows(children: [
          for (final b in candidates)
            Padding(
              key: ValueKey('incomeCandidate:${b.id}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SplitRow(
                    start: Text(_name(b), style: const TextStyle(fontWeight: FontWeight.w500)),
                    end: Text(moneyExact(b.expectedAmount, cur),
                        textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
                Text('${_period(b)} · next about ${shortDateOrRaw(b.nextDue)}',
                    style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                const SizedBox(height: 4),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  OutlinedButton(
                      key: ValueKey('incomeConfirm:${b.id}'),
                      style: accentOutlined(context),
                      onPressed: () {
                        logNav('income.confirm');
                        wc.confirmRecurring(b.id);
                      },
                      child: const Text('Confirm')),
                  TextButton(
                      key: ValueKey('incomeDismiss:${b.id}'),
                      onPressed: () {
                        logNav('income.dismiss');
                        wc.dismissRecurring(b.id);
                      },
                      child: const Text('Not regular')),
                  TextButton(
                      key: ValueKey('incomeEdit:${b.id}'),
                      onPressed: () => openRecurringForm(context, wc, edit: b),
                      child: const Text('Edit')),
                ]),
              ]),
            ),
        ]),
      ],
      if (confirmed.isNotEmpty) ...[
        const Heading('Confirmed', size: BwType.headingSize),
        Rows(children: [
          for (final b in confirmed) _confirmedRow(context, b, cur, today),
        ]),
      ],
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('addIncome'),
          style: accentOutlined(context),
          onPressed: () => openRecurringForm(context, wc, income: true),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add income'),
        ),
      ),
    ]);
  }

  Widget _confirmedRow(BuildContext context, RecurringBill b, String cur, String today) {
    final monthly = RecurringPeriod.of(b.intervalDays) == RecurringPeriod.monthly;
    final meta = TextStyle(fontSize: BwType.metaSize, color: context.c.ink2);
    return Container(
      key: ValueKey('income:${b.id}'),
      constraints: const BoxConstraints(minHeight: touchMin),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SplitRow(
                start: Text(_name(b), style: const TextStyle(fontWeight: FontWeight.w500)),
                end: Text(moneyExact(_shown(b), cur), textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
            Text(
                [wc.categoryTable.label(b.category), if (!monthly) billPeriodText(b.intervalDays), 'next ${shortDateOrRaw(b.nextDue)}']
                    .join(' · '),
                style: meta),
            if (b.hasRange)
              Text('${billRangeShort(b.minAmount!, b.maxAmount!, cur)}, counted at ${moneyExact(b.minAmount!, cur)}',
                  key: ValueKey('incomeRange:${b.id}'), style: meta),
            if (b.nextDue.compareTo(today) < 0) const StatusLabel(good: false, text: 'Not received yet'),
            Wrap(spacing: 4, children: [
              TextButton(
                key: ValueKey('incomeEdit:${b.id}'),
                style: ExpectedBillsPanel._tight,
                onPressed: () => openRecurringForm(context, wc, edit: b),
                child: const Text('Edit'),
              ),
            ]),
          ]),
        ),
        IconButton(
          key: ValueKey('incomeDelete:${b.id}'),
          tooltip: 'Remove income',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _delete(context, b),
        ),
      ]),
    );
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
