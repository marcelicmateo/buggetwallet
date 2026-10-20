import 'dart:async';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet_core/wallet_core.dart';

import 'src/controller.dart';
import 'src/format.dart';
import 'src/layout.dart';
import 'src/logging.dart';
import 'src/platform.dart';
import 'src/screens/goals.dart';
import 'src/screens/onboarding.dart';
import 'src/screens/plan.dart';
import 'src/screens/spending.dart';
import 'src/screens/today.dart';
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

class BudgetWalletApp extends StatelessWidget {
  final WalletController wc;
  const BudgetWalletApp({super.key, required this.wc});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Budget Wallet',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: ListenableBuilder(
        listenable: wc,
        builder: (context, _) => wc.hasWallet ? HomeShell(wc: wc) : OnboardingScreen(wc: wc),
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
};

class _HomeShellState extends State<HomeShell> {
  int tab = 0;
  late final AppLifecycleListener _life;

  /// Holds keyboard focus for the shortcuts when nothing else (a text field) has it.
  final _focus = FocusNode(debugLabel: 'shell', skipTraversal: true);
  bool _adding = false;

  /// The five tab pages, built once per data version and day (not on every tab switch): switching tabs only moves the
  /// IndexedStack, so the pages are not rebuilt and their derived data is not worked out again.
  late List<Widget> _pages;
  String? _pagesKey;

  /// Builds the pages again when the data or the day changed since they were built (a new day moves the period and months).
  void _refreshPages() {
    final key = '${widget.wc.dataVersion}|${widget.wc.today()}';
    if (key == _pagesKey) return;
    _pagesKey = key;
    _pages = _buildPages();
  }

  List<Widget> _buildPages() => [for (var i = 0; i < _tabs.length; i++) _page(i)];

  Widget _page(int i) => switch (i) {
        0 => TodayScreen(wc: widget.wc, openPlan: () => _go(4, 'today'), openSpending: () => _go(1, 'today'), addExpense: _addExpense),
        1 => SpendingScreen(wc: widget.wc),
        2 => WishlistScreen(wc: widget.wc),
        3 => GoalsScreen(wc: widget.wc),
        _ => PlanScreen(wc: widget.wc),
      };

  @override
  void initState() {
    super.initState();
    AppLog.setScreen(_tabs[tab]);
    _refreshPages();
    _life = AppLifecycleListener(onResume: () {
      widget.wc.checkDay(); // a new day also shows without a sync folder
      widget.wc.syncNow(quiet: true, trigger: 'resume');
    });
  }

  void _go(int i, String via) {
    if (i == tab) return;
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
    if (widget.wc.syncFolder == null) {
      toast(context, 'No sync folder yet. Set one in Plan.');
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
  };

  // The parent rebuilds this widget when the wallet changes; build() then makes new pages if the data or the day moved on.
  @override
  void didUpdateWidget(HomeShell old) {
    super.didUpdateWidget(old);
    if (old.wc != widget.wc) _pagesKey = null;
  }

  @override
  void dispose() {
    _life.dispose();
    _focus.dispose();
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

  /// The rail: labels always shown, wide (extended) at expanded. It scrolls when the window is short.
  Widget _rail(BuildContext context, LayoutSize size) {
    final c = context.c;
    final extended = size == LayoutSize.expanded;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return DecoratedBox(
      key: const ValueKey('rail'),
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(border: Border(right: BorderSide(color: c.lineStrong))),
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
                  child: SizedBox(
                    width: extended ? 188 : null,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      _logo(c),
                      if (extended) ...[
                        const SizedBox(width: 8),
                        const Flexible(
                            child: Text('Budget Wallet',
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17))),
                      ],
                    ]),
                  ),
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
      appBar: AppBar(
        backgroundColor: context.c.bg,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 16,
        // A 2 px rule under the header.
        bottom: PreferredSize(preferredSize: const Size.fromHeight(2), child: Container(height: 2, color: context.c.lineStrong)),
        // With a rail, the logo and name sit in the rail.
        title: compact
            ? Row(children: [
                _logo(context.c),
                const SizedBox(width: 8),
                const Flexible(
                    child: Text('Budget Wallet',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17))),
              ])
            : null,
        actions: [
          if (wc.syncing)
            const Padding(
                padding: EdgeInsets.only(right: 8),
                child:
                    Tooltip(message: 'Syncing', child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))),
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
                            style: numStyle.copyWith(fontSize: 12, fontWeight: FontWeight.w500))),
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
