import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../screens/bill_sheet.dart';
import '../screens/scan_bill.dart';
import '../theme.dart';
import 'common.dart';

/// Opens a bottom sheet on a phone, a dialog on windows [dialogMin] wide or more; logs `sheet.open` / `sheet.close` with
/// the sheet's type and result word. Both pop with the same result (the dialog's close button pops null).
Future<T?> showSheet<T>(BuildContext context, Widget child) {
  final name = child.runtimeType.toString();
  if (MediaQuery.sizeOf(context).width >= dialogMin) {
    return loggedRoute(
        name,
        showDialog<T>(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.4),
          // Dialog itself fills the window (it aligns its card), so the 480 limit is also set around it.
          builder: (ctx) => Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Dialog(
              insetPadding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, right: 4),
                      child: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: hasKeyboard ? 'Close (Esc)' : 'Close',
                          onPressed: () => Navigator.pop(ctx)),
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: child),
                  ),
                ]),
              ),
            ),
          )),
        ));
  }
  return loggedRoute(
      name,
      showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        barrierColor: Colors.black.withValues(alpha: 0.4),
        builder: (ctx) => Padding(
          padding: EdgeInsets.only(left: 16, right: 16, bottom: MediaQuery.viewInsetsOf(ctx).bottom + 20),
          child: SingleChildScrollView(child: child),
        ),
      ));
}

/// Add expense from anywhere (the Today button, Ctrl+N): opens the sheet and shows the toast for its result.
Future<void> addExpenseFlow(BuildContext context, WalletController wc) async {
  final r = await showSheet<String>(context, AddExpenseSheet(wc: wc));
  if (!context.mounted) return;
  if (r == 'added') toast(context, 'Expense added');
  if (r == 'wish') toast(context, 'On the wishlist. Decide in ${wc.settings.coolHours} hours.');
  if (r == 'scan') await scanBillFlow(context, wc);
}

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
      if (widget.wc.billInputs.camera.supported) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('scanBill'),
            style: accentOutlined(context),
            icon: const Icon(Icons.document_scanner_outlined, size: 18),
            label: const Text('Scan bill'),
            onPressed: () {
              logNav('expense.scanBill');
              Navigator.pop(context, 'scan');
            },
          ),
        ),
      ],
      const SizedBox(height: 14),
      TextField(
        controller: amount,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.end,
        style: numStyle.copyWith(fontSize: 30, fontWeight: FontWeight.w500),
        decoration: InputDecoration(suffixText: currencySymbol(cur), hintText: '0.00'),
      ),
      const SizedBox(height: 6),
      const DoubleRule(),
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
              key: const ValueKey('putOnWishlist'),
              child: const Text('Put on wishlist'),
            ),
          ),
        ]),
      ],
      const SizedBox(height: 14),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        key: const ValueKey('addExpenseSave'),
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
    final bill = widget.wc.billForTx(t.id);
    final src = switch (t.source) { 'pbz' => 'PBZ', 'revolut' => 'Revolut', _ => 'Added by you' };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(merchantName(t)),
      const SizedBox(height: 6),
      Text(money(t.amount, widget.wc.currency, decimals: 2, signed: true),
          textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: 26, fontWeight: FontWeight.w500)),
      const SizedBox(height: 6),
      const DoubleRule(),
      const SizedBox(height: 6),
      Muted('${longDateOrRaw(t.date)} · $src${t.bankType.isNotEmpty ? ' · ${t.bankType}' : ''}'),
      if (!manual)
        Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(t.description, style: const TextStyle(fontSize: 13))),
      if (bill != null) ...[
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
              key: const ValueKey('openBill'),
              style: accentOutlined(context),
              icon: const Icon(Icons.receipt_long_outlined, size: 18),
              label: const Text('Open bill'),
              onPressed: () => openBill(context, widget.wc, bill.id)),
        ),
      ],
      const SizedBox(height: 14),
      DropdownButtonFormField<String>(
        isExpanded: true,
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
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [
        FilledButton(
          onPressed: () {
            widget.wc.setCategory(t, cat, always: always && !manual);
            Navigator.pop(context, 'saved');
          },
          child: const Text('Save'),
        ),
        if (manual)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: context.c.bad),
            onPressed: () {
              widget.wc.deleteTx(t);
              Navigator.pop(context, 'deleted');
            },
            key: const ValueKey('txDelete'),
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
  String? error;

  static String _plain(int cents) => cents == 0 ? '' : (cents % 100 == 0 ? '${cents ~/ 100}' : (cents / 100).toStringAsFixed(2));

  String hint() {
    final t = parseMoney(target.text) ?? 0,
        m = parseMoney(monthly.text) ?? 0,
        s = (parseMoney(saved.text) ?? 0) + (parseMoney(add.text) ?? 0);
    if (m <= 0 || t <= s) return '';
    return 'At ${money(m, widget.wc.currency, decimals: 0)} a month you reach it in ${((t - s) / m).ceil()} months. This comes out of your daily spending money.';
  }

  /// An empty field means 0; text that is not an amount (or is negative, or too big) is refused, never turned into 0.
  int? _amount(TextEditingController c) => c.text.trim().isEmpty ? 0 : parseMoney(c.text);

  void _save() {
    // A new goal needs a target; an old goal that has none may keep it empty.
    final keepsNone = g != null && g!.target == 0;
    final t = keepsNone && target.text.trim().isEmpty ? 0 : parseMoney(target.text);
    final targetOk = t != null && (t > 0 || keepsNone);
    final m = _amount(monthly), sv = _amount(saved), ad = _amount(add);
    final bad = !targetOk
        ? 'Target'
        : m == null
            ? 'Each month'
            : sv == null
                ? 'Put aside so far'
                : ad == null
                    ? 'Add money now'
                    : (sv + ad > maxAmountCents ? 'Put aside so far' : null);
    if (bad != null) {
      logNav('goal.invalid', {'field': bad});
      setState(() => error = '$bad: enter an amount, like 500.');
      return;
    }
    widget.wc.saveGoal(
      id: g?.id,
      name: name.text.trim().isEmpty ? 'Goal' : name.text.trim(),
      target: t!,
      monthly: m!,
      saved: sv! + ad!,
      sort: g?.sort,
    );
    Navigator.pop(context, 'saved');
  }

  @override
  Widget build(BuildContext context) {
    void upd(String _) => setState(() => error = null);
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
                textAlign: TextAlign.end,
                style: numStyle,
                decoration: InputDecoration(labelText: 'Target', suffixText: currencySymbol(widget.wc.currency)))),
        const SizedBox(width: 10),
        Expanded(
            child: TextField(
                controller: monthly,
                onChanged: upd,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.end,
                style: numStyle,
                decoration: InputDecoration(labelText: 'Each month', suffixText: currencySymbol(widget.wc.currency)))),
      ]),
      const SizedBox(height: 10),
      TextField(
          controller: saved,
          onChanged: upd,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.end,
          style: numStyle,
          decoration: InputDecoration(labelText: 'Put aside so far', suffixText: currencySymbol(widget.wc.currency))),
      if (g != null) ...[
        const SizedBox(height: 10),
        TextField(
            controller: add,
            onChanged: upd,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.end,
            style: numStyle,
            decoration: InputDecoration(
                labelText: 'Add money now', hintText: 'e.g. a bonus or tax refund', suffixText: currencySymbol(widget.wc.currency))),
      ],
      const SizedBox(height: 8),
      Muted(hint()),
      const SizedBox(height: 12),
      if (error != null) ...[StatusLabel(good: false, text: error!), const SizedBox(height: 10)],
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [
        FilledButton(
          onPressed: _save,
          key: const ValueKey('goalSave'),
          child: const Text('Save goal'),
        ),
        if (g != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: context.c.bad),
            onPressed: () {
              widget.wc.deleteGoal(g!.id);
              Navigator.pop(context, 'deleted');
            },
            key: const ValueKey('goalDelete'),
            child: const Text('Delete'),
          ),
      ]),
    ]);
  }
}
