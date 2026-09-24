/// Live-update status (GitHub #61 / #64 / #65) — "is data flowing right
/// now?" folded into the ONE status line each battery card and the detail
/// header carry.
///
/// [liveStatusFor] is the pure, unit-tested liveness decision: from the
/// connection state, the silence since the last decoded frame, the #62 probe
/// verdict and the #53 sampling state it yields a [LiveLevel], whether there
/// is data behind the screen ([LiveStatus.hasData]) and the detail text:
///
///  * live     — a frame within [staleMs] (3 s): green dot, "updated 0.4 s
///               ago" (not shown: the blinking dot is the signal);
///  * stale    — 3–10 s: amber, "updated 5.2 s ago" trails the state;
///  * waiting  — connected, no telemetry yet on this link: amber, no data;
///  * silent   — ≥ [BatteryConnection.notStreamingMs] (10 s): red, no data,
///               "not streaming — BMS not running" / "BMS awake, not
///               streaming" per the probe, matching the watchdog;
///  * sampled  — background sampling mode: "sampled 2 min ago · next in 3 min"
///               (data = the last captured sample);
///  * connecting / offline — no data.
///
/// [statusTextFor] (#65) is the pure text rule for the merged line: with data
/// the charge state ("Idle · no load", "Charging") as before, optionally
/// trailed by the stale / sample age; with NO data never a charge state —
/// "No data · <reason>" (or "Offline · last seen …" for a remembered
/// favourite) and the caller renders the figures as "—".
///
/// [LiveStatusLine] is the widget: a self-ticking (300 ms) row whose dot is
/// the live dot and whose figures come from a [LiveStatusLine.trailing]
/// builder told whether there is data. It repaints only itself and only when
/// its text or level changes, so the list page's 300 ms signature tick stays
/// cheap — it carries just the level / hasData.
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

enum LiveLevel { live, stale, waiting, silent, sampled, connecting, offline }

/// The liveness decision: level, whether there is data behind the screen
/// and the detail text (the age while there is data, the reason while not).
class LiveStatus {
  final LiveLevel level;
  final String text;

  /// #65: false whenever the displayed state / figures would be stale or
  /// absent — silent, waiting for the first frame, connecting, offline, or
  /// sampling with no sample captured yet. The status line then shows
  /// "No data · …" and the figures "—".
  final bool hasData;

  const LiveStatus(this.level, this.text, {required this.hasData});

  Color get color => switch (level) {
        LiveLevel.live => HealthPalette.healthy,
        LiveLevel.stale => Colors.amber,
        LiveLevel.waiting => Colors.amber,
        LiveLevel.silent => HealthPalette.faultRed,
        LiveLevel.sampled => Colors.lightBlueAccent,
        LiveLevel.connecting => Colors.amber,
        LiveLevel.offline => Colors.white38,
      };

  @override
  bool operator ==(Object other) =>
      other is LiveStatus &&
      other.level == level &&
      other.text == text &&
      other.hasData == hasData;

  @override
  int get hashCode => Object.hash(level, text, hasData);

  @override
  String toString() =>
      'LiveStatus(${level.name}${hasData ? '' : ', no data'}: $text)';
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
  // #53: between samples (link released) — and mid-sample until the first
  // frame lands (#65: the last sample IS data; no "No data" blip per sample)
  // — the sample ages are shown.
  if (sampling &&
      (conn != ConnState.connected ||
          (!hasFrameOnLink && (silenceMs ?? 0) < staleMs))) {
    final last = lastFrameEverMs == null
        ? 'not sampled yet'
        : 'sampled ${fmtAgeShort(nowMs - lastFrameEverMs)} ago';
    final next = nextDueMs == null
        ? (conn == ConnState.idle || conn == ConnState.disconnected
            ? 'next sample due'
            : 'sampling now')
        : (nextDueMs <= nowMs
            ? 'sampling now'
            : 'next in ${fmtAgeShort(nextDueMs - nowMs)}');
    return LiveStatus(LiveLevel.sampled, '$last · $next',
        hasData: lastFrameEverMs != null);
  }
  switch (conn) {
    case ConnState.connecting:
    case ConnState.scanning:
      return const LiveStatus(LiveLevel.connecting, 'connecting…',
          hasData: false);
    case ConnState.idle:
    case ConnState.disconnected:
      return const LiveStatus(LiveLevel.offline, 'not connected',
          hasData: false);
    case ConnState.connected:
      break;
  }
  final silence = silenceMs ?? 0;
  if (silence >= BatteryConnection.notStreamingMs) {
    return LiveStatus(LiveLevel.silent, silentReason(silence, streamClass),
        hasData: false);
  }
  if (!hasFrameOnLink) {
    return const LiveStatus(LiveLevel.waiting, 'waiting for the first frame',
        hasData: false);
  }
  final age = 'updated ${fmtAgeShort(silence)} ago';
  if (silence >= staleMs) return LiveStatus(LiveLevel.stale, age, hasData: true);
  return LiveStatus(LiveLevel.live, age, hasData: true);
}

/// The #62 verdict as the status line's "No data · …" reason for a silent
/// link: "not streaming — BMS not running" (dormant / no reply, #63), "BMS
/// awake, not streaming", or the plain silence while the probe is pending.
String silentReason(int silenceMs, StreamClass streamClass) =>
    switch (streamClass) {
      StreamClass.dormant || StreamClass.noResponse =>
        'not streaming — ${BatteryConnection.bmsNotRunningState}',
      StreamClass.awakeNotStreaming => BatteryConnection.awakeNotStreamingState,
      _ => 'not streaming — ${fmtAgeShort(silenceMs)} silent',
    };

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

/// #65: what the ONE status line shows — the pure text rule.
///
/// [state] is the charge-state text ("Idle · no load", "Charging") and is
/// null whenever there is no data; [detail] is the trailing age ("updated
/// 5.2 s ago", "sampled 2 min ago · next in 3 min") or, without data, the
/// whole line ("No data · not streaming — BMS not running", "Offline · last
/// seen 5 min ago"). [color] is the dot's (and the detail's) colour — the
/// #61 level colours; [stateColor] the charge-direction colour of the state.
class StatusText {
  final String? state;
  final String? detail;
  final Color color;
  final Color stateColor;
  final bool hasData;
  final LiveLevel level;

  const StatusText({
    required this.state,
    required this.detail,
    required this.color,
    required this.stateColor,
    required this.hasData,
    required this.level,
  });

  /// The whole line as plain text.
  String get text => [state, detail].whereType<String>().join(' · ');

  /// The no-data line is emphasised when the pack is silent (red).
  FontWeight get weight =>
      level == LiveLevel.silent ? FontWeight.w700 : FontWeight.w600;

  @override
  bool operator ==(Object other) =>
      other is StatusText &&
      other.state == state &&
      other.detail == detail &&
      other.color == color &&
      other.stateColor == stateColor &&
      other.hasData == hasData &&
      other.level == level;

  @override
  int get hashCode =>
      Object.hash(state, detail, color, stateColor, hasData, level);

  @override
  String toString() => 'StatusText(${level.name}: $text)';
}

/// The merged status line (#65) from the liveness decision [live] and the
/// charge-direction style [dir] of the pack's (last) state:
///
///  * streaming (live): the state alone — "Idle · no load", "Charging" —
///    green dot (blinking per cycle, #64);
///  * stale: the state + " · updated 5.2 s ago", amber dot;
///  * sampling (#53) with a sample captured: the last captured state +
///    " · sampled 2 min ago · next in 3 min";
///  * NO data (silent / dormant / not running / no reply / awake-not-
///    streaming / waiting for the first frame / connecting / not sampled yet):
///    "No data · <reason>" in the level colour, never a charge state;
///  * an [offline] remembered favourite: "Offline · last seen <relative>",
///    muted — the existing placeholder text.
StatusText statusTextFor(LiveStatus live, ChargeStateStyle dir,
    {bool offline = false, int? lastSeenMs, int? nowMs}) {
  if (offline) {
    return StatusText(
      state: null,
      detail: 'Offline · last seen ${relativeTime(lastSeenMs, nowMs: nowMs)}',
      color: Colors.white38,
      stateColor: Colors.white38,
      hasData: false,
      level: LiveLevel.offline,
    );
  }
  if (!live.hasData) {
    return StatusText(
      state: null,
      detail: 'No data · ${live.text}',
      color: live.color,
      stateColor: live.color,
      hasData: false,
      level: live.level,
    );
  }
  return StatusText(
    state: dir.label,
    detail: live.level == LiveLevel.live ? null : live.text,
    color: live.color,
    stateColor: dir.color,
    hasData: true,
    level: live.level,
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

/// The ONE status line (#65): live dot · state / no-data text · figures.
/// Self-ticking (300 ms) and self-contained: only this widget repaints as
/// the age text advances, and only when it changed; the dot's flash (#64) is
/// driven by the connection's events, not the timer.
class LiveStatusLine extends StatefulWidget {
  final BatteryConnection conn;

  /// The charge-direction style of the pack's state (shown only with data).
  final ChargeStateStyle dir;

  /// #34: a remembered favourite that is not connected — "Offline · last
  /// seen …", never a charge state.
  final bool offline;

  /// #53: the manager's sampling state, read on each tick and each event.
  final bool Function()? sampling;
  final int? Function()? nextDueMs;

  /// The trailing figures, built for "has data" (real values) or not ("—").
  final List<Widget> Function(bool hasData) trailing;
  final double dotSize;
  final double gap;
  final double? fontSize;

  const LiveStatusLine({
    super.key,
    required this.conn,
    required this.dir,
    required this.trailing,
    this.offline = false,
    this.sampling,
    this.nextDueMs,
    this.dotSize = 8,
    this.gap = 6,
    this.fontSize,
  });

  @override
  State<LiveStatusLine> createState() => _LiveStatusLineState();
}

class _LiveStatusLineState extends State<LiveStatusLine>
    with SingleTickerProviderStateMixin {
  Timer? _timer;
  StreamSubscription<BatteryEvent>? _events;
  StreamSubscription<ConnState>? _conn;
  final PulseTrigger _trigger = PulseTrigger();
  late StatusText _status = _compute();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: pulseDuration,
    value: 1.0, // at rest
  );

  StatusText _compute() {
    final now = widget.conn.now().millisecondsSinceEpoch;
    return statusTextFor(
      liveStatusOf(
        widget.conn,
        sampling: widget.sampling?.call() ?? false,
        nextDueMs: widget.nextDueMs?.call(),
        nowMs: now,
      ),
      widget.dir,
      offline: widget.offline,
      lastSeenMs: widget.conn.lastSeenMs,
      nowMs: now,
    );
  }

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
  void didUpdateWidget(LiveStatusLine old) {
    super.didUpdateWidget(old);
    if (old.conn != widget.conn) _subscribe();
    // The parent rebuilt (state / offline changed): recompute at once rather
    // than on the next tick.
    _status = _compute();
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
    final state = s.state;
    final detail = s.detail;
    return Row(
      children: [
        LiveDot(pulse: _pulse, color: s.color, size: widget.dotSize),
        SizedBox(width: widget.gap),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              if (state != null)
                TextSpan(text: state, style: TextStyle(color: s.stateColor)),
              if (state != null && detail != null)
                const TextSpan(
                    text: ' · ', style: TextStyle(color: Colors.white38)),
              if (detail != null)
                TextSpan(text: detail, style: TextStyle(color: s.color)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: widget.fontSize, fontWeight: s.weight),
          ),
        ),
        const SizedBox(width: 8),
        ...widget.trailing(s.hasData),
      ],
    );
  }
}
