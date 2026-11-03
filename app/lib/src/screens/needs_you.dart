// Needs you (ENG E7a, docs/context/ENG_UI_SPEC.md §3, mockups structure/Inbox.dc.html and Desktop.dc.html): one queue for every
// suggestion and open question. A card has one filled action, an outline alternative where the app already has one, and an Undo toast
// for an answer that can be taken back. Every action is the call the old tile or panel made; nothing new is written here. The list is
// the controller's `needsYouItems()`.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../tabs.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'accounts_panel.dart' show askBankBalance;
import 'bill_sheet.dart';
import 'bills_tab.dart' show openBillsPage;
import 'goal_planner.dart';
import 'key_backup.dart';
import 'plan_suggestions.dart' show proposalBasis, proposalLabel, proposalValue;
import 'review.dart';
import 'rules_panel.dart' show openRuleForm;
import 'setup_wizard.dart';
import 'sync_conflicts.dart';
import 'upcoming.dart';
import 'upcoming_view.dart';

/// The window width from which Overview has the queue as a standing pane on its right (HomeShell).
const needsYouPaneMin = 1280.0;

/// Opens the queue: a page on a phone, a dialog from [dialogMin] wide.
Future<void> openNeedsYou(BuildContext context, WalletController wc, {FileChooser chooser = const FileChooser()}) {
  logNav('needsYou.open', {'count': wc.needsYouCount()});
  return openPageOrDialog<void>(context, NeedsYouScreen(wc: wc, chooser: chooser), width: 560, maxHeight: 800, logName: 'NeedsYou');
}

class NeedsYouScreen extends StatelessWidget {
  final WalletController wc;
  final FileChooser chooser;
  const NeedsYouScreen({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: DialogAppBar(title: 'Needs you', actions: [
          Padding(
              padding: const EdgeInsets.only(right: pagePad),
              child: Center(child: ListenableBuilder(listenable: wc, builder: (context, _) => _Count(wc.needsYouCount())))),
        ]),
        body: NeedsYouList(wc: wc, chooser: chooser, onLeave: () => Navigator.of(context).maybePop()),
      );
}

/// The standing right pane of Overview from 1280 dp.
class NeedsYouPane extends StatelessWidget {
  final WalletController wc;
  final FileChooser chooser;
  const NeedsYouPane({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return DecoratedBox(
      key: const ValueKey('needsYouPane'),
      decoration: BoxDecoration(color: c.surface, border: Border(left: BorderSide(color: c.line))),
      child: ListenableBuilder(
        listenable: wc,
        builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: HeadingRow(const Text('Needs you', style: BwType.title), _Count(wc.needsYouCount())),
          ),
          Expanded(child: NeedsYouList(wc: wc, chooser: chooser)),
        ]),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  final int n;
  const _Count(this.n);
  @override
  Widget build(BuildContext context) =>
      Text(n == 0 ? 'None left' : '$n left', key: const ValueKey('needsYouCount'), style: numStyle.copyWith(color: context.c.ink2));
}

/// The cards. [onLeave] closes the page the list sits in before an action moves to another tab (null in the pane).
class NeedsYouList extends StatelessWidget {
  final WalletController wc;
  final FileChooser chooser;
  final VoidCallback? onLeave;
  const NeedsYouList({super.key, required this.wc, this.chooser = const FileChooser(), this.onLeave});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wc,
        builder: (context, _) {
          final items = wc.needsYouItems();
          final steps = wc.needsYouReviewSteps();
          final embedded = onLeave == null;
          return ListView(
            key: const ValueKey('needsYouList'),
            padding: EdgeInsets.fromLTRB(embedded ? 20 : pagePad, 12, embedded ? 20 : pagePad, pageBottomPad),
            children: gapped([
              if (steps.isNotEmpty) _ReviewProgress(steps: steps),
              if (items.isEmpty)
                const Panel(key: ValueKey('needsYouEmpty'), padding: EdgeInsets.symmetric(vertical: 20), children: [
                  Text('All decided', textAlign: TextAlign.center, style: BwType.heading),
                  Muted('Nothing needs you now.', align: TextAlign.center),
                ])
              else
                for (final it in items) NeedsYouCard(wc: wc, item: it, chooser: chooser, onLeave: onLeave),
            ], gap: 12),
          );
        },
      );
}

/// The weekly review as four steps, the first one not done marked "now".
class _ReviewProgress extends StatelessWidget {
  final List<NeedsYouStep> steps;
  const _ReviewProgress({required this.steps});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Panel(key: const ValueKey('needsYouReview'), children: [
      const HeadingRow(Text('Weekly review', style: BwType.heading), Muted('about 5 min')),
      Row(children: [
        for (final (i, s) in steps.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              label: '${s.label}, ${const ['to do', 'now', 'done'][s.state]}',
              excludeSemantics: true,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                    key: ValueKey('reviewStep:${s.label}:${s.state}'),
                    height: 4,
                    decoration: BoxDecoration(
                        color: s.state == 2 ? c.good : (s.state == 1 ? c.ink : c.line), borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 6),
                Text('${i + 1} · ${s.label}${s.state == 2 ? ' ✓' : ''}',
                    style: TextStyle(
                        fontSize: BwType.metaSize,
                        color: s.state == 1 ? c.ink : c.ink2,
                        fontWeight: s.state == 1 ? FontWeight.w600 : FontWeight.w400)),
              ]),
            ),
          ),
        ],
      ]),
    ]);
  }
}

/// (title, why) of a card; two kinds are worded with helpers that live in the screens.
({String title, String why}) _texts(WalletController wc, NeedsYouItem it) {
  switch (it.kind) {
    case NeedsYouKind.planProposal:
      final p = it.data! as SettingProposal;
      return (
        title: proposalLabel(p.key, wc.categoryTable),
        why: '${proposalValue(p, p.current, wc.currency)} → ${proposalValue(p, p.suggested, wc.currency)}. ${proposalBasis(p.basis)}'
      );
    case NeedsYouKind.review:
      return (title: it.title, why: reviewSummary(wc.reviewState()) ?? 'Nothing to fix. Import your latest files and tick it off.');
    default:
      return (title: it.title, why: it.why);
  }
}

class NeedsYouCard extends StatelessWidget {
  final WalletController wc;
  final NeedsYouItem item;
  final FileChooser chooser;
  final VoidCallback? onLeave;
  const NeedsYouCard({super.key, required this.wc, required this.item, this.chooser = const FileChooser(), this.onLeave});

  @override
  Widget build(BuildContext context) {
    final c = context.c, t = _texts(wc, item), id = item.id;
    return Container(
      key: ValueKey('needs:$id'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(cardRadius), border: Border.all(color: c.line)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: gapped([
            SplitRow(
              start: Align(alignment: Alignment.centerLeft, child: Tag(item.tag)),
              end: item.cents == null
                  ? const SizedBox.shrink()
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(moneyExact(item.cents!, wc.currency), style: numStyle.copyWith(fontWeight: FontWeight.w600))),
            ),
            Text(t.title, style: const TextStyle(fontSize: BwType.bodySize, fontWeight: FontWeight.w600)),
            if (t.why.isNotEmpty) Text(t.why, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(
                  key: ValueKey('needsPrimary:$id'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, touchMin)),
                  onPressed: () => _run(context, null),
                  child: Text(item.primary)),
              if (item.alt != null)
                OutlinedButton(
                    key: ValueKey('needsAlt:$id'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, touchMin)),
                    onPressed: () => _run(context, 'alt'),
                    child: Text(item.alt!)),
              for (final p in item.picks)
                OutlinedButton(
                    key: ValueKey('needsPick:$id:${p.id}'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, touchMin)),
                    onPressed: () => _run(context, p.id),
                    child: Text(p.label)),
            ]),
          ], gap: 8)),
    );
  }

  void _undo(BuildContext context, String msg, VoidCallback undo) => toast(context, msg, actionLabel: 'Undo', onAction: () {
        logNav('needs.undo', {'kind': item.kind.name});
        undo();
      });

  void _tab(int tab) {
    onLeave?.call();
    wc.openTab(tab, via: 'needsYou');
  }

  /// [which]: null = the filled action, 'alt', or a pick's id.
  Future<void> _run(BuildContext context, String? which) async {
    logNav('needs.action', {'kind': item.kind.name, 'which': which == null ? 'primary' : (which == 'alt' ? 'alt' : 'pick')});
    final d = item.data;
    switch (item.kind) {
      case NeedsYouKind.deviceStop || NeedsYouKind.newDevice:
        onLeave?.call();
        wc.openSettings(SettingsSection.sync, via: 'needsYou');
      case NeedsYouKind.conflicts:
        await openConflicts(context, wc);
      case NeedsYouKind.periodEnded || NeedsYouKind.newPayday:
        wc.startNewMonth(d! as String);
        toast(context, 'New period started');
      case NeedsYouKind.keyBackup:
        if (which == 'alt') {
          wc.snoozeKeyBackup();
          _undo(context, 'Reminder in 7 days', wc.unsnoozeKeyBackup);
        } else {
          await openKeyBackup(context, wc);
        }
      case NeedsYouKind.wizard:
        if (which == 'alt') {
          final before = wc.setupWizardState;
          wc.declineSetupWizard();
          _undo(context, 'Setup left out', () => wc.restoreSetupWizard(before));
        } else {
          await openSetupWizard(context, wc, chooser: chooser);
        }
      case NeedsYouKind.salary:
        if (which == 'alt') {
          wc.setPlanView('payday');
          _tab(Tabs.plan);
        } else {
          wc.updateSettings({'salaryConfirmed': true});
          _undo(context, 'Salary confirmed', () => wc.updateSettings({'salaryConfirmed': false}));
        }
      case NeedsYouKind.balance:
        final w = d! as BalanceWarning;
        if (which == 'alt') {
          _tab(Tabs.money);
        } else {
          await askBankBalance(
              context,
              wc,
              BankQuestion(
                  accountId: w.account.id,
                  name: w.account.name,
                  currency: w.account.currency,
                  date: wc.today(),
                  appCents: wc.appBalanceOn(w.account.id, wc.today())),
              fromImport: false);
        }
      case NeedsYouKind.billReview:
        await openBill(context, wc, (d! as Bill).id, chooser: chooser);
      case NeedsYouKind.plannedCategory:
        await openBill(context, wc, (d! as PlannedCost).sourceRef!, chooser: chooser);
      case NeedsYouKind.overdue:
        await openBillsPage(context, wc, chooser: chooser);
      case NeedsYouKind.review:
        await openReview(context, wc, chooser: chooser, openSpending: () {
          wc.setBudgetView('spending');
          _tab(Tabs.explore);
        });
      case NeedsYouKind.loanAsk:
        final a = d! as ({LoanPaymentMatch payment, List<Loan> loans});
        final tx = a.payment.txId;
        if (which == 'alt') {
          final err = wc.unlinkLoanPayment([for (final l in a.loans) l.id], tx);
          toast(context, err ?? 'Not a loan payment');
        } else {
          final to = which == null ? a.loans.first : a.loans.firstWhere((l) => l.id == which);
          final err = wc.confirmLoanPayment(to.id, tx);
          if (err != null) {
            toast(context, err);
          } else {
            // Core has no "unanswered" state: Undo answers No for this loan, so the row is not asked about again.
            _undo(context, 'Marked as a payment on ${to.name}', () => wc.unlinkLoanPayment([to.id], tx));
          }
        }
      case NeedsYouKind.goalReady:
        await openGoalPlanner(context, wc, (d! as Goal).id);
      case NeedsYouKind.loanEnded:
        final (e, firstGoal) = d! as (LoanEnded, String?);
        final goal = which == 'alt' ? null : (which ?? firstGoal);
        final err = wc.answerLoanEnded(e, goalId: goal);
        if (err != null) {
          toast(context, err);
        } else {
          _undo(context, goal == null ? 'Kept as spending money' : 'Added to your goal', () => wc.undoLoanEnded(e, goalId: goal));
        }
      case NeedsYouKind.planProposal:
        final p = d! as SettingProposal;
        if (which == 'alt') {
          wc.putOffPlanProposal(p.key);
          _undo(context, 'Not now', () => wc.restorePlanProposal(p.key));
        } else {
          final line = p.key.startsWith(WalletSettings.planPrefix);
          final salaryWas = wc.settings.salaryConfirmed;
          if (wc.acceptPlanProposals(only: {p.key}) > 0) {
            _undo(context, 'Plan updated', () {
              if (line) {
                wc.savePlanLines({p.key.substring(WalletSettings.planPrefix.length): p.current});
              } else {
                wc.updateSettings({p.key: p.current ?? 0, if (p.key == 'salary') 'salaryConfirmed': salaryWas});
              }
            });
          }
        }
      case NeedsYouKind.payeeRule:
        final pc = d! as PayeeCount;
        if (which == 'alt') {
          wc.dismissPayeeRecommendation(pc.merchantKey);
          _undo(context, 'Hidden on this device', () => wc.restorePayeeRecommendation(pc.merchantKey));
        } else {
          final tags = wc.setupMainTagIds();
          await openRuleForm(context, wc, payee: pc.merchantKey, category: tags.isEmpty ? null : tags.first);
        }
      case NeedsYouKind.ruleSuggest:
        final s = d! as RuleSuggestion;
        if (which == 'alt') {
          wc.dismissRuleSuggestion(s.merchantKey);
          _undo(context, 'Hidden on this device', () => wc.restoreRuleSuggestion(s.merchantKey));
        } else {
          wc.makeSuggestedRule(s);
          _undo(context, 'Rule made', () => wc.undoSuggestedRule(s));
        }
      case NeedsYouKind.headsUp:
        final h = d! as HeadsUp;
        final planned = h.item.planned;
        if (planned != null && planned.isBill) {
          await openBill(context, wc, planned.sourceRef!, chooser: chooser);
        } else {
          await openUpcoming(context, UpcomingView(wc));
        }
    }
  }
}
