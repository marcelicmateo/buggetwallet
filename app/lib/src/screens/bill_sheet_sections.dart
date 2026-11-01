// The sections of the bill sheet, one private widget each (a `part` of bill_sheet.dart, so they can read the sheet's state). They only
// show: every edit goes through the state's `edit` and its handlers.
part of 'bill_sheet.dart';

/// What the sections of one build share: the sheet's state, the bill and the flags worked out once per build.
class _BillView {
  const _BillView(this.s, this.b, {required this.review, required this.guessed, required this.categoryNeeded});
  final _BillSheetState s;
  final Bill b;
  final bool review;

  /// Values read from free text (PDF text, a photo) are guesses: each filled field says so until the owner confirms the bill.
  final bool guessed;

  /// In review with a due date, or confirmed, unpaid and due from today on (a bill reopened without one): until it has a category its
  /// planned row is listed, not reserved.
  final bool categoryNeeded;

  WalletController get wc => s.widget.wc;

  InputDecoration deco(BuildContext context, String label, {bool filled = true, String? hint, String? suffix}) => InputDecoration(
      labelText: label,
      hintText: hint,
      suffixText: suffix,
      helperText: guessed && filled ? 'Unsure: read from text. Check it.' : null,
      helperMaxLines: 2,
      suffixIcon: guessed && filled ? Icon(Icons.help_outline, size: 18, color: context.c.warnInk) : null);

  Widget dateButton(String label, String? value, ValueChanged<String?> onPick, {bool clearable = false, bool guess = false}) {
    return DateField(
      label: label,
      value: value,
      helper: guess && value != null ? 'Unsure: check it.' : null,
      onPick: () async {
        final d = await s._pick(value);
        if (d != null) s.edit(() => onPick(d));
      },
      onClear: clearable ? () => s.edit(() => onPick(null)) : null,
    );
  }
}

/// A column that takes the sheet's width and only as much height as its children need (one section of the form).
Widget _sectionColumn(List<Widget> children) =>
    Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);

/// Title, where the bill was read from, the review hint and the recurring plan that planned it.
class _BillHeader extends StatelessWidget {
  const _BillHeader(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final planner = v.wc.billPlannedBy(v.b);
    return _sectionColumn([
      Heading(v.review ? 'Bill to review' : 'Bill'),
      const SizedBox(height: 4),
      Muted(
          switch (v.b.source) {
            BillSource.receiptQr => 'Read from a receipt code.',
            BillSource.hub3 => 'Read from the code on a payment slip.',
            BillSource.eInvoice => 'Read from an e-invoice.',
            BillSource.pdf => 'Read from a PDF.',
            BillSource.photo => 'Read from a photo.',
            BillSource.manual => 'Added by you.',
            BillSource.attachment => 'Attachment',
          },
          size: BwType.metaSize),
      if (v.review) const Muted('Check the fields, then confirm. Nothing counts until you do.', size: BwType.metaSize),
      if (planner != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.event_repeat, size: 16, color: c.ink2),
            const SizedBox(width: 6),
            Expanded(
                child: Text('Planned by ${planner.label}',
                    key: const ValueKey('plannedBy'), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2))),
          ]),
        )
      else if (v.wc.billsForSlip(v.b).isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              key: const ValueKey('slipBelongsTo'),
              icon: const Icon(Icons.event_repeat, size: 18),
              label: const Text('Belongs to bill…'),
              onPressed: () => v.s._belongsTo(v.b)),
        ),
    ]);
  }
}

/// The total, big, with the double rule under it.
class _BillTotal extends StatelessWidget {
  const _BillTotal(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final b = v.b, s = v.s;
    return _sectionColumn([
      MoneyField(
        fieldKey: const ValueKey('billTotal'),
        controller: s.total,
        onChanged: (_) => s.edit(() => s.error = null),
        style: numStyle.copyWith(fontSize: BwType.displaySize, fontWeight: FontWeight.w500),
        decoration: v.deco(context, 'Total',
            filled: s.total.text.isNotEmpty,
            hint: amountHintFor(b.currency.isEmpty ? v.wc.currency : b.currency),
            suffix: currencySymbol(b.currency.isEmpty ? v.wc.currency : b.currency)),
      ),
      const SizedBox(height: 4),
      const DoubleRule(),
    ]);
  }
}

/// Date and due date.
class _BillDates extends StatelessWidget {
  const _BillDates(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final s = v.s;
    return Wrap(spacing: 12, runSpacing: 8, children: [
      SizedBox(width: 200, child: v.dateButton('Date', s.date, (x) => s.date = x, guess: v.guessed)),
      SizedBox(width: 200, child: v.dateButton('Due date', s.due, (x) => s.due = x, clearable: true, guess: v.guessed)),
    ]);
  }
}

/// Payee, IBAN, reference and description.
class _BillTextFields extends StatelessWidget {
  const _BillTextFields(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final s = v.s;
    return _sectionColumn([
      TextField(
          key: const ValueKey('billPayee'), controller: s.payee, decoration: v.deco(context, 'Payee', filled: s.payee.text.isNotEmpty)),
      const SizedBox(height: 10),
      TextField(
          key: const ValueKey('billIban'),
          controller: s.iban,
          onChanged: (_) => s.edit(() => s.error = null),
          decoration: v.deco(context, 'IBAN', filled: s.iban.text.isNotEmpty)),
      const SizedBox(height: 10),
      TextField(
          key: const ValueKey('billReference'),
          controller: s.reference,
          decoration: v.deco(context, 'Reference', filled: s.reference.text.isNotEmpty)),
      const SizedBox(height: 10),
      TextField(
          key: const ValueKey('billDescription'),
          controller: s.description,
          decoration: v.deco(context, 'Description', filled: s.description.text.isNotEmpty)),
    ]);
  }
}

/// The category dropdown, with the "needed" and "suggested" hints.
class _BillCategory extends StatelessWidget {
  const _BillCategory(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final s = v.s;
    final category = s.category;
    return DropdownButtonFormField<String?>(
      key: ValueKey('billCategory:${category ?? ''}'),
      isExpanded: true,
      initialValue: category,
      decoration: InputDecoration(
          labelText: v.categoryNeeded ? 'Category (needed)' : 'Category',
          helperText: category != null && category == s._suggested
              ? 'Suggested from your earlier bills. Check it.'
              : (v.categoryNeeded && category == null ? "Pick the category so Budget Wallet doesn't count this bill twice." : null),
          helperMaxLines: 3),
      items: categoryMenuItems(v.wc.categoryTable, current: category, noneLabel: 'None'),
      onChanged: (x) => s.edit(() {
        s.category = x;
        s._categoryPicked = true;
        s.error = null;
      }),
    );
  }
}

/// The lines of an e-invoice or receipt (nothing when the bill has none).
class _BillItems extends StatelessWidget {
  const _BillItems(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final b = v.b;
    if (b.items.isEmpty) return const SizedBox.shrink();
    final cur = b.currency.isEmpty ? v.wc.currency : b.currency;
    return _sectionColumn([
      const SizedBox(height: 14),
      const SectionHead('Items'),
      Rows(children: [
        for (final i in b.items) LineItem(i.name, moneyExact(i.amount, cur), sub: i.quantity == null ? null : 'Quantity ${i.quantity}'),
      ]),
    ]);
  }
}

/// "Pay" for a confirmed, unpaid bill with an IBAN and a total.
class _BillPayButton extends StatelessWidget {
  const _BillPayButton(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final b = v.b, s = v.s;
    if (!(b.status == BillStatus.confirmed &&
        !b.paid &&
        s.iban.text.trim().isNotEmpty &&
        (parseMoney(s.total.text, currency: b.currency.isEmpty ? null : b.currency) ?? 0) > 0)) {
      return const SizedBox.shrink();
    }
    return _sectionColumn([
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('billPay'),
          style: accentOutlined(context),
          icon: const Icon(Icons.payments_outlined, size: 18),
          label: const Text('Pay'),
          onPressed: () => s._pay(b),
        ),
      ),
    ]);
  }
}

/// "Show photo / PDF / e-invoice file" when the bill has an original file.
class _BillFileButton extends StatelessWidget {
  const _BillFileButton(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final b = v.b;
    final fileType = b.blobType;
    if (fileType == null) return const SizedBox.shrink();
    return _sectionColumn([
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('showBillFile'),
          icon: const Icon(Icons.image_outlined, size: 18),
          label: Text(_billFileLabel(fileType)),
          onPressed: () {
            logNav('bill.showFile', {'type': fileType});
            Navigator.of(context).push<void>(
                MaterialPageRoute(fullscreenDialog: true, builder: (_) => BillFileScreen(wc: v.wc, bill: b, chooser: v.s.widget.chooser)));
          },
        ),
      ),
    ]);
  }
}

/// Who paid a confirmed bill: the linked payment, or the two ways to say it was paid.
class _BillPaid extends StatelessWidget {
  const _BillPaid(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final b = v.b, s = v.s;
    if (v.review) return const SizedBox.shrink();
    final tx = b.linkedTx == null ? null : v.wc.wholeTxs.where((t) => t.tx.id == b.linkedTx).firstOrNull;
    return _sectionColumn([
      const SizedBox(height: 14),
      const SectionHead('Paid'),
      const SizedBox(height: 6),
      if (b.paid) ...[
        const StatusLabel(good: true, text: 'Paid'),
        if (tx != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SplitRow(
                start: Text('${merchantName(tx.tx)} · ${shortDateOrRaw(tx.date)}', style: const TextStyle(fontSize: BwType.bodySize)),
                end: Text(money(tx.amount, tx.tx.currency, decimals: 2, signed: true), textAlign: TextAlign.end, style: numStyle)),
          )
        else
          const Padding(padding: EdgeInsets.only(top: 6), child: Muted('The payment has not arrived on this device yet.')),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              key: const ValueKey('unlinkBill'),
              onPressed: () {
                logNav('bill.unlink');
                v.wc.unlinkBill(b.id);
              },
              child: const Text('Unlink payment')),
        ),
      ] else
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              key: const ValueKey('paidBy'),
              style: accentOutlined(context),
              icon: const Icon(Icons.link, size: 18),
              label: const Text('Paid by…'),
              onPressed: () => s._paidBy(b)),
          OutlinedButton.icon(
              key: const ValueKey('paidCash'),
              icon: const Icon(Icons.payments_outlined, size: 18),
              label: const Text('Paid in cash → Add as expense'),
              onPressed: () => s._cash(b)),
        ]),
    ]);
  }
}

/// Warranty-until and return-by dates (saved as soon as they are picked).
class _BillWarranty extends StatelessWidget {
  const _BillWarranty(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final b = v.b, s = v.s;
    return _sectionColumn([
      const SizedBox(height: 14),
      const SectionHead('Warranty and returns'),
      const SizedBox(height: 6),
      _LengthDate(
          key: const ValueKey('warrantyDate'),
          v: v,
          id: 'warranty',
          label: 'Warranty until',
          value: b.warrantyUntil,
          maxReminder: WalletSettings.maxWarrantyReminderDays,
          reminderDays: v.wc.billReminderDays(b, warranty: true),
          saveReminder: (n) => v.wc.setBillReminderDays(b.id, warrantyDays: n),
          onDate: (x) => s._saveDates(b, warrantyUntil: x, clearWarranty: x == null)),
      const SizedBox(height: 14),
      _LengthDate(
          key: const ValueKey('returnDate'),
          v: v,
          id: 'return',
          label: 'Return by',
          value: b.returnBy,
          maxReminder: WalletSettings.maxReturnReminderDays,
          reminderDays: v.wc.billReminderDays(b, warranty: false),
          saveReminder: (n) => v.wc.setBillReminderDays(b.id, returnDays: n),
          onDate: (x) => s._saveDates(b, returnBy: x, clearReturnBy: x == null)),
      if (v.review)
        const Padding(
            padding: EdgeInsets.only(top: 4), child: Muted('Shown in Upcoming once the bill is confirmed.', size: BwType.metaSize)),
    ]);
  }
}

/// The error line and, at the end of the form and away from the confirm button, Delete.
class _BillFooter extends StatelessWidget {
  const _BillFooter(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final error = v.s.error;
    return _sectionColumn([
      if (error != null) ...[const SizedBox(height: 10), StatusLabel(key: const ValueKey('billError'), good: false, text: error)],
      const SizedBox(height: 14),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
            key: const ValueKey('deleteBill'),
            style: TextButton.styleFrom(foregroundColor: context.c.bad),
            onPressed: () => v.s._delete(v.b),
            child: const Text('Delete this bill')),
      ),
    ]);
  }
}

/// The main button, which stays in view while the form scrolls: Confirm bill for a bill in review, Save otherwise.
class _BillMainButton extends StatelessWidget {
  const _BillMainButton(this.v);
  final _BillView v;
  @override
  Widget build(BuildContext context) {
    final b = v.b, s = v.s;
    return v.review
        ? FilledButton.icon(
            key: const ValueKey('confirmBill'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
            icon: const Icon(Icons.check),
            label: const Text('Confirm bill'),
            onPressed: () => s._confirm(b))
        : FilledButton(
            key: const ValueKey('saveBill'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
            onPressed: () {
              if (s._save(b)) Navigator.pop(context, 'saved');
            },
            child: const Text('Save'));
  }
}
