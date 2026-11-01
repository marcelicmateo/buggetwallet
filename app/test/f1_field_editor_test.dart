// F1 (docs/context/FIELDS_PLAN.md): FieldEditor draws and saves any column by its kind, and a sheet that lists columns needs no other
// change to show one more. The done check: a test-only Col list with an extra DateCol. All data is SYNTHETIC.
import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/widgets/field_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/seams.dart';
import 'support/wallet.dart';

const _today = '2026-10-20';

enum _Shape { round, square }

// The test-only columns. `guaranteeUntil` is "the new field": this one line, plus its entry in `_cols`, is all the screen needs.
const _guaranteeUntil = DateCol('gadget', 'guarantee_until', label: 'Guarantee until', nullable: true);
const _boughtOn = DateCol('gadget', 'bought_on', label: 'Bought on', notAfterToday: true);
const _warnDays = IntCol('gadget', 'warn_days', label: 'Warning', nullable: true, min: 0, max: 30, unit: 'days before');
const _price = MoneyCol('gadget', 'price', label: 'Price', nullable: true);
const _shape = EnumCol('gadget', 'shape', label: 'Shape', values: _Shape.values, defaultValue: _Shape.round);
const _label = TextCol('gadget', 'label', label: 'Label', nullable: true, maxLength: 5);
const _boxed = FlagCol('gadget', 'boxed', label: 'Boxed');

/// A sheet that is only a field list over a map of values; `refuse` makes onSave say no.
class _Sheet extends StatefulWidget {
  const _Sheet(this.cols, this.saved, {this.refuse});
  final List<Col> cols;
  final Map<Col, Object?> saved;
  final String? refuse;
  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  @override
  Widget build(BuildContext context) => Scaffold(
          body: SingleChildScrollView(
              child: Column(children: [
        for (final c in widget.cols)
          FieldEditor(c,
              value: widget.saved[c],
              today: _today,
              currency: 'EUR',
              labelOf: (e) => e.name.toUpperCase(),
              onSave: (v) {
                if (widget.refuse != null) return widget.refuse;
                setState(() => widget.saved[c] = v);
                return null;
              }),
      ])));
}

Finder k(String key) => find.byKey(ValueKey(key));

void main() {
  tearDown(() => walletCurrencyCode = 'EUR');

  testWidgets('done check: one extra DateCol in the list renders, takes a length and clears', (t) async {
    final saved = <Col, Object?>{};
    await pumpApp(t, _Sheet(const [_boughtOn, _guaranteeUntil], saved));
    expect(find.text('Guarantee until'), findsOneWidget);
    expect(k('guaranteeUntil:chip:1y'), findsOneWidget, reason: 'an empty date offers the lengths');
    await t.tap(k('guaranteeUntil:chip:1y'));
    await t.pump();
    expect(saved[_guaranteeUntil], '2027-10-20');
    expect(k('guaranteeUntil:chip:1y'), findsNothing, reason: 'a set date shows the date only');
    expect(find.byTooltip('Clear Guarantee until'), findsOneWidget);
    await t.tap(find.byTooltip('Clear Guarantee until'));
    await t.pump();
    expect(saved[_guaranteeUntil], isNull);
    expect(saved.containsKey(_guaranteeUntil), isTrue);
    expect(find.byTooltip('Clear Bought on'), findsNothing, reason: 'a column that needs a value cannot be cleared');
  });

  testWidgets('a length field takes 45d and says what it cannot read; the column refuses a future date inline', (t) async {
    final saved = <Col, Object?>{};
    await pumpApp(t, _Sheet(const [_boughtOn, _guaranteeUntil], saved));
    await t.enterText(k('guaranteeUntil:length'), '45d');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(saved[_guaranteeUntil], '2026-12-04');
    await t.enterText(k('boughtOn:length'), 'soon');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(k('boughtOn:lengthError'), findsOneWidget);
    await t.tap(k('boughtOn:chip:4d'));
    await t.pump();
    expect(k('boughtOnError'), findsOneWidget, reason: 'Bought on cannot be after today: inline, onSave not called');
    expect(find.textContaining('Cannot be in the future.', findRichText: true), findsOneWidget);
    expect(saved.containsKey(_boughtOn), isFalse);
  });

  testWidgets('core\'s refusal is shown under the field and the value is not kept', (t) async {
    final saved = <Col, Object?>{};
    await pumpApp(t, _Sheet(const [_guaranteeUntil], saved, refuse: 'Guarantee until: no.'));
    await t.tap(k('guaranteeUntil:chip:1m'));
    await t.pump();
    expect(find.textContaining('Guarantee until: no.', findRichText: true), findsOneWidget);
    expect(saved, isEmpty);
  });

  testWidgets('number, amount, choice, text and switch', (t) async {
    final saved = <Col, Object?>{_warnDays: 3, _shape: _Shape.round};
    await pumpApp(t, _Sheet(const [_warnDays, _price, _shape, _label, _boxed], saved));
    expect(find.text('Warning 3 days before'), findsOneWidget);
    await t.tap(k('warnDaysChange'));
    await t.pump();
    await t.enterText(k('warnDaysDays'), '31');
    await t.tap(k('warnDaysSave'));
    await t.pump();
    expect(find.textContaining('0 to 30 days before.', findRichText: true), findsOneWidget);
    expect(saved[_warnDays], 3);
    await t.enterText(k('warnDaysDays'), '1');
    await t.tap(k('warnDaysSave'));
    await t.pump();
    expect(saved[_warnDays], 1);
    expect(find.text('Warning 1 day before'), findsOneWidget);

    await t.enterText(k('price'), '12,50x');
    await t.pump();
    await t.tap(k('priceSave'));
    await t.pump();
    expect(find.textContaining(invalidAmountMessage, findRichText: true), findsOneWidget);
    await t.enterText(k('price'), '12.50');
    await t.tap(k('priceSave'));
    await t.pump();
    expect(saved[_price], 1250);

    await t.tap(k('shape:square'));
    await t.pump();
    expect(saved[_shape], _Shape.square);
    expect(find.text('SQUARE'), findsOneWidget, reason: 'labelOf names the choices');

    await t.enterText(k('label'), 'toolong');
    await t.pump();
    await t.tap(k('labelSave'));
    await t.pump();
    expect(find.textContaining('Limited to 5 characters.', findRichText: true), findsOneWidget);
    await t.enterText(k('label'), 'ok');
    await t.pump();
    await t.tap(k('labelSave'));
    await t.pump();
    expect(saved[_label], 'ok');
    await t.enterText(k('label'), '');
    await t.pump();
    await t.tap(k('labelSave'));
    await t.pump();
    expect(saved[_label], isNull, reason: 'empty text in a nullable column clears it');

    await t.tap(k('boxed'));
    await t.pump();
    expect(saved[_boxed], true);
  });

  testWidgets('an amount is read in the row\'s currency (whole yen), and autoSave reports every change', (t) async {
    final seen = <Object?>[];
    await pumpApp(
        t,
        Scaffold(
            body: FieldEditor(_price, value: null, today: _today, currency: 'JPY', autoSave: true, onSave: (v) {
          seen.add(v);
          return null;
        })));
    expect(find.text('0'), findsWidgets, reason: 'the hint has no decimals');
    await t.enterText(k('price'), '1500');
    await t.pump();
    expect(seen.last, 150000, reason: 'stored in hundredths like every fiat, typed as whole yen');
    await t.enterText(k('price'), '');
    await t.pump();
    expect(seen.last, isNull);
  });

  test('wc.patchField writes through core and returns its refusal', () {
    final wc = seamedController(WalletRepo.inMemory(), key: VaultKey.generate(), clock: () => DateTime(2026, 10, 20, 12));
    final (id, _) = wc.repo
        .importBill(const NormalizedBill(source: BillSource.manual, externalId: 'f1', date: _today, total: 1000, payee: 'Synthetic shop'));
    wc.reload();
    expect(wc.patchField(BillCols.entity, id, BillCols.warrantyUntil, '2027-10-20'), isNull);
    expect(wc.bill(id)!.warrantyUntil, '2027-10-20');
    expect(wc.patchField(BillCols.entity, id, BillCols.warrantyUntil, clearValue), isNull);
    expect(wc.bill(id)!.warrantyUntil, isNull);
    expect(wc.patchField(BillCols.entity, id, BillCols.warrantyReminderDays, 91), 'Warranty reminder: 0 to 90 days before.');
    expect(wc.patchFields(BillCols.entity, id, {BillCols.returnBy: '2027-01-01', BillCols.returnReminderDays: 31}),
        'Return reminder: 0 to 30 days before.');
    expect(wc.bill(id)!.returnBy, isNull, reason: 'all or none');
    expect(wc.patchFields(BillCols.entity, id, {BillCols.returnBy: '2027-01-01', BillCols.returnReminderDays: 7}), isNull);
    expect(wc.bill(id)!.returnReminderDays, 7);
  });
}
