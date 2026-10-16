import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import 'src/controller.dart';
import 'src/format.dart';
import 'src/logging.dart';
import 'src/screens/goals.dart';
import 'src/screens/onboarding.dart';
import 'src/screens/plan.dart';
import 'src/screens/spending.dart';
import 'src/screens/today.dart';
import 'src/screens/wishlist.dart';
import 'src/theme.dart';

final _log = Logger('bw.app');

Future<void> main() async {
  final total = Stopwatch()..start();
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
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

class _HomeShellState extends State<HomeShell> {
  int tab = 0;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    AppLog.setScreen(_tabs[tab]);
    _life = AppLifecycleListener(onResume: () => widget.wc.syncNow(quiet: true, trigger: 'resume'));
  }

  void _go(int i, String via) {
    if (i == tab) return;
    logNav('nav.tab', {'from': _tabs[tab], 'to': _tabs[i], 'via': via});
    AppLog.setScreen(_tabs[i]);
    setState(() => tab = i);
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final p = wc.period();
    final pages = [
      TodayScreen(wc: wc, openPlan: () => _go(4, 'today')),
      SpendingScreen(wc: wc),
      WishlistScreen(wc: wc),
      GoalsScreen(wc: wc),
      PlanScreen(wc: wc),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: context.c.bg,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 16,
        title: Row(children: [
          Container(width: 22, height: 16, decoration: BoxDecoration(color: context.c.accent, borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 8),
          const Text('Budget Wallet', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
        ]),
        actions: [
          if (wc.syncing)
            const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Chip(
                label: Text('${shortDate(p.start)} – ${shortDate(addDays(p.end, -1))}', style: const TextStyle(fontSize: 12.5)),
                visualDensity: VisualDensity.compact),
          ),
        ],
      ),
      body: SafeArea(child: IndexedStack(index: tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => _go(i, 'bar'),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'Spending'),
          NavigationDestination(icon: Icon(Icons.hourglass_empty), selectedIcon: Icon(Icons.hourglass_bottom), label: 'Wishlist'),
          NavigationDestination(icon: Icon(Icons.flag_outlined), selectedIcon: Icon(Icons.flag), label: 'Goals'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Plan'),
        ],
      ),
    );
  }
}
