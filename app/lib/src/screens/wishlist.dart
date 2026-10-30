import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../insights_api.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dash.dart';
import '../widgets/sheets.dart';
import 'save.dart';

/// Save tab › Wishlist (RX6): the "Can I afford it?" check, then tiles: Ready to decide (needs the owner: Buy it / Skip), Cooling off
/// (the waiting total and a row per wish), Saved by waiting (core's all-time figure) and the Decided rows.
class WishlistScreen extends StatefulWidget {
  final WalletController wc;

  /// On the Save tab the panels sit in that tab's scroll: no list or page width of their own.
  final bool embedded;
  const WishlistScreen({super.key, required this.wc, this.embedded = false});
  @override
  State<WishlistScreen> createState() => _WishlistScreenState();
}

class _WishlistScreenState extends State<WishlistScreen> {
  final name = TextEditingController();
  final price = TextEditingController();

  /// The wish a toast's "Open" pointed at: tinted and scrolled into view once.
  String? _highlight;
  final _highlightKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    widget.wc.highlightWish.addListener(_takeHighlight);
    _takeHighlight();
  }

  @override
  void dispose() {
    widget.wc.highlightWish.removeListener(_takeHighlight);
    name.dispose();
    price.dispose();
    super.dispose();
  }

  void _takeHighlight() {
    final id = widget.wc.highlightWish.value;
    if (id == null) return;
    widget.wc.highlightWish.value = null;
    setState(() => _highlight = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _highlightKey.currentContext;
      if (ctx != null && ctx.mounted) Scrollable.ensureVisible(ctx, alignment: 0.3);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final s = wc.settings;
    final cur = wc.currency;
    final now = wc.now.millisecondsSinceEpoch;
    final waiting = wc.wish.where((w) => w.status == 'waiting' && w.hoursLeft(s.coolHours, now) > 0).toList()
      ..sort((a, b) => a.hoursLeft(s.coolHours, now).compareTo(b.hoursLeft(s.coolHours, now)));
    final ready = wc.wish.where((w) => w.status == 'waiting' && w.hoursLeft(s.coolHours, now) <= 0).toList();
    final done = wc.wish.where((w) => w.status != 'waiting').toList()..sort((a, b) => (b.decided ?? 0).compareTo(a.decided ?? 0));
    final saved = wc.savedAllTime();
    final p = parseMoney(price.text);

    Widget head(String label) => Padding(padding: const EdgeInsets.only(bottom: 4), child: TileLabel(label));

    final grid = DashGrid(children: [
      DashItem(
        span: 2,
        child: Tile(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            const TileLabel('Can I afford it?'),
            // Under the label, not beside it: at large text a side-by-side pair cuts both.
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Text('Over ${moneyExact(s.impulse, cur)} waits ${s.coolHours} h',
                  style: TextStyle(fontSize: BwType.metaSize, color: context.c.muted)),
            ),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: name,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'What', hintText: 'Running shoes'))),
              const SizedBox(width: 10),
              SizedBox(
                width: 120,
                child: MoneyField(
                    controller: price,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(labelText: 'Price', suffixText: currencySymbol(cur))),
              ),
            ]),
            if (p != null && p > 0) _verdict(context, p),
          ]),
        ),
      ),
      if (ready.isEmpty)
        const StatTile(key: ValueKey('emptySection:Ready to decide'), label: 'Ready', value: '0', sub: 'Nothing yet')
      else
        DashItem(
          span: 2,
          child: Tile(
            attention: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              SplitRow(start: const TileLabel('Ready to decide'), end: TileNote('${ready.length}')),
              Rows(children: [
                for (final w in ready)
                  WishRow(key: _rowKey(w), highlight: w.id == _highlight, w: w, currency: cur, sub: 'Waited ${s.coolHours}h', actions: [
                    OutlinedButton(style: accentOutlined(context), onPressed: () => _buy(w), child: const Text('Buy it')),
                    TextButton(onPressed: () => _skip(w), child: const Text('Skip')),
                  ]),
              ]),
            ]),
          ),
        ),
      if (waiting.isEmpty)
        const StatTile(key: ValueKey('emptySection:Cooling off'), label: 'Waiting', value: '0', sub: 'Wishlist is empty')
      else
        DashItem(
          span: 2,
          child: Tile(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              head('Cooling off'),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(moneyExact(wc.waitingTotal, cur), maxLines: 1, style: dashNumStyle(color: context.c.ink)),
              ),
              Text('${waiting.length} ${waiting.length == 1 ? 'wish' : 'wishes'}',
                  style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
              const SizedBox(height: 4),
              Rows(children: [
                for (final w in waiting)
                  WishRow(
                      key: _rowKey(w),
                      highlight: w.id == _highlight,
                      w: w,
                      currency: cur,
                      sub: timeLeft(w.hoursLeft(s.coolHours, now)),
                      actions: [
                        TextButton(onPressed: () => _skip(w), child: const Text("Don't need it")),
                      ]),
              ]),
            ]),
          ),
        ),
      if (done.isEmpty)
        const StatTile(key: ValueKey('emptySection:Decided'), label: 'Saved by waiting', value: '0', sub: 'Nothing decided yet')
      else ...[
        StatTile(
          key: const ValueKey('savedByWaiting'),
          label: 'Saved by waiting',
          value: moneyExact(saved.cents, cur),
          sub: '${saved.count} skipped',
        ),
        DashItem(
          span: 2,
          child: Tile(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              head('Decided'),
              Rows(children: [
                for (final w in done.take(20))
                  WishRow(
                      key: _rowKey(w),
                      highlight: w.id == _highlight,
                      w: w,
                      currency: cur,
                      sub: w.status == 'bought' ? 'Bought' : 'Skipped',
                      actions: const [])
              ]),
            ]),
          ),
        ),
      ],
    ]);
    final panel = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const SaveSectionHead('Wishlist'), grid]);
    if (widget.embedded) return panel;
    return ColoredBox(
        color: context.c.desk, child: ListView(padding: const EdgeInsets.fromLTRB(pagePad, 12, pagePad, pageBottomPad), children: [panel]));
  }

  Key _rowKey(WishItem w) => w.id == _highlight ? _highlightKey : ValueKey('wish:${w.id}');

  Widget _verdict(BuildContext context, int price) {
    final wc = widget.wc;
    final s = wc.settings;
    final cur = wc.currency;
    final p = wc.period();
    final a = affordability(price, p);
    String by(int perDay) => shortDate(addDays(wc.today(), (price / perDay).ceil()));
    final ended = p.paydayPassed && a.verdict != Verdict.overBudget;
    final head = switch (a.verdict) {
      _ when ended => const StatusLabel(key: ValueKey('verdictEnded'), good: false, text: 'Pay period ended'),
      Verdict.now => const StatusLabel(good: true, text: 'Fits this month'),
      Verdict.tight => const StatusLabel(good: false, text: 'Possible, but tight'),
      Verdict.later => const StatusLabel(good: false, text: 'Not this month'),
      Verdict.overBudget => const StatusLabel(key: ValueKey('verdictOverBudget'), good: false, text: 'Over budget this period'),
    };
    final left = p.remaining > 0 ? p.remaining : 0;
    final body = ended
        ? 'The pay period has ended. Start the new period, then check again.'
        : switch (a.verdict) {
            Verdict.overBudget => p.overBy > 0
                ? 'Spending is already ${moneyExact(p.overBy, cur)} over the plan ${p.paydayPassed ? 'this period' : 'until payday'}, so nothing more fits.'
                : 'Your plan leaves no spending money this period, so nothing more fits.',
            Verdict.later => "It's more than the ${moneyExact(left, cur)} you have left until payday.",
            _ =>
              'Your daily budget would drop from ${moneyExact(p.allowanceToday, cur)} to ${moneyExact(a.newDaily, cur)} for the next ${p.daysLeft} ${p.daysLeft == 1 ? 'day' : 'days'}.',
          };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 10),
      head,
      const SizedBox(height: 6),
      Text(body, style: const TextStyle(fontSize: BwType.bodySize)),
      Rows(children: [
        LineItem('Spend ${moneyExact(500, cur)}/day less', by(500), sub: 'ready by'),
        LineItem('Spend ${moneyExact(1000, cur)}/day less', by(1000), sub: 'ready by'),
      ]),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (price > s.impulse)
          FilledButton(
            onPressed: () {
              wc.addWish(name.text.trim().isEmpty ? 'Wishlist item' : name.text.trim(), price);
              name.clear();
              this.price.clear();
              setState(() {});
              toast(context, 'On the wishlist. Decide in ${s.coolHours} hours.');
            },
            child: Text('Put on wishlist (${s.coolHours}h)'),
          )
        else
          Padding(padding: const EdgeInsets.only(top: 10), child: Muted('Under ${moneyExact(s.impulse, cur)}, no wait needed.')),
        OutlinedButton(
          onPressed: () => showSheet<void>(
              context, GoalSheet(wc: wc, name: name.text.trim().isEmpty ? 'Big purchase' : name.text.trim(), target: price)),
          child: const Text('Save for it'),
        ),
      ]),
    ]);
  }

  Future<void> _buy(WishItem w) => buyWish(context, widget.wc, w);

  void _skip(WishItem w) => skipWish(context, widget.wc, w);
}

/// "Buy it" on a wish that finished waiting: marks it bought and opens Add expense with its price (also used by the review).
Future<void> buyWish(BuildContext context, WalletController wc, WishItem w) async {
  wc.decideWish(w.id, 'bought');
  toast(context, 'Log it with Add expense when you pay');
  await showSheet<String>(context, AddExpenseSheet(wc: wc, amount: w.price, note: w.name, skipImpulse: true));
}

void skipWish(BuildContext context, WalletController wc, WishItem w) {
  wc.decideWish(w.id, 'skipped');
  toast(context, 'Skipped. ${moneyExact(w.price, wc.currency)} stays in your pocket.');
}

class WishRow extends StatelessWidget {
  final WishItem w;
  final String currency;
  final String sub;
  final List<Widget> actions;

  /// Tinted: the wish a toast's "Open" pointed at.
  final bool highlight;
  const WishRow({super.key, required this.w, required this.currency, required this.sub, required this.actions, this.highlight = false});

  @override
  Widget build(BuildContext context) => HoverTint(
      child: DecoratedBox(
          key: highlight ? const ValueKey('wishHighlight') : null,
          decoration: BoxDecoration(color: highlight ? context.c.accentSoft : null),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SplitRow(
                  start: Text(w.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                  end:
                      Text(moneyExact(w.price, currency), textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
              Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                Text(sub, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                if (actions.isNotEmpty) Wrap(spacing: 4, children: actions),
              ]),
            ]),
          )));
}
