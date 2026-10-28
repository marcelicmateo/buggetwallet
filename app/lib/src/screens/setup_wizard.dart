// "Set up my wallet" (stage X, spec docs/context/X_SPEC.md): one guided page of eight steps after a new wallet and again from
// Settings. Each step shows what the app found and why; Accept (or a row's own button) writes only that step, Skip writes
// nothing. The steps reuse the controller methods of the panels they stand for (import, accounts, plan suggestions, bills,
// incomes, payee rules, budgets); no money is worked out here. Progress is device-local (`setupWizard` = `step:<n>`).
//
// Privacy: logs say the step and an action word (`setup.step {n, action}`), never a name or an amount.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/category_picker.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'accounts_panel.dart';
import 'import_flow.dart';
import 'plan_suggestions.dart';
import 'recurring_sheet.dart' show billPeriodText;
import 'today.dart' show shown;

/// Opens the wizard as a full-screen page (a dialog on wide windows). [restart]: from step 1 (Settings › Set up my wallet again);
/// otherwise where the last run stopped. A restart keeps no progress unless the wizard was already under way (a finished or declined
/// wallet must not get "Finish setting up" back on Today). Returns when it was closed.
Future<void> openSetupWizard(BuildContext context, WalletController wc, {FileChooser chooser = const FileChooser(), bool restart = false}) {
  final start = restart ? 1 : wc.setupWizardStep;
  final track = !restart || wc.setupWizardOpen;
  logNav('setup.open', {'step': start, 'restart': restart});
  return openPageOrDialog<void>(context, SetupWizard(wc: wc, chooser: chooser, start: start, restart: restart, track: track),
      width: 560, logName: 'setup.wizard');
}

const _titles = <int, String>{
  1: 'Your bank files',
  2: 'Your accounts',
  3: 'Your payday plan',
  4: 'Bills and subscriptions',
  5: 'Extra income',
  6: 'Payees without a main tag',
  7: 'Budgets',
  8: "Here's your wallet",
};

class SetupWizard extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;
  final int start;

  /// From Settings: the steps skipped by an earlier run are forgotten.
  final bool restart;

  /// Whether the step reached and the skipped steps are kept for resuming.
  final bool track;
  const SetupWizard(
      {super.key, required this.wc, this.chooser = const FileChooser(), this.start = 1, this.restart = false, this.track = true});
  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  late int _step = widget.start.clamp(1, setupWizardSteps);
  late final Set<int> _skipped = widget.restart ? {} : wc.setupSkippedSteps; // skipped with nothing done in them
  final Set<int> _acted = {}; // steps where something was written on this page
  bool _imported = false; // the owner picked files on this page: their result lines show

  WalletController get wc => widget.wc;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _shown());
  }

  void _shown() {
    if (!mounted) return;
    if (widget.track) {
      wc.saveSetupStep(_step);
      wc.saveSetupSkipped(_skipped);
    }
    wc.logSetupStep(_step, 'shown');
  }

  /// A step wrote something (a row accepted, cash added, a rule made): it does not count as skipped any more.
  void _act(int step, String action) {
    wc.logSetupStep(step, action, count: 1);
    _acted.add(step);
    _skipped.remove(step);
  }

  void _go(int n, String action) {
    wc.logSetupStep(_step, action);
    setState(() => _step = n.clamp(1, setupWizardSteps));
    _shown();
  }

  void _next() {
    _skipped.remove(_step);
    _go(_step + 1, 'next');
  }

  void _skip() {
    if (_step == 1) {
      // "Skip, I'll add payments by hand": nothing to find in, so the middle steps are left too.
      _skipped.addAll([
        for (var i = 1; i < setupWizardSteps; i++)
          if (!_acted.contains(i)) i
      ]);
      _go(setupWizardSteps, 'skip');
    } else {
      if (!_acted.contains(_step)) _skipped.add(_step);
      _go(_step + 1, 'skip');
    }
  }

  void _accepted(int n) {
    wc.logSetupStep(_step, 'accept', count: n);
    _acted.add(_step);
    _skipped.remove(_step);
    setState(() => _step = (_step + 1).clamp(1, setupWizardSteps));
    _shown();
  }

  void _finish() {
    wc.logSetupStep(_step, 'done');
    wc.finishSetupWizard();
    Navigator.pop(context);
  }

  /// The primary button of the step: the step's Accept when something waits for it, else Next.
  ({String label, Key key, VoidCallback onTap}) _primary() {
    ({String label, Key key, VoidCallback onTap}) accept(String label, int Function() act) =>
        (label: label, key: const ValueKey('setupAccept'), onTap: () => _accepted(act()));
    switch (_step) {
      case 3:
        final n = wc.planProposalList().length;
        if (n > 0) return accept(n == 1 ? 'Accept' : 'Accept all $n', () => wc.acceptPlanProposals());
      case 4:
        final ids = [
          for (final b in wc.expectedBills())
            if (b.status == 'candidate') b.id
        ];
        if (ids.isNotEmpty) {
          return accept(ids.length == 1 ? 'Confirm' : 'Confirm all ${ids.length}', () {
            ids.forEach(wc.confirmRecurring);
            return ids.length;
          });
        }
      case 5:
        final ids = [
          for (final b in wc.expectedIncomes())
            if (b.status == 'candidate') b.id
        ];
        if (ids.isNotEmpty) {
          return accept(ids.length == 1 ? 'Confirm' : 'Confirm all ${ids.length}', () {
            ids.forEach(wc.confirmRecurring);
            return ids.length;
          });
        }
      case 7:
        final n = wc.setupBudgetProposals().length;
        if (n > 0) return accept(n == 1 ? 'Accept' : 'Accept all $n', () => wc.acceptBudgetProposals());
      case 8:
        return (label: 'Done', key: const ValueKey('setupDone'), onTap: _finish);
    }
    return (label: 'Next', key: const ValueKey('setupNext'), onTap: _next);
  }

  Widget _body() => switch (_step) {
        1 => _ImportStep(
            wc: wc,
            imported: _imported,
            onPick: () async {
              await pickAndImport(context, wc, widget.chooser);
              if (mounted) setState(() => _imported = true);
            }),
        2 => _AccountsStep(wc: wc, act: _act),
        3 => _PlanStep(wc: wc, act: _act),
        4 => _BillsStep(wc: wc, act: _act),
        5 => _IncomeStep(wc: wc, act: _act),
        6 => _PayeesStep(wc: wc, act: _act),
        7 => _BudgetsStep(wc: wc, act: _act),
        _ => _DoneStep(wc: wc, skipped: _skipped, onGo: (n) => _go(n, 'goto')),
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const DialogAppBar(title: 'Set up my wallet'),
      body: ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final primary = _primary();
          return Column(key: const ValueKey('setupWizard'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Eyebrow('Step $_step of $setupWizardSteps'),
                const SizedBox(height: 2),
                Semantics(header: true, child: Heading(_titles[_step]!, key: const ValueKey('setupTitle'))),
              ]),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(pagePad, 4, pagePad, 12),
                child: KeyedSubtree(key: ValueKey('setupStep:$_step'), child: _body()),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: context.c.line))),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    FilledButton(
                        key: primary.key,
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
                        onPressed: primary.onTap,
                        child: Text(primary.label)),
                    const SizedBox(height: 4),
                    Wrap(alignment: WrapAlignment.spaceBetween, children: [
                      if (_step > 1)
                        TextButton.icon(
                            key: const ValueKey('setupBack'),
                            style: TextButton.styleFrom(minimumSize: const Size(48, touchMin)),
                            onPressed: () => _go(_step - 1, 'back'),
                            icon: const Icon(Icons.arrow_back, size: 18),
                            label: const Text('Back')),
                      if (_step < setupWizardSteps)
                        TextButton(
                            key: const ValueKey('setupSkip'),
                            style: TextButton.styleFrom(minimumSize: const Size(48, touchMin)),
                            onPressed: _skip,
                            child: Text(_step == 1 ? "Skip, I'll add payments by hand" : 'Skip')),
                    ]),
                  ]),
                ),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- step 1: import

class _ImportStep extends StatelessWidget {
  final WalletController wc;
  final bool imported;
  final Future<void> Function() onPick;
  const _ImportStep({required this.wc, required this.imported, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final n = wc.setupSummary().payments;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Muted('Pick the files you downloaded from your bank (PBZ, Revolut, or a CSV). They are read on this device. '
          'You see what comes in before it is added.'),
      const SizedBox(height: 12),
      if (n > 0) Text('Your wallet has $n payments.', key: const ValueKey('setupPaymentCount')),
      if (n > 0) const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
            key: const ValueKey('setupImport'),
            style: accentOutlined(context),
            onPressed: onPick,
            icon: const Icon(Icons.upload_file, size: 18),
            label: Text(imported ? 'Choose more files' : 'Choose bank files')),
      ),
      if (imported) ...[
        const SizedBox(height: 12),
        if (wc.lastImport.isEmpty)
          const Muted('No file was read.', key: ValueKey('setupImportNone'))
        else
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, l) in wc.lastImport.indexed)
              Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: StatusLabel(key: ValueKey('setupImported:$i'), good: l.ok, text: '${l.file}: ${l.message}')),
          ]),
      ],
    ]);
  }
}

// ---------------------------------------------------------------- step 2: accounts

class _AccountsStep extends StatefulWidget {
  final WalletController wc;
  final void Function(int step, String action) act;
  const _AccountsStep({required this.wc, required this.act});
  @override
  State<_AccountsStep> createState() => _AccountsStepState();
}

class _AccountsStepState extends State<_AccountsStep> {
  final _cash = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _cash.dispose();
    super.dispose();
  }

  Future<void> _addCash() async {
    final cents = parseMoney(_cash.text);
    if (cents == null) {
      setState(() => _error = invalidAmountMessage);
      return;
    }
    final wc = widget.wc;
    try {
      await wc.addAccount(name: 'Cash', currency: wc.currency, opening: cents, openingDate: wc.today());
      widget.act(2, 'accept');
      _cash.clear();
      if (mounted) setState(() => _error = null);
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final balances = [
      for (final b in wc.accountBalanceList())
        if (b.duplicateOf == null) b
    ];
    final cur = wc.currency;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Muted('One account for each bank file you added, with what it holds. Check it against your bank app, or add your cash.'),
      const SizedBox(height: 8),
      if (balances.isEmpty)
        const EmptyNote('No accounts yet. A bank file adds one, or add your cash below.')
      else
        Rows(children: [
          for (final b in balances)
            Padding(
              key: ValueKey('setupAccount:${b.account.id}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SplitRow(
                    start: Text(b.account.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                    end: MoneyText(moneyExact(b.balance, b.account.currency),
                        textAlign: TextAlign.end,
                        style: numStyle.copyWith(fontWeight: FontWeight.w500, color: b.balance < 0 ? context.c.bad : null))),
                Text(
                    b.account.isCash
                        ? 'Cash · ${b.account.currency}'
                        : wc.lastBankCheckOf(b.account.id) == null
                            ? '${b.account.currency} · not checked against the bank yet'
                            : '${b.account.currency} · checked against the bank',
                    style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                if (!b.account.isCash)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                        key: ValueKey('setupCheck:${b.account.id}'),
                        onPressed: () => askBankBalance(context, wc, wc.bankQuestionFor(b.account), fromImport: false),
                        child: const Text('What does your bank app show?')),
                  ),
              ]),
            ),
        ]),
      if (!wc.hasCashAccount) ...[
        const SizedBox(height: 12),
        const Heading('How much cash do you have?', size: BwType.headingSize),
        const SizedBox(height: 6),
        MoneyField(
          fieldKey: const ValueKey('setupCash'),
          controller: _cash,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: InputDecoration(
              labelText: 'Cash', suffixText: currencySymbol(cur), hintText: amountHint, errorText: _error, errorMaxLines: 3),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
              key: const ValueKey('setupCashAdd'), style: accentOutlined(context), onPressed: _addCash, child: const Text('Add cash')),
        ),
      ],
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
            key: const ValueKey('setupAccountAdd'),
            onPressed: () async {
              final n = wc.accountsAll().length;
              await openAddAccount(context, wc);
              if (wc.accountsAll().length > n) widget.act(2, 'accept');
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add another account')),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- step 3: payday plan

class _PlanStep extends StatelessWidget {
  final WalletController wc;
  final void Function(int step, String action) act;
  const _PlanStep({required this.wc, required this.act});

  @override
  Widget build(BuildContext context) {
    final proposals = wc.planProposalList();
    final cur = wc.currency;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Muted('Worked out from your bank rows. Nothing changes until you accept it.'),
      const SizedBox(height: 8),
      if (proposals.isEmpty)
        const EmptyNote('Nothing to suggest. Your plan matches what the imports show, or there are not enough rows yet.')
      else
        Rows(children: [
          for (final p in proposals)
            Padding(
              key: ValueKey('setupProposal:${p.key}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(proposalLabel(p.key, wc.categoryTable), style: const TextStyle(fontWeight: FontWeight.w500)),
                Text('${proposalValue(p, p.current, cur)} → ${proposalValue(p, p.suggested, cur)}',
                    key: ValueKey('setupProposalValue:${p.key}'), style: numStyle.copyWith(fontWeight: FontWeight.w500)),
                Text(proposalBasis(p.basis), style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                      key: ValueKey('setupProposalAccept:${p.key}'),
                      style: accentOutlined(context),
                      onPressed: () {
                        act(3, 'accept');
                        wc.acceptPlanProposals(only: {p.key});
                      },
                      child: const Text('Accept')),
                ),
              ]),
            ),
        ]),
    ]);
  }
}

// ---------------------------------------------------------------- steps 4 and 5: bills and extra income

String _billName(RecurringBill b) => b.label.isNotEmpty ? b.label : b.payee.replaceAll('_', ' ');

String _every(RecurringBill b) {
  final t = billPeriodText(b.intervalDays);
  return '${t[0].toUpperCase()}${t.substring(1)} · next about ${shortDateOrRaw(b.nextDue)}';
}

Widget _candidateRow(BuildContext context, RecurringBill b, String cur,
    {required String rowKey,
    required String confirmKey,
    required String dismissKey,
    required String dismissLabel,
    required VoidCallback onConfirm,
    required VoidCallback onDismiss}) {
  return Padding(
    key: ValueKey(rowKey),
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SplitRow(
          start: Text(_billName(b), style: const TextStyle(fontWeight: FontWeight.w500)),
          end: MoneyText(moneyExact(b.expectedAmount, cur),
              textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
      Text(_every(b), style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
      const SizedBox(height: 4),
      Wrap(spacing: 8, runSpacing: 4, children: [
        OutlinedButton(key: ValueKey(confirmKey), style: accentOutlined(context), onPressed: onConfirm, child: const Text('Confirm')),
        TextButton(key: ValueKey(dismissKey), onPressed: onDismiss, child: Text(dismissLabel)),
      ]),
    ]),
  );
}

class _BillsStep extends StatelessWidget {
  final WalletController wc;
  final void Function(int step, String action) act;
  const _BillsStep({required this.wc, required this.act});

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency;
    final bills = wc.expectedBills();
    final candidates = [
      for (final b in bills)
        if (b.status == 'candidate') b
    ];
    final confirmed = bills.where((b) => b.status == 'confirmed').length;
    final cost = wc.billsCost();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Muted('Payments that repeat. A confirmed bill is set aside from your daily money until it is paid.'),
      const SizedBox(height: 8),
      if (cost != null)
        Text(
            'Bills and subscriptions: ${cost.approximate ? 'about ' : ''}${moneyExact(cost.monthly, cur)} a month · '
            '${cost.approximate ? 'about ' : ''}${moneyExact(cost.yearly, cur)} a year',
            key: const ValueKey('setupBillsCost'),
            style: const TextStyle(fontWeight: FontWeight.w600)),
      if (confirmed > 0)
        Padding(padding: const EdgeInsets.only(top: 4), child: Muted('$confirmed confirmed.', key: const ValueKey('setupBillsConfirmed'))),
      if (candidates.isEmpty)
        const EmptyNote('No repeating bills found yet. They show up after a few months of imports.')
      else
        Rows(children: [
          for (final b in candidates)
            _candidateRow(context, b, cur,
                rowKey: 'setupBill:${b.id}',
                confirmKey: 'confirm:${b.id}',
                dismissKey: 'dismiss:${b.id}',
                dismissLabel: 'Not a bill', onConfirm: () {
              act(4, 'accept');
              wc.confirmRecurring(b.id);
            }, onDismiss: () {
              act(4, 'dismiss');
              wc.dismissRecurring(b.id);
            }),
        ]),
    ]);
  }
}

class _IncomeStep extends StatelessWidget {
  final WalletController wc;
  final void Function(int step, String action) act;
  const _IncomeStep({required this.wc, required this.act});

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency;
    final incomes = wc.expectedIncomes();
    final candidates = [
      for (final b in incomes)
        if (b.status == 'candidate') b
    ];
    final confirmed = incomes.where((b) => b.status == 'confirmed').length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Muted('Regular money that comes in besides your salary. It counts toward your spending money only once it lands.'),
      if (confirmed > 0)
        Padding(padding: const EdgeInsets.only(top: 4), child: Muted('$confirmed confirmed.', key: const ValueKey('setupIncomeConfirmed'))),
      const SizedBox(height: 8),
      if (candidates.isEmpty)
        const EmptyNote('No regular income found yet. It shows up after a few months of imports.')
      else
        Rows(children: [
          for (final b in candidates)
            _candidateRow(context, b, cur,
                rowKey: 'setupIncome:${b.id}',
                confirmKey: 'incomeConfirm:${b.id}',
                dismissKey: 'incomeDismiss:${b.id}',
                dismissLabel: 'Not income', onConfirm: () {
              act(5, 'accept');
              wc.confirmRecurring(b.id);
            }, onDismiss: () {
              act(5, 'dismiss');
              wc.dismissRecurring(b.id);
            }),
        ]),
    ]);
  }
}

// ---------------------------------------------------------------- step 6: payees

class _PayeesStep extends StatefulWidget {
  final WalletController wc;
  final void Function(int step, String action) act;
  const _PayeesStep({required this.wc, required this.act});
  @override
  State<_PayeesStep> createState() => _PayeesStepState();
}

class _PayeesStepState extends State<_PayeesStep> {
  // Read once: a payee stays in the list after its rule is made (it shows the tag), so the owner can change or undo it.
  late final List<PayeeCount> _payees = widget.wc.uncategorisedPayeeList();
  late final List<String> _ids = widget.wc.setupMainTagIds();
  final Map<String, String> _ruled = {};

  void _pick(PayeeCount p, String cat) {
    final wc = widget.wc;
    final before = _ruled[p.merchantKey]; // Undo goes back to this choice, or to none
    wc.makePayeeRule(p.merchantKey, cat);
    widget.act(6, 'accept');
    setState(() => _ruled[p.merchantKey] = cat);
    toast(context, 'Always put ${p.merchantName} in ${wc.categoryTable.label(cat)}', actionLabel: 'Undo', onAction: () {
      if (before == null) {
        wc.undoPayeeRule(p.merchantKey);
      } else {
        wc.makePayeeRule(p.merchantKey, before);
      }
      if (mounted) setState(() => before == null ? _ruled.remove(p.merchantKey) : _ruled[p.merchantKey] = before);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Muted('Payees with the most payments that have no main tag yet. Pick one and every payment from that payee goes there. '
          'Nothing is guessed from the amount.'),
      const SizedBox(height: 8),
      if (_payees.isEmpty)
        const EmptyNote('Every payee has a main tag already.')
      else
        Rows(children: [
          for (final p in _payees)
            Padding(
              key: ValueKey('setupPayee:${p.merchantKey}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SplitRow(
                    start: Text(p.merchantName, style: const TextStyle(fontWeight: FontWeight.w500)),
                    end: Text('${p.count} ${p.count == 1 ? 'payment' : 'payments'}',
                        textAlign: TextAlign.end, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2))),
                const SizedBox(height: 6),
                MainTagPicker(
                    dropdown: true,
                    table: wc.categoryTable,
                    ids: _ids,
                    selected: _ruled[p.merchantKey],
                    fieldKey: ValueKey('setupPayeeTag:${p.merchantKey}'),
                    onPick: (c) => _pick(p, c)),
                if (_ruled[p.merchantKey] != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: StatusLabel(
                          key: ValueKey('setupPayeeRule:${p.merchantKey}'),
                          good: true,
                          text: 'Always in ${wc.categoryTable.label(_ruled[p.merchantKey]!)}')),
              ]),
            ),
        ]),
    ]);
  }
}

// ---------------------------------------------------------------- step 7: budgets

class _BudgetsStep extends StatelessWidget {
  final WalletController wc;
  final void Function(int step, String action) act;
  const _BudgetsStep({required this.wc, required this.act});

  @override
  Widget build(BuildContext context) {
    final proposals = wc.setupBudgetProposals();
    final cur = wc.currency;
    final table = wc.categoryTable;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Muted('A monthly amount for each main tag, from your last 6 months. Nothing changes until you accept it.'),
      const SizedBox(height: 8),
      if (proposals.isEmpty)
        const EmptyNote('Nothing to suggest. Budgets need a few months of payments.')
      else
        Rows(children: [
          for (final p in proposals)
            Padding(
              key: ValueKey('setupBudget:${p.category}'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(table.label(p.category), style: const TextStyle(fontWeight: FontWeight.w500)),
                Text('${p.current == null ? 'not set' : moneyExact(p.current!, cur)} → ${moneyExact(p.suggested, cur)}',
                    style: numStyle.copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                      key: ValueKey('setupBudgetAccept:${p.category}'),
                      style: accentOutlined(context),
                      onPressed: () {
                        act(7, 'accept');
                        wc.acceptBudgetProposals(only: {p.category});
                      },
                      child: const Text('Accept')),
                ),
              ]),
            ),
        ]),
    ]);
  }
}

// ---------------------------------------------------------------- step 8: done

class _DoneStep extends StatelessWidget {
  final WalletController wc;
  final Set<int> skipped;
  final void Function(int) onGo;
  const _DoneStep({required this.wc, required this.skipped, required this.onGo});

  @override
  Widget build(BuildContext context) {
    final s = wc.setupSummary();
    final cur = wc.currency;
    final c = context.c;
    final bad = s.over && !s.ended;
    final left = [for (final n in skipped.toList()..sort()) n];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Eyebrow(s.label),
      TotalRule(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
        child: FittedBox(
          alignment: Alignment.centerLeft,
          fit: BoxFit.scaleDown,
          child: MoneyText(bad ? shown(s.hero, cur) : money(s.hero, cur, decimals: 0),
              key: const ValueKey('setupSafe'),
              style: numStyle.copyWith(
                  fontSize: BwType.heroSize, height: 0.95, fontWeight: FontWeight.w500, letterSpacing: -3, color: bad ? c.bad : c.ink)),
        ),
      ),
      LineItem(s.ended ? 'Payday was' : 'Next payday', shortDateOrRaw(s.payday), key: const ValueKey('setupPayday')),
      LineItem('Held for bills', moneyExact(s.billsHeld, cur), key: const ValueKey('setupBillsHeld')),
      const SizedBox(height: 12),
      const Heading('Accounts', size: BwType.headingSize),
      if (s.accounts.isEmpty)
        const EmptyNote('No accounts yet.')
      else
        Rows(children: [
          for (final b in s.accounts)
            Padding(
                key: ValueKey('setupDoneAccount:${b.account.id}'),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SplitRow(
                    start: Text(b.account.name),
                    end: MoneyText(moneyExact(b.balance, b.account.currency), textAlign: TextAlign.end, style: numStyle))),
        ]),
      if (left.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Heading('You skipped', size: BwType.headingSize),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final n in left)
            OutlinedButton(
                key: ValueKey('setupGoto:$n'), style: accentOutlined(context), onPressed: () => onGo(n), child: Text(_titles[n]!)),
        ]),
      ],
    ]);
  }
}
