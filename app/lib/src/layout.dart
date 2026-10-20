// Window-width layout: sizes, content widths and the two-column helper. Decide on the width the shell (or the content)
// really has (MediaQuery.sizeOf / LayoutBuilder), never on the device type, so a resized desktop window adapts live.
import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets/common.dart' show MarginLine;

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

  List<Widget> _spaced(List<Widget> xs) => [
        for (var i = 0; i < xs.length; i++) ...[if (i > 0) SizedBox(height: gap), xs[i]],
      ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final l = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(left));
        final r = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _spaced(right));
        if (box.maxWidth + 2 * pagePad >= twoColMin) {
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
