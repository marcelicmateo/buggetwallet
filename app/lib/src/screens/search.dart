import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart'
    show Bill, BillStatus, CategorizedTx, PlannedCost, PlannedStatus, RuleKind, RuleView, SearchFilter, SearchResult;

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../tabs.dart';
import '../theme.dart';
import '../widgets/charts.dart' show RangePicker, systemRangePicker;
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'bill_sheet.dart';
import 'rules_panel.dart' show openRuleForm;
import 'search_filters.dart';
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

  /// The date range picker of the Date filter (tests give their own).
  final RangePicker picker;
  const SearchPane(
      {super.key,
      required this.wc,
      required this.onClose,
      required this.onOpenTab,
      required this.onOpenBills,
      this.picker = systemRangePicker});
  @override
  State<SearchPane> createState() => _SearchPaneState();
}

class _SearchPaneState extends State<SearchPane> {
  final _text = TextEditingController();
  final _focus = FocusNode(debugLabel: 'search');
  Timer? _debounce;

  /// The query the results are for (the field's text, a moment after typing stops).
  String _query = '';

  /// The filter chips' state (Q7). With a filter on, the results are payments only and a blank query is allowed.
  SearchFilter _filter = const SearchFilter();

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

  /// Opens a transaction found by the search. It runs here, in the pane's own context, so the toast after "Delete" still shows when
  /// the section the row was in has gone.
  Future<void> _openTx(CategorizedTx t) async {
    logNav('search.open.result', {'kind': 'tx'});
    final res = await showSheet<String>(context, TxSheet(wc: widget.wc, t: t));
    if (mounted) txSheetToast(context, widget.wc, res);
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
        SearchFilterBar(wc: widget.wc, filter: _filter, picker: widget.picker, onChanged: (f) => setState(() => _filter = f)),
        const SizedBox(height: 4),
        Expanded(
            child: _SearchResults(
                wc: widget.wc,
                query: _query,
                filter: _filter,
                onOpenTab: widget.onOpenTab,
                onOpenBills: widget.onOpenBills,
                onOpenTx: _openTx)),
      ]),
    );
  }
}

/// The ruled result sections for [query] (or the hint while it is too short).
class _SearchResults extends StatelessWidget {
  const _SearchResults(
      {required this.wc,
      required this.query,
      required this.filter,
      required this.onOpenTab,
      required this.onOpenBills,
      required this.onOpenTx});
  final WalletController wc;
  final String query;
  final SearchFilter filter;
  final void Function(int tab) onOpenTab;
  final VoidCallback onOpenBills;
  final Future<void> Function(CategorizedTx t) onOpenTx;

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency;
    final filtered = !filter.isEmpty;
    final searched = query.length >= searchMinChars || filtered;
    final r = !searched ? null : (filtered ? wc.searchFiltered(query, filter) : wc.search(query));
    final planned = searched && !filtered ? wc.searchPlanned(query) : const <PlannedCost>[];
    final billsFound = searched && !filtered ? wc.searchBills(query) : const <Bill>[];

    final body = <Widget>[
      if (!searched)
        const EmptyNote('Type at least 2 letters or digits to search transactions, goals, the wishlist and bills.')
      else if (r!.isEmpty && planned.isEmpty && billsFound.isEmpty)
        const EmptyNote('Nothing found')
      else ...[
        if (filtered) const Muted('Filters on: only payments are listed.', key: ValueKey('filterNote')),
        if (r.txs.isNotEmpty) _TxResults(wc, r, query, onOpenTx),
        if (r.goals.isNotEmpty)
          _ResultSection('Goals', r.goals.length, [
            Rows(children: [
              for (final g in r.goals)
                _ResultRow(g.name, '${money(g.saved, cur, decimals: 0)} / ${money(g.target, cur, decimals: 0)}', 'Goal', 'goal',
                    () => onOpenTab(Tabs.save), query),
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
                    () => wc.openWish(w.id, via: 'search'),
                    query),
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
                    () => p.isBill ? openBill(context, wc, p.sourceRef!) : openUpcoming(context, UpcomingView(wc)),
                    query),
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
                    () => openBill(context, wc, b.id),
                    query),
            ]),
          ]),
        if (r.rules.isNotEmpty)
          _ResultSection('Rules', r.rules.length, [
            Rows(children: [
              for (final rule in r.rules)
                KeyedSubtree(
                    key: ValueKey('searchRule:${rule.id}'),
                    child: _ResultRow(rule.text, '', rule.categoryLabel == null ? 'Tags only' : '→ ${rule.categoryLabel}', 'rule',
                        () => _openRule(context, wc, rule), query, true)),
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
                    onOpenBills,
                    query),
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

/// A rule found by name: its own form (Settings › Rules' edit path); a built-in rule cannot be edited, so Settings › Rules opens.
Future<void> _openRule(BuildContext context, WalletController wc, RuleView rule) async {
  if (rule.kind == RuleKind.builtIn || !rule.editable) {
    wc.openSettings(SettingsSection.rules, via: 'search');
    return;
  }
  await openRuleForm(context, wc, edit: rule);
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
  const _ResultRow(this.label, this.value, this.sub, this.kind, this.go, [this.query = '', this.highlightSub = false]);
  final String label, value, sub, kind, query;

  /// The match is bolded in [sub] too (a rule's category label).
  final bool highlightSub;
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
              start: Highlighted(label, query, style: const TextStyle(fontWeight: FontWeight.w500)),
              end: Text(value, textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
          Padding(
              padding: const EdgeInsets.only(top: 2),
              child: highlightSub
                  ? Highlighted(sub, query, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2))
                  : Text(sub, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2))),
        ]),
      ),
    );
  }
}

/// The matching transactions (the first [searchTxLimit]).
class _TxResults extends StatelessWidget {
  const _TxResults(this.wc, this.r, this.query, this.onOpenTx);
  final WalletController wc;
  final SearchResult r;
  final String query;
  final Future<void> Function(CategorizedTx t) onOpenTx;
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
              matched: wc.isMatchedBank(t.tx.id),
              iouTag: wc.iouTagOf(t.tx.id),
              splitCount: wc.splitCount(t.tx.id),
              splitBroken: wc.splitIsBroken(t.tx.id),
              matchedPart: r.matchedPart[t.tx.id],
              highlight: query,
              onTap: () => onOpenTx(t)),
        if (r.txs.length > searchTxLimit) const Muted('Showing the first 50. Type more to narrow it down.'),
      ]);
}
