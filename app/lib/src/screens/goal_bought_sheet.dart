// "I bought it" (ENG E6, spec §5.5 step 3): the owner picks the payment rows the purchase was made with (never an amount match), checks the
// loan as the plan guessed it (each guess marked Unsure until touched) and confirms once. Pops `'bought'`.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'goal_planner.dart' show rateBpText;
import 'loan_fields.dart';

class BoughtSheet extends StatefulWidget {
  final WalletController wc;
  final Goal goal;

  /// The planner's inputs: the loan fields start from them.
  final GoalDraft draft;
  const BoughtSheet({super.key, required this.wc, required this.goal, required this.draft});
  @override
  State<BoughtSheet> createState() => _BoughtSheetState();
}

class _BoughtSheetState extends State<BoughtSheet> {
  final picked = <String>{};
  final search = TextEditingController();
  final loanState = LoanFieldsState();
  late bool withLoan = financed;
  String? error;

  WalletController get wc => widget.wc;
  bool get financed => widget.draft.depositPermille < 1000;

  @override
  void initState() {
    super.initState();
    if (!financed) return;
    final d = widget.draft, plan = wc.planFor(widget.goal, d);
    loanState.guess('principal', loanState.principal, centsToFieldText(plan.loan));
    if (d.rateBp != null) loanState.guess('rate', loanState.rate, rateBpText(d.rateBp!).replaceAll(' %', ''));
    if (d.months != null) loanState.guess('years', loanState.years, '${d.months! / 12}'.replaceAll(RegExp(r'\.0$'), ''));
    if (plan.payment != null) loanState.guess('payment', loanState.payment, centsToFieldText(plan.payment!));
    loanState.firstDue = addDays(wc.today(), 30);
    loanState.unsure.add('first');
  }

  @override
  void dispose() {
    search.dispose();
    loanState.dispose();
    super.dispose();
  }

  void _confirm() {
    Loan? loan;
    if (financed && withLoan) {
      final (l, err) = loanState.read(wc, name: widget.goal.name, needAll: true);
      if (err != null) return setState(() => error = err);
      loan = l;
    }
    try {
      wc.buyGoal(widget.goal.id, txIds: picked.toList(), loan: loan);
    } on ArgumentError catch (e) {
      return setState(() => error = '${e.message}');
    }
    logNav('goal.bought.confirm', {'rows': picked.length, 'loan': loan != null});
    Navigator.pop(context, 'bought');
  }

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency, c = context.c;
    final q = search.text.trim().toLowerCase();
    final rows = [
      for (final t in wc.purchaseCandidates())
        if (q.isEmpty || merchantName(t).toLowerCase().contains(q) || picked.contains(t.id)) t
    ].take(12).toList();
    return Column(
        key: const ValueKey('boughtSheet'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: gapped([
          Heading('I bought ${widget.goal.name}'),
          const Muted('Pick the payments you made for it, like the deposit and the costs. The money you saved counts as spent on them.'),
          TextField(
              key: const ValueKey('boughtSearch'),
              controller: search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Find a payment', prefixIcon: Icon(Icons.search))),
          if (rows.isEmpty)
            const EmptyNote('No payments out to find.', key: ValueKey('boughtNone'))
          else
            Rows(children: [
              for (final t in rows)
                Semantics(
                  checked: picked.contains(t.id),
                  child: InkWell(
                    key: ValueKey('pick:${t.id}'),
                    onTap: () => setState(() => picked.contains(t.id) ? picked.remove(t.id) : picked.add(t.id)),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: rowMin),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(children: [
                          Icon(picked.contains(t.id) ? Icons.check_box : Icons.check_box_outline_blank,
                              color: picked.contains(t.id) ? c.accent : c.muted),
                          const SizedBox(width: 10),
                          Expanded(
                            child: LayoutBuilder(builder: (context, box) {
                              final name = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(merchantName(t),
                                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text(shortDateOrRaw(t.date), style: TextStyle(fontSize: BwType.metaSize, color: c.muted)),
                              ]);
                              final amount = Text(moneyExact(-t.amount, cur), textAlign: TextAlign.end, style: numStyle);
                              // Too narrow for both side by side at this text size: the amount goes under the name.
                              return box.maxWidth / MediaQuery.textScalerOf(context).scale(1.0) < 260
                                  ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [name, amount])
                                  : SplitRow(start: name, end: amount);
                            }),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ),
            ]),
          Muted(picked.isEmpty ? 'Nothing picked yet. You can confirm without payments.' : '${picked.length} picked',
              key: const ValueKey('boughtPicked')),
          if (financed) ...[
            SwitchListTile(
                key: const ValueKey('boughtWithLoan'),
                contentPadding: EdgeInsets.zero,
                title: const Text('With a loan'),
                value: withLoan,
                onChanged: (v) => setState(() => withLoan = v)),
            if (withLoan) ...[
              const Text('The loan, as the lender wrote it', style: BwType.heading),
              LoanFields(wc: wc, s: loanState),
            ],
          ],
          if (error != null) StatusLabel(key: const ValueKey('boughtError'), good: false, text: error!),
          if (financed && withLoan && loanState.unsure.isNotEmpty)
            const Muted('Check the marked values: they come from your plan.', key: ValueKey('boughtCheckMarked')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton(key: const ValueKey('boughtConfirm'), onPressed: _confirm, child: const Text('Confirm')),
            OutlinedButton(key: const ValueKey('boughtCancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ]),
        ], gap: 12));
  }
}
