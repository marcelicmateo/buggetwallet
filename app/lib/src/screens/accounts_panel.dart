import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show bankProfiles;

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// The currencies the pickers offer (the wallet's own is added when it is another one).
const _currencies = ['EUR', 'USD', 'GBP', 'CHF'];

/// "Cash" or the bank's name for an account `source` (`null` = cash).
String accountTypeLabel(String? source) {
  if (source == null) return 'Cash';
  for (final p in bankProfiles) {
    if (p.id == source) return p.label;
  }
  return source;
}

/// The readable text of an [ArgumentError] from core.
String _problem(Object e) => e is ArgumentError ? e.message.toString() : 'Could not save. Try again.';

/// An amount typed in a balance field: `null` when it is not a number; [negative] turns it below zero.
int? _balanceCents(String text, {required bool negative}) {
  final v = parseMoney(text);
  return v == null ? null : (negative ? -v : v);
}

/// Plan › Accounts: what is held in each bank and in cash, a balance per account (exact cents, its own currency), a total per
/// currency (never mixed), and add / rename / correct / delete (with Undo).
class AccountsPanel extends StatelessWidget {
  final WalletController wc;
  const AccountsPanel({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final balances = wc.accountBalanceList();
    final totals = wc.heldTotals();
    final byId = {for (final b in balances) b.account.id: b.account};
    return Panel(children: [
      SectionHead('Accounts',
          trailing: TextButton.icon(
              key: const ValueKey('accountAdd'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              onPressed: () => openAddAccount(context, wc))),
      Explainer(wc, 'accounts',
          'How much you hold in each bank and in cash. A balance is the amount you gave plus the rows imported or added after its date.'),
      if (balances.isEmpty)
        const EmptyNote('No accounts yet. Add one to see how much you hold.')
      else
        Rows(children: [
          for (final b in balances)
            b.duplicateOf != null ? _DuplicateRow(wc, b, byId[b.duplicateOf]?.name ?? 'another account') : _AccountRow(wc, b),
        ]),
      if (totals.isNotEmpty)
        TotalRule(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (final e in totals.entries)
                LineItem('Total ${e.key}', moneyExact(e.value, e.key), key: ValueKey('accountTotal:${e.key}'), bold: true),
            ])),
    ]);
  }
}

class _AccountRow extends StatelessWidget {
  final WalletController wc;
  final AccountBalance b;
  const _AccountRow(this.wc, this.b);

  @override
  Widget build(BuildContext context) {
    final a = b.account;
    final asOf = b.lastRowDate ?? a.openingDate;
    return Padding(
      key: ValueKey('account:${a.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SplitRow(
          start: Text(a.name, style: const TextStyle(fontWeight: FontWeight.w500)),
          end: MoneyText(moneyExact(b.balance, a.currency),
              textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500, color: b.balance < 0 ? context.c.bad : null)),
        ),
        Text('${accountTypeLabel(a.source)} · ${a.currency} · as of ${shortDateOrRaw(asOf)}',
            style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 4, children: [
          TextButton(
              key: ValueKey('accountRename:${a.id}'), onPressed: () => openRenameAccount(context, wc, a), child: const Text('Rename')),
          TextButton(
              key: ValueKey('accountCorrect:${a.id}'),
              onPressed: () => openCorrectBalance(context, wc, b),
              child: const Text('Correct balance')),
          TextButton(
              key: ValueKey('accountDelete:${a.id}'), onPressed: () => deleteAccountWithUndo(context, wc, a), child: const Text('Delete')),
        ]),
      ]),
    );
  }
}

/// An account that only exists because two devices each added it before a sync: it is not counted (core's `duplicateOf`).
class _DuplicateRow extends StatelessWidget {
  final WalletController wc;
  final AccountBalance b;
  final String ofName;
  const _DuplicateRow(this.wc, this.b, this.ofName);

  @override
  Widget build(BuildContext context) {
    final a = b.account;
    return Padding(
      key: ValueKey('accountDuplicate:${a.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(Icons.content_copy_outlined, size: 18, color: context.c.muted),
        const SizedBox(width: 8),
        Expanded(child: Muted('${a.name}: duplicate of $ofName, not counted', size: BwType.bodySize)),
        TextButton(
            key: ValueKey('accountDelete:${a.id}'),
            onPressed: () => deleteAccountWithUndo(context, wc, a, duplicate: true),
            child: const Text('Delete')),
      ]),
    );
  }
}

/// Deletes [a] and offers Undo in the toast (the Stage I pattern); Undo says why when another account took its place. A sync
/// duplicate ([duplicate]) is only removed, with no Undo (it was never counted). The messenger is taken before the first await: the
/// row may be gone (a list that shrank) when Undo fails, and its context is then unmounted.
Future<void> deleteAccountWithUndo(BuildContext context, WalletController wc, Account a, {bool duplicate = false}) async {
  logNav('accounts.delete');
  final messenger = ScaffoldMessenger.of(context);
  final wide = layoutOf(context) != LayoutSize.compact, accessible = MediaQuery.accessibleNavigationOf(context);
  void say(String m, {String? label, VoidCallback? action}) =>
      toastOn(messenger, m, wide: wide, accessible: accessible, actionLabel: label, onAction: action);
  try {
    await wc.deleteAccount(a.id);
  } catch (e, st) {
    logError(Logger('bw.accounts'), 'accounts.delete.failed', e, st);
    say(_problem(e));
    return;
  }
  if (duplicate) {
    say('Removed');
    return;
  }
  say('Account removed', label: 'Undo', action: () async {
    try {
      await wc.undeleteAccount(a.id);
    } catch (e, st) {
      logError(Logger('bw.accounts'), 'accounts.undelete.failed', e, st);
      say(_problem(e));
    }
  });
}

Future<void> openAddAccount(BuildContext context, WalletController wc) async {
  logNav('accounts.add');
  await showSheet<bool>(context, AccountFormSheet(wc: wc));
}

Future<void> openRenameAccount(BuildContext context, WalletController wc, Account a) async {
  logNav('accounts.rename');
  await showSheet<bool>(context, RenameAccountSheet(wc: wc, account: a));
}

Future<void> openCorrectBalance(BuildContext context, WalletController wc, AccountBalance b) async {
  logNav('accounts.correctOpen');
  await showSheet<bool>(context, CorrectBalanceSheet(wc: wc, balance: b));
}

/// "Below zero" switch next to a balance field (an overdraft); the field itself takes the size only.
class _BelowZero extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _BelowZero({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => CheckboxListTile(
        key: const ValueKey('accountNegative'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        dense: true,
        value: value,
        onChanged: (v) => onChanged(v ?? false),
        title: const Text('Below zero (overdrawn)'),
      );
}

/// The Add account sheet: type (Cash or a bank), name, currency, balance and the date it was true. Pops `true` once saved.
class AccountFormSheet extends StatefulWidget {
  final WalletController wc;
  const AccountFormSheet({super.key, required this.wc});
  @override
  State<AccountFormSheet> createState() => _AccountFormSheetState();
}

class _AccountFormSheetState extends State<AccountFormSheet> {
  final _name = TextEditingController(text: 'Cash');
  final _amount = TextEditingController();
  String? _source; // null = cash
  late String _currency = widget.wc.currency;
  late String _date = widget.wc.today();
  bool _negative = false, _nameEdited = false;
  String? _nameError, _amountError, _dateError, _error;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cents = _balanceCents(_amount.text, negative: _negative);
    if (cents == null) {
      setState(() {
        _amountError = invalidAmountMessage;
        _nameError = _dateError = _error = null;
      });
      return;
    }
    try {
      await widget.wc.addAccount(name: _name.text, source: _source, currency: _currency, opening: cents, openingDate: _date);
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      final m = e.message.toString();
      setState(() {
        _nameError = _amountError = _dateError = _error = null;
        if (m.contains('name')) {
          _nameError = m;
        } else if (m.contains('balance')) {
          _amountError = m;
        } else if (m.toLowerCase().contains('date')) {
          _dateError = m;
        } else {
          _error = m;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final currencies = [..._currencies, if (!_currencies.contains(wc.currency)) wc.currency];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Add an account'),
      const SizedBox(height: 12),
      DropdownButtonFormField<String?>(
        key: const ValueKey('accountType'),
        isExpanded: true,
        initialValue: _source,
        decoration: const InputDecoration(labelText: 'Type'),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('Cash')),
          for (final p in bankProfiles) DropdownMenuItem<String?>(value: p.id, child: Text(p.label)),
        ],
        onChanged: (v) => setState(() {
          _source = v;
          if (!_nameEdited) _name.text = accountTypeLabel(v);
        }),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('accountName'),
        controller: _name,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {
          _nameEdited = true;
          _nameError = null;
        }),
        decoration: InputDecoration(labelText: 'Name', errorText: _nameError, errorMaxLines: 3),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: const ValueKey('accountCurrency'),
        isExpanded: true,
        initialValue: _currency,
        decoration: const InputDecoration(labelText: 'Currency'),
        items: [for (final c in currencies) DropdownMenuItem(value: c, child: Text(c))],
        onChanged: (v) => setState(() => _currency = v ?? _currency),
      ),
      const SizedBox(height: 12),
      MoneyField(
        fieldKey: const ValueKey('accountOpening'),
        controller: _amount,
        onChanged: (_) {
          if (_amountError != null) setState(() => _amountError = null);
        },
        style: numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500),
        decoration: InputDecoration(
            labelText: 'Balance', suffixText: currencySymbol(_currency), hintText: amountHint, errorText: _amountError, errorMaxLines: 3),
      ),
      _BelowZero(value: _negative, onChanged: (v) => setState(() => _negative = v)),
      DateField(
        key: const ValueKey('accountDate'),
        label: 'Balance on',
        value: _date,
        onPick: () async {
          final today = wc.today();
          final d = await showDatePicker(
              context: context, initialDate: parseIso(_date), firstDate: parseIso(addDays(today, -3650)), lastDate: parseIso(today));
          if (d != null) {
            setState(() {
              _date = isoDate(d);
              _dateError = null;
            });
          }
        },
      ),
      if (_dateError != null) ...[
        const SizedBox(height: 6),
        StatusLabel(key: const ValueKey('accountDateError'), good: false, text: _dateError!)
      ],
      if (_error != null) ...[const SizedBox(height: 10), StatusLabel(key: const ValueKey('accountError'), good: false, text: _error!)],
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('accountSave'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: const Text('Add account')),
      const SizedBox(height: 8),
      const Muted('Rows after this date are added to the balance. Cash counts only the expenses you add by hand.'),
    ]);
  }
}

/// Changes an account's name. Pops `true` once saved.
class RenameAccountSheet extends StatefulWidget {
  final WalletController wc;
  final Account account;
  const RenameAccountSheet({super.key, required this.wc, required this.account});
  @override
  State<RenameAccountSheet> createState() => _RenameAccountSheetState();
}

class _RenameAccountSheetState extends State<RenameAccountSheet> {
  late final _name = TextEditingController(text: widget.account.name);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await widget.wc.renameAccount(widget.account.id, _name.text);
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Heading('Rename account'),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('accountName'),
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          decoration: InputDecoration(labelText: 'Name', errorText: _error, errorMaxLines: 3),
        ),
        const SizedBox(height: 14),
        FilledButton(
            key: const ValueKey('accountSave'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: _save,
            child: const Text('Save')),
      ]);
}

/// "The real balance today is…": the balance counts from today on. Pops `true` once saved.
class CorrectBalanceSheet extends StatefulWidget {
  final WalletController wc;
  final AccountBalance balance;
  const CorrectBalanceSheet({super.key, required this.wc, required this.balance});
  @override
  State<CorrectBalanceSheet> createState() => _CorrectBalanceSheetState();
}

class _CorrectBalanceSheetState extends State<CorrectBalanceSheet> {
  late final _amount = TextEditingController(text: centsToFieldText(widget.balance.balance.abs()));
  late bool _negative = widget.balance.balance < 0;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cents = _balanceCents(_amount.text, negative: _negative);
    if (cents == null) {
      setState(() => _error = invalidAmountMessage);
      return;
    }
    try {
      await widget.wc.correctAccountBalance(widget.balance.account.id, balance: cents, date: widget.wc.today());
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.balance.account;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(a.name),
      const SizedBox(height: 6),
      const Muted('The real balance today is…'),
      const SizedBox(height: 12),
      MoneyField(
        fieldKey: const ValueKey('accountCorrectAmount'),
        controller: _amount,
        autofocus: true,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        style: numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500),
        decoration: InputDecoration(labelText: 'Balance', suffixText: currencySymbol(a.currency), errorText: _error, errorMaxLines: 3),
      ),
      _BelowZero(value: _negative, onChanged: (v) => setState(() => _negative = v)),
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('accountCorrectSave'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: const Text('Set balance')),
      const SizedBox(height: 8),
      const Muted('Rows after today are added to this number.'),
    ]);
  }
}
