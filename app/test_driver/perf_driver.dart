// Host side of the profile-mode performance test (integration_test/perf_test.dart), run by `tools/build.sh perf`:
//   flutter drive --profile -d linux --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart
// For every `perf_<action>` timeline the test reported it writes, into $BW_PERF_OUT (the run's log folder):
//   <action>.timeline.json          the full trace (open in DevTools > Performance or ui.perfetto.dev)
//   <action>.timeline_summary.json  flutter_driver's TimelineSummary
// plus one line per action in perf-records.jsonl (perf_budget.dart `historyRecord`; tools/build_log.py perf adds them
// to history/perf.jsonl), prints the numbers, checks the budgets and exits with 1 on an overrun.
// Only frame numbers and counts here; no wallet data reaches the files.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

import 'perf_budget.dart';

/// Budgets per action, from baseline runs on 2026-10-19 after the tab-switch fix (build p90 ≤ 1.4 ms, 0 missed build
/// frames, ~190–250 frames; build max: tab switch ≤ 10 ms, Spending scroll 8.9–14.0 ms). Build limits are strict; raster
/// limits are loose because Xvfb uses software GL and the shared laptop's load moves raster p90 between 8 and 20 ms.
/// Scrolling gets a wider build max (28 ms) than switching tabs (20 ms): post-fix runs under load reached 14.0 ms
/// (history/perf.jsonl), so 20 left only about 1.4x headroom on a shared laptop. Lasting jank is still caught by the
/// missed-build-frames limit of 2. An action without an entry gets the default.
const _baseline = PerfBudget(buildP90Ms: 4, buildMaxMs: 20, rasterP90Ms: 30, rasterMaxMs: 60, missedBuildFrames: 2, minFrames: 100);
const _scroll = PerfBudget(buildP90Ms: 4, buildMaxMs: 28, rasterP90Ms: 30, rasterMaxMs: 60, missedBuildFrames: 2, minFrames: 100);
const budgets = <String, PerfBudget>{'spending_scroll': _scroll, 'tab_switch': _baseline};

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
