// Stage Q8 app half: the Owed panel on the Save tab, the IOU sheet (repayments, Close, Delete + Undo), "Lent to someone" and "Repayment" on
// a payment, the row tags, and the owner-readable validation messages. Fixed clock (20 Oct 2026), synthetic data only.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/owed.dart';
import 'package:budget_wallet/src/screens/save.dart';
import 'package:budget_wallet/src/screens/today.dart';
import 'package:budget_wallet/src/screens/today_view.dart';
import 'package:budget_wallet/src/widgets/common.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _t = Timeout(Duration(seconds: 60));

Finder _key(String k) => find.byKey(ValueKey(k));

/// What the summary tile with [key] says (its spoken label: both numbers), and the two figures it shows.
String _sum(WidgetTester t, String key) => t.widget<Tile>(_key(key)).semanticLabel!;
Finder _fig(String key, String text) => find.descendant(of: _key(key), matching: find.text(text));

WalletController _wallet() {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  addTearDown(wc.dispose);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
  return wc;
}

Future<void> _panel(WidgetTester t, WalletController wc, {double scale = 1, Size size = const Size(400, 1200)}) =>
    pumpApp(t, Scaffold(body: SingleChildScrollView(child: OwedPanel(wc: wc))), textScale: scale, size: size);

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _type(WidgetTester t, String key, String text) async {
  await t.ensureVisible(_key(key));
  await t.enterText(_key(key), text);
  await t.pump();
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.ensureVisible(_key(key));
  await t.pump();
  await t.tap(_key(key));
  await t.pump();
}

/// A widget test that lets the controller's 3 s sync debounce run out at the end (a pending timer fails the test).
void tw(String name, Future<void> Function(WidgetTester t) body, {Timeout? timeout}) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 4));
    }, timeout: timeout);

void main() {
  group('Owed panel', () {
    tw('empty: a note and Add; Add opens the sheet, Save adds a line and the totals', (t) async {
      final wc = _wallet();
      await _panel(t, wc);
      expect(_key('owedPanel'), findsOneWidget);
      expect(find.text('Nothing owed'), findsOneWidget);
      await t.tap(_key('owedAdd'));
      await _settle(t);
      expect(_key('iouSheet'), findsOneWidget);
      await _type(t, 'iouPerson', 'Sam');
      await _type(t, 'iouAmount', '50.00');
      await _tap(t, 'iouSave');
      await _settle(t);
      final v = wc.iousAll().single;
      expect((v.iou.person, v.iou.amount, v.iou.direction), ('Sam', 5000, IouDirection.lent));
      expect(_key('iou:${v.iou.id}'), findsOneWidget);
      expect(_sum(t, 'owedSummary'), 'People owe you ${moneyExact(5000, 'EUR')}, you owe ${moneyExact(0, 'EUR')}');
      expect(_fig('owedSummary', moneyExact(5000, 'EUR')), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    }, timeout: _t);

    tw('borrowed money is in "You owe"', (t) async {
      final wc = _wallet();
      wc.addIou(person: 'Alex', direction: IouDirection.borrowed, amount: 3500, date: '2026-10-10');
      await _panel(t, wc);
      expect(_sum(t, 'owedSummary'), 'People owe you ${moneyExact(0, 'EUR')}, you owe ${moneyExact(3500, 'EUR')}');
      expect(_fig('owedSummary', moneyExact(3500, 'EUR')), findsOneWidget);
      expect(find.textContaining('you owe'), findsWidgets);
    }, timeout: _t);

    tw('only foreign IOUs: a total per currency, never "0 €" for the wallet', (t) async {
      final wc = _wallet();
      wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 5000, date: '2026-10-10', currency: 'USD');
      wc.addIou(person: 'Alex', direction: IouDirection.borrowed, amount: 2000, date: '2026-10-10', currency: 'USD');
      await _panel(t, wc);
      expect(_key('owedSummary'), findsNothing);
      expect(_sum(t, 'owedSummary:USD'), 'In USD: People owe you ${moneyExact(5000, 'USD')}, you owe ${moneyExact(2000, 'USD')}');
      expect(find.descendant(of: _key('owedSummary:USD'), matching: find.text('In USD')), findsOneWidget);
      expect(find.textContaining('0 €'), findsNothing);
    }, timeout: _t);

    tw('mixed currencies: the wallet total first, the others on their own line', (t) async {
      final wc = _wallet();
      wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 5000, date: '2026-10-10');
      wc.addIou(person: 'Alex', direction: IouDirection.lent, amount: 3000, date: '2026-10-10', currency: 'USD');
      await _panel(t, wc);
      expect(_sum(t, 'owedSummary'), 'People owe you ${moneyExact(5000, 'EUR')}, you owe ${moneyExact(0, 'EUR')}');
      expect(_sum(t, 'owedSummary:USD'), 'In USD: People owe you ${moneyExact(3000, 'USD')}, you owe ${moneyExact(0, 'USD')}');
      expect(t.getTopLeft(_key('owedSummary')).dy, lessThan(t.getTopLeft(_key('owedSummary:USD')).dy), reason: 'the wallet currency first');
    }, timeout: _t);

    tw('a person with two IOUs is one group, a line per IOU under the name; one IOU stays a single line', (t) async {
      final wc = _wallet();
      final a = wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 5000, date: '2026-10-10');
      final b = wc.addIou(person: 'sam', direction: IouDirection.lent, amount: 2500, date: '2026-10-12');
      final c = wc.addIou(person: 'Alex', direction: IouDirection.lent, amount: 1000, date: '2026-10-11');
      await _panel(t, wc);
      expect(_key('owedPerson:sam'), findsOneWidget);
      expect(find.descendant(of: _key('owedPerson:sam'), matching: find.text('sam')), findsOneWidget); // the newest IOU's spelling
      expect(find.descendant(of: _key('owedPerson:sam'), matching: _key('iou:$a')), findsOneWidget);
      expect(find.descendant(of: _key('owedPerson:sam'), matching: _key('iou:$b')), findsOneWidget);
      expect(_key('owedPerson:alex'), findsNothing);
      expect(_key('iou:$c'), findsOneWidget);
      await t.tap(_key('iou:$b'));
      await _settle(t);
      expect(_key('iouSheet'), findsOneWidget);
    }, timeout: _t);

    tw('validation shows core\'s message: no name, a zero amount, a name that is too long', (t) async {
      final wc = _wallet();
      await _panel(t, wc);
      await t.tap(_key('owedAdd'));
      await _settle(t);
      await _type(t, 'iouAmount', '10.00');
      await _tap(t, 'iouSave');
      expect(find.textContaining('Say who the money is with.'), findsOneWidget);
      await _type(t, 'iouPerson', 'Sam');
      await _type(t, 'iouAmount', '0');
      await _tap(t, 'iouSave');
      expect(find.textContaining('Enter an amount above zero.'), findsOneWidget);
      await _type(t, 'iouAmount', 'abc');
      await _tap(t, 'iouSave');
      expect(find.textContaining(invalidAmountMessage), findsOneWidget);
      await _type(t, 'iouPerson', 'x' * (Iou.maxPerson + 1));
      await _type(t, 'iouAmount', '5.00');
      await _tap(t, 'iouSave');
      expect(find.textContaining('The name is limited to ${Iou.maxPerson} characters.'), findsOneWidget);
      expect(wc.iousAll(), isEmpty);
    }, timeout: _t);

    tw('a repayment lowers what is left; too much shows core\'s message; a removed one comes back with Undo', (t) async {
      final wc = _wallet();
      final id = wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 12000, date: '2026-10-10');
      await _panel(t, wc);
      await t.tap(_key('iou:$id'));
      await _settle(t);
      await _type(t, 'iouPartAmount', '40.00');
      await _tap(t, 'iouAddPart');
      expect(find.text('${moneyExact(4000, 'EUR')} of ${moneyExact(12000, 'EUR')} · ${moneyExact(8000, 'EUR')} left'), findsOneWidget);
      await _type(t, 'iouPartAmount', '90.00');
      await _tap(t, 'iouAddPart');
      expect(find.textContaining('That is more than is still owed.'), findsOneWidget);
      expect(wc.iouById(id)!.parts, hasLength(1));
      final part = wc.iouById(id)!.parts.single.id;
      await _tap(t, 'iouPartDelete:$part');
      expect(wc.iouById(id)!.parts, isEmpty);
      expect(_key('iouPartUndo'), findsOneWidget);
      await t.tap(find.descendant(of: _key('iouPartUndo'), matching: find.text('Undo')));
      await t.pump();
      expect(wc.iouById(id)!.parts, hasLength(1));
    }, timeout: _t);

    tw('Close moves it to "Show settled"; Open again brings it back', (t) async {
      final wc = _wallet();
      final id = wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 12000, date: '2026-10-10');
      await _panel(t, wc);
      await t.tap(_key('iou:$id'));
      await _settle(t);
      await _tap(t, 'iouClose');
      await _settle(t);
      expect(wc.iouById(id)!.iou.closed, isTrue);
      expect(_key('iou:$id'), findsNothing);
      await t.tap(_key('owedShowClosed'));
      await t.pump();
      expect(find.textContaining('settled'), findsWidgets);
      await t.tap(_key('iou:$id'));
      await _settle(t);
      await _tap(t, 'iouClose');
      await _settle(t);
      expect(wc.iouById(id)!.iou.closed, isFalse);
    }, timeout: _t);

    tw('Delete removes it with a toast; Undo brings it back', (t) async {
      final wc = _wallet();
      final id = wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 12000, date: '2026-10-10');
      await _panel(t, wc);
      await t.tap(_key('iou:$id'));
      await _settle(t);
      await _tap(t, 'iouDelete');
      await _settle(t);
      expect(wc.iousAll(), isEmpty);
      expect(find.text('IOU deleted'), findsOneWidget);
      await t.tap(find.text('Undo'));
      await t.pump();
      expect(wc.iousAll().single.iou.person, 'Sam');
      await t.pump(const Duration(seconds: 4));
    }, timeout: _t);

    tw('the Save tab shows the panel under the wishlist', (t) async {
      final wc = _wallet();
      await pumpApp(t, Scaffold(body: SaveScreen(wc: wc)), size: const Size(400, 1800));
      expect(_key('owedPanel'), findsOneWidget);
    }, timeout: _t);

    for (final dark in [false, true]) {
      tw('320 dp at text 2.0 ${dark ? 'dark' : 'light'}: panel, IOU sheet with repayments and the repayment picker fit', (t) async {
        t.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        final wc = _wallet();
        final id = wc.addIou(
            person: 'A person with a rather long synthetic name',
            direction: IouDirection.lent,
            amount: 123456,
            date: '2026-10-10',
            note: 'n' * 120);
        wc.addIouPart(id, amount: 1000, date: '2026-10-12');
        wc.addIou(person: 'Alex', direction: IouDirection.borrowed, amount: 3500, date: '2026-10-10');
        await _panel(t, wc, scale: 2, size: const Size(320, 640));
        expect(t.takeException(), isNull);
        await t.ensureVisible(_key('iou:$id'));
        await t.pump();
        await t.tap(_key('iou:$id'));
        await _settle(t);
        expect(t.takeException(), isNull);
        final scroll = find.byType(Scrollable).last;
        await t.drag(scroll, const Offset(0, -800));
        await t.pump();
        expect(t.takeException(), isNull);
      }, timeout: _t);
    }
  });

  group('on a payment', () {
    Future<void> openTx(WidgetTester t, WalletController wc, CategorizedTx row,
        {double scale = 1, Size size = const Size(400, 1400)}) async {
      await pumpApp(
          t,
          Scaffold(
              body: Builder(
                  builder: (c) => TextButton(
                      key: const ValueKey('open'),
                      onPressed: () => showSheet<String>(c, TxSheet(wc: wc, t: row)),
                      child: const Text('open')))),
          textScale: scale,
          size: size);
      await t.tap(_key('open'));
      await _settle(t);
    }

    tw('Lent to someone takes the expense out of the totals, tags the row and the sheet says it is linked', (t) async {
      final wc = _wallet();
      wc.repo.addTransaction(date: '2026-10-12', amount: 4000, category: 'Shopping');
      wc.repo.addTransaction(date: '2026-10-13', amount: 2500, category: 'Groceries');
      wc.reload();
      final spentBefore = wc.period().spent;
      final row = wc.txs.firstWhere((x) => x.tx.amount == -4000);
      await openTx(t, wc, row);
      expect(_key('txRepayment'), findsNothing);
      await t.tap(_key('txLent'));
      await _settle(t);
      expect(find.text('Lent to someone'), findsWidgets);
      expect(t.widget<TextField>(_key('iouAmount')).controller!.text, centsToFieldText(4000), reason: 'the payment\'s exact amount');
      await _type(t, 'iouPerson', 'Sam');
      await _tap(t, 'iouSave');
      await _settle(t);
      final v = wc.iousAll().single;
      expect((v.iou.amount, v.iou.tx, v.iou.direction), (4000, row.tx.id, IouDirection.lent));
      expect(wc.iouTagOf(row.tx.id), 'lent');
      expect(wc.period().spent, spentBefore - 4000, reason: 'a linked loan is not spending');
      // The same row, opened again, shows the link instead of the button.
      await openTx(t, wc, wc.txs.firstWhere((x) => x.tx.id == row.tx.id));
      expect(_key('txLent'), findsNothing);
      expect(_key('iouLinked'), findsOneWidget);
    }, timeout: _t);

    tw('a tile of a linked row carries the "lent" tag', (t) async {
      final wc = _wallet();
      final id = wc.repo.addTransaction(date: '2026-10-12', amount: 4000, category: 'Shopping');
      wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 4000, date: '2026-10-12', tx: id);
      final row = wc.txs.firstWhere((x) => x.tx.id == id);
      await pumpApp(t, Scaffold(body: TxTile(t: row, currency: 'EUR', iouTag: wc.iouTagOf(id))));
      expect(find.text('lent'), findsOneWidget);
    }, timeout: _t);

    tw('the tag also shows with the search highlight (TxTile.highlight + iouTag)', (t) async {
      final wc = _wallet();
      final id = wc.repo.addTransaction(date: '2026-10-12', amount: 4000, category: 'Shopping', note: 'Synthetic lamp');
      wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 4000, date: '2026-10-12', tx: id);
      final row = wc.txs.firstWhere((x) => x.tx.id == id);
      await pumpApp(t, Scaffold(body: TxTile(t: row, currency: 'EUR', iouTag: wc.iouTagOf(id), highlight: 'lamp')));
      expect(find.text('lent'), findsOneWidget);
    }, timeout: _t);

    tw('Today\'s Recent list carries the tag', (t) async {
      final wc = _wallet();
      final id = wc.repo.addTransaction(date: '2026-10-19', amount: 4000, category: 'Shopping', note: 'Synthetic lamp');
      wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 4000, date: '2026-10-19', tx: id);
      wc.snoozeKeyBackup();
      await pumpApp(t, Scaffold(body: TodayScreen(view: TodayView(wc), openPlan: () {}, clock: () => budgetToday)),
          size: const Size(400, 3000));
      expect(find.text('lent'), findsOneWidget);
    }, timeout: _t);

    tw('a payment of the wrong size is refused with core\'s message', (t) async {
      final wc = _wallet();
      final id = wc.repo.addTransaction(date: '2026-10-12', amount: 4000, category: 'Shopping');
      final tx = wc.repo.transaction(id)!;
      wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 4000, date: '2026-10-12', tx: id);
      // The same payment cannot be linked twice.
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: IouSheet(wc: wc, tx: tx))));
      await _type(t, 'iouPerson', 'Alex');
      await _tap(t, 'iouSave');
      expect(find.textContaining('This payment is already linked to an IOU.'), findsOneWidget);
      expect(wc.iousAll(), hasLength(1));
    }, timeout: _t);

    tw('Repayment on income: pick the IOU, the money leaves the income, the IOU is smaller', (t) async {
      final wc = _wallet();
      final iou = wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 10000, date: '2026-10-05');
      wc.repo.addTransaction(date: '2026-10-14', amount: -4000, category: 'Extra income');
      wc.reload();
      final incomeBefore = wc.period().received;
      final row = wc.txs.firstWhere((x) => x.tx.amount == 4000);
      await openTx(t, wc, row);
      expect(_key('txLent'), findsNothing);
      await t.tap(_key('txRepayment'));
      await _settle(t);
      expect(_key('repayPick:$iou'), findsOneWidget);
      await t.tap(_key('repayPick:$iou'));
      await _settle(t);
      final v = wc.iouById(iou)!;
      expect((v.outstanding, v.parts.single.tx), (6000, row.tx.id));
      expect(wc.iouTagOf(row.tx.id), 'repaid');
      expect(wc.period().received, lessThanOrEqualTo(incomeBefore));
    }, timeout: _t);

    tw('Repayment with no IOU that owes that much says so', (t) async {
      final wc = _wallet();
      wc.addIou(person: 'Sam', direction: IouDirection.lent, amount: 1000, date: '2026-10-05');
      wc.repo.addTransaction(date: '2026-10-14', amount: -4000, category: 'Extra income');
      wc.reload();
      final row = wc.txs.firstWhere((x) => x.tx.amount == 4000);
      await openTx(t, wc, row);
      await t.tap(_key('txRepayment'));
      await _settle(t);
      expect(_key('repayNone'), findsOneWidget);
    }, timeout: _t);

    for (final dark in [false, true]) {
      tw('320 dp at text 2.0 ${dark ? 'dark' : 'light'}: the payment sheet with the new action and the pickers fit', (t) async {
        t.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        final wc = _wallet();
        wc.addIou(person: 'A person with a rather long synthetic name', direction: IouDirection.lent, amount: 10000, date: '2026-10-05');
        wc.repo.addTransaction(date: '2026-10-12', amount: 4000, category: 'Shopping');
        wc.repo.addTransaction(date: '2026-10-14', amount: -4000, category: 'Extra income');
        wc.reload();
        await openTx(t, wc, wc.txs.firstWhere((x) => x.tx.amount == -4000), scale: 2, size: const Size(320, 640));
        expect(t.takeException(), isNull);
        await t.tap(_key('sheetClose'));
        await _settle(t);
        await openTx(t, wc, wc.txs.firstWhere((x) => x.tx.amount == 4000), scale: 2, size: const Size(320, 640));
        await t.tap(_key('txRepayment'));
        await _settle(t);
        expect(t.takeException(), isNull);
      }, timeout: _t);
    }
  });
}
