// The dashboard kit (RX2, "Paper Tiles", docs/design/dashboard/CONCEPT.md §5): paper tiles on a darker desk. Dumb widgets: values
// arrive formatted (use `moneyExact`: always exact cents, a tile scales its number down instead of rounding), nothing here reads the
// controller or computes money. Charts live in `dash_charts.dart` (exported from here).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../layout.dart';
import '../theme.dart';
import 'common.dart';

export 'dash_charts.dart';

/// Tile figures: Plex Sans semibold with proportional figures (they read better large than the mono of the lists).
TextStyle dashNumStyle({double size = BwType.displaySize, Color? color}) => TextStyle(
      fontFamily: sansFamily,
      fontWeight: FontWeight.w600,
      fontSize: size,
      height: 1.1,
      letterSpacing: -0.3,
      fontFeatures: const [FontFeature.proportionalFigures()],
      color: color,
    );

/// One cell of a [DashGrid]: [span] columns wide (2 makes a wide tile; a grid with one column clamps it to 1).
class DashItem extends ParentDataWidget<_DashParentData> {
  final int span;
  const DashItem({super.key, this.span = 1, required super.child});

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _DashParentData;
    if (data.span != span) {
      data.span = span;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => DashGrid;
}

class _DashParentData extends ContainerBoxParentData<RenderBox> {
  int span = 1;
}

/// Tiles in 1, 2 or 4 columns, in the same order at every size. Columns come from the window ([sizeFor]: compact and medium 2,
/// expanded 4) and drop (4 → 2 → 1) while a column would be under [minColumn] dp, so 320 dp at text scale 2.0 gets one column.
/// A row's tiles are stretched to the tallest one. Children are tiles, optionally wrapped in [DashItem] to span 2.
class DashGrid extends MultiChildRenderObjectWidget {
  final double gap;
  final double minColumn;
  const DashGrid({super.key, super.children, this.gap = 10, this.minColumn = 150});

  /// Columns for a grid [width] dp wide in a window [windowWidth] dp wide.
  static int columnsFor(double width, double windowWidth, {double gap = 10, double minColumn = 150}) {
    var cols = sizeFor(windowWidth) == LayoutSize.expanded ? 4 : 2;
    while (cols > 1 && (width - gap * (cols - 1)) / cols < minColumn) {
      cols = cols == 4 ? 2 : 1;
    }
    return cols;
  }

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDash(windowWidth: MediaQuery.sizeOf(context).width, gap: gap, minColumn: minColumn);

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) {
    renderObject as _RenderDash;
    renderObject
      ..windowWidth = MediaQuery.sizeOf(context).width
      ..gap = gap
      ..minColumn = minColumn;
  }
}

class _RenderDash extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _DashParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _DashParentData> {
  _RenderDash({required double windowWidth, required double gap, required double minColumn})
      : _windowWidth = windowWidth,
        _gap = gap,
        _minColumn = minColumn;

  double _windowWidth, _gap, _minColumn;
  set windowWidth(double v) {
    if (v == _windowWidth) return;
    _windowWidth = v;
    markNeedsLayout();
  }

  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  set minColumn(double v) {
    if (v == _minColumn) return;
    _minColumn = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DashParentData) child.parentData = _DashParentData();
  }

  @override
  void performLayout() {
    assert(constraints.hasBoundedWidth, 'DashGrid needs a bounded width');
    final w = constraints.maxWidth;
    final cols = DashGrid.columnsFor(w, _windowWidth, gap: _gap, minColumn: _minColumn);
    final colW = (w - _gap * (cols - 1)) / cols;
    var y = 0.0, used = 0;
    final row = <(RenderBox, double)>[]; // child, width
    var rowH = 0.0;

    void flush() {
      if (row.isEmpty) return;
      var col = 0;
      for (final (child, width) in row) {
        final data = child.parentData! as _DashParentData;
        if (child.size.height < rowH) child.layout(BoxConstraints.tightFor(width: width, height: rowH), parentUsesSize: true);
        data.offset = Offset(col * (colW + _gap), y);
        col += data.span.clamp(1, cols);
      }
      y += rowH + _gap;
      row.clear();
      used = 0;
      rowH = 0;
    }

    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _DashParentData;
      final span = data.span.clamp(1, cols);
      if (used + span > cols) flush();
      final width = colW * span + _gap * (span - 1);
      child.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
      row.add((child, width));
      used += span;
      if (child.size.height > rowH) rowH = child.size.height;
    }
    flush();
    size = constraints.constrain(Size(w, y > 0 ? y - _gap : 0));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);
}

/// A paper tile: 12 dp radius, `surface` on the `desk`, a 1 px `line` border, no shadow. With [onTap] it answers a touch with
/// the ink response (no chevron). [semanticLabel] replaces what a screen reader would read from the parts.
class Tile extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;
  const Tile({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.all(12), this.semanticLabel});

  static const radius = 12.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final body = Material(
      color: c.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: c.line)),
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
    if (semanticLabel == null) return body;
    return Semantics(container: true, button: onTap != null, label: semanticLabel, onTap: onTap, excludeSemantics: true, child: body);
  }
}

/// The small caps label on top of a tile (1–3 words).
class TileLabel extends StatelessWidget {
  final String text;
  const TileLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), maxLines: 2, overflow: TextOverflow.ellipsis, style: BwType.eyebrow.copyWith(color: context.c.muted));
}

/// A chip that says its state in an icon and a word, never in colour alone. [spoken] is what a screen reader says.
abstract class DashChip extends StatelessWidget {
  const DashChip({super.key});
  String get spoken;
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color fg, bg;
  const _Chip({required this.icon, required this.text, required this.fg, required this.bg});
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 2),
            Flexible(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: BwType.metaSize, fontWeight: FontWeight.w600, color: fg)),
            ),
          ]),
        ),
      );
}

enum Trend { up, down, flat }

/// A change against something: ▲ / ▼ / – and the figure and a word ("12 % vs last period"). [good] says whether that direction is
/// good news (spending up is not): green or red ground; null = neutral.
class DeltaChip extends DashChip {
  final Trend trend;
  final String text;
  final bool? good;
  const DeltaChip({super.key, required this.trend, required this.text, this.good});

  @override
  String get spoken => '${switch (trend) {
        Trend.up => 'up',
        Trend.down => 'down',
        Trend.flat => 'unchanged',
      }} $text';

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (fg, bg) = switch (good) {
      true => (c.good, c.goodSoft),
      false => (c.bad, c.badSoft),
      null => (c.ink2, c.surface2),
    };
    final icon = switch (trend) {
      Trend.up => Icons.arrow_drop_up,
      Trend.down => Icons.arrow_drop_down,
      Trend.flat => Icons.remove,
    };
    return _Chip(icon: icon, text: text, fg: fg, bg: bg);
  }
}

enum DashState { onPace, over, date, held }

/// A state: ✓ On pace, ▲ Over, ⏱ a date, 🔒 Held. Icon and word; the ground colour is a second cue only.
class StateChip extends DashChip {
  final DashState state;
  final String text;
  const StateChip._(this.state, this.text, {super.key});
  const StateChip.onPace({Key? key, String text = 'On pace'}) : this._(DashState.onPace, text, key: key);
  const StateChip.over({Key? key, String text = 'Over'}) : this._(DashState.over, text, key: key);
  const StateChip.date(String text, {Key? key}) : this._(DashState.date, text, key: key);
  const StateChip.held({Key? key, String text = 'Held'}) : this._(DashState.held, text, key: key);

  @override
  String get spoken => text;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (icon, fg, bg) = switch (state) {
      DashState.onPace => (Icons.check, c.good, c.goodSoft),
      DashState.over => (Icons.warning_amber_rounded, c.bad, c.badSoft),
      DashState.date => (Icons.schedule, c.ink2, c.surface2),
      DashState.held => (Icons.lock_outline, c.accent, c.accentSoft),
    };
    return _Chip(icon: icon, text: text, fg: fg, bg: bg);
  }
}

/// One number: label (1–3 words), the figure scaled down to fit (never wrapped, never rounded), an optional sub line, one
/// optional [visual] and one optional [chip].
class StatTile extends StatelessWidget {
  final String label, value;
  final String? sub;
  final Widget? visual;
  final DashChip? chip;
  final VoidCallback? onTap;
  final Color? valueColor;
  const StatTile({super.key, required this.label, required this.value, this.sub, this.visual, this.chip, this.onTap, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Tile(
      onTap: onTap,
      semanticLabel: [label, value, if (sub != null) sub, if (chip != null) chip!.spoken].join(', '),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        TileLabel(label),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, maxLines: 1, style: dashNumStyle(color: valueColor ?? c.ink)),
        ),
        if (sub != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(sub!, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
          ),
        if (visual != null) Padding(padding: const EdgeInsets.only(top: 8), child: visual),
        if (chip != null) Padding(padding: const EdgeInsets.only(top: 8), child: chip),
      ]),
    );
  }
}

/// A row of a [DashRows] list.
class DashRowData {
  final String title;

  /// The amount, already formatted (mono, right edge).
  final String? amount;
  final String? sub;
  final DashChip? chip;
  final VoidCallback? onTap;
  final Key? key;
  const DashRowData({required this.title, this.amount, this.sub, this.chip, this.onTap, this.key});
}

/// Ruled rows for a tile (a name, a muted line, a state chip and a mono amount): the Ledger list inside a tile.
class DashRows extends StatelessWidget {
  final List<DashRowData> rows;
  const DashRows({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final r in rows)
        Semantics(
          container: true,
          button: r.onTap != null,
          label: [r.title, if (r.amount != null) r.amount, if (r.sub != null) r.sub, if (r.chip != null) r.chip!.spoken].join(', '),
          onTap: r.onTap,
          excludeSemantics: true,
          child: InkWell(
            key: r.key,
            onTap: r.onTap,
            child: RuledRow(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SplitRow(
                crossAxisAlignment: CrossAxisAlignment.start,
                start: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.title, style: const TextStyle(fontSize: BwType.bodySize, height: 1.25)),
                  if (r.sub != null) Text(r.sub!, style: TextStyle(fontSize: BwType.metaSize, height: 1.25, color: c.muted)),
                  if (r.chip != null) Padding(padding: const EdgeInsets.only(top: 4), child: r.chip),
                ]),
                end: r.amount == null
                    ? const SizedBox.shrink()
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(r.amount!, maxLines: 1, style: BwType.amount.copyWith(color: c.ink)),
                      ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// A tile with a dashed border and "+ Goal": the last tile of a list of tiles.
class AddTile extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const AddTile({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      container: true,
      button: true,
      label: 'Add $label',
      onTap: onTap,
      excludeSemantics: true,
      child: CustomPaint(
        foregroundPainter: DashedBorderPainter(color: c.lineStrong, radius: Tile.radius),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(Tile.radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: rowMin + 16),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.add, size: 18, color: c.ink2),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: BwType.bodyStrong.copyWith(color: c.ink2)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded rectangle outline, dashed ([dash] null = solid), optionally filled. Also the base of the calendar cells.
class DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius, width;
  final double? dash;
  final Color? fill;
  const DashedBorderPainter({required this.color, this.radius = 4, this.width = 1.5, this.dash = 5, this.fill});

  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius((Offset.zero & size).deflate(width / 2), Radius.circular(radius));
    if (fill != null) canvas.drawRRect(rr, Paint()..color = fill!);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final d = dash;
    if (d == null) {
      canvas.drawRRect(rr, stroke);
      return;
    }
    for (final m in (Path()..addRRect(rr)).computeMetrics()) {
      for (var at = 0.0; at < m.length; at += d * 2) {
        canvas.drawPath(m.extractPath(at, (at + d).clamp(0, m.length)), stroke);
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorderPainter old) =>
      old.color != color || old.radius != radius || old.width != width || old.dash != dash || old.fill != fill;
}
