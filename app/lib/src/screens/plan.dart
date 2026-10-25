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
import 'accounts_panel.dart';
import 'backup_panel.dart';
import 'bills_panel.dart';
import 'budgets.dart';
import 'calendars_panel.dart';
import 'categories_panel.dart';
import 'diagnostics.dart';
import 'export_panel.dart';
import 'forget_browser.dart';
import 'habits_panels.dart';
import 'import_flow.dart';
import 'join_another.dart';
import 'key_backup.dart';
import 'look_panel.dart';
import 'plan_suggestions.dart';
import 'rules_panel.dart';
import 'sync_panel.dart';
import 'tags_panel.dart';

class PlanScreen extends StatefulWidget {
  final WalletController wc;

  /// The system file and folder choosers (tests pass one that fails).
  final FileChooser chooser;

  /// Fires when Today's "Due by payday" line is tapped: the page then scrolls to Expected bills.
  final Listenable? showBills;

  /// Fires when Today's "N bills to review" line is tapped: the page then scrolls to Bills.
  final Listenable? showBillsDb;

  /// Fires when Today's "Held" line is tapped: the page then scrolls to Accounts.
  final Listenable? showAccounts;
  const PlanScreen({super.key, required this.wc, this.chooser = const FileChooser(), this.showBills, this.showBillsDb, this.showAccounts});
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

  /// One field per plan line (P1: a fixed category of your own, by id), made when its category appears. Same rules as [f].
  final Map<String, TextEditingController> _pl = {};
  final Map<String, String> _plShown = {};
  String currency = 'EUR';
  String _shownCurrency = 'EUR';
  bool importing = false;

  /// Payday plan shows the ledger lines; Edit turns them into the fields (Save / Cancel go back).
  bool _editing = false;
  final _billsKey = GlobalKey();
  final _billsDbKey = GlobalKey();
  final _accountsKey = GlobalKey();
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
    widget.showAccounts?.addListener(_scrollToAccounts);
  }

  /// Scrolls to Expected bills. A ListView builds only the rows near the window, so when the panel is not built yet the page
  /// is moved down a screen at a time until it is.
  Future<void> _scrollToBills() => _scrollTo(_billsKey);

  Future<void> _scrollToBillsDb() => _scrollTo(_billsDbKey);

  Future<void> _scrollToAccounts() => _scrollTo(_accountsKey);

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
    if (old.showAccounts != widget.showAccounts) {
      old.showAccounts?.removeListener(_scrollToAccounts);
      widget.showAccounts?.addListener(_scrollToAccounts);
    }
  }

  @override
  void dispose() {
    widget.wc.removeListener(_onChange);
    widget.showBills?.removeListener(_scrollToBills);
    widget.showBillsDb?.removeListener(_scrollToBillsDb);
    widget.showAccounts?.removeListener(_scrollToAccounts);
    _scroll.dispose();
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
    final planIds = wc.categoryTable.planLineIds;

    Widget field(String key, String label, {bool money = true, TextEditingController? ctl, Key? fieldKey}) {
      void changed(String _) {
        if (_errors.containsKey(key)) setState(() => _errors.remove(key));
      }

      // The currency sign is drawn always (the label stays floated) and read with the label, not as a node of its own: a lone "€"
      // node cut by the scroll edge has no readable contrast.
      final sign = currencySymbol(currency);
      final decoration = InputDecoration(
          label: money ? Text(label, semanticsLabel: '$label, $sign') : null,
          labelText: money ? null : label,
          floatingLabelBehavior: money ? FloatingLabelBehavior.always : null,
          suffix: money ? ExcludeSemantics(child: Text(sign, style: numStyle.copyWith(color: context.c.ink2))) : null,
          errorText: _errors[key],
          errorMaxLines: 3);
      return money
          ? MoneyField(controller: ctl ?? f[key]!, fieldKey: fieldKey, onChanged: changed, decoration: decoration)
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
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
            children: gapped([
              if (_editing)
                Panel(children: [
                  const SectionHead('Payday plan'),
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
                  const Muted('ATM withdrawals this big or bigger count as rent. 0 turns it off.', size: BwType.metaSize),
                  for (final id in planIds) ...[
                    field('planLine_$id', wc.categoryTable.label(id), ctl: _pl[id], fieldKey: ValueKey('planLine_$id')),
                    if (id == planIds.last)
                      const Muted('Your own fixed main tags: what you spend on each every month.', size: BwType.metaSize),
                  ],
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton(key: const ValueKey('planSave'), onPressed: _savePlan, child: const Text('Save')),
                    OutlinedButton(key: const ValueKey('planCancel'), onPressed: _cancelEdit, child: const Text('Cancel')),
                  ]),
                ])
              else
                Panel(children: [
                  SectionHead('Payday plan',
                      trailing: TextButton.icon(
                          key: const ValueKey('planEdit'),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text('Edit'),
                          onPressed: _startEdit)),
                  Heading(
                      p.flexBudget < 0
                          ? 'Nothing to spend: the plan is ${moneyExact(-p.flexBudget, cur)} over'
                          : p.flexBudget == 0
                              ? 'Nothing to spend: the plan leaves no spending money'
                              : '${moneyExact(p.flexBudget, cur)} to spend · ${moneyExact(p.planDaily, cur)}/day',
                      key: const ValueKey('planHeading')),
                  const Muted('Salary minus bills minus savings. Whatever is left is your spending money until the next payday.'),
                  Rows(children: [
                    LineItem(
                        'Salary ${s.incomeMode == 'received' && p.received > 0 ? '(received)' : '(planned)'}', moneyExact(p.income, cur)),
                    LineItem('Rent', moneyExact(-s.rent, cur), sub: 'Paid since payday: ${moneyExact(p.fixedPaid['Rent'] ?? 0, cur)}'),
                    LineItem('Loan', moneyExact(-s.loan, cur),
                        sub:
                            'Paid since payday: ${moneyExact(p.fixedPaid['Loan'] ?? 0, cur)}${s.loanEnd != null ? ' · ends ${monthLong(s.loanEnd!)}' : ''}'),
                    LineItem('Bills & subscriptions', moneyExact(-s.subs, cur),
                        sub: 'Paid since payday: ${moneyExact(p.fixedPaid['Bills & subscriptions'] ?? 0, cur)}'),
                    for (final id in planIds)
                      LineItem(wc.categoryTable.label(id), moneyExact(-(s.planLines[id] ?? 0), cur),
                          key: ValueKey('ledgerPlanLine_$id'),
                          sub: 'Paid since payday: ${moneyExact(p.fixedPaid[id] ?? 0, cur)}'
                              '${(s.planLines[id] ?? 0) > 0 ? '' : '\nNot taken off your daily money until you fill this in.'}'),
                    for (final g in wc.goals) LineItem(g.name, moneyExact(-g.monthly, cur), sub: 'savings goal'),
                    // P9: money from a confirmed recurring income that has landed is spending money; one not landed yet is only listed.
                    if (p.landedIncome > 0)
                      LineItem('Extra income received', '+${moneyExact(p.landedIncome, cur)}',
                          key: const ValueKey('ledgerLandedIncome'), sub: 'Regular income that is in; it is spending money now'),
                    if (p.expectedIncome.isNotEmpty)
                      Padding(
                        key: const ValueKey('ledgerExpectedIncome'),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          for (final x in p.expectedIncome)
                            Text(
                                'Expected, not counted yet: ${x.bill.label.isNotEmpty ? x.bill.label : x.bill.payee.replaceAll('_', ' ')} '
                                '${moneyExact(x.amount, cur)} on ${shortDateOrRaw(x.due)}',
                                style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                        ]),
                      ),
                    // Bills and planned costs due before payday come off the spending money too: the rows add up to the total.
                    if (p.reservedBills + p.reservedPlanned > 0)
                      LineItem('Set aside for coming costs', moneyExact(-(p.reservedBills + p.reservedPlanned), cur),
                          key: const ValueKey('ledgerSetAside'), sub: 'Bills and planned costs due before payday'),
                  ]),
                  TotalRule(
                      padding: EdgeInsets.zero,
                      child: LineItem(
                          'Spending money', p.flexBudget < 0 ? 'Over by ${moneyExact(-p.flexBudget, cur)}' : moneyExact(p.flexBudget, cur),
                          key: const ValueKey('ledgerSpendingMoney'),
                          valueColor: p.flexBudget < 0 ? context.c.bad : null,
                          bold: true,
                          sub: '${p.length} days, ${shortDate(p.start)} to ${shortDate(addDays(p.end, -1))}')),
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
              PlanSuggestionsPanel(wc: wc),
              KeyedSubtree(key: _accountsKey, child: AccountsPanel(wc: wc)),
              KeyedSubtree(key: _billsKey, child: ExpectedBillsPanel(wc: wc)),
              ExpectedIncomePanel(wc: wc),
              KeyedSubtree(key: _billsDbKey, child: BillsPanel(wc: wc, chooser: widget.chooser)),
              CategoriesPanel(key: const ValueKey('categoriesPanel'), wc: wc),
              TagsPanel(key: const ValueKey('tagsPanel'), wc: wc),
              RulesPanel(key: const ValueKey('rulesPanel'), wc: wc),
              BudgetsPanel(key: const ValueKey('budgetsPanel'), wc: wc),
              CalendarsPanel(key: const ValueKey('calendarsPanel'), wc: wc, chooser: widget.chooser),
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
                const Heading('Import bank exports', size: BwType.headingSize),
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
              if (!isWeb)
                Panel(children: [
                  const SectionHead('Another wallet'),
                  const Muted('Have a wallet on another device? Join it here. This wallet is set aside on this device first, not deleted.'),
                  OutlinedButton.icon(
                    key: const ValueKey('joinAnother'),
                    icon: const Icon(Icons.login),
                    label: const Text('Join another wallet…'),
                    onPressed: () => joinAnotherWallet(context, wc),
                  ),
                ]),
              BackupPanel(wc: wc, chooser: widget.chooser),
              ExportPanel(wc: wc, chooser: widget.chooser),
              LookPanel(wc: wc),
              DiagnosticsPanel(wc: wc, chooser: widget.chooser),
              if (isWeb) _browserPanel(context),
            ])));
  }

  void _startEdit() {
    logNav('plan.edit');
    setState(() => _editing = true);
  }

  /// Back to the ledger lines; the fields show the saved values again.
  void _cancelEdit() {
    logNav('plan.cancel');
    setState(() {
      _errors.clear();
      _fill(widget.wc.settings, force: true);
      _editing = false;
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
    if (currency != s.currency) changes['currency'] = currency;
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
      setState(() => _editing = false);
      toast(context, 'Nothing to save');
      return;
    }
    if (lines.isNotEmpty) widget.wc.savePlanLines(lines);
    if (changes.isNotEmpty) widget.wc.updateSettings(changes);
    setState(() => _editing = false);
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
