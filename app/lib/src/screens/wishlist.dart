import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
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

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final s = wc.settings;
    final cur = wc.currency;
    final now = DateTime.now().millisecondsSinceEpoch;
    final waiting = wc.wish.where((w) => w.status == 'waiting' && w.hoursLeft(s.coolHours, now) > 0).toList();
    final ready = wc.wish.where((w) => w.status == 'waiting' && w.hoursLeft(s.coolHours, now) <= 0).toList();
    final done = wc.wish.where((w) => w.status != 'waiting').toList()..sort((a, b) => (b.decided ?? 0).compareTo(a.decided ?? 0));
    final skipped = done.where((w) => w.status == 'skipped').fold<int>(0, (a, w) => a + w.price);
    final p = parseMoney(price.text);

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: gapped([
      Panel(children: [
        const Eyebrow('Can I afford it?'),
        const Heading('Check before you buy'),
        Muted('Anything over ${money(s.impulse, cur, decimals: 0)} waits ${s.coolHours} hours on the wishlist first.'),
        Row(children: [
          Expanded(child: TextField(controller: name, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'What', hintText: 'Running shoes'))),
          const SizedBox(width: 10),
          SizedBox(
            width: 120,
            child: TextField(controller: price, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Price', prefixText: currencySymbol(cur))),
          ),
        ]),
        if (p != null && p > 0) _verdict(context, p),
      ]),
      Panel(children: [
        Row(children: [const Heading('Ready to decide', size: 15), const Spacer(), Tag('${ready.length}')]),
        if (ready.isEmpty)
          const EmptyNote('Nothing has finished waiting yet.')
        else
          Rows(children: [
            for (final w in ready)
              _WishRow(w: w, currency: cur, sub: 'Waited ${s.coolHours}h', actions: [
                FilledButton.tonal(onPressed: () => _buy(w), child: const Text('Buy it')),
                TextButton(onPressed: () => _skip(w), child: const Text('Skip')),
              ]),
          ]),
      ]),
      Panel(children: [
        Row(children: [const Heading('Cooling off', size: 15), const Spacer(), Tag('${waiting.length}')]),
        if (waiting.isEmpty)
          const EmptyNote('Your wishlist is empty. Check something above to add it.')
        else
          Rows(children: [
            for (final w in waiting)
              _WishRow(w: w, currency: cur, sub: _left(w.hoursLeft(s.coolHours, now)), actions: [
                TextButton(onPressed: () => _skip(w), child: const Text("Don't need it")),
              ]),
          ]),
      ]),
      Panel(children: [
        Row(children: [const Heading('Decided', size: 15), const Spacer(), Text('Saved by waiting: ${money(skipped, cur, decimals: 0)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))]),
        if (done.isEmpty)
          const EmptyNote('Items you buy or skip show up here.')
        else
          Rows(children: [for (final w in done.take(20)) _WishRow(w: w, currency: cur, sub: w.status == 'bought' ? 'Bought' : 'Skipped', actions: const [])]),
      ]),
    ]));
  }

  String _left(double h) => h >= 24 ? '${h ~/ 24}d ${(h % 24).round()}h left' : '${h.ceil()}h left';

  Widget _verdict(BuildContext context, int price) {
    final wc = widget.wc;
    final s = wc.settings;
    final cur = wc.currency;
    final p = wc.period();
    final a = affordability(price, p);
    String by(int perDay) => shortDate(addDays(wc.today(), (price / perDay).ceil()));
    final head = switch (a.verdict) {
      Verdict.now => const StatusLabel(good: true, text: 'Fits this month'),
      Verdict.tight => const StatusLabel(good: false, text: 'Possible, but tight'),
      Verdict.later => const StatusLabel(good: false, text: 'Not this month'),
    };
    final body = a.verdict == Verdict.later
        ? "It's more than the ${money(p.flexBudget - p.spent < 0 ? 0 : p.flexBudget - p.spent, cur, decimals: 0)} you have left until payday."
        : 'Your daily budget would drop from ${money(p.allowanceToday, cur)} to ${money(a.newDaily, cur)} for the next ${p.daysLeft} days.';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head,
      const SizedBox(height: 6),
      Text(body, style: const TextStyle(fontSize: 14)),
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
          onPressed: () => showSheet<void>(context, GoalSheet(wc: wc, name: name.text.trim().isEmpty ? 'Big purchase' : name.text.trim(), target: price)),
          child: const Text('Save for it'),
        ),
      ]),
    ]);
  }

  Future<void> _buy(WishItem w) async {
    widget.wc.decideWish(w.id, 'bought');
    toast(context, 'Log it with Add expense when you pay');
    await showSheet<String>(context, AddExpenseSheet(wc: widget.wc, amount: w.price, note: w.name, skipImpulse: true));
  }

  void _skip(WishItem w) {
    widget.wc.decideWish(w.id, 'skipped');
    toast(context, 'Skipped. ${money(w.price, widget.wc.currency, decimals: 0)} stays in your pocket.');
  }
}

class _WishRow extends StatelessWidget {
  final WishItem w;
  final String currency;
  final String sub;
  final List<Widget> actions;
  const _WishRow({required this.w, required this.currency, required this.sub, required this.actions});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(w.name, style: const TextStyle(fontWeight: FontWeight.w500))),
            Text(money(w.price, currency, decimals: 0), style: numStyle),
          ]),
          Row(children: [Text(sub, style: TextStyle(fontSize: 12.5, color: context.c.muted)), const Spacer(), ...actions]),
        ]),
      );
}
