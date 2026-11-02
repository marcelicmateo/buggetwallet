import 'package:flutter/material.dart';

import '../controller.dart';
import '../layout.dart';
import '../logging.dart';
import '../tabs.dart' show JumpRequest;
import '../widgets/jump_when_built.dart';
import '../widgets/scroll_to.dart';
import 'budgets.dart';
import 'habits_panels.dart' show ExpectedIncomePanel;
import 'payday_plan.dart';
import 'save.dart';

/// The Plan page (ENG E1): a **Payday plan | Saving** switch over the payday plan (with Expected income and Budgets per category) and
/// the Save page (goals, wishlist, owed). The choice is device-local (`wc.planView`); links pick the page they mean before the tab
/// opens. Both pages stay built (an [IndexedStack]), so the plan editor keeps what was typed while Saving is shown.
class PlanScreen extends StatefulWidget {
  final WalletController wc;

  /// Keeps the payday plan's State when the shell rebuilds the page.
  final Key? planKey;

  /// Overview's income tile: scrolls the plan to Expected income.
  final JumpRequest<bool>? incomeRequest;
  const PlanScreen({super.key, required this.wc, this.planKey, this.incomeRequest});
  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  /// The page last built, so a controller change that is not the switch does not rebuild this level.
  String _shown = '';
  final _planScroll = ScrollController();
  final _incomeKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.wc.addListener(_changed);
    widget.incomeRequest?.addListener(_jumpIncome);
    jumpWhenBuilt(widget.incomeRequest, () => mounted, _jumpIncome);
  }

  void _jumpIncome() {
    if (mounted) scrollToKey(_planScroll, _incomeKey, alive: () => mounted);
  }

  @override
  void didUpdateWidget(PlanScreen old) {
    super.didUpdateWidget(old);
    if (old.wc != widget.wc) {
      old.wc.removeListener(_changed);
      widget.wc.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.wc.removeListener(_changed);
    widget.incomeRequest?.removeListener(_jumpIncome);
    _planScroll.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted && widget.wc.planView != _shown) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final view = _shown = wc.planView;
    final switcher = PlanSwitch(
        view: view,
        onChanged: (v) {
          logNav('plan.view', {'view': v});
          wc.setPlanView(v);
        });
    return IndexedStack(index: view == 'saving' ? 1 : 0, sizing: StackFit.expand, children: [
      MarginLine(
        child: ListView(
            controller: _planScroll,
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
            children: gapped([
              switcher,
              PaydayPlan(key: widget.planKey, wc: wc),
              ExpectedIncomePanel(key: _incomeKey, wc: wc),
              BudgetsPanel(key: const ValueKey('budgetsPanel'), wc: wc),
            ])),
      ),
      SaveScreen(wc: wc, switcher: switcher),
    ]);
  }
}

/// The Payday plan | Saving switch (`planSwitch`; segments `planPayday`, `planSaving`).
class PlanSwitch extends StatelessWidget {
  final String view;
  final ValueChanged<String> onChanged;
  const PlanSwitch({super.key, required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) => SegmentedButton<String>(
        key: const ValueKey('planSwitch'),
        style: SegmentedButton.styleFrom(minimumSize: const Size(0, touchMin)),
        showSelectedIcon: true,
        segments: const [
          ButtonSegment(value: 'payday', label: Text('Payday plan', key: ValueKey('planPayday'), maxLines: 1)),
          ButtonSegment(value: 'saving', label: Text('Saving', key: ValueKey('planSaving'), maxLines: 1)),
        ],
        selected: {view},
        onSelectionChanged: (s) => onChanged(s.first),
      );
}
