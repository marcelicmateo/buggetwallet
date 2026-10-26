import 'package:flutter/widgets.dart';

/// Rebuilds [builder] whenever [listenable] changes, but only while this part of the tree is shown (a tab of the shell's
/// IndexedStack is not: its tickers are off). A hidden page keeps what it last built and builds again when it is shown or when its
/// parent gives it new widgets (data or day changed), so a change made on this device while it was hidden still shows.
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
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_shown) {
      setState(() => _built = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    _shown = TickerMode.valuesOf(context).enabled;
    if (!_shown && _built != null) return _built!;
    return _built = widget.builder(context);
  }
}
