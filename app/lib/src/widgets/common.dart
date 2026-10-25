import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../layout.dart';
import '../theme.dart';
import 'tag_picker.dart';

export '../layout.dart' show gapped;
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: gapped(children, gap: 12)),
    );
  }
}

class Eyebrow extends StatelessWidget {
  final String text;
  const Eyebrow(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(), style: BwType.eyebrow.copyWith(color: context.c.muted));
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
      padding: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.c.line))),
      child: trailing == null ? label : SplitRow(start: label, end: trailing!),
    );
  }
}

class Heading extends StatelessWidget {
  final String text;
  final double size;
  const Heading(this.text, {super.key, this.size = BwType.titleSize});
  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, letterSpacing: -0.2));
}

/// A text field for an amount: decimal keyboard, right-aligned mono digits. Give the field a test key with [fieldKey] (it lands on the
/// TextField itself). The parsing is `parseMoney`; the text for an existing amount is `centsToFieldText`.
class MoneyField extends StatelessWidget {
  final TextEditingController controller;
  final Key? fieldKey;
  final InputDecoration decoration;
  final TextStyle? style;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  const MoneyField({
    super.key,
    required this.controller,
    required this.decoration,
    this.fieldKey,
    this.style,
    this.autofocus = false,
    this.onChanged,
  });
  @override
  Widget build(BuildContext context) => TextField(
        key: fieldKey,
        controller: controller,
        autofocus: autofocus,
        onChanged: onChanged,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.end,
        style: style ?? numStyle,
        decoration: decoration,
      );
}

/// The page of the screens before the wallet opens (first run, unlock, open in another tab): the logo and name, then [children], in a
/// 480 dp column.
class GatePage extends StatelessWidget {
  final List<Widget> children;
  const GatePage({super.key, required this.children});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                  padding: const EdgeInsets.all(20),
                  shrinkWrap: true,
                  children: gapped([
                    const Row(children: [
                      LedgerLogo(),
                      SizedBox(width: 10),
                      Flexible(child: Heading('Budget Wallet', size: BwType.displaySize)),
                    ]),
                    ...children,
                  ])),
            ),
          ),
        ),
      );
}

class Muted extends StatelessWidget {
  final String text;
  final double size;
  final TextAlign align;
  const Muted(this.text, {super.key, this.size = BwType.metaSize, this.align = TextAlign.start});
  @override
  Widget build(BuildContext context) => Text(text, textAlign: align, style: TextStyle(fontSize: size, color: context.c.muted, height: 1.4));
}

/// The muted paragraph under a section head, shown in full the first time (per [id], remembered on this device), then folded
/// behind an info icon (`explainerInfo`) that opens it again.
class Explainer extends StatefulWidget {
  final WalletController wc;
  final String id;
  final String text;
  const Explainer(this.wc, this.id, this.text, {super.key});
  @override
  State<Explainer> createState() => _ExplainerState();
}

class _ExplainerState extends State<Explainer> {
  late bool _open = !widget.wc.explainerSeen(widget.id);

  // Marked seen only while it can be seen: the shell builds every tab, and a hidden tab (TickerMode off) must not use it up.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_open && TickerMode.valuesOf(context).enabled) widget.wc.markExplainerSeen(widget.id);
  }

  @override
  Widget build(BuildContext context) {
    if (_open) return Muted(widget.text);
    return Align(
      alignment: Alignment.centerLeft,
      child: IconButton(
        key: const ValueKey('explainerInfo'),
        tooltip: 'Show explanation',
        icon: const Icon(Icons.info_outline, size: 20),
        color: context.c.ink2,
        onPressed: () => setState(() => _open = true),
      ),
    );
  }
}

/// One muted line "Other currencies, not counted: 12 $ spent" for rows in a currency other than the wallet's (they are in no total).
/// Nothing when [byCurrency] is empty. Signed cents by currency code, never rounded.
class ForeignNote extends StatelessWidget {
  final Map<String, int> byCurrency;
  const ForeignNote(this.byCurrency, {super.key});
  @override
  Widget build(BuildContext context) {
    if (byCurrency.isEmpty) return const SizedBox.shrink();
    final codes = byCurrency.keys.toList()..sort();
    final parts = [
      for (final k in codes) '${moneyExact(byCurrency[k]!.abs(), k)} ${byCurrency[k]! < 0 ? 'spent' : 'received'}',
    ];
    return Muted('Other currencies, not counted: ${parts.join(', ')}', size: BwType.metaSize);
  }
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
      style: TextStyle(color: col, fontWeight: FontWeight.w600, fontSize: BwType.metaSize),
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
        child: Text(text, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2)),
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

/// Two 1 px rules with a 2 px gap: the line under a total (the only double rule in the app).
class DoubleRule extends StatelessWidget {
  const DoubleRule({super.key});
  @override
  Widget build(BuildContext context) {
    final line = Container(height: 1, color: context.c.lineStrong);
    return Column(mainAxisSize: MainAxisSize.min, children: [line, const SizedBox(height: 2), line]);
  }
}

/// A total: a light 1 px rule above [child] and a double rule below it.
class TotalRule extends StatelessWidget {
  final Widget? child;
  final EdgeInsets padding;
  const TotalRule({super.key, this.child, this.padding = const EdgeInsets.symmetric(vertical: 8)});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(height: 1, color: context.c.line),
        if (child != null) Padding(padding: padding, child: child) else SizedBox(height: padding.vertical),
        const DoubleRule(),
      ]);
}

const _dateCol = 52.0, _amountCol = 104.0;

/// Below this text scale the transaction rows use the Date | Particulars | Amount columns; above it they stack (the columns
/// would not fit a phone at large text).
const _stackScale = 1.15;

/// Below this screen width the date goes under the name (no date column).
const _compactWidth = 400.0;

bool _columnsFit(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) <= _stackScale && MediaQuery.sizeOf(context).width >= _compactWidth;

/// The column heads over a list of [TxTile]s.
class TxHeaderRow extends StatelessWidget {
  const TxHeaderRow({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final st = numStyle.copyWith(fontSize: BwType.eyebrowSize, letterSpacing: 0.8, fontWeight: FontWeight.w500, color: c.muted);
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

  /// A bill is linked to this payment: a small receipt mark (tap the row for "Open bill").
  final bool hasBill;

  /// The categories the row label comes from (null: the built-in names).
  final CategoryTable? table;

  /// The tags the row's `#tag` chips come from (null: no chips).
  final TagTable? tagTable;

  /// The payment is split into this many parts (P6): a "Split · N" mark. Spending lists the parts under the tile ([PartTile]).
  final int splitCount;

  /// The payment's stored split no longer adds up: "Split doesn't add up" under the tile.
  final bool splitBroken;

  /// A search found this payment by one of its parts (0-based): "Part 2 matches".
  final int? matchedPart;
  const TxTile(
      {super.key,
      required this.t,
      required this.currency,
      this.onTap,
      this.hasBill = false,
      this.table,
      this.tagTable,
      this.splitCount = 0,
      this.splitBroken = false,
      this.matchedPart});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final inc = t.amount > 0;
    final src = switch (t.tx.source) { 'manual' => 'added', 'revolut' => 'Revolut', 'pbz' => 'PBZ', final s => s };
    final amount = money(t.amount, currency, decimals: 2, signed: true);
    final amountStyle = numStyle.copyWith(fontSize: BwType.amountSize, fontWeight: FontWeight.w500, color: inc ? c.good : c.ink);
    final columns = _columnsFit(context);
    final name =
        Text(merchantName(t.tx), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500));
    final catLabel = (table ?? CategoryTable.builtIn).label(t.category);
    final date = shortDateOrRaw(t.date);
    final sub = Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(columns ? catLabel : '$date · $catLabel',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
      Tag(src),
      if (splitCount > 0) Tag('Split · $splitCount'),
      if (matchedPart != null) Tag('Part ${matchedPart! + 1} matches'),
      if (t.isPart) Tag('part of ${money(t.tx.amount, currency, decimals: 2, signed: true)}'),
      if (splitBroken || t.splitBroken)
        Row(key: const ValueKey('splitBroken'), mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.warning_amber_outlined, size: 14, color: c.bad),
          const SizedBox(width: 4),
          Flexible(child: Text("Split doesn't add up", style: TextStyle(fontSize: BwType.metaSize, color: c.bad))),
        ]),
      if (tagTable != null) ...rowTagChips(tagTable!, t.tags),
      if (hasBill) Icon(Icons.receipt_long_outlined, key: const ValueKey('billMark'), size: 15, semanticLabel: 'Has a bill', color: c.ink2),
    ]);
    final Widget body;
    if (columns) {
      final divider = BorderSide(color: c.line);
      body = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: _dateCol,
            child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(date, style: numStyle.copyWith(fontSize: BwType.metaSize, color: c.ink2)))),
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
    return MergeSemantics(
      child: InkWell(
        onTap: onTap,
        hoverColor: c.surface2,
        focusColor: c.accentSoft,
        mouseCursor: onTap == null ? null : SystemMouseCursors.click,
        child: RuledRow(child: body),
      ),
    );
  }
}

/// One part of a split payment, indented under the payment's [TxTile] on Spending (P6): amount, main tag, tags and note.
/// Tapping it opens the payment (the caller's [onTap]).
class PartTile extends StatelessWidget {
  final CategorizedTx part;
  final String currency;
  final VoidCallback? onTap;
  final CategoryTable? table;
  final TagTable? tagTable;
  const PartTile({super.key, required this.part, required this.currency, this.onTap, this.table, this.tagTable});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final amount = money(part.amount, currency, decimals: 2, signed: true);
    final label = (table ?? CategoryTable.builtIn).label(part.category);
    final note = part.partNote;
    return MergeSemantics(
      child: InkWell(
        onTap: onTap,
        hoverColor: c.surface2,
        focusColor: c.accentSoft,
        mouseCursor: onTap == null ? null : SystemMouseCursors.click,
        child: RuledRow(
          minHeight: 40,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 0, 6),
            child: SplitRow(
              gap: 12,
              start: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.subdirectory_arrow_right, size: 16, color: c.muted),
                const SizedBox(width: 4),
                Expanded(
                  child: Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(label, style: const TextStyle(fontSize: BwType.metaSize)),
                    if (tagTable != null) ...rowTagChips(tagTable!, part.tags),
                    if (note != null) Text(note, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
                  ]),
                ),
              ]),
              end: Text(amount,
                  textAlign: TextAlign.end, style: numStyle.copyWith(fontSize: BwType.metaSize, color: part.amount > 0 ? c.good : c.ink)),
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of a ruled list: at least [minHeight] tall with a hairline under it (no card, no fill).
class RuledRow extends StatelessWidget {
  final Widget child;
  final double minHeight;
  final EdgeInsetsGeometry? padding;
  const RuledRow({super.key, required this.child, this.minHeight = rowMin, this.padding});
  @override
  Widget build(BuildContext context) => Container(
        constraints: BoxConstraints(minHeight: minHeight),
        padding: padding,
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.c.line))),
        child: child,
      );
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

  /// The value's colour (default: the text colour), e.g. `bad` for "Over by …".
  final Color? valueColor;
  const LineItem(this.label, this.value, {super.key, this.sub, this.bold = false, this.leading, this.valueColor});
  @override
  Widget build(BuildContext context) {
    final w = bold ? FontWeight.w600 : FontWeight.w500;
    return Container(
      constraints: const BoxConstraints(minHeight: rowMin),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(
        builder: (context, box) => Row(children: [
          if (leading != null) ...[leading!, const SizedBox(width: 10)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontWeight: w)),
              if (sub != null)
                Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(sub!, style: TextStyle(fontSize: BwType.metaSize, color: context.c.ink2))),
            ]),
          ),
          const SizedBox(width: 8),
          // A long value ("Over by 1,234.56 €" at large text) wraps beyond 60 % of the row instead of overflowing.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * 0.6),
            child: Text(value, textAlign: TextAlign.end, style: numStyle.copyWith(fontWeight: w, color: valueColor)),
          ),
        ]),
      ),
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

/// A date picker that looks like a text field: floating [label], the date inside, a calendar icon (or a clear button with
/// [onClear]). A tap calls [onPick]; the sheet opens `showDatePicker` there.
class DateField extends StatelessWidget {
  final String label;

  /// `YYYY-MM-DD`, or null when not set.
  final String? value;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  final String? helper;
  const DateField({super.key, required this.label, required this.value, required this.onPick, this.onClear, this.helper});

  @override
  Widget build(BuildContext context) {
    final v = value;
    final text = v == null ? 'Set date' : shortDateOrRaw(v);
    return Row(children: [
      Expanded(
        child: InkWell(
          onTap: onPick,
          child: InputDecorator(
            decoration: InputDecoration(labelText: label, helperText: helper, suffixIcon: const Icon(Icons.event, size: 18)),
            child: Text(text, overflow: TextOverflow.ellipsis, style: v == null ? TextStyle(color: context.c.muted) : null),
          ),
        ),
      ),
      if (onClear != null && v != null) IconButton(tooltip: 'Clear $label', icon: const Icon(Icons.close, size: 18), onPressed: onClear),
    ]);
  }
}

/// How long a toast stays, with or without an action (I4).
const toastDuration = Duration(milliseconds: 2500);

/// A short message at the bottom: full width on a phone, a 400 dp floating card on wide windows.
///
/// Stays [toastDuration] (also with an action; only with a screen reader on does an action toast persist) and is cleared by [clearToasts] when the owner changes
/// tab or opens a sheet or page. With [actionLabel] and [onAction] the snack bar has one action button (like "Undo"); the
/// action gets the key `toastAction` (`toastUndo` for an action labelled "Undo").
void toast(BuildContext context, String msg, {String? actionLabel, VoidCallback? onAction}) => toastOn(ScaffoldMessenger.of(context), msg,
    wide: layoutOf(context) != LayoutSize.compact,
    accessible: MediaQuery.accessibleNavigationOf(context),
    actionLabel: actionLabel,
    onAction: onAction);

/// [toast] through a messenger taken earlier: for a message shown after the widget that asked may be gone (an Undo action).
void toastOn(ScaffoldMessengerState messenger, String msg,
    {required bool wide, required bool accessible, String? actionLabel, VoidCallback? onAction}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        width: wide ? 400 : null,
        duration: toastDuration,
        // With an action it stays for screen-reader users (they need time to reach it); otherwise it times out (I4).
        persist: onAction != null && accessible,
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(key: ValueKey(actionLabel == 'Undo' ? 'toastUndo' : 'toastAction'), label: actionLabel, onPressed: onAction)));
}

/// Removes the toast on screen and any queued one: called on a tab change and when a sheet or page opens.
void clearToasts(BuildContext context) => ScaffoldMessenger.maybeOf(context)?.clearSnackBars();

/// Clears toasts when a route is pushed (any `Navigator.push`, sheet or dialog), so a message never stays over a new screen.
class ToastClearer extends NavigatorObserver {
  final GlobalKey<ScaffoldMessengerState> messenger;
  ToastClearer(this.messenger);
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) messenger.currentState?.clearSnackBars();
  }
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
      Positioned(left: 0, right: 0, top: 0, height: 1, child: IgnorePointer(child: ColoredBox(color: c.lineStrong))),
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
