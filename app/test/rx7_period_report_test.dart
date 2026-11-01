// RX7: the Pay-period report. Exact cents on every tile, stepping with the disabled ends, the delta chip (absent for the first period
// and when the period before spent nothing), the running chip once, the heatmap (squares, levels, refund day, days to come, a tap shows
// the exact amount, the spoken label), reviews and saved-by-waiting across a period boundary, how the page opens (phone chip, rail
// badge) and layout at 320 dp x 2.0 / 360 / 1280, light and dark. SYNTHETIC data; the clock is fixed at 20 Oct 2026.
import 'dart:io';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/insights_api.dart';
import 'package:budget_wallet/src/screens/period_report.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/seams.dart';
import 'support/wallet.dart';

Future<void> _loadFonts() async {
  for (final (fam, prefix) in [('IBM Plex Sans', 'IBMPlexSans'), ('IBM Plex Mono', 'IBMPlexMono')]) {
    final l = FontLoader(fam);
    for (final w in ['Regular', 'Medium', 'SemiBold']) {
      l.addFont(File('assets/fonts/$prefix-$w.ttf').readAsBytes().then(ByteData.sublistView));
    }
    await l.load();
  }
}

final _clock = DateTime(2026, 10, 20, 12);

/// Paydays on the 5th: periods 5 Aug-4 Sep, 5 Sep-4 Oct, 5 Oct-4 Nov (running; today is the 20th).
///   Aug: out 400 + 123.45 = 523.45, kept 976.55          Sep: out 400 + 250.50 = 650.50, kept 849.50
///   Oct: out 400 + (84.20 + 25 + 10 - 7.50) = 511.70, kept 988.30; the 16th is a net refund of 7.50
/// Reviews: Sep 2 (30 Sep, 4 Oct), Oct 3 (5, 12, 18 Oct). Skipped wishes: Sep 1 (45.05, decided 4 Oct 23:30), Oct 2 (120.50 decided
/// 5 Oct 00:00 sharp + 30 decided on the 15th = 150.50); a bought wish never counts.
WalletController _wallet({bool august = true}) {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => _clock);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    if (august) syntheticTx('2026-08-05', 150000, 'Plaća/Mirovina', 'Neto placa synthetic a'),
    syntheticTx('2026-09-05', 150000, 'Plaća/Mirovina', 'Neto placa synthetic b'),
    syntheticTx('2026-10-05', 150000, 'Plaća/Mirovina', 'Neto placa synthetic c'),
  ]));
  void out(String date, int cents, String cat) => wc.repo.addTransaction(date: date, amount: cents, category: cat);
  if (august) {
    out('2026-08-07', 40000, 'Rent');
    out('2026-08-10', 12345, 'Groceries');
  }
  out('2026-09-07', 40000, 'Rent');
  out('2026-09-10', 20000, 'Groceries');
  out('2026-09-20', 5050, 'Eating out');
  out('2026-10-07', 40000, 'Rent');
  out('2026-10-12', 8420, 'Groceries');
  out('2026-10-14', 2500, 'Eating out');
  out('2026-10-16', -750, 'Shopping');
  out('2026-10-18', 1000, 'Groceries');
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'paydayDay': 5});
  for (final d in const ['2026-09-30', '2026-10-04', '2026-10-05', '2026-10-12', '2026-10-18']) {
    wc.repo.markReviewDone(d);
  }
  void wish(String id, int price, String status, DateTime decided) => wc.repo.applyRemote([
        Op('wish', id, {'name': id, 'price': price, 'added': 1, 'status': status, 'decided': decided.millisecondsSinceEpoch, 'deleted': 0},
            Hlc(_clock.millisecondsSinceEpoch, 0, 'peer').toString()),
      ]);
  wish('w1', 4505, 'skipped', DateTime(2026, 10, 4, 23, 30));
  wish('w2', 12050, 'skipped', DateTime(2026, 10, 5));
  wish('w3', 3000, 'skipped', DateTime(2026, 10, 15, 10));
  wish('w4', 9999, 'bought', DateTime(2026, 10, 10));
  wc.snoozeKeyBackup();
  wc.reload();
  addTearDown(wc.dispose);
  return wc;
}

Future<void> _pump(WidgetTester tester, WalletController wc,
    {Size size = const Size(400, 2400), double scale = 1, Brightness mode = Brightness.light}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(mode),
    builder: (context, c) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: c!),
    home: PeriodReportScreen(wc),
  ));
  await tester.pump();
}

Finder _k(String key) => find.byKey(ValueKey(key));
Finder _in(String key, String text) => find.descendant(of: _k(key), matching: find.text(text));

/// The hero figure is one `Text.rich` (number, narrow gap, sign).
Finder _kept(String text) =>
    find.byWidgetPredicate((w) => w is Text && w.key == const ValueKey('reportKept') && (w.textSpan?.toPlainText() ?? w.data) == text);
Finder _contains(String key, String text) => find.descendant(of: _k(key), matching: find.textContaining(text));
String _title(WidgetTester t) => t.widget<Text>(_k('reportTitle')).data!;
Color? _fill(WidgetTester t, String date) =>
    (t.widget<DecoratedBox>(find.descendant(of: _k('heatDay:$date'), matching: find.byType(DecoratedBox)).first).decoration
            as BoxDecoration)
        .color;

Future<void> _tapIcon(WidgetTester t, String key) async {
  await t.tap(_k(key));
  await t.pump();
}

void main() {
  setUpAll(_loadFonts);

  group('UX-A: the next payday and "start a new month" (was Settings › Month)', () {
    testWidgets('the running period shows its expected payday and the button; a finished one shows neither', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc);
      final end = wc.periodReportsFor(count: 12).last.end;
      expect(find.text('Expected ${shortDate(end)}'), findsOneWidget);
      expect(_k('startNewMonth'), findsOneWidget);
      await _tapIcon(tester, 'reportPrev');
      expect(_k('reportNewMonth'), findsNothing);
      expect(_k('startNewMonth'), findsNothing);
    });

    testWidgets('Cancel writes nothing; OK starts the month on the day picked and says so', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc);
      final before = wc.settings.periodStart;
      await tester.ensureVisible(_k('startNewMonth'));
      await tester.tap(_k('startNewMonth'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(wc.settings.periodStart, before);

      await tester.tap(_k('startNewMonth'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(wc.settings.periodStart, '2026-10-20');
      expect(wc.period().start, '2026-10-20');
      expect(find.text('New month started ${shortDate('2026-10-20')}'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3)); // the toast's timer
    });

    testWidgets('fits 320 dp at text scale 2.0', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc, size: const Size(320, 2400), scale: 2);
      await tester.ensureVisible(_k('startNewMonth'));
      expect(tester.takeException(), isNull);
    });
  });

  group('running chip wording', () {
    /// Payday 10, today 20 Oct 2026, the given synthetic salary rows.
    WalletController wallet(List<String> salaryDays, {String? periodStart}) {
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => _clock);
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (final d in salaryDays) syntheticTx(d, 150000, 'Plaća/Mirovina', 'Neto placa synthetic $d'),
      ]));
      wc.repo.updateSettings({
        'salary': 150000,
        'salaryConfirmed': true,
        'paydayDay': 10,
        if (periodStart != null) 'periodStart': periodStart,
      });
      wc.snoozeKeyBackup();
      wc.reload();
      addTearDown(wc.dispose);
      return wc;
    }

    testWidgets("the days left count from the report's own end, also when Today's period ended", (tester) async {
      // Saved start 12 Sep ends Today's period on 10 Oct (0 days left there); the salary of 11 Oct starts the report that runs to 10 Nov.
      final wc = wallet(['2026-09-11', '2026-10-11'], periodStart: '2026-09-12');
      expect(wc.period().daysLeft, 0, reason: "Today's period has ended");
      await _pump(tester, wc);
      expect(find.text('Running · 21 days left'), findsOneWidget);
      expect(_k('reportLate'), findsNothing);
    });

    testWidgets('the expected payday passed without a salary: "Salary late", no days left', (tester) async {
      final wc = wallet(['2026-09-10']);
      await _pump(tester, wc);
      expect(_k('reportLate'), findsOneWidget);
      expect(find.text('Salary late'), findsOneWidget);
      expect(_k('reportRunning'), findsNothing);
      expect(find.textContaining('days left'), findsNothing);
    });

    testWidgets('the salary came on time: the chip counts the days to the next payday', (tester) async {
      final wc = wallet(['2026-09-10', '2026-10-10']);
      await _pump(tester, wc);
      expect(find.text('Running · 21 days left'), findsOneWidget);
      expect(find.text('Salary late'), findsNothing);
    });
  });

  group('the running period', () {
    testWidgets('exact cents on every tile, the chips say each thing once', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc);
      expect(_title(tester), '5 Oct – 4 Nov');
      expect(_kept('988.30\u00A0€'), findsOneWidget);
      expect(_in('reportIn', '1,500\u00A0€'), findsOneWidget);
      expect(_in('reportOut', '511.70\u00A0€'), findsOneWidget);
      expect(_contains('reportSplit', 'Fixed'), findsOneWidget);
      expect(_contains('reportSplit', '400\u00A0€'), findsOneWidget);
      expect(_contains('reportSplit', 'Flexible'), findsOneWidget);
      expect(_contains('reportSplit', '111.70\u00A0€'), findsOneWidget);
      // The period is still running: its partial spending is not compared with a whole period (no "better" after 3 days).
      expect(_k('reportDelta'), findsNothing);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      // The running state is said once, without the end date the title already has (16 days: 20 Oct to 4 Nov).
      expect(_k('reportRunning'), findsOneWidget);
      expect(find.text('Running · 16 days left'), findsOneWidget);
      expect(find.textContaining('4 Nov'), findsOneWidget, reason: 'only the title says the end date');
      expect(find.textContaining('so far'), findsNothing);
      // Reviews and saved by waiting count the period [5 Oct, 5 Nov).
      expect(_in('reportReviews', '3'), findsOneWidget);
      expect(_in('reportSaved', '150.50\u00A0€'), findsOneWidget);
      expect(_in('reportSaved', '2 skipped'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a negative kept shows the minus sign and the exact figure', (tester) async {
      final wc = _wallet();
      wc.repo.addTransaction(date: '2026-10-19', amount: 200000, category: 'Shopping');
      wc.reload();
      await _pump(tester, wc);
      // 988.30 - 2,000 = -1,011.70
      expect(_kept(moneyExact(-101170, 'EUR')), findsOneWidget);
      expect(moneyExact(-101170, 'EUR'), contains('−'));
      expect(tester.takeException(), isNull);
    });
  });

  group('stepping', () {
    testWidgets('back to the first period and forward again; the ends are disabled', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc);
      IconButton btn(String k) => tester.widget<IconButton>(_k(k));
      expect(btn('reportNext').onPressed, isNull, reason: 'the running period is the last');
      expect(btn('reportPrev').onPressed, isNotNull);

      await _tapIcon(tester, 'reportPrev');
      expect(_title(tester), '5 Sep – 4 Oct');
      expect(_kept('849.50\u00A0€'), findsOneWidget);
      expect(_in('reportIn', '1,500\u00A0€'), findsOneWidget);
      expect(_in('reportOut', '650.50\u00A0€'), findsOneWidget);
      expect(_contains('reportSplit', '250.50\u00A0€'), findsOneWidget);
      // Up 24 % on August's 523.45: up, and bad.
      expect(find.descendant(of: _k('reportDelta'), matching: find.text('Out 24 % vs 5 Aug – 4 Sep')), findsOneWidget);
      expect(find.byIcon(Icons.arrow_drop_up), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(_k('reportRunning'), findsNothing, reason: 'a finished period has no running chip');
      // The review on 4 Oct and the wish decided at 23:30 that day are September's; the ones on the 5th are October's.
      expect(_in('reportReviews', '2'), findsOneWidget);
      expect(_in('reportSaved', '45.05\u00A0€'), findsOneWidget);
      expect(_in('reportSaved', '1 skipped'), findsOneWidget);
      expect(btn('reportNext').onPressed, isNotNull);

      await _tapIcon(tester, 'reportPrev');
      expect(_title(tester), '5 Aug – 4 Sep');
      expect(_kept('976.55\u00A0€'), findsOneWidget);
      expect(_k('reportDelta'), findsNothing, reason: 'the first period has nothing before it');
      expect(_in('reportReviews', '0'), findsOneWidget);
      expect(_in('reportSaved', '0\u00A0€'), findsOneWidget);
      expect(_in('reportSaved', 'None skipped'), findsOneWidget);
      expect(btn('reportPrev').onPressed, isNull, reason: 'the first period is the first');

      await _tapIcon(tester, 'reportNext');
      await _tapIcon(tester, 'reportNext');
      expect(_title(tester), '5 Oct – 4 Nov');
      expect(btn('reportNext').onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no change chip when the period before spent nothing', (tester) async {
      final wc = _wallet(august: false);
      await _pump(tester, wc);
      await _tapIcon(tester, 'reportPrev');
      expect(_title(tester), '5 Sep – 4 Oct');
      expect(_k('reportDelta'), findsNothing, reason: 'first period');
      await _tapIcon(tester, 'reportNext');
      expect(_k('reportDelta'), findsNothing, reason: 'the running period is not compared');

      // The same wallet with a September that spent nothing: October has no figure to compare with.
      final empty = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => _clock);
      addTearDown(empty.dispose);
      empty.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-09-05', 150000, 'Plaća/Mirovina', 'Neto placa synthetic b'),
        syntheticTx('2026-10-05', 150000, 'Plaća/Mirovina', 'Neto placa synthetic c'),
      ]));
      empty.repo.addTransaction(date: '2026-10-12', amount: 8420, category: 'Groceries');
      empty.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'paydayDay': 5});
      empty.reload();
      await _pump(tester, empty);
      expect(_in('reportOut', '84.20\u00A0€'), findsOneWidget);
      expect(_k('reportDelta'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a finished period that spent less than the one before: down, and good', (tester) async {
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => _clock);
      addTearDown(wc.dispose);
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-08-05', 150000, 'Plaća/Mirovina', 'Neto placa synthetic a'),
        syntheticTx('2026-09-05', 150000, 'Plaća/Mirovina', 'Neto placa synthetic b'),
        syntheticTx('2026-10-05', 150000, 'Plaća/Mirovina', 'Neto placa synthetic c'),
      ]));
      wc.repo.addTransaction(date: '2026-08-10', amount: 20000, category: 'Groceries');
      wc.repo.addTransaction(date: '2026-09-10', amount: 15000, category: 'Groceries');
      wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'paydayDay': 5});
      wc.snoozeKeyBackup();
      wc.reload();
      await _pump(tester, wc);
      await _tapIcon(tester, 'reportPrev');
      expect(_title(tester), '5 Sep – 4 Oct');
      expect(find.descendant(of: _k('reportDelta'), matching: find.text('Out 25 % vs 5 Aug – 4 Sep')), findsOneWidget);
      expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no pay periods yet: one short line, no tiles', (tester) async {
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => _clock);
      addTearDown(wc.dispose);
      wc.snoozeKeyBackup();
      await _pump(tester, wc);
      expect(find.text('No salary found yet.'), findsOneWidget);
      expect(_k('reportKept'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('imports without any salary row say the same short line', (tester) async {
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => _clock);
      addTearDown(wc.dispose);
      wc.repo.addTransaction(date: '2026-10-12', amount: 8420, category: 'Groceries');
      wc.snoozeKeyBackup();
      wc.reload();
      await _pump(tester, wc);
      expect(find.text('No salary found yet.'), findsOneWidget);
      expect(find.textContaining('Import'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('heatmap', () {
    testWidgets('one square per day, shaded by size; empty for nothing or a refund; to come after today', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc);
      final c = tester.element(_k('reportHeatmap:2026-10-05')).c;
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('heatDay:')),
          findsNWidgets(31),
          reason: '5 Oct to 4 Nov');
      // 84.20 is the biggest day: the darkest level; 25.00 and 10.00 are lighter, in order.
      final big = _fill(tester, '2026-10-12'), mid = _fill(tester, '2026-10-14'), small = _fill(tester, '2026-10-18');
      expect(big, c.s1);
      expect({big, mid, small, c.surface2}.length, 4, reason: 'four different shades');
      expect(heatLevel(8420, 8420), 4);
      expect(heatLevel(2500, 8420), 2);
      expect(heatLevel(1000, 8420), 1);
      // Nothing spent, a net refund: empty. Rent is fixed money, not flexible, so the 7th is empty too.
      expect(_fill(tester, '2026-10-06'), c.surface2);
      expect(_fill(tester, '2026-10-07'), c.surface2);
      expect(_fill(tester, '2026-10-16'), c.surface2);
      // After today (20 Oct): an outline, no fill. Today itself is a normal square.
      expect(_fill(tester, '2026-10-21'), isNull);
      expect(_fill(tester, '2026-11-04'), isNull);
      expect(_fill(tester, '2026-10-20'), c.surface2);
      expect(find.text('Less'), findsOneWidget);
      expect(find.text('More'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the readout starts on the biggest day; a tap shows that day exact, a refund day too', (tester) async {
      final wc = _wallet();
      await _pump(tester, wc);
      expect(_in('heatReadout', '12 Oct'), findsOneWidget);
      expect(_in('heatReadout', '84.20\u00A0€'), findsOneWidget);
      await tester.tap(_k('heatDay:2026-10-14'));
      await tester.pump();
      expect(_in('heatReadout', '14 Oct'), findsOneWidget);
      expect(_in('heatReadout', '25\u00A0€'), findsOneWidget);
      await tester.tap(_k('heatDay:2026-10-16'));
      await tester.pump();
      expect(_in('heatReadout', '16 Oct'), findsOneWidget);
      expect(_in('heatReadout', moneyExact(-750, 'EUR')), findsOneWidget);
      await tester.tap(_k('heatDay:2026-10-06'));
      await tester.pump();
      expect(_in('heatReadout', '0\u00A0€'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('one spoken label for the tile; a finished period has no days to come', (tester) async {
      final handle = tester.ensureSemantics();
      final wc = _wallet();
      await _pump(tester, wc);
      expect(find.bySemanticsLabel('31 days, spending on 3, biggest day 12 Oct, 84.20\u00A0€, 15 to come'), findsOneWidget);
      await _tapIcon(tester, 'reportPrev');
      expect(find.bySemanticsLabel('30 days, spending on 2, biggest day 10 Sep, 200\u00A0€'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('heatDay:')),
          findsNWidgets(30));
      handle.dispose();
    });

    testWidgets('a row dated after today stays a day to come: no shade, not the biggest day', (tester) async {
      final handle = tester.ensureSemantics();
      final wc = _wallet();
      wc.repo.addTransaction(date: '2026-10-25', amount: 99999, category: 'Groceries');
      wc.reload();
      await _pump(tester, wc);
      expect(_fill(tester, '2026-10-25'), isNull);
      expect(_in('heatReadout', '12 Oct'), findsOneWidget);
      expect(find.bySemanticsLabel('31 days, spending on 3, biggest day 12 Oct, 84.20\u00A0€, 15 to come'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a day to come is not tappable: the readout never shows a future amount', (tester) async {
      final wc = _wallet();
      wc.repo.addTransaction(date: '2026-10-25', amount: 99999, category: 'Groceries');
      wc.reload();
      await _pump(tester, wc);
      await tester.tap(_k('heatDay:2026-10-25'), warnIfMissed: false);
      await tester.pump();
      expect(_in('heatReadout', '12 Oct'), findsOneWidget);
      expect(_in('heatReadout', moneyExact(99999, 'EUR')), findsNothing);
      expect(_in('heatReadout', '25 Oct'), findsNothing);
      // Today and earlier days still answer.
      await tester.tap(_k('heatDay:2026-10-14'));
      await tester.pump();
      expect(_in('heatReadout', '14 Oct'), findsOneWidget);
    });

    testWidgets('a period with no flexible spending says so and shows no readout', (tester) async {
      final handle = tester.ensureSemantics();
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => _clock);
      addTearDown(wc.dispose);
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-05', 150000, 'Plaća/Mirovina', 'Neto placa synthetic c'),
      ]));
      wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'paydayDay': 5});
      wc.snoozeKeyBackup();
      wc.reload();
      await _pump(tester, wc);
      expect(find.bySemanticsLabel('31 days, no spending, 15 to come'), findsOneWidget);
      expect(_k('heatReadout'), findsNothing);
      expect(_kept('1,500\u00A0€'), findsOneWidget);
      handle.dispose();
    });
  });

  group('how the page opens', () {
    testWidgets('the app bar chip opens it on a phone', (tester) async {
      final wc = _wallet();
      await pumpFull(tester, wc, 1, size: const Size(400, 800));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_k('reportKept'), findsNothing);
      await tester.tap(_k('periodChip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(_k('reportKept'), findsOneWidget);
      expect(_kept('988.30\u00A0€'), findsOneWidget);
      await tester.tap(_k('sheetClose'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(_k('reportKept'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the chip and the badge can be activated by a screen reader (tap action), and it opens the page', (tester) async {
      final handle = tester.ensureSemantics();
      final wc = _wallet();
      await pumpFull(tester, wc, 1, size: const Size(400, 800));
      await tester.pump(const Duration(milliseconds: 400));
      final chip = find.semantics.byLabel(RegExp('^Pay-period report, '));
      expect(chip, findsOneWidget);
      expect(chip.evaluate().single.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.semantics.tap(chip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(_k('reportKept'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the rail badge opens it as a dialog on a wide window', (tester) async {
      final wc = _wallet();
      await pumpFull(tester, wc, 1, size: const Size(1280, 800));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_k('periodChip'), findsNothing);
      await tester.tap(_k('periodBadgeTap'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(Dialog), findsOneWidget);
      expect(_kept('988.30\u00A0€'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the rail badge has a tap action for screen readers and it opens the dialog', (tester) async {
      final handle = tester.ensureSemantics();
      final wc = _wallet();
      await pumpFull(tester, wc, 1, size: const Size(1280, 800));
      await tester.pump(const Duration(milliseconds: 400));
      final badge = find.semantics.byLabel(RegExp('^Pay-period report, '));
      expect(badge, findsOneWidget);
      expect(badge.evaluate().single.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.semantics.tap(badge);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(Dialog), findsOneWidget);
      handle.dispose();
    });
  });

  group('layout', () {
    for (final (w, h, scale) in const [(320.0, 700.0, 2.0), (360.0, 800.0, 1.0), (1280.0, 900.0, 1.0)]) {
      for (final mode in Brightness.values) {
        testWidgets('${w.round()} dp x $scale, ${mode.name}: no overflow, the page scrolls to its end', (tester) async {
          final wc = _wallet();
          await _pump(tester, wc, size: Size(w, h), scale: scale, mode: mode);
          scanFlex(tester);
          await tester.dragUntilVisible(_k('reportSaved'), _k('periodReportPage'), const Offset(0, -200));
          await tester.pump();
          scanFlex(tester);
          expect(overflowing, isEmpty, reason: overflowing.join('\n'));
          overflowing.clear();
          expect(tester.takeException(), isNull);
          // The first period too (fewer tiles' content, a longer name).
          await _tapIcon(tester, 'reportPrev');
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
