import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../device_list.dart';
import '../file_chooser.dart';
import '../widgets/sheets.dart';
import 'accounts_panel.dart' show askBankBalance;
import 'bill_sheet.dart';
import 'findings.dart';
import 'key_backup.dart';
import 'period_report.dart';
import 'review.dart';
import 'setup_wizard.dart';
import 'upcoming.dart';
import 'upcoming_view.dart';

/// What the Today page reads and does, and nothing else: a read-only facade over the controller, so [TodayScreen] never holds it.
/// It is a [Listenable] (it notifies when the controller does). The sheets Today opens are launched here, with the controller
/// they need.
class TodayView implements Listenable {
  const TodayView(this._wc);

  final WalletController _wc;

  @override
  void addListener(VoidCallback listener) => _wc.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _wc.removeListener(listener);

  /// Picks the page (`'plan'` = Plan › Payday plan, or `'spending'` = Explore › Spending) before Overview switches to it.
  void showBudgetView(String view) => view == 'plan' ? _wc.setPlanView('payday') : _wc.setBudgetView(view);

  // ---------- reads ----------
  /// The Today number tiles' order and hidden ids (device-local, Settings > Look).
  ({List<String> order, Set<String> hidden}) get tiles => _wc.todayTiles;
  WalletSettings get settings => _wc.settings;
  String get currency => _wc.currency;
  DateTime get now => _wc.now;
  String today() => _wc.today();
  PeriodBudget period() => _wc.period();
  List<PeriodDay> periodDays() => _wc.periodDays();
  String? newPayday(String periodStart) => _wc.newPayday(periodStart);
  bool get keyBackupRowVisible => _wc.keyBackupRowVisible;
  DeviceStop? get deviceStop => _wc.deviceStop;
  String? get deviceCode => _wc.deviceCode;
  bool get setupWizardOpen => _wc.setupWizardOpen;
  int get setupWizardStep => _wc.setupWizardStep;
  int get setupWizardStepCount => setupWizardSteps;
  int get deliveryOrders90 => _wc.deliveryOrders90;
  (int, int) get deliveries => _wc.deliveries;
  CategoryBudgetLine? tightestBudget() => _wc.tightestBudget();
  ReviewState reviewState() => _wc.reviewState();
  String? get lastReview => _wc.lastReview;
  ({int count, int total}) comingUp() => _wc.comingUp();
  Map<String, int> heldTotals() => _wc.heldTotals();
  List<BalanceWarning> balanceWarnings() => _wc.balanceWarningList();
  String? iouTagOf(String txId) => _wc.iouTagOf(txId);
  int suggestionCount() => _wc.suggestionCount();
  List<HeadsUp> headsUpLines() => _wc.headsUpLines();
  List<PlannedCost> plannedNeedingCategory() => _wc.plannedNeedingCategory();
  int billsToReview() => _wc.billsToReview();
  List<CategorizedTx> get wholeTxs => _wc.wholeTxs;
  List<Goal> get goals => _wc.goals;
  Map<String, String> get latestBySource => _wc.latestBySource;
  CategoryTable get categoryTable => _wc.categoryTable;
  TagTable get tagTable => _wc.tagTable;
  CategorizedTx shown(CategorizedTx t) => _wc.shown(t);
  Bill? billForTx(String txId) => _wc.billForTx(txId);
  bool isMatchedBank(String bankId) => _wc.isMatchedBank(bankId);
  int splitCount(String txId) => _wc.splitCount(txId);
  bool splitIsBroken(String txId) => _wc.splitIsBroken(txId);
  bool setupCollapsedFor(List<String> steps) => _wc.setupCollapsedFor(steps);

  // ---------- Overview (E2) ----------
  /// The € | hours switch: Overview listens to it, so a toggle rebuilds Overview only.
  ValueListenable<bool> get hoursMode => _wc.hoursMode;
  bool get hoursAvailable => _wc.hoursAvailable;
  bool get showHours => _wc.showHours;
  void setShowHours(bool on) => _wc.setShowHours(on);

  /// An amount as Overview shows it: exact money, or hours of work when the switch is on.
  String amount(int cents, String cur) => _wc.amountText(cents, cur);
  List<FindingCard> foundCards() => _wc.foundCards();

  /// The pinned series that can be drawn (a view this build cannot run is left out).
  List<PinData> pins() => [
        for (final v in _wc.pinnedViews())
          if (_wc.pinData(v) case final d?) d
      ];
  void unpin(String id) => _wc.unpinView(id);
  void repin(String id) => _wc.repinView(id);
  Goal? nearestGoal() => _wc.nearestGoal();

  /// Plan › Saving (the goal bar's link); the caller switches the tab.
  void showSaving() => _wc.setPlanView('saving');
  Future<void> showFindings(BuildContext context, {VoidCallback? openExplore}) => openFindings(context, _wc, openExplore: openExplore);
  Future<void> showPeriodReport(BuildContext context) => openPeriodReport(context, _wc);

  // ---------- actions ----------
  void startNewMonth(String date) => _wc.startNewMonth(date);
  void updateSettings(Map<String, Object?> changes) => _wc.updateSettings(changes);
  void setSetupCollapsed(bool v, List<String> steps) => _wc.setSetupCollapsed(v, steps);
  void snoozeKeyBackup() => _wc.snoozeKeyBackup();
  void declineSetupWizard() => _wc.declineSetupWizard();
  void openCurrencies() => _wc.openCurrencies();

  // ---------- sheets and pages Today opens ----------
  Future<void> showUpcoming(BuildContext context) => openUpcoming(context, UpcomingView(_wc));
  Future<void> showBill(BuildContext context, String billId) => openBill(context, _wc, billId);
  Future<void> showAddExpense(BuildContext context) => addExpenseFlow(context, _wc);
  Future<void> showReview(BuildContext context, {VoidCallback? openSpending, FileChooser chooser = const FileChooser()}) =>
      openReview(context, _wc, openSpending: openSpending, chooser: chooser);
  Future<bool> showKeyBackup(BuildContext context) => openKeyBackup(context, _wc);
  Future<void> showSetupWizard(BuildContext context, FileChooser chooser) => openSetupWizard(context, _wc, chooser: chooser);

  /// "Check your PBZ balance": the bank question for [account] with today's date and the app's own number prefilled.
  Future<void> showBalanceCheck(BuildContext context, Account account) => askBankBalance(
      context,
      _wc,
      BankQuestion(
          accountId: account.id,
          name: account.name,
          currency: account.currency,
          date: _wc.today(),
          appCents: _wc.appBalanceOn(account.id, _wc.today())),
      fromImport: false);

  /// A payment's sheet, then the toast for what it did.
  Future<void> openTx(BuildContext context, CategorizedTx t) async {
    final r = await showSheet<String>(context, TxSheet(wc: _wc, t: t));
    if (context.mounted) txSheetToast(context, _wc, r);
  }
}
