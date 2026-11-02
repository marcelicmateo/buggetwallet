// ENG E2/E3: the Overview's € | hours switch, its found and pinned sections, and the Findings screen. SYNTHETIC data only.
import 'dart:convert';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/findings.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/layout.dart';
import 'support/wallet.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

/// The demo wallet with a payment a day for 380 days before today: the days and payments milestones fire. One main tag is pinned.
WalletController _foundWallet({bool pin = true}) {
  final wc = demoWallet(clock: pinnedNoon);
  final today = wc.today();
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    for (var i = 3; i < 380; i++) syntheticTx(addDays(today, -i), -1500 - i, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
  ]));
  wc.reload();
  if (pin) {
    final cat = wc.txs.firstWhere((t) => t.tx.description.contains('LIDL')).category;
    final q = SeriesQuery(
        measure: Measure.spent,
        keys: [SeriesKey(SeriesKind.mainTag, cat)],
        bucket: Bucket.month,
        window: DateRange(start: addDays(today, -300), end: today));
    final id = wc.repo.addView(name: 'Food per month', query: jsonEncode(q.toJson()));
    wc.repo.patchView(id, pinned: true);
    wc.reload();
  }
  return wc;
}

/// Every text on screen that shows an amount in euro (a number, a no-break space, the sign).
Iterable<String> _euroTexts(WidgetTester t) => [
      for (final w in t.widgetList<RichText>(find.byType(RichText)))
        if (RegExp(r'\d[  ]€').hasMatch(w.text.toPlainText())) w.text.toPlainText()
    ];

Finding _f(FindingKind kind,
        {String subject = 'food',
        String? other,
        int n = 12,
        int? strength,
        int? ratio,
        List<(String, int)>? series,
        List<(String, int)>? otherSeries}) =>
    Finding(
        id: '${kind.name}:$subject',
        kind: kind,
        subjectKey: subject,
        otherKey: other,
        from: '2025-01-01',
        to: '2026-10-28',
        n: n,
        strengthPermille: strength,
        ratioPermille: ratio,
        series: series ?? [for (var i = 0; i < 12; i++) ('2025-${(i + 1).toString().padLeft(2, '0')}', 5000 + i * 300)],
        otherSeries: otherSeries ?? const []);

void main() {
  group('hours switch', () {
    testWidgets('switches every amount and its unit, and back', (t) async {
      final wc = demoWallet(clock: pinnedNoon);
      await pumpFull(t, wc, 1.0, size: const Size(400, 1400));
      expect(_key('hoursSwitch'), findsOneWidget);
      expect(_euroTexts(t), isNotEmpty);
      expect(t.widget<Text>(_key('safeToSpend')).textSpan?.toPlainText() ?? t.widget<Text>(_key('safeToSpend')).data, contains('€'));

      await t.tap(_key('amountsHours'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      final hero = t.widget<Text>(_key('safeToSpend'));
      final heroText = hero.textSpan?.toPlainText() ?? hero.data!;
      expect(heroText, matches(RegExp(r'^\d[\d.,]* h$')));
      expect(_euroTexts(t), isEmpty, reason: 'no euro amount is left on the Overview');
      expect(wc.showHours, isTrue);

      await t.tap(_key('amountsMoney'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(_euroTexts(t), isNotEmpty);
      expect(wc.showHours, isFalse);
    });

    testWidgets('is hidden without a salary', (t) async {
      final wc = emptyWallet();
      await pumpFull(t, wc, 1.0, size: const Size(400, 900));
      expect(_key('hoursSwitch'), findsNothing);
      wc.setShowHours(true);
      expect(wc.showHours, isFalse);
    });

    test('hours text is one decimal; foreign amounts stay money', () {
      final wc = demoWallet(clock: pinnedNoon);
      wc.setShowHours(true);
      // 1,500 EUR a month at 40 h a week: 173.33 h, so 100 EUR is 11.6 h (tenths rounded once).
      expect(wc.amountText(10000, 'EUR'), '11.6\u00A0h');
      expect(wc.amountText(10000, 'USD'), isNot(contains('h')));
    });
  });

  group('found and pinned', () {
    testWidgets('no data: neither section is on screen', (t) async {
      await pumpFull(t, demoWallet(clock: pinnedNoon), 1.0, size: const Size(400, 1400));
      expect(_key('foundSection'), findsNothing);
      expect(_key('pinnedSection'), findsNothing);
      expect(_key('goalBar'), findsOneWidget); // the demo wallet has goals with targets
    });

    testWidgets('with data: found cards and the pinned tile show; "All N" opens Findings', (t) async {
      final wc = _foundWallet();
      await pumpFull(t, wc, 1.0, size: const Size(400, 3000));
      expect(_key('foundSection'), findsOneWidget);
      expect(_key('pinnedSection'), findsOneWidget);
      await t.tap(_key('foundAll'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(_key('findingsPage'), findsOneWidget);
      expect(find.textContaining('A link is not proof of a cause.'), findsOneWidget);
      expect(find.textContaining('days of your data'), findsOneWidget);
    });

    testWidgets('long press on a pin unpins it; Undo brings it back', (t) async {
      final wc = _foundWallet();
      await pumpFull(t, wc, 1.0, size: const Size(400, 3000));
      final pin = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key! as ValueKey).value.toString().startsWith('pin:'));
      expect(pin, findsOneWidget);
      await t.longPress(pin);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(wc.pinnedViews(), isEmpty, reason: 'the long press unpinned the view');
      expect(_key('pinnedSection'), findsNothing);
      await t.tap(_key('toastUndo'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(_key('pinnedSection'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('layouts: 320 dp at 2.0, and two columns at 1400 dp, light content, no overflow', (t) async {
      for (final (size, scale) in [(const Size(320, 640), 2.0), (const Size(1400, 900), 1.0)]) {
        final wc = _foundWallet();
        await withErrors((errors) async {
          await pumpFull(t, wc, scale, size: size);
          await t.pump(const Duration(milliseconds: 500));
          await scrollThrough(t);
          if (size.width > 1300) {
            final found = t.getTopLeft(_key('foundSection')).dx, hero = t.getTopLeft(_key('heroTile')).dx;
            expect(found, greaterThan(hero + 300), reason: 'found sits in the right column');
          }
          errors.check();
        });
        await t.pump(const Duration(seconds: 4));
      }
    });
  });

  group('cards follow the hours switch, pins use completed buckets', () {
    /// A payment a month for 12 months (5,000 cents), two big ones this month: "above your usual month" fires.
    WalletController aboveUsualWallet() {
      final wc = demoWallet(clock: pinnedNoon);
      final today = wc.today();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        for (var m = 1; m <= 13; m++) syntheticTx(addDays(today, -30 * m), -5000, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
        syntheticTx(addDays(today, -20), -10000, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
        syntheticTx(today, -10001, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB'),
      ]));
      wc.reload();
      return wc;
    }

    test('the above-usual basis switches unit with the toggle (memo keyed on the switch)', () {
      final wc = aboveUsualWallet();
      addTearDown(wc.dispose);
      FindingCard card() => wc.foundCards().firstWhere((k) => k.finding.kind == FindingKind.aboveUsual);
      expect(card().basis, contains('€'));
      wc.setShowHours(true);
      expect(card().basis, matches(RegExp(r'\d\u00A0h this month$')));
      expect(card().basis, isNot(contains('€')));
      wc.setShowHours(false);
      expect(card().basis, contains('€'));
    });

    test('a pin shows its last completed bucket, never the running one', () {
      final wc = _foundWallet();
      addTearDown(wc.dispose);
      final v = wc.pinnedViews().single;
      final rows = runQuery(wc.queryIndex, v.parsed!, today: wc.today());
      final done = [
        for (final r in rows)
          if (!r.partial) r
      ];
      expect(rows.last.partial, isTrue, reason: 'this month is running');
      final pin = wc.pinData(v)!;
      expect(pin.last, done.last.together);
      expect(pin.values, hasLength(done.length));
    });
  });

  group('Findings screen', () {
    testWidgets('dismiss hides the milestones, Undo shows them', (t) async {
      final wc = _foundWallet(pin: false);
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => openFindings(c, wc), child: const Text('go'))))));
      await t.tap(find.text('go'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(_key('finding:milestones'), findsOneWidget);
      expect(_key('findingBasis:milestones'), findsOneWidget);
      await t.tap(_key('findingDismiss:milestones'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(_key('finding:milestones'), findsNothing);
      expect(_key('findingsEmpty'), findsOneWidget);
      await t.tap(_key('toastUndo').last); // the page and the host both hold a Scaffold here
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(_key('finding:milestones'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('each kind draws its evidence and its basis line', (t) async {
      final wc = _foundWallet(pin: false);
      final cards = <FindingCard>[
        FindingCard(_f(FindingKind.weeklyRhythm, subject: 'all', ratio: 2100, series: [for (var i = 1; i <= 7; i++) ('$i', 1000 * i)]),
            'Weekly rhythm', 'Sundays cost you 2.1× your cheapest day', 'Average spend per day of the week, 12 months. Tap a bar.'),
        FindingCard(
            _f(FindingKind.movesTogether,
                other: 'fuel',
                strength: 620,
                series: [for (var i = 0; i < 12; i++) ('m$i', 100 * i)],
                otherSeries: [for (var i = 0; i < 12; i++) ('m$i', 90 * i + 7)]),
            'Moves together',
            'Food and Fuel move together',
            '12 months, link strength 0.62 of 1: fairly strong.',
            subjectName: 'Food',
            otherName: 'Fuel'),
        FindingCard(_f(FindingKind.slowCreep, ratio: 1600, series: [('a', 6400), ('b', 8000), ('c', 10400)]), 'Slow creep',
            'Gym went from 64 € to 104 € a month', '3 months of payments, 60 % up.'),
        FindingCard(_f(FindingKind.aboveUsual, ratio: 1340), 'Above usual', 'Food is 34 % above your usual month',
            'vs 12-month median · 96 € this month'),
        FindingCard(_f(FindingKind.seasonality, other: '12'), 'Seasonality', 'December is your priciest month for Food',
            'The top month in 3 years.'),
      ];
      await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: Column(children: [
            for (final k in cards) FindingCardView(wc: wc, card: k, onExplore: () {}),
          ])))));
      for (final k in cards) {
        await t.ensureVisible(_key('finding:${k.finding.id}'));
        expect(find.descendant(of: _key('finding:${k.finding.id}'), matching: find.text(k.basis)), findsOneWidget, reason: k.eyebrow);
        expect(_key('findingExplore:${k.finding.id}'), findsOneWidget);
      }
      // The weekday bars: a tap puts that day's exact amount in the label.
      await t.ensureVisible(_key('weekBar:0'));
      await t.tap(_key('weekBar:0'));
      await t.pump();
      expect(t.widget<Text>(_key('weekBarValue')).data, wc.amountText(1000, wc.currency));
      // The step line writes its first and last value.
      expect(t.widget<Text>(_key('stepFirst')).data, wc.amountText(6400, wc.currency));
      expect(t.widget<Text>(_key('stepLast')).data, wc.amountText(10400, wc.currency));
      await t.pump(const Duration(seconds: 4));
    });
  });

  test('the TodayView facade hands out pins only for queries this build can run', () {
    final wc = _foundWallet();
    final view = TodayView(wc);
    expect(view.pins(), hasLength(1));
    expect(view.pins().single.name, 'Food per month');
    wc.dispose();
  });
}
