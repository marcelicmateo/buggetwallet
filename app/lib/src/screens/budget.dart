import 'package:flutter/material.dart';

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import 'payday_plan.dart';
import 'spending.dart';
import 'tags_window.dart';

/// The Budget tab (RX4): two dashboards behind a **Spending | Plan** switch. Spending answers "where did it go?", Plan "where will
/// the salary go?". The choice is remembered on the device (`wc.budgetView`, default Spending); Today's links pick the page they mean
/// before the tab opens, and a search (Ctrl+F, the app bar) always lands on Spending. Both pages stay built (an [IndexedStack]), so
/// the plan editor keeps what was typed while the other page is shown.
class BudgetScreen extends StatefulWidget {
  final WalletController wc;

  /// Counts the Ctrl+F presses; Spending opens its search view on each.
  final Listenable? searchRequest;
  final void Function(int tab)? openTab;
  final VoidCallback? openBills;

  /// Keeps the payday plan's State when the shell rebuilds the page.
  final Key? planKey;
  const BudgetScreen({super.key, required this.wc, this.searchRequest, this.openTab, this.openBills, this.planKey});
  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  /// The page last built, so a controller change that is not the switch does not rebuild this level.
  String _shown = '';

  @override
  void initState() {
    super.initState();
    widget.wc.addListener(_changed);
    widget.searchRequest?.addListener(_search);
  }

  @override
  void didUpdateWidget(BudgetScreen old) {
    super.didUpdateWidget(old);
    if (old.wc != widget.wc) {
      old.wc.removeListener(_changed);
      widget.wc.addListener(_changed);
    }
    if (old.searchRequest != widget.searchRequest) {
      old.searchRequest?.removeListener(_search);
      widget.searchRequest?.addListener(_search);
    }
  }

  @override
  void dispose() {
    widget.wc.removeListener(_changed);
    widget.searchRequest?.removeListener(_search);
    super.dispose();
  }

  void _changed() {
    if (mounted && widget.wc.budgetView != _shown) setState(() {});
  }

  void _search() => widget.wc.setBudgetView('spending');

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final view = _shown = wc.budgetView;
    final switcher = BudgetSwitch(
        view: view,
        onChanged: (v) {
          logNav('budget.view', {'view': v});
          wc.setBudgetView(v);
        });
    return IndexedStack(index: switch (view) { 'plan' => 1, 'tags' => 2, _ => 0 }, sizing: StackFit.expand, children: [
      SpendingScreen(wc: wc, searchRequest: widget.searchRequest, openTab: widget.openTab, openBills: widget.openBills, switcher: switcher),
      MarginLine(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
            children: gapped([switcher, PaydayPlan(key: widget.planKey, wc: wc)])),
      ),
      // Built only while shown: three long lists need not be laid out behind the other pages.
      view == 'tags' ? TagsWindow(wc: wc, switcher: switcher) : const SizedBox.shrink(),
    ]);
  }
}

/// The Spending | Plan | Tags switch (`budgetSwitch`; segments `budgetSpending`, `budgetPlan`, `budgetTags`): the chosen segment has a tick and a tint.
class BudgetSwitch extends StatelessWidget {
  final String view;
  final ValueChanged<String> onChanged;
  const BudgetSwitch({super.key, required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) => SegmentedButton<String>(
        key: const ValueKey('budgetSwitch'),
        style: SegmentedButton.styleFrom(minimumSize: const Size(0, touchMin)),
        showSelectedIcon: true,
        segments: const [
          ButtonSegment(value: 'spending', label: Text('Spending', key: ValueKey('budgetSpending'), maxLines: 1)),
          ButtonSegment(value: 'plan', label: Text('Plan', key: ValueKey('budgetPlan'), maxLines: 1)),
          ButtonSegment(value: 'tags', label: Text('Tags', key: ValueKey('budgetTags'), maxLines: 1)),
        ],
        selected: {view},
        onSelectionChanged: (s) => onChanged(s.first),
      );
}
