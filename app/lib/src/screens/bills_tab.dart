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
import '../widgets/jump_when_built.dart';
import '../widgets/rebuild_when_shown.dart';
import 'bills_panel.dart';
import 'habits_panels.dart';
import 'recurring_sheet.dart';
import 'scan_bill.dart';

/// The Bills tab (P5): what is due before payday, the slips to review, the expected (repeating) bills and the bills database,
/// with Scan bill (where there is a camera) and Add bill on top. The panels are the ones that used to be in Plan.
class BillsScreen extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;

  /// A link (Today's bills lines) asks for a place on this page.
  final JumpRequest<BillsAnchor>? request;
  const BillsScreen({super.key, required this.wc, this.chooser = const FileChooser(), this.request});
  @override
  State<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends State<BillsScreen> {
  final _scroll = ScrollController();
  final Map<BillsAnchor, GlobalKey> _keys = {for (final a in BillsAnchor.values) a: GlobalKey()};

  @override
  void initState() {
    super.initState();
    widget.request?.addListener(_jump);
    jumpWhenBuilt(widget.request, () => mounted, _jump); // a link that opened this tab before its page existed
  }

  @override
  void didUpdateWidget(BillsScreen old) {
    super.didUpdateWidget(old);
    if (old.request != widget.request) {
      old.request?.removeListener(_jump);
      widget.request?.addListener(_jump);
    }
  }

  @override
  void dispose() {
    widget.request?.removeListener(_jump);
    _scroll.dispose();
    super.dispose();
  }

  /// The page is a plain column, so every panel is built: scrolling to one needs no paging.
  Future<void> _jump() async {
    final a = widget.request?.value;
    if (a == null) return;
    await WidgetsBinding.instance.endOfFrame;
    final c = _keys[a]!.currentContext;
    if (!mounted || c == null || !c.mounted) return;
    await Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250));
  }

  // Rebuilds on every change of the controller while shown, like the Plan tab did (the panels read the wallet in build(); a
  // device-local switch changes no data version). Hidden, it waits until it is shown or the shell gives it new data.
  @override
  Widget build(BuildContext context) => RebuildWhenShown(listenable: widget.wc, builder: _page);

  Widget _page(BuildContext context) {
    final wc = widget.wc;
    final review = wc.billLists().review;
    return NarrowPage(
      child: SingleChildScrollView(
        key: const ValueKey('billsPage'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: gapped([
            KeyedSubtree(key: _keys[BillsAnchor.comingUp], child: _Actions(wc: wc, chooser: widget.chooser)),
            ComingUpPanel(wc: wc),
            if (review.isNotEmpty)
              KeyedSubtree(
                key: _keys[BillsAnchor.review],
                child: Panel(key: const ValueKey('billsReviewPanel'), children: [
                  SectionHead('To review', trailing: Tag('${review.length}')),
                  const Muted('Read from a code, file or photo. Nothing counts until you check and confirm it.'),
                  Rows(children: [for (final b in review) BillRow(wc: wc, chooser: widget.chooser, bill: b)]),
                ]),
              ),
            KeyedSubtree(key: _keys[BillsAnchor.expected], child: ExpectedBillsPanel(wc: wc)),
            KeyedSubtree(key: _keys[BillsAnchor.slips], child: BillsPanel(wc: wc, chooser: widget.chooser, showReview: false)),
          ]),
        ),
      ),
    );
  }
}

/// Scan bill (only where there is a camera) and Add bill (a repeating bill).
class _Actions extends StatelessWidget {
  final WalletController wc;
  final FileChooser chooser;
  const _Actions({required this.wc, required this.chooser});
  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        if (wc.billInputs.camera.supported)
          OutlinedButton.icon(
            key: const ValueKey('billsScan'),
            style: accentOutlined(context),
            icon: const Icon(Icons.document_scanner_outlined),
            label: const Text('Scan bill'),
            onPressed: () {
              logNav('bills.scanTab');
              scanBillFlow(context, wc, chooser: chooser);
            },
          ),
        OutlinedButton.icon(
          key: const ValueKey('billsAdd'),
          style: accentOutlined(context),
          icon: const Icon(Icons.add),
          label: const Text('Add bill'),
          onPressed: () {
            logNav('bills.addTab');
            openRecurringForm(context, wc);
          },
        ),
      ]);
}

/// "N bills before payday: total", then each bill with its due date and what it sets aside. The numbers are core's (`dueCycles`,
/// the same as Today's "Due by payday" line); a bill in a plan line is listed as covered and not added; a long bill after payday
/// says it is held until paid.
class ComingUpPanel extends StatelessWidget {
  final WalletController wc;
  const ComingUpPanel({super.key, required this.wc});

  static String _name(RecurringBill b) => b.label.isNotEmpty ? b.label : b.payee;

  @override
  Widget build(BuildContext context) {
    final p = wc.period();
    final cur = wc.currency, today = wc.today();
    final table = wc.categoryTable;
    bool held(DueCycle x) => x.bill.isLong && x.due.compareTo(p.end) >= 0;
    final soon = [
      for (final x in p.dueCycles)
        if (!held(x)) x
    ];
    final heldCycles = [
      for (final x in p.dueCycles)
        if (held(x) && x.reserve > 0) x
    ];
    final counted = [
      for (final x in soon)
        if (!x.coveredIn(table)) x
    ];
    final billCount = {for (final x in counted) x.bill.id}.length;
    final reserved = counted.fold<int>(0, (s, x) => s + x.reserve);
    final heldTotal = heldCycles.fold<int>(0, (s, x) => s + x.reserve);
    final payments = counted.length > billCount ? ' (${counted.length} payments)' : '';
    final shown = [...soon]..sort((a, b) => a.due.compareTo(b.due));
    return Panel(key: const ValueKey('comingUpPanel'), children: [
      const SectionHead('Coming up'),
      if (shown.isEmpty && heldCycles.isEmpty)
        const EmptyNote('No bills due before payday. Bills get here when you add one, scan a slip or import a bill file.')
      else ...[
        Heading(
            billCount > 0
                ? '$billCount ${billCount == 1 ? 'bill' : 'bills'}$payments before payday: ${moneyExact(reserved, cur)}'
                : heldCycles.isNotEmpty
                    ? 'Held until paid: ${moneyExact(heldTotal, cur)}'
                    : 'Nothing to set aside before payday',
            key: const ValueKey('comingUpHeading')),
        const Muted('These come off your daily money until they are paid.'),
        if (shown.isNotEmpty)
          Rows(children: [
            for (final x in shown)
              LineItem(_name(x.bill), moneyExact(x.reserve, cur),
                  key: ValueKey('comingUp:${x.bill.id}:${x.due}'),
                  sub: [
                    'Due ${shortDateOrRaw(x.due)}',
                    if (x.due.compareTo(today) < 0) 'overdue',
                    if (x.coveredIn(table)) 'covered by your plan, not added',
                  ].join(' · ')),
          ]),
        for (final x in heldCycles)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('${_name(x.bill)} ${moneyExact(x.reserve, cur)} held until paid',
                key: ValueKey('comingHeld:${x.bill.id}'), style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
          ),
      ],
    ]);
  }
}
