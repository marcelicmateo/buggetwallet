import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/sheets.dart';

class WishlistScreen extends StatefulWidget {
  final WalletController wc;
  const WishlistScreen({super.key, required this.wc});
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
    final waiting = wc.wish.where((w) => w.status == 'waiting' && w.hoursLeft(s.coolHours, now) > 0).toList();
    final ready = wc.wish.where((w) => w.status == 'waiting' && w.hoursLeft(s.coolHours, now) <= 0).toList();
    final done = wc.wish.where((w) => w.status != 'waiting').toList()..sort((a, b) => (b.decided ?? 0).compareTo(a.decided ?? 0));
    final skipped = done.where((w) => w.status == 'skipped').fold<int>(0, (a, w) => a + w.price);
    final p = parseMoney(price.text);

    return NarrowPage(
        child: ListView(
            padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
            children: gapped([
              Panel(children: [
                const Eyebrow('Can I afford it?'),
                const Heading('Check before you buy'),
                Muted('Anything over ${money(s.impulse, cur, decimals: 0)} waits ${s.coolHours} hours on the wishlist first.'),
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
              if (ready.isEmpty)
                const _EmptySection('Ready to decide', 'Nothing has finished waiting yet.')
              else
                Panel(children: [
                  HeadingRow(const Heading('Ready to decide', size: BwType.headingSize), Tag('${ready.length}')),
                  Rows(children: [
                    for (final w in ready)
                      WishRow(key: _rowKey(w), highlight: w.id == _highlight, w: w, currency: cur, sub: 'Waited ${s.coolHours}h', actions: [
                        OutlinedButton(style: accentOutlined(context), onPressed: () => _buy(w), child: const Text('Buy it')),
                        TextButton(onPressed: () => _skip(w), child: const Text('Skip')),
                      ]),
                  ]),
                ]),
              if (waiting.isEmpty)
                const _EmptySection('Cooling off', 'Your wishlist is empty. Check something above to add it.')
              else
                Panel(children: [
                  HeadingRow(const Heading('Cooling off', size: BwType.headingSize), Tag('${waiting.length}')),
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
                  TotalRule(
                      child: SplitRow(
                          start: const Text('Waiting in total', style: TextStyle(fontWeight: FontWeight.w600)),
                          end: Text(money(wc.waitingTotal, cur, decimals: 0),
                              textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w600)))),
                ]),
              if (done.isEmpty)
                const _EmptySection('Decided', 'Items you buy or skip show up here.')
              else
                Panel(children: [
                  HeadingRow(
                    const Heading('Decided', size: BwType.headingSize),
                    Text('Saved by waiting: ${money(skipped, cur, decimals: 0)}',
                        style: const TextStyle(fontSize: BwType.metaSize, fontWeight: FontWeight.w600)),
                  ),
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
            ])));
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
                ? 'Spending is already ${money(p.overBy, cur)} over the plan ${p.paydayPassed ? 'this period' : 'until payday'}, so nothing more fits.'
                : 'Your plan leaves no spending money this period, so nothing more fits.',
            Verdict.later => "It's more than the ${money(left, cur, decimals: 0)} you have left until payday.",
            _ =>
              'Your daily budget would drop from ${money(p.allowanceToday, cur)} to ${money(a.newDaily, cur)} for the next ${p.daysLeft} ${p.daysLeft == 1 ? 'day' : 'days'}.',
          };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head,
      const SizedBox(height: 6),
      Text(body, style: const TextStyle(fontSize: BwType.bodySize)),
      Rows(children: [
        LineItem('Spend ${money(500, cur, decimals: 0)}/day less', by(500), sub: 'ready by'),
        LineItem('Spend ${money(1000, cur, decimals: 0)}/day less', by(1000), sub: 'ready by'),
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
          Padding(padding: const EdgeInsets.only(top: 10), child: Muted('Under ${money(s.impulse, cur, decimals: 0)}, no wait needed.')),
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
  toast(context, 'Skipped. ${money(w.price, wc.currency, decimals: 0)} stays in your pocket.');
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
                  end: Text(money(w.price, currency, decimals: 0),
                      textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: FontWeight.w500))),
              Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                Text(sub, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
                if (actions.isNotEmpty) Wrap(spacing: 4, children: actions),
              ]),
            ]),
          )));
}

/// A section with nothing in it: its title and the reason, on one ruled line (not a panel with a heading and a note).
class _EmptySection extends StatelessWidget {
  final String title;
  final String note;
  const _EmptySection(this.title, this.note);
  @override
  Widget build(BuildContext context) => RuledRow(
        key: ValueKey('emptySection:$title'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SplitRow(start: Heading(title, size: BwType.headingSize), end: Muted(note, align: TextAlign.end)),
      );
}
