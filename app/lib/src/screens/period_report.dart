// RX7: the Pay-period report, "How did the pay period go?" (Paper Tiles, docs/design/dashboard/CONCEPT.md §3/§5). Opened from the
// period chip in the app bar and the badge in the rail; ‹ › step through the last 12 pay periods, starting on the running one.
// Every figure comes from wallet_core through the controller (`periodReportsFor`, `periodDaySpendFor`, `reviewsBetween`,
// `savedBetween`); the page only formats them. The only arithmetic here is display shading of the heatmap (`heatLevel`).
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/charts.dart' show DayDots;
import '../widgets/common.dart';
import '../widgets/dash.dart';
import '../widgets/sheets.dart';

/// Opens the report (a page on a phone, a dialog from 600 dp).
Future<void> openPeriodReport(BuildContext context, WalletController wc) =>
    openPageOrDialog<void>(context, PeriodReportScreen(wc), width: 840, logName: 'periodReport');

/// How dark a day's square is, 0 = empty (nothing spent, or a net refund) to 4 = the biggest days: [spent] against the period's
/// [biggest] day. Display only: no verdict.
int heatLevel(int spent, int biggest) {
  if (spent <= 0 || biggest <= 0) return 0;
  return ((spent * 4 + biggest - 1) ~/ biggest).clamp(1, 4);
}

class PeriodReportScreen extends StatefulWidget {
  final WalletController wc;
  const PeriodReportScreen(this.wc, {super.key});
  @override
  State<PeriodReportScreen> createState() => _PeriodReportScreenState();
}

class _PeriodReportScreenState extends State<PeriodReportScreen> {
  /// The shown period's start; null = the running (last) one.
  String? _start;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.wc,
        builder: (context, _) {
          final wc = widget.wc, c = context.c;
          final reports = wc.periodReportsFor(count: 12);
          var i = _start == null ? reports.length - 1 : reports.indexWhere((r) => r.start == _start);
          if (i < 0) i = reports.length - 1;
          void go(int to) {
            logNav('periodReport.step', {'dir': to < i ? 'prev' : 'next'});
            setState(() => _start = to == reports.length - 1 ? null : reports[to].start);
          }

          return Scaffold(
            backgroundColor: c.desk,
            appBar: const DialogAppBar(title: 'Pay period'),
            body: ColoredBox(
              color: c.desk,
              child: reports.isEmpty
                  ? const EmptyNote('No salary found yet.')
                  : Column(children: [
                      _Stepper(
                        report: reports[i],
                        today: wc.today(),
                        paydayDay: wc.settings.paydayDay,
                        onPrev: i > 0 ? () => go(i - 1) : null,
                        onNext: i < reports.length - 1 ? () => go(i + 1) : null,
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          key: const ValueKey('periodReportPage'),
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                          child: _Tiles(wc: wc, report: reports[i], previous: i > 0 ? reports[i - 1] : null),
                        ),
                      ),
                    ]),
            ),
          );
        },
      );
}

/// ‹ name › and, for the running period, its one state chip.
class _Stepper extends StatelessWidget {
  final PeriodReport report;
  final VoidCallback? onPrev, onNext;
  final String today;
  final int paydayDay;
  const _Stepper({required this.report, required this.today, required this.paydayDay, required this.onPrev, required this.onNext});

  /// The running report's expected payday came and no salary row has started a new period.
  bool get _late => nextPayday(report.start, paydayDay).compareTo(today) <= 0;

  /// Days from today to this report's own end (exclusive), not Today's period: that one may have ended already.
  int _daysLeft() => daysBetween(today, report.end);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Row(children: [
          IconButton(key: const ValueKey('reportPrev'), icon: const Icon(Icons.chevron_left), tooltip: 'Earlier period', onPressed: onPrev),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(dateRange(report.start, report.end),
                    key: const ValueKey('reportTitle'),
                    maxLines: 1,
                    style: TextStyle(fontSize: BwType.headingSize, fontWeight: FontWeight.w600, color: context.c.ink)),
              ),
              if (report.running)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  // The title already has the dates: the chip only says it is running and how long it has to go.
                  child: _late
                      ? const StateChip.over(text: 'Salary late', key: ValueKey('reportLate'))
                      : StateChip.date('Running · ${_daysLeft()} ${_daysLeft() == 1 ? 'day' : 'days'} left',
                          key: const ValueKey('reportRunning')),
                ),
            ]),
          ),
          IconButton(key: const ValueKey('reportNext'), icon: const Icon(Icons.chevron_right), tooltip: 'Later period', onPressed: onNext),
        ]),
      );
}

class _Tiles extends StatelessWidget {
  final WalletController wc;
  final PeriodReport report;
  final PeriodReport? previous;
  const _Tiles({required this.wc, required this.report, required this.previous});

  DashChip? _delta() {
    final prev = previous;
    // A running period is partial: 3 days of spending against a whole period before would always look "better".
    if (prev == null || report.running) return null;
    final change = changePermille(report.out, prev.out);
    if (change == null) return null;
    final name = dateRange(prev.start, prev.end);
    // Under half a percent is the same as before: a flat chip, never "0 % worse". Spending less is the good direction.
    if (change.abs() < 5) return DeltaChip(key: const ValueKey('reportDelta'), trend: Trend.flat, text: 'Out same as $name');
    return DeltaChip(
        key: const ValueKey('reportDelta'),
        trend: change > 0 ? Trend.up : Trend.down,
        text: 'Out ${(change.abs() + 5) ~/ 10} % vs $name',
        good: change < 0);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c, cur = wc.currency, r = report;
    final reviews = wc.reviewsBetween(r.start, r.end).length;
    final saved = wc.savedBetween(r.start, r.end);
    final days = wc.periodDaySpendFor(r.start, r.end);
    return DashGrid(children: [
      DashItem(
        span: 2,
        child: HeroTile(
          key: const ValueKey('reportHero'),
          valueKey: const ValueKey('reportKept'),
          label: 'Kept',
          value: moneyExact(r.net, cur),
          valueColor: r.net < 0 ? c.bad : null,
          chip: _delta(),
        ),
      ),
      StatTile(key: const ValueKey('reportIn'), label: 'In', value: moneyExact(r.income, cur)),
      StatTile(key: const ValueKey('reportOut'), label: 'Out', value: moneyExact(r.out, cur)),
      DashItem(
        span: 2,
        child: Tile(
          key: const ValueKey('reportSplit'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const TileLabel('Fixed vs flexible'),
            const SizedBox(height: 10),
            SplitBar(segments: [
              DashSegment(label: 'Fixed', value: moneyExact(r.fixed, cur), weight: r.fixed.toDouble(), color: c.s2),
              DashSegment(label: 'Flexible', value: moneyExact(r.flex, cur), weight: r.flex.toDouble(), color: c.s1),
            ]),
          ]),
        ),
      ),
      DashItem(
        span: 2,
        child: _Heatmap(key: ValueKey('reportHeatmap:${r.start}'), days: days, today: r.running ? wc.today() : null, currency: cur),
      ),
      StatTile(key: const ValueKey('reportReviews'), label: 'Reviews', value: '$reviews'),
      StatTile(
        key: const ValueKey('reportSaved'),
        label: 'Saved by waiting',
        value: moneyExact(saved.cents, cur),
        sub: saved.count == 0 ? 'None skipped' : '${saved.count} skipped',
      ),
    ]);
  }
}

/// One square per day of the period, shaded by the flexible money spent that day (relative to the period's biggest day). A tap on a
/// square shows that day's exact amount; before any tap the readout shows the biggest day. No verdict: nothing is "over".
class _Heatmap extends StatefulWidget {
  final List<DaySpend> days;

  /// The date of today while the period is running (later days are "to come"), else null.
  final String? today;
  final String currency;
  const _Heatmap({super.key, required this.days, required this.today, required this.currency});
  @override
  State<_Heatmap> createState() => _HeatmapState();
}

class _HeatmapState extends State<_Heatmap> {
  String? _picked;

  static const _alphas = [0.3, 0.5, 0.75, 1.0];

  DaySpend? get _biggest {
    DaySpend? best;
    for (final d in widget.days) {
      if (d.spent > 0 && !_toCome(d) && (best == null || d.spent > best.spent)) best = d;
    }
    return best;
  }

  bool _toCome(DaySpend d) => widget.today != null && d.date.compareTo(widget.today!) > 0;

  String _spoken() {
    final days = widget.days, spendDays = days.where((d) => d.spent > 0 && !_toCome(d)).length, toCome = days.where(_toCome).length;
    final best = _biggest;
    final head = '${days.length} days, ${spendDays == 0 ? 'no spending' : 'spending on $spendDays'}';
    final big = best == null ? '' : ', biggest day ${shortDate(best.date)}, ${moneyExact(best.spent, widget.currency)}';
    return '$head$big${toCome > 0 ? ', $toCome to come' : ''}';
  }

  Color _fill(WalletColors c, int level) =>
      level == 0 ? c.surface2 : Color.alphaBlend(c.s1.withValues(alpha: _alphas[level - 1]), c.surface);

  @override
  Widget build(BuildContext context) {
    final c = context.c, days = widget.days;
    final best = _biggest, biggest = best?.spent ?? 0;
    final shown = _picked == null ? best : days.where((d) => d.date == _picked).firstOrNull;
    const sq = DayDots.square, gap = DayDots.gap;
    final offset = days.isEmpty ? 0 : DateTime.parse(days.first.date).weekday - 1; // Monday = 0
    final rows = (offset + days.length + 6) ~/ 7;

    Widget cell(DaySpend d) {
      final Widget box = _toCome(d)
          ? DecoratedBox(decoration: BoxDecoration(border: Border.all(color: c.lineStrong)))
          : DecoratedBox(
              decoration: BoxDecoration(
                  color: _fill(c, heatLevel(d.spent, biggest)), border: d.date == shown?.date ? Border.all(color: c.ink, width: 2) : null));
      final square = SizedBox(key: ValueKey('heatDay:${d.date}'), width: sq, height: sq, child: box);
      // A day to come has nothing to show: no tap, no amount.
      if (_toCome(d)) return square;
      return GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => setState(() => _picked = d.date), child: square);
    }

    final grid = Semantics(
      container: true,
      label: _spoken(),
      excludeSemantics: true,
      child: SizedBox(
        key: const ValueKey('heatGrid'),
        width: DayDots.width,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var r = 0; r < rows; r++)
            Padding(
              padding: EdgeInsets.only(top: r == 0 ? 0 : gap),
              child: Row(children: [
                for (var col = 0; col < 7; col++) ...[
                  if (col > 0) const SizedBox(width: gap),
                  () {
                    final i = r * 7 + col - offset;
                    return i >= 0 && i < days.length ? cell(days[i]) : const SizedBox(width: sq, height: sq);
                  }(),
                ],
              ]),
            ),
        ]),
      ),
    );

    final readout = shown == null
        ? const SizedBox.shrink()
        : Column(
            key: const ValueKey('heatReadout'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
                Text(shortDate(shown.date), style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(moneyExact(shown.spent, widget.currency),
                      key: const ValueKey('heatAmount'), maxLines: 1, style: dashNumStyle(size: 22, color: c.ink)),
                ),
              ]);

    final legend = Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text('Less', style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
      for (var l = 0; l <= 4; l++) Container(width: 10, height: 10, color: _fill(c, l)),
      Text('More', style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
    ]);

    return Tile(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const TileLabel('Flexible spending'),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, box) {
          final side = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [readout, const SizedBox(height: 12), legend]);
          if (box.maxWidth >= DayDots.width + 16 + 120) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [grid, const SizedBox(width: 16), Expanded(child: side)]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [grid, const SizedBox(height: 12), side]);
        }),
      ]),
    );
  }
}
