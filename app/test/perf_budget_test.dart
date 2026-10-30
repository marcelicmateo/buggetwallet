import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../test_driver/perf_budget.dart';

const _keys = <String>[
  'frame_count',
  '90th_percentile_frame_build_time_millis',
  'worst_frame_build_time_millis',
  '90th_percentile_frame_rasterizer_time_millis',
  'worst_frame_rasterizer_time_millis',
  'missed_frame_build_budget_count',
  'missed_frame_rasterizer_budget_count',
];

Map<String, Object?> _summary() => <String, Object?>{
      'average_frame_build_time_millis': 3.2,
      'frame_count': 120,
      '90th_percentile_frame_build_time_millis': 5.5,
      '99th_percentile_frame_build_time_millis': 9.0,
      'worst_frame_build_time_millis': 20.25,
      'missed_frame_build_budget_count': 2,
      'average_frame_rasterizer_time_millis': 10.0,
      '90th_percentile_frame_rasterizer_time_millis': 25,
      'worst_frame_rasterizer_time_millis': 90.5,
      'missed_frame_rasterizer_budget_count': 3,
      'frame_begin_times': <int>[1, 2, 3],
      'frame_build_times': <int>[100, 200],
      'new_gen_gc_count': 4,
    };

PerfMetrics _ok({
  int frameCount = 100,
  double buildP90 = 5,
  double buildMax = 20,
  double rasterP90 = 20,
  double rasterMax = 100,
  int missedBuild = 0,
  int missedRaster = 0,
}) =>
    PerfMetrics(
      frameCount: frameCount,
      buildP90Ms: buildP90,
      buildMaxMs: buildMax,
      rasterP90Ms: rasterP90,
      rasterMaxMs: rasterMax,
      missedBuildFrames: missedBuild,
      missedRasterFrames: missedRaster,
    );

void main() {
  const budget = PerfBudget();

  group('PerfBudget defaults', () {
    test('match the documented values', () {
      expect(budget.buildP90Ms, closeTo(16.67, 0.01), reason: 'one frame at 60 Hz');
      expect(budget.buildP90Ms, PerfBudget.frame60HzMs);
      expect(budget.buildMaxMs, 50);
      expect(budget.rasterMaxMs, 250);
      expect(budget.missedBuildShare, 0.10);
      expect(budget.minFrames, 10);
    });
  });

  group('PerfMetrics.fromSummary', () {
    test('parses a realistic summary and ignores unknown keys', () {
      final m = PerfMetrics.fromSummary(_summary());
      expect(m.frameCount, 120);
      expect(m.buildP90Ms, 5.5);
      expect(m.buildMaxMs, 20.25);
      expect(m.rasterP90Ms, 25.0);
      expect(m.rasterMaxMs, 90.5);
      expect(m.missedBuildFrames, 2);
      expect(m.missedRasterFrames, 3);
    });

    test('accepts ints and doubles in any numeric field', () {
      final j = <String, Object?>{
        'frame_count': 50.0,
        '90th_percentile_frame_build_time_millis': 6,
        'worst_frame_build_time_millis': 30,
        '90th_percentile_frame_rasterizer_time_millis': 12.5,
        'worst_frame_rasterizer_time_millis': 80,
        'missed_frame_build_budget_count': 1.0,
        'missed_frame_rasterizer_budget_count': 0,
      };
      final m = PerfMetrics.fromSummary(j);
      expect(m.frameCount, 50);
      expect(m.buildP90Ms, 6.0);
      expect(m.buildMaxMs, 30.0);
      expect(m.rasterP90Ms, 12.5);
      expect(m.missedBuildFrames, 1);
      expect(m.missedRasterFrames, 0);
    });

    test('zero values are valid', () {
      final j = _summary();
      for (final k in _keys) {
        j[k] = 0;
      }
      final m = PerfMetrics.fromSummary(j);
      expect(m.frameCount, 0);
      expect(m.buildMaxMs, 0);
    });

    for (final key in _keys) {
      group(key, () {
        void rejects(String label, void Function(Map<String, Object?>) mutate) {
          test(label, () {
            final j = _summary();
            mutate(j);
            expect(
              () => PerfMetrics.fromSummary(j),
              throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(key))),
            );
          });
        }

        rejects('missing', (j) => j.remove(key));
        rejects('null', (j) => j[key] = null);
        rejects('string', (j) => j[key] = '12');
        rejects('bool', (j) => j[key] = true);
        rejects('NaN', (j) => j[key] = double.nan);
        rejects('infinity', (j) => j[key] = double.infinity);
        rejects('negative infinity', (j) => j[key] = double.negativeInfinity);
        rejects('negative int', (j) => j[key] = -1);
        rejects('negative double', (j) => j[key] = -0.5);
      });
    }
  });

  group('overruns', () {
    test('a healthy run has none', () {
      expect(overruns(_ok(), budget), isEmpty);
    });

    test('every limit exactly equal passes', () {
      final m = _ok(frameCount: 10, buildP90: PerfBudget.frame60HzMs, buildMax: 50, rasterMax: 250, missedBuild: 1);
      expect(overruns(m, budget), isEmpty);
    });

    test('raster p90 is recorded, not gated', () {
      expect(overruns(_ok(rasterP90: 5000), budget), isEmpty);
    });

    test('missed build frames are gated as a share of the frames, not as a count', () {
      expect(overruns(_ok(frameCount: 200, missedBuild: 20), budget), isEmpty, reason: '10 %');
      expect(overruns(_ok(frameCount: 200, missedBuild: 21), budget), hasLength(1), reason: '10.5 %');
      expect(overruns(_ok(frameCount: 1000, missedBuild: 100), budget), isEmpty);
      expect(overruns(_ok(frameCount: 20, missedBuild: 3), budget), hasLength(1), reason: '15 % of a short run');
      expect(overruns(_ok(frameCount: 20, missedBuild: 2), budget), isEmpty);
      expect(_ok(frameCount: 0, missedBuild: 4).missedBuildShare, 0, reason: 'no frames: no division by zero');
    });

    test('missed raster frames never cause an overrun', () {
      expect(overruns(_ok(missedRaster: 100000), budget), isEmpty);
    });

    test('too few frames: below minFrames fails, at minFrames passes', () {
      final below = overruns(_ok(frameCount: 9), budget);
      expect(below, hasLength(1));
      expect(below.single, isNotEmpty);
      expect(below.single.toLowerCase(), contains('frame'));
      expect(overruns(_ok(frameCount: 10), budget), isEmpty);
    });

    test('zero frames is an overrun and other checks still run', () {
      final r = overruns(_ok(frameCount: 0, buildP90: 17), budget);
      expect(r, hasLength(2));
      expect(r[0].toLowerCase(), contains('frame'));
      expect(r[1].toLowerCase(), contains('build'));
    });

    test('just above each limit fails with exactly one line naming the metric', () {
      final cases = <String, PerfMetrics>{
        'build p90': _ok(buildP90: 16.7),
        'build max': _ok(buildMax: 50.001),
        'raster max': _ok(rasterMax: 250.001),
        'missed': _ok(missedBuild: 11),
      };
      for (final e in cases.entries) {
        final r = overruns(e.value, budget);
        expect(r, hasLength(1), reason: e.key);
        expect(r.single, isNotEmpty);
        expect(r.single.toLowerCase(), contains(e.key.split(' ').first), reason: e.key);
      }
    });

    test('several overruns are all listed in the specified order', () {
      final m = _ok(
        frameCount: 3,
        buildP90: 20,
        buildMax: 100,
        rasterP90: 90,
        rasterMax: 500,
        missedBuild: 40,
        missedRaster: 40,
      );
      final r = overruns(m, budget);
      expect(r, hasLength(5));
      expect(r.every((l) => l.isNotEmpty), isTrue);
      expect(r[0].toLowerCase(), contains('frame'));
      expect(r[1].toLowerCase(), contains('build'));
      expect(r[2].toLowerCase(), contains('build'));
      expect(r[3].toLowerCase(), contains('raster'));
      expect(r[4].toLowerCase(), contains('missed'));
      expect(r.toSet(), hasLength(5), reason: 'lines must be distinct');
    });

    test('order holds for a subset: raster max before missed build', () {
      final r = overruns(_ok(rasterMax: 300, missedBuild: 11), budget);
      expect(r, hasLength(2));
      expect(r[0].toLowerCase(), contains('raster'));
      expect(r[1].toLowerCase(), contains('missed'));
    });

    test('custom budget is honoured', () {
      const tight = PerfBudget(
        buildP90Ms: 2,
        buildMaxMs: 4,
        rasterMaxMs: 8,
        missedBuildShare: 0,
        minFrames: 200,
      );
      expect(overruns(_ok(missedBuild: 1), tight), hasLength(5));
      const loose = PerfBudget(
        buildP90Ms: 100,
        buildMaxMs: 1000,
        rasterMaxMs: 1000,
        missedBuildShare: 1,
        minFrames: 1,
      );
      expect(overruns(_ok(buildP90: 50, buildMax: 900, missedBuild: 999, frameCount: 1000), loose), isEmpty);
      expect(overruns(_ok(frameCount: 0), loose), hasLength(1));
    });

    test('custom budget limits are inclusive too', () {
      const b = PerfBudget(buildP90Ms: 3.5, missedBuildShare: 0, minFrames: 1);
      expect(overruns(_ok(frameCount: 1, buildP90: 3.5), b), isEmpty);
      expect(overruns(_ok(frameCount: 1, buildP90: 3.6), b), hasLength(1));
      expect(overruns(_ok(frameCount: 1, buildP90: 1, missedBuild: 1), b), hasLength(1));
    });
  });

  group('toJson', () {
    test('has exactly the seven snake_case keys with exact values', () {
      final m = _ok(
        frameCount: 77,
        buildP90: 4.5,
        buildMax: 21,
        rasterP90: 11.25,
        rasterMax: 99.5,
        missedBuild: 2,
        missedRaster: 3,
      );
      expect(m.toJson(), <String, Object?>{
        'frame_count': 77,
        'build_p90_ms': 4.5,
        'build_max_ms': 21.0,
        'raster_p90_ms': 11.25,
        'raster_max_ms': 99.5,
        'missed_build_frames': 2,
        'missed_raster_frames': 3,
      });
    });

    test('survives a jsonEncode / jsonDecode round trip', () {
      final m = PerfMetrics.fromSummary(_summary());
      final back = jsonDecode(jsonEncode(m.toJson())) as Map<String, Object?>;
      expect(back, hasLength(7));
      expect(back['frame_count'], 120);
      expect(back['build_p90_ms'], 5.5);
      expect(back['raster_max_ms'], 90.5);
      expect(back['missed_raster_frames'], 3);
    });
  });

  group('historyRecord', () {
    test('contains exactly time, commit, action, the metrics and ok', () {
      final m = _ok(missedRaster: 4);
      final r = historyRecord('open_plan', m, budget, commit: 'abc1234', time: '2026-10-19T10:00:00Z');
      expect(r.keys.toSet(), <String>{'time', 'commit', 'action', ...m.toJson().keys, 'ok'});
      expect(r['time'], '2026-10-19T10:00:00Z');
      expect(r['commit'], 'abc1234');
      expect(r['action'], 'open_plan');
      for (final e in m.toJson().entries) {
        expect(r[e.key], e.value, reason: e.key);
      }
      expect(r['ok'], isTrue);
      expect(() => jsonEncode(r), returnsNormally);
    });

    test('ok is false when anything overruns', () {
      final r = historyRecord('scroll', _ok(buildMax: 50.5), budget, commit: 'c', time: 't');
      expect(r['ok'], isFalse);
      expect(r['build_max_ms'], 50.5);
    });

    test('ok is false for a broken trace and respects a custom budget', () {
      expect(historyRecord('a', _ok(frameCount: 2), budget, commit: 'c', time: 't')['ok'], isFalse);
      const loose = PerfBudget(minFrames: 1);
      expect(historyRecord('a', _ok(frameCount: 2), loose, commit: 'c', time: 't')['ok'], isTrue);
    });
  });
}
