import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show CsvMapping;

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/currency_picker.dart';
import '../widgets/sheets.dart';
import 'account_form.dart';
import 'currencies_panel.dart' show openFxSheet;
import 'currency_offer.dart' show switchWalletCurrency;

export 'account_form.dart' show AccountFormSheet;

/// "Cash" or the bank's name for an account `source` (`null` = cash).
String accountTypeLabel(String? source, {Map<String, CsvMapping> csvMappings = const {}}) =>
    accountSourceLabel(source, csvMappings: csvMappings);

/// The readable text of an [ArgumentError] from core.
String _problem(Object e) => e is ArgumentError ? e.message.toString() : 'Could not save. Try again.';

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
      _WalletCurrency(wc),
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

/// The wallet's currency: shown as a field, a tap opens the picker. Existing payments keep their own currency (said plainly).
class _WalletCurrency extends StatelessWidget {
  final WalletController wc;
  const _WalletCurrency(this.wc);

  void _set(BuildContext context, String code) {
    if (code == wc.currency) return;
    logNav('accounts.walletCurrency');
    switchWalletCurrency(context, wc, code);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CurrencyField(
              key: const ValueKey('walletCurrency'),
              wc: wc,
              value: wc.currency,
              label: 'Wallet currency',
              choice: CurrencyChoice.fiat,
              onChanged: (c) => _set(context, c)),
          const SizedBox(height: 4),
          const Muted('Totals, budgets and the plan are in this currency. Payments you already have keep their own currency.',
              key: ValueKey('walletCurrencyNote')),
        ]),
      );
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
        Text(
            [
              if (a.source != null) accountTypeLabel(a.source, csvMappings: wc.settings.csvMappings) else accountKindLabel(a.kind),
              if (a.institution != null) a.institution!,
              a.currency,
              'as of ${shortDateOrRaw(asOf)}',
            ].join(' · '),
            style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
        if (a.currency != wc.currency) _HomeValue(wc, b),
        if (!a.isCash && b.duplicateOf == null) _CheckLine(wc, a),
        const SizedBox(height: 4),
        Wrap(spacing: 8, runSpacing: 4, children: [
          TextButton(key: ValueKey('accountEdit:${a.id}'), onPressed: () => openEditAccount(context, wc, a), child: const Text('Edit')),
          if (!a.isCash && b.duplicateOf == null)
            TextButton(
                key: ValueKey('accountCheck:${a.id}'),
                onPressed: () => askBankBalance(
                    context,
                    wc,
                    BankQuestion(
                        accountId: a.id, name: a.name, currency: a.currency, date: wc.today(), appCents: wc.appBalanceOn(a.id, wc.today())),
                    fromImport: false),
                child: const Text('Check balance')),
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

/// A foreign account's balance in the wallet currency ("about 1,200 €" and where the rate comes from: "ECB 31 Oct" or "your rate"), or
/// "Rate missing" with "Set a rate" while a part of it has none (never a partial sum).
class _HomeValue extends StatelessWidget {
  final WalletController wc;
  final AccountBalance b;
  const _HomeValue(this.wc, this.b);

  @override
  Widget build(BuildContext context) {
    final a = b.account, v = wc.accountHomeValue(b);
    final style = TextStyle(fontSize: BwType.metaSize, color: context.c.ink2);
    if (v != null) {
      final src = wc.accountRateSource(b);
      return Text('About ${moneyExact(v, wc.currency)}${src == null ? '' : ' · $src'}', key: ValueKey('accountHome:${a.id}'), style: style);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(key: ValueKey('accountRateMissing:${a.id}'), children: [
        Icon(Icons.block, size: 14, color: context.c.muted),
        const SizedBox(width: 6),
        Expanded(child: Text('Rate missing: not counted in ${wc.currency}', style: style)),
      ]),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
            key: ValueKey('accountSetRate:${a.id}'),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: Text('Set a rate for ${a.currency}'),
            onPressed: () => openFxSheet(context, wc, a.currency)),
      ),
    ]);
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

Future<void> openEditAccount(BuildContext context, WalletController wc, Account a) async {
  logNav('accounts.edit');
  await showSheet<bool>(context, AccountFormSheet(wc: wc, account: a));
}

Future<void> openCorrectBalance(BuildContext context, WalletController wc, AccountBalance b) async {
  logNav('accounts.correctOpen');
  await showSheet<bool>(context, CorrectBalanceSheet(wc: wc, balance: b));
}

/// "The real balance today is…": the balance counts from today on. Pops `true` once saved.
class CorrectBalanceSheet extends StatefulWidget {
  final WalletController wc;
  final AccountBalance balance;

  /// The number to start from (the bank's, after a check that was off) and the day it was true on; default: the app's balance, today.
  final int? prefill;
  final String? date;
  const CorrectBalanceSheet({super.key, required this.wc, required this.balance, this.prefill, this.date});
  @override
  State<CorrectBalanceSheet> createState() => _CorrectBalanceSheetState();
}

class _CorrectBalanceSheetState extends State<CorrectBalanceSheet> {
  late final int _start = widget.prefill ?? widget.balance.balance;
  late final _amount = TextEditingController(text: centsToFieldText(_start.abs(), currency: widget.balance.account.currency));
  late bool _negative = _start < 0;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cents = balanceCentsOf(_amount.text, negative: _negative, currency: widget.balance.account.currency);
    if (cents == null) {
      setState(() => _error = invalidAmountMessage);
      return;
    }
    try {
      await widget.wc.correctAccountBalance(widget.balance.account.id, balance: cents, date: widget.date ?? widget.wc.today());
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
      Muted(widget.date == null ? 'The real balance today is…' : 'The real balance on ${longDateOrRaw(widget.date!)} was…'),
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
      BelowZeroBox(value: _negative, onChanged: (v) => setState(() => _negative = v)),
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('accountCorrectSave'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: const Text('Set balance')),
      const SizedBox(height: 8),
      Muted(widget.date == null ? 'Rows after today are added to this number.' : 'Rows after that day are added to this number.'),
    ]);
  }
}

/// "Checked 12 Oct: matches the bank" / "off by 12 €" under an account (Q5). Says so when it was never checked.
class _CheckLine extends StatelessWidget {
  final WalletController wc;
  final Account a;
  const _CheckLine(this.wc, this.a);
  @override
  Widget build(BuildContext context) {
    final last = wc.lastBankCheckOf(a.id);
    final style = TextStyle(fontSize: BwType.metaSize, color: context.c.ink2);
    if (last == null) return Text('Not checked against the bank yet', key: ValueKey('accountChecked:${a.id}'), style: style);
    final diff = last.bankCents - wc.appBalanceOn(a.id, last.date);
    return Text('Checked ${shortDateOrRaw(last.date)}: ${diff == 0 ? 'matches the bank' : 'off by ${moneyExact(diff.abs(), a.currency)}'}',
        key: ValueKey('accountChecked:${a.id}'), style: diff == 0 ? style : style.copyWith(color: context.c.bad));
  }
}

/// Asks "What did the bank app show…" for [q] (after an import, or from Settings › Accounts). Returns once the owner answered or skipped.
Future<void> askBankBalance(BuildContext context, WalletController wc, BankQuestion q, {required bool fromImport}) async {
  logNav('bankCheck.open', {'import': fromImport});
  await showSheet<bool>(context, BankCheckSheet(wc: wc, q: q, fromImport: fromImport));
}

/// The bank question: the file's newest date, the app's own balance prefilled, **Matches** (one tap), a Below zero switch and Skip.
/// The answer is stored as a check ([WalletController.recordBalanceCheck]); a number that is off shows the difference and offers
/// Correct balance, never corrects by itself.
class BankCheckSheet extends StatefulWidget {
  final WalletController wc;
  final BankQuestion q;
  final bool fromImport;
  const BankCheckSheet({super.key, required this.wc, required this.q, required this.fromImport});
  @override
  State<BankCheckSheet> createState() => _BankCheckSheetState();
}

class _BankCheckSheetState extends State<BankCheckSheet> {
  late final _amount = TextEditingController(text: centsToFieldText(widget.q.appCents.abs(), currency: widget.q.currency));
  late bool _negative = widget.q.appCents < 0;
  String? _error;
  BalanceCheck? _result;
  int _bank = 0;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _record(int bankCents) {
    try {
      final c = widget.wc.recordBalanceCheck(widget.q.accountId, date: widget.q.date, bankCents: bankCents);
      if (c.matches) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _result = c;
          _bank = bankCents;
        });
      }
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
  }

  void _save() {
    final cents = balanceCentsOf(_amount.text, negative: _negative, currency: widget.q.currency);
    if (cents == null) {
      setState(() => _error = invalidAmountMessage);
      return;
    }
    _record(cents);
  }

  Future<void> _correct() async {
    final b = widget.wc.accountBalanceList().where((x) => x.account.id == widget.q.accountId).firstOrNull;
    if (b == null) return;
    final done = await showSheet<bool>(context, CorrectBalanceSheet(wc: widget.wc, balance: b, prefill: _bank, date: widget.q.date));
    if (done == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.q;
    final r = _result;
    if (r != null) {
      return Column(key: const ValueKey('bankCheckOff'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Heading(q.name),
        const SizedBox(height: 8),
        StatusLabel(good: false, text: 'Off by ${moneyExact(r.diff.abs(), q.currency)}. See the rows since ${shortDateOrRaw(r.since)}.'),
        const SizedBox(height: 6),
        const Muted('Payments may still be pending at the bank. Nothing was changed.'),
        const SizedBox(height: 14),
        FilledButton(
            key: const ValueKey('bankCheckCorrect'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
            onPressed: _correct,
            child: const Text('Correct balance')),
        const SizedBox(height: 8),
        TextButton(
            key: const ValueKey('bankCheckLeave'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave it')),
      ]);
    }
    return Column(key: const ValueKey('bankCheckSheet'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(q.name),
      const SizedBox(height: 6),
      Muted(widget.fromImport
          ? 'What did the bank app show when you downloaded this file? Newest row: ${longDateOrRaw(q.date)}.'
          : 'What does the bank app show now?'),
      const SizedBox(height: 12),
      MoneyField(
        fieldKey: const ValueKey('bankCheckAmount'),
        controller: _amount,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        style: numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500),
        decoration: InputDecoration(labelText: 'Bank balance', suffixText: currencySymbol(q.currency), errorText: _error, errorMaxLines: 3),
      ),
      BelowZeroBox(value: _negative, onChanged: (v) => setState(() => _negative = v)),
      const SizedBox(height: 6),
      Muted('The app counts ${moneyExact(q.appCents, q.currency)}.'),
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('bankCheckMatches'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: () => _record(q.appCents),
          child: const Text('Matches')),
      const SizedBox(height: 8),
      OutlinedButton(
          key: const ValueKey('bankCheckSave'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: const Text('Save this number')),
      const SizedBox(height: 8),
      TextButton(
          key: const ValueKey('bankCheckSkip'),
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
          onPressed: () {
            logNav('bankCheck.skip');
            Navigator.pop(context, false);
          },
          child: const Text('Skip')),
    ]);
  }
}
