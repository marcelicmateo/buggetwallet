// A write refused because this device's clock is behind the wallet's newest change (core's ClockBehindException, H7). Writes
// happen all over the app, so the error hooks (logging.dart) hand it here and `BudgetWalletApp` shows one sentence in a dialog.
import 'package:flutter/foundation.dart';
import 'package:sqlite3/common.dart' show SqliteException;
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

/// The toast for a write the database refused (I8): nothing was saved, so say so instead of failing quietly.
const writeFailedText = "Couldn't save. Nothing was changed.";

/// Counts failed writes (not the clock case, which has its own dialog); the app listens and shows [writeFailedText].
final ValueNotifier<int> writeFailedNotice = ValueNotifier(0);

/// True (and the toast is raised) when [error] is a database error thrown by a write on the screen's own call stack. The caller
/// still logs it (error type only).
bool noticeWriteFailed(Object error) {
  if (error is! SqliteException) return false;
  writeFailedNotice.value++;
  return true;
}
