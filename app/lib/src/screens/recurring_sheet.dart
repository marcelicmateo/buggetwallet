import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/category_picker.dart';
import '../widgets/common.dart';
import '../widgets/field_editor.dart';
import '../widgets/sheets.dart';

/// How often a bill comes, in words: "every week", "every 2 weeks", "monthly", "every 3 months", "yearly" ("every 45 days" for a custom one).
String billPeriodText(int days) => switch (RecurringPeriod.of(days)) {
      RecurringPeriod.weekly => 'every week',
      RecurringPeriod.biweekly => 'every 2 weeks',
      RecurringPeriod.monthly => 'monthly',
      RecurringPeriod.quarterly => 'every 3 months',
      RecurringPeriod.yearly => 'yearly',
      null => 'every $days days',
    };

/// The chip label of a period in the add-bill sheet.
String billPeriodChip(RecurringPeriod p) => switch (p) {
      RecurringPeriod.weekly => 'Weekly',
      RecurringPeriod.biweekly => 'Every 2 weeks',
      RecurringPeriod.monthly => 'Monthly',
      RecurringPeriod.quarterly => 'Every 3 months',
      RecurringPeriod.yearly => 'Yearly',
    };

/// "40–70 €" for a range of whole units, else "40.50 € to 70 €".
String billRangeShort(int lo, int hi, String cur) => lo % storageScale(cur) == 0 && hi % storageScale(cur) == 0
    ? '${unitsText(lo, cur)}–${moneyExact(hi, cur)}'
    : '${moneyExact(lo, cur)} to ${moneyExact(hi, cur)}';

/// "40–70 €, sets aside 70 €" for a bill with an amount range, else null.
String? billRangeText(RecurringBill b, String cur) =>
    b.hasRange ? '${billRangeShort(b.minAmount!, b.maxAmount!, cur)}, sets aside ${moneyExact(b.maxAmount!, cur)}' : null;

/// "60 of 100 € paid": both numbers in the money format, the symbol once.
String billPaidText(int paid, int total, String cur) {
  final p = moneyExact(paid, cur), sym = '\u00A0${currencySymbol(cur)}';
  return '${p.endsWith(sym) ? p.substring(0, p.length - sym.length) : p} of ${moneyExact(total, cur)} paid';
}

/// "3 of 12 left" for a bill with a last due date, else null. [total] is not stored, so the words are "3 payments left".
String? billInstalmentText(RecurringBill b) {
  final n = b.instalmentsLeft;
  if (n == null) return null;
  if (n == 0) return 'All payments made';
  return n == 1 ? '1 payment left' : '$n payments left';
}

/// Opens the add-bill sheet ([edit] null) or the change sheet for [edit], and says what happened. With [income] (or an [edit] that is
/// an income, P9) it is the income form: payee required, main tags of kind extra only, no instalments.
Future<void> openRecurringForm(BuildContext context, WalletController wc, {RecurringBill? edit, bool income = false}) async {
  final isIncome = income || (edit?.isIncome ?? false);
  logNav(edit == null ? (isIncome ? 'income.add.open' : 'bill.add.open') : (isIncome ? 'income.edit.open' : 'bill.edit.open'));
  final messenger = ScaffoldMessenger.of(context);
  final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
  final r = await showSheet<String>(context, RecurringFormSheet(wc: wc, edit: edit, income: isIncome));
  if (r == 'saved') {
    toastOn(messenger, isIncome ? (edit == null ? 'Income added' : 'Income saved') : (edit == null ? 'Bill added' : 'Bill saved'),
        wide: wide, accessible: accessible);
  }
}

/// Add a bill by hand, or change one (found or added): name, main tag, amount or range, how often, first due date, payee and an
/// optional number of payments. Pops `'saved'`. Core's messages (an [ArgumentError]) show under the form.
class RecurringFormSheet extends StatefulWidget {
  final WalletController wc;
  final RecurringBill? edit;

  /// Income mode (P9): "Add income". Also on when [edit] is an income.
  final bool income;
  const RecurringFormSheet({super.key, required this.wc, this.edit, this.income = false});
  @override
  State<RecurringFormSheet> createState() => _RecurringFormSheetState();
}

class _RecurringFormSheetState extends State<RecurringFormSheet> {
  RecurringBill? get _b => widget.edit;
  bool get _income => widget.income || (_b?.isIncome ?? false);

  /// The draft the field editors keep; Save writes it (a new bill through `addRecurringBill`, an old one through one `patch`).
  late final Map<Col, Object?> _draft = {
    RecurringCols.label: _b?.label ?? '',
    RecurringCols.expectedAmount: _b?.expectedAmount,
    RecurringCols.minAmount: _b?.hasRange == true ? _b!.minAmount : null,
    RecurringCols.maxAmount: _b?.hasRange == true ? _b!.maxAmount : null,
    RecurringCols.nextDue: _b?.nextDue.isNotEmpty == true && isCalendarDate(_b!.nextDue) ? _b!.nextDue : widget.wc.today(),
  };
  late final TextEditingController _count = TextEditingController(text: _countText());
  late bool _range = _b?.hasRange ?? false;
  late bool _ends = _b?.endsOn != null;
  late int _days = _b?.intervalDays ?? RecurringPeriod.monthly.days;
  late String? _category = _b?.category;
  late final List<RulePayee> _payees = _income ? widget.wc.incomePayees() : widget.wc.recentPayees();
  String? _payee;
  String? _error;

  late final String _openCount = _countText();

  String _countText() {
    final n = _b?.instalmentsLeft;
    return n == null || n < 1 ? '' : '$n';
  }

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  void _fail(String m) => setState(() => _error = m);

  void _save() {
    final wc = widget.wc;
    final d = _draft;
    final int amount;
    final lo = d[RecurringCols.minAmount] as int?, hi = d[RecurringCols.maxAmount] as int?;
    if (_range) {
      if (lo == null || hi == null) return _fail('Enter both ends of the range, like 40 and 70.');
      amount = hi;
    } else {
      final a = d[RecurringCols.expectedAmount] as int?;
      if (a == null) return _fail(invalidAmountMessage);
      amount = a;
    }
    final due = d[RecurringCols.nextDue] as String, name = d[RecurringCols.label] as String;
    final b = _b;
    // Editing: a plan whose count was blank when the sheet opened (finished, or an end that does not read) and is still blank keeps its stored end.
    final keepEnd = b != null && b.endsOn != null && _ends && _count.text.trim().isEmpty && _openCount.isEmpty;
    int? count;
    if (_ends && !keepEnd) {
      count = int.tryParse(_count.text.trim());
      if (count == null) return _fail('Enter how many payments, like 12.');
    }
    final category = _category;
    if (category == null) return _fail(_income ? 'Pick a main tag for the income.' : 'Pick a main tag for the bill.');
    if (b == null) {
      try {
        wc.addRecurringBill(
            label: name,
            category: category,
            amount: amount,
            minAmount: _range ? lo : null,
            maxAmount: _range ? hi : null,
            intervalDays: _days,
            firstDue: due,
            payee: _payee,
            instalments: _income ? null : count,
            direction: _income ? RecurringBill.directionIn : RecurringBill.directionOut);
      } on ArgumentError catch (e) {
        return _fail('${e.message}');
      }
    } else {
      // The last due date is worked out (calendar months for a monthly bill) only when the count, the due date or the interval changed.
      final endChanged =
          count != null && (_count.text.trim() != _openCount || due != b.nextDue || _days != b.intervalDays || b.endsOn == null);
      final newEnd = endChanged ? RecurringBill.lastDueFor(due, _days, count) : null;
      final refusal = wc.updateRecurringBill(b.id, {
        if (name.trim() != b.label) RecurringCols.label: name,
        if (category != b.category) RecurringCols.category: category,
        RecurringCols.expectedAmount: amount,
        // The range is written as a pair; both null clears it.
        RecurringCols.minAmount: _range ? lo : null,
        RecurringCols.maxAmount: _range ? hi : null,
        RecurringCols.intervalDays: _days,
        RecurringCols.nextDue: due,
        if (!_ends && b.endsOn != null)
          RecurringCols.endsOn: null
        else if (newEnd != null && newEnd != b.endsOn)
          RecurringCols.endsOn: newEnd,
      });
      if (refusal != null) return _fail(refusal);
    }
    Navigator.pop(context, 'saved');
  }

  Widget _field(Col c, String id, {String? label, String? hint, bool first = false, bool large = false}) => FieldEditor(c,
          key: ValueKey(c),
          id: id,
          label: label,
          hint: hint,
          autofocus: first,
          value: _draft[c],
          today: widget.wc.today(),
          autoSave: true,
          lengths: false,
          large: large,
          capitalize: TextCapitalization.sentences, onSave: (v) {
        setState(() {
          _draft[c] = v;
          _error = null;
        });
        return null;
      });

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final editing = _b != null;
    final selected = RecurringPeriod.of(_days);
    final income = _income;
    return Column(key: ValueKey(income ? 'incomeSheet' : 'recurringSheet'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(income ? (editing ? 'Change income' : 'Add income') : (editing ? 'Change bill' : 'Add bill')),
      const SizedBox(height: 12),
      _field(RecurringCols.label, 'recurringName', label: 'Name', hint: income ? 'Side job' : 'Car insurance', first: !editing),
      const SizedBox(height: 12),
      DropdownButtonFormField<String?>(
        key: const ValueKey('recurringCategory'),
        isExpanded: true,
        initialValue: _category,
        decoration: const InputDecoration(labelText: 'Main tag'),
        items: categoryMenuItems(wc.categoryTable,
            kinds: income ? const {BudgetKind.extra} : const {BudgetKind.fixed, BudgetKind.flex}, current: _category),
        onChanged: (v) => setState(() => _category = v),
      ),
      const SizedBox(height: 4),
      SwitchListTile(
        key: const ValueKey('recurringRange'),
        contentPadding: EdgeInsets.zero,
        title: const Text('The amount changes', style: TextStyle(fontSize: BwType.bodySize)),
        subtitle: Text(income ? 'Counted at the lowest.' : 'Set aside the highest.', style: const TextStyle(fontSize: BwType.metaSize)),
        value: _range,
        onChanged: (v) => setState(() => _range = v),
      ),
      if (_range) ...[
        _field(RecurringCols.minAmount, 'recurringMin', label: 'From'),
        const SizedBox(height: 12),
        _field(RecurringCols.maxAmount, 'recurringMax', label: 'To'),
      ] else
        _field(RecurringCols.expectedAmount, 'recurringAmount', large: true),
      const SizedBox(height: 12),
      const Eyebrow('How often'),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final p in RecurringPeriod.values)
          ChoiceChip(
            key: ValueKey('recurringPeriod:${p.name}'),
            label: Text(billPeriodChip(p)),
            selected: selected == p,
            onSelected: (_) => setState(() => _days = p.days),
          ),
        if (selected == null)
          ChoiceChip(key: const ValueKey('recurringPeriod:custom'), label: Text('Every $_days days'), selected: true, onSelected: (_) {}),
      ]),
      const SizedBox(height: 12),
      _field(RecurringCols.nextDue, 'recurringDue', label: editing ? 'Next due' : 'First due'),
      const SizedBox(height: 12),
      if (editing)
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Payee'),
          child: Text(_b!.payee.isEmpty ? (income ? 'None' : 'None: you mark each payment paid') : _b!.payee.replaceAll('_', ' '),
              key: const ValueKey('recurringPayeeFixed')),
        )
      else
        DropdownButtonFormField<String?>(
          key: const ValueKey('recurringPayee'),
          isExpanded: true,
          initialValue: _payee,
          decoration: InputDecoration(
              labelText: income ? 'Paid by' : 'Payee (optional)',
              helperText:
                  income ? 'Pick who pays you, so the payment is found when it lands.' : 'Pick it so bank payments mark the bill paid.',
              helperMaxLines: 2),
          items: [
            if (!income) const DropdownMenuItem<String?>(value: null, child: Text('None: I mark each payment paid')),
            for (final p in _payees)
              DropdownMenuItem<String?>(
                  value: p.key, child: Text(p.label, key: ValueKey('payeeItem:${p.key}'), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _payee = v),
        ),
      if (!income)
        SwitchListTile(
          key: const ValueKey('recurringEnds'),
          contentPadding: EdgeInsets.zero,
          title: Text(editing ? 'Ends after some payments' : 'Instalments', style: const TextStyle(fontSize: BwType.bodySize)),
          subtitle: const Text('A fixed number of payments.', style: TextStyle(fontSize: BwType.metaSize)),
          value: _ends,
          onChanged: (v) => setState(() => _ends = v),
        ),
      if (_ends && !income)
        TextField(
          key: const ValueKey('recurringCount'),
          controller: _count,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: editing ? 'Payments left' : 'Number of payments', hintText: '12'),
        ),
      if (_error != null) ...[const SizedBox(height: 10), StatusLabel(key: const ValueKey('recurringError'), good: false, text: _error!)],
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('recurringSave'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: Text(editing ? 'Save' : (income ? 'Add income' : 'Add bill'))),
      const SizedBox(height: 8),
      Muted(
          income
              ? 'It shows as expected. It counts toward your spending money only once the payment is in.'
              : _days > 31
                  ? 'A bill that comes less often than monthly is set aside in full from today until it is paid.'
                  : 'It is set aside from your daily money until it is paid.',
          size: BwType.metaSize),
    ]);
  }
}
