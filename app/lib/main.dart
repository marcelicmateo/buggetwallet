import 'dart:async';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';

import 'src/clock_notice.dart';
import 'src/controller.dart';
import 'src/format.dart';
import 'src/layout.dart';
import 'src/logging.dart';
import 'src/platform.dart';
import 'src/screens/bill_sheet.dart';
import 'src/screens/goals.dart';
import 'src/screens/in_use.dart';
import 'src/screens/key_backup.dart';
import 'src/screens/onboarding.dart';
import 'src/screens/plan.dart';
import 'src/screens/spending.dart';
import 'src/screens/today.dart';
import 'src/screens/unlock.dart';
import 'src/screens/welcome_balance.dart';
import 'src/screens/wishlist.dart';
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
/// The screenshot test calls this too, with [catchErrors] off (the test binding owns the error hooks).
Future<WalletController> bootstrap({bool catchErrors = true}) async {
  final sw = Stopwatch()..start();
  await AppLog.init(catchErrors: catchErrors);
  AppLog.logAppInfo();
  logEvent(_log, Level.INFO, 'app.start', {'phase': 'logs', 'ms': sw.elapsedMilliseconds});
  final wc = await WalletController.load();
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

const _tabs = ['today', 'spending', 'wishlist', 'goals', 'plan'];

/// One list for the bottom bar and the rail.
const _destinations = [
  (label: 'Today', icon: Icons.account_balance_wallet_outlined, selected: Icons.account_balance_wallet),
  (label: 'Spending', icon: Icons.bar_chart_outlined, selected: Icons.bar_chart),
  (label: 'Wishlist', icon: Icons.hourglass_empty, selected: Icons.hourglass_bottom),
  (label: 'Goals', icon: Icons.flag_outlined, selected: Icons.flag),
  (label: 'Plan', icon: Icons.tune, selected: Icons.tune),
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

class _PlanIntent extends Intent {
  const _PlanIntent();
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
  const SingleActivator(LogicalKeyboardKey.comma, control: true): const _PlanIntent(),
  const SingleActivator(LogicalKeyboardKey.keyF, control: true): const _SearchIntent(),
};

class _HomeShellState extends State<HomeShell> {
  int tab = 0;
  late final AppLifecycleListener _life;

  /// Holds keyboard focus for the shortcuts when nothing else (a text field) has it.
  final _focus = FocusNode(debugLabel: 'shell', skipTraversal: true);
  bool _adding = false;

  /// Counts the taps on Today's "Due by payday" line; Plan scrolls to Expected bills on each.
  final _billsRequest = ValueNotifier<int>(0);

  /// Counts the taps on Today's "N bills to review" line; Plan scrolls to Bills on each.
  final _billsDbRequest = ValueNotifier<int>(0);
  final _accountsRequest = ValueNotifier<int>(0);
  final _incomeRequest = ValueNotifier<int>(0);
  StreamSubscription<BillImport>? _sharedSub;

  /// Counts the Ctrl+F presses; Spending opens its search view on each.
  final _searchRequest = ValueNotifier<int>(0);

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

  List<Widget> _buildPages() => [for (var i = 0; i < _tabs.length; i++) _page(i)];

  Widget _page(int i) => switch (i) {
        0 => TodayScreen(
            wc: widget.wc,
            openPlan: () => _go(4, 'today'),
            openSpending: () => _go(1, 'today'),
            addExpense: _addExpense,
            openBills: () {
              _go(4, 'today');
              _billsRequest.value++; // Plan scrolls to Expected bills
            },
            openBillsReview: () {
              _go(4, 'today');
              _billsDbRequest.value++; // Plan scrolls to Bills
            },
            openAccounts: () {
              _go(4, 'today');
              _accountsRequest.value++; // Plan scrolls to Accounts
            },
            openIncome: () {
              _go(4, 'today');
              _incomeRequest.value++; // Plan scrolls to Expected income
            }),
        1 => SpendingScreen(
            wc: widget.wc,
            searchRequest: _searchRequest,
            openTab: (i) => _go(i, 'search'),
            openBills: () {
              _go(4, 'search');
              _billsRequest.value++;
            }),
        2 => WishlistScreen(wc: widget.wc),
        3 => GoalsScreen(wc: widget.wc),
        _ => PlanScreen(
            wc: widget.wc,
            showBills: _billsRequest,
            showBillsDb: _billsDbRequest,
            showAccounts: _accountsRequest,
            showIncome: _incomeRequest),
      };

  @override
  void initState() {
    super.initState();
    widget.wc.tabHook = _go;
    AppLog.setScreen(_tabs[tab]);
    _refreshPages();
    _life = AppLifecycleListener(
      onResume: () {
        widget.wc.checkDay(); // a new day also shows without a relay
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
    // A wallet just created: ask the owner to save the key before the first Today.
    if (widget.wc.takeKeyBackupPrompt()) {
      // Then one optional step: how much cash there is (Skip or close it and nothing is added).
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await openKeyBackup(context, widget.wc);
        if (mounted) await openWelcomeBalance(context, widget.wc);
      });
    }
  }

  void _go(int i, String via) {
    if (i == tab) return;
    clearToasts(context);
    logNav('nav.tab', {'from': _tabs[tab], 'to': _tabs[i], 'via': via});
    AppLog.setScreen(_tabs[i]);
    // Today and Wishlist show the time of day (delivery hour, hours left): they get a fresh build when opened.
    // The data they use is cached in the controller, so this is cheap.
    if (i == 0 || i == 2) _pages[i] = _page(i);
    setState(() => tab = i);
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
      toast(context, 'No relay address yet. Set one in Plan › Sync.');
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
    _PlanIntent: CallbackAction<_PlanIntent>(onInvoke: (_) => _key('ctrlComma', () => _go(4, 'key'))),
    _SearchIntent: CallbackAction<_SearchIntent>(
        onInvoke: (_) => _key('ctrlF', () {
              _go(1, 'key');
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
    _billsDbRequest.dispose();
    _accountsRequest.dispose();
    _incomeRequest.dispose();
    _sharedSub?.cancel();
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

  /// The persistent add action (same path as Ctrl+N; a second tap while the sheet opens does nothing).
  Widget _addButton(BuildContext context, {bool small = false}) {
    final c = context.c;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(3));
    final label = _hint('Add expense', 'Ctrl+N');
    void tap() {
      logNav('nav.addFab');
      _addExpense();
    }

    return small
        ? FloatingActionButton.small(
            key: const ValueKey('addFab'),
            heroTag: null,
            tooltip: label,
            backgroundColor: c.ink,
            foregroundColor: c.bg,
            elevation: 0,
            focusElevation: 0,
            hoverElevation: 0,
            highlightElevation: 0,
            shape: shape,
            onPressed: tap,
            child: const Icon(Icons.add))
        : FloatingActionButton(
            key: const ValueKey('addFab'),
            heroTag: null,
            tooltip: label,
            backgroundColor: c.ink,
            foregroundColor: c.bg,
            elevation: 0,
            focusElevation: 0,
            hoverElevation: 0,
            highlightElevation: 0,
            shape: shape,
            onPressed: tap,
            child: const Icon(Icons.add));
  }

  Widget _searchButton() => IconButton(
        key: const ValueKey('appBarSearch'),
        tooltip: _hint('Search', 'Ctrl+F'),
        icon: const Icon(Icons.search),
        onPressed: () => _key('appBarSearch', () {
          _go(1, 'appbar');
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
                    _addButton(context, small: true),
                    const SizedBox(height: 8),
                    _searchButton(),
                    const SizedBox(height: 4),
                    _periodBadge(context, extended),
                    _SyncSlot(active: widget.wc.syncing),
                  ]),
                ),
                destinations: [
                  for (final (i, d) in _destinations.indexed)
                    NavigationRailDestination(
                      icon: _railIcon(d.label, i, Icon(d.icon)),
                      selectedIcon: _railIcon(d.label, i, Icon(d.selected)),
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
                        child: IndexedStack(index: tab, children: _pages),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
      floatingActionButton: compact ? _addButton(context) : null,
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
                        icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: d.label, tooltip: _hint(d.label, 'Ctrl+${i + 1}')),
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
