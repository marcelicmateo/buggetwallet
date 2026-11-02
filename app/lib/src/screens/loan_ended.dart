// A loan that was paid off (ENG E6, spec §5.5 step 5): "Your <name> loan of X a month has ended. Move X to savings or a goal?" on the Payday
// plan. Nothing moves until a tap; the answer hides the card, and Undo puts both back. The sum is core's (`loanEndedProposals`).
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../logging.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart';

class LoanEndedTile extends StatelessWidget {
  final WalletController wc;
  const LoanEndedTile({super.key, required this.wc});

  void _answer(BuildContext context, LoanEnded e, {Goal? goal}) {
    logNav('loan.ended.answer', {'goal': goal != null});
    final err = wc.answerLoanEnded(e, goalId: goal?.id);
    toast(context, err ?? (goal == null ? 'Kept as spending money' : 'Added to ${goal.name}'),
        actionLabel: err == null ? 'Undo' : null, onAction: err == null ? () => wc.undoLoanEnded(e, goalId: goal?.id) : null);
  }

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency;
    final goals = [
      for (final g in wc.goals)
        if (g.boughtAt == null) g
    ];
    return Tile(
      key: const ValueKey('planLoanEnded'),
      attention: true,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: gapped([
            const TileLabel('Loan paid off'),
            for (final e in wc.loanEnded())
              Column(
                  key: ValueKey('loanEnded:${e.loanId}'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: gapped([
                    Text(
                        'Your ${wc.loanOf(e.loanId)?.name ?? 'loan'} loan of ${moneyExact(e.payment, cur)} a month has ended. '
                        'Move ${moneyExact(e.payment, cur)} to savings or a goal?',
                        style: const TextStyle(height: 1.35)),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final g in goals)
                        OutlinedButton(
                            key: ValueKey('loanEndedGoal:${e.loanId}:${g.id}'),
                            onPressed: () => _answer(context, e, goal: g),
                            child: Text('Add to ${g.name}')),
                      TextButton(
                          key: ValueKey('loanEndedKeep:${e.loanId}'),
                          onPressed: () => _answer(context, e),
                          child: const Text('Keep as spending money')),
                    ]),
                  ], gap: 8)),
          ], gap: 10)),
    );
  }
}
