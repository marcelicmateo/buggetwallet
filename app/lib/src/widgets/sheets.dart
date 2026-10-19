import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../logging.dart';
import '../theme.dart';
import 'common.dart';

/// Opens a bottom sheet; logs `sheet.open` / `sheet.close` with the sheet's type and result word.
Future<T?> showSheet<T>(BuildContext context, Widget child) => loggedRoute(
    child.runtimeType.toString(),
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: context.c.surface,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(left: 16, right: 16, bottom: MediaQuery.viewInsetsOf(ctx).bottom + 20),
        child: SingleChildScrollView(child: child),
      ),
    ));

// ---------------------------------------------------------------- add expense
class AddExpenseSheet extends StatefulWidget {
  final WalletController wc;
  final int? amount;
  final String? note;
  final bool skipImpulse;
  const AddExpenseSheet({super.key, required this.wc, this.amount, this.note, this.skipImpulse = false});
  @override
  State<AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends State<AddExpenseSheet> {
  late final TextEditingController amount =
      TextEditingController(text: widget.amount == null ? '' : (widget.amount! / 100).toStringAsFixed(2));
  late final TextEditingController note = TextEditingController(text: widget.note ?? '');
  String cat = 'Groceries';
  DateTime date = DateTime.now();
  String? error;
  bool warned = false;

  @override
  void initState() {
    super.initState();
    warned = widget.skipImpulse;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.wc.settings;
    final cur = widget.wc.currency;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Add expense'),
      const SizedBox(height: 14),
      TextField(
        controller: amount,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
        decoration: InputDecoration(prefixText: currencySymbol(cur), hintText: '0.00'),
      ),
      const SizedBox(height: 14),
      const Muted('Category'),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final c in flexCategories.where((c) => c != 'Bank fees'))
          ChoiceChip(label: Text(c), selected: c == cat, onSelected: (_) => setState(() => cat = c)),
      ]),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: TextField(controller: note, decoration: const InputDecoration(labelText: 'Note', hintText: 'Lunch with Ana'))),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          icon: const Icon(Icons.event, size: 18),
          label: Text(shortDate(isoDate(date))),
          onPressed: () async {
            final d = await showDatePicker(
                context: context, initialDate: date, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 1)));
            if (d != null) setState(() => date = d);
          },
        ),
      ]),
      if (error != null) ...[const SizedBox(height: 10), StatusLabel(good: false, text: error!)],
      if (warned && !widget.skipImpulse && (parseMoney(amount.text) ?? 0) > s.impulse) ...[
        const SizedBox(height: 12),
        Panel(color: context.c.warnBg, children: [
          Text('Over ${money(s.impulse, cur, decimals: 0)}: wishlist first?',
              style: TextStyle(fontWeight: FontWeight.w600, color: context.c.warnInk)),
          Text('Your rule says big buys wait ${s.coolHours} hours. If you already paid, tap Add expense again.',
              style: TextStyle(color: context.c.warnInk, fontSize: 13)),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () {
                widget.wc.addWish(note.text.trim().isEmpty ? cat : note.text.trim(), parseMoney(amount.text)!);
                Navigator.pop(context, 'wish');
              },
              child: const Text('Put on wishlist'),
            ),
          ),
        ]),
      ],
      const SizedBox(height: 14),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        icon: const Icon(Icons.add),
        label: const Text('Add expense', style: TextStyle(fontSize: 16)),
        onPressed: () {
          final a = parseMoney(amount.text);
          if (a == null || a <= 0) {
            logNav('expense.invalid');
            setState(() => error = 'Enter an amount, like 12.50.');
            return;
          }
          if (a > s.impulse && !warned) {
            logNav('expense.impulseWarning');
            setState(() {
              warned = true;
              error = null;
            });
            return;
          }
          widget.wc.addExpense(amount: a, category: cat, note: note.text.trim(), date: isoDate(date));
          Navigator.pop(context, 'added');
        },
      ),
      const SizedBox(height: 10),
      const Muted(
          'Cash from an ATM is already counted when you withdraw it. Log card payments here; the weekly import matches them so nothing is counted twice.',
          size: 12.5),
    ]);
  }
}

// ---------------------------------------------------------------- transaction
class TxSheet extends StatefulWidget {
  final WalletController wc;
  final CategorizedTx t;
  const TxSheet({super.key, required this.wc, required this.t});
  @override
  State<TxSheet> createState() => _TxSheetState();
}

class _TxSheetState extends State<TxSheet> {
  late String cat = widget.t.category;
  bool always = true;

  @override
  Widget build(BuildContext context) {
    final t = widget.t.tx;
    final manual = t.source == 'manual';
    final src = switch (t.source) { 'pbz' => 'PBZ', 'revolut' => 'Revolut', _ => 'Added by you' };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(merchantName(t)),
      const SizedBox(height: 6),
      Text(money(t.amount, widget.wc.currency, decimals: 2, signed: true), style: numStyle.copyWith(fontSize: 22)),
      const SizedBox(height: 4),
      Muted('${longDate(t.date)} · $src${t.bankType.isNotEmpty ? ' · ${t.bankType}' : ''}'),
      if (!manual)
        Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(t.description, style: const TextStyle(fontSize: 13))),
      const SizedBox(height: 14),
      DropdownButtonFormField<String>(
        initialValue: cat,
        decoration: const InputDecoration(labelText: 'Category'),
        items: [for (final c in categories.keys) DropdownMenuItem(value: c, child: Text(c))],
        onChanged: (v) => setState(() => cat = v ?? cat),
      ),
      if (!manual)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: always,
          onChanged: (v) => setState(() => always = v),
          title: Text('Always use this for ${merchantName(t)}', style: const TextStyle(fontSize: 14)),
        ),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton(
          onPressed: () {
            widget.wc.setCategory(t, cat, always: always && !manual);
            Navigator.pop(context, 'saved');
          },
          child: const Text('Save'),
        ),
        const Spacer(),
        if (manual)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: context.c.bad),
            onPressed: () {
              widget.wc.deleteTx(t);
              Navigator.pop(context, 'deleted');
            },
            child: const Text('Delete'),
          ),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------- goal
class GoalSheet extends StatefulWidget {
  final WalletController wc;
  final Goal? goal;
  final String? name;
  final int? target;
  const GoalSheet({super.key, required this.wc, this.goal, this.name, this.target});
  @override
  State<GoalSheet> createState() => _GoalSheetState();
}

class _GoalSheetState extends State<GoalSheet> {
  late final g = widget.goal;
  late final name = TextEditingController(text: g?.name ?? widget.name ?? '');
  late final target = TextEditingController(text: _plain(g?.target ?? widget.target ?? 0));
  late final monthly = TextEditingController(text: _plain(g?.monthly ?? 5000));
  late final saved = TextEditingController(text: _plain(g?.saved ?? 0));
  final add = TextEditingController();

  static String _plain(int cents) => cents == 0 ? '' : (cents % 100 == 0 ? '${cents ~/ 100}' : (cents / 100).toStringAsFixed(2));

  String hint() {
    final t = parseMoney(target.text) ?? 0,
        m = parseMoney(monthly.text) ?? 0,
        s = (parseMoney(saved.text) ?? 0) + (parseMoney(add.text) ?? 0);
    if (m <= 0 || t <= s) return '';
    return 'At ${money(m, widget.wc.currency, decimals: 0)} a month you reach it in ${((t - s) / m).ceil()} months. This comes out of your daily spending money.';
  }

  @override
  Widget build(BuildContext context) {
    void upd(String _) => setState(() {});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(g == null ? 'New goal' : 'Edit goal'),
      const SizedBox(height: 14),
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', hintText: 'New laptop')),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
            child: TextField(
                controller: target,
                onChanged: upd,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Target'))),
        const SizedBox(width: 10),
        Expanded(
            child: TextField(
                controller: monthly,
                onChanged: upd,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Each month'))),
      ]),
      const SizedBox(height: 10),
      TextField(
          controller: saved,
          onChanged: upd,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Put aside so far')),
      if (g != null) ...[
        const SizedBox(height: 10),
        TextField(
            controller: add,
            onChanged: upd,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Add money now', hintText: 'e.g. a bonus or tax refund')),
      ],
      const SizedBox(height: 8),
      Muted(hint()),
      const SizedBox(height: 12),
      Row(children: [
        FilledButton(
          onPressed: () {
            widget.wc.saveGoal(
              id: g?.id,
              name: name.text.trim().isEmpty ? 'Goal' : name.text.trim(),
              target: parseMoney(target.text) ?? 0,
              monthly: parseMoney(monthly.text) ?? 0,
              saved: (parseMoney(saved.text) ?? 0) + (parseMoney(add.text) ?? 0),
              sort: g?.sort,
            );
            Navigator.pop(context, 'saved');
          },
          child: const Text('Save goal'),
        ),
        const Spacer(),
        if (g != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: context.c.bad),
            onPressed: () {
              widget.wc.deleteGoal(g!.id);
              Navigator.pop(context, 'deleted');
            },
            child: const Text('Delete'),
          ),
      ]),
    ]);
  }
}
