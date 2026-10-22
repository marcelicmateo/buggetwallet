import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_importer/wallet_importer.dart' show validIban;

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

/// Opens one bill (the sheet with its fields) and shows the toast for its result. [chooser] saves the original file where it cannot
/// be shown.
Future<void> openBill(BuildContext context, WalletController wc, String billId, {FileChooser chooser = const FileChooser()}) async {
  logNav('bill.open');
  final r = await showSheet<String>(context, BillSheet(wc: wc, billId: billId, chooser: chooser));
  if (!context.mounted) return;
  final msg = switch (r) {
    'confirmed' => 'Bill confirmed',
    'saved' => 'Saved',
    'deleted' => 'Bill deleted',
    'paid' => 'Marked as paid',
    _ => null,
  };
  if (msg != null) toast(context, msg);
}

/// Shows how adding a bill ended. A slip that is already there says so, and offers "Add as new bill" (next month's slip can look
/// the same); a bill that was added offers "Open".
void showBillImport(BuildContext context, WalletController wc, BillImport r, {FileChooser chooser = const FileChooser()}) {
  if (r.kind == BillImportKind.added && r.billId != null) {
    toast(context, r.message, actionLabel: 'Open', onAction: () => openBill(context, wc, r.billId!, chooser: chooser));
  } else if (r.kind == BillImportKind.duplicate && r.addAsNew != null) {
    toast(context, r.message, actionLabel: 'Add as new bill', onAction: () async {
      logNav('bill.addAsNew');
      final n = await r.addAsNew!();
      if (!context.mounted) return;
      if (n.kind == BillImportKind.added && n.billId != null) {
        toast(context, n.message);
        await openBill(context, wc, n.billId!, chooser: chooser);
      } else {
        toast(context, n.message);
      }
    });
  } else {
    toast(context, r.message);
  }
}

/// The words for the original file's button.
String _billFileLabel(String? type) => switch (type) {
      'pdf' => 'Show PDF',
      'xml' => 'Show e-invoice file',
      _ => 'Show photo',
    };

/// One bill: fields (a mark on the ones guessed from text), items, the original photo or PDF, Confirm, who paid it, warranty and
/// return-by dates, Delete. Pops `'confirmed'`, `'saved'`, `'deleted'` or `'paid'`.
class BillSheet extends StatefulWidget {
  final WalletController wc;
  final String billId;
  final FileChooser chooser;
  const BillSheet({super.key, required this.wc, required this.billId, this.chooser = const FileChooser()});
  @override
  State<BillSheet> createState() => _BillSheetState();
}

class _BillSheetState extends State<BillSheet> {
  late final Bill? _first = widget.wc.bill(widget.billId);
  late final total = TextEditingController(text: _first?.total == null ? '' : centsToFieldText(_first!.total!));
  late final payee = TextEditingController(text: _first?.payee ?? '');
  late final iban = TextEditingController(text: _first?.iban ?? '');
  late final reference = TextEditingController(text: _first?.reference ?? '');
  late final description = TextEditingController(text: _first?.description ?? '');
  late final note = TextEditingController(text: _first?.note ?? '');
  late String? date = _first?.date;
  late String? due = _first?.dueDate;
  // A bill to review whose category is empty starts with the suggestion (earlier bills of the same payee); it is marked as one.
  late final String? _suggested =
      _first == null || _first.status != BillStatus.review || _first.category != null ? null : widget.wc.suggestedBillCategory(_first);
  late String? category = _first?.category ?? _suggested;
  String? error;

  @override
  void dispose() {
    for (final c in [total, payee, iban, reference, description, note]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The fields the owner changed, saved on top of the bill. Returns false (and says why) when the total is not an amount.
  bool _save(Bill b) {
    final t = total.text.trim().isEmpty ? null : parseMoney(total.text);
    if (total.text.trim().isNotEmpty && (t == null || t <= 0)) {
      setState(() => error = 'Total: enter an amount, like 12.50.');
      return false;
    }
    String? changed(TextEditingController c, String? old) {
      final v = c.text.trim();
      return v.isEmpty || v == (old ?? '') ? null : v;
    }

    final typedIban = iban.text.replaceAll(' ', '').toUpperCase();
    if (typedIban.isNotEmpty && typedIban != (b.iban ?? '') && !validIban(typedIban)) {
      setState(() => error = 'IBAN: check the number, it does not look right.');
      return false;
    }
    final saved = widget.wc.updateBill(b.id,
        date: date != b.date ? date : null,
        dueDate: due != b.dueDate ? due : null,
        total: t != b.total ? t : null,
        payee: changed(payee, b.payee),
        iban: typedIban.isEmpty || typedIban == (b.iban ?? '') ? null : typedIban,
        reference: changed(reference, b.reference),
        description: changed(description, b.description),
        category: category != b.category ? category : null,
        note: changed(note, b.note),
        clearDueDate: due == null && b.dueDate != null,
        clearCategory: category == null && b.category != null);
    if (!saved) {
      // Core refused it: the bill is still to be paid and would reserve money with no category.
      logNav('bill.invalid', {'why': 'category'});
      setState(() => error = "Pick the category so Budget Wallet doesn't count this bill twice.");
    }
    return saved;
  }

  /// Saves a warranty or return-by date; a refusal keeps the sheet open with the reason.
  void _saveDates(Bill b, {String? warrantyUntil, String? returnBy, bool clearWarranty = false, bool clearReturnBy = false}) {
    final ok = widget.wc
        .setBillDates(b.id, warrantyUntil: warrantyUntil, returnBy: returnBy, clearWarranty: clearWarranty, clearReturnBy: clearReturnBy);
    if (!ok) setState(() => error = "Pick the category so Budget Wallet doesn't count this bill twice.");
  }

  Future<String?> _pick(String? current, {DateTime? first, DateTime? last}) async {
    final d = await showDatePicker(
        context: context,
        initialDate: current != null && isCalendarDate(current) ? parseIso(current) : widget.wc.now,
        firstDate: first ?? DateTime(2000),
        lastDate: last ?? DateTime(2100));
    return d == null ? null : isoDate(d);
  }

  Future<void> _confirm(Bill b) async {
    if (!_save(b)) return;
    final t = total.text.trim().isEmpty ? null : parseMoney(total.text);
    if (date == null || (t ?? 0) <= 0) {
      logNav('bill.invalid');
      setState(() => error = 'Add a date and a total first.');
      return;
    }
    if (category == null && due != null && due!.compareTo(widget.wc.today()) >= 0) {
      logNav('bill.invalid', {'why': 'category'});
      setState(() => error = "Pick the category so Budget Wallet doesn't count this bill twice.");
      return;
    }
    if (widget.wc.confirmBill(b.id) && mounted) Navigator.pop(context, 'confirmed');
  }

  Future<void> _paidBy(Bill b) async {
    logNav('bill.paidBy');
    final txId = await showSheet<String>(context, _CandidatesSheet(wc: widget.wc, bill: b));
    if (txId == null || !mounted) return;
    if (widget.wc.linkBill(b.id, txId)) {
      Navigator.pop(context, 'paid');
    } else {
      toast(context, 'That payment belongs to another bill.');
    }
  }

  Future<void> _cash(Bill b) async {
    logNav('bill.cash');
    final cat = await showSheet<String>(context, _CashSheet(wc: widget.wc, bill: b));
    if (cat == null || !mounted) return;
    widget.wc.addBillAsExpense(b.id, category: cat);
    Navigator.pop(context, 'paid');
  }

  Future<void> _delete(Bill b) async {
    logNav('bill.deleteAsk');
    final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Delete this bill?'),
              content: const Text('The bill and its photo or file are removed. A payment linked to it stays.'),
              actions: [
                TextButton(key: const ValueKey('deleteBillKeep'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                TextButton(
                    key: const ValueKey('deleteBillYes'),
                    style: TextButton.styleFrom(foregroundColor: context.c.bad),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Delete')),
              ],
            ));
    if (yes != true || !mounted) return;
    widget.wc.deleteBill(b.id);
    Navigator.pop(context, 'deleted');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.wc,
      builder: (context, _) {
        final b = widget.wc.bill(widget.billId);
        if (b == null) return const Padding(padding: EdgeInsets.all(16), child: EmptyNote('This bill is gone.'));
        return _body(context, b);
      });

  Widget _body(BuildContext context, Bill b) {
    final wc = widget.wc;
    final cur = wc.currency;
    final c = context.c;
    final review = b.status == BillStatus.review;
    // In review with a due date, or confirmed, unpaid and due from today on (a bill reopened without one): until it has a
    // category its planned row is listed, not reserved.
    final categoryNeeded = due != null && !b.paid && (review || due!.compareTo(widget.wc.today()) >= 0);
    final planner = wc.billPlannedBy(b);
    // Values read from free text (PDF text, a photo) are guesses: each filled field says so until the owner confirms the bill.
    final guessed = review && b.unsure > 0;
    InputDecoration deco(String label, {bool filled = true, String? hint, String? suffix}) => InputDecoration(
        labelText: label,
        hintText: hint,
        suffixText: suffix,
        helperText: guessed && filled ? 'Unsure: read from text. Check it.' : null,
        helperMaxLines: 2,
        suffixIcon: guessed && filled ? Icon(Icons.help_outline, size: 18, color: c.warnInk) : null);

    Widget dateButton(String label, String? value, ValueChanged<String?> onPick, {bool clearable = false, bool guess = false}) {
      return Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Muted(label, size: 12),
            const SizedBox(height: 2),
            OutlinedButton.icon(
              icon: const Icon(Icons.event, size: 18),
              label: Text(value == null ? 'Set date' : shortDateOrRaw(value), overflow: TextOverflow.ellipsis),
              onPressed: () async {
                final d = await _pick(value);
                if (d != null) setState(() => onPick(d));
              },
            ),
            if (guess && value != null) Text('Unsure: check it.', style: TextStyle(fontSize: 12, color: c.warnInk)),
          ]),
        ),
        if (clearable && value != null)
          IconButton(tooltip: 'Clear $label', icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => onPick(null))),
      ]);
    }

    final tx = b.linkedTx == null ? null : wc.txs.where((t) => t.tx.id == b.linkedTx).firstOrNull;
    final fileType = b.blobType;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading(review ? 'Bill to review' : 'Bill'),
      const SizedBox(height: 4),
      Muted(
          switch (b.source) {
            BillSource.receiptQr => 'Read from a receipt code.',
            BillSource.hub3 => 'Read from the code on a payment slip.',
            BillSource.eInvoice => 'Read from an e-invoice.',
            BillSource.pdf => 'Read from a PDF.',
            BillSource.photo => 'Read from a photo.',
            BillSource.manual => 'Added by you.',
          },
          size: 12.5),
      if (review) const Muted('Check the fields, then confirm. Nothing counts until you do.', size: 12.5),
      if (planner != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.event_repeat, size: 16, color: c.ink2),
            const SizedBox(width: 6),
            Expanded(
                child:
                    Text('Planned by ${planner.label}', key: const ValueKey('plannedBy'), style: TextStyle(fontSize: 12.5, color: c.ink2))),
          ]),
        ),
      const SizedBox(height: 12),
      MoneyField(
        fieldKey: const ValueKey('billTotal'),
        controller: total,
        onChanged: (_) => setState(() => error = null),
        style: numStyle.copyWith(fontSize: 26, fontWeight: FontWeight.w500),
        decoration:
            deco('Total', filled: total.text.isNotEmpty, hint: '0.00', suffix: currencySymbol(b.currency.isEmpty ? cur : b.currency)),
      ),
      const SizedBox(height: 4),
      const DoubleRule(),
      const SizedBox(height: 12),
      Wrap(spacing: 12, runSpacing: 8, children: [
        SizedBox(width: 200, child: dateButton('Date', date, (v) => date = v, guess: guessed)),
        SizedBox(width: 200, child: dateButton('Due date', due, (v) => due = v, clearable: true, guess: guessed)),
      ]),
      const SizedBox(height: 10),
      TextField(key: const ValueKey('billPayee'), controller: payee, decoration: deco('Payee', filled: payee.text.isNotEmpty)),
      const SizedBox(height: 10),
      TextField(key: const ValueKey('billIban'), controller: iban, decoration: deco('IBAN', filled: iban.text.isNotEmpty)),
      const SizedBox(height: 10),
      TextField(
          key: const ValueKey('billReference'), controller: reference, decoration: deco('Reference', filled: reference.text.isNotEmpty)),
      const SizedBox(height: 10),
      TextField(
          key: const ValueKey('billDescription'),
          controller: description,
          decoration: deco('Description', filled: description.text.isNotEmpty)),
      const SizedBox(height: 10),
      DropdownButtonFormField<String?>(
        key: ValueKey('billCategory:${category ?? ''}'),
        isExpanded: true,
        initialValue: category,
        decoration: InputDecoration(
            labelText: categoryNeeded ? 'Category (needed)' : 'Category',
            helperText: category != null && category == _suggested
                ? 'Suggested from your earlier bills. Check it.'
                : (categoryNeeded && category == null ? "Pick the category so Budget Wallet doesn't count this bill twice." : null),
            helperMaxLines: 3),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('None')),
          for (final k in categories.keys) DropdownMenuItem<String?>(value: k, child: Text(k)),
        ],
        onChanged: (v) => setState(() {
          category = v;
          error = null;
        }),
      ),
      const SizedBox(height: 10),
      TextField(key: const ValueKey('billNote'), controller: note, decoration: const InputDecoration(labelText: 'Note')),
      if (b.items.isNotEmpty) ...[
        const SizedBox(height: 14),
        const SectionHead('Items'),
        Rows(children: [
          for (final i in b.items) LineItem(i.name, moneyExact(i.amount, cur), sub: i.quantity == null ? null : 'Quantity ${i.quantity}'),
        ]),
      ],
      if (fileType != null) ...[
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
                  MaterialPageRoute(fullscreenDialog: true, builder: (_) => BillFileScreen(wc: wc, bill: b, chooser: widget.chooser)));
            },
          ),
        ),
      ],
      if (!review) ...[
        const SizedBox(height: 14),
        const SectionHead('Paid'),
        const SizedBox(height: 6),
        if (b.paid) ...[
          const StatusLabel(good: true, text: 'Paid'),
          if (tx != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SplitRow(
                  start: Text('${merchantName(tx.tx)} · ${shortDateOrRaw(tx.date)}', style: const TextStyle(fontSize: 13.5)),
                  end: Text(money(tx.amount, cur, decimals: 2, signed: true), textAlign: TextAlign.end, style: numStyle)),
            )
          else
            const Padding(padding: EdgeInsets.only(top: 6), child: Muted('The payment has not arrived on this device yet.')),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                key: const ValueKey('unlinkBill'),
                onPressed: () {
                  logNav('bill.unlink');
                  widget.wc.unlinkBill(b.id);
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
                onPressed: () => _paidBy(b)),
            OutlinedButton.icon(
                key: const ValueKey('paidCash'),
                icon: const Icon(Icons.payments_outlined, size: 18),
                label: const Text('Paid in cash → Add as expense'),
                onPressed: () => _cash(b)),
          ]),
      ],
      const SizedBox(height: 14),
      const SectionHead('Warranty and returns'),
      const SizedBox(height: 6),
      Wrap(spacing: 12, runSpacing: 8, children: [
        SizedBox(
            width: 200,
            child: dateButton('Warranty until', b.warrantyUntil, (v) {
              _saveDates(b, warrantyUntil: v, clearWarranty: v == null);
            }, clearable: true)),
        SizedBox(
            width: 200,
            child: dateButton('Return by', b.returnBy, (v) {
              _saveDates(b, returnBy: v, clearReturnBy: v == null);
            }, clearable: true)),
      ]),
      if (review) const Padding(padding: EdgeInsets.only(top: 4), child: Muted('Shown in Upcoming once the bill is confirmed.', size: 12)),
      if (error != null) ...[const SizedBox(height: 10), StatusLabel(key: const ValueKey('billError'), good: false, text: error!)],
      const SizedBox(height: 14),
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, spacing: 8, children: [
        if (review)
          FilledButton.icon(
              key: const ValueKey('confirmBill'),
              icon: const Icon(Icons.check),
              label: const Text('Confirm bill'),
              onPressed: () => _confirm(b))
        else
          FilledButton(
              key: const ValueKey('saveBill'),
              onPressed: () {
                if (_save(b)) Navigator.pop(context, 'saved');
              },
              child: const Text('Save')),
        TextButton(
            key: const ValueKey('deleteBill'),
            style: TextButton.styleFrom(foregroundColor: c.bad),
            onPressed: () => _delete(b),
            child: const Text('Delete')),
      ]),
    ]);
  }
}

/// "Paid by…": the payments that could be this bill, payee-word matches first. Pops the chosen transaction id.
class _CandidatesSheet extends StatelessWidget {
  final WalletController wc;
  final Bill bill;
  const _CandidatesSheet({required this.wc, required this.bill});
  @override
  Widget build(BuildContext context) {
    final list = wc.billCandidatesFor(bill);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Paid by…'),
      const SizedBox(height: 4),
      const Muted('Pick the payment from your bank. Nothing is matched by amount alone.', size: 12.5),
      const SizedBox(height: 8),
      if (list.isEmpty)
        const EmptyNote('No payment found near this date. Import your bank files, or add it as a cash expense.')
      else
        Column(children: [
          const TxHeaderRow(),
          for (final t in list.take(30))
            TxTile(
                key: ValueKey('cand:${t.tx.id}'),
                t: t,
                currency: wc.currency,
                onTap: () {
                  Navigator.pop(context, t.tx.id);
                }),
        ]),
    ]);
  }
}

/// "Paid in cash": the category of the hand-added expense. Pops the category.
class _CashSheet extends StatefulWidget {
  final WalletController wc;
  final Bill bill;
  const _CashSheet({required this.wc, required this.bill});
  @override
  State<_CashSheet> createState() => _CashSheetState();
}

class _CashSheetState extends State<_CashSheet> {
  late String cat = widget.bill.category != null && categories.containsKey(widget.bill.category) ? widget.bill.category! : 'Groceries';

  @override
  Widget build(BuildContext context) {
    final b = widget.bill;
    final cur = widget.wc.currency;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Heading('Add as expense'),
      const SizedBox(height: 4),
      Muted(
          'Adds ${b.total == null ? 'an expense' : moneyExact(b.total!, cur)} on ${b.date == null ? 'the bill date' : shortDateOrRaw(b.date!)} as a cash expense.',
          size: 12.5),
      const SizedBox(height: 10),
      const Muted('Category'),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final c in flexCategories.where((c) => c != 'Bank fees'))
          ChoiceChip(label: Text(c), selected: c == cat, onSelected: (_) => setState(() => cat = c)),
      ]),
      const SizedBox(height: 14),
      FilledButton.icon(
          key: const ValueKey('addCashExpense'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(touchMin)),
          icon: const Icon(Icons.add),
          label: const Text('Add expense'),
          onPressed: () => Navigator.pop(context, cat)),
    ]);
  }
}

/// The original photo, PDF or e-invoice file of a bill, fetched on demand (this device first, then the relay). A picture can be
/// zoomed; a PDF is shown page by page where the phone can render it; elsewhere (and for XML) it can be saved.
class BillFileScreen extends StatefulWidget {
  final WalletController wc;
  final Bill bill;
  final FileChooser chooser;
  const BillFileScreen({super.key, required this.wc, required this.bill, this.chooser = const FileChooser()});
  @override
  State<BillFileScreen> createState() => _BillFileScreenState();
}

class _BillFileScreenState extends State<BillFileScreen> {
  late Future<_Shown> _future = _load();

  Future<_Shown> _load() async {
    final f = await widget.wc.billFile(widget.bill);
    if (f.state != BillFileState.ready) return _Shown(f.state);
    final type = f.type ?? 'jpg';
    if (type == 'pdf' && widget.wc.billInputs.pdf.supported) {
      final pages = await widget.wc.billInputs.pdf.render(f.bytes!, dpi: 130, maxPages: 10);
      if (pages.isNotEmpty) return _Shown(f.state, bytes: f.bytes, type: type, pages: pages);
    }
    return _Shown(f.state, bytes: f.bytes, type: type);
  }

  Future<void> _save(_Shown s) async {
    logNav('bill.saveFile', {'type': s.type});
    try {
      final name = 'bill-${widget.bill.date ?? widget.wc.today()}.${s.type}';
      await widget.chooser.saveBillFile(fileName: name, bytes: s.bytes!, title: 'Save the bill file');
    } catch (e, st) {
      logError(Logger('bw.bills'), 'bill.saveFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) toast(context, chooserFailedMessage);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: DialogAppBar(title: _billFileLabel(widget.bill.blobType)),
        body: FutureBuilder<_Shown>(
            future: _future,
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final s = snap.data!;
              if (s.state == BillFileState.none) return const Center(child: EmptyNote('This bill has no photo or file.'));
              if (s.state == BillFileState.missing) {
                return Center(
                    child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('The file is on the relay; sync to fetch it', key: ValueKey('fileOnRelay'), textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                        icon: const Icon(Icons.sync, size: 18),
                        label: const Text('Sync now'),
                        onPressed: () async {
                          await widget.wc.syncNow();
                          if (mounted) setState(() => _future = _load());
                        }),
                  ]),
                ));
              }
              if (s.pages.isNotEmpty) {
                return InteractiveViewer(
                    maxScale: 5,
                    child: ListView(
                        children: [for (final p in s.pages) Padding(padding: const EdgeInsets.only(bottom: 8), child: Image.memory(p))]));
              }
              if (s.type == 'jpg' || s.type == 'png') {
                return InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(s.bytes!, key: const ValueKey('billImage'))));
              }
              return Center(
                  child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(isAndroid ? "Can't show this file here." : 'This file opens in another app.', textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                      key: const ValueKey('saveBillFile'),
                      icon: const Icon(Icons.save_alt, size: 18),
                      label: const Text('Save file…'),
                      onPressed: () => _save(s)),
                ]),
              ));
            }),
      );
}

class _Shown {
  final BillFileState state;
  final Uint8List? bytes;
  final String? type;
  final List<Uint8List> pages;
  const _Shown(this.state, {this.bytes, this.type, this.pages = const []});
}
