// Stage Q5 app half: the bank balance question, Settings > Accounts "Check balance", the result line after an import and the red lines on
// Today. The app never warns from a balance it does not trust. Fixed clock (20 Oct 2026), synthetic data only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/accounts_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _t = Timeout(Duration(seconds: 60));

Finder _key(String k) => find.byKey(ValueKey(k));

/// A route needs a first frame to start its animation, then time to finish.
Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
}

/// A wallet with one PBZ account. [openingDate] decides trust: within 35 days of 20 Oct 2026 the opening counts as confirmed.
Future<(WalletController, String)> _wallet({
  required String openingDate,
  int opening = 100000,
  List<(String, int)> rows = const [],
}) async {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  addTearDown(wc.dispose);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01'});
  final id = await wc.addAccount(name: 'PBZ current', source: 'pbz', currency: 'EUR', opening: opening, openingDate: openingDate);
  if (rows.isNotEmpty) {
    wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
      for (final (i, r) in rows.indexed) syntheticTx(r.$1, r.$2, 'POS plaćanje', 'SYNTHETIC SHOP $i'),
    ]));
  }
  wc.reload();
  return (wc, id);
}

Future<void> _openSheet(WidgetTester t, WalletController wc, BankQuestion q, {bool fromImport = true, double scale = 1, Size? size}) =>
    pumpApp(t, Scaffold(body: SingleChildScrollView(child: BankCheckSheet(wc: wc, q: q, fromImport: fromImport))),
        textScale: scale, size: size ?? const Size(400, 900));

BankQuestion _question(WalletController wc, String id, String date) =>
    BankQuestion(accountId: id, name: 'PBZ current', currency: 'EUR', date: date, appCents: wc.appBalanceOn(id, date));

/// A widget test that lets the controller's 3 s sync debounce run out at the end (a pending timer fails the test).
void tw(String name, Future<void> Function(WidgetTester t) body, {Timeout? timeout}) => testWidgets(name, (t) async {
      await body(t);
      await t.pump(const Duration(seconds: 4));
    }, timeout: timeout);

void main() {
  group('the question', () {
    tw('Matches records a check with the app\'s number and changes no balance', (t) async {
      final (wc, id) = await _wallet(openingDate: '2026-09-01', rows: [('2026-10-10', -2000)]);
      final q = _question(wc, id, '2026-10-12');
      expect(q.appCents, 98000);
      await _openSheet(t, wc, q);
      expect(find.textContaining('What did the bank app show when you downloaded this file?'), findsOneWidget);
      expect(find.textContaining('12 Oct'), findsWidgets);
      expect(t.widget<TextField>(_key('bankCheckAmount')).controller!.text, centsToFieldText(98000));
      await t.tap(_key('bankCheckMatches'));
      await t.pump();
      final c = wc.lastBankCheckOf(id)!;
      expect((c.date, c.bankCents, c.appCents), ('2026-10-12', 98000, 98000));
      expect(wc.accountBalanceList().single.balance, 98000);
    }, timeout: _t);

    tw('a different number shows "Off by", changes nothing, and Correct balance opens prefilled with the bank\'s number', (t) async {
      final (wc, id) = await _wallet(openingDate: '2026-09-01', rows: [('2026-10-10', -2000)]);
      await _openSheet(t, wc, _question(wc, id, '2026-10-12'));
      await t.enterText(_key('bankCheckAmount'), '970.00');
      await t.tap(_key('bankCheckSave'));
      await t.pump();
      expect(_key('bankCheckOff'), findsOneWidget);
      expect(find.textContaining('Off by'), findsOneWidget);
      expect(find.textContaining('pending at the bank'), findsOneWidget);
      expect(wc.lastBankCheckOf(id)!.bankCents, 97000);
      expect(wc.accountBalanceList().single.balance, 98000, reason: 'nothing is corrected automatically');
      await t.tap(_key('bankCheckCorrect'));
      await _settle(t);
      expect(t.widget<TextField>(_key('accountCorrectAmount')).controller!.text, centsToFieldText(97000));
      await t.tap(_key('accountCorrectSave'));
      await _settle(t);
      expect(wc.accountBalanceList().single.balance, 97000);
      await t.pump(const Duration(seconds: 4));
    }, timeout: _t);

    tw('Below zero turns the typed number negative; a bad number is refused with the amount message', (t) async {
      final (wc, id) = await _wallet(openingDate: '2026-09-01');
      await _openSheet(t, wc, _question(wc, id, '2026-10-12'));
      await t.enterText(_key('bankCheckAmount'), 'abc');
      await t.tap(_key('bankCheckSave'));
      await t.pump();
      expect(find.textContaining(invalidAmountMessage), findsOneWidget);
      expect(wc.lastBankCheckOf(id), isNull);
      await t.enterText(_key('bankCheckAmount'), '20.00');
      await t.tap(_key('accountNegative'));
      await t.pump();
      await t.tap(_key('bankCheckSave'));
      await t.pump();
      expect(wc.lastBankCheckOf(id)!.bankCents, -2000);
    }, timeout: _t);

    tw('Skip stores nothing', (t) async {
      final (wc, id) = await _wallet(openingDate: '2026-09-01');
      await _openSheet(t, wc, _question(wc, id, '2026-10-12'));
      await t.tap(_key('bankCheckSkip'));
      await t.pump();
      expect(wc.lastBankCheckOf(id), isNull);
    }, timeout: _t);

    for (final dark in [false, true]) {
      tw('320 dp at text 2.0 ${dark ? 'dark' : 'light'}: the question and the off state fit', (t) async {
        final (wc, id) = await _wallet(openingDate: '2026-09-01', rows: [('2026-10-10', -2000)]);
        t.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
        addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
        await _openSheet(t, wc, _question(wc, id, '2026-10-12'), scale: 2, size: const Size(320, 640));
        expect(t.takeException(), isNull);
        await t.enterText(_key('bankCheckAmount'), '1.00');
        await t.ensureVisible(_key('bankCheckSave'));
        await t.pump();
        await t.tap(_key('bankCheckSave'));
        await t.pump();
        expect(_key('bankCheckOff'), findsOneWidget);
        expect(t.takeException(), isNull);
      }, timeout: _t);
    }
  });

  group('older answers', () {
    tw('an older answer never replaces a newer stored check', (t) async {
      final (wc, id) = await _wallet(openingDate: '2026-09-01', rows: [('2026-10-10', -2000)]);
      wc.recordBalanceCheck(id, date: '2026-10-18', bankCents: 98000);
      final c = wc.recordBalanceCheck(id, date: '2026-10-12', bankCents: 90000);
      expect(c.matches, isFalse, reason: 'the comparison is still told');
      final last = wc.lastBankCheckOf(id)!;
      expect((last.date, last.bankCents), ('2026-10-18', 98000));
      wc.recordBalanceCheck(id, date: '2026-10-19', bankCents: 98000);
      expect(wc.lastBankCheckOf(id)!.date, '2026-10-19', reason: 'a newer one still replaces');
    }, timeout: _t);
  });

  group('Settings > Accounts', () {
    tw('shows "not checked", then the last check, and Check balance opens the question for today', (t) async {
      final (wc, id) = await _wallet(openingDate: '2026-09-01', rows: [('2026-10-10', -2000)]);
      await pumpApp(
          t, Scaffold(body: SingleChildScrollView(child: ListenableBuilder(listenable: wc, builder: (_, __) => AccountsPanel(wc: wc)))));
      expect(find.text('Not checked against the bank yet'), findsOneWidget);
      await t.tap(_key('accountCheck:$id'));
      await _settle(t);
      expect(_key('bankCheckSheet'), findsOneWidget);
      expect(find.textContaining('What does the bank app show now?'), findsOneWidget);
      await t.tap(_key('bankCheckMatches'));
      await _settle(t);
      expect(find.textContaining('matches the bank'), findsOneWidget);
      expect(wc.lastBankCheckOf(id)!.date, '2026-10-20');
      await t.pump(const Duration(seconds: 4));
    }, timeout: _t);

    tw('cash has no Check balance', (t) async {
      final (wc, _) = await _wallet(openingDate: '2026-09-01');
      final cash = await wc.addAccount(name: 'Cash', currency: 'EUR', opening: 1000, openingDate: '2026-09-01');
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: AccountsPanel(wc: wc))));
      expect(_key('accountCheck:$cash'), findsNothing);
      expect(_key('accountCorrect:$cash'), findsOneWidget);
    }, timeout: _t);
  });

  group('Today', () {
    // Since ENG E7a a balance warning is a Needs-you card (Overview only counts it).
    Future<void> today(WidgetTester t, WalletController wc, {double scale = 1, Size? size}) =>
        pumpApp(t, needsYouOf(wc), textScale: scale, size: size ?? const Size(400, 1600));

    tw('an untrusted balance shows only "a Check tile", never a warning, and a tap opens the question', (t) async {
      // Opening is old and negative: a number we do not trust must not say "below zero".
      final (wc, id) = await _wallet(openingDate: '2026-07-01', opening: -50000);
      expect(wc.balanceWarningList().map((w) => w.kind), [BalanceWarningKind.checkBalance]);
      await today(t, wc);
      expect(_key('needs:balance:$id'), findsOneWidget);
      expect(find.descendant(of: _key('needs:balance:$id'), matching: find.text('PBZ current')), findsOneWidget);
      expect(find.descendant(of: _key('needs:balance:$id'), matching: find.text('The balance was not confirmed lately.')), findsOneWidget);
      expect(find.descendant(of: _key('needs:balance:$id'), matching: find.text('Check balance')), findsOneWidget);
      expect(find.textContaining('Below zero'), findsNothing);
      await t.tap(_key('needsPrimary:balance:$id'));
      await _settle(t);
      expect(_key('bankCheckSheet'), findsOneWidget);
    }, timeout: _t);

    tw('a confirmed balance below zero says so', (t) async {
      final (wc, id) = await _wallet(openingDate: '2026-10-15', opening: -5000);
      await today(t, wc);
      expect(find.descendant(of: _key('needs:balance:$id'), matching: find.text('Below zero now.')), findsOneWidget);
      expect(find.descendant(of: _key('needs:balance:$id'), matching: find.text(moneyExact(-5000, 'EUR'))), findsOneWidget);
    }, timeout: _t);

    tw('a balance confirmed by a matching check is trusted: no "Check your balance" line', (t) async {
      final (wc, id) = await _wallet(openingDate: '2026-07-01', rows: [('2026-10-10', -2000)]);
      wc.recordBalanceCheck(id, date: '2026-10-18', bankCents: 98000);
      expect(wc.balanceWarningList(), isEmpty);
      await today(t, wc);
      expect(_key('needs:balance:$id'), findsNothing);
    }, timeout: _t);

    tw('a check that is off does not make the balance trusted', (t) async {
      final (wc, id) = await _wallet(openingDate: '2026-07-01', rows: [('2026-10-10', -2000)]);
      wc.recordBalanceCheck(id, date: '2026-10-18', bankCents: 90000);
      expect(wc.balanceWarningList().map((w) => w.kind), [BalanceWarningKind.checkBalance]);
    }, timeout: _t);

    tw('the warning fits 320 dp at text 2.0', (t) async {
      final (wc, _) = await _wallet(openingDate: '2026-10-15', opening: -5000);
      await today(t, wc, scale: 2, size: const Size(320, 1800));
      expect(t.takeException(), isNull);
    }, timeout: _t);
  });

  group('after an import', () {
    const withBalance = 'Datum;Opis;Iznos;Valuta;Stanje\n12.10.2026;Synthetic shop;-20,00;EUR;970,00\n';
    const without = 'Datum;Opis;Iznos;Valuta\n12.10.2026;Synthetic shop;-20,00;EUR\n';

    /// A wallet whose account reads the mapped CSV of [csv] (source `csv:<shape id>`), opened with 1000.00 on 1 Sep.
    Future<(WalletController, String)> csvWallet(String csv) async {
      final bytes = Uint8List.fromList(utf8.encode(csv));
      final (wc, _) = await _wallet(openingDate: '2026-09-01');
      final shape = csvShape(bytes);
      wc.repo.setCsvMapping(shape.shapeId, guessMapping(shape)!.copyWith(name: 'Erste (CSV)', headers: shape.headers));
      wc.reload();
      final id =
          await wc.addAccount(name: 'Erste', source: 'csv:${shape.shapeId}', currency: 'EUR', opening: 100000, openingDate: '2026-09-01');
      return (wc, id);
    }

    Future<List<ImportLine>> run(WalletController wc, String csv) {
      final bytes = Uint8List.fromList(utf8.encode(csv));
      return wc.importFiles([('a.csv', bytes)], askMapping: (_, b) async {
        final shape = csvShape(b);
        return CsvChoice(shape.shapeId, guessMapping(shape)!.copyWith(name: 'Erste (CSV)', headers: shape.headers));
      });
    }

    test('a stated balance that differs: "off by", the date to look from and the pending note; a check is stored', () async {
      final (wc, id) = await csvWallet(withBalance);
      final lines = await run(wc, withBalance);
      expect(lines.single.message, contains('Erste is off by ${moneyExact(1000, 'EUR')}: see rows since 1 Sep.'));
      expect(lines.single.message, contains('Payments may still be pending at the bank.'));
      expect(lines.single.questions, isEmpty, reason: 'the file gave a balance: no question');
      expect(wc.lastBankCheckOf(id)!.bankCents, 97000);
    });

    test('a stated balance that matches says so with a tick', () async {
      final file = withBalance.replaceFirst('970,00', '980,00');
      final (wc, _) = await csvWallet(file);
      final lines = await run(wc, file);
      expect(lines.single.message, contains('Erste matches the bank ✓.'));
      expect(lines.single.message, isNot(contains('pending')));
    });

    test('a file without a balance leaves one question: the newest row date and the app\'s own number', () async {
      final (wc, id) = await csvWallet(without);
      final lines = await run(wc, without);
      final q = lines.single.questions.single;
      expect((q.accountId, q.date, q.appCents), (id, '2026-10-12', 98000));
      expect(wc.lastBankCheckOf(id), isNull);
    });

    test('two files out of date order: the question is recounted over every row when it is asked', () async {
      const late = 'Datum;Opis;Iznos;Valuta\n20.10.2026;Synthetic late;-30,00;EUR\n';
      const early = 'Datum;Opis;Iznos;Valuta\n05.10.2026;Synthetic early;-20,00;EUR\n';
      final (wc, id) = await csvWallet(late);
      final lines = await wc
          .importFiles([('late.csv', Uint8List.fromList(utf8.encode(late))), ('early.csv', Uint8List.fromList(utf8.encode(early)))],
              askMapping: (_, b) async {
        final shape = csvShape(b);
        return CsvChoice(shape.shapeId, guessMapping(shape)!.copyWith(name: 'Erste (CSV)', headers: shape.headers));
      });
      final built = newestPerAccount(lines.expand((l) => l.questions)).single;
      expect((built.date, built.appCents), ('2026-10-20', 100000 - 3000), reason: 'built before the early file was written');
      final asked = wc.questionNow(built)!;
      expect(asked.date, '2026-10-20');
      expect(asked.appCents, 100000 - 3000 - 2000, reason: 'both files counted');
      expect(wc.appBalanceOn(id, '2026-10-20'), asked.appCents);
    });

    test('a question older than a stored check is not asked; a newer one is', () async {
      final (wc, id) = await csvWallet(without);
      wc.recordBalanceCheck(id, date: '2026-10-25', bankCents: 100000);
      final old = BankQuestion(accountId: id, name: 'Erste', currency: 'EUR', date: '2026-10-12', appCents: 1);
      expect(wc.questionNow(old), isNull);
      final same = BankQuestion(accountId: id, name: 'Erste', currency: 'EUR', date: '2026-10-25', appCents: 1);
      expect(wc.questionNow(same), isNull, reason: 'a check of that very day is enough');
      final newer = BankQuestion(accountId: id, name: 'Erste', currency: 'EUR', date: '2026-10-26', appCents: 1);
      expect(wc.questionNow(newer)!.appCents, 100000);
    });

    test('no question when the last check is already as new as the file', () async {
      final (wc, id) = await csvWallet(without);
      wc.recordBalanceCheck(id, date: '2026-10-12', bankCents: 100000);
      final lines = await run(wc, without);
      expect(lines.single.questions, isEmpty);
    });
  });
}
