// The home-screen widget and the launcher shortcut in the controller (P13, spec docs/context/P13_SPEC.md §1 and §2). A `part` of
// controller.dart. Android only: everywhere else [NoHomeWidget] does nothing.
//
// Privacy: the widget gets three words only (the already formatted amount of "Safe to spend today", a status word and the day it was
// computed). Logs carry flags only (`widget.update {changed}`, `shortcut.used {action}`), never the amount.
part of 'controller.dart';

final _homeLog = Logger('bw.widget');

extension HomeIntegration on WalletController {
  /// Is a wallet open (not the onboarding placeholder, not the locked web start)? Only then does the widget show numbers.
  bool get _walletOpen => !_dbPending && !locked;

  /// What the widget shows now: [WidgetStatus.ok] with today's safe amount, `overToday` / `overBudget` / `ended` with 0.
  /// The amount is never negative (like the Today hero).
  HomeWidgetState widgetState() {
    final p = period();
    final cur = currency;
    final status = p.paydayPassed
        ? WidgetStatus.ended
        : p.overToday > 0
            ? WidgetStatus.overToday
            : p.overBudget
                ? WidgetStatus.overBudget
                : WidgetStatus.ok;
    final cents = status == WidgetStatus.ok ? p.safeToday : 0;
    final amount = cents > 0 && cents < 10000 ? moneyExact(cents, cur) : money(cents, cur, decimals: 0);
    return HomeWidgetState(amount: amount, status: status, date: today());
  }

  /// Called after every reload and day change: one update per burst, and only when the words changed.
  void _widgetMayHaveChanged() {
    if (!homeWidget.supported || _widgetQueued) return;
    _widgetQueued = true;
    scheduleMicrotask(() {
      _widgetQueued = false;
      unawaited(updateHomeWidget());
    });
  }

  /// Sends the current numbers to the widget when they differ from what it was last given (resume calls this too). Without an open
  /// wallet the widget is cleared. Failures are logged and never thrown.
  Future<void> updateHomeWidget() async {
    if (!homeWidget.supported) return;
    try {
      if (!_walletOpen) {
        if (_widgetSent != null) {
          _widgetSent = null;
          await homeWidget.clear();
          logEvent(_homeLog, Level.INFO, 'widget.update', {'changed': true, 'cleared': true});
        }
        return;
      }
      final state = widgetState();
      final changed = state != _widgetSent;
      if (changed) {
        _widgetSent = state;
        await homeWidget.update(state);
      }
      logEvent(_homeLog, changed ? Level.INFO : Level.FINE, 'widget.update', {'changed': changed});
    } on Object catch (e, st) {
      _widgetSent = null; // try again next time
      logError(_homeLog, 'widget.updateFailed', e, st);
    }
  }

  /// Forgets what the widget was given and blanks it at once (another wallet is about to open, or this one is forgotten).
  Future<void> clearHomeWidget() async {
    if (!homeWidget.supported) return;
    _widgetSent = null;
    try {
      await homeWidget.clear();
      logEvent(_homeLog, Level.INFO, 'widget.update', {'changed': true, 'cleared': true});
    } on Object catch (e, st) {
      logError(_homeLog, 'widget.updateFailed', e, st);
    }
  }

  // ---------- launcher shortcut ----------

  /// Starts listening for shortcut actions: the one that started the app, then those of a running app.
  void startHomeIntegration() {
    if (!homeWidget.supported) return;
    _actionSub ??= homeWidget.actions.listen(onShortcut);
    scheduleMicrotask(() async {
      try {
        final first = await homeWidget.initialAction();
        if (first != null) onShortcut(first);
      } on Object catch (e, st) {
        logError(_homeLog, 'shortcut.failed', e, st);
      }
    });
  }

  /// A shortcut action arrived. `addExpense` opens the Add expense sheet once the wallet is open; with no wallet (onboarding, locked)
  /// it is ignored.
  void onShortcut(String action) {
    if (action != addExpenseAction) return;
    final open = _walletOpen;
    logEvent(_homeLog, Level.INFO, 'shortcut.used', {'action': action, 'open': open});
    if (!open) return;
    _shortcutAddPending = true;
    if (!_shortcutAdds.isClosed) _shortcutAdds.add(null);
  }

  /// Fires when a shortcut asks for the Add expense sheet (see [takeShortcutAdd]).
  Stream<void> get shortcutAdds => _shortcutAdds.stream;

  /// True once per shortcut request: the screen that opens the sheet takes it, so a request made before the shell was built is not lost
  /// and is never answered twice.
  bool takeShortcutAdd() {
    final v = _shortcutAddPending;
    _shortcutAddPending = false;
    return v;
  }
}
