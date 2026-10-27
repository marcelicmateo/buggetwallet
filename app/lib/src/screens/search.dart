import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart' show Bill, BillStatus, PlannedCost, PlannedStatus, SearchResult;

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../tabs.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'bill_sheet.dart';
import 'upcoming.dart';
import 'upcoming_view.dart';

/// A query needs this many characters before anything is searched.
const searchMinChars = 2;

/// Transactions listed at most; the rest is said in one line ("narrow the search").
const searchTxLimit = 50; // the note below says "50"

/// The search view of the Spending tab: the field stays at the top (the results scroll under it, never the field), results
/// are ruled sections Transactions / Goals / Wishlist / Expected bills. Esc or the close button calls [onClose].
class SearchPane extends StatefulWidget {
  final WalletController wc;
  final VoidCallback onClose;

  /// Goal, wish or bill tapped: the tab to jump to (both are on Save); [onOpenBills] for a bill (the Bills tab).
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
        Expanded(child: _SearchResults(wc: widget.wc, query: _query, onOpenTab: widget.onOpenTab, onOpenBills: widget.onOpenBills)),
      ]),
    );
  }
}

/// The ruled result sections for [query] (or the hint while it is too short).
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.wc, required this.query, required this.onOpenTab, required this.onOpenBills});
  final WalletController wc;
  final String query;
  final void Function(int tab) onOpenTab;
  final VoidCallback onOpenBills;

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency;
    final searched = query.length >= searchMinChars;
    final r = searched ? wc.search(query) : null;
    final planned = searched ? wc.searchPlanned(query) : const <PlannedCost>[];
    final billsFound = searched ? wc.searchBills(query) : const <Bill>[];

    final body = <Widget>[
      if (!searched)
        const EmptyNote('Type at least 2 letters or digits to search transactions, goals, the wishlist and bills.')
      else if (r!.isEmpty && planned.isEmpty && billsFound.isEmpty)
        const EmptyNote('Nothing found')
      else ...[
        if (r.txs.isNotEmpty) _TxResults(wc, r),
        if (r.goals.isNotEmpty)
          _ResultSection('Goals', r.goals.length, [
            Rows(children: [
              for (final g in r.goals)
                _ResultRow(g.name, '${money(g.saved, cur, decimals: 0)} / ${money(g.target, cur, decimals: 0)}', 'Goal', 'goal',
                    () => onOpenTab(Tabs.save)),
            ]),
          ]),
        if (r.wishlist.isNotEmpty)
          _ResultSection('Wishlist', r.wishlist.length, [
            Rows(children: [
              for (final w in r.wishlist)
                _ResultRow(
                    w.name,
                    money(w.price, cur, decimals: 0),
                    switch (w.status) { 'bought' => 'Bought', 'skipped' => 'Skipped', _ => 'Waiting' },
                    'wish',
                    () => wc.openWish(w.id, via: 'search')),
            ]),
          ]),
        if (planned.isNotEmpty)
          _ResultSection('Planned costs', planned.length, [
            Rows(children: [
              for (final p in planned)
                _ResultRow(
                    p.title,
                    p.amount == null ? 'No amount' : moneyExact(p.amount!, cur),
                    '${shortDateOrRaw(p.date)}${p.category == null ? '' : ' · ${wc.categoryTable.label(p.category!)}'}${p.status == PlannedStatus.open ? '' : ' · ${p.status == PlannedStatus.paid ? 'Paid' : 'Skipped'}'}',
                    'planned',
                    () => p.isBill ? openBill(context, wc, p.sourceRef!) : openUpcoming(context, UpcomingView(wc))),
            ]),
          ]),
        if (billsFound.isNotEmpty)
          _ResultSection('Bills', billsFound.length, [
            Rows(children: [
              for (final b in billsFound)
                _ResultRow(
                    (b.payee ?? '').isNotEmpty ? b.payee! : ((b.description ?? '').isNotEmpty ? b.description! : 'Bill'),
                    b.total == null ? 'No total' : moneyExact(b.total!, cur),
                    '${b.date == null ? 'No date' : shortDateOrRaw(b.date!)} · ${b.status == BillStatus.review ? 'To review' : (b.paid ? 'Paid' : 'Unpaid')}',
                    'billDb',
                    () => openBill(context, wc, b.id)),
            ]),
          ]),
        if (r.bills.isNotEmpty)
          _ResultSection('Expected bills', r.bills.length, [
            Rows(children: [
              for (final b in r.bills)
                _ResultRow(
                    b.label.isNotEmpty ? b.label : b.payee,
                    moneyExact(b.expectedAmount, cur),
                    '${b.status == 'confirmed' ? 'Confirmed' : 'Looks like a bill'} · next ${shortDateOrRaw(b.nextDue)}',
                    'bill',
                    onOpenBills),
            ]),
          ]),
      ],
    ];

    return ListView(
      key: const ValueKey('searchResults'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(pagePad, 0, pagePad, pageBottomPad),
      children: gapped(body),
    );
  }
}

/// A ruled result section: its title with the count, then the [rows].
class _ResultSection extends StatelessWidget {
  const _ResultSection(this.title, this.n, this.rows);
  final String title;
  final int n;
  final List<Widget> rows;
  @override
  Widget build(BuildContext context) => Panel(children: [
        SectionHead(title, trailing: Tag('$n')),
        ...rows,
      ]);
}

/// One tappable result. The name wraps and the value keeps its width (SplitRow), so a long goal name or amount fits 320 dp at
/// text scale 2.0.
class _ResultRow extends StatelessWidget {
  const _ResultRow(this.label, this.value, this.sub, this.kind, this.go);
  final String label, value, sub, kind;
  final VoidCallback go;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
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
          Padding(padding: const EdgeInsets.only(top: 2), child: Text(sub, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2))),
        ]),
      ),
    );
  }
}

/// The matching transactions (the first [searchTxLimit]).
class _TxResults extends StatelessWidget {
  const _TxResults(this.wc, this.r);
  final WalletController wc;
  final SearchResult r;
  @override
  Widget build(BuildContext context) => _ResultSection('Transactions', r.txs.length, [
        const TxHeaderRow(),
        for (final t in r.txs.take(searchTxLimit))
          TxTile(
              table: wc.categoryTable,
              tagTable: wc.tagTable,
              key: ValueKey('hit:${t.tx.id}'),
              t: wc.shown(t),
              currency: wc.currency,
              fxRates: wc.settings.fxRates,
              hasBill: wc.billForTx(t.tx.id) != null,
              splitCount: wc.splitCount(t.tx.id),
              splitBroken: wc.splitIsBroken(t.tx.id),
              matchedPart: r.matchedPart[t.tx.id],
              onTap: () async {
                logNav('search.open.result', {'kind': 'tx'});
                final res = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                if (context.mounted) txSheetToast(context, wc, res);
              }),
        if (r.txs.length > searchTxLimit) const Muted('Showing the first 50. Type more to narrow it down.'),
      ]);
}
