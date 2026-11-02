// The Loan screen (ENG E6, spec §5.5 step 4): what is owed, the per-year principal and interest, the payments found in Money, the
// lender's balance check and the what-if. Every number is core's (`loanSchedule`, `loanState`, `loanPayments`, `loanWhatIf`) through the
// controller. Opens from the Payday plan line, the goal and a Money row.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart';
import '../widgets/insight_charts.dart' show LegendItem;
import '../widgets/ledger_row.dart';
import '../widgets/sheets.dart';
import 'goal_planner.dart' show openGoalPlanner, scaledNumber;
import 'loan_fields.dart';

Future<void> openLoan(BuildContext context, WalletController wc, String loanId) =>
    openPageOrDialog<void>(context, LoanScreen(wc: wc, loanId: loanId), width: 600, logName: 'Loan');

/// "Turn into a loan…" (the old plan Loan setting) and "+ Loan" (a loan taken before the app).
Future<String?> showLoanForm(BuildContext context, WalletController wc, {required LoanFormMode mode, Loan? loan}) =>
    showSheet<String>(context, LoanFormSheet(wc: wc, mode: mode, loan: loan));

class LoanScreen extends StatefulWidget {
  final WalletController wc;
  final String loanId;
  const LoanScreen({super.key, required this.wc, required this.loanId});
  @override
  State<LoanScreen> createState() => _LoanScreenState();
}

class _LoanScreenState extends State<LoanScreen> {
  WalletController get wc => widget.wc;
  final shown = TextEditingController(),
      once = TextEditingController(),
      monthly = TextEditingController(),
      newRate = TextEditingController();
  LoanCheckView? checkResult;
  int? checkedBalance;
  String? checkError;

  @override
  void dispose() {
    for (final c in [shown, once, monthly, newRate]) {
      c.dispose();
    }
    super.dispose();
  }

  void _check(LoanView v) {
    final b = parseMoney(shown.text);
    if (b == null) return setState(() => checkError = invalidAmountMessage);
    setState(() {
      checkError = null;
      checkedBalance = b;
      checkResult = wc.checkLoanBalance(v, b, wc.today());
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final v = wc.loanView(widget.loanId);
          if (v == null) return const Scaffold(body: SizedBox.shrink());
          return Scaffold(
            appBar: DialogAppBar(title: v.loan.name, actions: [
              IconButton(
                  key: const ValueKey('loanEdit'),
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit details',
                  onPressed: () => showLoanForm(context, wc, mode: LoanFormMode.details, loan: v.loan))
            ]),
            body: ColoredBox(
              color: context.c.desk,
              child: ListView(
                key: const ValueKey('loanPage'),
                padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, pageBottomPad + 48),
                children: gapped([
                  _hero(context, v),
                  if (v.schedule.isNotEmpty) _chart(context, v),
                  _payments(context, v),
                  if (v.schedule.isNotEmpty && v.loan.open) ...[_check_(context, v), _whatIf(context, v)],
                  _footer(context, v),
                ], gap: 14),
              ),
            ),
          );
        },
      );

  Widget _hero(BuildContext context, LoanView v) {
    final cur = wc.currency, c = context.c, l = v.loan, st = v.state;
    final payment = wc.settings.loanLines[l.id] ?? l.payment;
    return Panel(key: const ValueKey('loanHero'), children: [
      if (!l.open)
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StateChip.onPace(key: const ValueKey('loanClosed'), text: 'Paid off ${shortDateOrRaw(l.closedAt!)}'),
          TextButton(
              key: const ValueKey('loanReopen'),
              onPressed: () {
                wc.reopenLoan(l.id);
                toast(context, 'Loan is open again');
              },
              child: const Text('Open it again')),
        ]),
      if (v.schedule.isEmpty) ...[
        const Eyebrow('Loan'),
        if (payment != null) Text('${moneyExact(payment, cur)} a month', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const Muted(
            'The amount borrowed, rate, length and first payment date are not known yet. Add them to see what is owed and when it ends.',
            key: ValueKey('loanNoDetails')),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
                key: const ValueKey('loanAddDetails'),
                onPressed: () => showLoanForm(context, wc, mode: LoanFormMode.details, loan: l),
                child: const Text('Add details'))),
      ] else ...[
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Eyebrow('Owed now'),
          const SizedBox(height: 4),
          Text(moneyExact(st.owedNow, cur),
              key: const ValueKey('loanOwed'), style: BwType.amount.copyWith(fontSize: 30, fontWeight: FontWeight.w700, color: c.ink)),
        ]),
        Rows(children: [
          LedgerRow('Months left', '${st.monthsLeft}', key: const ValueKey('loanMonthsLeft')),
          LedgerRow('Paid off in', st.payoffMonth == null ? '-' : monthLong(st.payoffMonth!), key: const ValueKey('loanPayoff')),
          LedgerRow('Interest paid so far', moneyExact(st.interestPaid, cur), key: const ValueKey('loanInterestPaid')),
          LedgerRow('Interest still to pay', moneyExact(st.interestToPay, cur),
              sub: 'An estimate', key: const ValueKey('loanInterestToPay')),
          if (payment != null) LedgerRow('Payment a month', moneyExact(payment, cur), key: const ValueKey('loanPayment')),
        ]),
      ],
    ]);
  }

  Widget _chart(BuildContext context, LoanView v) {
    final c = context.c, cur = wc.currency;
    final years = loanYears(v.schedule);
    final start = v.schedule.first.opening;
    return Panel(key: const ValueKey('loanChartPanel'), children: [
      const Text('Each year', style: BwType.heading),
      Wrap(spacing: 14, runSpacing: 4, children: [
        LegendItem(c.s1, 'Principal'),
        LegendItem(c.s4, 'Interest'),
        LegendItem(c.ink2, 'Balance', line: true),
      ]),
      Semantics(
        label: 'Per year: principal and interest paid, and the balance, from ${years.first.year} to ${years.last.year}',
        child: ExcludeSemantics(
          child: SizedBox(
            height: 150,
            child: CustomPaint(
              key: const ValueKey('loanChart'),
              size: Size.infinite,
              painter: _YearsPainter(
                  years: years, start: start, principal: c.s1, interest: c.s4, balance: c.ink2, line: c.lineStrong, muted: c.muted),
            ),
          ),
        ),
      ),
      ExpansionTile(
        key: const ValueKey('loanYearsTable'),
        tilePadding: EdgeInsets.zero,
        title: const Text('By year'),
        children: [
          Rows(children: [
            for (final y in years)
              LedgerRow('${y.year}', 'Left ${moneyExact(y.endBalance, cur)}',
                  sub: 'Principal ${moneyExact(y.principal, cur)} · interest ${moneyExact(y.interest, cur)}'
                      '${y.adjust == 0 ? '' : ' · balance checks ${moneyExactSigned(y.adjust, cur)}'}'),
          ]),
        ],
      ),
    ]);
  }

  Widget _payments(BuildContext context, LoanView v) {
    final cur = wc.currency, l = v.loan, c = context.c;
    final known = (l.payeeKey ?? '').isNotEmpty || loanReferenceUsable(l.reference);
    final asks = wc.loanAsks(l.id);
    final recent = v.payments.reversed.take(12).toList();
    return Panel(key: const ValueKey('loanPayments'), children: [
      const Text('Payments', style: BwType.heading),
      if (!known) ...[
        const Muted("Add the lender's name or the reference on each payment, and its payments in Money are found here.",
            key: ValueKey('loanNoMatch')),
        Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
                key: const ValueKey('loanAddLender'),
                onPressed: () => showLoanForm(context, wc, mode: LoanFormMode.details, loan: l),
                child: const Text('Add the lender'))),
      ] else ...[
        if (v.schedule.isNotEmpty) Muted('${v.state.paidMonths} of ${v.schedule.length} payments found', key: const ValueKey('loanFound')),
        for (final a in asks) _ask(context, l, a),
        if (v.state.notSeen.isNotEmpty)
          DashRows(rows: [
            for (final d in v.state.notSeen.reversed.take(6))
              DashRowData(key: ValueKey('notSeen:$d'), title: 'Due ${shortDateOrRaw(d)}', chip: const StateChip.date('Not seen yet')),
          ]),
        if (recent.isNotEmpty)
          Column(children: [
            for (final p in recent)
              RuledRow(
                key: ValueKey('loanPay:${p.txId}'),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: SplitRow(
                  start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(shortDateOrRaw(p.date), style: const TextStyle(fontSize: BwType.bodySize)),
                    if (p.amountChanged) const Padding(padding: EdgeInsets.only(top: 2), child: StateChip.over(text: 'Amount changed')),
                  ]),
                  end: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(child: Text(moneyExact(p.amount, cur), textAlign: TextAlign.end, style: numStyle)),
                    IconButton(
                        key: ValueKey('loanUnlink:${p.txId}'),
                        icon: Icon(Icons.link_off, size: 20, color: c.ink2),
                        tooltip: 'Unlink this payment',
                        onPressed: () => _unlink(l, p)),
                  ]),
                ),
              ),
          ])
        else if (v.state.notSeen.isEmpty && asks.isEmpty)
          const Muted('No payment found yet.', key: ValueKey('loanNoPayments')),
        const Muted("Found by the lender's name or reference."),
      ],
    ]);
  }

  /// "Loan payment?": a bank row the lender's name or reference finds, not answered yet. Yes (the loan, when several fit) or No.
  Widget _ask(BuildContext context, Loan l, ({LoanPaymentMatch payment, List<Loan> loans}) a) {
    final c = context.c, p = a.payment, cur = wc.currency;
    final several = a.loans.length > 1;
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    void yes(Loan to) {
      final err = wc.confirmLoanPayment(to.id, p.txId);
      // Core has no "unanswered" state: Undo answers No for this loan, so the row is not asked about again.
      toastOn(messenger, err ?? 'Marked as a payment on ${to.name}',
          wide: wide,
          accessible: accessible,
          actionLabel: err == null ? 'Undo' : null,
          onAction: err == null
              ? () {
                  wc.unlinkLoanPayment([to.id], p.txId);
                  toastOn(messenger, 'Undone. This payment is not matched to ${to.name}.', wide: wide, accessible: accessible);
                }
              : null);
    }

    return Container(
      key: ValueKey('loanAsk:${p.txId}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.accentSoftLine)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: gapped([
            const Text('Loan payment?', style: TextStyle(fontWeight: FontWeight.w700)),
            Text('${shortDateOrRaw(p.date)} · ${moneyExact(p.amount, cur)}', style: numStyle),
            if (several) Muted('It could be a payment on ${a.loans.map((x) => x.name).join(' or ')}.'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final to in several ? a.loans : [l])
                FilledButton(
                    key: ValueKey(several ? 'loanAskYes:${p.txId}:${to.id}' : 'loanAskYes:${p.txId}'),
                    onPressed: () => yes(to),
                    child: Text(several ? 'Yes, ${to.name}' : 'Yes')),
              OutlinedButton(
                  key: ValueKey('loanAskNo:${p.txId}'),
                  onPressed: () {
                    final err = wc.unlinkLoanPayment([for (final x in a.loans) x.id], p.txId);
                    toastOn(messenger, err ?? 'Not a loan payment', wide: wide, accessible: accessible);
                  },
                  child: const Text('No')),
            ]),
          ], gap: 6)),
    );
  }

  /// Unlink a matched payment; the toast's Undo confirms it again.
  void _unlink(Loan l, LoanPaymentMatch p) {
    final err = wc.unlinkLoanPayment([l.id], p.txId);
    toast(context, err ?? 'Unlinked',
        actionLabel: err == null ? 'Undo' : null, onAction: err == null ? () => wc.confirmLoanPayment(l.id, p.txId) : null);
  }

  Widget _check_(BuildContext context, LoanView v) {
    final cur = wc.currency, c = context.c, r = checkResult;
    return Panel(key: const ValueKey('loanCheck'), children: [
      const Text('What did the lender show?', style: BwType.heading),
      const Muted("Type the balance on the lender's statement. Nothing changes until you confirm."),
      MoneyField(
          fieldKey: const ValueKey('loanCheckField'),
          controller: shown,
          onChanged: (_) => setState(() {
                checkResult = null;
                checkError = null;
              }),
          decoration: InputDecoration(labelText: 'Balance', suffixText: currencySymbol(cur), errorText: checkError)),
      Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(key: const ValueKey('loanCheckGo'), onPressed: () => _check(v), child: const Text('Check'))),
      if (r != null && r.matches) const StatusLabel(key: ValueKey('loanCheckMatches'), good: true, text: 'Matches the schedule'),
      if (r != null && !r.matches) ...[
        Row(children: [
          Icon(Icons.warning_amber_rounded, color: c.warnInk, size: 18),
          const SizedBox(width: 6),
          Expanded(
              child: Text(
                  'Off by ${moneyExact(r.diff!.abs(), cur)} (${r.diff! > 0 ? 'more' : 'less'} than the schedule: ${moneyExact(r.expected!, cur)})',
                  key: const ValueKey('loanCheckOff'),
                  style: TextStyle(color: c.warnInk, fontWeight: FontWeight.w600))),
        ]),
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
                key: const ValueKey('loanCheckApply'),
                onPressed: () {
                  final err = wc.addLoanCheck(v.loan.id, checkedBalance!);
                  if (!mounted) return;
                  if (err != null) return setState(() => checkError = err);
                  setState(() {
                    checkResult = null;
                    shown.clear();
                  });
                  toast(context, 'The schedule goes on from this balance');
                },
                child: const Text('Continue from this balance'))),
      ],
    ]);
  }

  Widget _whatIf(BuildContext context, LoanView v) {
    final cur = wc.currency;
    int cents(TextEditingController c) => c.text.trim().isEmpty ? 0 : (parseMoney(c.text) ?? 0);
    final bp = newRate.text.trim().isEmpty ? null : scaledNumber(newRate.text, 100);
    final extraOnce = cents(once), extraMonthly = cents(monthly);
    final any = extraOnce > 0 || extraMonthly > 0 || bp != null;
    final w = any ? wc.loanWhatIfFor(v, extraOnce: extraOnce, extraMonthly: extraMonthly, newRateBp: bp) : null;
    Widget field(String key, String label, TextEditingController ctl) => MoneyField(
        fieldKey: ValueKey(key),
        controller: ctl,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: label, suffixText: currencySymbol(cur)));
    return Panel(key: const ValueKey('loanWhatIf'), children: [
      const Text('What if', style: BwType.heading),
      const Muted('Nothing is saved from here, except a new rate you choose to use.'),
      field('whatIfOnce', 'Extra payment, once', once),
      field('whatIfMonthly', 'Extra every month', monthly),
      TextField(
          key: const ValueKey('whatIfRate'),
          controller: newRate,
          onChanged: (_) => setState(() {}),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.end,
          style: numStyle,
          decoration: const InputDecoration(labelText: 'New rate from today', suffixText: '%')),
      if (w != null)
        Column(crossAxisAlignment: CrossAxisAlignment.start, key: const ValueKey('whatIfResult'), children: [
          Text(w.monthsSaved == 0 ? 'Ends in the same month' : '${w.monthsSaved.abs()} months ${w.monthsSaved > 0 ? 'sooner' : 'later'}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(
              w.interestSaved >= 0
                  ? '${moneyExact(w.interestSaved, cur)} less interest'
                  : '${moneyExact(-w.interestSaved, cur)} more interest',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          if (w.newPayment != null)
            Text('New payment ${moneyExact(w.newPayment!, cur)} a month', style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      if (w?.newPayment != null && bp != null)
        Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
                key: const ValueKey('whatIfUse'),
                onPressed: () {
                  final err = wc.addLoanRateNow(v.loan.id, bp, w!.newPayment);
                  if (err != null) return toast(context, err);
                  newRate.clear();
                  toast(context, 'New rate saved');
                },
                child: const Text('Use this rate'))),
    ]);
  }

  Widget _footer(BuildContext context, LoanView v) {
    final l = v.loan, goal = l.goalId == null ? null : wc.goalOf(l.goalId!);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: gapped([
          if (goal != null)
            TextButton.icon(
                key: const ValueKey('loanOpenGoal'),
                icon: const Icon(Icons.flag_outlined),
                label: Text('Bought as ${goal.name}'),
                onPressed: () => openGoalPlanner(context, wc, goal.id)),
          if (l.open)
            OutlinedButton(
                key: const ValueKey('loanClose'),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                            title: const Text('Close this loan?'),
                            content: const Text('It is marked as paid off today and its line leaves your plan.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                              FilledButton(
                                  key: const ValueKey('loanCloseConfirm'),
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Close loan')),
                            ],
                          ));
                  if (ok != true || !mounted) return;
                  final err = wc.closeLoanNow(l.id);
                  if (!mounted) return;
                  toast(this.context, err ?? 'Loan closed',
                      actionLabel: err == null ? 'Undo' : null, onAction: err == null ? () => wc.reopenLoan(l.id) : null);
                },
                child: const Text('Close loan')),
        ], gap: 8));
  }
}

/// Principal and interest stacked per year (2 px gap, interest in a series slot, never `bad`) and the balance as a line on its own scale.
class _YearsPainter extends CustomPainter {
  final List<LoanYear> years;
  final int start;
  final Color principal, interest, balance, line, muted;
  const _YearsPainter(
      {required this.years,
      required this.start,
      required this.principal,
      required this.interest,
      required this.balance,
      required this.line,
      required this.muted});

  void _label(Canvas canvas, String t, double x, double y, {bool right = false}) {
    final p = TextPainter(
        text: TextSpan(text: t, style: TextStyle(color: muted, fontSize: 10, fontFamily: monoFamily)), textDirection: TextDirection.ltr)
      ..layout();
    p.paint(canvas, Offset(right ? x - p.width : x, y));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (years.isEmpty) return;
    const top = 6.0, axis = 16.0;
    final bottom = size.height - axis, h = bottom - top, n = years.length;
    final slot = size.width / n, barW = math.max(2.0, slot - 3);
    // The bar scale (geometry only): the tallest stack of principal and interest.
    final tallest = years.map((y) => y.principal + y.interest).reduce(math.max);
    for (var i = 0; i < n; i++) {
      final y = years[i], x = i * slot + (slot - barW) / 2;
      final hp = tallest == 0 ? 0.0 : y.principal / tallest * h, hi = tallest == 0 ? 0.0 : y.interest / tallest * h;
      canvas.drawRect(Rect.fromLTWH(x, bottom - hp, barW, hp), Paint()..color = principal);
      // A 2 px gap between the two parts.
      if (hi > 2) canvas.drawRect(Rect.fromLTWH(x, bottom - hp - hi, barW, hi - 2), Paint()..color = interest);
    }
    final path = Path()..moveTo(0, bottom - h);
    for (var i = 0; i < n; i++) {
      final yy = start == 0 ? bottom : bottom - years[i].endBalance / start * h;
      path.lineTo(i * slot + slot / 2, yy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = balance
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
    canvas.drawLine(Offset(0, bottom), Offset(size.width, bottom), Paint()..color = line);
    _label(canvas, '${years.first.year}', 0, bottom + 3);
    _label(canvas, '${years.last.year}', size.width, bottom + 3, right: true);
  }

  @override
  bool shouldRepaint(_YearsPainter o) => o.years != years || o.principal != principal || o.interest != interest || o.balance != balance;
}

enum LoanFormMode { convert, add, details }

/// The loan form: [LoanFormMode.convert] moves the old plan Loan setting into a loan (nothing is written before Confirm),
/// [LoanFormMode.add] adds a loan taken before the app, [LoanFormMode.details] fills in or corrects [loan]. Pops `'saved'`.
class LoanFormSheet extends StatefulWidget {
  final WalletController wc;
  final LoanFormMode mode;
  final Loan? loan;
  const LoanFormSheet({super.key, required this.wc, required this.mode, this.loan});
  @override
  State<LoanFormSheet> createState() => _LoanFormSheetState();
}

class _LoanFormSheetState extends State<LoanFormSheet> {
  final s = LoanFieldsState();
  late final name = TextEditingController(text: widget.loan?.name ?? 'Loan');
  String? error;

  @override
  void initState() {
    super.initState();
    if (widget.loan != null) s.load(widget.loan!);
  }

  @override
  void dispose() {
    name.dispose();
    s.dispose();
    super.dispose();
  }

  void _save() {
    final wc = widget.wc, mode = widget.mode;
    final nm = name.text.trim().isEmpty ? 'Loan' : name.text.trim();
    final (l, err) = s.read(wc, name: nm, needAll: mode == LoanFormMode.add, withPayment: mode != LoanFormMode.convert);
    if (err != null) return setState(() => error = err);
    final String? problem;
    switch (mode) {
      case LoanFormMode.convert:
        problem = wc.convertLegacyLoan(
            name: nm,
            principal: l!.principal,
            rateBp: l.rateBp,
            months: l.months,
            firstDue: l.firstDue,
            payeeKey: l.payeeKey,
            reference: l.reference);
      case LoanFormMode.add:
        String? e;
        wc.addLoan(l!, error: (m) => e = m);
        problem = e;
      case LoanFormMode.details:
        problem = wc.saveLoanDetails(widget.loan!.id, l!);
    }
    if (problem != null) return setState(() => error = problem);
    logNav('loan.form', {'mode': mode.name});
    Navigator.pop(context, 'saved');
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc, cur = wc.currency;
    final mode = widget.mode;
    return Column(
        key: const ValueKey('loanForm'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: gapped([
          Heading(switch (mode) {
            LoanFormMode.convert => 'Turn into a loan',
            LoanFormMode.add => 'Add a loan',
            LoanFormMode.details => 'Loan details'
          }),
          if (mode == LoanFormMode.convert)
            Muted(
                'Nothing changes until you confirm. Your Loan line of ${moneyExact(wc.settings.loan, cur)} a month becomes this loan, and the old Loan setting goes to 0. '
                'Leave out what you do not know: you can add it later.',
                key: const ValueKey('loanConvertNote')),
          TextField(key: const ValueKey('lf:name'), controller: name, decoration: const InputDecoration(labelText: 'Name')),
          LoanFields(wc: wc, s: s, withPayment: mode != LoanFormMode.convert),
          if (error != null) StatusLabel(key: const ValueKey('loanFormError'), good: false, text: error!),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(
                key: const ValueKey('loanFormSave'), onPressed: _save, child: Text(mode == LoanFormMode.convert ? 'Confirm' : 'Save')),
            OutlinedButton(key: const ValueKey('loanFormCancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ]),
        ], gap: 12));
  }
}
