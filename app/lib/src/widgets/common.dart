import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../format.dart';
import '../layout.dart';
import '../theme.dart';

export '../theme.dart' show numStyle;

/// A ruled section (no card): a 1 px strong rule on top, a hairline below, vertical padding only (the page margin belongs to
/// layout.dart). With [color] it is a flat band with a 3 px bar on the left; the content keeps its own icon and words.
class Panel extends StatelessWidget {
  final List<Widget> children;
  final Color? color;
  final EdgeInsets padding;
  const Panel({super.key, required this.children, this.color, this.padding = const EdgeInsets.symmetric(vertical: 12)});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final band = color != null;
    final bar = color == c.warnBg ? c.warnInk : c.accent;
    return Container(
      decoration: BoxDecoration(
        color: color,
        border: Border(
          top: BorderSide(color: c.lineStrong),
          bottom: BorderSide(color: c.line),
          left: band ? BorderSide(color: bar, width: 3) : BorderSide.none,
        ),
      ),
      padding: band ? padding + const EdgeInsets.symmetric(horizontal: 12) : padding,
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
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: numStyle.copyWith(fontSize: 11, letterSpacing: 11 * 0.08, fontWeight: FontWeight.w500, color: context.c.muted));
}

/// A section title: mono 11 px capitals over a strong underline, with something on the right if given.
class SectionHead extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionHead(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) {
    final label = Eyebrow(text);
    return Container(
      padding: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.c.lineStrong))),
      child: trailing == null ? label : SplitRow(start: label, end: trailing!),
    );
  }
}

class Heading extends StatelessWidget {
  final String text;
  final double size;
  const Heading(this.text, {super.key, this.size = 19});
  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, letterSpacing: -0.2));
}

class Muted extends StatelessWidget {
  final String text;
  final double size;
  final TextAlign align;
  const Muted(this.text, {super.key, this.size = 13, this.align = TextAlign.start});
  @override
  Widget build(BuildContext context) => Text(text, textAlign: align, style: TextStyle(fontSize: size, color: context.c.muted, height: 1.4));
}

/// Status pill with icon + label, so state is never colour alone. The label wraps (the icon stays on the first
/// line), so long messages fit narrow screens and large text; inside a Row, wrap it in Flexible.
class StatusLabel extends StatelessWidget {
  final bool good;
  final String text;
  final TextAlign textAlign;
  const StatusLabel({super.key, required this.good, required this.text, this.textAlign = TextAlign.start});
  @override
  Widget build(BuildContext context) {
    final col = good ? context.c.good : context.c.bad;
    return Text.rich(
      TextSpan(children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 5),
            child: Icon(good ? Icons.check_circle_outline : Icons.error_outline, size: 16, color: col),
          ),
        ),
        TextSpan(text: text),
      ]),
      textAlign: textAlign,
      style: TextStyle(color: col, fontWeight: FontWeight.w600, fontSize: 13),
    );
  }
}

/// A row with [start] taking the room and [end] (an amount, a note) at the right end at its natural width, up to
/// [maxEnd] of the row, wrapping beyond that. Use instead of `Expanded` + `Flexible`, which splits the row in half.
class SplitRow extends StatelessWidget {
  final Widget start, end;
  final double gap, maxEnd;
  final CrossAxisAlignment crossAxisAlignment;
  const SplitRow(
      {super.key,
      required this.start,
      required this.end,
      this.gap = 8,
      this.maxEnd = 0.5,
      this.crossAxisAlignment = CrossAxisAlignment.center});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
      builder: (context, box) => Row(crossAxisAlignment: crossAxisAlignment, children: [
            Expanded(child: start),
            SizedBox(width: gap),
            ConstrainedBox(constraints: BoxConstraints(maxWidth: box.maxWidth * maxEnd), child: end),
          ]));
}

/// A panel heading with something on its right (a count, tag, icon or note). On a narrow screen or with large
/// text the right part moves under the heading instead of overflowing.
class HeadingRow extends StatelessWidget {
  final Widget heading;
  final Widget trailing;
  const HeadingRow(this.heading, this.trailing, {super.key});
  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [heading, trailing],
      );
}

class Tag extends StatelessWidget {
  final String text;
  const Tag(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration:
            BoxDecoration(color: context.c.surface2, borderRadius: BorderRadius.circular(2), border: Border.all(color: context.c.line)),
        child: Text(text, style: TextStyle(fontSize: 11, color: context.c.ink2)),
      );
}

/// The Ledger mark: an accent square with a margin line and a few ruled lines.
class LedgerLogo extends StatelessWidget {
  final double size;
  const LedgerLogo({super.key, this.size = 26});
  @override
  Widget build(BuildContext context) => SizedBox(
      width: size, height: size, child: CustomPaint(painter: _LogoPainter(context.c.accent, Theme.of(context).scaffoldBackgroundColor)));
}

class _LogoPainter extends CustomPainter {
  final Color fill, paper;
  _LogoPainter(this.fill, this.paper);
  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 26;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, size.height), Radius.circular(3 * k)), Paint()..color = fill);
    final p = Paint()..style = PaintingStyle.stroke;
    canvas.drawLine(
        Offset(8.5 * k, 3 * k),
        Offset(8.5 * k, 23 * k),
        p
          ..color = const Color(0xFFF0A59B)
          ..strokeWidth = 1.1 * k);
    p
      ..color = paper
      ..strokeWidth = 1.6 * k;
    for (final (y, x2) in [(7.5, 20.5), (11.5, 20.5), (15.5, 17.0)]) {
      canvas.drawLine(Offset(11.5 * k, y * k), Offset(x2 * k, y * k), p);
    }
    p.strokeWidth = 0.8 * k;
    for (final y in [19.0, 20.8]) {
      canvas.drawLine(Offset(11.5 * k, y * k), Offset(20.5 * k, y * k), p);
    }
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.fill != fill || old.paper != paper;
}

/// A money string (number, one NBSP, sign) in one Text whose gap is a narrow space: in a mono font the space is a full
/// character wide, which looks like a hole at big sizes. The plain text is still exactly [text].
class MoneyText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final TextAlign? textAlign;
  const MoneyText(this.text, {super.key, required this.style, this.textAlign});
  @override
  Widget build(BuildContext context) {
    final i = text.indexOf('\u00A0');
    if (i < 0) return Text(text, style: style, textAlign: textAlign);
    final size = style.fontSize ?? 14;
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: text.substring(0, i)),
        TextSpan(text: '\u00A0', style: TextStyle(fontSize: size * 0.4)),
        TextSpan(text: text.substring(i + 1)),
      ]),
      style: style,
      textAlign: textAlign,
    );
  }
}

/// Two 1 px rules with a 1 px gap: the line under a total.
class DoubleRule extends StatelessWidget {
  const DoubleRule({super.key});
  @override
  Widget build(BuildContext context) {
    final line = Container(height: 1, color: context.c.lineStrong);
    return Column(mainAxisSize: MainAxisSize.min, children: [line, const SizedBox(height: 1), line]);
  }
}

/// A total: a 1 px rule above [child] and a double rule below it.
class TotalRule extends StatelessWidget {
  final Widget? child;
  final EdgeInsets padding;
  const TotalRule({super.key, this.child, this.padding = const EdgeInsets.symmetric(vertical: 8)});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(height: 1, color: context.c.lineStrong),
        if (child != null) Padding(padding: padding, child: child) else SizedBox(height: padding.vertical),
        const DoubleRule(),
      ]);
}

const _dateCol = 52.0, _amountCol = 104.0;

/// Below this text scale the transaction rows use the Date | Particulars | Amount columns; above it they stack (the columns
/// would not fit a phone at large text).
const _stackScale = 1.15;

bool _columnsFit(BuildContext context) => MediaQuery.textScalerOf(context).scale(1) <= _stackScale;

/// The column heads over a list of [TxTile]s.
class TxHeaderRow extends StatelessWidget {
  const TxHeaderRow({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final st = numStyle.copyWith(fontSize: 10, letterSpacing: 0.8, fontWeight: FontWeight.w500, color: c.muted);
    Widget cell(String t, {TextAlign align = TextAlign.start}) => Text(t.toUpperCase(), textAlign: align, style: st);
    final bottom = BoxDecoration(border: Border(bottom: BorderSide(color: c.line)));
    if (!_columnsFit(context)) {
      return Container(
          decoration: bottom,
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: SplitRow(start: cell('Particulars'), end: cell('Amount', align: TextAlign.end)));
    }
    return Container(
      decoration: bottom,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(width: _dateCol, child: cell('Date')),
        Expanded(child: Padding(padding: const EdgeInsets.only(left: 11), child: cell('Particulars'))),
        SizedBox(width: _amountCol, child: cell('Amount', align: TextAlign.end)),
      ]),
    );
  }
}

/// One transaction row: Date | Particulars | Amount with hairline column dividers (stacked at large text).
class TxTile extends StatelessWidget {
  final CategorizedTx t;
  final String currency;
  final VoidCallback? onTap;
  const TxTile({super.key, required this.t, required this.currency, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final inc = t.amount > 0;
    final src = switch (t.tx.source) { 'manual' => 'added', 'revolut' => 'Revolut', 'pbz' => 'PBZ', final s => s };
    final amount = money(t.amount, currency, decimals: 2, signed: true);
    final amountStyle = numStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w500, color: inc ? c.good : c.ink);
    final columns = _columnsFit(context);
    final name =
        Text(merchantName(t.tx), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500));
    final date = shortDateOrRaw(t.date);
    final sub = Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(columns ? t.category : '$date · ${t.category}',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: c.ink2)),
      Tag(src),
    ]);
    final Widget body;
    if (columns) {
      final divider = BorderSide(color: c.line);
      body = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: _dateCol,
            child:
                Padding(padding: const EdgeInsets.only(top: 12), child: Text(date, style: numStyle.copyWith(fontSize: 12, color: c.ink2)))),
        Expanded(
          child: Container(
            decoration: BoxDecoration(border: Border(left: divider, right: divider)),
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, const SizedBox(height: 2), sub]),
          ),
        ),
        SizedBox(
          width: _amountCol,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: FittedBox(
                fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Text(amount, textAlign: TextAlign.end, style: amountStyle)),
          ),
        ),
      ]);
    } else {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SplitRow(
          gap: 12,
          start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, const SizedBox(height: 2), sub]),
          end: Text(amount, textAlign: TextAlign.end, style: amountStyle),
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      hoverColor: c.surface2,
      focusColor: c.accentSoft,
      mouseCursor: onTap == null ? null : SystemMouseCursors.click,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
        child: body,
      ),
    );
  }
}

/// Tints its child with the hover colour while a mouse is over it (rows that are not tappable themselves).
class HoverTint extends StatefulWidget {
  final Widget child;
  const HoverTint({super.key, required this.child});
  @override
  State<HoverTint> createState() => _HoverTintState();
}

class _HoverTintState extends State<HoverTint> {
  bool _over = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: DecoratedBox(decoration: BoxDecoration(color: _over ? context.c.surface2 : null), child: widget.child),
      );
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

/// Label on the left, value (mono, right-aligned) on the right, optional sub-line and a [leading] mark.
class LineItem extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final bool bold;
  final Widget? leading;
  const LineItem(this.label, this.value, {super.key, this.sub, this.bold = false, this.leading});
  @override
  Widget build(BuildContext context) {
    final w = bold ? FontWeight.w600 : FontWeight.w500;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: 10)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontWeight: w)),
            if (sub != null)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text(sub!, style: TextStyle(fontSize: 12.5, color: context.c.ink2))),
          ]),
        ),
        const SizedBox(width: 8),
        Text(value, textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: w)),
      ]),
    );
  }
}

/// A small empty square, the mark of an open checklist item.
class CheckSquare extends StatelessWidget {
  const CheckSquare({super.key});
  @override
  Widget build(BuildContext context) => Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(border: Border.all(color: context.c.lineStrong, width: 1.5), borderRadius: BorderRadius.circular(1)));
}

class EmptyNote extends StatelessWidget {
  final String text;
  const EmptyNote(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: context.c.muted)));
}

/// A short message at the bottom: full width on a phone, a 400 dp floating card on wide windows.
///
/// With [actionLabel] and [onAction] the snack bar has one action button (like "Undo") and stays a little longer.
void toast(BuildContext context, String msg, {String? actionLabel, VoidCallback? onAction}) {
  final wide = layoutOf(context) != LayoutSize.compact;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        width: wide ? 400 : null,
        duration: Duration(seconds: onAction == null ? 3 : 6),
        action: actionLabel == null || onAction == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction)));
}

/// The bottom bar with a 1 px ink rule on top and a 3 px accent bar over the selected destination (the bar's destinations
/// share the width equally).
class NavBarFrame extends StatelessWidget {
  final int selected, count;
  final Widget child;
  const NavBarFrame({super.key, required this.selected, required this.count, required this.child});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Stack(children: [
      child,
      Positioned(left: 0, right: 0, top: 0, height: 1, child: IgnorePointer(child: ColoredBox(color: c.ink))),
      Positioned.fill(
        child: IgnorePointer(
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth / count;
            return Stack(children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 150),
                left: selected * w + 16,
                width: w - 32,
                top: 0,
                height: 3,
                child: ColoredBox(color: c.accent),
              ),
            ]);
          }),
        ),
      ),
    ]);
  }
}

/// Children with a fixed gap between them, for ListView pages.
List<Widget> gapped(List<Widget> xs, {double gap = 14}) => [
      for (var i = 0; i < xs.length; i++) ...[if (i > 0) SizedBox(height: gap), xs[i]],
    ];
