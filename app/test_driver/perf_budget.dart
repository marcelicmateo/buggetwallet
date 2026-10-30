// Budgets for the profile-mode performance test (integration_test/perf_test.dart, driven by perf_driver.dart).
// Pure Dart (no Flutter, no dart:io) so test/perf_budget_test.dart can run it. The numbers are in milliseconds of one
// frame, taken from flutter_driver's TimelineSummary.summaryJson.

/// Limits for one measured action. A value equal to its limit passes.
///
/// The app targets 60 Hz (owner, 2026-10-30), so a frame is 1000/60 = 16.7 ms. Gated: build p90, the share of missed build
/// frames (`missed_frame_build_budget_count / frame_count`), the worst build frame and the worst raster frame. Raster p90 and
/// the missed raster frames are recorded in the history only: the perf test runs on software GL under Xvfb, whose raster
/// times are not a GPU's.
class PerfBudget {
  const PerfBudget({
    this.buildP90Ms = frame60HzMs,
    this.buildMaxMs = 50,
    this.rasterMaxMs = 250,
    this.missedBuildShare = 0.10,
    this.minFrames = 10,
  });

  /// One frame at 60 Hz.
  static const frame60HzMs = 1000 / 60;

  final double buildP90Ms, buildMaxMs, rasterMaxMs;

  /// Largest allowed share (0..1) of the frames that missed the build budget.
  final double missedBuildShare;

  /// Fewer frames than this means the trace is broken (no frames were recorded).
  final int minFrames;
}

/// The frame numbers of one action.
class PerfMetrics {
  const PerfMetrics({
    required this.frameCount,
    required this.buildP90Ms,
    required this.buildMaxMs,
    required this.rasterP90Ms,
    required this.rasterMaxMs,
    required this.missedBuildFrames,
    required this.missedRasterFrames,
  });

  /// Reads the keys frame_count, 90th_percentile_frame_build_time_millis, worst_frame_build_time_millis,
  /// 90th_percentile_frame_rasterizer_time_millis, worst_frame_rasterizer_time_millis, missed_frame_build_budget_count
  /// and missed_frame_rasterizer_budget_count of `TimelineSummary.summaryJson`. Numbers may be int or double.
  /// Throws a [FormatException] naming the key when one is missing, null, not a number, NaN, infinite or negative.
  factory PerfMetrics.fromSummary(Map<String, Object?> json) {
    double number(String key) {
      if (!json.containsKey(key)) throw FormatException('perf summary: "$key" is missing');
      final v = json[key];
      if (v == null) throw FormatException('perf summary: "$key" is null');
      if (v is! num) throw FormatException('perf summary: "$key" is not a number');
      if (v.isNaN || v.isInfinite || v < 0) throw FormatException('perf summary: "$key" is not a finite, non-negative number');
      return v.toDouble();
    }

    return PerfMetrics(
      frameCount: number('frame_count').round(),
      buildP90Ms: number('90th_percentile_frame_build_time_millis'),
      buildMaxMs: number('worst_frame_build_time_millis'),
      rasterP90Ms: number('90th_percentile_frame_rasterizer_time_millis'),
      rasterMaxMs: number('worst_frame_rasterizer_time_millis'),
      missedBuildFrames: number('missed_frame_build_budget_count').round(),
      missedRasterFrames: number('missed_frame_rasterizer_budget_count').round(),
    );
  }

  final int frameCount, missedBuildFrames, missedRasterFrames;
  final double buildP90Ms, buildMaxMs, rasterP90Ms, rasterMaxMs;

  /// Missed build frames as a share of all frames (0 when there are no frames: [PerfBudget.minFrames] reports that).
  double get missedBuildShare => frameCount == 0 ? 0 : missedBuildFrames / frameCount;

  Map<String, Object?> toJson() => {
        'frame_count': frameCount,
        'build_p90_ms': buildP90Ms,
        'build_max_ms': buildMaxMs,
        'raster_p90_ms': rasterP90Ms,
        'raster_max_ms': rasterMaxMs,
        'missed_build_frames': missedBuildFrames,
        'missed_raster_frames': missedRasterFrames,
      };
}

String _ms(double v) => v.toStringAsFixed(1);
String _pct(double v) => '${(v * 100).toStringAsFixed(1)} %';

/// One human-readable line per exceeded limit (frames, build p90, build max, raster max, missed build share). Fewer frames than [PerfBudget.minFrames] is an overrun too, and the other checks still run.
/// An empty list means within budget.
List<String> overruns(PerfMetrics m, PerfBudget b) => [
      if (m.frameCount < b.minFrames) 'frames: ${m.frameCount} < ${b.minFrames} (the trace is broken)',
      if (m.buildP90Ms > b.buildP90Ms) 'build p90: ${_ms(m.buildP90Ms)} ms > ${_ms(b.buildP90Ms)} ms',
      if (m.buildMaxMs > b.buildMaxMs) 'build max: ${_ms(m.buildMaxMs)} ms > ${_ms(b.buildMaxMs)} ms',
      if (m.rasterMaxMs > b.rasterMaxMs) 'raster max: ${_ms(m.rasterMaxMs)} ms > ${_ms(b.rasterMaxMs)} ms',
      if (m.missedBuildShare > b.missedBuildShare)
        'missed build frames: ${m.missedBuildFrames} of ${m.frameCount} (${_pct(m.missedBuildShare)}) > ${_pct(b.missedBuildShare)}',
    ];

/// The history line of one action: `{"time", "commit", "action", ...metrics, "ok"}`.
Map<String, Object?> historyRecord(String action, PerfMetrics m, PerfBudget b, {required String commit, required String time}) => {
      'time': time,
      'commit': commit,
      'action': action,
      ...m.toJson(),
      'ok': overruns(m, b).isEmpty,
    };
