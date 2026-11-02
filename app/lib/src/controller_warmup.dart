// Idle warm-up in the controller: the list of derived values the four destinations ask for first, worked out one memo per idle task after
// the first frame and after every data or day change (see warm_up.dart), so the first visit of a tab finds them ready.
// A `part` of controller.dart so it can use the cache.
//
// Privacy: task names are fixed words; the log line (`warmup.done`) carries counts and milliseconds only.
part of 'controller.dart';

extension WarmUpTasks on WalletController {
  /// The steps one tab needs, cheapest and most visible first. One call per step (a month of the Spending figures counts as one),
  /// so no frame waits for more than one memo. A step that throws is logged by name and skipped. A value several tabs read is
  /// listed in each: the second time it is only a cache hit.
  List<WarmTask> warmUpTasksFor(int tab) {
    final month = monthOf(today());
    return switch (tab) {
      Tabs.overview => <WarmTask>[
          ('period', period),
          ('periodDays', this.periodDays),
          ('heldTotals', heldTotals),
          ('tightestBudget', tightestBudget),
          ('comingUp', comingUp),
          ('reviewState', this.reviewState),
          ('balanceWarnings', balanceWarningList),
          ('headsUps', headsUpLines),
          ('deliveries', () => deliveries),
          ('deliveryOrders90', () => deliveryOrders90),
          ('latestBySource', () => latestBySource),
          ('findings', foundCards),
          ('nearestGoal', nearestGoal),
          for (final v in pinnedViews()) ('pin', () => pinData(v)),
        ],
      Tabs.explore => <WarmTask>[
          ('exploreIndex', () => exploreIndex),
          ('exploreQuery', () => exploreRows(exploreDefaultQuery())), // the Explore page's first build
          ('period', period),
          ('payPeriods', () => payPeriods(count: 12)),
          for (final m in monthsEnding(month, 13)) ('monthSummary', () => monthSummaryFor(m)),
          ('averageSpending', () => averageSpending(month)),
          ('spending', spending),
          ('budgetVsActual', () => this.budgetVsActual(month)), // Spending's first build reads it
        ],
      Tabs.money => <WarmTask>[
          ('billLists', billLists),
          ('expectedBills', expectedBills),
          ('expectedIncomes', expectedIncomes),
          ('recurringPayments', recurringPayments),
          ('billsCost', billsCost),
        ],
      Tabs.plan => <WarmTask>[
          ('budgetVsActual', () => this.budgetVsActual(month)),
          ('paceRows', paceRows),
          ('paydayForecast', paydayForecast),
          ('owedTotals', owedTotals),
          ('goalTargetTotal', () => goalTargetTotal),
        ],
      _ => const <WarmTask>[],
    };
  }

  /// Every step of every tab, then the default Insights ranges (the heaviest: they read every row of the range).
  List<WarmTask> warmUpTasks() {
    final seen = <String>{};
    return <WarmTask>[
      for (var tab = 0; tab < Tabs.names.length; tab++)
        for (final t in warmUpTasksFor(tab))
          if (t.$1 == 'monthSummary' || t.$1 == 'pin' || seen.add(t.$1)) t,
      for (final id in insightGraphs) ('insights.$id', () => _warmInsight(id)),
    ];
  }

  /// The default range of one Insights graph and the data its panel draws from it.
  void _warmInsight(String id) {
    final r = insightRange(id).range;
    switch (id) {
      case 'spending':
        spendingSeriesFor(r, bucketFor(r)); // builds the day index, which the income and budget graphs read too
      case 'share':
        shareFor(r);
      case 'tags':
        tagShareFor(r);
      case 'income':
        incomeSeriesFor(r, bucketFor(r));
      case 'budget':
        budgetSeriesFor(r, bucketFor(r));
      case 'biggest':
        biggestIn(r);
    }
  }

  /// Starts the warm-up for the current data version and day (the run for an older one ends by itself). [onDone] runs after the
  /// last step, unless the data changed meanwhile. Does nothing while [WarmUp.enabled] is off.
  void startWarmUp({void Function()? onDone}) {
    final version = dataVersion;
    final day = today();
    warmUp.start(warmUpTasks(), current: () => !_disposed && version == dataVersion && day == today(), onDone: onDone);
  }
}
