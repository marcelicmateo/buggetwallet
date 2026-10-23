import 'package:flutter/material.dart';

import '../layout.dart';
import '../logging.dart';
import '../page_reload.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Web: the wallet is open in another tab of this browser. This tab opened nothing, so the two cannot overwrite each other.
class InUseScreen extends StatefulWidget {
  /// Reloads the page; tests pass their own.
  final void Function() onReload;
  const InUseScreen({super.key, this.onReload = reloadPage});
  @override
  State<InUseScreen> createState() => _InUseScreenState();
}

class _InUseScreenState extends State<InUseScreen> {
  @override
  void initState() {
    super.initState();
    AppLog.setScreen('inUse');
    logNav('inUse.show');
  }

  @override
  Widget build(BuildContext context) => GatePage(children: [
        const Muted('Budget Wallet is open in another tab. Close it, then reload this one.', size: BwType.bodySize),
        FilledButton(
          key: const ValueKey('inUseReload'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(buttonMin)),
          onPressed: () {
            logNav('inUse.reload');
            widget.onReload();
          },
          child: const Text('Reload', style: TextStyle(fontSize: BwType.headingSize)),
        ),
      ]);
}
