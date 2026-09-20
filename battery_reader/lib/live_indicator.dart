/// Live-update indicator (GitHub #61) — "is data flowing right now?" at a
/// glance, per battery, on the list card and the detail header.
///
/// [liveStatusFor] is the pure, unit-tested decision: from the connection
/// state, the silence since the last decoded frame, the #62 probe verdict and
/// the #53 sampling state it yields a [LiveLevel] + text:
///
///  * live     — a frame within [staleMs] (3 s): pulsing green dot,
///               "live · updated 0.4 s ago", ticking with each decoded cycle;
///  * stale    — 3–10 s: amber "updated 5.2 s ago";
///  * silent   — ≥ [BatteryConnection.notStreamingMs] (10 s): red
///               "not streaming …" refined by the probe (dormant / awake /
///               no reply), matching the not-streaming watchdog;
///  * sampled  — background sampling mode: "sampled 2 min ago · next in 3 min";
///  * connecting / offline.
///
/// [LiveIndicator] is a small self-ticking widget (its own 300 ms timer,
/// repainting only itself and only when the text or level changes), so the
/// list page's 300 ms signature tick stays cheap — it carries just the level.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'battery_connection.dart';
import 'fmt.dart';
import 'health_palette.dart';

enum LiveLevel { live, stale, silent, sampled, connecting, offline }

/// The indicator's state: level + the text beside the dot.
class LiveStatus {
  final LiveLevel level;
  final String text;
  const LiveStatus(this.level, this.text);

  Color get color => switch (level) {
        LiveLevel.live => HealthPalette.healthy,
        LiveLevel.stale => Colors.amber,
        LiveLevel.silent => HealthPalette.faultRed,
        LiveLevel.sampled => Colors.lightBlueAccent,
        LiveLevel.connecting => Colors.amber,
        LiveLevel.offline => Colors.white38,
      };

  @override
  bool operator ==(Object other) =>
      other is LiveStatus && other.level == level && other.text == text;

  @override
  int get hashCode => Object.hash(level, text);

  @override
  String toString() => 'LiveStatus(${level.name}: $text)';
}

/// A frame younger than this is "live"; older is "stale" until
/// [BatteryConnection.notStreamingMs] makes it "silent".
const int staleMs = 3000;

/// The pure decision. [silenceMs] is ms since the last decoded frame on the
/// current link (or since it came up); [streamClass] the #62 probe verdict;
/// while [sampling] (background mode, link released) the sample ages are
/// shown instead: [lastFrameEverMs] = last decoded frame on any link,
/// [nextDueMs] = the scheduler's next sample.
LiveStatus liveStatusFor({
  required ConnState conn,
  required int? silenceMs,
  required int nowMs,
  StreamClass streamClass = StreamClass.unknown,
  bool sampling = false,
  int? lastFrameEverMs,
  int? nextDueMs,
  bool hasFrameOnLink = true,
}) {
  if (sampling && conn != ConnState.connected) {
    final last = lastFrameEverMs == null
        ? 'not sampled yet'
        : 'sampled ${fmtAgeShort(nowMs - lastFrameEverMs)} ago';
    final next = nextDueMs == null
        ? (conn == ConnState.connecting ? 'sampling now' : 'next sample due')
        : (nextDueMs <= nowMs
            ? 'sampling now'
            : 'next in ${fmtAgeShort(nextDueMs - nowMs)}');
    return LiveStatus(LiveLevel.sampled, '$last · $next');
  }
  switch (conn) {
    case ConnState.connecting:
    case ConnState.scanning:
      return const LiveStatus(LiveLevel.connecting, 'connecting…');
    case ConnState.idle:
    case ConnState.disconnected:
      return const LiveStatus(LiveLevel.offline, 'not connected');
    case ConnState.connected:
      break;
  }
  final silence = silenceMs ?? 0;
  if (silence >= BatteryConnection.notStreamingMs) {
    final why = switch (streamClass) {
      // #63: with or without the bridge's 0x30, the BMS is not running.
      StreamClass.dormant || StreamClass.noResponse =>
        BatteryConnection.bmsNotRunningState,
      StreamClass.awakeNotStreaming =>
        BatteryConnection.awakeNotStreamingState,
      _ => '${fmtAgeShort(silence)} silent',
    };
    return LiveStatus(LiveLevel.silent, 'not streaming · $why');
  }
  if (!hasFrameOnLink) {
    return const LiveStatus(
        LiveLevel.stale, 'connected · waiting for the first frame');
  }
  if (silence >= staleMs) {
    return LiveStatus(LiveLevel.stale, 'updated ${fmtAgeShort(silence)} ago');
  }
  return LiveStatus(LiveLevel.live, 'live · updated ${fmtAgeShort(silence)} ago');
}

/// [liveStatusFor] over a live connection. [sampling] / [nextDueMs] come from
/// the manager (#53).
LiveStatus liveStatusOf(BatteryConnection c,
    {bool sampling = false, int? nextDueMs, int? nowMs}) {
  final now = nowMs ?? c.now().millisecondsSinceEpoch;
  return liveStatusFor(
    conn: c.connState,
    silenceMs: c.silenceMs,
    nowMs: now,
    streamClass: c.streamClass,
    sampling: sampling,
    lastFrameEverMs: c.lastFrameEverMs,
    nextDueMs: nextDueMs,
    hasFrameOnLink: c.lastTelemetryMs != null,
  );
}

/// The dot + text. Self-ticking (300 ms) and self-contained: only this
/// widget repaints as the age text advances, and only when it changed.
class LiveIndicator extends StatefulWidget {
  final BatteryConnection conn;

  /// #53: the manager's sampling state, read on each tick.
  final bool Function()? sampling;
  final int? Function()? nextDueMs;
  final double fontSize;

  const LiveIndicator({
    super.key,
    required this.conn,
    this.sampling,
    this.nextDueMs,
    this.fontSize = 12,
  });

  @override
  State<LiveIndicator> createState() => _LiveIndicatorState();
}

class _LiveIndicatorState extends State<LiveIndicator>
    with SingleTickerProviderStateMixin {
  Timer? _timer;
  late LiveStatus _status = _compute();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: 0.35,
    upperBound: 1.0,
  );

  LiveStatus _compute() => liveStatusOf(
        widget.conn,
        sampling: widget.sampling?.call() ?? false,
        nextDueMs: widget.nextDueMs?.call(),
      );

  @override
  void initState() {
    super.initState();
    _syncPulse();
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final next = _compute();
      if (next == _status) return;
      setState(() => _status = next);
      _syncPulse();
    });
  }

  void _syncPulse() {
    if (_status.level == LiveLevel.live) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 1.0;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final size = widget.fontSize * 0.7;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: _pulse,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            s.text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: s.color,
              fontSize: widget.fontSize,
              fontWeight: s.level == LiveLevel.silent
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
