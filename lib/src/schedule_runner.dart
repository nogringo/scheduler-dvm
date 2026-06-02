// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'dvm_job.dart';
import 'scheduler_dvm_config.dart';

typedef DueJobHandler = Future<void> Function(String jobId);

class ScheduleRunner {
  final DvmClock _clock;
  final DueJobHandler _onDue;
  final Map<String, Timer> _timers = {};

  ScheduleRunner({required DvmClock clock, required DueJobHandler onDue})
    : _clock = clock,
      _onDue = onDue;

  void schedule(DvmJob job) {
    cancel(job.jobId);
    if (job.isTerminal) return;

    final now = _clock().millisecondsSinceEpoch ~/ 1000;
    final delaySeconds = job.scheduleAt - now;
    if (delaySeconds <= 0) {
      unawaited(_run(job.jobId));
      return;
    }

    _timers[job.jobId] = Timer(Duration(seconds: delaySeconds), () {
      _timers.remove(job.jobId);
      unawaited(_run(job.jobId));
    });
  }

  void cancel(String jobId) {
    _timers.remove(jobId)?.cancel();
  }

  Future<void> dispose() async {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<void> _run(String jobId) async {
    try {
      await _onDue(jobId);
    } catch (_) {
      // The caller owns durable job state and status feedback.
    }
  }
}
