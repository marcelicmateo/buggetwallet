// Idle warm-up in the controller: the list of derived values the five tabs ask for first, worked out one memo per idle task after
// the first frame and after every data or day change (see warm_up.dart), so the first visit of a tab finds them ready.
// A `part` of controller.dart so it can use the cache.
//
// Privacy: task names are fixed words; the log line (`warmup.done`) carries counts and milliseconds only.
part of 'controller.dart';

extension WarmUpTasks on WalletController {
  /// The steps, cheapest and most visible first: Today, Budget, Bills, Save, then the default Insights ranges (the heaviest: they
  /// read every row of the range). One call per step, so no frame waits for more than one memo. A step that throws is logged
  /// by name and skipped.
  List<WarmTask> warmUpTasks() {
    final month = monthOf(today());
    return <WarmTask>[
      ('period', period),
      ('periodDays', this.periodDays),
      ('heldTotals', heldTotals),
      ('tightestBudget', tightestBudget),
      ('comingUp', comingUp),
      ('reviewState', this.reviewState),
      ('billLists', billLists),
      ('paydayForecast', paydayForecast),
      ('balanceWarnings', balanceWarningList),
      ('headsUps', headsUpLines),
      ('deliveries', () => deliveries),
      ('deliveryOrders90', () => deliveryOrders90),
      ('payPeriods', () => payPeriods(count: 12)),
      ('spending', spending),
      ('budgetVsActual', () => this.budgetVsActual(month)),
      ('paceRows', paceRows),
      ('expectedBills', expectedBills),
      ('expectedIncomes', expectedIncomes),
      ('recurringPayments', recurringPayments),
      ('billsCost', billsCost),
      ('owedTotals', owedTotals),
      ('latestBySource', () => latestBySource),
      ('goalTargetTotal', () => goalTargetTotal),
      for (final id in insightGraphs) ('insights.$id', () => _warmInsight(id)),
    ];
  }

  /// The default range of one Insights graph and the data its panel draws from it.
  void _warmInsight(String id) {
    final r = insightRange(id).range;
    switch (id) {
      case 'spending':
        spendingBars(r);
      case 'share':
        shareFor(r);
      case 'tags':
        tagShareFor(r);
      case 'income':
        incomeBars(r);
      case 'budget':
        budgetBars(r);
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
