// Every component of the dashboard kit (lib/src/widgets/dash.dart) with synthetic numbers, in one scroll view. Used by
// test/dash_kit_test.dart (layout, exact cents, states) and integration_test/dash_gallery_test.dart (screenshots). Not shipped.
import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/theme.dart';
import 'package:budget_wallet/src/widgets/dash.dart';
import 'package:flutter/material.dart';

String _m(int cents) => moneyExact(cents, 'EUR');

class DashGallery extends StatelessWidget {
  /// Counts taps on tiles (tests).
  final void Function(String name)? onTap;
  const DashGallery({super.key, this.onTap});

  VoidCallback _tap(String n) => () => onTap?.call(n);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final split = [
      DashSegment(label: 'Fixed', value: _m(84800), weight: 848, color: c.s2),
      DashSegment(label: 'Saved', value: _m(35000), weight: 350, color: c.s3),
      DashSegment(label: 'Spending', value: _m(62205), weight: 622, color: c.s1),
    ];
    return ColoredBox(
      color: c.desk,
      child: SizedBox.expand(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: DashGrid(children: [
                  DashItem(
                    span: 2,
                    child: StatTile(
                      key: const ValueKey('hero'),
                      label: 'Left to spend',
                      value: _m(132047),
                      sub: '${_m(4126)} a day for 32 days',
                      chip: const StateChip.onPace(),
                      visual: const Sparkline(values: [9, 8.2, 7.9, 6.1, 6.4, 5.2, 4.8, 4.9, 3.7], semanticLabel: 'Money left each day'),
                      onTap: _tap('hero'),
                    ),
                  ),
                  StatTile(
                      label: 'Spent today',
                      value: _m(3890),
                      sub: 'Most: groceries',
                      chip: const DeltaChip(trend: Trend.up, text: '12 % vs avg', good: false)),
                  StatTile(label: 'Kept', value: _m(18016), chip: const DeltaChip(trend: Trend.down, text: '4 % vs last', good: false)),
                  StatTile(
                      label: 'Before payday',
                      value: _m(48230),
                      sub: '3 bills, 2 planned',
                      chip: const StateChip.date('10 Nov'),
                      onTap: _tap('before')),
                  StatTile(label: 'Held', value: _m(421005), sub: '2 accounts', chip: const StateChip.held()),
                  StatTile(label: 'Over budget', value: _m(61250), sub: 'Eating out', chip: const StateChip.over(), valueColor: c.bad),
                  StatTile(label: 'In this period', value: _m(210000), chip: const DeltaChip(trend: Trend.flat, text: 'same as last')),
                  RingTile(
                    label: 'Holiday',
                    center: '62 %',
                    value: _m(186000),
                    sub: 'of ${_m(300000)}, done in Mar',
                    progress: 0.62,
                    color: c.s3,
                    onTap: _tap('goal'),
                  ),
                  const RingTile(label: 'Period', center: '68 %', value: '22 days', sub: '10 left', progress: 0.68),
                  DashItem(
                    span: 2,
                    child: Tile(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        const TileLabel('Salary split'),
                        const SizedBox(height: 10),
                        Center(
                          child: Donut(
                            segments: split,
                            center: Text('${_m(155205)}\nplan',
                                textAlign: TextAlign.center, style: dashNumStyle(size: BwType.metaSize, color: c.ink)),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  DashItem(
                    span: 2,
                    child: Tile(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        const TileLabel('Where the salary goes'),
                        const SizedBox(height: 10),
                        SplitBar(segments: split),
                      ]),
                    ),
                  ),
                  DashItem(
                    span: 2,
                    child: Tile(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        const TileLabel('Budgets'),
                        const SizedBox(height: 6),
                        BarList(rows: [
                          BarRow(label: 'Groceries', value: _m(25200), note: '${_m(4800)} left', fraction: 0.84, onTap: _tap('groceries')),
                          BarRow(label: 'Transport', value: _m(11030), note: '${_m(3970)} left', fraction: 0.74, color: c.s2),
                          BarRow(label: 'Eating out', value: _m(11205), note: 'Over by ${_m(2205)}', fraction: 1.24, over: true),
                        ]),
                      ]),
                    ),
                  ),
                  const DashItem(
                    span: 2,
                    child: Tile(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        TileLabel('Kept per period'),
                        SizedBox(height: 10),
                        NetBars(currency: 'EUR', bars: [
                          NetBar(label: 'Jun', cents: 21000),
                          NetBar(label: 'Jul', cents: -8000),
                          NetBar(label: 'Aug', cents: 15000),
                          NetBar(label: 'Sep', cents: 30000),
                          NetBar(label: 'Oct', cents: 18016, running: true),
                        ]),
                      ]),
                    ),
                  ),
                  DashItem(
                    span: 2,
                    child: Tile(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        const TileLabel('Until payday'),
                        const SizedBox(height: 10),
                        CalendarStrip(
                          semanticLabel: 'Until payday: bills on the 2nd and 7th, planned cost on the 4th, payday on the 10th',
                          days: [
                            for (var d = 30; d <= 31; d++) CalDay('$d', today: d == 30, kind: d == 31 ? CalKind.bill : CalKind.none),
                            for (var d = 1; d <= 10; d++)
                              CalDay('$d',
                                  kind: switch (d) {
                                    2 || 7 => CalKind.bill,
                                    4 => CalKind.planned,
                                    10 => CalKind.payday,
                                    _ => CalKind.none,
                                  }),
                          ],
                        ),
                      ]),
                    ),
                  ),
                  DashItem(
                    span: 2,
                    child: Tile(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        const TileLabel('Expected bills'),
                        DashRows(rows: [
                          DashRowData(
                              title: 'Rent', amount: _m(55000), sub: '1 Nov', chip: const StateChip.date('1 Nov'), onTap: _tap('rent')),
                          DashRowData(title: 'Phone', amount: _m(1299), sub: 'Paid 2 Oct', chip: const StateChip.onPace(text: 'Paid')),
                          DashRowData(title: 'Insurance', amount: _m(8420), sub: 'Late', chip: const StateChip.over(text: 'Overdue')),
                        ]),
                      ]),
                    ),
                  ),
                  AddTile(label: 'Goal', onTap: _tap('add')),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
