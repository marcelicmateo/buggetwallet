import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../layout.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';
import 'import_flow.dart';
import 'spending.dart' show BudgetSummary;
import 'wishlist.dart';

/// "4 weeks in a row" for the review streak.
String streakText(int weeks) => '$weeks ${weeks == 1 ? 'week' : 'weeks'} in a row';

/// "3 categories to confirm · 1 behind pace · 2 wishlist decisions": the steps that have something to do (null when none).
String? reviewSummary(ReviewState r) {
  final cats = r.count('categories'), pace = r.count('pace'), wishes = r.count('wishlist');
  final parts = [
    if (cats > 0) '$cats ${cats == 1 ? 'category' : 'categories'} to confirm',
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
    toast(context, 'Review done · ${streakText(wc.reviewState().streak)}');
    Navigator.pop(context, 'done');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.wc,
      builder: (context, _) {
        final wc = widget.wc;
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
                    for (final l in wc.lastImport) StatusLabel(good: l.ok, text: l.message),
                  ],
                ),
                _Step(
                  key: const ValueKey('step:categories'),
                  title: 'Confirm categories',
                  count: r.count('categories'),
                  done: rows.isEmpty,
                  children: [
                    if (rows.isEmpty)
                      const Muted('All categories from the last 7 days are confirmed.')
                    else ...[
                      const Muted('Tap Looks right, or Change to pick another. It remembers the merchant.'),
                      Rows(children: [for (final t in rows.take(8)) _CategoryRow(wc: wc, t: t)]),
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
                      const Muted('No budgets yet. Set some in Plan to see your pace.')
                    else
                      BudgetSummary(budget, cur),
                    if (pace.isNotEmpty)
                      Rows(children: [
                        for (final l in pace)
                          _PaceRow(
                            l: l,
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
                  child: const Text('Done', style: TextStyle(fontSize: 16)),
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
          Expanded(child: Heading(title, size: 16)),
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
  final String currency;
  final VoidCallback onTap;
  const _PaceRow({required this.l, required this.currency, required this.onTap});
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
                  Text(l.category, style: const TextStyle(fontWeight: FontWeight.w500)),
                  Text(l.over ? 'over budget' : 'behind pace', style: TextStyle(fontSize: 12.5, color: context.c.ink2)),
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
  const _CategoryRow({required this.wc, required this.t});
  @override
  Widget build(BuildContext context) => HoverTint(
          child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SplitRow(
              start: Text(merchantName(t.tx), style: const TextStyle(fontWeight: FontWeight.w500)),
              end: Text(money(t.amount, wc.currency, decimals: 2, signed: true),
                  textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            Text('${t.category} · ${shortDateOrRaw(t.date)}', style: TextStyle(fontSize: 12.5, color: context.c.ink2)),
            Wrap(spacing: 4, children: [
              TextButton(
                  onPressed: () async {
                    final r = await showSheet<String>(context, TxSheet(wc: wc, t: t));
                    if (r == 'saved') wc.confirmCategory(t.tx); // the picked category is now the owner's choice
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
