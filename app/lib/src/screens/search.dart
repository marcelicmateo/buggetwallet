import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart' show Bill, BillStatus, PlannedCost, PlannedStatus;

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'bill_sheet.dart';
import 'upcoming.dart';

/// A query needs this many characters before anything is searched.
const searchMinChars = 2;

/// Transactions listed at most; the rest is said in one line ("narrow the search").
const searchTxLimit = 50; // the note below says "50"

/// The search view of the Spending tab: the field stays at the top (the results scroll under it, never the field), results
/// are ruled sections Transactions / Goals / Wishlist / Expected bills. Esc or the close button calls [onClose].
class SearchPane extends StatefulWidget {
  final WalletController wc;
  final VoidCallback onClose;

  /// Goal, wish or bill tapped: the tab to jump to (3 goals, 2 wishlist); [onOpenBills] for a bill (Plan, Expected bills).
  final void Function(int tab) onOpenTab;
  final VoidCallback onOpenBills;
  const SearchPane({super.key, required this.wc, required this.onClose, required this.onOpenTab, required this.onOpenBills});
  @override
  State<SearchPane> createState() => _SearchPaneState();
}

class _SearchPaneState extends State<SearchPane> {
  final _text = TextEditingController();
  final _focus = FocusNode(debugLabel: 'search');
  Timer? _debounce;

  /// The query the results are for (the field's text, a moment after typing stops).
  String _query = '';

  @override
  void initState() {
    super.initState();
    logNav('search.open');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _typed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _query = v.trim());
    });
  }

  void _close() {
    logNav('search.close');
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final cur = wc.currency;
    final c = context.c;
    final searched = _query.length >= searchMinChars;
    final r = searched ? wc.search(_query) : null;
    final planned = searched ? wc.searchPlanned(_query) : const <PlannedCost>[];
    final billsFound = searched ? wc.searchBills(_query) : const <Bill>[];

    // The name wraps and the value keeps its width (SplitRow), so a long goal name or amount fits 320 dp at text scale 2.0.
    Widget tap(String label, String value, String sub, String kind, VoidCallback go) => InkWell(
          hoverColor: c.surface2,
          focusColor: c.accentSoft,
          mouseCursor: SystemMouseCursors.click,
          onTap: () {
            logNav('search.open.result', {'kind': kind});
            go();
          },
          child: Container(
            constraints: const BoxConstraints(minHeight: rowMin),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SplitRow(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  start: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
                  end: Text(value, textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
              Padding(padding: const EdgeInsets.only(top: 2), child: Text(sub, style: TextStyle(fontSize: 12.5, color: c.ink2))),
            ]),
          ),
        );

    Widget section(String title, int n, List<Widget> rows) => Panel(children: [
          SectionHead(title, trailing: Tag('$n')),
          ...rows,
        ]);

    final body = <Widget>[
      if (!searched)
        const EmptyNote('Type at least 2 letters or digits to search transactions, goals, the wishlist and bills.')
      else if (r!.isEmpty && planned.isEmpty && billsFound.isEmpty)
        const EmptyNote('Nothing found')
      else ...[
        if (r.txs.isNotEmpty)
          section('Transactions', r.txs.length, [
            const TxHeaderRow(),
            for (final t in r.txs.take(searchTxLimit))
              TxTile(
                  key: ValueKey('hit:${t.tx.id}'),
                  t: t,
                  currency: cur,
                  hasBill: wc.billForTx(t.tx.id) != null,
                  onTap: () async {
                    logNav('search.open.result', {'kind': 'tx'});
                    final res = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                    if (res != null && context.mounted) toast(context, res == 'deleted' ? 'Deleted' : 'Category saved');
                  }),
            if (r.txs.length > searchTxLimit) const Muted('Showing the first 50. Type more to narrow it down.'),
          ]),
        if (r.goals.isNotEmpty)
          section('Goals', r.goals.length, [
            Rows(children: [
              for (final g in r.goals)
                tap(g.name, '${money(g.saved, cur, decimals: 0)} / ${money(g.target, cur, decimals: 0)}', 'Goal', 'goal',
                    () => widget.onOpenTab(3)),
            ]),
          ]),
        if (r.wishlist.isNotEmpty)
          section('Wishlist', r.wishlist.length, [
            Rows(children: [
              for (final w in r.wishlist)
                tap(w.name, money(w.price, cur, decimals: 0),
                    switch (w.status) { 'bought' => 'Bought', 'skipped' => 'Skipped', _ => 'Waiting' }, 'wish', () => widget.onOpenTab(2)),
            ]),
          ]),
        if (planned.isNotEmpty)
          section('Planned costs', planned.length, [
            Rows(children: [
              for (final p in planned)
                tap(
                    p.title,
                    p.amount == null ? 'No amount' : moneyExact(p.amount!, cur),
                    '${shortDateOrRaw(p.date)}${p.category == null ? '' : ' · ${p.category}'}${p.status == PlannedStatus.open ? '' : ' · ${p.status == PlannedStatus.paid ? 'Paid' : 'Skipped'}'}',
                    'planned',
                    () => plannedIsBill(p) ? openBill(context, wc, p.sourceRef!) : openUpcoming(context, wc)),
            ]),
          ]),
        if (billsFound.isNotEmpty)
          section('Bills', billsFound.length, [
            Rows(children: [
              for (final b in billsFound)
                tap(
                    (b.payee ?? '').isNotEmpty ? b.payee! : ((b.description ?? '').isNotEmpty ? b.description! : 'Bill'),
                    b.total == null ? 'No total' : moneyExact(b.total!, cur),
                    '${b.date == null ? 'No date' : shortDateOrRaw(b.date!)} · ${b.status == BillStatus.review ? 'To review' : (b.paid ? 'Paid' : 'Unpaid')}',
                    'billDb',
                    () => openBill(context, wc, b.id)),
            ]),
          ]),
        if (r.bills.isNotEmpty)
          section('Expected bills', r.bills.length, [
            Rows(children: [
              for (final b in r.bills)
                tap(
                    b.label.isNotEmpty ? b.label : b.payee,
                    moneyExact(b.expectedAmount, cur),
                    '${b.status == 'confirmed' ? 'Confirmed' : 'Looks like a bill'} · next ${shortDateOrRaw(b.nextDue)}',
                    'bill',
                    widget.onOpenBills),
            ]),
          ]),
      ],
    ];

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, 8),
          child: TextField(
            key: const ValueKey('searchField'),
            controller: _text,
            focusNode: _focus,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _typed,
            decoration: InputDecoration(
              hintText: 'Search everything',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                  key: const ValueKey('searchClose'),
                  tooltip: hasKeyboard ? 'Close search (Esc)' : 'Close search',
                  icon: const Icon(Icons.close),
                  onPressed: _close),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            key: const ValueKey('searchResults'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(pagePad, 0, pagePad, 24),
            children: gapped(body),
          ),
        ),
      ]),
    );
  }
}
