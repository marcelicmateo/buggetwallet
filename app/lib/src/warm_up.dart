// Idle warm-up: works out the derived values the tabs will ask for, one small step at a time, while the app is idle (after the
// first frame, after a reload, after a day change). A step is one memo, so no frame waits for more than one. Each step runs in
// its own event-loop turn, between frames and only while nothing animates and no frame is waiting ([WarmUp.whenIdle]). (The
// scheduler's own idle tasks are not used: while an animation runs it polls them in a tight loop.) A new data version cancels the run.
//
// Privacy: the log line carries counts and milliseconds only; task names are fixed words in the code.
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/gestures.dart'
    show GestureBinding, PointerCancelEvent, PointerDownEvent, PointerEvent, PointerScrollEvent, PointerUpEvent;
import 'package:flutter/scheduler.dart';
import 'package:wallet_core/wallet_core.dart' show Level, Logger, logError, logEvent;

final _log = Logger('bw.warmup');

/// One warm-up step: a fixed name (never data) and the work, usually one call that fills a memo.
typedef WarmTask = (String, void Function());

class WarmUp {
  /// Off in `app/test` (`test/flutter_test_config.dart`): idle tasks are zero-delay timers, which a widget test with
  /// fake async reports as pending at its end. The warm-up tests switch it on.
  static bool enabled = true;

  /// The shell starts the warm-up after the first frame was rasterized. A widget test has no rasterizer: it sets this false.
  static bool waitForFirstRaster = true;

  /// How long to wait before looking again when a frame or an animation is in the way.
  static const retry = Duration(milliseconds: 32);

  /// The same while the app is hidden (frames are off): no need to look often.
  static const hiddenRetry = Duration(milliseconds: 500);

  /// Nothing runs while a pointer is down or for this long after the last touch, click or scroll: a finger on the screen is the
  /// moment a frame must not wait for a task.
  static const quietAfterPointer = Duration(milliseconds: 300);

  static int _down = 0;
  static bool _recentPointer = false;
  static Timer? _quiet;
  static bool _routed = false;

  static void _pointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      _down++;
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      if (_down > 0) _down--;
    } else if (e is! PointerScrollEvent) {
      return; // moves and hovers: a pointer that is down is already counted
    }
    _recentPointer = true;
    _quiet?.cancel();
    _quiet = Timer(quietAfterPointer, () => _recentPointer = false);
  }

  /// Forgets the pointer state (tests).
  @visibleForTesting
  static void resetPointerState() {
    _quiet?.cancel();
    _quiet = null;
    _down = 0;
    _recentPointer = false;
  }

  /// Runs [work] in a later event-loop turn, once the app is idle: nothing animates, no frame is scheduled, frames are on (the app
  /// is shown) and no finger or mouse wheel was busy lately (looking again every [retry] until then). [wanted] is asked before each
  /// look: when it says no, [work] never runs.
  static void whenIdle(void Function() work, {bool Function()? wanted}) {
    if (!_routed) {
      _routed = true;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    }
    void attempt() {
      if (wanted != null && !wanted()) return;
      final s = SchedulerBinding.instance;
      if (!s.framesEnabled) {
        Timer(hiddenRetry, attempt);
        return;
      }
      if (s.transientCallbackCount > 0 || s.hasScheduledFrame || _down > 0 || _recentPointer) {
        Timer(retry, attempt);
        return;
      }
      work();
    }

    Timer.run(attempt);
  }

  /// A task over this many milliseconds is logged by name (`warmup.slow`): split it.
  static const slowTaskMs = 16;

  /// Runs one task, logs a failure by name and a slow one (over [slowTaskMs]) by name; returns the milliseconds it took.
  static int _runTask(String name, void Function() work) {
    final sw = Stopwatch()..start();
    try {
      work();
    } catch (e, st) {
      logError(_log, 'warmup.taskFailed', e, st, fields: {'task': name});
    }
    final ms = sw.elapsedMilliseconds;
    if (ms > slowTaskMs) logEvent(_log, Level.INFO, 'warmup.slow', {'task': name, 'ms': ms});
    return ms;
  }

  /// For a tab the owner opened before its data was ready: one task after each frame (the incoming page fades in meanwhile, which
  /// is the time to calculate), then [done] with true. [done] gets false when [wanted] says no. No idle gate: the owner is waiting.
  static void perFrame(List<WarmTask> tasks, {required bool Function() wanted, required void Function(bool completed) done}) {
    var i = 0;
    void step() {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!wanted()) return done(false);
        if (i >= tasks.length) return done(true);
        final (name, work) = tasks[i++];
        _runTask(name, work);
        step();
      });
      SchedulerBinding.instance.scheduleFrame();
    }

    step();
  }

  int _run = 0;

  /// How many tasks the current or last run has finished (for tests).
  int tasksRun = 0;

  /// Stops the current run, if any (a task already queued sees this and does nothing).
  void cancel() => _run++;

  /// Runs [tasks] one per idle task. [current] says whether the data they work on is still the data of the wallet; when it turns
  /// false the run ends quietly. [onDone] is called once after the last task, not when the run was cancelled. Starting a run
  /// cancels the previous one. A task that throws is logged by name and skipped.
  void start(List<WarmTask> tasks, {required bool Function() current, void Function()? onDone}) {
    final run = ++_run;
    if (!enabled) return;
    var i = 0;
    var computeMs = 0;
    var slowestMs = 0;
    var slowest = '';
    tasksRun = 0;
    final wall = Stopwatch()..start();
    void next() {
      whenIdle(() {
        if (i >= tasks.length) {
          logEvent(_log, Level.INFO, 'warmup.done',
              {'tasks': tasks.length, 'ms': computeMs, 'slowest': slowest, 'slowestMs': slowestMs, 'wallMs': wall.elapsedMilliseconds});
          onDone?.call();
          return;
        }
        final (name, work) = tasks[i++];
        final ms = _runTask(name, work);
        computeMs += ms;
        if (ms > slowestMs) {
          slowestMs = ms;
          slowest = name;
        }
        tasksRun = i;
        next();
      }, wanted: () => run == _run && current());
    }

    next();
  }
}
