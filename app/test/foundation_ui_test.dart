// The shared UI helpers of Stage G3: MoneyField, DialogAppBar + openPageOrDialog, GatePage, RuledRow, gapped. All data is SYNTHETIC.
import 'package:budget_wallet/src/layout.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

class _Page extends StatelessWidget {
  const _Page();
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: const DialogAppBar(title: 'Synthetic page', actions: [Icon(Icons.add)]),
        body: Center(child: FilledButton(onPressed: () => Navigator.pop(context, 'done'), child: const Text('Finish'))),
      );
}

class _Opener extends StatelessWidget {
  final void Function(String? r) onResult;
  const _Opener(this.onResult);
  @override
  Widget build(BuildContext context) => Center(
        child: FilledButton(
          onPressed: () async => onResult(await openPageOrDialog<String>(context, const _Page(), width: 500, logName: 'SyntheticPage')),
          child: const Text('Open'),
        ),
      );
}

void main() {
  testWidgets('MoneyField: decimal keyboard, right-aligned, fieldKey lands on the TextField', (tester) async {
    final c = TextEditingController();
    String? seen;
    await pumpApp(
        tester,
        Scaffold(
          body: MoneyField(
              fieldKey: const ValueKey('synthetic'),
              controller: c,
              onChanged: (v) => seen = v,
              decoration: const InputDecoration(labelText: 'Amount')),
        ));
    final field = tester.widget<TextField>(find.byKey(const ValueKey('synthetic')));
    expect(field.keyboardType, const TextInputType.numberWithOptions(decimal: true));
    expect(field.textAlign, TextAlign.end);
    await tester.enterText(find.byKey(const ValueKey('synthetic')), '12.50');
    expect(seen, '12.50');
    expect(c.text, '12.50');
  });

  for (final (name, size) in [('a phone', const Size(400, 800)), ('a desktop window', const Size(1200, 800))]) {
    testWidgets('openPageOrDialog on $name: DialogAppBar closes it with the tooltip Close, the result comes back', (tester) async {
      String? result = 'unset';
      await pumpApp(tester, _Opener((r) => result = r), size: size);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic page'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(find.byType(Dialog), size.width >= dialogMin ? findsOneWidget : findsNothing);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(result, isNull, reason: 'closing pops null');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(result, 'done');
    });
  }

  testWidgets('GatePage shows the name, then its children in a column no wider than 480', (tester) async {
    await pumpApp(tester, const GatePage(children: [Text('Synthetic body')]), size: const Size(1200, 800));
    expect(find.text('Budget Wallet'), findsOneWidget);
    expect(find.text('Synthetic body'), findsOneWidget);
    expect(tester.getSize(find.byType(ListView)).width, 480);
  });

  testWidgets('RuledRow is at least rowMin tall; gapped puts the gap between children only', (tester) async {
    await pumpApp(
        tester,
        Scaffold(
            body: Column(children: [
          const RuledRow(child: Text('One')),
          ...gapped(const [Text('A'), Text('B')], gap: 20)
        ])));
    expect(tester.getSize(find.byType(RuledRow)).height, greaterThanOrEqualTo(rowMin));
    expect(tester.getTopLeft(find.text('B')).dy - tester.getBottomLeft(find.text('A')).dy, closeTo(20, 0.01));
    expect(gapped(const [Text('x')]).length, 1);
    expect(gapped(const <Widget>[]), isEmpty);
  });
}
