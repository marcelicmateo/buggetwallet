// Host side of the profile-mode performance test (integration_test/perf_test.dart), run by `make perf`:
//   flutter drive --profile -d linux --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart
// For every `perf_<action>` timeline the test reported it writes, into $BW_PERF_OUT (the run's log folder):
//   <action>.timeline.json          the full trace (open in DevTools > Performance or ui.perfetto.dev)
//   <action>.timeline_summary.json  flutter_driver's TimelineSummary
// plus one line per action in perf-records.jsonl (perf_budget.dart `historyRecord`; wallet-build adds them
// to history/perf.jsonl), prints the numbers, checks the budgets and exits with 1 on an overrun.
// Only frame numbers and counts here; no wallet data reaches the files.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

import 'perf_budget.dart';

/// Budgets per action (owner, 2026-10-30): the app targets 60 Hz, so one frame is 16.7 ms. The gates are build p90 <= 16.7 ms,
/// at most 10 % of the frames missing the build budget, worst build frame <= 50 ms and worst raster frame <= 250 ms (software GL
/// under Xvfb; raster p90 is recorded, not gated). Every action has the same budget except for the frame count: the minimum
/// is what a healthy run of that action produces, so a trace that lost its frames fails. An action without an entry gets the
/// default (10 frames).
const _baseline = PerfBudget(minFrames: 100);
// Frame-count noise: the unchanged base measured 96-98 frames here on a busy laptop (history had 106-112), so the floor is 90.
const _scroll = PerfBudget(minFrames: 90);

/// Insights: open, six range switches over ~20k rows, a scroll through five graphs, close. About 92-94 frames were measured.
const _insights = PerfBudget(minFrames: 50);

/// Insights pan and pinch (ZC): drags and pinches of the spending graph over ~20k rows. The same budget as the other chart actions.
const _insightsPan = PerfBudget(minFrames: 50);

/// Explore "All" (ENG E4): the whole history, a crosshair sweep, bar size and range changes and a scroll over ~20k rows.
const _exploreAll = PerfBudget(minFrames: 40);

/// First visit of every tab after the data changed (what the idle warm-up should make cheap). Few frames: one per tab and a fade.
const _firstSwitch = PerfBudget(minFrames: 20);

/// The same tabs opened at once after a data change, before the warm-up had time: each switch works its data out one task per frame
/// and then builds the page. The first build of the Budget page is one unit that cannot be split from the app (~80 ms, 2026-10-30,
/// 20k rows, profile mode on a busy laptop); core's `recurringPayments` was the other (~90 ms) until stage CX made it 3-5 ms. So
/// the worst build frame may be 110 ms here (everything else as for every action); lower it to the shared 50 ms once the Budget
/// page's first build is cheaper.
const _earlySwitch = PerfBudget(minFrames: 20, buildMaxMs: 110);
const budgets = <String, PerfBudget>{
  'spending_scroll': _scroll,
  'tab_switch': _baseline,
  'insights': _insights,
  'insights_pan': _insightsPan,
  'explore_all': _exploreAll,
  'first_switch': _firstSwitch,
  'early_switch': _earlySwitch,
};

/// Counts timeline events that look like shader compilation (any stream). Flutter 3.47 has no summary field for shader
/// jank, so this is the closest available signal; a run with Impeller (precompiled shaders) is expected to show 0.
int shaderEvents(Timeline timeline) =>
    (timeline.events ?? const <TimelineEvent>[]).where((e) => (e.name ?? '').toLowerCase().contains('shader')).length;

/// UTC, to the second ("2026-10-19T14:45:00Z"): the container's clock has no zone.
String nowIso() => '${DateTime.now().toUtc().toIso8601String().substring(0, 19)}Z';

Future<void> main() {
  final out = Platform.environment['BW_PERF_OUT'] ?? '../dist/logs';
  final commit = Platform.environment['BW_COMMIT'] ?? 'unknown';
  return integrationDriver(
    // Also on failure: the numbers explain a failed run
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      if (data == null) return;
      await Directory(out).create(recursive: true);
      final time = nowIso();
      final records = <String>[];
      final failures = <String>[];
      for (final key in data.keys.where((k) => k.startsWith('perf_')).toList()..sort()) {
        final action = key.substring('perf_'.length);
        final timeline = Timeline.fromJson(data[key] as Map<String, dynamic>);
        final summary = TimelineSummary.summarize(timeline);
        await summary.writeTimelineToFile(action, destinationDirectory: out, pretty: true);
        final budget = budgets[action] ?? const PerfBudget();
        final PerfMetrics metrics;
        try {
          metrics = PerfMetrics.fromSummary(summary.summaryJson);
        } on FormatException catch (e) {
          failures.add('$action: ${e.message}');
          continue;
        }
        final over = overruns(metrics, budget);
        final record = {...historyRecord(action, metrics, budget, commit: commit, time: time), 'shader_events': shaderEvents(timeline)};
        records.add(jsonEncode(record));
        stdout.writeln('PERF $action: ${jsonEncode(record)}');
        failures.addAll([for (final o in over) '$action: $o']);
      }
      if (records.isEmpty && failures.isEmpty) failures.add('no perf_* timeline in the test report');
      if (records.isNotEmpty) {
        await File('$out/perf-records.jsonl').writeAsString('${records.join('\n')}\n', mode: FileMode.append);
      }
      if (failures.isNotEmpty) {
        stdout.writeln('PERF budget overruns:');
        failures.forEach(stdout.writeln);
        exit(1);
      }
    },
  );
}
