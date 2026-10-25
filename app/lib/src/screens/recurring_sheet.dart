import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/category_picker.dart';
import '../widgets/common.dart';
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
String billRangeShort(int lo, int hi, String cur) =>
    lo % 100 == 0 && hi % 100 == 0 ? '${unitsText(lo)}–${moneyExact(hi, cur)}' : '${moneyExact(lo, cur)} to ${moneyExact(hi, cur)}';

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

/// Opens the add-bill sheet ([edit] null) or the change sheet for [edit], and says what happened.
Future<void> openRecurringForm(BuildContext context, WalletController wc, {RecurringBill? edit}) async {
  logNav(edit == null ? 'bill.add.open' : 'bill.edit.open');
  final messenger = ScaffoldMessenger.of(context);
  final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
  final r = await showSheet<String>(context, RecurringFormSheet(wc: wc, edit: edit));
  if (r == 'saved') toastOn(messenger, edit == null ? 'Bill added' : 'Bill saved', wide: wide, accessible: accessible);
}

/// Add a bill by hand, or change one (found or added): name, main tag, amount or range, how often, first due date, payee and an
/// optional number of payments. Pops `'saved'`. Core's messages (an [ArgumentError]) show under the form.
class RecurringFormSheet extends StatefulWidget {
  final WalletController wc;
  final RecurringBill? edit;
  const RecurringFormSheet({super.key, required this.wc, this.edit});
  @override
  State<RecurringFormSheet> createState() => _RecurringFormSheetState();
}

class _RecurringFormSheetState extends State<RecurringFormSheet> {
  RecurringBill? get _b => widget.edit;
  late final TextEditingController _name = TextEditingController(text: _b?.label ?? '');
  late final TextEditingController _amount = TextEditingController(text: _b == null ? '' : centsToFieldText(_b!.expectedAmount));
  late final TextEditingController _min = TextEditingController(text: _b?.hasRange == true ? centsToFieldText(_b!.minAmount!) : '');
  late final TextEditingController _max = TextEditingController(text: _b?.hasRange == true ? centsToFieldText(_b!.maxAmount!) : '');
  late final TextEditingController _count = TextEditingController(text: _countText());
  late bool _range = _b?.hasRange ?? false;
  late bool _ends = _b?.endsOn != null;
  late int _days = _b?.intervalDays ?? RecurringPeriod.monthly.days;
  late String _due = _b?.nextDue.isNotEmpty == true && isCalendarDate(_b!.nextDue) ? _b!.nextDue : widget.wc.today();
  late String? _category = _b?.category;
  late final List<RulePayee> _payees = widget.wc.recentPayees();
  String? _payee;
  String? _error;

  late final String _openCount = _countText();

  String _countText() {
    final n = _b?.instalmentsLeft;
    return n == null || n < 1 ? '' : '$n';
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _min.dispose();
    _max.dispose();
    _count.dispose();
    super.dispose();
  }

  void _fail(String m) => setState(() => _error = m);

  void _save() {
    final wc = widget.wc;
    int amount;
    int? lo, hi;
    if (_range) {
      lo = parseMoney(_min.text);
      hi = parseMoney(_max.text);
      if (lo == null || hi == null) return _fail('Enter both ends of the range, like 40 and 70.');
      amount = hi;
    } else {
      final a = parseMoney(_amount.text);
      if (a == null) return _fail(invalidAmountMessage);
      amount = a;
    }
    final b = _b;
    // Editing: a plan whose count was blank when the sheet opened (finished, or an end that does not read) and is still blank keeps its stored end.
    final keepEnd = b != null && b.endsOn != null && _ends && _count.text.trim().isEmpty && _openCount.isEmpty;
    int? count;
    if (_ends && !keepEnd) {
      count = int.tryParse(_count.text.trim());
      if (count == null) return _fail('Enter how many payments, like 12.');
    }
    final category = _category;
    if (category == null) return _fail('Pick a main tag for the bill.');
    try {
      if (b == null) {
        wc.addRecurringBill(
            label: _name.text,
            category: category,
            amount: amount,
            minAmount: lo,
            maxAmount: hi,
            intervalDays: _days,
            firstDue: _due,
            payee: _payee,
            instalments: count);
      } else {
        // The last due date is worked out (calendar months for a monthly bill) only when the count, the due date or the interval changed.
        final endChanged =
            count != null && (_count.text.trim() != _openCount || _due != b.nextDue || _days != b.intervalDays || b.endsOn == null);
        final newEnd = endChanged ? RecurringBill.lastDueFor(_due, _days, count) : null;
        wc.updateRecurringBill(b.id,
            label: _name.text.trim() != b.label ? _name.text : null,
            category: category != b.category ? category : null,
            amount: amount,
            minAmount: lo,
            maxAmount: hi,
            clearRange: !_range && (b.minAmount != null || b.maxAmount != null),
            intervalDays: _days,
            nextDue: _due,
            endsOn: newEnd != b.endsOn ? newEnd : null,
            clearEnd: !_ends && b.endsOn != null);
      }
    } on ArgumentError catch (e) {
      return _fail('${e.message}');
    }
    Navigator.pop(context, 'saved');
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final cur = wc.currency;
    final editing = _b != null;
    final today = wc.today();
    final selected = RecurringPeriod.of(_days);
    return Column(key: const ValueKey('recurringSheet'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(editing ? 'Change bill' : 'Add bill'),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('recurringName'),
        controller: _name,
        autofocus: !editing,
        maxLength: 40,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Name', hintText: 'Car insurance', counterText: ''),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String?>(
        key: const ValueKey('recurringCategory'),
        isExpanded: true,
        initialValue: _category,
        decoration: const InputDecoration(labelText: 'Main tag'),
        items: categoryMenuItems(wc.categoryTable, kinds: const {BudgetKind.fixed, BudgetKind.flex}, current: _category),
        onChanged: (v) => setState(() => _category = v),
      ),
      const SizedBox(height: 4),
      SwitchListTile(
        key: const ValueKey('recurringRange'),
        contentPadding: EdgeInsets.zero,
        title: const Text('The amount changes', style: TextStyle(fontSize: BwType.bodySize)),
        subtitle: const Text('Set aside the highest.', style: TextStyle(fontSize: BwType.metaSize)),
        value: _range,
        onChanged: (v) => setState(() => _range = v),
      ),
      if (_range) ...[
        MoneyField(
          fieldKey: const ValueKey('recurringMin'),
          controller: _min,
          decoration: InputDecoration(labelText: 'From', suffixText: currencySymbol(cur), hintText: amountHint),
        ),
        const SizedBox(height: 12),
        MoneyField(
          fieldKey: const ValueKey('recurringMax'),
          controller: _max,
          decoration: InputDecoration(labelText: 'To', suffixText: currencySymbol(cur), hintText: amountHint),
        ),
      ] else
        MoneyField(
          fieldKey: const ValueKey('recurringAmount'),
          controller: _amount,
          style: numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500),
          decoration: InputDecoration(labelText: 'Amount', suffixText: currencySymbol(cur), hintText: amountHint),
        ),
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
      DateField(
        key: const ValueKey('recurringDue'),
        label: editing ? 'Next due' : 'First due',
        value: _due,
        onPick: () async {
          final d = await showDatePicker(
              context: context,
              initialDate: parseIso(_due),
              firstDate: parseIso(addDays(today, -400)),
              lastDate: parseIso(addDays(today, 365 * 5)));
          if (d != null) setState(() => _due = isoDate(d));
        },
      ),
      const SizedBox(height: 12),
      if (editing)
        InputDecorator(
          decoration: const InputDecoration(labelText: 'Payee'),
          child: Text(_b!.payee.isEmpty ? 'None: you mark each payment paid' : _b!.payee.replaceAll('_', ' '),
              key: const ValueKey('recurringPayeeFixed')),
        )
      else
        DropdownButtonFormField<String?>(
          key: const ValueKey('recurringPayee'),
          isExpanded: true,
          initialValue: _payee,
          decoration: const InputDecoration(
              labelText: 'Payee (optional)', helperText: 'Pick it so bank payments mark the bill paid.', helperMaxLines: 2),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('None: I mark each payment paid')),
            for (final p in _payees)
              DropdownMenuItem<String?>(
                  value: p.key, child: Text(p.label, key: ValueKey('payeeItem:${p.key}'), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() => _payee = v),
        ),
      SwitchListTile(
        key: const ValueKey('recurringEnds'),
        contentPadding: EdgeInsets.zero,
        title: Text(editing ? 'Ends after some payments' : 'Instalments', style: const TextStyle(fontSize: BwType.bodySize)),
        subtitle: const Text('A fixed number of payments.', style: TextStyle(fontSize: BwType.metaSize)),
        value: _ends,
        onChanged: (v) => setState(() => _ends = v),
      ),
      if (_ends)
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
          child: Text(editing ? 'Save' : 'Add bill')),
      const SizedBox(height: 8),
      Muted(
          _days > 31
              ? 'A bill that comes less often than monthly is set aside in full from today until it is paid.'
              : 'It is set aside from your daily money until it is paid.',
          size: BwType.metaSize),
    ]);
  }
}
