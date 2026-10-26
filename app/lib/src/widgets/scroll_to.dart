import 'package:flutter/widgets.dart';

/// Scrolls the page of [scroll] until the widget with [key] is on screen. A ListView builds only the rows near the window, so when
/// the widget is not built yet the page is moved down a screen at a time until it is (at most 12 steps). [alive] says whether the
/// caller is still mounted.
Future<void> scrollToKey(ScrollController scroll, GlobalKey key, {required bool Function() alive}) async {
  for (var i = 0; i < 12 && alive(); i++) {
    await WidgetsBinding.instance.endOfFrame;
    final c = key.currentContext;
    if (c != null && c.mounted) {
      await Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250));
      return;
    }
    if (!scroll.hasClients || scroll.position.pixels >= scroll.position.maxScrollExtent) return;
    scroll.jumpTo((scroll.position.pixels + 400).clamp(0.0, scroll.position.maxScrollExtent));
  }
}
