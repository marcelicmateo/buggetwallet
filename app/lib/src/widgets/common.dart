import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../format.dart';
import '../theme.dart';

/// A plain bordered card with consistent padding and spacing.
class Panel extends StatelessWidget {
  final List<Widget> children;
  final Color? color;
  final EdgeInsets padding;
  const Panel({super.key, required this.children, this.color, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color ?? context.c.surface,
        borderRadius: BorderRadius.circular(14),
        border: color == null ? Border.all(color: context.c.line) : null,
      ),
      padding: padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(children, 12)),
    );
  }
}

List<Widget> _spaced(List<Widget> xs, double gap) => [
      for (var i = 0; i < xs.length; i++) ...[if (i > 0) SizedBox(height: gap), xs[i]],
    ];

class Eyebrow extends StatelessWidget {
  final String text;
  const Eyebrow(this.text, {super.key});
  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: TextStyle(fontSize: 11.5, letterSpacing: 0.9, fontWeight: FontWeight.w600, color: context.c.muted));
}

class Heading extends StatelessWidget {
  final String text;
  final double size;
  const Heading(this.text, {super.key, this.size = 19});
  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, letterSpacing: -0.2));
}

class Muted extends StatelessWidget {
  final String text;
  final double size;
  const Muted(this.text, {super.key, this.size = 13});
  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: size, color: context.c.muted, height: 1.4));
}

/// Status pill with icon + label, so state is never colour alone.
class StatusLabel extends StatelessWidget {
  final bool good;
  final String text;
  const StatusLabel({super.key, required this.good, required this.text});
  @override
  Widget build(BuildContext context) {
    final col = good ? context.c.good : context.c.bad;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(good ? Icons.check_circle_outline : Icons.error_outline, size: 16, color: col),
      const SizedBox(width: 5),
      Text(text, style: TextStyle(color: col, fontWeight: FontWeight.w600, fontSize: 13)),
    ]);
  }
}

class Tag extends StatelessWidget {
  final String text;
  const Tag(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration:
            BoxDecoration(color: context.c.surface2, borderRadius: BorderRadius.circular(5), border: Border.all(color: context.c.line)),
        child: Text(text, style: TextStyle(fontSize: 11, color: context.c.ink2)),
      );
}

const numStyle = TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontFamily: 'monospace');

/// One transaction row.
class TxTile extends StatelessWidget {
  final CategorizedTx t;
  final String currency;
  final VoidCallback? onTap;
  const TxTile({super.key, required this.t, required this.currency, this.onTap});

  @override
  Widget build(BuildContext context) {
    final inc = t.amount > 0;
    final src = switch (t.tx.source) { 'manual' => 'added', 'revolut' => 'Revolut', 'pbz' => 'PBZ', final s => s };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(merchantName(t.tx), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Row(children: [
                Flexible(
                    child: Text('${shortDate(t.date)} · ${t.category}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: context.c.muted))),
                const SizedBox(width: 6),
                Tag(src),
              ]),
            ]),
          ),
          const SizedBox(width: 12),
          Text(money(t.amount, currency, decimals: 2, signed: true), style: numStyle.copyWith(color: inc ? context.c.good : context.c.ink)),
        ]),
      ),
    );
  }
}

/// Rows separated by hairlines.
class Rows extends StatelessWidget {
  final List<Widget> children;
  const Rows({super.key, required this.children});
  @override
  Widget build(BuildContext context) => Column(children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) Divider(height: 1, color: context.c.line), children[i]],
      ]);
}

/// Label on the left, value on the right, optional sub-line.
class LineItem extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final bool bold;
  const LineItem(this.label, this.value, {super.key, this.sub, this.bold = false});
  @override
  Widget build(BuildContext context) {
    final w = bold ? FontWeight.w700 : FontWeight.w500;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontWeight: w)),
            if (sub != null)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text(sub!, style: TextStyle(fontSize: 12.5, color: context.c.muted))),
          ]),
        ),
        Text(value, style: numStyle.copyWith(fontWeight: w)),
      ]),
    );
  }
}

class EmptyNote extends StatelessWidget {
  final String text;
  const EmptyNote(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: context.c.muted)));
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3)));
}

/// Children with a fixed gap between them, for ListView pages.
List<Widget> gapped(List<Widget> xs, {double gap = 14}) => [
      for (var i = 0; i < xs.length; i++) ...[if (i > 0) SizedBox(height: gap), xs[i]],
    ];
