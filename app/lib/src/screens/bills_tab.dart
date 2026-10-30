import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../tabs.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart';
import '../widgets/jump_when_built.dart';
import '../widgets/rebuild_when_shown.dart';
import 'bills_panel.dart';
import 'habits_panels.dart';
import 'recurring_sheet.dart';
import 'scan_bill.dart';
import 'upcoming.dart';
import 'upcoming_view.dart';

/// The Bills tab (RX5, Paper Tiles): Before payday, the cost per month and per year, the days until payday, the slips to review, the
/// expected (repeating) bills with Scan bill and Add bill, then the bills database.
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
    final cost = wc.billsCost();
    final cur = wc.currency;
    return NarrowPage(
      child: SingleChildScrollView(
        key: const ValueKey('billsPage'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: gapped([
            DashGrid(children: [
              DashItem(span: 2, child: KeyedSubtree(key: _keys[BillsAnchor.comingUp], child: BeforePaydayTile(wc: wc))),
              if (cost != null) ...[
                DashItem(
                    child: StatTile(
                        key: const ValueKey('recurringCost'),
                        label: 'Per month',
                        value: moneyExact(cost.monthly, cur),
                        trailing: cost.approximate ? const TileNote('about') : null)),
                DashItem(
                    child: StatTile(
                        label: 'Per year',
                        value: moneyExact(cost.yearly, cur),
                        trailing: cost.approximate ? const TileNote('about') : null)),
              ],
              if (_hasCalendar(wc)) DashItem(span: 2, child: UntilPaydayTile(wc: wc)),
              if (review.isNotEmpty)
                DashItem(
                  span: 2,
                  child: KeyedSubtree(
                    key: _keys[BillsAnchor.review],
                    child: Tile(
                      key: const ValueKey('billsReviewPanel'),
                      attention: true,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                        HeadingRow(const TileLabel('To review'), TileNote('${review.length} to check')),
                        Rows(children: [for (final b in review) BillRow(wc: wc, chooser: widget.chooser, bill: b)]),
                      ]),
                    ),
                  ),
                ),
              DashItem(
                span: 4, // the whole row, on a wide window too (the grid clamps it to the columns it has)
                child: KeyedSubtree(
                  key: _keys[BillsAnchor.expected],
                  child: ExpectedBillsPanel(wc: wc, trailing: _Actions(wc: wc, chooser: widget.chooser)),
                ),
              ),
            ]),
            KeyedSubtree(key: _keys[BillsAnchor.slips], child: BillsPanel(wc: wc, chooser: widget.chooser, showReview: false)),
          ]),
        ),
      ),
    );
  }

  static bool _hasCalendar(WalletController wc) => _calendarDays(wc).days.any((d) => d.kind == CalKind.bill || d.kind == CalKind.planned);
}

/// Scan bill (only where there is a camera) and Add bill (a repeating bill), in the label row of the Expected bills tile.
class _Actions extends StatelessWidget {
  final WalletController wc;
  final FileChooser chooser;
  const _Actions({required this.wc, required this.chooser});
  @override
  Widget build(BuildContext context) => Wrap(alignment: WrapAlignment.end, children: [
        if (wc.billInputs.camera.supported)
          TileAction(
            key: const ValueKey('billsScan'),
            label: 'Scan bill',
            onTap: () {
              logNav('bills.scanTab');
              scanBillFlow(context, wc, chooser: chooser);
            },
          ),
        TileAction(
          key: const ValueKey('billsAdd'),
          label: 'Add bill',
          onTap: () {
            logNav('bills.addTab');
            openRecurringForm(context, wc);
          },
        ),
      ]);
}

/// "Before payday": the money held for the bills and planned costs due before payday (core's `PeriodBudget.beforePayday`, the same
/// number and label as Today) and how many costs it holds. A tap opens Upcoming, the list with dates.
class BeforePaydayTile extends StatelessWidget {
  final WalletController wc;
  const BeforePaydayTile({super.key, required this.wc});
  @override
  Widget build(BuildContext context) {
    final p = wc.period();
    final n = p.beforePaydayCount;
    return StatTile(
      key: const ValueKey('comingUpPanel'),
      label: 'Before payday',
      value: moneyExact(p.beforePayday, wc.currency),
      sub: n > 0 ? '$n ${n == 1 ? 'cost' : 'costs'}' : 'Nothing due',
      onTap: () {
        logNav('bills.upcoming');
        openUpcoming(context, UpcomingView(wc));
      },
    );
  }
}

/// What the calendar shows: [days] from today to payday (Monday-first with [startWeekday]), and the spoken form.
({List<CalDay> days, int startWeekday, String spoken}) _calendarDays(WalletController wc) {
  final p = wc.period();
  final cur = wc.currency, today = wc.today();
  final end = p.end;
  // Counted costs only (the ones Before payday holds): a bill in a plan line is covered, not set aside again; a long bill held
  // until paid and due after payday is not before payday.
  final table = wc.categoryTable;
  final items = <String, List<({String name, int amount, bool bill})>>{};
  for (final x in p.dueCycles) {
    if (x.coveredIn(table) || x.due.compareTo(today) < 0 || x.due.compareTo(end) >= 0) continue;
    final name = x.bill.label.isNotEmpty ? x.bill.label : x.bill.payee;
    (items[x.due] ??= []).add((name: name, amount: x.reserve, bill: true));
  }
  for (final x in p.reservedPlannedRows) {
    if (x.date.compareTo(today) < 0 || x.date.compareTo(end) >= 0) continue;
    (items[x.date] ??= []).add((name: x.title, amount: x.amount ?? 0, bill: false));
  }
  final days = <CalDay>[];
  final spoken = <String>[];
  for (var d = today; d.compareTo(end) <= 0 && days.length < 62; d = addDays(d, 1)) {
    final label = '${int.parse(d.substring(8))}';
    final here = items[d] ?? const [];
    if (d == end) {
      days.add(CalDay(label, kind: CalKind.payday, today: d == today));
      spoken.add('${shortDateOrRaw(d)}: payday');
    } else if (here.isEmpty) {
      days.add(CalDay(label, today: d == today));
    } else {
      // One item: its amount. Several: how many (the widget adds nothing up).
      days.add(CalDay(label,
          kind: here.any((i) => i.bill) ? CalKind.bill : CalKind.planned,
          today: d == today,
          amount: here.length == 1 ? moneyExact(here.first.amount, cur) : '${here.length}×'));
      spoken.add('${shortDateOrRaw(d)}: ${here.map((i) => i.name).join(', ')}');
    }
  }
  return (days: days, startWeekday: DateTime.parse(today).weekday, spoken: spoken.join('. '));
}

/// The days until payday: a bill is filled, a planned cost dashed, payday flagged. A day with one cost shows its amount, a day with
/// several shows how many. A tap opens Upcoming.
class UntilPaydayTile extends StatelessWidget {
  final WalletController wc;
  const UntilPaydayTile({super.key, required this.wc});
  @override
  Widget build(BuildContext context) {
    final cal = _calendarDays(wc);
    return Tile(
      key: const ValueKey('untilPaydayTile'),
      onTap: () {
        logNav('bills.upcoming');
        openUpcoming(context, UpcomingView(wc));
      },
      semanticLabel: 'Until payday. ${cal.spoken}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        HeadingRow(const TileLabel('Until payday'), TileNote('payday ${shortDateOrRaw(wc.period().end)}')),
        const SizedBox(height: 8),
        IgnorePointer(child: CalendarStrip(days: cal.days, startWeekday: cal.startWeekday)),
      ]),
    );
  }
}
