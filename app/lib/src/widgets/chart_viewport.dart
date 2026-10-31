// ChartViewport (stage ZC): the gesture layer of a time graph. It owns the window the graph shows and turns a drag (move through
// time, with a fling), a pinch or double tap (zoom), the mouse wheel (Shift = move, Ctrl = zoom), the arrow and + / − keys and the
// buttons into a new window, kept inside the data and the limits (`chart_window.dart`). Our own layer, not fl_chart's: the picture
// must get finer bars when it zooms in, not just stretch.
//
// While the fingers move, only the graph redraws (`chart` gets the live window and its bar size, and reads sums from the day index).
// When they stop the window is committed: `onCommit` (the dates line, the drill-down target), `legend` and `rows` are built for it, and
// `insights.view {graph, bucket}` is logged (no dates, no amounts).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';

import '../chart_window.dart';
import '../layout.dart';
import '../theme.dart';

final _log = Logger('bw.insights');

/// A part of the viewport built for a window and the bar size it gets.
typedef ViewBuilder = Widget Function(BuildContext context, DateRange window, Bucket bucket);

/// − / + (zoom) and Reset, keys `chartZoomOut_<id>`, `chartZoomIn_<id>`, `chartReset_<id>`. A null callback is a disabled button.
class ZoomButtons extends StatelessWidget {
  final String id;
  final VoidCallback? onIn, onOut, onReset;

  /// Shown between the buttons (the dates, for a graph with no range control of its own).
  final Widget? middle;
  const ZoomButtons({super.key, required this.id, this.onIn, this.onOut, this.onReset, this.middle});

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 4, runSpacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
      IconButton(
          key: ValueKey('chartZoomOut_$id'),
          tooltip: 'Zoom out',
          constraints: const BoxConstraints(minWidth: touchMin, minHeight: touchMin),
          icon: const Icon(Icons.remove),
          onPressed: onOut),
      IconButton(
          key: ValueKey('chartZoomIn_$id'),
          tooltip: 'Zoom in',
          constraints: const BoxConstraints(minWidth: touchMin, minHeight: touchMin),
          icon: const Icon(Icons.add),
          onPressed: onIn),
      if (middle != null) middle!,
      TextButton.icon(
          key: ValueKey('chartReset_$id'),
          style: TextButton.styleFrom(minimumSize: const Size(0, touchMin)),
          onPressed: onReset,
          icon: const Icon(Icons.restart_alt, size: 18),
          label: const Text('Reset')),
    ]);
  }
}

class ChartViewport extends StatefulWidget {
  /// The graph id (keys, logs).
  final String id;

  /// The committed window when something else owns it (an `InsightRange`); with [onCommit]. Without it the viewport keeps its own,
  /// starting at [initial].
  final DateRange? window;
  final DateRange? initial;
  final ValueChanged<DateRange>? onCommit;

  /// Reset when [window] is owned elsewhere; [canReset] says whether it would change anything. Own window: back to [initial].
  final VoidCallback? onReset;
  final bool canReset;

  /// Where a window may go (first day with data, today).
  final ChartEdges Function(DateRange window) edges;

  /// The finest bar size (the forecast's is a day) and how many rods a bar has (the bars may not get thinner than 6 px).
  final Bucket finest;
  final int rodsPerBar;

  /// The graph; redrawn on every frame of a drag.
  final ViewBuilder chart;

  /// Under the graph and the buttons: built for the committed window only.
  final ViewBuilder? legend, rows;

  /// Show the dates between the buttons (the graph has no range control above it).
  final String? Function(DateRange window)? datesText;

  /// Smaller buttons row for a narrow tile.
  final bool buttons;
  const ChartViewport({
    super.key,
    required this.id,
    this.window,
    this.initial,
    this.onCommit,
    this.onReset,
    this.canReset = true,
    required this.edges,
    required this.chart,
    this.legend,
    this.rows,
    this.finest = Bucket.day,
    this.rodsPerBar = 1,
    this.datesText,
    this.buttons = true,
  }) : assert(window != null || initial != null);

  @override
  State<ChartViewport> createState() => _ChartViewportState();
}

class _ChartViewportState extends State<ChartViewport> with SingleTickerProviderStateMixin {
  late DateRange _own = widget.window ?? widget.initial!;
  late final ValueNotifier<DateRange> _live = ValueNotifier(_own);
  final _focus = FocusNode(debugLabel: 'chartViewport');
  late final AnimationController _fling = AnimationController.unbounded(vsync: this)..addListener(_flingTick);
  Timer? _wheelCommit;
  bool _focused = false;
  double _width = 300;

  // The gesture in progress.
  late DateRange _w0;
  late ChartEdges _edges;
  double _f0 = 0.5;
  Offset _start = Offset.zero;
  int _stuck = 0;
  DateRange _flingFrom = DateRange(start: '2000-01-01', end: '2000-01-31');

  DateRange get _committed => widget.window ?? _own;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted && _focus.hasFocus != _focused) setState(() => _focused = _focus.hasFocus);
    });
    FocusManager.instance.addHighlightModeListener(_highlightChanged);
  }

  // The outline shows for a keyboard or mouse user only; a change of mode redraws it.
  void _highlightChanged(FocusHighlightMode _) {
    if (mounted && _focused) setState(() {});
  }

  @override
  void didUpdateWidget(ChartViewport old) {
    super.didUpdateWidget(old);
    final w = widget.window;
    if (w != null && w != old.window && !_fling.isAnimating) _live.value = w;
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_highlightChanged);
    _wheelCommit?.cancel();
    _fling.dispose();
    _live.dispose();
    _focus.dispose();
    super.dispose();
  }

  Bucket _bucket(DateRange w, double width) =>
      bucketFor(w, maxBars: (width / (6.0 * widget.rodsPerBar)).floor().clamp(6, 40), finest: widget.finest);

  void _begin() {
    _fling.stop();
    _wheelCommit?.cancel();
    _w0 = _live.value;
    _edges = widget.edges(_w0);
  }

  void _commit() {
    _wheelCommit?.cancel();
    final w = _live.value;
    if (w == _committed) return;
    _own = w;
    logEvent(_log, Level.INFO, 'insights.view', {'graph': widget.id, 'bucket': _bucket(w, _width).name});
    widget.onCommit?.call(w);
    if (mounted) setState(() {});
  }

  /// A step by a button, a key or a double tap: one window to the next, at once.
  void _jump(DateRange Function(ChartEdges e, DateRange w) f) {
    _begin();
    _live.value = f(_edges, _w0);
    _commit();
  }

  void _zoom(double factor, [double focal = 0.5]) => _jump((e, w) => e.zoom(w, factor, focal: focal));

  void _pan(double windows) => _jump((e, w) {
        var days = (windows * w.days).round();
        if (days == 0) days = windows < 0 ? -1 : 1;
        return e.pan(w, days);
      });

  void _reset() {
    _fling.stop();
    if (widget.window == null) {
      _live.value = widget.initial!;
      _commit();
    } else {
      widget.onReset?.call();
    }
  }

  bool get _canReset => widget.window == null ? _committed != widget.initial : widget.canReset;

  // --- gestures
  void _scaleStart(ScaleStartDetails d) {
    _begin();
    _start = d.localFocalPoint;
    _f0 = (d.localFocalPoint.dx / _width).clamp(0.0, 1.0);
  }

  void _scaleUpdate(ScaleUpdateDetails d) {
    final f1 = (d.localFocalPoint.dx / _width).clamp(0.0, 1.0);
    _live.value = _edges.transform(_w0, d.scale, _f0, f1);
  }

  void _scaleEnd(ScaleEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dx;
    if (d.pointerCount == 0 && v.abs() > 200 && _live.value.days == _w0.days) {
      // A fling: the days per second the finger left behind, slowing down.
      _flingFrom = _live.value;
      _stuck = 0;
      _fling.value = 0;
      _fling.animateWith(FrictionSimulation(0.02, 0, -v / (_width / _w0.days))).then((_) => _commit());
    } else {
      _commit();
    }
  }

  void _flingTick() {
    if (!_fling.isAnimating) return;
    final w = _edges.pan(_flingFrom, _fling.value.round());
    if (w == _live.value) {
      if (++_stuck > 2 && _fling.value.abs() > 1) {
        _fling.stop(); // an edge: no use going on
        _commit();
      }
      return;
    }
    _stuck = 0;
    _live.value = w;
  }

  void _doubleTap(Offset at) => _zoom(2, (at.dx / _width).clamp(0.0, 1.0));

  void _signal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    final zoom = keys.isControlPressed || keys.isMetaPressed;
    final pan = keys.isShiftPressed || e.scrollDelta.dx != 0;
    if (!zoom && !pan) return; // a plain wheel scrolls the page
    GestureBinding.instance.pointerSignalResolver.register(e, (event) {
      event as PointerScrollEvent;
      if (_fling.isAnimating || _wheelCommit == null || !_wheelCommit!.isActive) _begin();
      final cur = _live.value;
      _edges = widget.edges(cur);
      if (zoom) {
        final f = (event.localPosition.dx / _width).clamp(0.0, 1.0);
        _live.value = _edges.zoom(cur, math.exp(-event.scrollDelta.dy / 300), focal: f);
      } else {
        final delta = event.scrollDelta.dx != 0 ? event.scrollDelta.dx : event.scrollDelta.dy;
        _live.value = _edges.pan(cur, (delta / (_width / cur.days)).round());
      }
      _wheelCommit?.cancel();
      _wheelCommit = Timer(const Duration(milliseconds: 250), _commit);
    });
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) {
      _pan(-0.25);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _pan(0.25);
    } else if (k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd || k == LogicalKeyboardKey.equal) {
      _zoom(2);
    } else if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
      _zoom(0.5);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final committed = _committed;
    final edges = widget.edges(committed);
    final dates = widget.datesText?.call(committed);
    return LayoutBuilder(builder: (context, box) {
      _width = math.max(1, box.maxWidth);
      final bucket = _bucket(committed, _width);
      final live = _live;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Focus(
          focusNode: _focus,
          onKeyEvent: _key,
          child: Listener(
            onPointerDown: (_) => _focus.requestFocus(),
            onPointerSignal: _signal,
            child: GestureDetector(
              key: ValueKey('chartGestures_${widget.id}'),
              behavior: HitTestBehavior.opaque,
              onScaleStart: _scaleStart,
              onScaleUpdate: _scaleUpdate,
              onScaleEnd: _scaleEnd,
              onDoubleTapDown: (d) => _start = d.localPosition,
              onDoubleTap: () => _doubleTap(_start),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                    border: Border.all(
                        color: _focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional
                            ? c.lineStrong
                            : Colors.transparent)),
                child: ValueListenableBuilder<DateRange>(
                  valueListenable: live,
                  builder: (context, w, _) => widget.chart(context, w, _bucket(w, _width)),
                ),
              ),
            ),
          ),
        ),
        if (widget.legend != null) widget.legend!(context, committed, bucket),
        if (widget.buttons)
          Align(
            alignment: Alignment.centerLeft,
            child: ZoomButtons(
              id: widget.id,
              onIn: ChartEdges.canZoomIn(committed) ? () => _zoom(2) : null,
              onOut: ChartEdges.canZoomOut(committed) && _canZoomOutMore(edges, committed) ? () => _zoom(0.5) : null,
              onReset: _canReset ? _reset : null,
              middle: dates == null
                  ? null
                  : Text(dates, key: ValueKey('chartDates_${widget.id}'), style: numStyle.copyWith(fontSize: BwType.metaSize)),
            ),
          ),
        if (widget.rows != null) widget.rows!(context, committed, bucket),
      ]);
    });
  }

  bool _canZoomOutMore(ChartEdges e, DateRange w) => e.zoom(w, 0.5) != w;
}
