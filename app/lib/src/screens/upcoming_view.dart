import 'package:flutter/widgets.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../widgets/sheets.dart';
import 'bill_sheet.dart';
import 'planned_sheets.dart';

/// What the Upcoming page reads and does, and nothing else: a read-only facade over the controller, so [UpcomingScreen] never
/// holds it. It is a [Listenable] (it notifies when the controller does). The sheets Upcoming opens are launched here.
class UpcomingView implements Listenable {
  const UpcomingView(this._wc);

  final WalletController _wc;

  @override
  void addListener(VoidCallback listener) => _wc.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _wc.removeListener(listener);

  // ---------- reads ----------
  String get currency => _wc.currency;
  String today() => _wc.today();
  CategoryTable get categoryTable => _wc.categoryTable;
  ({String start, String end}) upcomingRange({bool next = false}) => _wc.upcomingRange(next: next);
  List<UpcomingItem> upcomingItems(String from, String to) => _wc.upcomingItems(from, to);
  ({int count, int total}) countedIn(List<UpcomingItem> items) => _wc.countedIn(items);

  // ---------- actions ----------
  void confirmSuggestion(UpcomingItem it, {required int amount, String? title, String? date, String? category}) =>
      _wc.confirmSuggestion(it, amount: amount, title: title, date: date, category: category);
  void dismissSuggestion(UpcomingItem it) => _wc.dismissSuggestion(it);
  void reopenPlanned(PlannedCost p) => _wc.reopenPlanned(p);

  // ---------- sheets Upcoming opens ----------
  /// The add form, on [date] when given; returns the sheet's answer (`saved`).
  Future<String?> showAddForm(BuildContext context, {String? date}) => showSheet<String>(context, PlannedFormSheet(wc: _wc, date: date));

  /// The form to change a calendar suggestion before it is confirmed.
  Future<String?> showSuggestionForm(BuildContext context, UpcomingItem suggestion) =>
      showSheet<String>(context, PlannedFormSheet(wc: _wc, suggestion: suggestion));

  /// Change / Paid / Skip / Delete for a planned cost.
  Future<String?> showEntry(BuildContext context, PlannedCost planned) =>
      showSheet<String>(context, PlannedEntrySheet(wc: _wc, planned: planned));

  Future<void> showBill(BuildContext context, String billId) => openBill(context, _wc, billId);
}
