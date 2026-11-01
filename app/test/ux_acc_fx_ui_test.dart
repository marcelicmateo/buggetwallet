// Stage UX, UI half: "Which account is this?" at import (UX-ACC, asked once per export account), the Account field of a bank payment, and
// the ECB exchange rates (UX-FX): the automatic fetch (never on a metered network), "Get rates now", the failure line on the Currencies
// panel, the source of every shown rate ("ECB 16 Oct" / "your rate"), foreign account rows and the wallet currency switch. All data is
// SYNTHETIC on the fixed clock 20 Oct 2026; the ECB files are example values in the ECB's CSV shape.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/screens/account_question.dart';
import 'package:budget_wallet/src/screens/accounts_panel.dart';
import 'package:budget_wallet/src/screens/currencies_panel.dart';
import 'package:budget_wallet/src/screens/currency_offer.dart';
import 'package:budget_wallet/src/screens/import_flow.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart';
import 'package:wallet_sync/wallet_sync.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _t = Timeout(Duration(seconds: 60));
final _day = DateTime(2026, 10, 20, 12);

/// A Revolut statement with two pockets (Product): Current and Savings.
const _twoPockets = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
    'Card Payment,Current,2026-10-12 10:00:00,2026-10-12 10:00:00,Synthetic shop one,-12.30,0.00,EUR,COMPLETED,100.00\n'
    'Card Payment,Savings,2026-10-13 10:00:00,2026-10-13 10:00:00,Synthetic shop two,-5.00,0.00,EUR,COMPLETED,50.00\n'
    'Card Payment,Savings,2026-10-14 10:00:00,2026-10-14 10:00:00,Synthetic shop three,-1.00,0.00,EUR,COMPLETED,49.00\n';
const _morePockets = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
    'Card Payment,Current,2026-10-15 10:00:00,2026-10-15 10:00:00,Synthetic shop four,-2.00,0.00,EUR,COMPLETED,98.00\n'
    'Card Payment,Savings,2026-10-16 10:00:00,2026-10-16 10:00:00,Synthetic shop five,-3.00,0.00,EUR,COMPLETED,46.00\n';

/// The ECB's CSV shape: 15 and 16 October 2026 (example values).
const _ecbCsv = 'Date,USD,GBP,\n2026-10-16,1.0900,0.8600,\n2026-10-15,1.1000,0.8700,\n';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

WalletController _wallet() => seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => _day);

NormalizedTransaction _bank(String source, String date, int cents, String currency, {String desc = 'SYNTHETIC SHOP'}) =>
    NormalizedTransaction(
        id: transactionId(date, cents, '$source$desc$currency', 0),
        source: source,
        date: date,
        amountMinor: cents,
        currency: currency,
        bankType: 'POS',
        description: desc);

/// A wallet with a Revolut EUR main account.
Future<(WalletController, String)> _revolut() async {
  final wc = _wallet();
  final main = await wc.repo.addAccount(name: 'Revolut', source: 'revolut', currency: 'EUR', opening: 10000, openingDate: '2026-10-01');
  wc.reload();
  return (wc, main);
}

/// A wallet with one 12.00 USD payment on 16 Oct (an amount that needs an ECB rate).
WalletController _usdWallet() {
  final wc = _wallet();
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('pbz', '2026-10-16', -1200, 'USD')]));
  wc.reload();
  return wc;
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(milliseconds: 400));
}

Finder _key(String k) => find.byKey(ValueKey(k));

Future<void> _tap(WidgetTester t, String k) async {
  await t.ensureVisible(_key(k));
  await t.pump();
  await t.tap(_key(k));
  await _settle(t);
}

Widget _panel(Widget Function() child, WalletController wc) =>
    ListenableBuilder(listenable: wc, builder: (_, __) => Scaffold(body: SingleChildScrollView(child: child())));

class _Chooser extends FileChooser {
  final List<PickedFile> files;
  _Chooser(this.files);
  @override
  Future<List<PickedFile>> pickBankFiles() async => files;
}

class _Picked extends PickedFile {
  _Picked(String name, Uint8List data) : super(name, () async => data, length: () async => data.length);
}

Tx _row(WalletController wc, String desc) => wc.repo.transactions().firstWhere((t) => t.description == desc);

void main() {
  tearDown(() => numberStyle = NumberStyle.point);

  group('Which account is this? (controller)', () {
    test('one question per unknown export account; an answer is kept and the next file is not asked', () async {
      final (wc, main) = await _revolut();
      final asked = <ImportAccountQuestion>[];
      String? savings;
      final lines = await wc.importFiles([('a.csv', _bytes(_twoPockets))], askAccount: (q) async {
        asked.add(q);
        if (asked.length == 1) return AccountAnswer.existing(main);
        return AccountAnswer.created(NewAccountDraft(
            name: 'My savings',
            kind: AccountKind.savings,
            institution: null,
            source: q.source,
            currency: q.currency,
            opening: 5000,
            openingDate: '2026-10-01'));
      });
      savings = wc.repo.accounts().firstWhere((a) => a.name == 'My savings').id;
      expect(asked.length, 2, reason: 'Current and Savings, once each');
      expect(asked.first.rows + asked.last.rows, 3);
      expect(lines.single.ok, isTrue);
      // The answers are the accounts' match keys; the rows went where the owner said.
      final accounts = wc.repo.accounts();
      expect(accounts.firstWhere((a) => a.id == main).matchKey, asked.first.accountKey);
      expect(accounts.firstWhere((a) => a.id == savings).matchKey, asked.last.accountKey);
      expect(_row(wc, 'Synthetic shop two').account, savings);
      expect(_row(wc, 'Synthetic shop one').account, main);
      // A second file of the same export accounts: nothing to ask.
      var again = 0;
      final more = await wc.importFiles([('b.csv', _bytes(_morePockets))], askAccount: (q) async {
        again++;
        return null;
      });
      expect(again, 0);
      expect(more.single.ok, isTrue);
      expect(_row(wc, 'Synthetic shop five').account, savings);
      await _drain();
    });

    test('Cancel imports nothing and writes no key', () async {
      final (wc, main) = await _revolut();
      final before = wc.repo.transactions().length;
      final lines = await wc.importFiles([('a.csv', _bytes(_twoPockets))], askAccount: (q) async => null);
      expect(lines.single.ok, isFalse);
      expect(lines.single.message, contains('skipped'));
      expect(wc.repo.transactions().length, before);
      expect(wc.repo.accounts().firstWhere((a) => a.id == main).matchKey, isNull);
      await _drain();
    });

    NewAccountDraft draftOf(ImportAccountQuestion q) => NewAccountDraft(
        name: 'Pocket',
        kind: AccountKind.bank,
        institution: null,
        source: q.source,
        currency: q.currency,
        opening: 5000,
        openingDate: '2026-10-01');

    test('Cancel at the 2nd question writes nothing: no key after a pick, no account after "New account"', () async {
      for (final firstIsNew in [false, true]) {
        final (wc, main) = await _revolut();
        var n = 0;
        final lines = await wc.importFiles([('a.csv', _bytes(_twoPockets))], askAccount: (q) async {
          n++;
          if (n == 2) return null;
          return firstIsNew ? AccountAnswer.created(draftOf(q)) : AccountAnswer.existing(main);
        });
        expect(n, 2);
        expect(lines.single.ok, isFalse);
        expect(wc.repo.accounts().length, 1, reason: 'no new account (firstIsNew=$firstIsNew)');
        expect(wc.repo.accounts().single.matchKey, isNull, reason: 'no key (firstIsNew=$firstIsNew)');
        expect(wc.repo.transactions(), isEmpty);
        await _drain();
      }
    });

    test('Cancel in the preview writes nothing either: the answers are written only once the file goes in', () async {
      final (wc, main) = await _revolut();
      var n = 0;
      final lines = await wc.importFiles([('a.csv', _bytes(_twoPockets))],
          askAccount: (q) async => ++n == 1 ? AccountAnswer.existing(main) : AccountAnswer.created(draftOf(q)),
          confirmPreview: (preview, bank) async {
            // While the owner looks at the preview nothing is written yet.
            expect(wc.repo.accounts().length, 1);
            expect(wc.repo.accounts().single.matchKey, isNull);
            return null;
          });
      expect(lines.single.ok, isFalse);
      expect(wc.repo.accounts().length, 1);
      expect(wc.repo.accounts().single.matchKey, isNull);
      expect(wc.repo.transactions(), isEmpty);
      await _drain();
    });

    test('the question carries the day of the first row; the answers are written when the preview is confirmed', () async {
      final (wc, main) = await _revolut();
      final days = <String>[];
      final lines = await wc.importFiles([('a.csv', _bytes(_twoPockets))],
          askAccount: (q) async {
            days.add((q as FileAccountQuestion).firstDate);
            return days.length == 1 ? AccountAnswer.existing(main) : AccountAnswer.created(draftOf(q));
          },
          confirmPreview: (preview, bank) async => <String>{});
      expect(days.toSet(), {'2026-10-12', '2026-10-13'}, reason: 'Current starts on the 12th, Savings on the 13th');
      expect(lines.single.ok, isTrue);
      expect(wc.repo.accounts().length, 2);
      await _drain();
    });

    test('"Skip this file" skips that file only: the next file is asked and imported', () async {
      final (wc, main) = await _revolut();
      const other = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
          'Card Payment,Current,2026-10-17 10:00:00,2026-10-17 10:00:00,Synthetic shop six,-4.00,0.00,EUR,COMPLETED,90.00\n';
      var asked = 0;
      final lines = await wc.importFiles([('a.csv', _bytes(_twoPockets)), ('b.csv', _bytes(other))], askAccount: (q) async {
        asked++;
        return asked == 1 ? null : AccountAnswer.existing(main);
      });
      expect(lines.length, 2);
      expect(lines.first.ok, isFalse);
      expect(lines.last.ok, isTrue);
      expect(asked, 2);
      expect(wc.repo.transactions().map((t) => t.description), ['Synthetic shop six']);
      expect(wc.repo.accounts().single.matchKey, isNotNull);
      await _drain();
    });

    test('without the callback the rows go in as before (main account), and no key is asked for', () async {
      final (wc, _) = await _revolut();
      final lines = await wc.importFiles([('a.csv', _bytes(_twoPockets))]);
      expect(lines.single.ok, isTrue);
      expect(_row(wc, 'Synthetic shop two').account, isNull);
      await _drain();
    });
  });

  group('Which account is this? (sheet)', () {
    testWidgets('the question lists the unclaimed accounts, the main one first; Skip imports nothing', timeout: _t, (t) async {
      final (wc, main) = await _revolut();
      await pumpApp(
          t,
          Scaffold(
              body: Builder(
                  builder: (context) => FilledButton(
                      key: const ValueKey('go'),
                      onPressed: () => pickAndImport(context, wc, _Chooser([_Picked('a.csv', _bytes(_twoPockets))])),
                      child: const Text('Import')))),
          size: const Size(400, 900));
      await _tap(t, 'go');
      expect(find.text('Which account is this?'), findsOneWidget);
      expect(_key('accountPick:$main'), findsOneWidget);
      expect(find.text('Revolut (main account)'), findsOneWidget);
      expect(_key('accountPickNew'), findsOneWidget);
      expect(find.text('Skip this file'), findsOneWidget);
      expect(find.textContaining('In the file:'), findsOneWidget);
      await _tap(t, 'accountPickCancel');
      expect(find.text('Skip this file'), findsNothing);
      expect(find.text('Which account is this?'), findsNothing, reason: 'Skip ends this file: no second question');
      expect(wc.repo.transactions(), isEmpty);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Pick the main account, then New account: the form is prefilled and the new account gets the match key', timeout: _t,
        (t) async {
      final (wc, main) = await _revolut();
      await pumpApp(
          t,
          Scaffold(
              body: Builder(
                  builder: (context) => FilledButton(
                      key: const ValueKey('go'),
                      onPressed: () => pickAndImport(context, wc, _Chooser([_Picked('a.csv', _bytes(_twoPockets))])),
                      child: const Text('Import')))),
          size: const Size(400, 1200));
      await _tap(t, 'go');
      await _tap(t, 'accountPick:$main'); // Current -> the main account
      expect(find.text('Which account is this?'), findsOneWidget, reason: 'the second export account (Savings) is asked next');
      expect(_key('accountPick:$main'), findsNothing, reason: 'the main account now claims an export account');
      await _tap(t, 'accountPickNew');
      expect(find.text('New account'), findsWidgets);
      expect(t.widget<TextField>(_key('accountName')).controller!.text, 'Revolut', reason: 'the bank, never the file\'s account name');
      await t.enterText(_key('accountName'), 'Holiday pocket');
      await t.enterText(_key('accountOpening'), '50');
      await _tap(t, 'accountSave');
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await _settle(t);
      expect(_key('importPreview'), findsOneWidget, reason: 'the preview follows the questions');
      await _tap(t, 'importPreviewImport');
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await _settle(t);
      final accounts = wc.repo.accounts();
      final mine = accounts.firstWhere((a) => a.name == 'Holiday pocket');
      expect(mine.source, 'revolut');
      expect(mine.currency, 'EUR');
      expect(mine.kind, AccountKind.bank);
      expect(mine.matchKey, isNotNull);
      expect(accounts.firstWhere((a) => a.id == main).matchKey, isNotNull);
      expect(accounts.firstWhere((a) => a.id == main).matchKey, isNot(mine.matchKey));
      expect(_row(wc, 'Synthetic shop two').account, mine.id);
      expect(_row(wc, 'Synthetic shop one').account, main);
      // The default balance date is the day before the file's first row of it (13 Oct), so its rows count: 50.00 - 5.00 - 1.00.
      expect(mine.openingDate, '2026-10-12');
      final bal = wc.accountBalanceList().firstWhere((b) => b.account.id == mine.id);
      expect(bal.rowsCounted, 2);
      expect(bal.balance, 4400);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('New account at the 1st question, Skip at the 2nd: no account, no key, no rows', timeout: _t, (t) async {
      final (wc, main) = await _revolut();
      await pumpApp(
          t,
          Scaffold(
              body: Builder(
                  builder: (context) => FilledButton(
                      key: const ValueKey('go'),
                      onPressed: () => pickAndImport(context, wc, _Chooser([_Picked('a.csv', _bytes(_twoPockets))])),
                      child: const Text('Import')))),
          size: const Size(400, 1200));
      await _tap(t, 'go');
      await _tap(t, 'accountPickNew');
      await t.enterText(_key('accountName'), 'Pocket');
      await t.enterText(_key('accountOpening'), '10');
      await _tap(t, 'accountSave');
      expect(wc.repo.accounts().length, 1, reason: 'the form wrote nothing');
      expect(find.text('Which account is this?'), findsOneWidget, reason: 'the second question');
      await _tap(t, 'accountPickCancel');
      expect(wc.repo.accounts().length, 1);
      expect(wc.repo.accounts().single.id, main);
      expect(wc.repo.accounts().single.matchKey, isNull);
      expect(wc.repo.transactions(), isEmpty);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('closing the new-account form keeps the question open', timeout: _t, (t) async {
      final (wc, _) = await _revolut();
      ImportAccountQuestion? q;
      await pumpApp(
          t,
          Scaffold(
              body: Builder(
                  builder: (context) => FilledButton(
                      key: const ValueKey('go'),
                      onPressed: () {
                        q = wc.repo
                            .unknownImportAccounts(ImportBatch(
                                source: 'revolut',
                                transactions: [_bank('revolut', '2026-10-12', -100, 'EUR').withAccountKey('ak:0123456789abcdef')]))
                            .single;
                        askWhichAccount(context, wc, q!);
                      },
                      child: const Text('Ask')))),
          size: const Size(400, 900));
      await _tap(t, 'go');
      await _tap(t, 'accountPickNew');
      expect(_key('accountFormHeading'), findsOneWidget);
      await t.tapAt(const Offset(200, 8)); // the scrim: dismiss the form only
      await _settle(t);
      expect(_key('accountQuestion'), findsOneWidget);
      expect(wc.repo.accounts().length, 1);
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('Account field of a bank payment', () {
    Future<(WalletController, String, String)> two() async {
      final wc = _wallet();
      final a = await wc.repo.addAccount(name: 'Current', source: 'pbz', currency: 'EUR', opening: 10000, openingDate: '2026-10-01');
      final b = await wc.repo.addAccount(
          name: 'Savings', source: 'pbz', currency: 'EUR', opening: 0, openingDate: '2026-10-01', matchKey: 'ak:0123456789abcdef');
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('pbz', '2026-10-12', -1000, 'EUR', desc: 'SYNTHETIC ONE')]));
      wc.reload();
      return (wc, a, b);
    }

    testWidgets('two accounts of the bank and currency: the field moves the payment (setTxAccount)', timeout: _t, (t) async {
      final (wc, a, b) = await two();
      final row = wc.txs.single;
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))), size: const Size(400, 1400));
      expect(_key('txAccount'), findsOneWidget);
      await t.ensureVisible(_key('txAccount'));
      await t.tap(_key('txAccount'));
      await _settle(t);
      await t.tap(find.byKey(ValueKey('txAccount:$b')).last);
      await _settle(t);
      expect(wc.repo.transactions().single.account, b);
      expect(wc.accountBalanceList().firstWhere((x) => x.account.id == b).balance, -1000);
      expect(wc.accountBalanceList().firstWhere((x) => x.account.id == a).balance, 10000);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('one account, a manual row, or another currency: no Account field', timeout: _t, (t) async {
      final wc = _wallet();
      await wc.repo.addAccount(name: 'Current', source: 'pbz', currency: 'EUR', opening: 10000, openingDate: '2026-10-01');
      await wc.repo.addAccount(name: 'Dollars', source: 'pbz', currency: 'USD', opening: 0, openingDate: '2026-10-01');
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('pbz', '2026-10-12', -1000, 'EUR')]));
      wc.addExpense(amount: 500, category: 'Groceries', note: 'hand', date: '2026-10-13');
      wc.reload();
      for (final row in wc.txs) {
        await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: row))), size: const Size(400, 1400));
        expect(_key('txAccount'), findsNothing, reason: row.tx.manual ? 'a hand-added row' : 'only one EUR account of this bank');
      }
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('ECB fetch (controller)', () {
    test('automatic when a rate is missing, once a day; the rates then count', () async {
      final wc = _usdWallet();
      var calls = 0;
      EcbFile? asked;
      wc.seams.ecbFetcher = (f) async {
        calls++;
        asked = f;
        return utf8.encode(_ecbCsv);
      };
      expect(wc.fxMissingCount(), 1);
      await wc.fetchRatesAuto();
      expect(calls, 1);
      expect(asked, EcbFile.history, reason: 'an empty cache asks for the whole history');
      expect(wc.ecbCacheInfo().newest, '2026-10-16');
      expect(wc.fxMissingCount(), 0);
      expect(wc.ecbLastFailure(), isNull);
      expect(wc.fxSourceOf(wc.repo.transactions().single), 'ECB ${shortDate('2026-10-16')}');
      await wc.fetchRatesAuto();
      expect(calls, 1, reason: 'at most once a day (core)');
      await _drain();
    });

    test('nothing missing: no download', () async {
      final wc = _wallet();
      var calls = 0;
      wc.seams.ecbFetcher = (f) async {
        calls++;
        return utf8.encode(_ecbCsv);
      };
      await wc.fetchRatesAuto();
      expect(calls, 0);
      await _drain();
    });

    test('a metered network skips the automatic fetch, notes no attempt; Get rates now runs', () async {
      final wc = _usdWallet();
      var calls = 0;
      wc.seams.isMetered = () async => true;
      wc.seams.ecbFetcher = (f) async {
        calls++;
        return utf8.encode(_ecbCsv);
      };
      await wc.fetchRatesAuto();
      expect(calls, 0);
      expect(wc.ecbCacheInfo().attemptOn, isNull, reason: 'the next start on another network may try');
      expect(await wc.getRatesNow(), isTrue);
      expect(calls, 1);
      expect(wc.ecbCacheInfo().newest, '2026-10-16');
      await _drain();
    });

    test('the currency switch needs a rate for the very pair: EUR to RSD keeps the "set the rate" path', () async {
      final wc = _usdWallet();
      expect(wc.ecbCoversSwitch('EUR', 'GBP'), isFalse, reason: 'nothing cached yet');
      wc.seams.ecbFetcher = (_) async => utf8.encode(_ecbCsv);
      await wc.getRatesNow();
      expect(wc.ecbCoversSwitch('EUR', 'GBP'), isTrue);
      expect(wc.ecbCoversSwitch('EUR', 'USD'), isTrue);
      expect(wc.ecbCoversSwitch('EUR', 'RSD'), isFalse, reason: 'the cache holds days but no RSD');
      expect(wc.ecbCoversSwitch('EUR', 'BTC'), isFalse);
      await _drain();
    });

    test('the automatic fetch shows at once (also while the network is looked at); a "Get rates now" meanwhile is not lost', () async {
      final wc = _usdWallet();
      var calls = 0;
      wc.seams.ecbFetcher = (_) async {
        calls++;
        return utf8.encode(_ecbCsv);
      };
      final net = Completer<bool>();
      wc.seams.isMetered = () => net.future;
      var notes = 0;
      wc.addListener(() => notes++);
      final auto = wc.fetchRatesAuto();
      await Future<void>.delayed(Duration.zero);
      expect(wc.ecbFetching, isTrue);
      expect(notes, greaterThan(0), reason: 'the panel is told before the network answers');
      expect(await wc.getRatesNow(), isFalse, reason: 'queued, not run beside the automatic one');
      net.complete(true); // metered: the automatic run gives up, the owner's tap runs forced after it
      await auto;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      expect(wc.ecbCacheInfo().newest, '2026-10-16');
      expect(wc.ecbFetching, isFalse);
      await _drain();
    });

    test('a tap queued during an automatic fetch that brought the rates does not download twice', () async {
      final wc = _usdWallet();
      var calls = 0;
      final file = Completer<List<int>>();
      wc.seams.ecbFetcher = (_) {
        calls++;
        return file.future;
      };
      final auto = wc.fetchRatesAuto();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 1);
      expect(await wc.getRatesNow(), isFalse);
      file.complete(utf8.encode(_ecbCsv));
      await auto;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      await _drain();
    });

    test('closing the app mid-fetch: a disposed controller finishes quietly (download, network check, button)', () async {
      for (final where in ['download', 'network', 'button']) {
        final wc = _usdWallet();
        final gate = Completer<List<int>>();
        final net = Completer<bool>();
        wc.seams.ecbFetcher = (_) => gate.future;
        wc.seams.isMetered = () => where == 'network' ? net.future : Future.value(false);
        final run = where == 'button' ? wc.getRatesNow() : wc.fetchRatesAuto();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(wc.ecbFetching, isTrue, reason: where);
        wc.dispose();
        gate.complete(utf8.encode(_ecbCsv));
        net.complete(false);
        await run; // no error, no write into the closed database, no notify after dispose
        expect(wc.ecbFetching, isFalse, reason: where);
      }
    });

    test('import and sync trigger the same plan (once a day), and a failure never throws', () async {
      final wc = _usdWallet();
      var calls = 0;
      wc.seams.ecbFetcher = (f) async {
        calls++;
        throw const EcbFetchException(EcbFetchFailure.unreachable, 'The exchange rates could not be downloaded: no connection.');
      };
      final lines = await wc.importFiles([('a.csv', _bytes(_twoPockets))]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(lines.single.ok, isTrue, reason: 'a failed download never blocks an import');
      expect(calls, 1);
      expect(wc.ecbLastFailure()?.reason, 'unreachable');
      await _drain();
    });

    test('every failure is a plain reason; a damaged file writes nothing; a good one clears the failure', () async {
      final wc = _usdWallet();
      for (final (f, reason, why) in [
        (const EcbFetchException(EcbFetchFailure.timeout, 'x'), 'timeout', 'it took too long'),
        (const EcbFetchException(EcbFetchFailure.status, 'x'), 'status', 'the ECB did not answer'),
        (const EcbFetchException(EcbFetchFailure.tooLarge, 'x'), 'tooLarge', 'the download was too large'),
      ]) {
        wc.seams.ecbFetcher = (_) async => throw f;
        expect(await wc.getRatesNow(), isFalse);
        expect(wc.ecbLastFailure()?.reason, reason);
        expect(wc.ecbLastFailure()?.why, why);
      }
      wc.seams.ecbFetcher = (_) async => utf8.encode('this is not an ECB file');
      expect(await wc.getRatesNow(), isFalse);
      expect(wc.ecbLastFailure()?.why, 'the file was damaged');
      expect(wc.ecbCacheInfo().days, 0, reason: 'nothing written');
      wc.seams.ecbFetcher = (_) async => utf8.encode(_ecbCsv);
      expect(await wc.getRatesNow(), isTrue);
      expect(wc.ecbLastFailure(), isNull);
      await _drain();
    });

    test('logs carry the outcome and reason only: no address, no error text', () async {
      final lines = <String>[];
      final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
      addTearDown(sub.cancel);
      final wc = _usdWallet();
      wc.seams.ecbFetcher =
          (_) async => throw const EcbFetchException(EcbFetchFailure.unreachable, 'https://example.invalid/secret failed');
      await wc.getRatesNow();
      final ours = lines.where((l) => l.contains('fx.fetch')).toList();
      expect(ours, isNotEmpty);
      expect(ours.any((l) => l.contains('outcome') && l.contains('unreachable')), isTrue);
      for (final l in lines) {
        expect(l, isNot(contains('example.invalid')));
        expect(l, isNot(contains('https://')));
      }
      await _drain();
    });
  });

  group('Currencies panel', () {
    testWidgets('shows what the cache holds, the failure plainly (no toast), and Get rates now runs on a metered network', timeout: _t,
        (t) async {
      final wc = _usdWallet();
      wc.seams.isMetered = () async => true;
      wc.seams.ecbFetcher = (_) async => throw const EcbFetchException(EcbFetchFailure.unreachable, 'x');
      await pumpApp(t, _panel(() => CurrenciesPanel(wc: wc), wc), size: const Size(400, 1200));
      expect(find.text('No ECB rates on this device yet.'), findsOneWidget);
      expect(_key('ecbMissing'), findsOneWidget);
      expect(_key('ecbFailure'), findsNothing);
      await _tap(t, 'ecbGetNow');
      await t.pump(const Duration(milliseconds: 50));
      expect(_key('ecbFailure'), findsOneWidget);
      expect(find.textContaining("Couldn't get rates: no connection (${shortDate('2026-10-20')}).", findRichText: true), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing, reason: 'a failure is shown on the panel, not as a toast');
      // The next try works.
      wc.seams.ecbFetcher = (_) async => utf8.encode(_ecbCsv);
      await _tap(t, 'ecbGetNow');
      expect(_key('ecbFailure'), findsNothing);
      expect(find.text('ECB rates up to ${shortDate('2026-10-16')}.'), findsOneWidget);
      expect(_key('ecbMissing'), findsNothing);
      expect(find.text('Rates updated'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('a retry shows "Getting rates…" even while the last failure is stored', timeout: _t, (t) async {
      final wc = _usdWallet();
      wc.seams.isMetered = () async => false;
      wc.seams.ecbFetcher = (_) async => throw const EcbFetchException(EcbFetchFailure.unreachable, 'x');
      await wc.getRatesNow();
      await pumpApp(t, _panel(() => CurrenciesPanel(wc: wc), wc), size: const Size(400, 1200));
      expect(_key('ecbFailure'), findsOneWidget);
      final gate = Completer<List<int>>();
      wc.seams.ecbFetcher = (_) => gate.future;
      await _tap(t, 'ecbGetNow');
      expect(wc.ecbFetching, isTrue);
      expect(_key('ecbBusy'), findsOneWidget);
      expect(_key('ecbFailure'), findsNothing, reason: 'the old failure waits until this try is over');
      expect(t.widget<TextButton>(_key('ecbGetNow')).onPressed, isNull);
      gate.complete(utf8.encode(_ecbCsv));
      await _settle(t);
      expect(_key('ecbBusy'), findsNothing);
      expect(_key('ecbFailure'), findsNothing);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('every rate states its source: ECB day or your rate (a hand rate wins)', timeout: _t, (t) async {
      final wc = _usdWallet();
      wc.seams.ecbFetcher = (_) async => utf8.encode(_ecbCsv);
      await wc.getRatesNow();
      await pumpApp(t, _panel(() => CurrenciesPanel(wc: wc), wc), size: const Size(400, 1200));
      expect(find.text('ECB ${shortDate('2026-10-16')} · 1 payment'), findsOneWidget);
      expect(find.text('USD — counted at the ECB rate of each day'), findsOneWidget);
      expect(_key('fxNotCounted:USD'), findsNothing);
      await _tap(t, 'fxSet:USD');
      await t.enterText(_key('fxRateField'), '0.9');
      await _tap(t, 'fxSave');
      expect(find.text('your rate · 1 payment'), findsOneWidget);
      expect(find.textContaining('ECB ${shortDate('2026-10-16')} ·'), findsNothing);
      expect(wc.fxSourceOf(wc.repo.transactions().single), 'your rate');
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('a coin has no ECB rate: hand-set only, said so', timeout: _t, (t) async {
      final wc = _wallet();
      await wc.repo.addAccount(name: 'Coins', currency: 'BTC', opening: 10000000, openingDate: '2026-10-01', kind: AccountKind.crypto);
      wc.reload();
      await pumpApp(t, _panel(() => CurrenciesPanel(wc: wc), wc), size: const Size(400, 1200));
      expect(_key('fxCoin:BTC'), findsOneWidget);
      expect(find.text('Coins have no ECB rate: you set it by hand.'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('Foreign account rows', () {
    Future<(WalletController, String)> usdAccount() async {
      final wc = _wallet();
      final id = await wc.repo.addAccount(name: 'Dollars', source: 'revolut', currency: 'USD', opening: 10000, openingDate: '2026-10-15');
      wc.reload();
      return (wc, id);
    }

    testWidgets('a value in the wallet currency with its source, or "Rate missing" while a part has none', timeout: _t, (t) async {
      final (wc, id) = await usdAccount();
      await pumpApp(t, _panel(() => AccountsPanel(wc: wc), wc), size: const Size(400, 1600));
      expect(_key('accountRateMissing:$id'), findsOneWidget);
      expect(find.textContaining('Rate missing'), findsOneWidget);
      expect(_key('accountHome:$id'), findsNothing);
      expect(_key('accountSetRate:$id'), findsOneWidget);
      wc.seams.ecbFetcher = (_) async => utf8.encode(_ecbCsv);
      await wc.getRatesNow();
      await t.pump();
      // 100.00 USD on 15 Oct at 1.1000 USD per EUR = 90.91 EUR.
      expect(find.text('About ${moneyExact(9091, 'EUR')} · ECB ${shortDate('2026-10-15')}'), findsOneWidget);
      expect(_key('accountRateMissing:$id'), findsNothing);
      wc.setFxRate('USD', 900000);
      await t.pump();
      expect(find.text('About ${moneyExact(9000, 'EUR')} · your rate'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('Counts as (payment sheet)', () {
    Widget opener(WalletController wc, CategorizedTx row) => Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                key: const ValueKey('openTx'),
                onPressed: () => showSheet<String>(context, TxSheet(wc: wc, t: row)),
                child: const Text('open'))));

    testWidgets('a hand rate says "at 0.9000 · your rate"', timeout: _t, (t) async {
      final wc = _usdWallet();
      wc.setFxRate('USD', 900000);
      final converted = wc.txs.firstWhere((c) => c.originalAmount != null);
      await pumpApp(t, opener(wc, converted), size: const Size(400, 2400));
      await _tap(t, 'openTx');
      expect(find.text('Counts as ${money(-1080, 'EUR', decimals: 2, signed: true)} at 0.9000 · your rate'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });

    test("with the bank's own amount the line says so, whatever the hand rate (core counts the bank's amount)", () {
      final wc = _usdWallet();
      wc.setFxRate('USD', 900000);
      final tx = wc.repo.transactions().single;
      expect(wc.fxBasisText(tx), ' at 0.9000 · your rate');
      final bankSays = Tx(
          id: tx.id,
          source: tx.source,
          date: tx.date,
          amount: tx.amount,
          currency: tx.currency,
          bankType: tx.bankType,
          description: tx.description,
          homeAmount: -1100);
      expect(homeAmount(bankSays, wc.settings), -1100, reason: 'core counts the bank\'s amount');
      expect(wc.fxBasisText(bankSays), " · the bank's amount");
    });
  });

  group('Wallet currency switch', () {
    Widget host(WalletController wc, String code) => Scaffold(
        body: Builder(
            builder: (context) => FilledButton(
                key: const ValueKey('go'), onPressed: () => switchWalletCurrency(context, wc, code), child: const Text('Switch'))));

    testWidgets('with ECB rates the dialog says old payments count at their own day\'s rate', timeout: _t, (t) async {
      final wc = _usdWallet();
      wc.seams.ecbFetcher = (_) async => utf8.encode(_ecbCsv);
      await wc.getRatesNow();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('pbz', '2026-10-12', -1000, 'EUR', desc: 'SYNTHETIC EUR')]));
      wc.reload();
      await pumpApp(t, host(wc, 'GBP'), size: const Size(400, 900));
      await _tap(t, 'go');
      expect(find.textContaining('ECB rate of its own day'), findsOneWidget);
      expect(find.textContaining('nothing drops out'), findsOneWidget);
      expect(_key('currencySwitchRate'), findsOneWidget, reason: 'the owner may still set a rate of their own');
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('without ECB rates the old text stays', timeout: _t, (t) async {
      final wc = _usdWallet();
      wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [_bank('pbz', '2026-10-12', -1000, 'EUR', desc: 'SYNTHETIC EUR')]));
      wc.reload();
      await pumpApp(t, host(wc, 'GBP'), size: const Size(400, 900));
      await _tap(t, 'go');
      expect(find.textContaining('ECB rate'), findsNothing);
      expect(find.textContaining('only with a EUR→GBP rate'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
    });
  });
}

/// Lets the controller's 3 s sync debounce run out (a pending timer fails a plain test).
Future<void> _drain() => Future<void>.delayed(const Duration(seconds: 4));
