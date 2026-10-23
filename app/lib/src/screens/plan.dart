import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'backup_panel.dart';
import 'bills_panel.dart';
import 'budgets.dart';
import 'calendars_panel.dart';
import 'diagnostics.dart';
import 'export_panel.dart';
import 'forget_browser.dart';
import 'habits_panels.dart';
import 'import_flow.dart';
import 'key_backup.dart';
import 'sync_panel.dart';

class PlanScreen extends StatefulWidget {
  final WalletController wc;

  /// The system file and folder choosers (tests pass one that fails).
  final FileChooser chooser;

  /// Fires when Today's "Due by payday" line is tapped: the page then scrolls to Expected bills.
  final Listenable? showBills;

  /// Fires when Today's "N bills to review" line is tapped: the page then scrolls to Bills.
  final Listenable? showBillsDb;
  const PlanScreen({super.key, required this.wc, this.chooser = const FileChooser(), this.showBills, this.showBillsDb});
  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  static const _moneyKeys = {'salary', 'rent', 'loan', 'subs', 'impulse', 'rentCashThreshold'};
  static const _keys = ['salary', 'rent', 'loan', 'subs', 'impulse', 'coolHours', 'paydayDay', 'rentCashThreshold'];
  final Map<String, TextEditingController> f = {for (final k in _keys) k: TextEditingController()};

  /// The text each field last got from the settings. A field whose text differs was edited by the user:
  /// only those are saved, and only the others follow setting changes (sync, other screens).
  final Map<String, String> _shown = {};
  String currency = 'EUR';
  String _shownCurrency = 'EUR';
  bool importing = false;
  final _billsKey = GlobalKey();
  final _billsDbKey = GlobalKey();
  final _scroll = ScrollController();

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
    widget.showBills?.addListener(_scrollToBills);
    widget.showBillsDb?.addListener(_scrollToBillsDb);
  }

  /// Scrolls to Expected bills. A ListView builds only the rows near the window, so when the panel is not built yet the page
  /// is moved down a screen at a time until it is.
  Future<void> _scrollToBills() => _scrollTo(_billsKey);

  Future<void> _scrollToBillsDb() => _scrollTo(_billsDbKey);

  Future<void> _scrollTo(GlobalKey key) async {
    for (var i = 0; i < 12 && mounted; i++) {
      await WidgetsBinding.instance.endOfFrame;
      final c = key.currentContext;
      if (c != null && c.mounted) {
        await Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250));
        return;
      }
      if (!_scroll.hasClients || _scroll.position.pixels >= _scroll.position.maxScrollExtent) return;
      _scroll.jumpTo((_scroll.position.pixels + 400).clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  @override
  void didUpdateWidget(PlanScreen old) {
    super.didUpdateWidget(old);
    if (old.wc != widget.wc) {
      old.wc.removeListener(_onChange);
      widget.wc.addListener(_onChange);
      _fill(widget.wc.settings, force: true);
    }
    if (old.showBills != widget.showBills) {
      old.showBills?.removeListener(_scrollToBills);
      widget.showBills?.addListener(_scrollToBills);
    }
    if (old.showBillsDb != widget.showBillsDb) {
      old.showBillsDb?.removeListener(_scrollToBillsDb);
      widget.showBillsDb?.addListener(_scrollToBillsDb);
    }
  }

  @override
  void dispose() {
    widget.wc.removeListener(_onChange);
    widget.showBills?.removeListener(_scrollToBills);
    widget.showBillsDb?.removeListener(_scrollToBillsDb);
    _scroll.dispose();
    for (final c in f.values) {
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
    if (force || currency == _shownCurrency) currency = s.currency;
    _shownCurrency = s.currency;
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final s = wc.settings;
    final cur = wc.currency;
    final p = wc.period();
    final lowIncome = p.lowIncome;

    Widget field(String key, String label, {bool money = true}) {
      void changed(String _) {
        if (_errors.containsKey(key)) setState(() => _errors.remove(key));
      }

      final decoration =
          InputDecoration(labelText: label, suffixText: money ? currencySymbol(currency) : null, errorText: _errors[key], errorMaxLines: 3);
      return money
          ? MoneyField(controller: f[key]!, onChanged: changed, decoration: decoration)
          : TextField(
              controller: f[key],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.end,
              style: numStyle,
              onChanged: changed,
              decoration: decoration,
            );
    }

    return NarrowPage(
        child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, 24),
            children: gapped([
              Panel(children: [
                const SectionHead('Payday plan'),
                Heading(
                    p.planDaily <= 0
                        ? 'Nothing to spend: the plan is ${moneyExact(-p.flexBudget, cur)} over'
                        : '${money(p.flexBudget, cur, decimals: 0)} to spend · ${money(p.planDaily, cur, decimals: 0)}/day',
                    key: const ValueKey('planHeading')),
                const Muted('Salary minus bills minus savings. Whatever is left is your spending money until the next payday.'),
                Rows(children: [
                  LineItem('Salary ${s.incomeMode == 'received' && p.received > 0 ? '(received)' : '(planned)'}',
                      money(p.income, cur, decimals: 0)),
                  LineItem('Rent', money(-s.rent, cur, decimals: 0),
                      sub: 'Paid since payday: ${money(p.fixedPaid['Rent'] ?? 0, cur, decimals: 0)}'),
                  LineItem('Loan', money(-s.loan, cur, decimals: 0),
                      sub:
                          'Paid since payday: ${money(p.fixedPaid['Loan'] ?? 0, cur, decimals: 0)}${s.loanEnd != null ? ' · ends ${monthLong(s.loanEnd!)}' : ''}'),
                  LineItem('Bills & subscriptions', money(-s.subs, cur, decimals: 0),
                      sub: 'Paid since payday: ${money(p.fixedPaid['Bills & subscriptions'] ?? 0, cur, decimals: 0)}'),
                  for (final g in wc.goals) LineItem(g.name, money(-g.monthly, cur, decimals: 0), sub: 'savings goal'),
                ]),
                TotalRule(
                    padding: EdgeInsets.zero,
                    child: LineItem('Spending money', money(p.flexBudget, cur, decimals: 0),
                        bold: true, sub: '${p.length} days, ${shortDate(p.start)} to ${shortDate(addDays(p.end, -1))}')),
                if (lowIncome)
                  Panel(color: context.c.warnBg, children: [
                    Text(
                        'Salary received so far is ${money(p.received, cur, decimals: 0)}, below your planned ${money(s.salary, cur, decimals: 0)}.',
                        style: TextStyle(color: context.c.warnInk)),
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: 'planned', label: Text('Plan on ${money(s.salary, cur, decimals: 0)}')),
                        ButtonSegment(value: 'received', label: Text('Plan on ${money(p.received, cur, decimals: 0)}')),
                      ],
                      selected: {s.incomeMode},
                      onSelectionChanged: (v) => wc.updateSettings({'incomeMode': v.first}),
                    ),
                  ]),
              ]),
              Panel(children: [
                const SectionHead('Numbers'),
                Row(children: [
                  Expanded(child: field('salary', 'Salary per month')),
                  const SizedBox(width: 10),
                  Expanded(child: field('rent', 'Rent'))
                ]),
                Row(children: [
                  Expanded(child: field('loan', 'Loan')),
                  const SizedBox(width: 10),
                  Expanded(child: field('subs', 'Bills & subs'))
                ]),
                Row(children: [
                  Expanded(child: field('impulse', 'Wishlist above')),
                  const SizedBox(width: 10),
                  Expanded(child: field('coolHours', 'Wait (hours)', money: false))
                ]),
                Row(children: [
                  Expanded(child: field('paydayDay', 'Latest payday', money: false)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(currency),
                      isExpanded: true,
                      initialValue: currency,
                      decoration: const InputDecoration(labelText: 'Currency'),
                      items: [
                        for (final c in const ['EUR', 'USD', 'GBP', 'CHF']) DropdownMenuItem(value: c, child: Text(c))
                      ],
                      onChanged: (v) => setState(() => currency = v ?? currency),
                    ),
                  ),
                ]),
                field('rentCashThreshold', 'Cash withdrawal counts as rent from'),
                const Muted('ATM withdrawals this big or bigger count as rent. 0 turns it off.', size: 12),
                FilledButton(onPressed: _savePlan, child: const Text('Save numbers')),
              ]),
              KeyedSubtree(key: _billsKey, child: ExpectedBillsPanel(wc: wc)),
              KeyedSubtree(key: _billsDbKey, child: BillsPanel(wc: wc, chooser: widget.chooser)),
              BudgetsPanel(wc: wc),
              CalendarsPanel(wc: wc, chooser: widget.chooser),
              Panel(children: [
                const SectionHead('Month'),
                Muted(
                    'Your month runs from the day your salary lands. Started ${shortDate(p.start)}; next payday expected by ${shortDate(p.end)}.'),
                OutlinedButton.icon(
                  icon: const Icon(Icons.event_repeat),
                  label: const Text('Salary landed: start new month'),
                  onPressed: () async {
                    logNav('month.pick');
                    final d = await showDatePicker(context: context, initialDate: wc.now, firstDate: DateTime(2020), lastDate: wc.now);
                    if (d == null) return;
                    wc.startNewMonth(isoDate(d));
                    if (context.mounted) toast(context, 'New month started ${shortDate(isoDate(d))}');
                  },
                ),
              ]),
              Panel(children: [
                const SectionHead('Weekly review'),
                ReviewDayRow(wc: wc),
                const Heading('Import bank exports', size: 15),
                const Muted(
                    'PBZ: Excel export of the current account. Revolut: account statement as Excel or CSV. Importing the same dates twice is safe; nothing gets doubled. Expenses you added by hand are matched to the bank rows.'),
                OutlinedButton.icon(
                  style: accentOutlined(context),
                  icon: importing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.upload_file),
                  key: const ValueKey('planImport'),
                  label: const Text('Choose files'),
                  onPressed: importing ? null : _import,
                ),
                for (final l in wc.lastImport) StatusLabel(good: l.ok, text: '${l.file}: ${l.message}'),
              ]),
              if (!isWeb) NudgesPanel(wc: wc),
              SyncPanel(wc: wc, onShowKey: () => _showKey(context)),
              BackupPanel(wc: wc, chooser: widget.chooser),
              ExportPanel(wc: wc, chooser: widget.chooser),
              DiagnosticsPanel(wc: wc, chooser: widget.chooser),
              if (isWeb) _browserPanel(context),
            ])));
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
    if (errors.isNotEmpty) {
      logNav('plan.invalid', {'keys': errors.keys.join(',')}); // keys only
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
    if (currency != s.currency) changes['currency'] = currency;
    final now = s.toMap();
    changes.removeWhere((k, v) => now[k] == v);
    if (changes.containsKey('salary')) changes['salaryConfirmed'] = true;
    // Edited fields show the saved value (e.g. "1500.0" -> "1500", payday 31 -> 28) and are no longer "edited".
    for (final k in vals.keys) {
      final t = _text(WalletSettings.fromMap({...now, ...changes}), k);
      f[k]!.text = t;
      _shown[k] = t;
    }
    if (changes.isEmpty) {
      toast(context, 'Nothing to save');
      return;
    }
    widget.wc.updateSettings(changes);
    toast(context, 'Plan saved');
  }

  Future<void> _import() async {
    setState(() => importing = true);
    try {
      await pickAndImport(context, widget.wc, widget.chooser);
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  /// Web only: the wallet key, and "Forget this browser".
  Widget _browserPanel(BuildContext context) => Panel(children: [
        const SectionHead('This browser'),
        const Muted('The wallet is stored in this browser, on this computer only. Sync keeps it in step with your other devices; '
            'Backup moves it as a file. Clearing the browser data deletes it.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              key: const ValueKey('showKey'),
              icon: const Icon(Icons.key),
              label: const Text('Show wallet key'),
              onPressed: () => _showKey(context)),
          OutlinedButton.icon(
              key: const ValueKey('forgetBrowser'),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Forget this browser'),
              onPressed: () => confirmForgetBrowser(context, widget.wc)),
        ]),
      ]);

  Future<void> _showKey(BuildContext context) => showWalletKey(context, widget.wc);
}
