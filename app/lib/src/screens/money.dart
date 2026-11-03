// Money (ENG E7a, docs/context/ENG_UI_SPEC.md §3, mockup structure/Money.dc.html): one timeline. The accounts strip, the filters, what is
// coming up as dashed rows, a "Today" line, then the payments by day, newest first (a lazy list). A row opens the sheet it always had.
// The Per month / Per year bill costs are one strip that opens "Bills & slips". The list and its filters are the controller's
// `moneyTimeline`; this file only draws it.
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../tabs.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart' show DashedBorderPainter;
import '../widgets/jump_when_built.dart';
import '../widgets/rebuild_when_shown.dart';
import '../widgets/sheets.dart';
import 'bill_sheet.dart';
import 'bills_tab.dart';
import 'planned_sheets.dart' show plannedEntryToast;
import 'recurring_sheet.dart';
import 'search.dart';
import 'upcoming.dart';
import 'upcoming_view.dart';

const _filterNames = {
  MoneyFilter.all: 'All',
  MoneyFilter.out: 'Out',
  MoneyFilter.income: 'In',
  MoneyFilter.bills: 'Bills',
  MoneyFilter.planned: 'Planned',
};

class MoneyScreen extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;

  /// A link (Overview, search) asks for a place on this page: see [BillsAnchor].
  final JumpRequest<BillsAnchor>? request;

  /// Counts the Ctrl+F presses; Money opens its search on each.
  final Listenable? searchRequest;
  const MoneyScreen({super.key, required this.wc, this.chooser = const FileChooser(), this.request, this.searchRequest});
  @override
  State<MoneyScreen> createState() => _MoneyScreenState();
}

class _Entry {
  final String kind; // up | today | day | tx
  final MoneyUpRow? up;
  final String? date;
  final CategorizedTx? tx;
  const _Entry(this.kind, {this.up, this.date, this.tx});
}

class _MoneyScreenState extends State<MoneyScreen> {
  final _scroll = ScrollController();
  MoneyFilter _filter = MoneyFilter.all;
  String? _account;
  bool _searching = false;

  // The flattened rows of the timeline last built (rebuilt when the controller hands out another one).
  MoneyTimeline? _of;
  List<_Entry> _entries = const [];

  @override
  void initState() {
    super.initState();
    widget.request?.addListener(_jump);
    widget.searchRequest?.addListener(_search);
    jumpWhenBuilt(widget.request, () => mounted, _jump); // a link that opened this tab before its page existed
  }

  @override
  void didUpdateWidget(MoneyScreen old) {
    super.didUpdateWidget(old);
    if (old.request != widget.request) {
      old.request?.removeListener(_jump);
      widget.request?.addListener(_jump);
    }
    if (old.searchRequest != widget.searchRequest) {
      old.searchRequest?.removeListener(_search);
      widget.searchRequest?.addListener(_search);
    }
  }

  @override
  void dispose() {
    widget.request?.removeListener(_jump);
    widget.searchRequest?.removeListener(_search);
    _scroll.dispose();
    super.dispose();
  }

  void _search() {
    if (mounted && !_searching) setState(() => _searching = true);
  }

  /// A link to the bills (the Explore search's expected bill) opens Bills & slips at the place it names.
  Future<void> _jump() async {
    final a = widget.request?.value;
    if (a == null) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await openBillsPage(context, widget.wc, chooser: widget.chooser, anchor: a);
  }

  @override
  Widget build(BuildContext context) => RebuildWhenShown(listenable: widget.wc, builder: _page);

  Widget _page(BuildContext context) {
    final wc = widget.wc;
    if (_searching) {
      return ColoredBox(
        color: context.c.desk,
        child: SearchPane(
          wc: wc,
          onClose: () => setState(() => _searching = false),
          onOpenTab: (i) => wc.openTab(i, via: 'search'),
          onOpenBills: () => openBillsPage(context, wc, chooser: widget.chooser),
        ),
      );
    }
    final accounts = wc.moneyAccounts();
    if (_account != null && !accounts.any((b) => b.account.id == _account)) _account = null;
    final tl = wc.moneyTimeline(_filter, accountId: _account);
    if (!identical(tl, _of)) {
      _of = tl;
      _entries = _flatten(tl, wc.today());
    }
    final cost = wc.billsCost();
    final cur = wc.currency;
    final asOf = [
      for (final b in accounts)
        if (b.lastRowDate != null) b.lastRowDate!
    ].fold<String?>(null, (a, d) => a == null || d.compareTo(a) > 0 ? d : a);
    final head = <Widget>[
      const Text('Money', style: BwType.title),
      if (accounts.isNotEmpty)
        SingleChildScrollView(
          key: const ValueKey('moneyAccounts'),
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final b in accounts) ...[
              if (b != accounts.first) const SizedBox(width: 8),
              _AccountCard(
                  key: ValueKey('moneyAccount:${b.account.id}'),
                  name: b.account.name,
                  balance: moneyExact(b.balance, b.account.currency),
                  on: _account == b.account.id,
                  onTap: () {
                    logNav('money.account', {'on': _account != b.account.id});
                    setState(() => _account = _account == b.account.id ? null : b.account.id);
                  }),
            ],
          ]),
        ),
      if (asOf != null) Muted('Balances as of last import, ${shortDateOrRaw(asOf)}'),
      if (cost != null) _CostStrip(cost: cost, cur: cur, onTap: () => openBillsPage(context, wc, chooser: widget.chooser)),
      Wrap(spacing: 8, runSpacing: 4, children: [
        for (final f in MoneyFilter.values)
          ChoiceChip(
              key: ValueKey('moneyFilter:${f.name}'),
              label: Text(_filterNames[f]!),
              selected: _filter == f,
              onSelected: (_) {
                logNav('money.filter', {'filter': f.name});
                setState(() => _filter = f);
              }),
        ActionChip(
            key: const ValueKey('billsOpen'),
            avatar: const Icon(Icons.receipt_long_outlined, size: 18),
            label: const Text('Bills & slips'),
            onPressed: () => openBillsPage(context, wc, chooser: widget.chooser)),
      ]),
    ];
    return ColoredBox(
      color: context.c.desk,
      child: CustomScrollView(
        key: const ValueKey('moneyPage'),
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, 8),
            sliver: SliverList(delegate: SliverChildListDelegate(gapped(head, gap: 12))),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(pagePad, 0, pagePad, pageBottomPad),
            sliver: SliverList.builder(
              itemCount: _entries.length + 1,
              itemBuilder: (context, i) => i == 0
                  ? _ComingHead(held: tl.held, cur: cur, n: tl.up.length, onTap: () => openUpcoming(context, UpcomingView(wc)))
                  : _row(context, _entries[i - 1], cur),
            ),
          ),
        ],
      ),
    );
  }

  List<_Entry> _flatten(MoneyTimeline tl, String today) => [
        for (final u in tl.up) _Entry('up', up: u),
        const _Entry('today'),
        for (final d in tl.days) ...[
          if (d.date != today) _Entry('day', date: d.date),
          for (final t in d.rows) _Entry('tx', tx: t),
        ],
      ];

  Widget _row(BuildContext context, _Entry e, String cur) {
    final wc = widget.wc;
    switch (e.kind) {
      case 'up':
        return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _UpRow(row: e.up!, cur: cur, today: wc.today(), onTap: () => _openUp(context, e.up!)));
      case 'today':
        return _TodayLine(
            date: wc.today(),
            none: _entries.length == 1
                ? (_filter != MoneyFilter.all || _account != null ? 'Nothing matches this filter.' : _emptyNote)
                : null);
      case 'day':
        return Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
            child: Text(weekdayShortDate(e.date!),
                key: ValueKey('moneyDay:${e.date}'), style: TextStyle(fontWeight: FontWeight.w600, color: context.c.ink2)));
      default:
        final t = e.tx!;
        return ColoredBox(
          color: context.c.surface,
          child: TxTile(
              key: ValueKey('moneyTx:${t.tx.id}'),
              table: wc.categoryTable,
              tagTable: wc.tagTable,
              t: wc.shown(t),
              currency: cur,
              fxRates: wc.settings.fxRates,
              hasBill: wc.billForTx(t.tx.id) != null,
              matched: wc.isMatchedBank(t.tx.id),
              iouTag: wc.iouTagOf(t.tx.id),
              splitCount: wc.splitCount(t.tx.id),
              splitBroken: wc.splitIsBroken(t.tx.id),
              onTap: () async {
                final r = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                if (context.mounted) txSheetToast(context, wc, r);
              }),
        );
    }
  }

  static const _emptyNote = 'No payments yet. Add one with the + button, or import your bank files in Settings.';

  /// A row opens the sheet it had on the old pages.
  Future<void> _openUp(BuildContext context, MoneyUpRow r) async {
    final wc = widget.wc;
    logNav('money.openUp', {'tag': r.tag});
    final i = r.item;
    if (r.tx != null) {
      final res = await showSheet<String>(context, TxSheet(wc: wc, t: r.tx!));
      if (context.mounted) txSheetToast(context, wc, res);
      return;
    }
    if (r.income != null) return openRecurringForm(context, wc, edit: r.income!.bill, income: true);
    if (i == null) return;
    if (i.billDb != null) return openBill(context, wc, i.billDb!.id, chooser: widget.chooser);
    if (i.kind == UpcomingKind.suggestion) return openUpcoming(context, UpcomingView(wc));
    final p = i.planned;
    if (p == null) {
      if (i.bill != null) return openRecurringForm(context, wc, edit: i.bill);
      return;
    }
    if (p.isBill) return openBill(context, wc, p.sourceRef!, chooser: widget.chooser);
    final res = await UpcomingView(wc).showEntry(context, p);
    if (!context.mounted || res == null) return;
    final msg = plannedEntryToast(res);
    if (msg.isEmpty) return;
    if (res == 'paid' || res == 'skipped') {
      toast(context, msg, actionLabel: 'Undo', onAction: () => wc.reopenPlanned(p));
    } else {
      toast(context, msg);
    }
  }
}

class _AccountCard extends StatelessWidget {
  final String name, balance;
  final bool on;
  final VoidCallback onTap;
  const _AccountCard({super.key, required this.name, required this.balance, required this.on, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      selected: on,
      label: '$name, $balance',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: on ? c.accentSoft : c.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14), side: BorderSide(color: on ? c.accent : c.line, width: on ? 2 : 1)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 120, minHeight: touchMin),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
                Text(balance, style: numStyle.copyWith(fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Per month and per year of the confirmed bills, one line; a tap opens Bills & slips.
class _CostStrip extends StatelessWidget {
  final ({int monthly, int yearly, bool approximate}) cost;
  final String cur;
  final VoidCallback onTap;
  const _CostStrip({required this.cost, required this.cur, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget one(String label, int cents, Key key) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
          Text(
              key: key,
              '${cost.approximate ? 'about ' : ''}${moneyExact(cents, cur)}',
              style: numStyle.copyWith(fontWeight: FontWeight.w600)),
        ]);
    return Semantics(
      button: true,
      onTap: onTap,
      child: Material(
        key: const ValueKey('recurringCost'),
        color: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: c.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: touchMin),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Wrap(spacing: 24, runSpacing: 6, children: [
                one('Bills per month', cost.monthly, const ValueKey('costMonth')),
                one('Bills per year', cost.yearly, const ValueKey('costYear')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComingHead extends StatelessWidget {
  final int held, n;
  final String cur;
  final VoidCallback onTap;
  const _ComingHead({required this.held, required this.cur, required this.n, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        key: const ValueKey('comingUpPanel'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: touchMin),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            child: HeadingRow(
                Text('COMING UP TO PAYDAY ›', style: BwType.eyebrow.copyWith(color: context.c.muted)),
                n == 0 && held == 0
                    ? const Muted('Nothing due')
                    : Text('${moneyExact(held, cur)} held',
                        key: const ValueKey('moneyHeld'), style: numStyle.copyWith(color: context.c.ink2))),
          ),
        ),
      );
}

/// A coming-up row: dashed outline, the date, the name with its kind, the signed amount.
class _UpRow extends StatelessWidget {
  final MoneyUpRow row;
  final String cur, today;
  final VoidCallback onTap;
  const _UpRow({required this.row, required this.cur, required this.today, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return CustomPaint(
      painter: DashedBorderPainter(color: c.lineStrong, radius: 12, width: 1, dash: 4),
      child: InkWell(
        key: ValueKey('up:${row.key}'),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: touchMin + 4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: SplitRow(
              start: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                SizedBox(
                    width: 64, child: Text(shortDateOrRaw(row.date), style: numStyle.copyWith(fontSize: BwType.metaSize, color: c.ink2))),
                Expanded(
                  child: Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(row.title, style: const TextStyle(fontWeight: FontWeight.w500)),
                    Tag(row.tag),
                    if (row.late) StatusLabel(key: ValueKey('upLate:${row.key}'), good: false, text: 'Overdue'),
                  ]),
                ),
              ]),
              maxEnd: 0.4,
              end: row.cents == null
                  ? Text('reminder', textAlign: TextAlign.end, style: TextStyle(fontSize: BwType.metaSize, color: c.muted))
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(moneyExactSigned(row.cents!, cur), style: numStyle.copyWith(color: row.cents! > 0 ? c.good : c.ink))),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Today" line between what is coming and what was paid.
class _TodayLine extends StatelessWidget {
  final String date;
  final String? none;
  const _TodayLine({required this.date, this.none});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(key: const ValueKey('moneyToday'), children: [
          Expanded(child: SizedBox(height: 1, child: CustomPaint(painter: _Rule(c.accent)))),
          // flex 100: the label gets its whole width before the two rules share what is left.
          Flexible(
            flex: 100,
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('TODAY · ${shortDateOrRaw(date).toUpperCase()}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: BwType.eyebrow.copyWith(color: c.accent))),
          ),
          Expanded(child: SizedBox(height: 1, child: CustomPaint(painter: _Rule(c.accent)))),
        ]),
        if (none != null) Padding(padding: const EdgeInsets.only(top: 12), child: EmptyNote(none!)),
      ]),
    );
  }
}

class _Rule extends CustomPainter {
  final Color color;
  const _Rule(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0.5), Offset((x + 4).clamp(0, size.width), 0.5), p);
    }
  }

  @override
  bool shouldRepaint(_Rule old) => old.color != color;
}
