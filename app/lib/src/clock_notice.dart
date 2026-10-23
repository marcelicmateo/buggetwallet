// A write refused because this device's clock is behind the wallet's newest change (core's ClockBehindException, H7). Writes
// happen all over the app, so the error hooks (logging.dart) hand it here and `BudgetWalletApp` shows one sentence in a dialog.
import 'package:flutter/foundation.dart';
import 'package:wallet_core/wallet_core.dart';

final _log = Logger('bw.app');

/// The sentence shown. No dates, no clock values.
const clockBehindText = "This device's clock is behind. Set the date and time, then try again.";

/// Counts refused writes; the app listens and shows [clockBehindText].
final ValueNotifier<int> clockBehindNotice = ValueNotifier(0);

/// True (and the notice is raised) when [error] is a refused write; the caller then does not report it as a crash.
bool noticeClockBehind(Object error) {
  if (error is! ClockBehindException) return false;
  logEvent(_log, Level.WARNING, 'write.clockBehind');
  clockBehindNotice.value++;
  return true;
}
