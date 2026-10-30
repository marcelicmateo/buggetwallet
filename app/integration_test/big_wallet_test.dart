// Performance with a big SYNTHETIC wallet (~5 years, ~20,000 transactions): seeding, restart, weekly and yearly
// imports, every tab and scrolling Spending. Measured from the app's own perf log (bw.perf) and frame timings, with
// generous upper bounds so it fails on real regressions, not noise. Numbers: dist/logs/report-big_wallet.json.
// Run: tools/emulator.sh test big_wallet
import 'dart:convert';
import 'dart:typed_data';

import 'package:budget_wallet/src/format.dart';
import 'package:budget_wallet/src/logging.dart';
import 'package:budget_wallet/src/screens/spending.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/big_wallet.dart';
import 'support/harness.dart';

final _test = Logger('bw.test');
void phase(String name) => logEvent(_test, Level.INFO, 'test.phase', {'name': name});

/// ms of every bw.perf line per phase: {phase: {name: [ms...]}}.
Map<String, Map<String, List<int>>> perfByPhase(String log) {
  final out = <String, Map<String, List<int>>>{};
  var cur = 'start';
  final ph = RegExp(r' bw\.test test\.phase \{"name":"([^"]+)"\}$');
  final perf = RegExp(r' bw\.perf (\S+) (\{.*\})$');
  for (final line in const LineSplitter().convert(log)) {
    final p = ph.firstMatch(line);
    if (p != null) {
      cur = p[1]!;
      continue;
    }
    final m = perf.firstMatch(line);
    if (m == null) continue;
    final ms = (jsonDecode(m[2]!) as Map<String, Object?>)['ms'];
    if (ms is int) out.putIfAbsent(cur, () => {}).putIfAbsent(m[1]!, () => []).add(ms);
  }
  return out;
}

/// Frame build/raster times while [action] runs (wallet_core FrameStats: p50/p90/p99/max ms, janky count).
Future<Map<String, Object?>> frames(WidgetTester t, Future<void> Function() action) async {
  final stats = FrameStats();
  void onTimings(List<FrameTiming> ts) {
    for (final f in ts) {
      stats.add(buildMicros: f.buildDuration.inMicroseconds, rasterMicros: f.rasterDuration.inMicroseconds);
    }
  }

  SchedulerBinding.instance.addTimingsCallback(onTimings);
  try {
    await action();
    for (var i = 0; i < 10; i++) {
      // the engine reports timings in batches
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
  }
  return stats.summary();
}

/// The slowest [name] timing in [phase].
int maxOf(Map<String, Map<String, List<int>>> p, String phase, String name) {
  final xs = p[phase]?[name];
  expect(xs, isNotNull, reason: 'no $name in phase $phase');
  return xs!.reduce((a, b) => a > b ? a : b);
}

void main() {
  Harness.init();
  Harness.private(
      texts: ['BOLT', 'SPOTIFY', 'PLODINE', 'BAUHAUS', 'DM DROGERIE', 'weekly-export', 'year-export'], cents: [55000, 25000, 1299, 40000]);

  itest('big wallet: ~20k rows over 5 years stay fast', (t) async {
    final today = todayIso();
    final sw = Stopwatch()..start();
    var wc = await Harness.start(t, pump: false, settings: {'salary': 180000, 'rent': 55000, 'loan': 25000, 'subs': 1299, 'paydayDay': 10});
    phase('seed');
    final batches = bigWallet(today);
    final rows = batches.fold<int>(0, (a, b) => a + b.transactions.length);
    expect(rows, inInclusiveRange(18000, 23000));
    for (final b in batches) {
      final s = wc.repo.importBatch(b);
      expect(s.added, b.transactions.length);
    }
    final seedMs = sw.elapsedMilliseconds;

    phase('restart');
    wc = await Harness.restart(t);
    AppLog.startMonitors();
    expect(wc.txs, hasLength(rows));

    phase('weekly-import');
    final weekly = Uint8List.fromList(utf8.encode(bigRevolutCsv(today)));
    final w = await wc.importFiles([('weekly-export.csv', weekly)]);
    expect(w.single.message, 'Revolut: 42 new, 0 already here.');
    await t.pumpAndSettle();

    phase('year-import');
    final year = Uint8List.fromList(utf8.encode(bigRevolutCsv(today, days: 365, perDay: 8, seed: 2)));
    final y = await wc.importFiles([('year-export.csv', year)]);
    expect(y.single.ok, isTrue);
    expect(y.single.message, startsWith('Revolut: 2920 new'));
    await t.pumpAndSettle();
    phase('re-import');
    final again = await wc.importFiles([('year-export.csv', year)]);
    expect(again.single.message, 'Revolut: 0 new, 2920 already here.');
    final total = rows + 42 + 2920;
    expect(wc.txs, hasLength(total));
    await t.pumpAndSettle();

    // A data change recomputes everything the tabs show: this phase bounds the uncached work.
    phase('derive');
    wc.reload();
    await t.pump();
    // Since RX4 nothing on screen asks for the Spending view while Today is shown, so ask for it here (the uncached work: its month
    // summaries and pay periods), as the Budget tab does the first time it is opened.
    wc.spending();
    await t.pump();

    phase('tabs');
    final framesTabs = await frames(t, () async {
      for (var r = 0; r < 2; r++) {
        for (final tab in ['Budget', 'Bills', 'Save', 'Settings', 'Today']) {
          await goTab(t, tab);
        }
      }
    });

    phase('spending-scroll');
    await goTab(t, 'Budget');
    final list = pageList(SpendingScreen);
    final framesScroll = await frames(t, () async {
      for (var i = 0; i < 10; i++) {
        await t.fling(list, const Offset(0, -700), 3000);
        await t.pumpAndSettle();
      }
      for (var i = 0; i < 10; i++) {
        await t.fling(list, const Offset(0, 700), 3000);
        await t.pumpAndSettle();
      }
    });

    phase('spending-months');
    t.state<ScrollableState>(list).position.jumpTo(0);
    await t.pumpAndSettle();
    final months = monthsEnding(monthOf(today), 13);
    for (final m in months.sublist(months.length - 7, months.length - 1).reversed) {
      await tapVisible(t, find.widgetWithText(ChoiceChip, monthShort(m)));
      // The Out tile names the month ("Out in September", with the year for another year than today's).
      final name = m.substring(0, 4) == monthOf(today).substring(0, 4) ? monthLong(m).split(' ').first : monthLong(m);
      expect(find.descendant(of: find.byKey(const ValueKey('outTile')), matching: find.text('Out in $name'.toUpperCase())), findsOneWidget);
    }
    phase('end');
    AppLog.logFrameWindow();
    AppLog.logMemory();
    await Harness.shot(t, 'big-wallet-spending');

    final log = await Harness.checkLog();
    final p = perfByPhase(log);
    final numbers = <String, Object?>{
      'rows': total,
      'seed_s': (seedMs / 1000).toStringAsFixed(1),
      'seed_importBatch_max_ms': maxOf(p, 'seed', 'repo.importBatch'),
      'restart_repo_open_ms': maxOf(p, 'restart', 'repo.open'),
      'restart_repo_transactions_ms': maxOf(p, 'restart', 'repo.transactions'),
      'restart_wc_reload_ms': maxOf(p, 'restart', 'wc.reload'),
      'weekly_import_files_ms': maxOf(p, 'weekly-import', 'import.files'),
      'weekly_import_parse_ms': maxOf(p, 'weekly-import', 'import.parse'),
      'weekly_repo_importBatch_ms': maxOf(p, 'weekly-import', 'repo.importBatch'),
      'weekly_wc_reload_ms': maxOf(p, 'weekly-import', 'wc.reload'),
      'year_import_files_ms': maxOf(p, 'year-import', 'import.files'),
      'reimport_import_files_ms': maxOf(p, 're-import', 'import.files'),
      'derive_wc_reload_ms': maxOf(p, 'derive', 'wc.reload'),
      'derive_wc_period_max_ms': maxOf(p, 'derive', 'wc.period'),
      'derive_wc_payPeriods_max_ms': maxOf(p, 'derive', 'wc.payPeriods'),
      'derive_wc_monthSummary_max_ms': maxOf(p, 'derive', 'wc.monthSummary'),
      'derive_spending_derive_max_ms': maxOf(p, 'derive', 'spending.derive'),
      'months_spending_derive_max_ms': maxOf(p, 'spending-months', 'spending.derive'),
      'frames_tabs': framesTabs,
      'frames_spending_scroll': framesScroll,
      'frame_windows': [
        for (final m in RegExp(r' bw\.frames frames\.window (\{.*\})$', multiLine: true).allMatches(log)) jsonDecode(m[1]!),
      ].where((w) => (w as Map)['frames'] is int && (w['frames'] as int) > 5).toList(),
      'mem': [for (final m in RegExp(r' bw\.mem mem (\{.*\})$', multiLine: true).allMatches(log)) jsonDecode(m[1]!)].lastOrNull,
    };
    Harness.report['bigWallet'] = numbers;
    for (final e in numbers.entries) {
      if (e.value is! List) debugPrint('PERF ${e.key} = ${e.value is Map ? jsonEncode(e.value) : e.value}');
    }

    // Bounds ~5-10x the emulator numbers of 2026-10-17 (software rendering; desktops are faster): they fail on real
    // regressions, not noise. Measured then: reload 262 ms, weekly import 92 ms, spending.derive 24 ms, scroll p90 1.5 ms.
    void under(String key, int ms) => expect(numbers[key] as int, lessThan(ms), reason: '$key = ${numbers[key]} ms');
    under('restart_repo_open_ms', 500);
    under('restart_repo_transactions_ms', 750);
    under('restart_wc_reload_ms', 2000);
    under('weekly_import_files_ms', 2000);
    under('weekly_wc_reload_ms', 2000);
    under('year_import_files_ms', 3000);
    under('reimport_import_files_ms', 1500);
    under('derive_wc_reload_ms', 2000);
    under('derive_wc_period_max_ms', 100);
    under('derive_wc_payPeriods_max_ms', 200);
    under('derive_wc_monthSummary_max_ms', 300);
    under('derive_spending_derive_max_ms', 300);
    // Switching tabs only moves the IndexedStack: nothing derived is worked out again, so a broken cache shows here.
    for (final name in ['wc.period', 'wc.payPeriods', 'wc.monthSummary', 'spending.derive']) {
      expect(p['tabs']?[name], isNull, reason: '$name was recomputed while switching tabs: ${p['tabs']?[name]} ms');
    }
    under('months_spending_derive_max_ms', 300);
    expect(framesScroll['frames'] as int, greaterThan(20), reason: 'frame timings arrived');
    expect(framesScroll['build_p90_ms'] as num, lessThan(50), reason: 'Spending scroll frames: $framesScroll');
    expect(framesTabs['build_max_ms'] as num, lessThan(1000), reason: 'tab switch frames: $framesTabs');
  });
}
