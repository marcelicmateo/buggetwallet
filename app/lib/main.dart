import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart' show addDays;

import 'src/controller.dart';
import 'src/format.dart';
import 'src/screens/goals.dart';
import 'src/screens/onboarding.dart';
import 'src/screens/plan.dart';
import 'src/screens/spending.dart';
import 'src/screens/today.dart';
import 'src/screens/wishlist.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final wc = await WalletController.load();
  runApp(BudgetWalletApp(wc: wc));
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

class _HomeShellState extends State<HomeShell> {
  int tab = 0;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onResume: () => widget.wc.syncNow(quiet: true));
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
      TodayScreen(wc: wc, openPlan: () => setState(() => tab = 4)),
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
          if (wc.syncing) const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Chip(label: Text('${shortDate(p.start)} – ${shortDate(addDays(p.end, -1))}', style: const TextStyle(fontSize: 12.5)), visualDensity: VisualDensity.compact),
          ),
        ],
      ),
      body: SafeArea(child: IndexedStack(index: tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'Spending'),
          NavigationDestination(icon: Icon(Icons.hourglass_empty), selectedIcon: Icon(Icons.hourglass_bottom), label: 'Wishlist'),
          NavigationDestination(icon: Icon(Icons.flag_outlined), selectedIcon: Icon(Icons.flag), label: 'Goals'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Plan'),
        ],
      ),
    );
  }
}
