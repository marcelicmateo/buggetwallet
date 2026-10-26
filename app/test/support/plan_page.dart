import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/layout.dart';
import 'package:budget_wallet/src/screens/bills_panel.dart';
import 'package:budget_wallet/src/screens/habits_panels.dart';
import 'package:budget_wallet/src/screens/payday_plan.dart';
import 'package:budget_wallet/src/screens/settings.dart';
import 'package:budget_wallet/src/tabs.dart';
import 'package:flutter/material.dart';

/// Every panel the Plan tab held before P5 (payday plan, expected bills and income, bills, all Settings sections) in one tall list, in
/// the old order. The panels now live on Budget, Bills and Settings; tests of what a panel does (not where it sits) pump this page,
/// so they keep checking that the moved panels behave as before. Where a panel sits is tested on the real tabs (`p5_tabs_test.dart`).
class PlanPage extends StatelessWidget {
  final WalletController wc;
  final FileChooser chooser;
  const PlanPage({super.key, required this.wc, this.chooser = const FileChooser()});

  @override
  Widget build(BuildContext context) {
    List<Widget> of(SettingsSection s) => settingsPanels(context, wc, s, chooser: chooser);
    // Like the Plan tab, it rebuilds on every change of the controller.
    return ListenableBuilder(listenable: wc, builder: (context, _) => _page(context, of));
  }

  Widget _page(BuildContext context, List<Widget> Function(SettingsSection) of) {
    // A plain column: every panel is built whatever the window height (the old Plan was a lazy list, and its order and heights differ).
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: gapped([
            PaydayPlan(wc: wc),
            ...of(SettingsSection.accounts),
            ExpectedBillsPanel(wc: wc),
            ...of(SettingsSection.income),
            BillsPanel(wc: wc, chooser: chooser),
            for (final s in SettingsSection.listed)
              if (s != SettingsSection.accounts && s != SettingsSection.income) ...of(s),
          ])),
    );
  }
}
