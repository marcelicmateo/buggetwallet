// P13 §4: the "Looks right?" sheet after the first import that leaves plan suggestions. All data is SYNTHETIC.
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/file_chooser.dart';
import 'package:budget_wallet/src/screens/first_plan_sheet.dart';
import 'package:budget_wallet/src/screens/import_flow.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'plan_suggestions_ui_test.dart' show proposalWallet;
import 'support/wallet.dart';

const _csv = 'Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n'
    'Card Payment,Current,2026-10-01 10:00:00,2026-10-02 10:00:00,Synthetic shop,-12.30,0.00,EUR,COMPLETED,100.00\n';

base class _Picked extends PlatformFile {
  @override
  final String name = 'synthetic.csv';
  final Uint8List data;
  _Picked(this.data);
  @override
  Uri get uri => Uri(path: name);
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => data.length;
  @override
  Future<int?> length() async => data.length;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(data);
}

class _Chooser extends FileChooser {
  final String text;
  _Chooser(this.text);
  @override
  Future<List<PlatformFile>> pickBankFiles() async {
    return [_Picked(Uint8List.fromList(utf8.encode(text)))];
  }
}

Future<void> _pumpImportButton(WidgetTester t, WalletController wc, FileChooser chooser) => pumpApp(
    t,
    Scaffold(
        body: Builder(
            builder: (context) =>
                TextButton(key: const ValueKey('go'), onPressed: () => pickAndImport(context, wc, chooser), child: const Text('Import')))),
    size: const Size(400, 900));

Future<void> _tap(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 600));
}

Future<void> _import(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('go')));
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('after an import with suggestions the sheet lists them with their basis; nothing is written by looking', (t) async {
    final wc = proposalWallet();
    final before = wc.settings.toMap().toString();
    await _pumpImportButton(t, wc, _Chooser(_csv));
    await _import(t);
    expect(find.byKey(const ValueKey('firstPlanHeading')), findsOneWidget);
    expect(find.text('Looks right?'), findsOneWidget);
    for (final k in ['salary', 'paydayDay', 'rent']) {
      expect(find.byKey(ValueKey('firstPlan:$k')), findsOneWidget);
    }
    expect(find.text('From your last salary payments.'), findsOneWidget);
    expect(find.byKey(const ValueKey('firstPlanAcceptAll')), findsOneWidget);
    expect(find.byKey(const ValueKey('firstPlanChoose')), findsOneWidget);
    expect(find.byKey(const ValueKey('firstPlanLater')), findsOneWidget);
    expect(wc.settings.toMap().toString(), before);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('Accept all writes the settings and the sheet closes', (t) async {
    final wc = proposalWallet();
    await _pumpImportButton(t, wc, _Chooser(_csv));
    await _import(t);
    await _tap(t, 'firstPlanAcceptAll');
    expect((wc.settings.salary, wc.settings.paydayDay, wc.settings.rent), (120000, 10, 60000));
    expect(find.byKey(const ValueKey('firstPlanHeading')), findsNothing);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('Choose… lets the owner untick a row; only the ticked ones are written', (t) async {
    final wc = proposalWallet();
    await _pumpImportButton(t, wc, _Chooser(_csv));
    await _import(t);
    await _tap(t, 'firstPlanChoose');
    expect(find.byKey(const ValueKey('firstPlanTick:salary')), findsOneWidget);
    await _tap(t, 'firstPlanTick:rent');
    await _tap(t, 'firstPlanAcceptTicked');
    expect(wc.settings.salary, 120000);
    expect(wc.settings.paydayDay, 10);
    expect(wc.settings.rent, 0, reason: 'unticked');
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('Not now writes nothing, hides the same rows as the Not now in Plan › Suggestions and is not shown again', (t) async {
    final wc = proposalWallet();
    await _pumpImportButton(t, wc, _Chooser(_csv));
    await _import(t);
    await _tap(t, 'firstPlanLater');
    expect(find.byKey(const ValueKey('firstPlanHeading')), findsNothing);
    expect(wc.settings.salary, 150000);
    expect(wc.repo.localValue('planSuggestShown'), '1');
    expect(wc.repo.localValue('planNotNow:salary'), '120000');
    expect(wc.repo.localValue('planNotNow:rent'), '60000');
    expect(wc.planProposalList(), isEmpty, reason: 'the same as Not now in Plan › Suggestions');
    await _import(t);
    expect(find.byKey(const ValueKey('firstPlanHeading')), findsNothing, reason: 'once per wallet');
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('an import that added no rows (all already here) shows no sheet and does not use it up', (t) async {
    final wc = proposalWallet();
    await _pumpImportButton(t, wc, _Chooser(_csv));
    await t.runAsync(() => wc.importFiles([('synthetic.csv', Uint8List.fromList(utf8.encode(_csv)))])); // the row is in already
    await _import(t);
    expect(wc.lastImport.single.added, 0);
    expect(find.byKey(const ValueKey('firstPlanHeading')), findsNothing);
    expect(wc.shouldOfferFirstPlan(), isTrue);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('no suggestions, or an import that read nothing: no sheet and it is not used up', (t) async {
    final wc = WalletController.forTest(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => budgetToday);
    await _pumpImportButton(t, wc, _Chooser(_csv));
    await _import(t);
    expect(find.byKey(const ValueKey('firstPlanHeading')), findsNothing);
    expect(wc.repo.localValue('planSuggestShown'), isNull);
    final wc2 = proposalWallet();
    await _pumpImportButton(t, wc2, _Chooser('not a bank file'));
    await _import(t);
    expect(find.byKey(const ValueKey('firstPlanHeading')), findsNothing);
    expect(wc2.shouldOfferFirstPlan(), isTrue);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('the sheet fits 320 dp at text scale 2.0', (t) async {
    final wc = proposalWallet();
    await pumpApp(
        t,
        Scaffold(
            body: Builder(
                builder: (context) =>
                    TextButton(key: const ValueKey('go'), onPressed: () => offerFirstPlan(context, wc), child: const Text('Open')))),
        size: const Size(320, 900),
        textScale: 2);
    await t.tap(find.byKey(const ValueKey('go')));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('firstPlanHeading')), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 4));
  });
}
