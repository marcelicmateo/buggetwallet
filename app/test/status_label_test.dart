// StatusLabel must wrap long text instead of overflowing (bug D). Synthetic text only.
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wallet.dart';

const _long = 'Sync failed: the folder could not be read because the storage permission was removed on this device';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('long text wraps at 320 dp, text scale $scale', (tester) async {
      await pumpApp(
          tester,
          const Scaffold(
              body: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    StatusLabel(good: false, text: _long),
                    Row(children: [Text('Label'), SizedBox(width: 8), Flexible(child: StatusLabel(good: true, text: _long))]),
                  ]))),
          size: const Size(320, 1600),
          textScale: scale);
      expect(tester.takeException(), isNull);
      final box = tester.getSize(find.byType(StatusLabel).first);
      expect(box.width, lessThanOrEqualTo(288));
      expect(box.height, greaterThan(16 * 2 * scale), reason: 'more than one line');
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });
  }

  testWidgets('short text stays on one line next to the icon', (tester) async {
    await pumpApp(tester, const Scaffold(body: Center(child: StatusLabel(good: true, text: 'On plan'))), size: const Size(320, 640));
    expect(tester.getSize(find.byType(StatusLabel)).height, lessThan(24));
  });
}
