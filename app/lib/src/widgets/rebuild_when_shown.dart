import 'package:flutter/widgets.dart';

/// Rebuilds [builder] whenever [listenable] changes, but only while this part of the tree is shown (a tab of the shell's
/// IndexedStack is not: the shell turns its tickers off). A hidden page keeps what it last built. It builds again when it is shown
/// only if something changed meanwhile (the listenable, a new widget from the parent, or an inherited value such as the theme),
/// so showing the tab again with no change costs nothing.
class RebuildWhenShown extends StatefulWidget {
  final Listenable listenable;
  final WidgetBuilder builder;
  const RebuildWhenShown({super.key, required this.listenable, required this.builder});
  @override
  State<RebuildWhenShown> createState() => _RebuildWhenShownState();
}

class _RebuildWhenShownState extends State<RebuildWhenShown> {
  Widget? _built;
  bool _shown = true;

  /// Something changed while hidden: build again when shown.
  bool _missed = false;

  /// The last TickerMode value seen: a dependency change with the same value is something else (theme, text scale...).
  bool? _lastEnabled;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(RebuildWhenShown old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _built = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    // Not the first call, and the tab was neither shown nor hidden: another inherited value changed.
    if (_lastEnabled != null && _lastEnabled == enabled) _missed = true;
    _lastEnabled = enabled;
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_shown) {
      setState(() => _built = null);
    } else {
      _missed = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    _shown = TickerMode.valuesOf(context).enabled;
    // Nothing missed, or hidden: keep what was built (a missed change waits for the tab to be shown).
    if (_built != null && (!_missed || !_shown)) return _built!;
    _missed = false;
    return _built = widget.builder(context);
  }
}
