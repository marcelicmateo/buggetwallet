// Stage Q7 UI: the search filter chips (Amount, Date, Category, Has attachment, Split, Uncategorised), filter-only search, the bold match,
// and the search button on Today's Recent panel. All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart' show NumberStyle, numberStyle;
import 'package:budget_wallet/src/screens/search.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/theme.dart' show buildTheme;
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _timeout = Timeout(Duration(seconds: 60));

Finder k(String key) => find.byKey(ValueKey(key));

/// Five bank rows (names are made up): A split in two, B with an own main tag, C with an attachment, D old and plain, E with accents.
class SearchData {
  final WalletController wc;
  final Map<String, String> id; // letter -> payment id
  SearchData(this.wc, this.id);
}

SearchData searchData() {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-02', -1850, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-05', -940, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-08', -12000, 'POS plaćanje', 'POS ZARA ZAGREB'),
    syntheticTx('2026-09-20', -5000, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
    syntheticTx('2026-10-10', -300, 'POS plaćanje', 'POS KAVANA CACAK ZAGREB'),
  ]));
  final byDate = {for (final t in wc.repo.transactions()) t.date: t};
  final id = {
    'A': byDate['2026-10-02']!.id,
    'B': byDate['2026-10-05']!.id,
    'C': byDate['2026-10-08']!.id,
    'D': byDate['2026-09-20']!.id,
    'E': byDate['2026-10-10']!.id
  };
  wc.repo.setCategory(id['B']!, 'Eating out');
  wc.repo.setSplit(id['A']!, const [
    SplitPart(amount: -1000, category: 'Groceries'),
    SplitPart(amount: -850, category: 'Shopping'),
  ]);
  wc.repo.addAttachment(id['C']!, BlobRef(hash: 'c' * 64, type: 'jpg', bytes: 300));
  wc.repo.saveGoal(name: 'Štednja za more', target: 100000, saved: 0, monthly: 1000, sort: 1);
  wc.reload();
  return SearchData(wc, id);
}

Future<void> pumpPane(WidgetTester t, WalletController wc,
    {Size size = const Size(400, 900), double textScale = 1, RangePickerFn? picker}) async {
  await pumpApp(t,
      Scaffold(body: SearchPane(wc: wc, onClose: () {}, onOpenTab: (_) {}, onOpenBills: () {}, picker: picker ?? (c, i, f, l) async => i)),
      size: size, textScale: textScale);
  await t.pump(const Duration(milliseconds: 100));
}

typedef RangePickerFn = Future<DateTimeRange?> Function(BuildContext, DateTimeRange, DateTime, DateTime);

Future<void> settle(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 300));
  await t.pump();
}

Future<void> tapKey(WidgetTester t, String key) async {
  final f = k(key).last;
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pumpAndSettle();
}

/// The letters of the payments listed.
Set<String> hits(WidgetTester t, SearchData d) {
  final shown = {
    for (final e in find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('hit:')).evaluate())
      ((e.widget.key as ValueKey).value as String).substring(4)
  };
  return {
    for (final e in d.id.entries)
      if (shown.contains(e.value)) e.key
  };
}

Future<void> amountSheet(WidgetTester t, {String? min, String? max}) async {
  await tapKey(t, 'filterAmount');
  if (min != null) await t.enterText(k('filterMin'), min);
  if (max != null) await t.enterText(k('filterMax'), max);
  await tapKey(t, 'filterAmountApply');
}

void main() {
  group('filters', () {
    testWidgets('Amount: from and up to, shown on the chip, cleared by its X', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc);
      await amountSheet(t, min: '10', max: '100');
      expect(hits(t, d), {'A', 'D'}, reason: '18.50 and 50.00; 9.40 and 120.00 are out');
      expect(find.descendant(of: k('filterAmount'), matching: find.textContaining('10.00')), findsOneWidget);
      expect(k('filterNote'), findsOneWidget);
      // Only an upper bound.
      await amountSheet(t, min: '', max: '10');
      expect(hits(t, d), {'B', 'E'});
      // The X clears it.
      await t.tap(find.descendant(of: k('filterAmount'), matching: find.byIcon(Icons.close)));
      await t.pumpAndSettle();
      expect(k('filterNote'), findsNothing);
      expect(hits(t, d), isEmpty, reason: 'no filter and no text: nothing is listed');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('Amount refuses text that is not an amount and a smallest above the largest', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc);
      await tapKey(t, 'filterAmount');
      await t.enterText(k('filterMin'), 'abc');
      await tapKey(t, 'filterAmountApply');
      expect(k('filterAmountApply'), findsOneWidget, reason: 'the sheet stays');
      expect(find.textContaining('Enter an amount'), findsOneWidget);
      await t.enterText(k('filterMin'), '50');
      await t.enterText(k('filterMax'), '10');
      await tapKey(t, 'filterAmountApply');
      expect(find.textContaining('above the largest'), findsOneWidget);
      expect(k('filterNote'), findsNothing);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('Date: the picked range, both days included', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc, picker: (c, i, f, l) async => DateTimeRange(start: DateTime(2026, 10, 2), end: DateTime(2026, 10, 5)));
      await tapKey(t, 'filterDate');
      expect(hits(t, d), {'A', 'B'});
      await t.tap(find.descendant(of: k('filterDate'), matching: find.byIcon(Icons.close)));
      await t.pumpAndSettle();
      expect(hits(t, d), isEmpty);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('Date: cancelling the picker changes nothing', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc, picker: (c, i, f, l) async => null);
      await tapKey(t, 'filterDate');
      expect(k('filterNote'), findsNothing);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('Category: a main tag, a split payment by one of its parts, and the chip says how many', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc);
      await tapKey(t, 'filterCategory');
      await tapKey(t, 'filterCat:Eating out');
      await tapKey(t, 'filterCategoryApply');
      expect(hits(t, d), {'B'});
      expect(find.descendant(of: k('filterCategory'), matching: find.text('Eating out')), findsOneWidget);
      await tapKey(t, 'filterCategory');
      await tapKey(t, 'filterCat:Shopping');
      await tapKey(t, 'filterCategoryApply');
      expect(hits(t, d).containsAll({'A', 'B', 'C'}), isTrue, reason: 'A has a Shopping part');
      expect(find.descendant(of: k('filterCategory'), matching: find.text('2 categories')), findsOneWidget);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('Has attachment, Split and Uncategorised each alone', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc);
      await tapKey(t, 'filterAttachment');
      expect(hits(t, d), {'C'});
      await tapKey(t, 'filterAttachment');
      expect(k('filterNote'), findsNothing, reason: 'a second tap switches it off');
      await tapKey(t, 'filterSplit');
      expect(hits(t, d), {'A'});
      await tapKey(t, 'filterSplit');
      await tapKey(t, 'filterUncategorised');
      expect(hits(t, d), {'C', 'D', 'E'}, reason: 'A is split and B has its own main tag');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('filters combine, and a typed text narrows them further', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc);
      await tapKey(t, 'filterUncategorised');
      await amountSheet(t, min: '10');
      expect(hits(t, d), {'C', 'D'});
      await tapKey(t, 'filterAttachment');
      expect(hits(t, d), {'C'});
      await tapKey(t, 'filterAttachment');
      await t.enterText(k('searchField'), 'zara');
      await settle(t);
      expect(hits(t, d), {'C'});
      await t.enterText(k('searchField'), 'konzum');
      await settle(t);
      expect(hits(t, d), {'D'});
      await settle(t);
    }, timeout: _timeout);

    testWidgets('with a filter on only payments are listed, even for a text that matches a goal', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc);
      await t.enterText(k('searchField'), 'stednja');
      await settle(t);
      expect(find.text('GOALS'), findsOneWidget);
      await tapKey(t, 'filterSplit');
      expect(find.text('GOALS'), findsNothing);
      expect(find.text('Nothing found'), findsOneWidget);
      await settle(t);
    }, timeout: _timeout);
  });

  group('bold match', () {
    /// The bold pieces of the Text widgets under [of].
    List<String> boldPieces(Finder of) {
      final out = <String>[];
      for (final e in find.descendant(of: of, matching: find.byType(Text)).evaluate()) {
        final span = (e.widget as Text).textSpan;
        if (span is! TextSpan) continue;
        for (final c in span.children ?? const <InlineSpan>[]) {
          if (c is TextSpan && c.style?.fontWeight == FontWeight.w800) out.add(c.toPlainText());
        }
      }
      return out;
    }

    testWidgets('the typed text is bold in the payee name, in any case', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc);
      await t.enterText(k('searchField'), 'KONZ');
      await settle(t);
      final bold = boldPieces(k('hit:${d.id['D']}'));
      expect(bold, hasLength(1));
      expect(foldText(bold.single), 'konz');
      await settle(t);
    }, timeout: _timeout);

    testWidgets('accents match: "stednja" is bold in "Štednja za more"', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc);
      await t.enterText(k('searchField'), 'stednja');
      await settle(t);
      final all = find.byKey(const ValueKey('searchResults'));
      expect(boldPieces(all), contains('Štednja'));
      await settle(t);
    }, timeout: _timeout);

    testWidgets('a text with no match stays plain', (t) async {
      await t.pumpWidget(const MaterialApp(home: Highlighted('Konzum', 'xyz')));
      expect(find.text('Konzum'), findsOneWidget);
      expect(t.widget<Text>(find.byType(Text)).textSpan, isNull);
      await t.pumpWidget(const MaterialApp(home: Highlighted('Konzum', 'ZUM')));
      final span = t.widget<Text>(find.byType(Text)).textSpan! as TextSpan;
      expect([for (final c in span.children!) c.toPlainText()], ['Kon', 'zum']);
    });
  });

  group('chips', () {
    testWidgets('a selected chip takes the on-accent ink, in the light and the dark theme', (t) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        final d = searchData();
        addTearDown(d.wc.dispose);
        t.view.physicalSize = const Size(400, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
            theme: buildTheme(brightness),
            home: Scaffold(
                body: SearchPane(wc: d.wc, onClose: () {}, onOpenTab: (_) {}, onOpenBills: () {}, picker: (c, i, f, l) async => i))));
        await t.pump(const Duration(milliseconds: 100));
        await tapKey(t, 'filterUncategorised');
        await amountSheet(t, min: '10');
        final onAccent = Theme.of(t.element(k('filterAmount'))).colorScheme.onPrimary;
        for (final key in ['filterUncategorised', 'filterAmount']) {
          final label = find.descendant(of: k(key), matching: find.textContaining(RegExp('Uncategorised|10')));
          expect(DefaultTextStyle.of(t.element(label.first)).style.color, onAccent, reason: '$key $brightness');
        }
        await expectLater(t, meetsGuideline(textContrastGuideline));
        await t.pumpWidget(const SizedBox());
      }
      await settle(t);
    }, timeout: _timeout);
  });

  group('number style', () {
    tearDown(() => numberStyle = NumberStyle.point);

    testWidgets('1.234,50 in the Amount field is 1234.50 in the comma style', (t) async {
      final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
      addTearDown(wc.dispose);
      wc.repo.setLocalValue('numberStyle', 'comma'); // the controller applies the stored style on every reload
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
        syntheticTx('2026-10-02', -123449, 'POS plaćanje', 'POS KONZUM 0000 ZAGREB'),
        syntheticTx('2026-10-03', -123450, 'POS plaćanje', 'POS ZARA ZAGREB'),
        syntheticTx('2026-10-04', -123451, 'POS plaćanje', 'POS IKEA ZAGREB'),
      ]));
      wc.reload();
      final byDate = {for (final c in wc.wholeTxs) c.tx.date: c.tx.id};
      await pumpPane(t, wc);
      await amountSheet(t, min: '1.234,50');
      expect(find.textContaining('Enter an amount'), findsNothing);
      final shown = {
        for (final e
            in find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('hit:')).evaluate())
          ((e.widget.key as ValueKey).value as String).substring(4)
      };
      expect(shown, {byDate['2026-10-03'], byDate['2026-10-04']});
      expect(find.descendant(of: k('filterAmount'), matching: find.textContaining('1.234,50')), findsOneWidget);
      await settle(t);
    }, timeout: _timeout);
  });

  group('layout', () {
    testWidgets('320 dp at text scale 2.0: chip row, results and the Amount and Category sheets', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc, size: const Size(320, 640), textScale: 2);
      await tapKey(t, 'filterUncategorised');
      expect(t.takeException(), isNull);
      await tapKey(t, 'filterAmount');
      expect(t.takeException(), isNull);
      await tapKey(t, 'filterAmountApply');
      await tapKey(t, 'filterCategory');
      expect(t.takeException(), isNull);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('a wide window wraps the chips', (t) async {
      final d = searchData();
      addTearDown(d.wc.dispose);
      await pumpPane(t, d.wc, size: const Size(1280, 800));
      for (final key in ['filterAmount', 'filterDate', 'filterCategory', 'filterAttachment', 'filterSplit', 'filterUncategorised']) {
        expect(k(key), findsOneWidget, reason: key);
      }
      expect(t.takeException(), isNull);
      await settle(t);
    }, timeout: _timeout);
  });

  group('Today', () {
    testWidgets('the Recent panel has a search button that calls openSearch', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      var opened = 0;
      await pumpApp(
          t, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, openSearch: () => opened++, clock: () => budgetToday)));
      await t.pump(const Duration(milliseconds: 100));
      final f = k('todaySearch');
      await t.ensureVisible(f);
      await t.pump();
      await t.tap(f);
      await t.pump();
      expect(opened, 1);
      await settle(t);
    }, timeout: _timeout);

    testWidgets('without openSearch there is no button', (t) async {
      final wc = budgetWallet();
      addTearDown(wc.dispose);
      await pumpApp(t, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday)));
      await t.pump(const Duration(milliseconds: 100));
      expect(k('todaySearch'), findsNothing);
      await settle(t);
    }, timeout: _timeout);
  });
}
