// D2 Unlink (owner 2026-10-31): a bank row that replaced a hand-added expense shows a mark and an Unlink action; Unlink makes the
// expense count again (toast with Undo), core's refusal text shows in the toast. Synthetic data only.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/widgets/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show ImportBatch;

import 'support/seams.dart';
import 'support/wallet.dart';

Finder key(String k) => find.byKey(ValueKey(k));

const _cash = 2340;

/// 20 Oct 2026: one hand-added 23.40 expense and the bank row that replaced it (same day), one unrelated bank row.
WalletController _wallet() {
  final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
  wc.repo.updateSettings({'salary': 150000, 'salaryConfirmed': true, 'periodStart': '2026-10-01', 'paydayDay': 1});
  wc.repo.setLocalValue('keyBackupConfirmed', '1');
  wc.repo.addTransaction(date: '2026-10-20', amount: _cash, category: 'Eating out', note: 'lunch');
  wc.repo.importBatch(ImportBatch(source: 'pbz', transactions: [
    syntheticTx('2026-10-20', -_cash, 'POS plaćanje', 'PBZ POS SYNTHETIC CAFE'),
    syntheticTx('2026-10-19', -990, 'POS plaćanje', 'PBZ POS SYNTHETIC KIOSK'),
  ]));
  wc.reload();
  addTearDown(wc.dispose);
  return wc;
}

CategorizedTx _bank(WalletController wc, int amount) => wc.txs.firstWhere((x) => !x.tx.manual && x.tx.amount == amount);

Tx _entry(WalletController wc) => wc.repo.transactions(includeHidden: true).firstWhere((x) => x.manual && !x.deleted);

/// A button that opens the transaction sheet of [row] and then the toast, as the lists do.
Future<void> _open(WidgetTester t, WalletController wc, CategorizedTx row, {Size size = const Size(400, 900), double scale = 1}) async {
  await pumpApp(
      t,
      Scaffold(
          body: Builder(
              builder: (c) => TextButton(
                  onPressed: () async {
                    final r = await showSheet<String>(c, TxSheet(wc: wc, t: row));
                    if (c.mounted) txSheetToast(c, wc, r);
                  },
                  child: const Text('go')))),
      size: size,
      textScale: scale);
  await t.tap(find.text('go'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
}

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
}

void main() {
  group('matched mark follows core', () {
    test('isMatchedBank reads matchedBankIds and follows the data version', () {
      final wc = _wallet();
      final bank = _bank(wc, -_cash), other = _bank(wc, -990);
      expect(wc.repo.matchedBankIds(), {bank.tx.id});
      expect(wc.isMatchedBank(bank.tx.id), isTrue);
      expect(wc.isMatchedBank(other.tx.id), isFalse);
      expect(wc.unlinkCashMatch(_entry(wc).id, bank.tx.id), isNull);
      expect(wc.isMatchedBank(bank.tx.id), isFalse, reason: 'cache dropped with the data version');
    });

    testWidgets('Unlink shows on the matched bank row only', (t) async {
      final wc = _wallet();
      await _open(t, wc, _bank(wc, -_cash));
      expect(key('matchedMark'), findsOneWidget);
      expect(key('unlinkMatch'), findsOneWidget);
      await t.tap(key('sheetClose'));
      await _settle(t);
      await _open(t, wc, _bank(wc, -990));
      expect(key('matchedMark'), findsNothing);
      expect(key('unlinkMatch'), findsNothing);
    });

    testWidgets('Unlink also shows on the hand-added entry that was replaced', (t) async {
      final wc = _wallet();
      final entry = _entry(wc);
      await _open(t, wc, CategorizedTx(entry, 'Eating out', BudgetKind.flex));
      expect(key('unlinkMatch'), findsOneWidget);
    });
  });

  group('Unlink', () {
    testWidgets('the cash entry counts again in Today, the mark goes, Undo puts it back', (t) async {
      final wc = _wallet();
      final bank = _bank(wc, -_cash);
      expect(wc.period().spentToday, _cash, reason: 'matched: the entry is hidden, the bank row counts once');
      await _open(t, wc, bank);
      await t.tap(key('unlinkMatch'));
      await _settle(t);
      expect(key('unlinkMatch'), findsNothing, reason: 'the sheet closed');
      expect(find.text('Unlinked: the cash entry counts again'), findsOneWidget);
      expect(wc.period().spentToday, 2 * _cash, reason: 'the entry counts again next to the bank row');
      expect(wc.isMatchedBank(bank.tx.id), isFalse);
      expect(_entry(wc).matchedTo, isNull);

      await t.tap(key('toastUndo'));
      await _settle(t);
      expect(wc.period().spentToday, _cash);
      expect(wc.isMatchedBank(bank.tx.id), isTrue);
      expect(_entry(wc).matchedTo, bank.tx.id);
      await t.pump(const Duration(seconds: 4));
    });

    test('unlinking again does not match them again after a reload', () {
      final wc = _wallet();
      expect(wc.unlinkCashMatch(_entry(wc).id, _bank(wc, -_cash).tx.id), isNull);
      wc.reload();
      expect(wc.isMatchedBank(_bank(wc, -_cash).tx.id), isFalse);
      expect(wc.period().spentToday, 2 * _cash);
    });

    testWidgets("core's refusal shows inside the sheet (a toast would sit under it) and the sheet stays open", (t) async {
      final wc = _wallet();
      await _open(t, wc, _bank(wc, -_cash));
      wc.repo.deleteTransaction(_entry(wc).id); // gone since the sheet opened
      await t.tap(key('unlinkMatch'));
      await _settle(t);
      expect(key('unlinkError'), findsOneWidget);
      expect(find.descendant(of: key('unlinkError'), matching: find.textContaining('No such transaction.', findRichText: true)),
          findsOneWidget);
      expect(find.byType(SnackBar), findsNothing, reason: 'not a toast under the sheet');
      expect(key('unlinkMatch'), findsOneWidget, reason: 'the sheet is still open');
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets("core's refusal on Undo shows in a toast", (t) async {
      final wc = _wallet();
      final bank = _bank(wc, -_cash);
      await _open(t, wc, bank);
      await t.tap(key('unlinkMatch'));
      await _settle(t);
      wc.deleteTransaction(bank.tx);
      await t.tap(key('toastUndo'));
      await _settle(t);
      expect(find.text('That bank row is no longer in the wallet.'), findsOneWidget);
      expect(_entry(wc).matchedTo, isNull);
      await t.pump(const Duration(seconds: 4));
    });

    test('the controller returns core text and logs nothing else on failure', () {
      final wc = _wallet();
      expect(wc.unlinkCashMatch('nope', 'nope'), 'No such transaction.');
      expect(wc.relinkCashMatch(_entry(wc).id, 'nope'), 'This expense was not unlinked from that bank row.');
    });

    testWidgets('the matched sheet fits 320 dp at text scale 2.0', (t) async {
      final wc = _wallet();
      await pumpApp(t, Scaffold(body: SingleChildScrollView(child: TxSheet(wc: wc, t: _bank(wc, -_cash)))),
          size: const Size(320, 1600), textScale: 2.0);
      expect(t.takeException(), isNull);
      final box = t.getRect(key('unlinkMatch'));
      expect(box.left >= 0 && box.right <= 320, isTrue, reason: 'inside the screen: $box');
      expect(box.height, greaterThanOrEqualTo(48));
    });
  });
}
