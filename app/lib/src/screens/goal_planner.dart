// The planner of a big-purchase goal (ENG E6, docs/context/ENG_UI_SPEC.md §5.5, mockup docs/design/engineer/screens/E-House*.dc.html):
// when it is ready to buy, the inputs, the numbers that foot, "Get there sooner", and (once bought) the way on to its loan.
// Every figure is core's (`goalPlan`, `goalLevers`, via the controller); the sliders only change a draft that is written when
// the thumb is let go. Nothing here is specific to a kind of purchase: the copy uses the goal's own name.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/ledger_row.dart';
import '../widgets/param_slider.dart';
import '../widgets/sheets.dart';
import 'goal_bought_sheet.dart';
import 'loan_screen.dart';

Future<void> openGoalPlanner(BuildContext context, WalletController wc, String goalId) =>
    openPageOrDialog<void>(context, GoalPlannerScreen(wc: wc, goalId: goalId), width: 600, logName: 'GoalPlanner');

/// "2 y 3 m", "8 m", "5 y".
String spanText(int months) {
  final y = months ~/ 12, m = months % 12;
  return y == 0 ? '$m m' : (m == 0 ? '$y y' : '$y y $m m');
}

/// A permille as a percent ("20 %", "6.5 %").
String permilleText(int p) => p % 10 == 0 ? '${p ~/ 10} %' : '${(p / 10).toStringAsFixed(1).replaceAll('.', numberStyle.decimal)} %';

/// Basis points as a percent with 0.1 steps ("3.6 %"), two decimals when the rate has them.
String rateBpText(int bp) => '${(bp / 100).toStringAsFixed(bp % 10 == 0 ? 1 : 2).replaceAll('.', numberStyle.decimal)} %';

/// Typed text as a number times [scale] ("6.5" with 10 = 65), or null when it is not a number or is negative.
int? scaledNumber(String text, int scale) {
  final v = double.tryParse(text.trim().replaceAll(',', '.'));
  return v == null || v < 0 || v > 1e9 ? null : (v * scale).round();
}

double _niceStep(double max) => math.pow(10, (math.log(max) / math.ln10).floor() - 2).toDouble();

class GoalPlannerScreen extends StatefulWidget {
  final WalletController wc;
  final String goalId;
  const GoalPlannerScreen({super.key, required this.wc, required this.goalId});
  @override
  State<GoalPlannerScreen> createState() => _GoalPlannerState();
}

class _GoalPlannerState extends State<GoalPlannerScreen> {
  WalletController get wc => widget.wc;
  late final GoalDraft d = GoalDraft.of(wc.goalOf(widget.goalId)!);
  final Set<String> _levers = {}; // lever keys switched on (what-if only)
  bool _notYet = false;
  String? _error;

  /// The slider ends: fixed while a thumb moves (they grow only after a value is let go or typed beyond them), so dragging never runs away.
  late double _priceMax, _monthlyMax;
  static double _maxFor(int v, int floor) => math.max(v * 2, floor).toDouble();

  /// What was last written (or read); the planner writes a draft that differs when it closes (keyboard and screen-reader changes).
  late String _committed;

  @override
  void initState() {
    super.initState();
    _priceMax = _maxFor(d.price, 1000000);
    _monthlyMax = _maxFor(d.monthly, 300000);
    _committed = d.sig; // read now: a late initialiser would run only when first used, after the draft moved
  }

  void _commit() {
    if (d.price > _priceMax * 0.9) _priceMax = _maxFor(d.price, 1000000);
    if (d.monthly > _monthlyMax * 0.9) _monthlyMax = _maxFor(d.monthly, 300000);
    final err = wc.saveGoalDraft(widget.goalId, d);
    if (err != null) return setState(() => _error = err);
    _committed = d.sig;
  }

  void _commitOnClose() {
    final g = wc.goalOf(widget.goalId);
    if (g != null && g.boughtAt == null && d.sig != _committed) {
      wc.saveGoalDraft(widget.goalId, d);
      _committed = d.sig;
    }
  }

  void _set(VoidCallback f, {bool commit = false}) {
    setState(() {
      _error = null;
      f();
    });
    if (commit) _commit();
  }

  Future<void> _typeMoney(String title, int current, void Function(int) set) async {
    final t =
        await askText(context, title: title, initial: centsToFieldText(current, blankZero: true), suffix: currencySymbol(wc.currency));
    final v = t == null ? null : parseMoney(t);
    if (v != null) _set(() => set(v), commit: true);
  }

  Future<void> _typeScaled(String title, int scale, int max, void Function(int) set, {String suffix = '%'}) async {
    final t = await askText(context, title: title, suffix: suffix);
    final v = t == null ? null : scaledNumber(t, scale);
    if (v != null && v <= max) _set(() => set(v), commit: true);
  }

  Future<void> _customYears() async {
    final t = await askText(context,
        title: 'Loan length',
        suffix: 'years',
        initial: d.months == null ? '' : (d.months! % 12 == 0 ? '${d.months! ~/ 12}' : '${d.months! / 12}'));
    final y = t == null ? null : scaledNumber(t, 12);
    if (y != null && y >= 1 && y <= 600) _set(() => d.months = y, commit: true);
  }

  Future<void> _useLevers(GoalPlan shown, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Put ${moneyExact(shown.monthly, wc.currency)} a month into $name?'),
        content: const Text('It comes out of your spending money. Nothing changes until you confirm.'),
        actions: [
          TextButton(key: const ValueKey('leversCancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('leversConfirm'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Put it in')),
        ],
      ),
    );
    if (ok != true) return;
    logNav('goal.levers.use', {'count': _levers.length});
    _set(() {
      d.monthly = shown.monthly;
      _levers.clear();
    }, commit: true);
  }

  Future<void> _bought(Goal g) async {
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    final r = await showSheet<String>(context, BoughtSheet(wc: wc, goal: g, draft: d));
    if (r == 'bought') {
      toastOn(messenger, '${g.name} is marked as bought',
          wide: wide, accessible: accessible, actionLabel: 'Undo', onAction: () => wc.undoBuyGoal(g.id));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final g = wc.goalOf(widget.goalId);
          if (g == null) return const Scaffold(body: SizedBox.shrink());
          return PopScope(
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) _commitOnClose();
              },
              child: Scaffold(
                appBar: DialogAppBar(title: g.name, actions: [
                  IconButton(
                      key: const ValueKey('plannerEdit'),
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Edit goal',
                      onPressed: () async {
                        final r = await showSheet<String>(context, GoalSheet(wc: wc, goal: g));
                        if (!context.mounted) return;
                        goalSheetToast(context, wc, r);
                        if (r == 'deleted') Navigator.pop(context);
                      })
                ]),
                body: ColoredBox(
                  color: context.c.desk,
                  child: ListView(
                    key: const ValueKey('plannerPage'),
                    padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, pageBottomPad + 48),
                    children: gapped(g.boughtAt != null ? _boughtView(context, g) : _planView(context, g), gap: 14),
                  ),
                ),
              ));
        },
      );

  // ---------- bought ----------

  List<Widget> _boughtView(BuildContext context, Goal g) {
    final loan = wc.loanOfGoal(g);
    return [
      Panel(key: const ValueKey('plannerBought'), children: [
        const Eyebrow('Bought'),
        Text(longDateOrRaw(g.boughtAt!), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        Muted(loan == null ? 'Paid in full.' : 'With a loan. Its payment is a line in your payday plan.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (loan != null)
            FilledButton(
                key: const ValueKey('plannerOpenLoan'),
                onPressed: () => openLoan(context, wc, loan.id),
                child: const Text('Open the loan')),
          OutlinedButton(
              key: const ValueKey('plannerUndoBought'),
              onPressed: () {
                wc.undoBuyGoal(g.id);
                toast(context, '${g.name} is back to saving');
              },
              child: const Text('Not bought after all')),
        ]),
      ]),
    ];
  }

  // ---------- saving ----------

  List<Widget> _planView(BuildContext context, Goal g) {
    final cur = wc.currency, c = context.c;
    final plan = wc.planFor(g, d);
    final levers = plan.left > 0 ? wc.leversFor(g.id, plan) : const <GoalLever>[];
    final on = [
      for (final l in levers)
        if (_levers.contains(l.key)) l
    ];
    final shown = on.isEmpty ? plan : wc.planFor(g, d, applied: on);
    final financed = d.depositPermille < 1000;
    final ready = plan.need > 0 && plan.left == 0;
    final compare = wc.compareChoices();

    Widget readyCard() => Panel(key: const ValueKey('plannerReady'), color: c.accentSoft, children: [
          Row(children: [
            Icon(Icons.check_circle_outline, color: c.good),
            const SizedBox(width: 8),
            Expanded(child: Text('${g.name} is ready', style: BwType.heading)),
          ]),
          const Muted('You have the deposit and costs.'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(key: const ValueKey('plannerIBought'), onPressed: () => _bought(g), child: const Text('I bought it')),
            OutlinedButton(
                key: const ValueKey('plannerNotYet'), onPressed: () => setState(() => _notYet = true), child: const Text('Not yet')),
          ]),
        ]);

    final readyText = shown.months == null ? 'Set a monthly amount' : (shown.months == 0 ? 'Now' : monthLong(shown.readyMonth!));
    final readyLine = shown.months == null
        ? 'Nothing goes into ${g.name} each month yet.'
        : (shown.months == 0
            ? 'You have the deposit and costs.'
            : 'in ${spanText(shown.months!)} at ${moneyExact(shown.monthly, cur)} a month${on.isEmpty ? '' : ' (with your changes)'}');

    final hero = Panel(key: const ValueKey('plannerHero'), children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Eyebrow('Ready to buy'),
        const SizedBox(height: 6),
        Text(readyText,
            key: const ValueKey('plannerReadyMonth'),
            style: const TextStyle(fontSize: 32, height: 1.15, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
        const SizedBox(height: 4),
        Text(readyLine, key: const ValueKey('plannerReadyLine'), style: TextStyle(fontSize: 14, color: c.muted)),
      ]),
      if (shown.months != null && shown.months! > 0)
        Semantics(
          label: 'Fund growing from ${moneyExact(shown.saved, cur)} to the needed ${moneyExact(shown.need, cur)} in ${shown.months} months',
          child: ExcludeSemantics(
            child: SizedBox(
              height: 140,
              child: CustomPaint(
                key: const ValueKey('plannerChart'),
                size: Size.infinite,
                painter: _FundPainter(
                    saved: shown.saved,
                    monthly: shown.monthly,
                    need: shown.need,
                    months: shown.months!,
                    span: math.max(24, shown.months! + 6),
                    fund: c.s6,
                    line: c.lineStrong,
                    muted: c.muted,
                    ring: c.surface,
                    needLabel: 'Needed ${moneyExact(shown.need, cur)}',
                    meetLabel: _monthYear(shown.readyMonth!),
                    endLabel: _monthYear(addMonths(monthOf(wc.today()), math.max(24, shown.months! + 6)))),
              ),
            ),
          ),
        ),
    ]);

    final inputs = Panel(key: const ValueKey('plannerInputs'), children: [
      _price(g, plan),
      ParamSlider(
        id: 'plannerDeposit',
        label: 'Deposit',
        valueText: '${permilleText(d.depositPermille)} · ${moneyExact(plan.deposit, cur)}',
        value: d.depositPermille / 10,
        min: 0,
        max: 100,
        divisions: 100,
        onChanged: (v) => _set(() => d.depositPermille = v.round() * 10),
        onEnd: (_) => _commit(),
        onType: () => _typeScaled('Deposit', 10, 1000, (v) => d.depositPermille = v),
      ),
      ParamSlider(
        id: 'plannerCosts',
        label: 'Costs on top',
        note: "one-off costs the loan doesn't cover",
        valueText: '${permilleText(d.costsPermille)} · ${moneyExact(plan.costs, cur)}',
        value: d.costsPermille / 10,
        min: 0,
        max: 20,
        divisions: 40,
        onChanged: (v) => _set(() => d.costsPermille = (v * 2).round() * 5),
        onEnd: (_) => _commit(),
        onType: () => _typeScaled('Costs on top', 10, 1000, (v) => d.costsPermille = v),
      ),
      _monthly(),
      if (financed) ...[
        ParamSlider(
          id: 'plannerRate',
          label: 'Loan rate',
          note: 'typed by you',
          valueText: rateBpText(d.rateBp ?? 0),
          value: (d.rateBp ?? 0) / 100,
          min: 0,
          max: 15,
          divisions: 150,
          onChanged: (v) => _set(() => d.rateBp = (v * 10).round() * 10),
          onEnd: (_) => _commit(),
          onType: () => _typeScaled('Loan rate', 100, 10000, (v) => d.rateBp = v),
        ),
        if (d.rateBp == null) const Muted('No rate yet: the payment is the loan divided by the months.', key: ValueKey('plannerNoRate')),
        _lengthChips(),
      ],
      if (_error != null) StatusLabel(key: const ValueKey('plannerError'), good: false, text: _error!),
    ]);

    final ledger = Panel(key: const ValueKey('plannerLedger'), children: [
      const Text('The numbers', style: BwType.heading),
      Rows(children: [
        LedgerRow(financed ? 'Deposit' : 'Price', moneyExact(plan.deposit, cur), key: const ValueKey('ledgerDeposit')),
        LedgerRow('Costs on top', moneyExact(plan.costs, cur), key: const ValueKey('ledgerCosts')),
        LedgerRow('Already in the fund', '−${moneyExact(plan.need - plan.left, cur)}', key: const ValueKey('ledgerSaved')),
        LedgerRow('Still to save', moneyExact(plan.left, cur), bold: true, key: const ValueKey('ledgerLeft')),
        if (financed) ...[
          LedgerRow(d.months == null ? 'Loan' : 'Loan, ${spanText(d.months!)}', moneyExact(plan.loan, cur),
              key: const ValueKey('ledgerLoan')),
          LedgerRow('Payment a month (estimate)', plan.payment == null ? 'Set a length' : moneyExact(plan.payment!, cur),
              key: const ValueKey('ledgerPayment')),
          if (plan.vsCompare != null)
            LedgerRow('vs ${compare.where((x) => x.$1 == d.compareId).firstOrNull?.$2 ?? 'that line'}',
                '${moneyExactSigned(plan.vsCompare!, cur)} a month',
                key: const ValueKey('ledgerVs')),
          if (plan.afterPerPeriod != null)
            LedgerRow('Spending money per period after', moneyExact(plan.afterPerPeriod!, cur), key: const ValueKey('ledgerAfter'))
          else if (plan.shortBy != null)
            LedgerRow('Spending money per period after', 'Short by ${moneyExact(plan.shortBy!, cur)}',
                key: const ValueKey('ledgerAfter'), valueColor: c.bad, leading: Icon(Icons.warning_amber_rounded, color: c.bad, size: 18)),
        ],
      ]),
      if (financed && compare.isNotEmpty)
        DropdownButtonFormField<String?>(
          key: const ValueKey('plannerCompare'),
          initialValue: compare.any((x) => x.$1 == d.compareId) ? d.compareId : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Compare the payment with'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Nothing')),
            for (final x in compare)
              DropdownMenuItem<String?>(value: x.$1, child: Text('${x.$2} · ${moneyExact(x.$3, cur)}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => _set(() => d.compareId = v, commit: true),
        ),
    ]);

    final sooner = levers.isEmpty
        ? null
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, key: const ValueKey('plannerLevers'), children: [
            Text.rich(TextSpan(children: [
              const TextSpan(text: 'Get there sooner', style: BwType.heading),
              TextSpan(text: ' · from your own data', style: TextStyle(fontSize: 13, color: c.muted)),
            ])),
            const SizedBox(height: 8),
            ...gapped([
              for (final l in levers) _leverChip(l, cur),
              if (on.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                      key: const ValueKey('leversUse'), onPressed: () => _useLevers(shown, g.name), child: const Text('Use this')),
                ),
            ], gap: 8),
          ]);

    return [
      if (ready && !_notYet) readyCard(),
      hero,
      inputs,
      ledger,
      if (sooner != null) sooner,
      if (!ready || _notYet)
        Align(
            alignment: Alignment.centerLeft,
            child:
                OutlinedButton(key: const ValueKey('plannerIBoughtLate'), onPressed: () => _bought(g), child: const Text('I bought it'))),
      const Muted("Estimate only. The lender's offer gives the exact numbers.", key: ValueKey('plannerFooter')),
    ];
  }

  /// "Jul 2030": a `YYYY-MM` for the chart (the year in full, so it never reads as a day).
  String _monthYear(String ym) => '${monthShort(ym)} ${ym.substring(0, 4)}';

  Widget _price(Goal g, GoalPlan plan) {
    final max = _priceMax;
    final step = _niceStep(max);
    return ParamSlider(
      id: 'plannerPrice',
      label: 'Price',
      valueText: moneyExact(d.price, wc.currency),
      value: d.price.toDouble(),
      min: 0,
      max: max,
      onChanged: (v) => _set(() => d.price = (v / step).round() * step.round()),
      onEnd: (_) => _commit(),
      onType: () => _typeMoney('Price', d.price, (v) => d.price = v),
    );
  }

  Widget _monthly() {
    final max = _monthlyMax;
    final step = _niceStep(max);
    return ParamSlider(
      id: 'plannerMonthly',
      label: 'Into the fund each month',
      valueText: moneyExact(d.monthly, wc.currency),
      value: d.monthly.toDouble(),
      min: 0,
      max: max,
      onChanged: (v) => _set(() => d.monthly = (v / step).round() * step.round()),
      onEnd: (_) => _commit(),
      onType: () => _typeMoney('Into the fund each month', d.monthly, (v) => d.monthly = v),
    );
  }

  Widget _lengthChips() {
    const years = [5, 10, 20, 30];
    final custom = d.months != null && !years.contains(d.months! ~/ 12) || (d.months ?? 0) % 12 != 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text.rich(TextSpan(children: [
        const TextSpan(text: 'Loan length', style: TextStyle(fontWeight: FontWeight.w600)),
        TextSpan(text: ' · ${d.months == null ? 'not set' : spanText(d.months!)}', style: TextStyle(fontSize: 13, color: context.c.muted)),
      ])),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final y in years)
          ChoiceChip(
              key: ValueKey('plannerLen:$y'),
              label: Text('$y y'),
              selected: d.months == y * 12,
              onSelected: (_) => _set(() => d.months = y * 12, commit: true)),
        ChoiceChip(
            key: const ValueKey('plannerLen:custom'), label: const Text('Custom'), selected: custom, onSelected: (_) => _customYears()),
      ]),
    ]);
  }

  Widget _leverChip(GoalLever l, String cur) {
    final c = context.c;
    final on = _levers.contains(l.key);
    final label = l.kind == GoalLeverKind.tag
        ? '${wc.leverLabel(l)} back to your usual (−${moneyExact(l.cut, cur)} / mo)'
        : 'Send ${wc.leverLabel(l)} to the fund (+${moneyExact(l.cut, cur)} / mo)';
    final gain = l.monthsSaved == null ? 'ready in ${spanText(l.months)}' : '${l.monthsSaved} mo sooner';
    return Semantics(
      toggled: on,
      button: true,
      child: InkWell(
        key: ValueKey('lever:${l.key}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => on ? _levers.remove(l.key) : _levers.add(l.key)),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? c.s6 : c.lineStrong, width: on ? 2 : 1),
              color: on ? c.accentSoft : null),
          child: SplitRow(
            start: Row(children: [
              if (on) ...[Icon(Icons.check, size: 18, color: c.ink), const SizedBox(width: 6)],
              Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
            end: Text(gain, textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: 13)),
            maxEnd: 0.4,
          ),
        ),
      ),
    );
  }
}

/// The fund line from today's saved total, the dashed "Needed" line and the dot where they meet. [saved], [monthly] and [need] are core's
/// cents; the painter only scales them to the box.
class _FundPainter extends CustomPainter {
  final int saved, monthly, need, months, span;
  final Color fund, line, muted, ring;
  final String needLabel, meetLabel, endLabel;
  const _FundPainter(
      {required this.saved,
      required this.monthly,
      required this.need,
      required this.months,
      required this.span,
      required this.fund,
      required this.line,
      required this.muted,
      required this.ring,
      required this.needLabel,
      required this.meetLabel,
      required this.endLabel});

  void _text(Canvas canvas, String t, Offset at, {double size = 11, TextAlign align = TextAlign.left}) {
    final p = TextPainter(
        text: TextSpan(text: t, style: TextStyle(color: muted, fontSize: size, fontFamily: monoFamily)), textDirection: TextDirection.ltr)
      ..layout();
    p.paint(canvas, align == TextAlign.right ? Offset(at.dx - p.width, at.dy) : at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const top = 18.0, axis = 16.0;
    final bottom = size.height - axis, w = size.width;
    final ymax = need * 1.15;
    double x(num m) => 2 + m / span * (w - 4);
    double y(num v) => bottom - math.min(v, ymax) / ymax * (bottom - top);
    final needY = y(need);
    // The "Needed" line, dashed.
    final dash = Paint()
      ..color = muted
      ..strokeWidth = 1.5;
    for (var dx = 0.0; dx < w; dx += 9) {
      canvas.drawLine(Offset(dx, needY), Offset(math.min(dx + 5, w), needY), dash);
    }
    _text(canvas, needLabel, Offset(4, needY - 16));
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w, bottom));
    canvas.drawLine(
        Offset(x(0), y(saved)),
        Offset(x(span), y(saved + monthly * span)),
        Paint()
          ..color = fund
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round);
    canvas.restore();
    canvas.drawCircle(Offset(x(months), needY), 6, Paint()..color = ring);
    canvas.drawCircle(Offset(x(months), needY), 4.5, Paint()..color = fund);
    // The ready month under the dot, kept inside the box: right-aligned on its right half.
    final mx = x(months);
    _text(canvas, meetLabel, Offset(mx > w / 2 ? mx + 4 : mx - 4, needY + 9), align: mx > w / 2 ? TextAlign.right : TextAlign.left);
    canvas.drawLine(
        Offset(0, bottom),
        Offset(w, bottom),
        Paint()
          ..color = line
          ..strokeWidth = 1);
    _text(canvas, 'now', Offset(0, bottom + 3), size: 10);
    _text(canvas, endLabel, Offset(w, bottom + 3), size: 10, align: TextAlign.right);
  }

  @override
  bool shouldRepaint(_FundPainter o) =>
      o.meetLabel != meetLabel ||
      o.saved != saved ||
      o.monthly != monthly ||
      o.need != need ||
      o.months != months ||
      o.span != span ||
      o.fund != fund ||
      o.muted != muted;
}
