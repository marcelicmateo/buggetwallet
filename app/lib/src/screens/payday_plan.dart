import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/charts.dart' show ForecastStepChart;
import '../widgets/common.dart';
import '../widgets/currency_picker.dart';
import '../widgets/dash.dart';
import '../widgets/sheets.dart';
import 'currency_offer.dart' show switchWalletCurrency;
import 'plan_suggestions.dart';

/// Budget › Payday plan (P5, UX-B1): the ledger lines, edited in place: a tap on a value turns that row into its field with Save and
/// Cancel (one at a time; core's refusal shows under the field), and the suggestions from the imports.
class PaydayPlan extends StatefulWidget {
  final WalletController wc;
  const PaydayPlan({super.key, required this.wc});
  @override
  State<PaydayPlan> createState() => _PaydayPlanState();
}

class _PaydayPlanState extends State<PaydayPlan> {
  static const _moneyKeys = {'salary', 'rent', 'loan', 'subs', 'impulse', 'rentCashThreshold'};
  static const _keys = ['salary', 'rent', 'loan', 'subs', 'impulse', 'coolHours', 'paydayDay', 'rentCashThreshold'];
  final Map<String, TextEditingController> f = {for (final k in _keys) k: TextEditingController()};

  /// The text each field last got from the settings. A field whose text differs was edited by the user:
  /// only those are saved, and only the others follow setting changes (sync, other screens).
  final Map<String, String> _shown = {};

  /// One field per plan line (P1: a fixed category of your own, by id), made when its category appears. Same rules as [f].
  final Map<String, TextEditingController> _pl = {};
  final Map<String, String> _plShown = {};

  /// The value being edited in place (a settings key, or `planLine_<id>`); null = none.
  String? _editKey;

  static const _labels = {
    'salary': 'Salary per month',
    'rent': 'Rent',
    'loan': 'Loan',
    'subs': 'Bills & subs',
    'impulse': 'Wishlist above',
    'coolHours': 'Wait (hours)',
    'paydayDay': 'Latest payday',
    'rentCashThreshold': 'Cash withdrawal counts as rent from',
  };

  /// Field errors from the last Save, by key (shown under the field until it is edited).
  final Map<String, String> _errors = {};

  static String _text(WalletSettings s, String k) {
    final v = s.toMap()[k] as int;
    return _moneyKeys.contains(k) ? centsToFieldText(v) : '$v';
  }

  @override
  void initState() {
    super.initState();
    _fill(widget.wc.settings, force: true);
    widget.wc.addListener(_onChange);
  }

  @override
  void didUpdateWidget(PaydayPlan old) {
    super.didUpdateWidget(old);
    if (old.wc != widget.wc) {
      old.wc.removeListener(_onChange);
      widget.wc.addListener(_onChange);
      _fill(widget.wc.settings, force: true);
    }
  }

  @override
  void dispose() {
    widget.wc.removeListener(_onChange);
    for (final c in f.values) {
      c.dispose();
    }
    for (final c in _pl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() => _fill(widget.wc.settings));
  }

  /// Shows [s] in every field the user has not edited ([force]: in every field).
  void _fill(WalletSettings s, {bool force = false}) {
    for (final k in _keys) {
      final t = _text(s, k), c = f[k]!;
      if ((force || c.text.trim() == _shown[k]) && c.text != t) c.text = t;
      _shown[k] = t;
    }
    for (final id in widget.wc.categoryTable.planLineIds) {
      final t = centsToFieldText(s.planLines[id] ?? 0, blankZero: true);
      final c = _pl.putIfAbsent(id, () => TextEditingController(text: t));
      if ((force || c.text.trim() == _plShown[id]) && c.text != t) c.text = t;
      _plShown[id] = t;
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: gapped(_dashboard(context, widget.wc)));

  /// The field of [key] (money: the wallet currency's sign is drawn always and read with the label, not as a node of its own: a lone
  /// "€" node cut by the scroll edge has no readable contrast).
  Widget _field(BuildContext context, String key, String label, {bool money = true, TextEditingController? ctl, Key? fieldKey}) {
    final sign = currencySymbol(widget.wc.currency);
    final decoration = InputDecoration(
        label: money ? Text(label, semanticsLabel: '$label, $sign') : null,
        labelText: money ? null : label,
        floatingLabelBehavior: money ? FloatingLabelBehavior.always : null,
        suffix: money ? ExcludeSemantics(child: Text(sign, style: numStyle.copyWith(color: context.c.ink2))) : null,
        errorText: _errors[key],
        errorMaxLines: 3);
    void changed(String _) {
      if (_errors.containsKey(key)) setState(() => _errors.remove(key));
    }

    return money
        ? MoneyField(controller: ctl ?? f[key]!, fieldKey: fieldKey, autofocus: true, onChanged: changed, decoration: decoration)
        : TextField(
            controller: f[key],
            autofocus: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.end,
            style: numStyle,
            onChanged: changed,
            decoration: decoration,
          );
  }

  /// The row of [key] as its field with Save and Cancel.
  Widget _editor(BuildContext context, String key) {
    final line = key.startsWith('planLine_');
    final id = line ? key.substring(9) : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        line
            ? _field(context, key, widget.wc.categoryTable.label(id), ctl: _pl[id], fieldKey: ValueKey(key))
            : _field(context, key, _labels[key]!, money: _moneyKeys.contains(key)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(key: const ValueKey('planSave'), onPressed: _savePlan, child: const Text('Save')),
          OutlinedButton(key: const ValueKey('planCancel'), onPressed: _cancelEdit, child: const Text('Cancel')),
        ]),
      ]),
    );
  }

  /// Ledger rows; the row whose edit key is [_editKey] is its editor. A row with a key is tappable and opens it.
  Widget _rows(BuildContext context, List<(String?, DashRowData)> rows) {
    final out = <Widget>[];
    var run = <DashRowData>[];
    void flush() {
      if (run.isNotEmpty) out.add(DashRows(rows: run));
      run = [];
    }

    for (final (k, r) in rows) {
      if (k != null && k == _editKey) {
        flush();
        out.add(_editor(context, k));
      } else {
        run.add(k == null
            ? r
            : DashRowData(
                title: r.title,
                amount: r.amount,
                sub: r.sub,
                chip: r.chip,
                key: r.key ?? ValueKey('planRow_$k'),
                onTap: () => _startEdit(k)));
      }
    }
    flush();
    return Column(mainAxisSize: MainAxisSize.min, children: out);
  }

  // ---------- the Plan dashboard (RX4) ----------

  /// Budget › Plan, not editing: the salary split (donut), per day, the suggestions tile, the plan lines and the forecast.
  List<Widget> _dashboard(BuildContext context, WalletController wc) {
    final s = wc.settings, cur = wc.currency, p = wc.period(), c = context.c;
    final proposals = wc.planProposalList();
    final loanLeft = wc.loanLeftNow();
    final planIds = wc.categoryTable.planLineIds;

    // Core's split of the money coming in: fixed (plan lines + bills and planned costs before payday), saved, spending (what is
    // left; none when the plan is over). fixed + saved + spending − over == inTotal, so the slices always add up.
    final split = p.planSplit;
    final fixed = split.fixed;
    final spending = p.flexBudget;
    // The state in icon + word; the amounts are in the legend and the lines (said once).
    final DashChip state = spending < 0
        ? const StateChip.over(key: ValueKey('planHeading'), text: 'Over the plan')
        : spending == 0
            ? const StateChip.over(key: ValueKey('planHeading'), text: 'Nothing to spend')
            : const StateChip.onPace(key: ValueKey('planHeading'), text: 'On plan');
    final segments = [
      DashSegment(label: 'Fixed', value: moneyExact(fixed, cur), weight: fixed.toDouble(), color: c.s2),
      DashSegment(label: 'Saved', value: moneyExact(split.saved, cur), weight: split.saved.toDouble(), color: c.s3),
      DashSegment(label: 'Spending', value: '', weight: split.spending.toDouble(), color: c.s1),
    ];

    // A fixed line is paid once what left the account for it since payday reaches the planned amount.
    DashRowData fixedLine(String id, String title, int cents, {Key? key, String? sub}) => DashRowData(
        key: key,
        title: title,
        amount: moneyExact(-cents, cur),
        sub: sub,
        chip: cents > 0 && (p.fixedPaid[id] ?? 0) >= cents ? const StateChip.onPace(text: 'Paid') : null);

    final before = p.beforePayday;
    final rows = <(String?, DashRowData)>[
      (
        'salary',
        DashRowData(
            title: 'Salary ${s.incomeMode == 'received' && p.received > 0 ? '(received)' : '(planned)'}', amount: moneyExact(p.income, cur))
      ),
      ('rent', fixedLine('Rent', 'Rent', s.rent)),
      (
        'loan',
        fixedLine('Loan', 'Loan', s.loan,
            key: loanLeft == null ? null : const ValueKey('ledgerLoanLeft'),
            sub: loanLeft == null
                ? null
                : '${loanLeft.payments} payment${loanLeft.payments == 1 ? '' : 's'} left · ${moneyExact(loanLeft.cents, cur)} at this rate')
      ),
      ('subs', fixedLine('Bills & subscriptions', 'Bills & subscriptions', s.subs)),
      for (final id in planIds)
        (
          'planLine_$id',
          fixedLine(id, wc.categoryTable.label(id), s.planLines[id] ?? 0,
              key: ValueKey('ledgerPlanLine_$id'), sub: (s.planLines[id] ?? 0) > 0 ? null : 'Not counted until you fill it in')
        ),
      for (final g in wc.goals) (null, DashRowData(title: g.name, amount: moneyExact(-g.monthly, cur))),
      if (p.landedIncome > 0)
        (null, DashRowData(key: const ValueKey('ledgerLandedIncome'), title: 'Extra in', amount: '+${moneyExact(p.landedIncome, cur)}')),
      if (before > 0)
        (
          null,
          DashRowData(
              key: const ValueKey('ledgerSetAside'),
              title: 'Before payday',
              amount: moneyExact(-before, cur),
              sub: '${p.beforePaydayCount} ${p.beforePaydayCount == 1 ? 'cost' : 'costs'}')
        ),
      (
        null,
        DashRowData(
            key: const ValueKey('ledgerSpendingMoney'),
            title: 'Spending money',
            sub: dateRange(p.start, p.end),
            amount: spending < 0 ? null : moneyExact(spending, cur),
            chip: spending < 0 ? StateChip.over(text: 'Over by ${moneyExact(-spending, cur)}') : null)
      ),
    ];

    // The numbers that are not part of the split: shown and edited here too.
    final other = <(String?, DashRowData)>[
      ('paydayDay', DashRowData(title: 'Latest payday', amount: 'Day ${s.paydayDay}')),
      ('impulse', DashRowData(title: 'Wishlist above', amount: moneyExact(s.impulse, cur))),
      ('coolHours', DashRowData(title: 'Wait before buying', amount: '${s.coolHours} h')),
      (
        'rentCashThreshold',
        DashRowData(
            title: 'Cash counts as rent from',
            sub: 'ATM withdrawals this big or bigger count as rent. 0 turns it off.',
            amount: s.rentCashThreshold == 0 ? 'Off' : moneyExact(s.rentCashThreshold, cur))
      ),
    ];

    final tiles = <Widget>[
      DashItem(
        span: 2,
        child: Tile(
          key: const ValueKey('planTile'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const TileLabel('Payday plan'),
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerLeft, child: state),
            const SizedBox(height: 10),
            Donut(
              segments: segments,
              size: 112,
              stroke: 14,
              // Slices from core's `planSplit`. The salary is in the Salary row and the spending in the Spending money row, so the
              // ring says each only once (here: Fixed and Saved with values).
            ),
          ]),
        ),
      ),
      DashItem(
          span: proposals.isEmpty ? 2 : 1,
          child: StatTile(
              key: const ValueKey('planPerDay'),
              label: 'Per day',
              value: moneyExact(p.planDaily > 0 ? p.planDaily : 0, cur),
              sub: '${p.length} days')),
      if (proposals.isNotEmpty)
        StatTile(
          key: const ValueKey('planSuggestionsTile'),
          label: 'Suggestions',
          value: '${proposals.length}',
          sub: 'from your imports',
          attention: true,
          chip: const TileNote('Review'),
          onTap: () {
            logNav('plan.suggestions.open');
            showSheet<void>(context, PlanSuggestionsSheet(wc: wc));
          },
        ),
      DashItem(
        span: 2,
        child: Tile(
          key: const ValueKey('planLines'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const TileLabel('Lines'),
            const SizedBox(height: 4),
            _rows(context, rows),
            if (p.expectedIncome.isNotEmpty)
              Padding(
                key: const ValueKey('ledgerExpectedIncome'),
                padding: const EdgeInsets.only(top: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final x in p.expectedIncome)
                    Text(
                        'Expected, not counted yet: ${x.bill.label.isNotEmpty ? x.bill.label : x.bill.payee.replaceAll('_', ' ')} '
                        '${moneyExact(x.amount, cur)} on ${shortDateOrRaw(x.due)}',
                        style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
                ]),
              ),
          ]),
        ),
      ),
      DashItem(
        span: 2,
        child: Tile(
          key: const ValueKey('planOther'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const TileLabel('Other numbers'),
            const SizedBox(height: 4),
            _rows(context, other),
            const SizedBox(height: 8),
            CurrencyField(
              key: const ValueKey('planCurrency'),
              wc: wc,
              value: wc.currency,
              choice: CurrencyChoice.fiat,
              // The same sheet as Settings › Accounts: it says what a switch does; it is not part of Save.
              onChanged: (v) => switchWalletCurrency(context, wc, v),
            ),
          ]),
        ),
      ),
      if (wc.paydayForecast() case final f?) DashItem(span: 2, child: ForecastTile(wc: wc, forecast: f)),
    ];
    return [
      DashGrid(children: tiles),
      if (p.lowIncome)
        Panel(color: c.warnBg, children: [
          Text('Salary received so far is ${moneyExact(p.received, cur)}, below your planned ${moneyExact(s.salary, cur)}.',
              style: TextStyle(color: c.warnInk)),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'planned', label: Text('Plan on ${moneyExact(s.salary, cur)}')),
              ButtonSegment(value: 'received', label: Text('Plan on ${moneyExact(p.received, cur)}')),
            ],
            selected: {s.incomeMode},
            onSelectionChanged: (v) => wc.updateSettings({'incomeMode': v.first}),
          ),
        ]),
    ];
  }

  /// Opens [key] as its field; whatever was typed in another one is dropped.
  void _startEdit(String key) {
    logNav('plan.edit', {'field': key.startsWith('planLine_') ? 'planLine' : key});
    setState(() {
      _errors.clear();
      _fill(widget.wc.settings, force: true);
      _editKey = key;
    });
  }

  /// Back to the ledger lines; the fields show the saved values again.
  void _cancelEdit() {
    logNav('plan.cancel');
    setState(() {
      _errors.clear();
      _fill(widget.wc.settings, force: true);
      _editKey = null;
    });
  }

  /// Saves only the fields the user edited, on top of the latest settings, so changes made elsewhere
  /// (another screen, another device) are kept.
  void _savePlan() {
    final s = widget.wc.settings;
    final vals = <String, int?>{
      for (final k in _keys)
        if (f[k]!.text.trim() != _shown[k]) k: _moneyKeys.contains(k) ? parseMoney(f[k]!.text) : int.tryParse(f[k]!.text.trim()),
    };
    // parseMoney already rejects negative amounts; whole-number fields can't be negative either.
    final errors = <String, String>{
      for (final e in vals.entries)
        if (e.value == null) e.key: 'Numbers only' else if (e.value! < 0) e.key: "Can't be negative",
    };
    // Plan lines: only the edited ones; an emptied field removes the line, 0 on a missing line is no change.
    final lines = <String, int?>{};
    for (final id in widget.wc.categoryTable.planLineIds) {
      final c = _pl[id];
      if (c == null || c.text.trim() == _plShown[id]) continue;
      final text = c.text.trim();
      final cents = text.isEmpty ? null : parseMoney(text);
      if (text.isNotEmpty && cents == null) {
        errors['planLine_$id'] = 'Numbers only';
        continue;
      }
      if (cents == s.planLines[id] || (cents == 0 && !s.planLines.containsKey(id))) continue;
      lines[id] = cents;
    }
    if (errors.isNotEmpty) {
      // Setting keys only; a plan line is `planLine` (its key holds an own category's id).
      logNav('plan.invalid', {
        'keys': {for (final k in errors.keys) k.startsWith('planLine_') ? 'planLine' : k}.join(',')
      });
      setState(() => _errors
        ..clear()
        ..addAll(errors));
      toast(
          context,
          errors.containsKey('coolHours') && errors['coolHours'] != 'Numbers only'
              ? "Wait (hours) can't be negative."
              : invalidAmountMessage);
      return;
    }
    if (_errors.isNotEmpty) setState(_errors.clear);
    final changes = <String, Object?>{...vals};
    // A typed payday is kept within 1-28 before saving (45 → 28). Core clamps only stored 29-31 to 28 and reads anything
    // else stored as 15, which suits a bad value from sync, not what the owner just typed.
    if (changes['paydayDay'] case final int d) changes['paydayDay'] = d.clamp(1, 28);
    final now = s.toMap();
    changes.removeWhere((k, v) => now[k] == v);
    if (changes.containsKey('salary')) changes['salaryConfirmed'] = true;
    // Edited fields show the saved value (e.g. "1500.0" -> "1500", payday 31 -> 28) and are no longer "edited".
    for (final k in vals.keys) {
      final t = _text(WalletSettings.fromMap({...now, ...changes}, table: widget.wc.categoryTable), k);
      f[k]!.text = t;
      _shown[k] = t;
    }
    for (final id in _pl.keys) {
      // Edited lines show the saved value; an edit that was no change goes back to what is stored.
      final t = centsToFieldText((lines.containsKey(id) ? lines[id] : s.planLines[id]) ?? 0, blankZero: true);
      _pl[id]!.text = t;
      _plShown[id] = t;
    }
    if (changes.isEmpty && lines.isEmpty) {
      setState(() => _editKey = null);
      toast(context, 'Nothing to save');
      return;
    }
    if (lines.isNotEmpty) widget.wc.savePlanLines(lines);
    if (changes.isNotEmpty) widget.wc.updateSettings(changes);
    setState(() => _editKey = null);
    toast(context, 'Plan saved');
  }
}

/// Budget › Plan, the forecast tile (Q11): "On payday, after bills" with the exact balance, the balance after the daily allowance, the
/// steps that lead there and a note when an account was left out. Shown only when a bank account in the wallet currency has a balance
/// the app trusts (confirmed lately).
class ForecastTile extends StatelessWidget {
  final WalletController wc;
  final PaydayForecast forecast;
  const ForecastTile({super.key, required this.wc, required this.forecast});

  @override
  Widget build(BuildContext context) {
    final f = forecast, cur = wc.currency, c = context.c;
    final below = f.onPayday < 0;
    return Tile(
      key: const ValueKey('forecastPanel'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const TileLabel('On payday, after bills'),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(moneyExact(f.onPayday, cur),
              key: const ValueKey('forecastLine'), maxLines: 1, style: dashNumStyle(color: below ? c.bad : null)),
        ),
        if (below) const Padding(padding: EdgeInsets.only(top: 6), child: StateChip.over(text: 'Below zero')),
        if (f.afterSpending != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('After daily spending ${moneyExact(f.afterSpending!, cur)}',
                key: const ValueKey('forecastAfter'), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
          ),
        if (f.points.length > 1 || f.points.first.cents != 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(
              label: 'Balance until payday',
              child: ForecastStepChart(key: const ValueKey('forecastChart'), points: f.points, payday: f.payday, currency: cur),
            ),
          ),
        if (f.leftOut != null)
          Padding(padding: const EdgeInsets.only(top: 6), child: Muted(_capital(f.leftOut!), key: const ValueKey('forecastUnchecked'))),
      ]),
    );
  }
}

String _capital(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}.';
