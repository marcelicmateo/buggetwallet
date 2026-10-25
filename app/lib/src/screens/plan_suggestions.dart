import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The name of a plan setting as the Payday plan shows it.
String proposalLabel(String key, [CategoryTable? table]) => switch (key) {
      'salary' => 'Salary per month',
      'paydayDay' => 'Latest payday',
      'rent' => 'Rent',
      'loan' => 'Loan',
      'subs' => 'Bills & subs',
      _ when key.startsWith(WalletSettings.planPrefix) =>
        table?.label(key.substring(WalletSettings.planPrefix.length)) ?? key.substring(WalletSettings.planPrefix.length),
      _ => key,
    };

/// Where a suggestion comes from, in a few plain words (core's fixed `basis` keys).
String proposalBasis(String basis) => switch (basis) {
      'salaryRows' => 'From your last salary payments.',
      'paydayDates' => 'Your usual payday.',
      'rentRows' => 'From your rent payments.',
      'loanRows' => 'From your loan payments.',
      'confirmedBills' => 'From your confirmed bills.',
      'planRows' => 'From your payments in this category.',
      _ => 'From your imports.',
    };

/// A proposal value as text: money in the wallet's currency, a payday as "day 25".
String proposalValue(SettingProposal p, int? v, String currency) {
  if (v == null) return 'not set';
  return p.key == 'paydayDay' ? 'day $v' : moneyExact(v, currency);
}

/// Plan › Payday plan: "Suggestions from your imports". One row per plan value the imports point to that differs from the plan
/// (current → suggested, why), Accept / Not now per row and Accept all. Nothing is written without a tap; "Not now" hides a row
/// until its suggested value changes.
class PlanSuggestionsPanel extends StatelessWidget {
  final WalletController wc;
  const PlanSuggestionsPanel({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final proposals = wc.planProposalList();
    if (proposals.isEmpty) return const SizedBox.shrink();
    final cur = wc.currency;
    return Panel(key: const ValueKey('planSuggestions'), children: [
      const SectionHead('Suggestions from your imports'),
      Explainer(wc, 'planSuggestions', 'Worked out from your bank rows. Nothing changes until you accept it.'),
      Rows(children: [
        for (final p in proposals)
          Padding(
            key: ValueKey('proposal:${p.key}'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(proposalLabel(p.key, wc.categoryTable), style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text('${proposalValue(p, p.current, cur)} → ${proposalValue(p, p.suggested, cur)}',
                  key: ValueKey('proposalValue:${p.key}'), style: numStyle.copyWith(fontWeight: FontWeight.w500)),
              Text(proposalBasis(p.basis), style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
              const SizedBox(height: 4),
              Wrap(spacing: 8, runSpacing: 4, children: [
                OutlinedButton(
                    key: ValueKey('proposalAccept:${p.key}'),
                    style: accentOutlined(context),
                    onPressed: () => _accept(context, {p.key}),
                    child: const Text('Accept')),
                TextButton(
                    key: ValueKey('proposalLater:${p.key}'),
                    onPressed: () {
                      logNav('plan.suggestion.later', {'key': p.key.startsWith(WalletSettings.planPrefix) ? 'planLine' : p.key});
                      wc.putOffPlanProposal(p.key);
                    },
                    child: const Text('Not now')),
              ]),
            ]),
          ),
      ]),
      if (proposals.length > 1)
        FilledButton(key: const ValueKey('proposalAcceptAll'), onPressed: () => _accept(context, null), child: const Text('Accept all')),
    ]);
  }

  void _accept(BuildContext context, Set<String>? only) {
    logNav('plan.suggestion.accept', {'all': only == null});
    final n = wc.acceptPlanProposals(only: only);
    if (n > 0 && context.mounted) toast(context, n == 1 ? 'Plan updated' : 'Plan updated: $n values');
  }
}
