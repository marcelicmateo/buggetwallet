// Device settings in the controller: reminders (nudges), theme and number style, explainers seen, the log level,
// and the log files. A `part` of controller.dart so it can use `_changed`.
//
// Privacy: logs carry setting words and keys only, never values the owner typed.
part of 'controller.dart';

extension DeviceSettings on WalletController {
  /// Device-local (never synced): show the import preview before every import (default on, Q4). Off = files go straight in.
  bool get importPreviewAlways => repo.localValue('importPreview') != '0';

  void setImportPreviewAlways(bool on) {
    repo.setLocalValue('importPreview', on ? null : '0');
    logEvent(_import, Level.INFO, 'import.previewSetting', {'on': on});
    notifyListeners();
  }

  /// Device-local (never synced): are reminders on?
  bool get nudgesEnabled => repo.localValue('nudgesEnabled') == '1';

  /// Turns reminders on or off. On: asks the system for permission first; when refused the switch stays off and
  /// [nudgesDenied] says why. Returns whether reminders are on afterwards.
  Future<bool> setNudges(bool on) async {
    try {
      if (!on) {
        repo.setLocalValue('nudgesEnabled', null);
        nudgesDenied = false;
        await nudges.cancelAll();
        logEvent(_nudgeLog, Level.INFO, 'nudges.enabled', {'on': false});
        notifyListeners();
        await rescheduleHeadsUps(); // cancelAll took the heads-ups too
        return false;
      }
      final granted = await nudges.requestPermission();
      logEvent(_nudgeLog, Level.INFO, 'nudges.enabled', {'on': granted, 'granted': granted});
      nudgesDenied = !granted;
      if (granted) repo.setLocalValue('nudgesEnabled', '1');
      notifyListeners();
      if (granted) await rescheduleNudges();
      return granted;
    } catch (e, st) {
      logError(_nudgeLog, 'nudges.setFailed', e, st, fields: {'on': on});
      notifyListeners();
      return nudgesEnabled;
    }
  }

  /// Schedules the next days of reminders again (app start, resume): the list is only ever 4 weeks long.
  Future<void> rescheduleNudges() async {
    if (!nudges.supported) return;
    if (nudgesEnabled) {
      try {
        final n = await nudges.schedule(nudgeSlots(_clock()));
        logEvent(_nudgeLog, Level.INFO, 'nudges.scheduled', {'count': n});
      } catch (e, st) {
        logError(_nudgeLog, 'nudges.scheduleFailed', e, st);
      }
    }
    await rescheduleHeadsUps(); // scheduling the reminders cancelled everything, heads-ups included
  }

  // ---------- look (device-local) ----------
  /// Theme mode: 'system' (default), 'light' or 'dark'. Device-local, never synced.
  String get themeModeName {
    final v = repo.localValue('themeMode');
    return v == 'light' || v == 'dark' ? v! : 'system';
  }

  void setThemeMode(String mode) {
    if (mode != 'system' && mode != 'light' && mode != 'dark') return;
    final from = themeModeName;
    if (mode == from) return;
    repo.setLocalValue('themeMode', mode);
    logEvent(_log, Level.INFO, 'theme.mode', {'from': from, 'to': mode});
    notifyListeners();
  }

  /// Number style: 'point' (1,234.50, default) or 'comma' (1.234,50). Device-local, never synced.
  String get numberStyleName => _numberStyle.name;

  void _applyNumberStyle() => numberStyle = _numberStyle = NumberStyle.fromName(repo.localValue('numberStyle'));

  void setNumberStyle(String style) {
    if (style != 'point' && style != 'comma') return;
    if (style == numberStyleName) return;
    repo.setLocalValue('numberStyle', style);
    _numberStyle = NumberStyle.fromName(style);
    logEvent(_log, Level.INFO, 'number.style', {'style': style});
    notifyListeners();
  }

  /// Explore's switch: 'spending' (default) or 'tags'. Device-local, never synced, remembered across starts (an old 'plan' value reads as spending).
  String get budgetView => switch (repo.localValue('budgetView')) { final v? when _budgetViews.contains(v) => v, _ => 'spending' };

  static const _budgetViews = {'tags'};

  /// Plan's switch: 'payday' (default) or 'saving'. Device-local like [budgetView].
  String get planView => repo.localValue('planView') == 'saving' ? 'saving' : 'payday';

  void setPlanView(String view) {
    if (view != 'payday' && view != 'saving') return;
    if (view == planView) return;
    repo.setLocalValue('planView', view == 'payday' ? null : view);
    logEvent(_log, Level.INFO, 'plan.view', {'view': view});
    notifyListeners();
  }

  /// Chooses Spending or Tags on Explore. Links call it before they switch tabs.
  void setBudgetView(String view) {
    if (view != 'spending' && !_budgetViews.contains(view)) return;
    if (view == budgetView) return;
    repo.setLocalValue('budgetView', view == 'spending' ? null : view);
    logEvent(_log, Level.INFO, 'budget.view', {'view': view});
    notifyListeners();
  }

  /// The Today number tiles, in their default order (UX-B B4). The tiles that need action are not here: they always come first.
  static const todayTileIds = ['left', 'payday', 'before', 'budget', 'held', 'income', 'reviewed', 'add', 'recent'];

  /// The order of the Today number tiles (every id once) and the hidden ones. Device-local, never synced. Stored as
  /// `order|hidden` (ids, comma separated); an unknown id is ignored, a tile missing from the list is appended.
  ({List<String> order, Set<String> hidden}) get todayTiles {
    final parts = (repo.localValue('todayTiles') ?? '|').split('|');
    List<String> ids(String s) => s.split(',').where(todayTileIds.contains).toList();
    final order = ids(parts[0]).toSet().toList();
    return (
      order: [...order, ...todayTileIds.where((id) => !order.contains(id))],
      hidden: parts.length > 1 ? ids(parts[1]).toSet() : <String>{}
    );
  }

  /// Saves the order and the hidden tiles (nothing stored when it equals the default).
  void setTodayTiles(List<String> order, Set<String> hidden) {
    final isDefault = hidden.isEmpty && order.join(',') == todayTileIds.join(',');
    repo.setLocalValue('todayTiles', isDefault ? null : '${order.join(',')}|${hidden.join(',')}');
    logEvent(_log, Level.INFO, 'today.tiles', {'hidden': hidden.length});
    notifyListeners();
  }

  /// Whether the explainer paragraphs (the muted text under section heads) have been shown once. Device-local.
  bool explainerSeen(String key) => repo.localValue('explainer:$key') != null;

  /// Notes that the explainer [key] was shown; later it starts collapsed behind an info icon.
  void markExplainerSeen(String key) {
    if (explainerSeen(key)) return;
    repo.setLocalValue('explainer:$key', today());
  }

  // ---------- diagnostics ----------
  /// Device-local log level: 'all' (debug, the default while testing), 'info' or 'warning'.
  String get logLevel => repo.localValue('logLevel') ?? 'all';

  void setLogLevel(String level) {
    final from = logLevel;
    repo.setLocalValue('logLevel', level);
    AppLog.setLevel(level); // first, so the event below is logged at the new level
    logEvent(_log, Level.INFO, 'log.level', {'from': from, 'to': level});
    notifyListeners();
  }

  Future<LogStats> logStats() => AppLog.stats();

  String logFileName() => 'budget-wallet-logs-${today()}.txt';

  /// All logs as one text file's bytes.
  Future<Uint8List> logBytes() async => Uint8List.fromList(utf8.encode(await AppLog.combined()));

  Future<void> clearLogs() => AppLog.clear();
}
