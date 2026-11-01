// The dashboard kit (RX2, "Paper Tiles", docs/design/dashboard/CONCEPT.md §5): paper tiles on a darker desk. Dumb widgets: values
// arrive formatted (use `moneyExact`: always exact cents, a tile scales its number down instead of rounding), nothing here reads the
// controller or computes money. Charts live in `dash_charts.dart` (exported from here).
//
// Layout contract: [DashGrid] is its own render object and never asks its tiles for intrinsic sizes, so a tile must not hold an
// IntrinsicWidth/IntrinsicHeight, an AlertDialog or anything else that needs them. A tile is laid out with a bounded width and an
// UNBOUNDED height: no Spacer, Expanded or Flexible in a tile's main-axis Column (the grid stretches the tile, not its children).
// A tile's `visual` and `dots` slots only show things: nothing in them is tappable (the tile is).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../layout.dart';
import '../theme.dart';
import 'common.dart';

import 'dash_charts.dart';

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

/// One cell of a [DashGrid]: [span] columns wide (2 makes a wide tile; a grid with one column clamps it to 1) and [rowSpan] rows tall
/// (a 2×2 hero on desktop). A [rowSpan] counts only when the tile leaves room beside it (its span is under the column count): a
/// full-width tile is one row high.
class DashItem extends ParentDataWidget<_DashParentData> {
  final int span, rowSpan;
  const DashItem({super.key, this.span = 1, this.rowSpan = 1, required super.child});

  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _DashParentData;
    if (data.span != span || data.rowSpan != rowSpan) {
      data.span = span;
      data.rowSpan = rowSpan;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => DashGrid;
}

class _DashParentData extends ContainerBoxParentData<RenderBox> {
  int span = 1, rowSpan = 1;
}

/// Tiles in 1, 2 or 4 columns, in the same reading order at every size. Columns come from the window ([sizeFor]: compact and medium 2,
/// expanded 4) and drop (4 → 2 → 1) while a column would be under [minColumn] dp scaled by the text scale (130 dp at 1.0, 260 dp at
/// 2.0), so 320 dp at text scale 2.0 and 360 dp at 2.0 get one column. A tile's row is as tall as its tallest tile; a [DashItem] with
/// `rowSpan` 2 is as tall as two rows, the next tiles fill the cells beside it. Children are tiles, optionally wrapped in [DashItem].
///
/// With [fillRows] (Today only): when the next tile does not fit in the cells a row has left, and those cells are free, the one-row tiles
/// of that row take them (each one cell wider, the last first), so no empty cell stays above the last row.
class DashGrid extends MultiChildRenderObjectWidget {
  final double gap;
  final double minColumn;
  final bool fillRows;
  const DashGrid({super.key, super.children, this.gap = 10, this.minColumn = 130, this.fillRows = false});

  /// Columns for a grid [width] dp wide in a window [windowWidth] dp wide; [minColumn] is already scaled (see [minColumnFor]).
  static int columnsFor(double width, double windowWidth, {double gap = 10, double minColumn = 130}) {
    var cols = sizeFor(windowWidth) == LayoutSize.expanded ? 4 : 2;
    while (cols > 1 && (width - gap * (cols - 1)) / cols < minColumn) {
      cols = cols == 4 ? 2 : 1;
    }
    return cols;
  }

  /// The column minimum at the given text scaler.
  static double minColumnFor(TextScaler scaler, [double minColumn = 130]) => scaler.scale(minColumn);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderDash(
        windowWidth: MediaQuery.sizeOf(context).width,
        gap: gap,
        minColumn: minColumnFor(MediaQuery.textScalerOf(context), minColumn),
        fillRows: fillRows,
      );

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) {
    renderObject as _RenderDash;
    renderObject
      ..windowWidth = MediaQuery.sizeOf(context).width
      ..gap = gap
      ..minColumn = minColumnFor(MediaQuery.textScalerOf(context), minColumn)
      ..fillRows = fillRows;
  }
}

class _Place {
  final RenderBox child;
  final int row, rows;
  int col, span;
  double width;
  double natural = 0;
  _Place(this.child, this.row, this.col, this.span, this.rows, this.width);
  int get end => row + rows - 1;
}

class _RenderDash extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _DashParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _DashParentData> {
  _RenderDash({required double windowWidth, required double gap, required double minColumn, required bool fillRows})
      : _windowWidth = windowWidth,
        _gap = gap,
        _minColumn = minColumn,
        _fillRows = fillRows;

  double _windowWidth, _gap, _minColumn;
  bool _fillRows;
  set fillRows(bool v) {
    if (v == _fillRows) return;
    _fillRows = v;
    markNeedsLayout();
  }

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

    // Place every tile in reading order on a grid of cells; a tall tile blocks the cells under it.
    final taken = <List<bool>>[];
    bool free(int r, int c, int span, int rows) {
      for (var rr = r; rr < r + rows && rr < taken.length; rr++) {
        for (var cc = c; cc < c + span; cc++) {
          if (taken[rr][cc]) return false;
        }
      }
      return true;
    }

    final places = <_Place>[];
    var r = 0, c = 0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as _DashParentData;
      final span = data.span.clamp(1, cols);
      final rows = span < cols ? data.rowSpan.clamp(1, 1 << 10) : 1;
      while (true) {
        if (c + span > cols) {
          if (_fillRows && c > 0 && free(r, c, cols - c, 1)) {
            final rowPlaces = [
              for (final q in places)
                if (q.row == r && q.rows == 1) q
            ];
            if (rowPlaces.isNotEmpty && rowPlaces.fold<int>(0, (n, q) => n + q.span) == c) {
              for (var i = 0; i < cols - c; i++) {
                rowPlaces[rowPlaces.length - 1 - i % rowPlaces.length].span++;
              }
              var col = 0;
              for (final q in rowPlaces) {
                q.col = col;
                col += q.span;
                q.width = colW * q.span + _gap * (q.span - 1);
                q.child.layout(BoxConstraints.tightFor(width: q.width), parentUsesSize: true);
                q.natural = q.child.size.height;
              }
              for (var cc = c; cc < cols; cc++) {
                taken[r][cc] = true;
              }
            }
          }
          r++;
          c = 0;
        } else if (!free(r, c, span, rows)) {
          c++;
        } else {
          break;
        }
      }
      while (taken.length < r + rows) {
        taken.add(List.filled(cols, false));
      }
      for (var rr = r; rr < r + rows; rr++) {
        for (var cc = c; cc < c + span; cc++) {
          taken[rr][cc] = true;
        }
      }
      final width = colW * span + _gap * (span - 1);
      final place = _Place(child, r, c, span, rows, width);
      child.layout(BoxConstraints.tightFor(width: width), parentUsesSize: true);
      place.natural = child.size.height;
      places.add(place);
      c += span;
    }

    // Row heights: the tallest single-row tile; a tall tile that does not fit its rows widens the last of them.
    final rowH = List<double>.filled(taken.length, 0);
    for (final p in places.where((p) => p.rows == 1)) {
      if (p.natural > rowH[p.row]) rowH[p.row] = p.natural;
    }
    final tall = places.where((p) => p.rows > 1).toList()..sort((a, b) => a.end.compareTo(b.end));
    for (final p in tall) {
      var have = _gap * (p.rows - 1);
      for (var i = p.row; i <= p.end; i++) {
        have += rowH[i];
      }
      if (p.natural > have) rowH[p.end] += p.natural - have;
    }
    final top = List<double>.filled(taken.length, 0);
    for (var i = 1; i < taken.length; i++) {
      top[i] = top[i - 1] + rowH[i - 1] + _gap;
    }
    for (final p in places) {
      final h = top[p.end] + rowH[p.end] - top[p.row];
      // A minimum height, not a tight one: a tight size would make the tile a relayout boundary, and a tile that grows later (a form
      // showing its verdict) would never reach this grid again and paint past its own box.
      if ((p.child.size.height - h).abs() > 0.01) {
        p.child.layout(BoxConstraints(minWidth: p.width, maxWidth: p.width, minHeight: h), parentUsesSize: true);
      }
      (p.child.parentData! as _DashParentData).offset = Offset(p.col * (colW + _gap), top[p.row]);
    }
    size = constraints.constrain(Size(w, taken.isEmpty ? 0 : top.last + rowH.last));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);
}

/// A paper tile: 12 dp radius, `surface` on the `desk`, a 1 px `line` border, no shadow. With [onTap] it answers a touch with
/// the ink response (no chevron). [semanticLabel] replaces what a screen reader would read from the parts. [attention] marks a tile
/// that needs the owner (a 2 px accent border instead of the 1 px line, and "Needs action" in the spoken label): put a chip or a
/// word on the tile too, the border is not the only cue.
class Tile extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;
  final bool attention;

  /// Keep the parts of the tile (buttons, rows) in the semantics tree next to [semanticLabel] instead of replacing them.
  final bool exposeChildren;
  const Tile(
      {super.key,
      required this.child,
      this.onTap,
      this.padding = const EdgeInsets.all(12),
      this.semanticLabel,
      this.attention = false,
      this.exposeChildren = false});

  static const radius = 12.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final body = Material(
      color: c.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: attention ? c.accent : c.line, width: attention ? 2 : 1),
      ),
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
    if (semanticLabel == null) return body;
    return Semantics(
      container: true,
      button: onTap != null,
      label: attention ? 'Needs action: $semanticLabel' : semanticLabel,
      onTap: onTap,
      excludeSemantics: !exposeChildren,
      child: body,
    );
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

/// Something small that sits in a tile's label row or under its number and says its state in an icon or a word, never in colour
/// alone. [spoken] is what a screen reader says.
abstract class DashChip extends StatelessWidget {
  const DashChip({super.key});
  String get spoken;
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final IconData? trailing;
  final String text;
  final Color fg, bg;
  const _Chip({required this.icon, required this.text, required this.fg, required this.bg, this.trailing});
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(4, 2, trailing == null ? 8 : 4, 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 2),
            Flexible(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: BwType.metaSize, fontWeight: FontWeight.w600, color: fg)),
            ),
            if (trailing != null) ...[const SizedBox(width: 3), Icon(trailing, size: 14, color: fg)],
          ]),
        ),
      );
}

enum Trend { up, down, flat }

/// A change against something: ▲ / ▼ / – and the figure and a word ("12 % vs last period"). [good] says whether that direction is
/// good news (spending up is not): a green ground and a check, or a red ground and a warning icon, and "better" / "worse" for a
/// screen reader; null = neutral, no second icon.
class DeltaChip extends DashChip {
  final Trend trend;
  final String text;
  final bool? good;
  const DeltaChip({super.key, required this.trend, required this.text, this.good});

  @override
  String get spoken => '${switch (trend) {
        Trend.up => 'up',
        Trend.down => 'down',
        Trend.flat => 'unchanged'
      }} $text${good == null ? '' : (good! ? ', better' : ', worse')}';

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
    final second = good == null ? null : (good! ? Icons.check_circle_outline : Icons.error_outline);
    return _Chip(icon: icon, text: text, fg: fg, bg: bg, trailing: second);
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

/// A muted note in a tile's label row, such as a date ("30 Oct"). Text only.
class TileNote extends DashChip {
  final String text;
  const TileNote(this.text, {super.key});
  @override
  String get spoken => text;
  @override
  Widget build(BuildContext context) => Text(text,
      textAlign: TextAlign.end,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: BwType.metaSize, color: context.c.muted));
}

/// A small text action in a tile's label row ("Edit"). It is a button of its own (48 dp high), so a [StatTile] with one reads its
/// parts instead of one sentence.
class TileAction extends DashChip {
  final String label;
  final VoidCallback onTap;
  const TileAction({super.key, required this.label, required this.onTap});
  @override
  String get spoken => label;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: touchMin, minWidth: touchMin),
          child: Center(
            widthFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(label,
                  maxLines: 1, style: TextStyle(fontSize: BwType.metaSize, fontWeight: FontWeight.w600, color: context.c.accent)),
            ),
          ),
        ),
      );
}

/// A small (i) in a tile's label row: the help text of the tile opens behind it (a short sheet), never on the dashboard. It is a
/// button of its own (48 dp), so a [StatTile] with one reads its parts instead of one sentence.
class TileInfo extends DashChip {
  final VoidCallback onTap;
  final String label;
  const TileInfo({super.key, required this.onTap, this.label = 'What is this?'});
  @override
  String get spoken => label;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: touchMin, minWidth: touchMin),
            child: Center(widthFactor: 1, child: Icon(Icons.info_outline, size: 20, color: context.c.ink2)),
          ),
        ),
      );
}

String _spokenJoin(List<String?> parts) => parts.whereType<String>().where((p) => p.isNotEmpty).join(', ');

/// One number: label (1–3 words) with an optional [trailing] note, chip or action at the right of it, the figure scaled down to fit
/// (never wrapped, never rounded), an optional sub line, one optional [visual] (shown only, not tappable; [visualSpoken] says it) and
/// one optional [chip].
class StatTile extends StatelessWidget {
  final String label, value;
  final String? sub, visualSpoken;
  final Widget? visual;
  final DashChip? chip, trailing;
  final VoidCallback? onTap;
  final Color? valueColor;
  final bool attention;
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.visual,
    this.visualSpoken,
    this.chip,
    this.trailing,
    this.onTap,
    this.valueColor,
    this.attention = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Tile(
      onTap: onTap,
      attention: attention,
      semanticLabel: trailing is TileAction || trailing is TileInfo
          ? null
          : _spokenJoin([label, value, sub, trailing?.spoken, visualSpoken, chip?.spoken]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        trailing == null ? TileLabel(label) : SplitRow(start: TileLabel(label), end: trailing!),
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
        if (visual != null) Padding(padding: const EdgeInsets.only(top: 8), child: IgnorePointer(child: visual)),
        if (chip != null) Padding(padding: const EdgeInsets.only(top: 8), child: chip),
      ]),
    );
  }
}

/// The big tile of a dashboard (Today's hero): the exact figure scaled to fit, a [StateChip], a [dots] slot (the day dots, shown
/// only; [dotsSpoken] says them) and a pace meter with the expected mark ([paceUsed] and [paceExpected] as 0..1 shares; [paceSpoken]
/// says it). Wrap it in `DashItem(span: 2, rowSpan: 2)` for the desktop 2×2 hero.
class HeroTile extends StatelessWidget {
  final String label, value;
  final String? sub, dotsSpoken, paceSpoken;
  final DashChip? chip;
  final Widget? dots;

  /// A tighter [dots] (the same widget at a smaller size) and the widths of both, so the tile can put the grid beside the figure:
  /// beside it whenever the figure keeps at least [dotsMinScale] of its size, under it otherwise.
  final Widget? dotsCompact;
  final double dotsWidth, dotsCompactWidth;
  static const double dotsGap = 12, dotsMinScale = 0.65;
  final double? paceUsed, paceExpected;
  final bool paceOver;
  final VoidCallback? onTap;
  final Color? valueColor;

  /// The tile spans a whole wide row: the figure, its note and the pace meter on the left, the [dots] on the right (no measuring).
  final bool wide;

  /// A key for the figure's own `Text` (tests and screens that read the number).
  final Key? valueKey;
  const HeroTile({
    super.key,
    this.wide = false,
    this.valueKey,
    required this.label,
    required this.value,
    this.sub,
    this.chip,
    this.dots,
    this.dotsCompact,
    this.dotsWidth = 0,
    this.dotsCompactWidth = 0,
    this.dotsSpoken,
    this.paceUsed,
    this.paceExpected,
    this.paceOver = false,
    this.paceSpoken,
    this.onTap,
    this.valueColor,
  })  : assert(dots == null || dotsWidth > 0, 'dots needs dotsWidth so the tile can decide beside or under'),
        assert(dotsCompact == null || dotsCompactWidth > 0, 'dotsCompact needs dotsCompactWidth');

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hasPace = paceUsed != null && paceExpected != null;
    final style = dashNumStyle(size: 44, color: valueColor ?? c.ink);
    final number = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(_narrowGap(value, style), key: valueKey, maxLines: 1, style: style),
    );
    final subText = sub == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(sub!, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
          );
    final chipRow = chip == null ? null : Padding(padding: const EdgeInsets.only(top: 8), child: chip);
    Widget figure() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [number, if (subText != null) subText, if (chipRow != null) chipRow]);
    Widget slot(Widget w) => IgnorePointer(child: w);

    final pace = !hasPace
        ? null
        : Padding(padding: const EdgeInsets.only(top: 12), child: PaceMeter(used: paceUsed!, expected: paceExpected!, over: paceOver));
    if (wide && dots != null) {
      return Tile(
        onTap: onTap,
        semanticLabel: _spokenJoin([label, value, sub, chip?.spoken, dotsSpoken, paceSpoken]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          TileLabel(label),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [figure(), if (pace != null) pace])),
            const SizedBox(width: dotsGap * 2),
            slot(dots!),
          ]),
        ]),
      );
    }

    final body = LayoutBuilder(builder: (context, box) {
      if (dots == null) return figure();
      // The dots beside the figure whenever they fit: the figure may shrink to [dotsMinScale] of its size, the grid to its compact
      // size; under the figure only when even that does not fit (320 dp at a large text scale, a huge amount).
      final natural = _naturalWidth(context, value, style);
      for (final compact in const [false, true]) {
        final grid = compact ? dotsCompactWidth : dotsWidth;
        final w = compact ? dotsCompact : dots;
        if (w == null) continue;
        if (box.maxWidth - dotsGap - grid >= natural * dotsMinScale) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: figure()),
            const SizedBox(width: dotsGap),
            slot(w),
          ]);
        }
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        figure(),
        Padding(padding: const EdgeInsets.only(top: 12), child: slot(dots!)),
      ]);
    });

    return Tile(
      onTap: onTap,
      semanticLabel: _spokenJoin([label, value, sub, chip?.spoken, dotsSpoken, paceSpoken]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        TileLabel(label),
        const SizedBox(height: 6),
        body,
        if (pace != null) pace,
      ]),
    );
  }

  /// The hero figure as one text: the number, a narrow no-break space (0.4 of the size, as `MoneyText`) and the currency sign, so
  /// the big number keeps its sign close without a widget in between.
  static TextSpan _narrowGap(String text, TextStyle style) {
    final i = text.indexOf('\u00A0');
    if (i < 0) return TextSpan(text: text, style: style);
    return TextSpan(style: style, children: [
      TextSpan(text: text.substring(0, i)),
      TextSpan(text: '\u00A0', style: TextStyle(fontSize: (style.fontSize ?? 14) * 0.4)),
      TextSpan(text: text.substring(i + 1)),
    ]);
  }

  /// The figure's width at full size and the current text scale.
  static double _naturalWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: _narrowGap(text, style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
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

/// Ruled rows for a tile (a name, a muted line, a state chip and a mono amount): the Ledger list inside a tile. A tappable row is at
/// least [touchMin] high.
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
          label: _spokenJoin([r.title, r.amount, r.sub, r.chip?.spoken]),
          onTap: r.onTap,
          excludeSemantics: true,
          child: InkWell(
            key: r.key,
            onTap: r.onTap,
            child: RuledRow(
              minHeight: r.onTap != null ? touchMin : rowMin,
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
