import 'package:flutter/material.dart';

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import 'explore.dart';
import 'spending.dart';

/// The Explore tab (ENG E1, E4): two pages behind an **Explore | Spending** switch. Explore (`explore.dart`) is the query screen
/// and holds Insights and search; Spending is the old month page, kept until E7 moves its tiles. The choice is remembered on the device
/// (`wc.budgetView`, default Explore); a search (Ctrl+K, Ctrl+F, the app bar) always lands on Explore. Spending is built only while shown. Tags and rules live in
/// Settings (E7b).
class BudgetScreen extends StatefulWidget {
  final WalletController wc;

  /// Counts the Ctrl+F presses; Spending opens its search view on each.
  final Listenable? searchRequest;
  final void Function(int tab)? openTab;
  final VoidCallback? openBills;

  const BudgetScreen({super.key, required this.wc, this.searchRequest, this.openTab, this.openBills});
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

  void _search() => widget.wc.setBudgetView('explore');

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
    return IndexedStack(index: const {'explore': 0, 'spending': 1}[view]!, sizing: StackFit.expand, children: [
      ExploreScreen(wc: wc, searchRequest: widget.searchRequest, openTab: widget.openTab, openBills: widget.openBills, switcher: switcher),
      // Built only while shown: long lists need not be laid out behind the other page.
      view == 'spending'
          ? SpendingScreen(wc: wc, openTab: widget.openTab, openBills: widget.openBills, switcher: switcher)
          : const SizedBox.shrink(),
    ]);
  }
}

/// The Explore | Spending switch (`budgetSwitch`; segments `budgetExplore`, `budgetSpending`). It scrolls sideways when
/// the labels do not fit (320 dp at large text).
class BudgetSwitch extends StatelessWidget {
  final String view;
  final ValueChanged<String> onChanged;
  const BudgetSwitch({super.key, required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<String>(
          key: const ValueKey('budgetSwitch'),
          style: SegmentedButton.styleFrom(minimumSize: const Size(0, touchMin), padding: const EdgeInsets.symmetric(horizontal: 10)),
          showSelectedIcon: true,
          segments: const [
            ButtonSegment(value: 'explore', label: Text('Explore', key: ValueKey('budgetExplore'), maxLines: 1)),
            ButtonSegment(value: 'spending', label: Text('Spending', key: ValueKey('budgetSpending'), maxLines: 1)),
          ],
          selected: {view},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );
}
