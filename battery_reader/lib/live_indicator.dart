/// Live-update indicator (GitHub #61) — "is data flowing right now?" at a
/// glance, per battery, on the list card and the detail header.
///
/// [liveStatusFor] is the pure, unit-tested decision: from the connection
/// state, the silence since the last decoded frame, the #62 probe verdict and
/// the #53 sampling state it yields a [LiveLevel] + text:
///
///  * live     — a frame within [staleMs] (3 s): green dot,
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
///
/// #64: the dot flashes ONCE per decoded telemetry cycle — event-driven, not a
/// free-running animation. The widget subscribes to the connection's event
/// stream and [PulseTrigger] picks the cycle marker (one BAL_STATUS per ~1 Hz
/// cycle; in background sampling one per captured sample), firing a single
/// ~200 ms ease-out on [LiveDot]. No telemetry, no pulse: the level / colour
/// rules above then say how old the data is.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'battery_connection.dart';
import 'battery_protocol.dart';
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

/// #64: decides, per decoded event, whether the dot flashes. Pure and
/// unit-tested. The cycle marker is the BAL_STATUS ([BalancerEvent]) frame —
/// exactly one per ~1 Hz telemetry cycle, so the flash is 1:1 with real
/// cycles, not per frame. In background sampling (#53) a sample connects,
/// captures one full cycle (which can straddle two BAL_STATUS frames) and
/// disconnects: only the FIRST marker per link session pulses, re-armed when
/// the link goes down, so each captured sample flashes exactly once.
class PulseTrigger {
  bool _armed = true;

  /// True iff [e] is the marker that ends a cycle and should produce one pulse.
  bool onEvent(BatteryEvent e, {bool sampling = false}) {
    if (e is! BalancerEvent) return false;
    if (!sampling) return true;
    if (!_armed) return false;
    _armed = false;
    return true;
  }

  /// A connection-state change: any state but connected re-arms the
  /// once-per-sample pulse.
  void onConnState(ConnState s) {
    if (s != ConnState.connected) _armed = true;
  }
}

/// How long one flash lasts (#64): a quick ease-out, well under a cycle.
const Duration pulseDuration = Duration(milliseconds: 200);

/// The dot alone (#64): rebuilt by the pulse animation only — the text beside
/// it never repaints on a frame. [pulse] runs 0 → 1 over [pulseDuration] on
/// each cycle (0 = just decoded: enlarged and lit; 1 = at rest, solid dot).
class LiveDot extends StatelessWidget {
  final Animation<double> pulse;
  final Color color;
  final double size;

  const LiveDot(
      {super.key, required this.pulse, required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, _) {
          // Ease-out: a jump to 1.6× with a glow, decaying back to rest.
          final t = Curves.easeOut.transform(pulse.value);
          final k = 1 - t;
          return Transform.scale(
            scale: 1 + 0.6 * k,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color.lerp(color, Colors.white, 0.45 * k),
                shape: BoxShape.circle,
                boxShadow: k == 0
                    ? null
                    : [
                        BoxShadow(
                            color: color.withValues(alpha: 0.7 * k),
                            blurRadius: size * 0.8 * k,
                            spreadRadius: size * 0.25 * k),
                      ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The dot + text. Self-ticking (300 ms) and self-contained: only this
/// widget repaints as the age text advances, and only when it changed; the
/// dot's flash (#64) is driven by the connection's events, not the timer.
class LiveIndicator extends StatefulWidget {
  final BatteryConnection conn;

  /// #53: the manager's sampling state, read on each tick and each event.
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
  StreamSubscription<BatteryEvent>? _events;
  StreamSubscription<ConnState>? _conn;
  final PulseTrigger _trigger = PulseTrigger();
  late LiveStatus _status = _compute();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: pulseDuration,
    value: 1.0, // at rest
  );

  LiveStatus _compute() => liveStatusOf(
        widget.conn,
        sampling: widget.sampling?.call() ?? false,
        nextDueMs: widget.nextDueMs?.call(),
      );

  @override
  void initState() {
    super.initState();
    _subscribe();
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final next = _compute();
      if (next == _status) return;
      setState(() => _status = next);
    });
  }

  @override
  void didUpdateWidget(LiveIndicator old) {
    super.didUpdateWidget(old);
    if (old.conn != widget.conn) _subscribe();
  }

  /// (Re)subscribe to the connection's streams; a swapped connection (demo /
  /// live toggle) drops the old subscriptions first.
  void _subscribe() {
    _events?.cancel();
    _conn?.cancel();
    _events = widget.conn.events.listen(_onEvent);
    _conn = widget.conn.connection.listen(_trigger.onConnState);
  }

  void _onEvent(BatteryEvent e) {
    if (!mounted) return;
    if (_trigger.onEvent(e, sampling: widget.sampling?.call() ?? false)) {
      // One flash: restart the ease-out from the lit state. The controller
      // repaints LiveDot alone — no setState, no text rebuild.
      _pulse.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _events?.cancel();
    _conn?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LiveDot(pulse: _pulse, color: s.color, size: widget.fontSize * 0.7),
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
