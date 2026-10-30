// Idle warm-up: works out the derived values the tabs will ask for, one small step at a time, while the app is idle (after the
// first frame, after a reload, after a day change). A step is one memo, so no frame waits for more than one. Each step runs in
// its own event-loop turn, between frames and only while nothing animates and no frame is waiting ([WarmUp.whenIdle]). (The
// scheduler's own idle tasks are not used: while an animation runs it polls them in a tight loop.) A new data version cancels the run.
//
// Privacy: the log line carries counts and milliseconds only; task names are fixed words in the code.
import 'dart:async';

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

  /// Runs [work] in a later event-loop turn, once nothing animates and no frame is scheduled (looking again every [retry] until
  /// then). [wanted] is asked before each look: when it says no, [work] never runs.
  static void whenIdle(void Function() work, {bool Function()? wanted}) {
    void attempt() {
      if (wanted != null && !wanted()) return;
      final s = SchedulerBinding.instance;
      if (s.transientCallbackCount > 0 || s.hasScheduledFrame) {
        Timer(retry, attempt);
        return;
      }
      work();
    }

    Timer.run(attempt);
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
    tasksRun = 0;
    final wall = Stopwatch()..start();
    void next() {
      whenIdle(() {
        if (i >= tasks.length) {
          logEvent(_log, Level.INFO, 'warmup.done',
              {'tasks': tasks.length, 'ms': computeMs, 'slowestMs': slowestMs, 'wallMs': wall.elapsedMilliseconds});
          onDone?.call();
          return;
        }
        final (name, work) = tasks[i++];
        final sw = Stopwatch()..start();
        try {
          work();
        } catch (e, st) {
          logError(_log, 'warmup.taskFailed', e, st, fields: {'task': name});
        }
        final ms = sw.elapsedMilliseconds;
        computeMs += ms;
        if (ms > slowestMs) slowestMs = ms;
        tasksRun = i;
        next();
      }, wanted: () => run == _run && current());
    }

    next();
  }
}
