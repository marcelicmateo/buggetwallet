// Window-width layout: sizes, content widths and the two-column helper. Decide on the width the shell (or the content)
// really has (MediaQuery.sizeOf / LayoutBuilder), never on the device type, so a resized desktop window adapts live.
import 'package:flutter/material.dart';

import 'theme.dart';

/// compact: bottom bar, one column. medium: rail, one column. expanded: wide rail, content up to [expandedMaxWidth].
enum LayoutSize { compact, medium, expanded }

const mediumMin = 600.0;
const expandedMin = 1024.0;
const mediumMaxWidth = 720.0;
const expandedMaxWidth = 1040.0;

/// Sheets open as dialogs from this width.
const dialogMin = mediumMin;

/// Two columns from this content width (the shell's content area, the page padding included).
const twoColMin = 1040.0;

/// Side padding of the scrolling pages; TwoCol adds it back to the width it sees.
const pagePad = 16.0;

/// Space under the last row of a tab (no floating button: Today's Add expense is the only add action).
const pageBottomPad = 24.0;

/// Minimum heights of tappable things. [rowMin] = a list row (same as touchMin: 48 dp is the floor everywhere), [touchMin] = a field, chip or small button, [buttonMin] = a full button.
const rowMin = 48.0;
const touchMin = 48.0;
const buttonMin = 52.0;

/// [xs] with a fixed [gap] of empty space between them (for ListView and Column children).
List<Widget> gapped(List<Widget> xs, {double gap = 14}) => [
      for (var i = 0; i < xs.length; i++) ...[if (i > 0) SizedBox(height: gap), xs[i]],
    ];

LayoutSize sizeFor(double width) => width < mediumMin
    ? LayoutSize.compact
    : width < expandedMin
        ? LayoutSize.medium
        : LayoutSize.expanded;

/// The widest the page content gets at [size] (unbounded when compact).
double maxContentWidth(LayoutSize size) => switch (size) {
      LayoutSize.compact => double.infinity,
      LayoutSize.medium => mediumMaxWidth,
      LayoutSize.expanded => expandedMaxWidth,
    };

LayoutSize layoutOf(BuildContext context) => sizeFor(MediaQuery.sizeOf(context).width);

/// [left] and [right] side by side when the content area is [twoColMin] wide or more, else [left] above [right].
/// Both are lists of children, spaced [gap] apart (14 between stacked children, [colGap] between the two columns).
class TwoCol extends StatelessWidget {
  final List<Widget> left, right;
  final double gap, colGap;
  const TwoCol({super.key, required this.left, required this.right, this.gap = 14, this.colGap = 16});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final l = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: gapped(left, gap: gap));
        final r = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: gapped(right, gap: gap));
        if (box.maxWidth + 2 * pagePad + _gutterOf(context) >= twoColMin) {
          // A 1 px hairline in the middle of the gap (the columns are equally wide, so the middle is half the width).
          return Stack(children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: l), SizedBox(width: colGap), Expanded(child: r)]),
            Positioned(
              top: 0,
              bottom: 0,
              left: (box.maxWidth - 1) / 2,
              width: 1,
              child: IgnorePointer(child: ColoredBox(key: const ValueKey('twoColDivider'), color: context.c.line)),
            ),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [l, SizedBox(height: gap), r]);
      });
}

/// A page that stays [mediumMaxWidth] wide and centered in a wider content area (Wishlist, Plan).
class NarrowPage extends StatelessWidget {
  final Widget child;
  const NarrowPage({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: mediumMaxWidth), child: MarginLine(child: child)));
}

/// Where the margin line sits (x, inside the content column) and how wide it is (two 1 px rules with a 2 px gap).
const marginLineX = 22.0, marginLineWidth = 4.0;

/// Extra room on the left of a page on windows that show the margin line, so the content stays clear of it
/// (the line ends at x = 26; the page padding then puts the content at 32).
const marginGutter = 16.0;

double _gutterOf(BuildContext context) => layoutOf(context) == LayoutSize.compact ? 0 : marginGutter;

/// Draws the notebook margin line (a red double rule at x = [marginLineX] of the column) on windows [dialogMin] wide or
/// more (or as [show] says) and moves [child] right by [marginGutter] to clear it. Each page puts it around its own
/// column. [child] keeps the same place in the tree either way (pages keep their State).
class MarginLine extends StatelessWidget {
  final bool? show;
  final Widget child;
  const MarginLine({super.key, this.show, required this.child});
  @override
  Widget build(BuildContext context) {
    final show = this.show ?? layoutOf(context) != LayoutSize.compact;
    final col = marginLineColor(Theme.of(context).brightness);
    return Stack(fit: StackFit.passthrough, children: [
      Padding(padding: EdgeInsets.only(left: show ? marginGutter : 0), child: child),
      if (show)
        Positioned(
          left: marginLineX,
          top: 0,
          bottom: 0,
          width: marginLineWidth,
          child: IgnorePointer(
            child: DecoratedBox(
              key: const ValueKey('marginLine'),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: col), right: BorderSide(color: col))),
            ),
          ),
        ),
    ]);
  }
}
