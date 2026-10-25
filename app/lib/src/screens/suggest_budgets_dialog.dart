import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../format.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Budgets Suggest for fields that already have a number: one row each (old → suggested) with a checkbox, "Accept all" and Cancel.
/// Pops the categories to change (null when cancelled).
class SuggestBudgetsDialog extends StatefulWidget {
  final List<BudgetProposal> proposals;
  final String currency;

  /// Where the names come from (null: the built-in names).
  final CategoryTable? table;
  const SuggestBudgetsDialog({super.key, required this.proposals, required this.currency, this.table});
  @override
  State<SuggestBudgetsDialog> createState() => _SuggestBudgetsDialogState();
}

class _SuggestBudgetsDialogState extends State<SuggestBudgetsDialog> {
  final Set<String> _on = {};

  @override
  Widget build(BuildContext context) {
    final cur = widget.currency;
    return AlertDialog(
      title: const Text('Change your budgets?'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Muted('These already have a number. Tick the ones to change.', size: BwType.bodySize),
            for (final p in widget.proposals)
              CheckboxListTile(
                key: ValueKey('suggestPick:${p.category}'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _on.contains(p.category),
                onChanged: (v) => setState(() => v == true ? _on.add(p.category) : _on.remove(p.category)),
                title: Text((widget.table ?? CategoryTable.builtIn).label(p.category)),
                subtitle: Text('${moneyExact(p.current!, cur)} → ${moneyExact(p.suggested, cur)}', style: numStyle),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(key: const ValueKey('suggestCancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
            key: const ValueKey('suggestAcceptAll'),
            onPressed: () => Navigator.pop(context, {for (final p in widget.proposals) p.category}),
            child: const Text('Accept all')),
        FilledButton(
            key: const ValueKey('suggestAccept'),
            onPressed: _on.isEmpty ? null : () => Navigator.pop(context, {..._on}),
            child: const Text('Accept ticked')),
      ],
    );
  }
}
