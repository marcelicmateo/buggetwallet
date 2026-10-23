// Pins the two layout thresholds the Ledger theme depends on: the margin line shows from 600 dp, and transaction rows use
// the Date | Particulars | Amount columns up to text scale 1.15 and stack above it. SYNTHETIC data only.
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/layout.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

void main() {
  final marginLine = find.byKey(const ValueKey('marginLine'));

  testWidgets('margin line: absent at 599 dp, present at 600 dp, at x 22 with the content clear of it', (tester) async {
    await pumpApp(tester, const MarginLine(child: SizedBox.expand(key: ValueKey('page'))), size: const Size(599, 800));
    expect(marginLine, findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('page'))).dx, 0);

    await pumpApp(tester, const MarginLine(child: SizedBox.expand(key: ValueKey('page'))), size: const Size(600, 800));
    expect(marginLine, findsOneWidget);
    expect(tester.getTopLeft(marginLine).dx, marginLineX);
    // The page keeps its own 16 dp padding inside the gutter.
    expect(tester.getTopLeft(find.byKey(const ValueKey('page'))).dx + pagePad, greaterThanOrEqualTo(marginLineX + marginLineWidth));
  });

  testWidgets('margin line on the real pages: absent at 599 dp, present at 600 dp', (tester) async {
    await pumpFull(tester, demoWallet(), 1.0, size: const Size(599, 800));
    expect(marginLine, findsNothing);
    await pumpFull(tester, demoWallet(), 1.0, size: const Size(600, 800));
    expect(marginLine, findsOneWidget);
  });

  group('TxTile columns', () {
    // Columns need text scale <= 1.15 and a window of 400 dp or more; below 400 dp the date sits under the name.
    Future<void> pumpTile(WidgetTester tester, double scale, {double width = 420}) async {
      final wc = demoWallet();
      final t = wc.txs.firstWhere((t) => t.amount < 0);
      await pumpApp(tester, Scaffold(body: TxTile(t: t, currency: 'EUR')), size: Size(width, 640), textScale: scale);
      expect(tester.takeException(), isNull);
      // In the columns the date is a cell of its own; stacked, it is part of the "date · category" line.
      final columns = scale <= 1.15 && width >= 400;
      final date = shortDateOrRaw(t.date);
      expect(find.text(date), columns ? findsOneWidget : findsNothing, reason: 'scale $scale');
      expect(find.textContaining('$date · '), columns ? findsNothing : findsOneWidget, reason: 'scale $scale');
    }

    testWidgets('columns at text scale 1.15 and 420 dp', (tester) => pumpTile(tester, 1.15));
    testWidgets('stacked at 320 dp, even at text scale 1.0', (tester) => pumpTile(tester, 1.0, width: 320));
    testWidgets('stacked at 399 dp', (tester) => pumpTile(tester, 1.0, width: 399));
    testWidgets('stacked at text scale 1.2', (tester) => pumpTile(tester, 1.2));
  });
}
