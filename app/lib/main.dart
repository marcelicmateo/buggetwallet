import 'dart:async';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';

import 'src/clock_notice.dart';
import 'src/controller.dart';
import 'src/controller_deps.dart';
import 'src/format.dart';
import 'src/layout.dart';
import 'src/logging.dart';
import 'src/platform.dart';
import 'src/screens/bill_sheet.dart';
import 'src/screens/bills_tab.dart';
import 'src/screens/in_use.dart';
import 'src/screens/key_backup.dart';
import 'src/screens/onboarding.dart';
import 'src/screens/payday_plan.dart';
import 'src/screens/save.dart';
import 'src/screens/settings.dart';
import 'src/screens/setup_wizard.dart';
import 'src/screens/spending.dart';
import 'src/screens/today.dart';
import 'src/screens/today_view.dart';
import 'src/screens/unlock.dart';
import 'src/tabs.dart';
import 'src/theme.dart';
import 'src/widgets/common.dart';
import 'src/widgets/sheets.dart';

final _log = Logger('bw.app');

/// Adds the IBM Plex licence (SIL OFL 1.1) to the licences page.
void registerFontLicense() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(['IBM Plex Sans', 'IBM Plex Mono'], text);
  });
}

Future<void> main() async {
  final total = Stopwatch()..start();
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    registerFontLicense();
    final wc = await bootstrap();
    final sinceRunApp = Stopwatch()..start();
    runApp(BudgetWalletApp(wc: wc));
    AppLog.startMonitors();
    unawaited(logFirstFrame(sinceRunApp, total));
  }, AppLog.zoneError);
}

/// Logging first, then the wallet. Logs `app.info` and the `app.start` phases (logs, db, key, reload, ready).
/// The screenshot test calls this too, with [catchErrors] off (the test binding owns the error hooks) and its own [deps].
Future<WalletController> bootstrap({bool catchErrors = true, WalletControllerDeps? deps}) async {
  final sw = Stopwatch()..start();
  await AppLog.init(catchErrors: catchErrors);
  AppLog.logAppInfo();
  logEvent(_log, Level.INFO, 'app.start', {'phase': 'logs', 'ms': sw.elapsedMilliseconds});
  final wc = await WalletController.load(deps: deps);
  AppLog.setLevel(wc.logLevel);
  logEvent(_log, Level.INFO, 'app.start', {'phase': 'ready', 'ms': sw.elapsedMilliseconds});
  return wc;
}

/// Time from runApp to the first rasterized frame, and from main() to it.
Future<void> logFirstFrame(Stopwatch sinceRunApp, Stopwatch total) async {
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  logEvent(_log, Level.INFO, 'app.start', {'phase': 'firstFrame', 'ms': sinceRunApp.elapsedMilliseconds});
  logEvent(_log, Level.INFO, 'app.start', {'phase': 'total', 'ms': total.elapsedMilliseconds});
}

class BudgetWalletApp extends StatefulWidget {
  final WalletController wc;
  const BudgetWalletApp({super.key, required this.wc});

  @override
  State<BudgetWalletApp> createState() => _BudgetWalletAppState();
}

class _BudgetWalletAppState extends State<BudgetWalletApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late final _toastClearer = ToastClearer(_messenger);
  bool _noticeOpen = false;
  bool _failedOpen = false;
  final _light = buildTheme(Brightness.light);
  final _dark = buildTheme(Brightness.dark);

  /// Device-local choice (Plan › Look), read from the wallet's local values, so it is known before the first frame.
  late final _mode = ValueNotifier<ThemeMode>(_modeOf(widget.wc));

  static ThemeMode _modeOf(WalletController wc) =>
      switch (wc.themeModeName) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system };

  void _syncMode() => _mode.value = _modeOf(widget.wc);

  @override
  void initState() {
    super.initState();
    clockBehindNotice.addListener(_clockBehind);
    writeFailedNotice.addListener(_writeFailed);
    widget.wc.addListener(_syncMode);
  }

  @override
  void dispose() {
    widget.wc.removeListener(_syncMode);
    _mode.dispose();
    clockBehindNotice.removeListener(_clockBehind);
    writeFailedNotice.removeListener(_writeFailed);
    super.dispose();
  }

  /// A write failed in the database (any screen): a dialog on the top route like the clock notice, so it shows over an open
  /// sheet too (a toast sits in the page's Scaffold, under a modal sheet). Deferred: the error can arrive while a frame builds.
  void _writeFailed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigator.currentContext;
      if (!mounted || ctx == null || !ctx.mounted || _failedOpen) return;
      _failedOpen = true;
      logNav('write.failed.shown');
      showDialog<void>(
        context: ctx,
        builder: (c) => AlertDialog(
          key: const ValueKey('writeFailedDialog'),
          content: const Text(writeFailedText),
          actions: [TextButton(key: const ValueKey('writeFailedOk'), onPressed: () => Navigator.of(c).pop(), child: const Text('OK'))],
        ),
      ).whenComplete(() => _failedOpen = false);
    });
    // A frame must run for the callback to fire when the app is idle.
    WidgetsBinding.instance.scheduleFrame();
  }

  /// A write was refused because this device's clock is behind (any screen): one sentence over whatever is open.
  void _clockBehind() {
    final ctx = _navigator.currentContext;
    if (ctx == null || _noticeOpen) return;
    _noticeOpen = true;
    logNav('write.clockBehind.shown');
    showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        key: const ValueKey('clockBehindDialog'),
        content: const Text(clockBehindText),
        actions: [TextButton(key: const ValueKey('clockBehindOk'), onPressed: () => Navigator.of(c).pop(), child: const Text('OK'))],
      ),
    ).whenComplete(() => _noticeOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    // The themes are built once (a new ThemeData never compares equal and would animate on every notify); only the mode moves.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _mode,
      builder: (context, mode, _) => MaterialApp(
        navigatorKey: _navigator,
        scaffoldMessengerKey: _messenger,
        navigatorObservers: [_toastClearer],
        title: 'Budget Wallet',
        debugShowCheckedModeBanner: false,
        theme: _light,
        darkTheme: _dark,
        themeMode: mode,
        home: ListenableBuilder(
          listenable: wc,
          builder: (context, _) => wc.inUseElsewhere
              ? const InUseScreen()
              : wc.hasWallet
                  ? HomeShell(wc: wc)
                  : wc.locked
                      ? UnlockScreen(wc: wc)
                      : OnboardingScreen(wc: wc),
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  final WalletController wc;
  const HomeShell({super.key, required this.wc});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// One list for the bottom bar and the rail.
const _destinations = [
  (label: 'Today', icon: Icons.account_balance_wallet_outlined, selected: Icons.account_balance_wallet),
  (label: 'Budget', icon: Icons.bar_chart_outlined, selected: Icons.bar_chart),
  (label: 'Bills', icon: Icons.receipt_long_outlined, selected: Icons.receipt_long),
  (label: 'Save', icon: Icons.savings_outlined, selected: Icons.savings),
  (label: 'Settings', icon: Icons.settings_outlined, selected: Icons.settings),
];

/// Label with its shortcut, for tooltips; the shortcut shows only where a keyboard is usual (desktop, web).
String _hint(String label, String keys) => hasKeyboard ? '$label ($keys)' : label;

class _TabIntent extends Intent {
  final int tab;
  const _TabIntent(this.tab);
}

class _AddIntent extends Intent {
  const _AddIntent();
}

class _SyncIntent extends Intent {
  const _SyncIntent();
}

class _SettingsIntent extends Intent {
  const _SettingsIntent();
}

class _SearchIntent extends Intent {
  const _SearchIntent();
}

/// Ctrl combinations and F5 only: plain keys must stay free for typing.
final _shortcuts = <ShortcutActivator, Intent>{
  for (final (i, k) in [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
  ].indexed)
    SingleActivator(k, control: true): _TabIntent(i),
  const SingleActivator(LogicalKeyboardKey.keyN, control: true): const _AddIntent(),
  const SingleActivator(LogicalKeyboardKey.keyR, control: true): const _SyncIntent(),
  const SingleActivator(LogicalKeyboardKey.f5): const _SyncIntent(),
  const SingleActivator(LogicalKeyboardKey.comma, control: true): const _SettingsIntent(),
  const SingleActivator(LogicalKeyboardKey.keyF, control: true): const _SearchIntent(),
};

class _HomeShellState extends State<HomeShell> {
  int tab = 0;
  late final AppLifecycleListener _life;

  /// Holds keyboard focus for the shortcuts when nothing else (a text field) has it.
  final _focus = FocusNode(debugLabel: 'shell', skipTraversal: true);
  bool _adding = false;

  /// Today's "Due by payday" and "N bills to review" lines ask the Bills tab for a place on its page.
  final _billsRequest = JumpRequest<BillsAnchor>();
  StreamSubscription<BillImport>? _sharedSub;
  StreamSubscription<void>? _shortcutSub;

  /// Counts the Ctrl+F presses; Budget opens its search view on each.
  final _searchRequest = ValueNotifier<int>(0);

  /// The payday plan keeps its State (typed text, focus) when Budget changes between one and two columns: its place in the tree moves.
  final _paydayKey = GlobalKey();

  /// The five tab pages, built once per data version and day (not on every tab switch): switching tabs only moves the
  /// IndexedStack, so the pages are not rebuilt and their derived data is not worked out again.
  late List<Widget> _pages;
  String? _pagesKey;

  /// Builds the pages again when the data or the day changed since they were built (a new day moves the period and months).
  void _refreshPages() {
    final key = '${widget.wc.dataVersion}|${widget.wc.today()}|${widget.wc.numberStyleName}';
    if (key == _pagesKey) return;
    _pagesKey = key;
    _pages = _buildPages();
  }

  List<Widget> _buildPages() => [for (var i = 0; i < Tabs.names.length; i++) _page(i)];

  Widget _page(int i) => switch (i) {
        Tabs.today => TodayScreen(
            view: TodayView(widget.wc),
            openPlan: () => _go(Tabs.budget, 'today'),
            openSpending: () => _go(Tabs.budget, 'today'),
            openSearch: () {
              _go(Tabs.budget, 'today');
              _searchRequest.value++;
            },
            addExpense: _addExpense,
            openBills: () {
              _go(Tabs.bills, 'today');
              _billsRequest.request(BillsAnchor.comingUp);
            },
            openBillsReview: () {
              _go(Tabs.bills, 'today');
              _billsRequest.request(BillsAnchor.review);
            },
            openAccounts: () => widget.wc.openSettings(SettingsSection.accounts, via: 'today'),
            openSync: () => widget.wc.openSettings(SettingsSection.sync, via: 'today'),
            openIncome: () => widget.wc.openSettings(SettingsSection.income, via: 'today')),
        Tabs.budget => SpendingScreen(
            wc: widget.wc,
            searchRequest: _searchRequest,
            header: [PaydayPlan(key: _paydayKey, wc: widget.wc)],
            openTab: (i) => _go(i, 'search'),
            openBills: () {
              _go(Tabs.bills, 'search');
              _billsRequest.request(BillsAnchor.expected);
            }),
        Tabs.bills => BillsScreen(wc: widget.wc, request: _billsRequest),
        Tabs.save => SaveScreen(wc: widget.wc),
        _ => SettingsScreen(wc: widget.wc),
      };

  @override
  void initState() {
    super.initState();
    widget.wc.tabHook = _go;
    AppLog.setScreen(Tabs.names[tab]);
    _refreshPages();
    _life = AppLifecycleListener(
      onResume: () {
        widget.wc.checkDay(); // a new day also shows without a relay
        unawaited(widget.wc.updateHomeWidget()); // the home-screen widget (Android) shows today's number
        widget.wc.rescheduleNudges(); // reminders are scheduled for 4 weeks at a time (and the heads-ups after them)
        widget.wc.readCalendars(trigger: 'resume'); // calendars and .ics links are read again
        widget.wc.syncNow(quiet: true, trigger: 'resume');
      },
      // A browser tab that is hidden or closing: get the database into IndexedDB now.
      onInactive: () => unawaited(widget.wc.persistNow()),
      onHide: () => unawaited(widget.wc.persistNow()),
      onPause: () => unawaited(widget.wc.persistNow()),
    );
    // PDFs and photos shared to the app (Android) become bills to review.
    _sharedSub = widget.wc.sharedBillResults.listen((r) {
      if (!mounted) return;
      showBillImport(context, widget.wc, r);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.wc.startSharing());
    });
    // The launcher shortcut "Add expense" (Android): a request made before this shell existed waits in the controller.
    _shortcutSub = widget.wc.shortcutAdds.listen((_) => _shortcutAdd());
    WidgetsBinding.instance.addPostFrameCallback((_) => _shortcutAdd());
    // A wallet just created: ask the owner to save the key before the first Today.
    if (widget.wc.takeKeyBackupPrompt()) {
      // Then the "Set up my wallet" wizard (every step skippable; closing it keeps the step for Today's "Finish setting up").
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await openKeyBackup(context, widget.wc);
        if (mounted) await openSetupWizard(context, widget.wc);
      });
    }
  }

  void _go(int i, String via) {
    if (i == tab) return;
    clearToasts(context);
    logNav('nav.tab', {'from': Tabs.names[tab], 'to': Tabs.names[i], 'via': via});
    AppLog.setScreen(Tabs.names[i]);
    // Today and Save (the wishlist) show the time of day (delivery hour, hours left): they get a fresh build when opened.
    // The data they use is cached in the controller, so this is cheap.
    if (i == Tabs.today || i == Tabs.save) _pages[i] = _page(i);
    setState(() => tab = i);
  }

  /// Opens the Add expense sheet for a launcher shortcut (once per request; nothing when there is none).
  void _shortcutAdd() {
    if (mounted && widget.wc.takeShortcutAdd()) {
      logNav('nav.shortcut', {'action': 'addExpense'});
      _addExpense();
    }
  }

  /// Add expense, from the Today button or Ctrl+N. One sheet at a time.
  Future<void> _addExpense() async {
    if (_adding) return;
    _adding = true;
    try {
      await addExpenseFlow(context, widget.wc);
    } finally {
      _adding = false;
    }
  }

  void _syncNow() {
    if (widget.wc.relayUrl == null) {
      toast(context, 'No relay address yet. Set one in Settings › Sync.');
      return;
    }
    widget.wc.syncNow(trigger: 'key');
  }

  /// Logs the shortcut (a fixed name, nothing else) and runs it.
  Object? _key(String name, VoidCallback run) {
    logNav('nav.key', {'key': name});
    run();
    return null;
  }

  late final Map<Type, Action<Intent>> _actions = {
    _TabIntent: CallbackAction<_TabIntent>(onInvoke: (i) => _key('ctrl${i.tab + 1}', () => _go(i.tab, 'key'))),
    _AddIntent: CallbackAction<_AddIntent>(onInvoke: (_) => _key('ctrlN', _addExpense)),
    _SyncIntent: CallbackAction<_SyncIntent>(onInvoke: (_) => _key('sync', _syncNow)),
    _SettingsIntent: CallbackAction<_SettingsIntent>(onInvoke: (_) => _key('ctrlComma', () => _go(Tabs.settings, 'key'))),
    _SearchIntent: CallbackAction<_SearchIntent>(
        onInvoke: (_) => _key('ctrlF', () {
              _go(Tabs.budget, 'key');
              _searchRequest.value++;
            })),
  };

  // The parent rebuilds this widget when the wallet changes; build() then makes new pages if the data or the day moved on.
  @override
  void didUpdateWidget(HomeShell old) {
    super.didUpdateWidget(old);
    if (old.wc != widget.wc) _pagesKey = null;
  }

  @override
  void dispose() {
    widget.wc.tabHook = null;
    _life.dispose();
    _focus.dispose();
    _billsRequest.dispose();
    _sharedSub?.cancel();
    _shortcutSub?.cancel();
    _searchRequest.dispose();
    super.dispose();
  }

  /// A click or tap on the page: if nothing holds the keyboard focus, the shell takes it, so the shortcuts work.
  void _pointerDown(PointerDownEvent _) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final f = FocusManager.instance.primaryFocus;
      if (mounted && (f == null || f is FocusScopeNode)) _focus.requestFocus();
    });
  }

  Widget _logo(WalletColors c) => const LedgerLogo();

  Widget _searchButton() => IconButton(
        key: const ValueKey('appBarSearch'),
        tooltip: _hint('Search', 'Ctrl+F'),
        icon: const Icon(Icons.search),
        onPressed: () => _key('appBarSearch', () {
          _go(Tabs.budget, 'appbar');
          _searchRequest.value++;
        }),
      );

  /// The pay period as a small boxed label for the rail (the wide layouts have no app bar): one line when the rail is extended,
  /// two short lines when it is narrow. It scales down rather than growing the rail.
  Widget _periodBadge(BuildContext context, bool extended) {
    final p = widget.wc.period();
    final from = shortDate(p.start), to = shortDate(addDays(p.end, -1));
    return Tooltip(
      message: 'This pay period',
      child: Container(
        key: const ValueKey('periodBadge'),
        // The narrow rail grows with the text scale (like the rail itself), so large text still gets a box that fits it.
        width: extended ? 188 : (72 * MediaQuery.textScalerOf(context).scale(1)).clamp(72.0, 152.0),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: context.c.ink), borderRadius: BorderRadius.circular(2)),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(extended ? '$from – $to' : '$from –\n$to',
              textAlign: TextAlign.center, style: numStyle.copyWith(fontSize: BwType.metaSize, fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }

  /// The rail: labels always shown, wide (extended) at expanded. It scrolls when the window is short.
  Widget _rail(BuildContext context, LayoutSize size) {
    final c = context.c;
    final extended = size == LayoutSize.expanded;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return DecoratedBox(
      key: const ValueKey('rail'),
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(border: Border(right: BorderSide(color: c.line))),
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: IntrinsicHeight(
              child: NavigationRail(
                selectedIndex: tab,
                onDestinationSelected: (i) => _go(i, 'rail'),
                extended: extended,
                minExtendedWidth: 220,
                minWidth: (80 * scale).clamp(80.0, 160.0),
                // An extended rail shows its labels by itself (Flutter allows no labelType there).
                labelType: extended ? null : NavigationRailLabelType.all,
                // The name never makes the rail wider than minExtendedWidth (so the content width does not depend on the font).
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(
                      width: extended ? 188 : null,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        _logo(c),
                        if (extended) ...[
                          const SizedBox(width: 8),
                          const Flexible(
                              child: Text('Budget Wallet',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: BwType.headingSize))),
                        ],
                      ]),
                    ),
                    const SizedBox(height: 16),
                    _searchButton(),
                    const SizedBox(height: 4),
                    _periodBadge(context, extended),
                    _SyncSlot(active: widget.wc.syncing),
                  ]),
                ),
                destinations: [
                  for (final (i, d) in _destinations.indexed)
                    NavigationRailDestination(
                      icon: _railIcon(d.label, i, Icon(d.icon, key: ValueKey('tab:${Tabs.names[i]}'))),
                      selectedIcon: _railIcon(d.label, i, Icon(d.selected, key: ValueKey('tab:${Tabs.names[i]}'))),
                      label: Text(d.label),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _railIcon(String label, int i, Widget icon) => hasKeyboard ? Tooltip(message: _hint(label, 'Ctrl+${i + 1}'), child: icon) : icon;

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    _refreshPages();
    final p = wc.period();
    final size = layoutOf(context);
    final compact = size == LayoutSize.compact;
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      // Wide windows have no app bar: the search button and the pay period sit in the rail, so nothing stays pinned above the page.
      appBar: !compact
          ? null
          : AppBar(
              backgroundColor: context.c.bg,
              surfaceTintColor: Colors.transparent,
              titleSpacing: 16,
              // A 2 px rule under the header.
              bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(height: 1, color: context.c.line)),
              // With a rail, the logo and name sit in the rail.
              title: compact
                  ? Row(children: [
                      _logo(context.c),
                      // On a very narrow bar the search icon and the period take the room: the logo stands for the name.
                      if (width >= 360) ...[
                        const SizedBox(width: 8),
                        const Flexible(
                            child: Text('Budget Wallet',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontWeight: FontWeight.w600, fontSize: BwType.headingSize))),
                      ],
                    ])
                  : null,
              actions: [
                _searchButton(),
                if (wc.syncing)
                  const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Tooltip(
                          message: 'Syncing', child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))),
                // The period always shows in full: 280 at most, and on a narrow screen with large text it shrinks to half the bar.
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: width / 2 < 280 ? width / 2 : 280),
                    child: Tooltip(
                      message: 'This pay period',
                      child: Chip(
                          label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('${shortDate(p.start)} – ${shortDate(addDays(p.end, -1))}',
                                  style: numStyle.copyWith(fontSize: BwType.metaSize, fontWeight: FontWeight.w500))),
                          side: BorderSide(color: context.c.ink),
                          visualDensity: VisualDensity.compact),
                    ),
                  ),
                ),
              ],
            ),
      body: Shortcuts(
        shortcuts: _shortcuts,
        child: Actions(
          actions: _actions,
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            child: Listener(
              onPointerDown: _pointerDown,
              // The same widget shape at every size, with keys, so the pages keep their State when the window is resized.
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (!compact) _rail(context, size),
                Expanded(
                  key: const ValueKey('content'),
                  child: SafeArea(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxContentWidth(size)),
                        // A tab that is not shown has its tickers off (IndexedStack keeps it built, and does not do this itself): pages that wait
                        // for it (Explainer, RebuildWhenShown) know they are hidden.
                        child: IndexedStack(index: tab, children: [
                          for (final (i, page) in _pages.indexed) TickerMode(enabled: i == tab, child: page),
                        ]),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
      bottomNavigationBar: compact
          ? NavBarFrame(
              selected: tab,
              count: _destinations.length,
              child: NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: (i) => _go(i, 'bar'),
                destinations: [
                  for (final (i, d) in _destinations.indexed)
                    NavigationDestination(
                        key: ValueKey('tab:${Tabs.names[i]}'),
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selected),
                        label: d.label,
                        tooltip: _hint(d.label, 'Ctrl+${i + 1}')),
                ],
              ),
            )
          : null,
    );
  }
}

/// The rail's sync spinner. The 24 dp slot is always there, so the destinations below do not move when a sync starts or ends.
class _SyncSlot extends StatelessWidget {
  final bool active;
  const _SyncSlot({required this.active});
  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('syncSlot'),
        height: 24,
        child: active
            ? const Padding(
                padding: EdgeInsets.only(top: 8),
                child:
                    Tooltip(message: 'Syncing', child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))))
            : null,
      );
}
