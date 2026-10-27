import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../screens/bill_sheet.dart';
import '../screens/rules_panel.dart';
import '../screens/scan_bill.dart';
import '../theme.dart';
import 'attachments.dart';
import 'category_picker.dart';
import 'common.dart';
import 'split_sheet.dart';
import 'tag_picker.dart';

/// Opens a bottom sheet on a phone, a dialog on windows [dialogMin] wide or more; logs `sheet.open` / `sheet.close` with
/// the sheet's type and result word. With `scrolls: false` the sheet scrolls its own body (a `Flexible` scroll view) and
/// keeps a button pinned below it. Both pop with the same result (the dialog's close button pops null).
Future<T?> showSheet<T>(BuildContext context, Widget child, {bool scrolls = true}) {
  clearToasts(context);
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
                          key: const ValueKey('sheetClose'),
                          icon: const Icon(Icons.close),
                          tooltip: hasKeyboard ? 'Close (Esc)' : 'Close',
                          onPressed: () => Navigator.pop(ctx)),
                    ),
                  ),
                  Flexible(
                    child: scrolls
                        ? SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: child)
                        : Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: child),
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
          child: scrolls
              ? SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [closeRow(ctx), child]))
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  closeRow(ctx),
                  Flexible(child: child),
                ]),
        ),
      ));
}

/// The toast after a transaction sheet closed with [result] ('deleted' has an Undo, I4).
void txSheetToast(BuildContext context, WalletController wc, String? result) {
  if (result == null) return;
  final id = wc.lastDeletedTx;
  final removed = wc.lastRemovedSplit;
  final offer = result == 'saved' ? wc.takeRuleOffer() : null; // Q6: read once
  if (result == 'splitRemoved' && removed != null) {
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    toast(context, 'Split removed', actionLabel: 'Undo', onAction: () {
      if (!wc.restoreSplitOf(removed.$1, removed.$2)) toastOn(messenger, "Couldn't put the split back", wide: wide, accessible: accessible);
    });
  } else if (result == 'split') {
    toast(context, 'Split saved');
  } else if (result == 'deleted' && id != null) {
    toast(context, 'Deleted', actionLabel: 'Undo', onAction: () => wc.undeleteTransaction(id));
  } else if (offer != null) {
    // Q6: the third payment of a payee set by hand: offer a rule. Nothing is made until the tap; the Undo after it takes it back.
    final messenger = ScaffoldMessenger.of(context);
    final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
    final name = offer.suggestion.merchantName, cat = wc.categoryTable.label(offer.suggestion.category);
    toastOn(messenger, 'Always put $name in $cat?', wide: wide, accessible: accessible, actionLabel: 'Make rule', onAction: () {
      wc.makeOfferedRule(offer);
      toastOn(messenger, 'Rule made', wide: wide, accessible: accessible, actionLabel: 'Undo', onAction: () => wc.undoOfferedRule(offer));
    });
  } else {
    toast(context, result == 'deleted' ? 'Deleted' : (tagFailureText(wc.takeTagFailures()) ?? 'Saved'));
  }
}

/// The toast after a goal sheet closed with [result].
void goalSheetToast(BuildContext context, WalletController wc, String? result) {
  final id = wc.lastDeletedGoal;
  if (result == 'deleted' && id != null) toast(context, 'Goal deleted', actionLabel: 'Undo', onAction: () => wc.undeleteGoal(id));
}

/// The X at the top right of a phone sheet.
Widget closeRow(BuildContext ctx) => Align(
      alignment: Alignment.centerRight,
      child: IconButton(
          key: const ValueKey('sheetClose'), icon: const Icon(Icons.close), tooltip: 'Close', onPressed: () => Navigator.pop(ctx)),
    );

/// Opens [screen] (a Scaffold with a [DialogAppBar]) as a full-screen page on a phone and as a dialog [width] wide from [dialogMin]
/// (at most [maxHeight] tall, the window height minus 48 when that is less). With [logName] the open and close are logged like a sheet.
Future<T?> openPageOrDialog<T>(BuildContext context, Widget screen, {required double width, double maxHeight = 760, String? logName}) {
  clearToasts(context);
  final Future<T?> route;
  if (MediaQuery.sizeOf(context).width >= dialogMin) {
    route = showDialog<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: width, height: (MediaQuery.sizeOf(ctx).height - 48).clamp(300.0, maxHeight), child: screen),
      ),
    );
  } else {
    route = Navigator.of(context).push<T>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => screen));
  }
  return logName == null ? route : loggedRoute(logName, route);
}

/// The app bar of a page opened with [openPageOrDialog]: a close button on the left, the [title], optional [actions] and a 2 px
/// strong rule underneath.
class DialogAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;
  const DialogAppBar({super.key, required this.title, this.actions});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 2);

  @override
  Widget build(BuildContext context) => AppBar(
        title: Text(title),
        leading: IconButton(
            key: const ValueKey('sheetClose'), icon: const Icon(Icons.close), tooltip: 'Close', onPressed: () => Navigator.pop(context)),
        actions: actions,
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(height: 1, color: context.c.line)),
      );
}

/// Add expense from anywhere (the Today button, Ctrl+N): opens the sheet and shows the toast for its result.
Future<void> addExpenseFlow(BuildContext context, WalletController wc) async {
  final r = await showSheet<String>(context, AddExpenseSheet(wc: wc));
  if (!context.mounted) return;
  if (r == 'added') toast(context, tagFailureText(wc.takeTagFailures())?.replaceFirst('Saved', 'Expense added') ?? 'Expense added');
  if (r == 'wish') {
    final id = wc.lastAddedWish;
    toast(context, 'On the wishlist. Decide in ${wc.settings.coolHours} hours.',
        actionLabel: id == null ? null : 'Open', onAction: id == null ? null : () => wc.openWish(id));
  }
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
  late final TextEditingController amount = TextEditingController(text: widget.amount == null ? '' : centsToFieldText(widget.amount!));
  late final TextEditingController note = TextEditingController(text: widget.note ?? '');

  /// The last category used on this device; none on a fresh device (the CTA waits for a pick).
  late String? cat = widget.wc.lastExpenseCategory;

  /// Extra tags the new expense starts with (written with it).
  Set<String> tags = {};

  /// The main tags in recommended order, read once (core's ordering reads every row).
  late final List<String> mainIds = [
    for (final id in widget.wc.recommendedMainFor(null, kinds: addExpenseKinds))
      if (!addExpenseExclude.contains(id)) id
  ];
  final wishName = TextEditingController();
  late DateTime date = widget.wc.now;
  String? error;
  bool warned = false;

  final _noteFocus = FocusNode(debugLabel: 'expenseNote');

  /// The main tags the typed note suggests (Q1): chips under the note, a tap picks one. Never applied on its own.
  List<String> _suggested = const [];
  Timer? _suggestDebounce;
  String _suggestFor = '';

  @override
  void initState() {
    super.initState();
    warned = widget.skipImpulse;
    _suggested = widget.wc.suggestCategoriesFor(note.text);
    _suggestFor = note.text;
    note.addListener(_noteChanged);
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    note.removeListener(_noteChanged);
    _noteFocus.dispose();
    super.dispose();
  }

  /// A typed or completed note: the chips follow 250 ms after the typing stops.
  void _noteChanged() {
    if (note.text == _suggestFor) return;
    _suggestDebounce?.cancel();
    _suggestDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _suggestFor = note.text;
      final next = widget.wc.suggestCategoriesFor(note.text);
      if (!listEquals(next, _suggested)) setState(() => _suggested = next);
    });
  }

  Widget _noteField() => LayoutBuilder(
        builder: (context, box) => RawAutocomplete<String>(
          textEditingController: note,
          focusNode: _noteFocus,
          // Upwards: the list must not cover the chips and the Add button under the field.
          optionsViewOpenDirection: OptionsViewOpenDirection.up,
          optionsBuilder: (v) => widget.wc.payeesFor(v.text),
          optionsViewBuilder: (context, onSelected, options) => Align(
            alignment: Alignment.bottomLeft,
            child: Material(
              elevation: 4,
              color: context.c.surface,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth, maxHeight: touchMin * 5),
                child: ListView(key: const ValueKey('payeeOptions'), padding: EdgeInsets.zero, shrinkWrap: true, children: [
                  for (final (i, o) in options.indexed)
                    InkWell(
                      key: ValueKey('payeeOption:$i'),
                      onTap: () {
                        logNav('expense.payeePicked');
                        onSelected(o);
                      },
                      child: Container(
                          constraints: const BoxConstraints(minHeight: touchMin),
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Text(o)),
                    ),
                ]),
              ),
            ),
          ),
          fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
              key: const ValueKey('expenseNote'),
              controller: controller,
              focusNode: focus,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Note', hintText: 'Lunch with Ana')),
        ),
      );

  Widget _suggestChips(BuildContext context) {
    final table = widget.wc.categoryTable;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(key: const ValueKey('suggestChips'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Muted('Suggested main tag', size: BwType.metaSize),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final id in _suggested)
            ChoiceChip(
              key: ValueKey('suggestCat:$id'),
              label: Text(table.label(id)),
              selected: cat == id,
              onSelected: (_) {
                logNav('expense.suggestPicked');
                setState(() => cat = id);
              },
            ),
        ]),
      ]),
    );
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
      MoneyField(
        controller: amount,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        style: numStyle.copyWith(fontSize: BwType.entrySize, fontWeight: FontWeight.w500),
        decoration: InputDecoration(labelText: 'Amount', suffixText: currencySymbol(cur), hintText: amountHint),
      ),
      const SizedBox(height: 6),
      const DoubleRule(),
      const SizedBox(height: 14),
      InputDecorator(
        key: const ValueKey('categoryField'),
        decoration: InputDecoration(labelText: cat == null ? 'Main tag (pick one)' : 'Main tag'),
        child: MainTagPicker(table: widget.wc.categoryTable, ids: mainIds, selected: cat, onPick: (c) => setState(() => cat = c)),
      ),
      const SizedBox(height: 14),
      ExtraTagsEditor(wc: widget.wc, initial: tags, onChanged: (v, _) => tags = v),
      const SizedBox(height: 14),
      _noteField(),
      if (_suggested.isNotEmpty) _suggestChips(context),
      const SizedBox(height: 14),
      DateField(
        label: 'Date',
        value: isoDate(date),
        onPick: () async {
          final d = await showDatePicker(
              context: context, initialDate: date, firstDate: DateTime(2020), lastDate: widget.wc.now.add(const Duration(days: 1)));
          if (d != null) setState(() => date = d);
        },
      ),
      if (error != null) ...[const SizedBox(height: 10), StatusLabel(good: false, text: error!)],
      if (warned && !widget.skipImpulse && (parseMoney(amount.text) ?? 0) > s.impulse) ...[
        const SizedBox(height: 12),
        Panel(color: context.c.warnBg, children: [
          Text('Over ${money(s.impulse, cur, decimals: 0)}: wishlist first?',
              style: TextStyle(fontWeight: FontWeight.w600, color: context.c.warnInk)),
          Text('Your rule says big buys wait ${s.coolHours} hours. If you already paid, tap Add expense again.',
              style: TextStyle(color: context.c.warnInk, fontSize: BwType.metaSize)),
          // A wish takes its name from the note; with no note the owner names it (never the category).
          if (note.text.trim().isEmpty)
            TextField(
                key: const ValueKey('wishName'),
                controller: wishName,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Name of the wish', hintText: 'Running shoes')),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: (note.text.trim().isEmpty ? wishName.text.trim() : note.text.trim()).isEmpty
                  ? null
                  : () {
                      widget.wc.addWish(note.text.trim().isEmpty ? wishName.text.trim() : note.text.trim(), parseMoney(amount.text)!);
                      Navigator.pop(context, 'wish');
                    },
              key: const ValueKey('putOnWishlist'),
              child: const Text('Put on wishlist'),
            ),
          ),
        ]),
      ],
      const SizedBox(height: 14),
      const Muted(
          'Cash from an ATM is already counted when you withdraw it. Log card payments here; the weekly import matches them so nothing is counted twice.',
          size: BwType.metaSize),
      const SizedBox(height: 10),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
        key: const ValueKey('addExpenseSave'),
        icon: const Icon(Icons.add),
        label: const Text('Add expense', style: TextStyle(fontSize: BwType.headingSize)),
        onPressed: cat == null
            ? null
            : () {
                final a = parseMoney(amount.text);
                if (a == null || a <= 0) {
                  logNav('expense.invalid');
                  setState(() => error = invalidAmountMessage);
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
                widget.wc.addExpense(amount: a, category: cat!, note: note.text.trim(), date: isoDate(date), tags: tags.toList());
                Navigator.pop(context, 'added');
              },
      ),
    ]);
  }
}

// ---------------------------------------------------------------- transaction
class TxSheet extends StatefulWidget {
  final WalletController wc;
  final CategorizedTx t;

  /// The file dialogs (a fake in tests) for "Attach photo or PDF".
  final FileChooser chooser;
  const TxSheet({super.key, required this.wc, required this.t, this.chooser = const FileChooser()});
  @override
  State<TxSheet> createState() => _TxSheetState();
}

class _TxSheetState extends State<TxSheet> {
  /// The payment as one row: a part tapped in a list opens its payment's sheet (P6).
  late final CategorizedTx row = widget.wc.rawRow(widget.t); // never the converted row (P15)
  late String cat = row.category;
  bool always = true;

  /// The main tags in recommended order for this payment (the payee's first), read once.
  late final List<String> mainIds = widget.wc.recommendedMainFor(row.tx);

  /// The tag draft the editor reports (null: untouched). Save writes it; closing writes nothing.
  Set<String>? tagOn, tagRule;
  bool saving = false;

  /// The bank row that replaced this hand-added expense, or the expense a bank row replaced (read once: it scans the rows).
  /// Read-only: there is no unlink yet.
  late final Tx? matchedBank =
      row.tx.manual && row.tx.matchedTo != null && !row.tx.matchPending ? widget.wc.repo.transaction(row.tx.matchedTo!) : null;
  late final Tx? matchedEntry = row.tx.manual ? null : widget.wc.entryMatchedTo(row.tx.id);

  /// Bank and hand-added payments can be split, transfers cannot (P6).
  bool get canSplit => row.kind != BudgetKind.transfer && row.tx.transferTo == null && row.tx.amount != 0 && row.tx.live;

  Future<void> _openSplit() async {
    // The pick made on this sheet but not saved yet goes into the first part of a new split (the sheet's own Save is not used).
    final r = await showSheet<String>(context, SplitSheet(wc: widget.wc, row: row, firstCategory: cat, firstTags: tagOn));
    if (r != null && mounted) Navigator.pop(context, r);
  }

  Widget _splitSection(BuildContext context) {
    final id = row.tx.id;
    final n = widget.wc.splitCount(id);
    final broken = widget.wc.splitIsBroken(id);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (broken)
          Row(key: const ValueKey('splitBroken'), children: [
            Icon(Icons.warning_amber_outlined, size: 16, color: context.c.bad),
            const SizedBox(width: 6),
            Expanded(child: Text("Split doesn't add up", style: TextStyle(fontSize: BwType.metaSize, color: context.c.bad))),
          ])
        else if (n > 0)
          Muted('Split in $n parts', key: const ValueKey('splitInfo')),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              key: const ValueKey('splitOpen'),
              style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
              onPressed: _openSplit,
              child: Text(broken ? 'Fix split' : (n > 0 ? 'Edit split' : 'Split…'))),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = row.tx;
    final manual = t.source == 'manual';
    final bill = widget.wc.billForTx(t.id);
    final src = switch (t.source) { 'pbz' => 'PBZ', 'revolut' => 'Revolut', _ => 'Added by you' };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(merchantName(t)),
      const SizedBox(height: 6),
      Text(money(t.amount, t.currency, decimals: 2, signed: true),
          textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500)),
      if (widget.wc.shown(row) case final c when c.originalAmount != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
              'Counts as ${money(c.amount, c.tx.currency, decimals: 2, signed: true)} at ${rateText(widget.wc.settings.fxRates[t.currency]!.rate)}',
              key: const ValueKey('txCounted'),
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
        ),
      const SizedBox(height: 6),
      const DoubleRule(),
      const SizedBox(height: 6),
      Muted('${longDateOrRaw(t.date)} · $src${t.bankType.isNotEmpty ? ' · ${t.bankType}' : ''}'),
      if (matchedBank != null)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(key: const ValueKey('matchedMark'), children: [
              Icon(Icons.link, size: 16, color: context.c.good),
              const SizedBox(width: 6),
              Expanded(
                  child: Text('Matched with your bank · ${longDateOrRaw(matchedBank!.date)}',
                      style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2))),
            ])),
      if (matchedEntry != null)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(key: const ValueKey('matchedMark'), children: [
              Icon(Icons.link, size: 16, color: context.c.good),
              const SizedBox(width: 6),
              Expanded(
                  child: Text('Matched with your bank · you added it on ${longDateOrRaw(matchedEntry!.date)}',
                      style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2))),
            ])),
      if (!manual)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(t.description, style: const TextStyle(fontSize: BwType.metaSize))),
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
      AttachmentsSection(wc: widget.wc, txId: t.id, chooser: widget.chooser),
      const SizedBox(height: 14),
      MainTagPicker(
        dropdown: true,
        table: widget.wc.categoryTable,
        ids: mainIds,
        selected: cat,
        onPick: (v) => setState(() => cat = v),
      ),
      if (!manual)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: always,
          onChanged: (v) => setState(() => always = v),
          title: Text('Always use this main tag for ${merchantName(t)}', style: const TextStyle(fontSize: BwType.bodySize)),
        ),
      if (tagPayee(t) != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              key: const ValueKey('makeRule'),
              style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
              onPressed: () => openRuleForm(context, widget.wc, payee: tagPayee(t), category: cat, from: t),
              child: const Text('Make a rule…')),
        ),
      const SizedBox(height: 8),
      ExtraTagsEditor(
          wc: widget.wc,
          tx: row,
          payeeRule: !manual && tagPayee(t) != null,
          onChanged: (on, rule) {
            tagOn = on;
            tagRule = rule;
          }),
      if (canSplit) _splitSection(context),
      const SizedBox(height: 8),
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [
        FilledButton(
          onPressed: saving
              ? null
              : () async {
                  saving = true;
                  widget.wc.ruleOffer = null; // an offer left by an earlier sheet is stale
                  // Only an owner's pick is written: the category shown is the resolved one, so an untouched Save must not overwrite a
                  // deleted custom id (or the merchant rule that points at it).
                  if (cat != row.category) widget.wc.setCategory(t, cat, always: always && !manual);
                  // The tag draft: only what differs is written; a tag deleted meanwhile is counted and the toast says so.
                  if (tagOn != null) await widget.wc.saveTagChanges(row, on: tagOn!, rule: tagRule ?? const {});
                  if (context.mounted) Navigator.pop(context, 'saved');
                },
          child: const Text('Save'),
        ),
        if (manual)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: context.c.bad),
            onPressed: () {
              widget.wc.deleteTransaction(t);
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
  late final target = TextEditingController(text: centsToFieldText(g?.target ?? widget.target ?? 0, blankZero: true));
  late final monthly = TextEditingController(text: centsToFieldText(g?.monthly ?? 5000, blankZero: true));
  late final saved = TextEditingController(text: centsToFieldText(g?.saved ?? 0, blankZero: true));
  final add = TextEditingController();
  String? error;

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
            child: MoneyField(
                controller: target,
                onChanged: upd,
                decoration: InputDecoration(labelText: 'Target', suffixText: currencySymbol(widget.wc.currency)))),
        const SizedBox(width: 10),
        Expanded(
            child: MoneyField(
                controller: monthly,
                onChanged: upd,
                decoration: InputDecoration(labelText: 'Each month', suffixText: currencySymbol(widget.wc.currency)))),
      ]),
      const SizedBox(height: 10),
      MoneyField(
          controller: saved,
          onChanged: upd,
          decoration: InputDecoration(labelText: 'Put aside so far', suffixText: currencySymbol(widget.wc.currency))),
      if (g != null) ...[
        const SizedBox(height: 10),
        MoneyField(
            controller: add,
            onChanged: upd,
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
