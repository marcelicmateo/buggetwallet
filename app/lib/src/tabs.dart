// The destinations (Overview, Money, Explore, Plan) plus Settings, and the places a link can point at inside them (P5). Pure: no widgets.
import 'package:flutter/foundation.dart';

/// Page indexes: the four destinations in bar order (Ctrl+1-4), then Settings (not in the bar: the Overview gear, the rail bottom, Ctrl+,).
abstract final class Tabs {
  static const overview = 0, money = 1, explore = 2, plan = 3, settings = 4;
  static const names = ['overview', 'money', 'explore', 'plan', 'settings'];
}

/// The sections of the Settings tab, in page order. [currencies] is a place inside Accounts (a link scrolls to it).
enum SettingsSection {
  accounts('Accounts', 'Cash, banks and currencies'),
  import('Import', 'Bank files and file layouts'),
  sync('Sync', 'Relay, devices and wallet key'),
  backup('Backup and export', 'Files you keep'),
  calendars('Calendars and reminders', 'Calendars, nudges, review day'),
  look('Look', 'Theme and number style'),
  diagnostics('Diagnostics', 'Logs for support'),
  currencies('Currencies', 'Rates for other currencies');

  final String title, sub;
  const SettingsSection(this.title, this.sub);

  /// The entry of the section list this place belongs to.
  SettingsSection get nav => this == currencies ? accounts : this;

  /// The entries of the section list (everything but the places inside one).
  static List<SettingsSection> get listed => [
        for (final s in values)
          if (s == s.nav) s
      ];
}

/// Places on the Money page a link can scroll to.
enum BillsAnchor { comingUp, review, expected, slips }

/// A "go there" request: a section or place to show. Each [request] notifies, also for the same value twice.
/// A request made while no page listens (the tab's page is not built yet: the shell builds hidden pages one by one) is kept as
/// pending; the page that is built next collects it with `jumpWhenBuilt` (widgets/jump_when_built.dart) in its initState.
class JumpRequest<T> extends ChangeNotifier {
  T? _value;
  bool _pending = false;
  T? get value => _value;
  void request(T v) {
    _value = v;
    _pending = !hasListeners;
    notifyListeners();
  }

  /// The value of a request nobody was listening for, once; null when there is none.
  T? takePending() {
    if (!_pending) return null;
    _pending = false;
    return _value;
  }
}
