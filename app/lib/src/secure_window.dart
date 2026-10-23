// Android only: while the wallet key is on screen the window is secure (no screenshots, no screen recording, no thumbnail in
// the recent-apps list). `MainActivity.kt` answers `bw/secure` `setSecure(bool)` with FLAG_SECURE. Nothing else is touched
// on other platforms. The key is never passed through here.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wallet_core/wallet_core.dart';

import 'platform.dart';

final _log = Logger('bw.app');

const _channel = MethodChannel('bw/secure');

/// How many key views are open; the flag goes off only when the last one closes.
int _open = 0;

/// Changes when [resetSecureWindowCount] runs, so a view left over from before the reset does not count itself out.
int _epoch = 0;

/// Tests start from zero open key views.
@visibleForTesting
void resetSecureWindowCount() {
  _open = 0;
  _epoch++;
}

Future<void> _set(bool on) async {
  try {
    await _channel.invokeMethod<void>('setSecure', on);
    logEvent(_log, Level.FINE, 'secure.set', {'on': on});
  } on Object catch (e, st) {
    logError(_log, 'secure.failed', e, st, fields: {'on': on});
  }
}

/// Marks the window secure from the moment it is built until it is removed (closed, popped or disposed). A no-op off Android.
class SecureWindow extends StatefulWidget {
  final Widget child;
  const SecureWindow({super.key, required this.child});
  @override
  State<SecureWindow> createState() => _SecureWindowState();
}

class _SecureWindowState extends State<SecureWindow> {
  bool _on = false;
  final int _mine = _epoch;

  @override
  void initState() {
    super.initState();
    if (!isAndroid) return;
    _on = true;
    if (++_open == 1) _set(true);
  }

  @override
  void dispose() {
    if (_on && _mine == _epoch && --_open == 0) _set(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
