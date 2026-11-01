import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../bill_inputs.dart' show maxBillFileBytes;
import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/async_action.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart';
import 'bill_sheet.dart';
import 'scan_bill.dart';

final _log = Logger('bw.bills');

/// One line for the results of adding [results] (a file pick can add several): "Bill added to review", "Already in your bills",
/// "2 bills added to review · 1 already in your bills" or the reason it failed.
String billImportMessage(List<BillImport> results) {
  if (results.length == 1) return results.first.message;
  final added = results.where((r) => r.kind == BillImportKind.added).length;
  final dup = results.where((r) => r.kind == BillImportKind.duplicate).length;
  final bad = results.length - added - dup;
  final parts = [
    if (added > 0) '$added ${added == 1 ? 'bill' : 'bills'} added to review',
    if (dup > 0) '$dup already in your bills',
    if (bad > 0) "$bad couldn't be read",
  ];
  return parts.isEmpty ? "Couldn't add those bills." : parts.join(' · ');
}

/// Choose bill files (PDF, e-invoice XML, photos) and add them; every failure is logged (type and counts only, never file names or
/// paths) and shown as a short message. A single new bill opens its sheet.
Future<void> _pickAndImportBills(BuildContext context, WalletController wc, FileChooser chooser) async {
  logNav('bills.pick');
  final List<PickedFile> picked;
  try {
    picked = await chooser.pickBillFiles();
  } catch (e, st) {
    logError(_log, 'bills.pickerFailed', e, st, fields: {'type': e.runtimeType.toString()});
    if (context.mounted) toast(context, chooserFailedMessage);
    return;
  }
  if (picked.isEmpty) {
    logNav('bills.cancelled');
    return;
  }
  // The size is asked before the file is read: a huge file is never loaded into memory (limits in bill_inputs.dart).
  final files = <(String, Uint8List?)>[];
  try {
    for (final pf in picked) {
      final ext = fileExt(pf.name);
      final size = await pf.length();
      files.add((ext, size != null && size > maxBillFileBytes(ext) ? null : await pf.readBytes()));
    }
  } catch (e, st) {
    logError(_log, 'bills.openFailed', e, st, fields: {'files': picked.length, 'read': files.length});
    if (context.mounted) toast(context, "Couldn't open that file.");
    return;
  }
  logNav('bills.chosen', {
    'files': files.length,
    'exts': [for (final (x, _) in files) x],
    'bytes': [for (final (_, b) in files) b?.length ?? -1]
  });
  final results = <BillImport>[];
  for (final (ext, bytes) in files) {
    results.add(bytes == null ? const BillImport(BillImportKind.tooBig) : await wc.importBillFile(bytes, ext));
  }
  if (!context.mounted) return;
  final one = results.length == 1 ? results.first : null;
  if (one != null && one.kind == BillImportKind.added && one.billId != null) {
    toast(context, one.message);
    unawaited(openBill(context, wc, one.billId!, chooser: chooser)); // the panel is not busy while the sheet is open
    return;
  }
  if (one != null) {
    showBillImport(context, wc, one, chooser: chooser);
  } else {
    toast(context, billImportMessage(results));
  }
}

/// One bill in a list: name, dates, state mark and total. Tap opens the bill sheet.
class BillRow extends StatelessWidget {
  final WalletController wc;
  final FileChooser chooser;
  final Bill bill;
  final bool unpaid;
  const BillRow({super.key, required this.wc, required this.chooser, required this.bill, this.unpaid = false});

  @override
  Widget build(BuildContext context) {
    final b = bill;
    final c = context.c;
    final cur = wc.currency;
    final today = wc.today();
    final name = (b.payee ?? '').isNotEmpty ? b.payee! : ((b.description ?? '').isNotEmpty ? b.description! : 'Bill');
    final overdue = unpaid && b.dueDate != null && b.dueDate!.compareTo(today) < 0;
    final dates = [
      if (b.date != null) shortDateOrRaw(b.date!),
      if (b.dueDate != null && b.status == BillStatus.confirmed) 'due ${shortDateOrRaw(b.dueDate!)}',
    ].join(' · ');
    return InkWell(
      key: ValueKey('bill:${b.id}'),
      hoverColor: c.surface2,
      focusColor: c.accentSoft,
      onTap: () => openBill(context, wc, b.id, chooser: chooser),
      child: Container(
        constraints: const BoxConstraints(minHeight: touchMin),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SplitRow(
          crossAxisAlignment: CrossAxisAlignment.start,
          start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),
            if (dates.isNotEmpty) Text(dates, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
            if (overdue) const Padding(padding: EdgeInsets.only(top: 4), child: StateChip.over(text: 'Overdue')),
            if (b.paid) const Padding(padding: EdgeInsets.only(top: 4), child: StateChip.onPace(text: 'Paid')),
          ]),
          end: b.total == null
              ? Text('No total', textAlign: TextAlign.end, style: TextStyle(fontSize: BwType.metaSize, color: c.muted))
              : Text(moneyExact(b.total!, b.currency.isEmpty ? cur : b.currency),
                  textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}

/// Bills › Bills: the bills database. To review (read from codes, files and photos; nothing counts until confirmed), Unpaid (confirmed,
/// not linked to a payment yet) and Paid. "Import bill file" adds PDFs, e-invoices and photos; "Scan bill" opens the camera.
class BillsPanel extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;

  /// False where "To review" has a panel of its own (the Bills tab).
  final bool showReview;
  const BillsPanel({super.key, required this.wc, this.chooser = const FileChooser(), this.showReview = true});
  @override
  State<BillsPanel> createState() => _BillsPanelState();
}

class _BillsPanelState extends State<BillsPanel> with AsyncAction {
  bool _allPaid = false;
  static const _paidShown = 6;

  Future<void> _import() => run(() => _pickAndImportBills(context, widget.wc, widget.chooser));

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final lists = wc.billLists();

    Widget group(String title, List<Bill> list, {bool unpaid = false, int? limit}) => _BillGroup(
        wc: wc,
        chooser: widget.chooser,
        title: title,
        list: list,
        unpaid: unpaid,
        limit: limit,
        showAll: _allPaid,
        onToggleAll: () => setState(() => _allPaid = !_allPaid));

    return Panel(children: [
      const SectionHead('Bills'),
      Explainer(wc, 'bills',
          'Receipts, payment slips and PDF bills. Read from a code or file, they wait here until you check and confirm them. Photos and PDFs are kept, encrypted.'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          key: const ValueKey('importBill'),
          style: accentOutlined(context),
          icon: busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.upload_file),
          label: const Text('Import bill file'),
          onPressed: busy ? null : _import,
        ),
        if (wc.billInputs.camera.supported)
          OutlinedButton.icon(
            key: const ValueKey('scanBillPlan'),
            icon: const Icon(Icons.document_scanner_outlined),
            label: const Text('Scan bill'),
            onPressed: () => scanBillFlow(context, wc, chooser: widget.chooser),
          ),
      ]),
      if (lists.isEmpty) const EmptyNote('No bills yet. Import a bill file, or scan one with the camera.'),
      if (widget.showReview && lists.review.isNotEmpty) group('To review', lists.review),
      if (lists.unpaid.isNotEmpty) group('Unpaid', lists.unpaid, unpaid: true),
      if (lists.paid.isNotEmpty) group('Paid', lists.paid, limit: _paidShown),
    ]);
  }
}

/// One list of bills under its heading ("Unpaid (3)"). With a [limit] only that many show, and a button shows all or fewer.
class _BillGroup extends StatelessWidget {
  const _BillGroup({
    required this.wc,
    required this.chooser,
    required this.title,
    required this.list,
    required this.unpaid,
    required this.limit,
    required this.showAll,
    required this.onToggleAll,
  });
  final WalletController wc;
  final FileChooser chooser;
  final String title;
  final List<Bill> list;
  final bool unpaid;
  final int? limit;
  final bool showAll;
  final VoidCallback onToggleAll;

  @override
  Widget build(BuildContext context) {
    final limit = this.limit;
    final shown = limit == null || showAll ? list : list.take(limit).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Heading('$title (${list.length})', size: BwType.headingSize),
      Rows(children: [for (final b in shown) BillRow(wc: wc, chooser: chooser, bill: b, unpaid: unpaid)]),
      if (limit != null && list.length > limit)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              key: const ValueKey('paidMore'), onPressed: onToggleAll, child: Text(showAll ? 'Show fewer' : 'Show all ${list.length}')),
        ),
    ]);
  }
}
