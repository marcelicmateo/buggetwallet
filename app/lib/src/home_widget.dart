// Android only (P13): the home-screen widget "Safe to spend today" and the launcher shortcut "Add expense".
//
// Widget: `budget_wallet/widget` `update({amount, status, date, until?})` and `clear()` (MainActivity.kt keeps the three words in the app-private
// SharedPreferences file `bw_widget` and redraws SafeTodayWidget). Nothing else crosses: no payments, names, merchants, balances or key.
// Shortcut: `budget_wallet/shortcut` `getInitialAction()` once at start (the action of the intent that started the app, or null), and
// the native side calls `action` with the same words when the running app gets a new intent. Only the word `addExpense` exists.
import 'dart:async';

import 'package:flutter/services.dart';

import 'platform.dart';

/// What the widget shows. [status] is one of [WidgetStatus]; [date] the day the amount was computed (`YYYY-MM-DD`); [until] (only with
/// [WidgetStatus.ok]) the expected payday the amount runs to (`YYYY-MM-DD`), for the line "to 10 Nov".
class HomeWidgetState {
  final String amount, status, date;
  final String? until;
  const HomeWidgetState({required this.amount, required this.status, required this.date, this.until});
  Map<String, String> toMap() => {'amount': amount, 'status': status, 'date': date, if (until != null) 'until': until!};
  @override
  bool operator ==(Object other) =>
      other is HomeWidgetState && other.amount == amount && other.status == status && other.date == date && other.until == until;
  @override
  int get hashCode => Object.hash(amount, status, date, until);
}

/// The status words the widget understands (its muted line).
class WidgetStatus {
  static const ok = 'ok';
  static const overToday = 'overToday';
  static const overBudget = 'overBudget';
  static const ended = 'ended';
}

/// The shortcut action the app understands.
const addExpenseAction = 'addExpense';

abstract class HomeWidget {
  bool get supported;

  /// Shows [state] on the widgets already on the home screen (a no-op when there are none). Never throws.
  Future<void> update(HomeWidgetState state);

  /// Back to "set up in the app" (no wallet). Never throws.
  Future<void> clear();

  /// The shortcut action that started the app, if any (asked once).
  Future<String?> initialAction();

  /// Shortcut actions of a running app.
  Stream<String> get actions;
}

/// Everywhere but Android.
class NoHomeWidget implements HomeWidget {
  const NoHomeWidget();
  @override
  bool get supported => false;
  @override
  Future<void> update(HomeWidgetState state) async {}
  @override
  Future<void> clear() async {}
  @override
  Future<String?> initialAction() async => null;
  @override
  Stream<String> get actions => const Stream.empty();
}

class AndroidHomeWidget implements HomeWidget {
  final MethodChannel _widget, _shortcut;
  final StreamController<String> _actions = StreamController<String>.broadcast();

  AndroidHomeWidget({MethodChannel? widget, MethodChannel? shortcut})
      : _widget = widget ?? const MethodChannel('budget_wallet/widget'),
        _shortcut = shortcut ?? const MethodChannel('budget_wallet/shortcut') {
    _shortcut.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is String) _actions.add(call.arguments as String);
      return null;
    });
  }

  @override
  bool get supported => true;

  @override
  Future<void> update(HomeWidgetState state) => _widget.invokeMethod<void>('update', state.toMap());

  @override
  Future<void> clear() => _widget.invokeMethod<void>('clear');

  @override
  Future<String?> initialAction() => _shortcut.invokeMethod<String>('getInitialAction');

  @override
  Stream<String> get actions => _actions.stream;
}

/// The Android widget and shortcut on Android, nothing elsewhere.
HomeWidget defaultHomeWidget() => isAndroid ? AndroidHomeWidget() : const NoHomeWidget();
