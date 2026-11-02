// The account form (UX-A): kind first, then only the fields that kind has. One form adds an account and edits one (kind, name,
// institution, import format; a coin's rate). The balance of an existing account is changed with "Correct balance", the currency
// never changes.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show bankProfiles, csvSourcePrefix;

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/currency_picker.dart';
import '../widgets/field_editor.dart';
import 'accounts_panel.dart' show accountTypeLabel;

/// The plain name of an account kind, as the form and the rows say it.
String accountKindLabel(AccountKind k) => switch (k) {
      AccountKind.cash => 'Cash',
      AccountKind.bank => 'Bank',
      AccountKind.card => 'Card / e-money',
      AccountKind.savings => 'Savings',
      AccountKind.investment => 'Investment',
      AccountKind.crypto => 'Crypto',
      AccountKind.other => 'Other',
    };

IconData accountKindIcon(AccountKind k) => switch (k) {
      AccountKind.cash => Icons.payments_outlined,
      AccountKind.bank => Icons.account_balance_outlined,
      AccountKind.card => Icons.credit_card_outlined,
      AccountKind.savings => Icons.savings_outlined,
      AccountKind.investment => Icons.trending_up,
      AccountKind.crypto => Icons.currency_bitcoin,
      AccountKind.other => Icons.account_balance_wallet_outlined,
    };

/// An amount typed in a balance field, in stored units of [currency] (the wallet's when omitted): `null` when it is not a number;
/// [negative] turns it below zero.
int? balanceCentsOf(String text, {required bool negative, String? currency}) {
  final v = parseMoney(text, currency: currency);
  return v == null ? null : (negative ? -v : v);
}

/// "Below zero" switch next to a balance field (an overdraft); the field itself takes the size only.
class BelowZeroBox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const BelowZeroBox({super.key, required this.value, required this.onChanged});
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

/// Add an account, or change [account] (edit mode: no balance and no currency, those have their own buttons). Pops `true` once saved.
class AccountFormSheet extends StatefulWidget {
  final WalletController wc;

  /// The account to change; null adds a new one.
  final Account? account;

  /// UX-ACC: the question "Which account is this?" asked for a new account: a bank account of the file's bank and currency (both
  /// fixed) that gets the export account's match key. The name is the owner's. Save pops a [NewAccountDraft] (nothing is written; the
  /// controller adds the account when the file is imported).
  final ImportAccountQuestion? forImport;
  const AccountFormSheet({super.key, required this.wc, this.account, this.forImport});
  @override
  State<AccountFormSheet> createState() => _AccountFormSheetState();
}

class _AccountFormSheetState extends State<AccountFormSheet> {
  Account? get _a => widget.account;
  late AccountKind _kind = _a?.kind ?? (widget.forImport == null ? AccountKind.cash : AccountKind.bank);

  /// The text columns being edited (a draft; Save writes them): name and institution.
  late final Map<Col, String?> _draft = {
    AccountCols.name: _a?.name ??
        (widget.forImport == null
            ? accountKindLabel(_kind)
            : accountTypeLabel(widget.forImport!.source, csvMappings: widget.wc.settings.csvMappings)),
    AccountCols.institution: _a?.institution ?? ''
  };
  final _amount = TextEditingController();
  late final _rate = TextEditingController(text: _initialRate());
  late String? _source = _a?.source ?? widget.forImport?.source;
  late String _currency = _a?.currency ?? widget.forImport?.currency ?? widget.wc.currency;
  late String _date = _initialDate();
  late bool _nameEdited = _a != null;
  bool _negative = false;

  /// The owner saw "N payments will no longer count" and pressed Save again.
  bool _confirmedDrop = false;
  String? _nameError, _amountError, _dateError, _rateError, _error;

  bool get _editing => _a != null;
  bool get _isCrypto => _kind == AccountKind.crypto;

  /// The balance date of a new account: today; for a file's account the day before its first row in the file, so the file's payments
  /// (core counts rows dated after it) are in the balance.
  String _initialDate() {
    final q = widget.forImport;
    return q is FileAccountQuestion ? addDays(q.firstDate, -1) : widget.wc.today();
  }

  String _initialRate() {
    final r = widget.wc.settings.fxRates[_a?.currency ?? ''];
    return r == null ? '' : rateText(r.rate);
  }

  @override
  void dispose() {
    _amount.dispose();
    _rate.dispose();
    super.dispose();
  }

  /// How many payments count in the balance now but would not after this change (kind or import format): cash counts the rows added
  /// by hand, a bank, card or savings account with a format its file's rows, any other none. 0 when nothing is lost.
  int _lostRows() {
    final a = _a;
    if (a == null) return 0;
    final before = a.countsRows;
    final rowsChange = a.isCash != (_kind == AccountKind.cash) || _source != a.source;
    if (!before || !rowsChange) return 0;
    final b = widget.wc.accountBalanceList().where((x) => x.account.id == a.id).firstOrNull;
    return b?.rowsCounted ?? 0;
  }

  void _pickKind(AccountKind k) {
    if (k == _kind) return;
    if (widget.forImport != null && !k.takesSource) {
      setState(() => _error = 'A file\'s account is a bank, card or savings account.');
      return;
    }
    _confirmedDrop = false;
    setState(() {
      _kind = k;
      if (!_nameEdited) _draft[AccountCols.name] = accountKindLabel(k);
      if (!k.takesSource) _source = null;
      if (!_editing) {
        final coin = currencyInfo(_currency)?.crypto ?? false;
        if (k == AccountKind.crypto && !coin) _currency = 'BTC';
        if (k != AccountKind.crypto && coin) _currency = widget.wc.currency;
      }
      _error = _nameError = null;
    });
  }

  /// Sets the typed rate of a coin account when it is new or changed. Returns false after saying what is wrong.
  bool _rateOk() {
    if (!_isCrypto || _rate.text.trim().isEmpty) return true;
    final r = parseFxRate(_rate.text);
    if (r == null || r < FxRate.minRate || r > FxRate.maxRateOf(_currency)) {
      setState(() => _rateError = 'Enter a rate, like 62000${numberStyle.decimal}00.');
      return false;
    }
    return true;
  }

  void _saveRate() {
    if (!_isCrypto || _rate.text.trim().isEmpty) return;
    final r = parseFxRate(_rate.text)!;
    if (widget.wc.settings.fxRates[_currency]?.rate != r) widget.wc.setFxRate(_currency, r);
  }

  void _say(ArgumentError e) {
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

  Future<void> _save() async {
    final wc = widget.wc;
    final inst = _kind.takesSource || _isCrypto ? _draft[AccountCols.institution] ?? '' : '';
    if (!_rateOk()) return;
    if (_editing) {
      final a = _a!;
      final lost = _lostRows();
      if (lost > 0 && !_confirmedDrop) {
        setState(() => _confirmedDrop = true); // the note under the form asks; the next Save goes through
        return;
      }
      try {
        final srcChanged = _source != a.source;
        await wc.updateAccount(a.id,
            name: _draft[AccountCols.name] ?? '',
            kind: _kind != a.kind ? _kind : null,
            institution: inst.trim() == (a.institution ?? '') ? null : inst,
            source: srcChanged && _source != null ? _source : null,
            clearSource: srcChanged && _source == null);
        _saveRate();
        if (mounted) Navigator.pop(context, true);
      } on ArgumentError catch (e) {
        _say(e);
      }
      return;
    }
    final cents = balanceCentsOf(_amount.text, negative: _negative, currency: _currency);
    if (cents == null) {
      setState(() {
        _amountError = invalidAmountMessage;
        _nameError = _dateError = _error = null;
      });
      return;
    }
    if (widget.forImport != null) {
      // Checked here as core would: the account is added later, when the file is imported.
      final name = (_draft[AccountCols.name] ?? '').trim();
      if (name.isEmpty || name.runes.length > Account.maxName) {
        setState(() {
          _nameError = name.isEmpty ? 'Give the account a name.' : 'The account name is limited to ${Account.maxName} characters.';
          _amountError = _dateError = _error = null;
        });
        return;
      }
      if (cents.abs() > WalletSettings.maxAmount) {
        setState(() {
          _amountError = 'The balance is over the allowed amount.';
          _nameError = _dateError = _error = null;
        });
        return;
      }
      if (_date.compareTo(wc.today()) > 0) {
        setState(() {
          _dateError = 'The date cannot be in the future.';
          _nameError = _amountError = _error = null;
        });
        return;
      }
      Navigator.pop(
          context,
          NewAccountDraft(
              name: name,
              kind: _kind,
              institution: inst.trim().isEmpty ? null : inst.trim(),
              source: _source,
              currency: _currency,
              opening: cents,
              openingDate: _date));
      return;
    }
    try {
      await wc.addAccount(
          name: _draft[AccountCols.name] ?? '',
          kind: _kind,
          source: _source,
          institution: inst,
          currency: _currency,
          opening: cents,
          openingDate: _date);
      _saveRate();
      if (mounted) Navigator.pop(context, true);
    } on ArgumentError catch (e) {
      _say(e);
    }
  }

  /// The columns this kind asks for, in order (the currency, balance and date follow below, the rate for a coin). A new text column of the
  /// account is one more entry here and one case in [_field].
  List<Col> _fieldsOf(AccountKind k) => [
        AccountCols.name,
        if (k.takesSource || k == AccountKind.crypto) AccountCols.institution,
        if (k.takesSource && widget.forImport == null) AccountCols.source,
      ];

  Widget _field(Col c) {
    final wc = widget.wc, csv = wc.settings.csvMappings;
    if (c == AccountCols.source) {
      return FieldEditor(c, id: 'accountSource', label: 'Import format', value: _source, today: wc.today(), options: [
        const FieldOption(null, 'None: I set the balance'),
        for (final p in bankProfiles) FieldOption(p.id, p.label),
        for (final e in csv.entries) FieldOption('$csvSourcePrefix${e.key}', e.value.name, key: ValueKey('accountSource:csv:${e.key}')),
      ], onSave: (v) {
        setState(() {
          _source = v as String?;
          _confirmedDrop = false;
          if (!_nameEdited && v != null) _draft[AccountCols.name] = accountTypeLabel(v, csvMappings: csv);
        });
        return null;
      });
    }
    final name = c == AccountCols.name;
    return FieldEditor(c,
        key: ValueKey(c),
        id: name ? 'accountName' : 'accountInstitution',
        label: name ? null : (_isCrypto ? 'Exchange or wallet (optional)' : 'Bank or provider (optional)'),
        value: _draft[c],
        today: wc.today(),
        autoSave: true,
        capitalize: name ? TextCapitalization.sentences : TextCapitalization.words,
        errorText: name ? _nameError : null, onSave: (v) {
      setState(() {
        _draft[c] = v as String?;
        if (name) {
          _nameEdited = true;
          _nameError = null;
        }
      });
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(_editing ? 'Edit account' : (widget.forImport == null ? 'Add an account' : 'New account'),
          key: const ValueKey('accountFormHeading')),
      const SizedBox(height: 12),
      FieldEditor(AccountCols.kind,
          id: 'accountKind',
          label: 'What is it?',
          value: _kind,
          today: wc.today(),
          labelOf: (k) => accountKindLabel(k as AccountKind),
          iconOf: (k) => accountKindIcon(k as AccountKind),
          onSave: (k) {
            _pickKind(k as AccountKind);
            return null;
          }),
      for (final c in _fieldsOf(_kind)) ...[const SizedBox(height: 12), _field(c)],
      const SizedBox(height: 12),
      CurrencyField(
        key: const ValueKey('accountCurrency'),
        wc: wc,
        value: _currency,
        label: _isCrypto ? 'Coin' : 'Currency',
        choice: _isCrypto ? CurrencyChoice.crypto : CurrencyChoice.fiat,
        enabled: !_editing && widget.forImport == null,
        onChanged: (c) => setState(() => _currency = c),
      ),
      if (_isCrypto) ...[
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('accountRate'),
          controller: _rate,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          onChanged: (_) {
            if (_rateError != null) setState(() => _rateError = null);
          },
          style: numStyle,
          decoration: InputDecoration(
              labelText: 'Rate',
              prefixText: '1 $_currency = ',
              suffixText: currencySymbol(wc.currency),
              hintText: '62000${numberStyle.decimal}00',
              errorText: _rateError,
              errorMaxLines: 3),
        ),
        const Padding(
            padding: EdgeInsets.only(top: 4), child: Muted('You set the rate by hand. It turns the balance into your wallet currency.')),
      ],
      if (!_editing) ...[
        const SizedBox(height: 12),
        MoneyField(
          fieldKey: const ValueKey('accountOpening'),
          controller: _amount,
          onChanged: (_) {
            if (_amountError != null) setState(() => _amountError = null);
          },
          style: numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
              labelText: 'Balance',
              suffixText: currencySymbol(_currency),
              hintText: amountHintFor(_currency),
              errorText: _amountError,
              errorMaxLines: 3),
        ),
        BelowZeroBox(value: _negative, onChanged: (v) => setState(() => _negative = v)),
        FieldEditor(AccountCols.openingDate,
            id: 'accountDate',
            label: 'Balance on',
            value: _date,
            today: wc.today(),
            lengths: false,
            autoSave: true,
            errorText: _dateError, onSave: (d) {
          setState(() {
            _date = d as String;
            _dateError = null;
          });
          return null;
        }),
      ],
      if (_confirmedDrop && _editing) ...[
        const SizedBox(height: 10),
        StatusLabel(
            key: const ValueKey('accountDropNote'),
            good: false,
            text: _lostRows() == 1
                ? '1 ${_a!.isCash ? '' : 'imported '}payment will no longer count in this balance.'
                : '${_lostRows()} ${_a!.isCash ? '' : 'imported '}payments will no longer count in this balance.'),
      ],
      if (_error != null) ...[const SizedBox(height: 10), StatusLabel(key: const ValueKey('accountError'), good: false, text: _error!)],
      const SizedBox(height: 14),
      FilledButton(
          key: const ValueKey('accountSave'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          onPressed: _save,
          child: Text(!_editing ? 'Add account' : (_confirmedDrop ? 'Save anyway' : 'Save'))),
      const SizedBox(height: 8),
      Muted(_editing
          ? 'To change the balance, use Correct balance. The currency cannot change.'
          : widget.forImport != null
              ? 'Give the balance from before the first payment of the file, and that day. The file\'s payments are added to it.'
              : 'Rows after this date are added to the balance. Cash counts only the expenses you add by hand.'),
    ]);
  }
}
