import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/screens/tags_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Budget › Tags as one page (recommendations, main tags, tags, rules and the Add button); rebuilds with the controller.
Widget tagsWindow(WalletController wc) => Scaffold(body: TagsWindow(wc: wc, switcher: const SizedBox.shrink()));

/// One panel of the Tags window on its own, with the window's add flow (same `tagsAdd` key, same `openTagsAdd`) above it, so a test
/// of a panel's rows is not confused by the other two panels.
Widget panelWithAdd(WalletController wc, Widget Function() panel) => ListenableBuilder(
    listenable: wc,
    builder: (_, __) => Scaffold(
          body: SingleChildScrollView(
            child: Column(children: [
              Builder(
                  builder: (c) =>
                      TextButton(key: const ValueKey('tagsAdd'), onPressed: () => openTagsAdd(c, wc), child: const Text('Add'))),
              panel(),
            ]),
          ),
        ));

/// The one add flow: the Add button, then what to add (`main`, `tag` or `rule`).
Future<void> tapAdd(WidgetTester t, String what) async {
  for (final key in ['tagsAdd', 'tagsAdd:$what']) {
    final f = find.byKey(ValueKey(key));
    await t.ensureVisible(f);
    await t.pump();
    await t.tap(f);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }
  await t.pump(const Duration(milliseconds: 400)); // the choice sheet has closed; the form slides in
}
