// "+ Goal" (ENG E6): is it paid in full or with a loan? Paid in full is the goal sheet as it always was; with a loan asks for the price (and
// whether it is a property, which only picks the starting costs and loan length) and opens the planner.
import 'package:flutter/material.dart';

import '../controller.dart';
import '../format.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// The result of [GoalKindSheet] when a planner should open: this prefix and the new goal's id.
const goalPlannerResult = 'planner:';

class GoalKindSheet extends StatefulWidget {
  final WalletController wc;
  const GoalKindSheet({super.key, required this.wc});
  @override
  State<GoalKindSheet> createState() => _GoalKindSheetState();
}

class _GoalKindSheetState extends State<GoalKindSheet> {
  bool loan = false, property = false;
  final name = TextEditingController(), price = TextEditingController();
  String? error;

  @override
  void dispose() {
    name.dispose();
    price.dispose();
    super.dispose();
  }

  void _plan() {
    final p = parseMoney(price.text);
    if (p == null || p <= 0) return setState(() => error = 'Price: $invalidAmountMessage');
    final id = widget.wc.addBigGoal(name: name.text, price: p, financed: true, property: property, error: (e) => error = e);
    if (id == null) return setState(() {});
    Navigator.pop(context, '$goalPlannerResult$id');
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<bool>(
          key: const ValueKey('goalKind'),
          segments: const [
            ButtonSegment(value: false, label: Text('Paid in full')),
            ButtonSegment(value: true, label: Text('With a loan')),
          ],
          selected: {loan},
          onSelectionChanged: (v) => setState(() => loan = v.first),
        ),
        const SizedBox(height: 14),
        if (!loan)
          GoalSheet(wc: widget.wc)
        else
          Column(
              key: const ValueKey('goalLoanForm'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: gapped([
                const Heading('New goal with a loan'),
                TextField(
                    key: const ValueKey('goalLoanName'),
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Name', hintText: 'New car')),
                MoneyField(
                    fieldKey: const ValueKey('goalLoanPrice'),
                    controller: price,
                    onChanged: (_) => setState(() => error = null),
                    decoration: InputDecoration(labelText: 'Price', suffixText: currencySymbol(widget.wc.currency))),
                SwitchListTile(
                    key: const ValueKey('goalProperty'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Property'),
                    subtitle: const Text('Starts with 6 % costs on top and a 30-year loan. You can change both.'),
                    value: property,
                    onChanged: (v) => setState(() => property = v)),
                if (error != null) StatusLabel(key: const ValueKey('goalLoanError'), good: false, text: error!),
                Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(key: const ValueKey('goalLoanPlan'), onPressed: _plan, child: const Text('Plan it'))),
              ], gap: 12)),
      ]);
}
