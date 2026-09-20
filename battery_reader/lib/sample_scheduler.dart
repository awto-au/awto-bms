/// Background sampling scheduler (GitHub #53): the pure decisions behind the
/// manager's periodic connect -> capture one cycle -> disconnect loop.
///
/// A held BLE link costs the phone a radio + CPU wake for every ~1 Hz
/// notification and the vendor protocol has no rate control, so backgrounded
/// monitoring does not hold the links at all: every [intervalMs] the manager
/// reconnects each pack, captures one full telemetry cycle (~2-3 s) and
/// disconnects; the radio is idle in between.
///
/// This class owns only WHEN: a sample is due one interval after the previous
/// sample STARTED (the tick anchor), never sooner. A failed sample (no link,
/// no frames) does not retry early — it just waits for the next tick; the
/// per-device connect backoff (#49) is the manager's and is reused as is.
/// Pure Dart, unit-tested with an injected clock.
library;

class SampleScheduler {
  /// Milliseconds between samples (0 = continuous: never due).
  int intervalMs;

  /// When the last sample attempt STARTED (the anchor the next tick counts
  /// from), or null before [enter].
  int? lastStartMs;

  /// When the last sample that captured telemetry finished, or null.
  int? lastSuccessMs;

  /// Consecutive samples that captured nothing (reset by a success).
  int consecutiveFailures = 0;

  /// True between [started] and [finished] (never overlap two samples).
  bool inFlight = false;

  SampleScheduler({this.intervalMs = 0});

  /// Enter sampling mode at [nowMs] (optionally with a new interval). Live
  /// data was flowing until now, so the first sample is one full interval
  /// away and "sampled … ago" reads from now.
  void enter(int nowMs, {int? intervalMs}) {
    if (intervalMs != null) this.intervalMs = intervalMs;
    lastStartMs = nowMs;
    lastSuccessMs = nowMs;
    consecutiveFailures = 0;
    inFlight = false;
  }

  /// Epoch-ms of the next due sample, or null before [enter] / when
  /// continuous.
  int? get nextDueMs => lastStartMs == null || intervalMs <= 0
      ? null
      : lastStartMs! + intervalMs;

  /// Milliseconds until the next sample is due (0 when overdue), or null.
  int? msUntilDue(int nowMs) {
    final due = nextDueMs;
    if (due == null) return null;
    final d = due - nowMs;
    return d < 0 ? 0 : d;
  }

  /// True iff a sample should start now: none in flight and the interval has
  /// elapsed since the last one started.
  bool isDue(int nowMs) {
    final due = nextDueMs;
    return !inFlight && due != null && nowMs >= due;
  }

  /// A sample attempt begins at [nowMs] (re-anchors the next tick).
  void started(int nowMs) {
    inFlight = true;
    lastStartMs = nowMs;
  }

  /// The attempt ended; [ok] iff at least one pack's telemetry was captured.
  /// A failure changes nothing about the next due time.
  void finished(int nowMs, {required bool ok}) {
    inFlight = false;
    if (ok) {
      lastSuccessMs = nowMs;
      consecutiveFailures = 0;
    } else {
      consecutiveFailures++;
    }
  }
}
