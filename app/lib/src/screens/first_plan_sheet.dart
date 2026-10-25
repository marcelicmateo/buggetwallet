import 'package:flutter/material.dart';

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'plan_suggestions.dart';

/// After the first import that leaves plan suggestions (P13 §4): "Looks right?" with what the imports point to (salary, payday, rent,
/// loan, subscriptions, plan lines), a sentence for each, and Accept all / Choose… / Not now: the same actions as Plan › Suggestions.
/// Shown once per wallet (the controller marks it); Plan › Suggestions stays ("Not now" here hides the same rows there). Returns after the sheet closed.
Future<void> offerFirstPlan(BuildContext context, WalletController wc) async {
  if (!wc.shouldOfferFirstPlan()) return;
  wc.markFirstPlanShown();
  logNav('plan.firstSheet.show');
  await showSheet<void>(context, FirstPlanSheet(wc: wc));
}

class FirstPlanSheet extends StatefulWidget {
  final WalletController wc;
  const FirstPlanSheet({super.key, required this.wc});
  @override
  State<FirstPlanSheet> createState() => _FirstPlanSheetState();
}

class _FirstPlanSheetState extends State<FirstPlanSheet> {
  bool _choosing = false;
  late final _proposals = widget.wc.planProposalList();
  late final Set<String> _ticked = {for (final p in _proposals) p.key};

  void _accept(Set<String>? only) {
    logNav('plan.firstSheet.accept', {'all': only == null, 'count': only?.length ?? _proposals.length});
    final n = widget.wc.acceptPlanProposals(only: only);
    if (n > 0) toast(context, n == 1 ? 'Plan updated' : 'Plan updated: $n values');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final cur = wc.currency;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      const Heading('Looks right?', key: ValueKey('firstPlanHeading')),
      const SizedBox(height: 6),
      const Muted('Worked out from your bank rows. Nothing changes until you accept it.'),
      const SizedBox(height: 8),
      Rows(children: [
        for (final p in _proposals)
          Padding(
            key: ValueKey('firstPlan:${p.key}'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_choosing)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Checkbox(
                    key: ValueKey('firstPlanTick:${p.key}'),
                    value: _ticked.contains(p.key),
                    onChanged: (v) => setState(() => v == true ? _ticked.add(p.key) : _ticked.remove(p.key)),
                  ),
                ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(proposalLabel(p.key, wc.categoryTable), style: const TextStyle(fontWeight: FontWeight.w500)),
                  Text('${proposalValue(p, p.current, cur)} → ${proposalValue(p, p.suggested, cur)}',
                      style: numStyle.copyWith(fontWeight: FontWeight.w500)),
                  Text(proposalBasis(p.basis), style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                ]),
              ),
            ]),
          ),
      ]),
      const SizedBox(height: 10),
      if (_choosing)
        FilledButton(
            key: const ValueKey('firstPlanAcceptTicked'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: _ticked.isEmpty ? null : () => _accept(Set.of(_ticked)),
            child: Text(_ticked.length == 1 ? 'Accept 1' : 'Accept ${_ticked.length}'))
      else ...[
        FilledButton(
            key: const ValueKey('firstPlanAcceptAll'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: () => _accept(null),
            child: const Text('Accept all')),
        if (_proposals.length > 1)
          TextButton(
              key: const ValueKey('firstPlanChoose'),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
              onPressed: () => setState(() => _choosing = true),
              child: const Text('Choose…')),
      ],
      TextButton(
          key: const ValueKey('firstPlanLater'),
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: () {
            logNav('plan.firstSheet.later');
            // The same as "Not now" in Plan › Suggestions: each row stays hidden until its suggested value changes.
            for (final p in _proposals) {
              widget.wc.putOffPlanProposal(p.key);
            }
            Navigator.pop(context);
          },
          child: const Text('Not now')),
    ]);
  }
}
