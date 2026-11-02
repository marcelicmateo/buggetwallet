import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../insights_api.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/import_problems.dart';
import '../widgets/sheets.dart';
import 'import_flow.dart';
import 'spending.dart' show BudgetSummary;
import 'wishlist.dart';

/// "4 weeks in a row" for the review streak.
String streakText(int weeks) => '$weeks ${weeks == 1 ? 'week' : 'weeks'} in a row';

/// "3 main tags to confirm · 1 behind pace · 2 wishlist decisions": the steps that have something to do (null when none).
String? reviewSummary(ReviewState r) {
  final cats = r.count('categories'), pace = r.count('pace'), wishes = r.count('wishlist');
  final parts = [
    if (cats > 0) '$cats main ${cats == 1 ? 'tag' : 'tags'} to confirm',
    if (pace > 0) '$pace behind pace',
    if (wishes > 0) '$wishes wishlist ${wishes == 1 ? 'decision' : 'decisions'}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Opens the weekly review: a page on a phone, a dialog from [dialogMin] wide. [openSpending] is called after the review
/// closes when a pace row is tapped.
Future<void> openReview(BuildContext context, WalletController wc,
    {VoidCallback? openSpending, FileChooser chooser = const FileChooser()}) {
  return openPageOrDialog<String>(context, ReviewScreen(wc: wc, chooser: chooser), width: 560, logName: 'ReviewScreen').then((r) {
    if (r == 'spending') openSpending?.call();
  });
}

/// The weekly review: four ruled steps with a square tick each, then Done. Counts come from [WalletController.reviewState];
/// they drop as the owner works through the steps.
class ReviewScreen extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;
  const ReviewScreen({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _importing = false, _imported = false, _paceSeen = false;

  /// Set when Done was tapped: the page then shows [ReviewDoneView] instead of the steps.
  bool _finished = false;

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      await pickAndImport(context, widget.wc, widget.chooser);
      if (mounted) _imported = widget.wc.lastImport.any((l) => l.ok);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _done() {
    final wc = widget.wc;
    logNav('review.done');
    wc.markReviewDone();
    setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.wc,
      builder: (context, _) {
        final wc = widget.wc;
        if (_finished) return ReviewDoneView(wc: wc);
        final cur = wc.currency;
        final r = wc.reviewState();
        final rows = wc.reviewRows();
        final pace = wc.paceRows();
        final ready = wc.readyWishes();
        final month = monthOf(wc.today());
        final budget = wc.budgetVsActual(month);
        return Scaffold(
          appBar: const DialogAppBar(title: 'Weekly review'),
          body: ListView(
              padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, 24),
              children: gapped([
                const Muted('About five minutes. Nothing changes until you tap.'),
                _Step(
                  key: const ValueKey('step:import'),
                  title: 'Import',
                  done: _imported,
                  children: [
                    const Muted('Add your latest bank files.'),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        style: accentOutlined(context),
                        icon: _importing
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.upload_file),
                        key: const ValueKey('reviewImport'),
                        label: const Text('Choose files'),
                        onPressed: _importing ? null : _import,
                      ),
                    ),
                    for (final l in wc.lastImport) ...[
                      StatusLabel(good: l.ok, text: l.message),
                      ImportProblems(problems: l.problems, invalid: l.invalid, header: false),
                    ],
                  ],
                ),
                _Step(
                  key: const ValueKey('step:categories'),
                  title: 'Confirm main tags',
                  count: r.count('categories'),
                  done: rows.isEmpty,
                  children: [
                    if (rows.isEmpty)
                      const Muted('All main tags from the last 7 days are confirmed.')
                    else ...[
                      const Muted('Tap Looks right, or Change to pick another main tag or add tags. It remembers the merchant.'),
                      Rows(children: [for (final t in rows.take(8)) _CategoryRow(wc: wc, t: t, host: context)]),
                      if (rows.length > 8) Muted('${rows.length - 8} more after these.'),
                    ],
                  ],
                ),
                _Step(
                  key: const ValueKey('step:pace'),
                  title: 'Pace',
                  count: r.count('pace'),
                  done: pace.isEmpty || _paceSeen,
                  children: [
                    if (budget.budgetedCount == 0)
                      const Muted('No budgets yet. Set some in Budget › Plan to see your pace.')
                    else
                      BudgetSummary(budget, cur),
                    if (pace.isNotEmpty)
                      Rows(children: [
                        for (final l in pace)
                          _PaceRow(
                            l: l,
                            name: wc.categoryTable.label(l.category),
                            currency: cur,
                            onTap: () {
                              logNav('review.pace');
                              Navigator.pop(context, 'spending');
                            },
                          ),
                      ]),
                    if (pace.isNotEmpty && !_paceSeen)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                            key: const ValueKey('paceGotIt'),
                            onPressed: () => setState(() => _paceSeen = true),
                            child: const Text('Got it')),
                      ),
                  ],
                ),
                _Step(
                  key: const ValueKey('step:wishlist'),
                  title: 'Wishlist',
                  count: r.count('wishlist'),
                  done: ready.isEmpty,
                  children: [
                    if (ready.isEmpty)
                      const Muted('Nothing has finished waiting.')
                    else
                      Rows(children: [
                        for (final w in ready)
                          WishRow(w: w, currency: cur, sub: 'Waited ${wc.settings.coolHours}h', actions: [
                            OutlinedButton(
                                style: accentOutlined(context), onPressed: () => buyWish(context, wc, w), child: const Text('Buy it')),
                            TextButton(
                                key: ValueKey('skipWish:${w.id}'), onPressed: () => skipWish(context, wc, w), child: const Text('Skip')),
                          ]),
                      ]),
                  ],
                ),
                if (r.streak > 0) Muted('So far: ${streakText(r.streak)}.'),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
                  key: const ValueKey('reviewDone'),
                  onPressed: _done,
                  child: const Text('Done', style: TextStyle(fontSize: BwType.headingSize)),
                ),
              ])),
        );
      });
}

/// One ruled step: a square tick (a check mark when done), the title, the count, then the content.
class _Step extends StatelessWidget {
  final String title;
  final int? count;
  final bool done;
  final List<Widget> children;
  const _Step({super.key, required this.title, this.count, required this.done, required this.children});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Panel(children: [
      Semantics(
        label: '$title, ${done ? 'done' : 'to do'}',
        excludeSemantics: true,
        child: Row(children: [
          Container(
            key: ValueKey(done ? 'tick:done' : 'tick:open'),
            width: 20,
            height: 20,
            decoration: BoxDecoration(
                color: done ? c.accent : null,
                border: Border.all(color: done ? c.accent : c.lineStrong, width: 1.5),
                borderRadius: BorderRadius.circular(1)),
            child: done ? Icon(Icons.check, size: 15, color: c.bg) : null,
          ),
          const SizedBox(width: 10),
          Expanded(child: Heading(title, size: BwType.headingSize)),
          if (count != null && count! > 0) Tag('$count'),
        ]),
      ),
      ...children,
    ]);
  }
}

/// A budget line behind pace or over: name and state on the left, what is left on the right; a tap opens Spending.
class _PaceRow extends StatelessWidget {
  final CategoryBudgetLine l;
  final String name, currency;
  final VoidCallback onTap;
  const _PaceRow({required this.l, required this.name, required this.currency, required this.onTap});
  @override
  Widget build(BuildContext context) => HoverTint(
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: touchMin),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SplitRow(
                start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),
                  Text(l.over ? 'over budget' : 'behind pace', style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                ]),
                end: Text(budgetLeftText(l, currency),
                    textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500, color: l.over ? context.c.bad : null)),
              ),
            ),
          ),
        ),
      );
}

class _CategoryRow extends StatelessWidget {
  final WalletController wc;
  final CategorizedTx t;

  /// The screen's context: the row itself is removed when its transaction is deleted, the toast needs one that stays.
  final BuildContext host;
  const _CategoryRow({required this.wc, required this.t, required this.host});
  @override
  Widget build(BuildContext context) => HoverTint(
          child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SplitRow(
              start: Text(merchantName(t.tx), style: const TextStyle(fontWeight: FontWeight.w500)),
              end: Text(money(t.amount, t.tx.currency, decimals: 2, signed: true),
                  textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            Text(
                [
                  wc.categoryTable.label(t.category),
                  shortDateOrRaw(t.date),
                  if (originalNote(t, wc.settings.fxRates) case final o?) o,
                ].join(' · '),
                style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
            Wrap(spacing: 4, children: [
              TextButton(
                  onPressed: () async {
                    final r = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                    if (r == 'saved') {
                      wc.confirmCategory(t.tx); // the picked category is now the owner's choice
                      final failed = tagFailureText(wc.takeTagFailures());
                      if (failed != null && host.mounted) toast(host, failed);
                    }
                    if (r != 'saved' && host.mounted) txSheetToast(host, wc, r); // a delete says so, with Undo (the row is gone by then)
                  },
                  child: const Text('Change')),
              FilledButton(
                key: ValueKey('looksRight:${t.tx.id}'),
                onPressed: () {
                  logNav('review.confirm');
                  wc.confirmCategory(t.tx);
                },
                child: const Text('Looks right'),
              ),
            ]),
          ]),
        ]),
      ));
}

/// What Done shows (`reviewDoneScreen`): the streak and what waiting saved this pay period and all time. Close pops the review with
/// 'done'. The figures come from the controller ([WalletInsights.savedThisPeriod], [WalletInsights.savedAllTime]).
class ReviewDoneView extends StatelessWidget {
  final WalletController wc;
  const ReviewDoneView({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    final cur = wc.currency, streak = wc.reviewState().streak;
    final period = wc.savedThisPeriod(), all = wc.savedAllTime();
    String wishes(int n) => '$n ${n == 1 ? 'wish' : 'wishes'}';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, 'done');
      },
      child: Scaffold(
        key: const ValueKey('reviewDoneScreen'),
        appBar: const DialogAppBar(title: 'Review done'),
        body: ListView(
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, 24),
            children: gapped([
              Panel(children: [
                const Eyebrow('Review done'),
                StatusLabel(key: const ValueKey('reviewStreak'), good: true, text: streak > 0 ? streakText(streak) : 'Reviewed this week'),
              ]),
              Panel(children: [
                const Eyebrow('Saved by waiting'),
                if (all.count == 0)
                  const Muted('Nothing saved by waiting yet. A wish you skip after the wait counts here.', key: ValueKey('reviewSaved'))
                else ...[
                  Semantics(
                    container: true,
                    child: Text(
                        period.count == 0
                            ? 'Saved by waiting this period: nothing yet'
                            : 'Saved by waiting this period: ${moneyExact(period.cents, cur)} (${wishes(period.count)})',
                        key: const ValueKey('reviewSaved')),
                  ),
                  Text('All time: ${moneyExact(all.cents, cur)} (${wishes(all.count)})', key: const ValueKey('reviewSavedAll')),
                ],
              ]),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
                key: const ValueKey('reviewClose'),
                onPressed: () => Navigator.pop(context, 'done'),
                child: const Text('Close', style: TextStyle(fontSize: BwType.headingSize)),
              ),
            ])),
      ),
    );
  }
}
