// The fields of a loan as the lender wrote it (ENG E6): shared by "I bought it", "Turn into a loan…", "+ Loan" and a loan's details.
// A prefilled value is marked Unsure until the owner touches it (as the bill sheet does). Parsing only; core checks every value.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'goal_planner.dart' show rateBpText, scaledNumber;

class LoanFieldsState {
  final principal = TextEditingController(), rate = TextEditingController(), years = TextEditingController();
  final payment = TextEditingController(), lender = TextEditingController(), reference = TextEditingController();
  String? firstDue, accountId;

  /// Field ids still carrying a guess (`principal|rate|years|first|payment`).
  final Set<String> unsure = {};

  /// Fills a field from the plan and marks it Unsure.
  void guess(String id, TextEditingController c, String text) {
    c.text = text;
    if (text.isNotEmpty) unsure.add(id);
  }

  /// Prefills from an existing [l] (nothing is marked Unsure: the owner entered it).
  void load(Loan l) {
    principal.text = l.principal == null ? '' : centsToFieldText(l.principal!);
    rate.text = l.rateBp == null ? '' : rateBpText(l.rateBp!).replaceAll(' %', '');
    years.text = l.months == null ? '' : '${l.months! / 12}'.replaceAll(RegExp(r'\.0$'), '');
    payment.text = l.payment == null ? '' : centsToFieldText(l.payment!);
    firstDue = l.firstDue;
    reference.text = l.reference ?? '';
    accountId = l.accountId;
  }

  void dispose() {
    for (final c in [principal, rate, years, payment, lender, reference]) {
      c.dispose();
    }
  }

  /// The loan from the fields, or the text of what is wrong. With [needAll] the amount, rate, length and first payment date must be
  /// filled in; without it an empty field stays unknown.
  (Loan?, String?) read(WalletController wc, {required String name, required bool needAll, bool withPayment = true}) {
    int? money(TextEditingController c, String label) => c.text.trim().isEmpty ? null : parseMoney(c.text);
    final p = money(principal, 'Amount'), pay = withPayment ? money(payment, 'Payment') : null;
    if (principal.text.trim().isNotEmpty && (p == null || p <= 0)) return (null, 'Amount borrowed: $invalidAmountMessage');
    if (withPayment && payment.text.trim().isNotEmpty && (pay == null || pay <= 0)) return (null, 'Monthly payment: $invalidAmountMessage');
    final r = rate.text.trim().isEmpty ? null : scaledNumber(rate.text, 100);
    if (rate.text.trim().isNotEmpty && (r == null || r > 10000)) return (null, 'Rate: enter a percent, like 3.6.');
    final m = years.text.trim().isEmpty ? null : scaledNumber(years.text, 12);
    if (years.text.trim().isNotEmpty && (m == null || m < 1 || m > 600)) return (null, 'Length: enter years, like 25.');
    if (needAll && (p == null || r == null || m == null || firstDue == null)) {
      return (null, 'Fill in the amount, rate, length and first payment date.');
    }
    final lenderText = lender.text.trim(), ref = reference.text.trim();
    return (
      Loan(
          id: '',
          name: name,
          principal: p,
          rateBp: r,
          months: m,
          firstDue: firstDue,
          payment: pay,
          accountId: accountId,
          payeeKey: lenderText.isEmpty ? null : wc.payeeKeyOf(lenderText),
          reference: ref.isEmpty ? null : ref),
      null
    );
  }
}

class LoanFields extends StatefulWidget {
  final WalletController wc;
  final LoanFieldsState s;

  /// Show the monthly payment and the account (not for a converted plan loan: its payment is the plan's).
  final bool withPayment;
  const LoanFields({super.key, required this.wc, required this.s, this.withPayment = true});
  @override
  State<LoanFields> createState() => _LoanFieldsState();
}

class _LoanFieldsState extends State<LoanFields> {
  LoanFieldsState get s => widget.s;

  InputDecoration _dec(String id, String label, {String? suffix, String? hint, String? helper}) {
    final c = context.c, guessed = s.unsure.contains(id);
    return InputDecoration(
      labelText: label,
      suffixText: suffix,
      hintText: hint,
      helperText: guessed ? 'Unsure: from the plan. Check it.' : helper,
      helperStyle: guessed ? TextStyle(color: c.warnInk, fontWeight: FontWeight.w600) : null,
      enabledBorder: guessed ? OutlineInputBorder(borderSide: BorderSide(color: c.warnInk, width: 2)) : null,
    );
  }

  void _touched(String id) => setState(() => s.unsure.remove(id));

  Future<void> _pickDate() async {
    final now = DateTime.parse(widget.wc.today());
    final d = await showDatePicker(
        context: context,
        initialDate: s.firstDue == null ? now : parseIso(s.firstDue!),
        firstDate: DateTime(now.year - 50),
        lastDate: DateTime(now.year + 50));
    if (d == null) return;
    setState(() {
      s.firstDue = isoDate(d);
      s.unsure.remove('first');
    });
  }

  @override
  Widget build(BuildContext context) {
    final cur = currencySymbol(widget.wc.currency);
    final accounts = widget.wc.accountsAll();
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: gapped([
          MoneyField(
              fieldKey: const ValueKey('lf:principal'),
              controller: s.principal,
              onChanged: (_) => _touched('principal'),
              decoration: _dec('principal', 'Amount borrowed', suffix: cur)),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: TextField(
                    key: const ValueKey('lf:rate'),
                    controller: s.rate,
                    onChanged: (_) => _touched('rate'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.end,
                    style: numStyle,
                    decoration: _dec('rate', 'Rate a year', suffix: '%'))),
            const SizedBox(width: 10),
            Expanded(
                child: TextField(
                    key: const ValueKey('lf:years'),
                    controller: s.years,
                    onChanged: (_) => _touched('years'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.end,
                    style: numStyle,
                    decoration: _dec('years', 'Length', suffix: 'years'))),
          ]),
          DateField(
              key: const ValueKey('lf:first'),
              label: 'First payment',
              value: s.firstDue,
              onPick: _pickDate,
              helper: s.unsure.contains('first') ? 'Unsure: from the plan. Check it.' : null),
          if (widget.withPayment)
            MoneyField(
                fieldKey: const ValueKey('lf:payment'),
                controller: s.payment,
                onChanged: (_) => _touched('payment'),
                decoration: _dec('payment', 'Monthly payment', suffix: cur, helper: 'As the lender wrote it. Empty = worked out.')),
          TextField(
              key: const ValueKey('lf:lender'),
              controller: s.lender,
              decoration:
                  const InputDecoration(labelText: 'Lender, as your bank shows it', helperText: 'Used to find its payments in Money.')),
          TextField(
              key: const ValueKey('lf:reference'),
              controller: s.reference,
              decoration: const InputDecoration(labelText: 'Reference on each payment (optional)', helperText: 'At least 4 characters.')),
          if (widget.withPayment && accounts.isNotEmpty)
            DropdownButtonFormField<String?>(
              key: const ValueKey('lf:account'),
              initialValue: accounts.any((a) => a.id == s.accountId) ? s.accountId : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Paid from'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Not set')),
                for (final a in accounts) DropdownMenuItem<String?>(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => s.accountId = v),
            ),
        ], gap: 12));
  }
}
