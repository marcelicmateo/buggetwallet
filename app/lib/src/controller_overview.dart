// What the Overview and Findings screens read (ENG E2/E3, docs/context/ENG_UI_SPEC.md §5.1, §5.2): the € | hours switch, the
// findings with their sentences, the pinned series and the nearest goal. A `part` of controller.dart so it can use the cache.
// Everything is worked out here, once per data version; the widgets only draw it.
//
// Privacy: logs carry counts and kinds only (`findings.shown`, `pin.unpin`), never a name, a query or an amount.
part of 'controller.dart';

final _ovLog = Logger('bw.overview');

/// The most findings shown (spec §5.2: "max ~7").
const maxFindingsShown = 7;

/// One finding with the words around it: [eyebrow] (the kind), [sentence] (one line) and [basis] (period, n, strength).
class FindingCard {
  final Finding finding;
  final String eyebrow, sentence, basis;

  /// The main tag names of a movesTogether finding (the chart's axis names).
  final String subjectName, otherName;
  const FindingCard(this.finding, this.eyebrow, this.sentence, this.basis, {this.subjectName = '', this.otherName = ''});
}

/// One pinned series (a saved view with `pinned`): the bucket values for the sparkline (drawn only), the last bucket's exact
/// [last] (cents, or a count when [isCount]) and the change to the bucket before it in whole percent ([deltaPercent], null without one).
class PinData {
  final String id, name, span;
  final List<double> values;
  final int last;
  final bool isCount;
  final int? deltaPercent;
  const PinData(this.id, this.name, this.span, this.values, this.last, this.isCount, this.deltaPercent);
}

extension OverviewData on WalletController {
  // ---------- € | hours of work ----------

  /// Is there a salary and a work week, so an amount can be shown as hours? Without it the switch is hidden.
  bool get hoursAvailable => hoursTenths(1, settings) != null;

  /// Amounts shown as hours of work on the Overview (device-local, `amountsAs`). Never true without [hoursAvailable].
  bool get showHours => hoursAvailable && repo.localValue('amountsAs') == 'hours';

  void setShowHours(bool on) {
    if (on == (repo.localValue('amountsAs') == 'hours')) return;
    repo.setLocalValue('amountsAs', on ? 'hours' : null);
    logEvent(_ovLog, Level.INFO, 'overview.hours', {'on': on});
    notifyListeners();
  }

  /// [cents] in [cur] as the Overview shows it: hours ("8.4 h") when the switch is on and [cur] is the wallet currency, else exact money.
  String amountText(int cents, String cur) {
    if (!showHours || cur != currency) return moneyExact(cents, cur);
    final t = hoursTenths(cents, settings)!;
    return cents < 0 && t > 0 ? '−${hoursText(t)}' : hoursText(t);
  }

  // ---------- findings ----------

  /// The findings, newest rules first, without the dismissed ones, at most [maxFindingsShown] (core's order).
  // shortcut: one warm-up task for the whole findings run (23 ms on the desktop test wallet, over the 16 ms budget); split core's run when a real wallet shows it.
  List<Finding> foundList() => _cached(
        const MemoKey('findings'),
        () => timed('findings', () {
          final l = findings(txs, settings, categoryTable, today(), reviewDates: repo.reviewDates(), bills: recurringBills());
          logEvent(_ovLog, Level.FINE, 'findings.shown', {'n': l.length});
          return l.take(maxFindingsShown).toList();
        }, warnMs: 16),
      );

  /// Days from the first counted payment to today, inclusive (0 without data).
  int get trackedDays {
    final first = dayIndex.first;
    return first == null ? 0 : daysBetween(first, today()) + 1;
  }

  /// [foundList] with its words, memoized (the sentences read tag and bill names).
  List<FindingCard> foundCards() => _cached(const MemoKey('findingCards'), () => [for (final f in foundList()) _card(f)]);

  /// Hides these findings (one card hides one id, the milestones card up to three) in one write burst.
  void dismissFindings(List<String> ids) {
    for (final id in ids) {
      repo.dismissFinding(id);
    }
    logEvent(_ovLog, Level.INFO, 'finding.dismiss', {'n': ids.length});
    _changed();
  }

  void undismissFindings(List<String> ids) {
    for (final id in ids) {
      repo.undismissFinding(id);
    }
    logEvent(_ovLog, Level.INFO, 'finding.undismiss', {'n': ids.length});
    _changed();
  }

  static const _dayNames = ['Mondays', 'Tuesdays', 'Wednesdays', 'Thursdays', 'Fridays', 'Saturdays', 'Sundays'];

  FindingCard _card(Finding f) {
    String tag(String id) => categoryTable.label(id);
    String ratio(int permille) => '${permille ~/ 1000}${numberStyle.decimal}${(permille % 1000 + 50) ~/ 100 % 10}';
    final last = f.series.isEmpty ? 0 : f.series.last.$2;
    switch (f.kind) {
      case FindingKind.aboveUsual:
        final pct = (f.ratioPermille! - 1000 + 5) ~/ 10;
        return FindingCard(f, 'Above usual', '${tag(f.subjectKey)} is $pct % above your usual month',
            'vs ${f.n}-month median · ${amountText(last, currency)} this month');
      case FindingKind.weeklyRhythm:
        var top = 0;
        for (var i = 1; i < f.series.length; i++) {
          if (f.series[i].$2 > f.series[top].$2) top = i;
        }
        return FindingCard(f, 'Weekly rhythm', '${_dayNames[top]} cost you ${ratio(f.ratioPermille!)}× your cheapest day',
            'Average spend per day of the week, ${f.n} months. Tap a bar.');
      case FindingKind.movesTogether:
        final r = f.strengthPermille!, a = r.abs();
        final word = a >= 700 ? 'strong' : 'fairly strong';
        final strength = '0${numberStyle.decimal}${a ~/ 10}';
        return FindingCard(
            f,
            'Moves together',
            r > 0
                ? '${tag(f.subjectKey)} and ${tag(f.otherKey!)} move together'
                : 'When ${tag(f.subjectKey)} goes up, ${tag(f.otherKey!)} goes down',
            '${f.n} months, link strength $strength of 1: $word.',
            subjectName: tag(f.subjectKey),
            otherName: tag(f.otherKey!));
      case FindingKind.slowCreep:
        final bill = recurringBills().where((b) => b.id == f.subjectKey).firstOrNull;
        final first = f.series.isEmpty ? 0 : f.series.first.$2;
        return FindingCard(
            f,
            'Slow creep',
            '${bill?.payee ?? 'A bill'} went from ${amountText(first, currency)} to ${amountText(last, currency)} a month',
            '${f.n} months of payments, ${(f.ratioPermille! - 1000 + 5) ~/ 10} % up.');
      case FindingKind.seasonality:
        final month = monthLong('2000-${f.otherKey}').split(' ').first;
        return FindingCard(f, 'Seasonality', '$month is your priciest month for ${tag(f.subjectKey)}', 'The top month in ${f.n} years.');
      case FindingKind.milestone:
        final what = switch (f.subjectKey) {
          'days' => 'days tracked',
          'payments' => 'payments',
          _ => 'best streak, weeks',
        };
        return FindingCard(f, 'Milestone', '${groupInt(last)} $what', 'Since ${shortDate(f.from)}.');
    }
  }

  // ---------- pinned series ----------

  /// The day index with the accounts, for saved queries (account series count the rows an account owns).
  DayIndex get queryIndex => _cached(
        const MemoKey('ov.queryIndex'),
        () => timed('overview.queryIndex', () => DayIndex(txs, currency: currency, table: categoryTable, accounts: accountsAll()),
            fields: {'tx': txs.length}, warnMs: 50),
      );

  List<SavedView> pinnedViews() => _cached(
      const MemoKey('ov.pinnedViews'),
      () => [
            for (final v in repo.views())
              if (v.pinned) v
          ]);

  /// A pinned view as a tile; null when this build cannot run its query (written by a newer one) or it has no buckets.
  PinData? pinData(SavedView v) => _cached(MemoKey('ov.pin', (v.id, v.query)), () {
        final q = v.parsed;
        if (q == null) return null;
        final rows = runQuery(queryIndex, q, today: today());
        if (rows.isEmpty) return null;
        final vals = [for (final r in rows) r.together];
        final end = vals.length - 1;
        final prev = end > 0 ? vals[end - 1] : 0;
        // Percent change of the last bucket on the one before, rounded half away from zero in integers.
        final int? delta = prev <= 0 ? null : ((vals[end] - prev) * 100 + (vals[end] >= prev ? prev ~/ 2 : -(prev ~/ 2))) ~/ prev;
        final unit = switch (q.bucket) {
          Bucket.day => 'days',
          Bucket.week => 'weeks',
          Bucket.month => 'months',
          Bucket.quarter => 'quarters',
          _ => 'years'
        };
        return PinData(
            v.id, v.name, '${rows.length} $unit', [for (final x in vals) x.toDouble()], vals[end], q.measure == Measure.count, delta);
      });

  void unpinView(String id) {
    repo.patchView(id, pinned: false);
    logEvent(_ovLog, Level.INFO, 'pin.unpin', {});
    _changed();
  }

  void repinView(String id) {
    repo.patchView(id, pinned: true);
    logEvent(_ovLog, Level.INFO, 'pin.repin', {});
    _changed();
  }

  // ---------- nearest goal ----------

  /// The goal closest to done: the largest share saved of a target not yet reached; a tie goes to the bigger target.
  /// TODO(eng-6): once goals carry a price and a deposit share, use `goalPlan` ("ready ~ month", "for deposit and costs").
  Goal? nearestGoal() => _cached(const MemoKey('ov.nearestGoal'), () {
        Goal? best;
        for (final g in goals) {
          if (g.target <= 0 || g.saved >= g.target) continue;
          // Compare saved/target shares by cross-multiplication: exact, no doubles.
          if (best == null) {
            best = g;
            continue;
          }
          final a = g.saved * best.target, b = best.saved * g.target;
          if (a > b || (a == b && g.target > best.target)) best = g;
        }
        return best;
      });
}
