#!/usr/bin/env python3
"""Replay raw BMS frames into the readings the AWTO BMS app would have stored.

A line-for-line Python port of the app's decode and logging rules, so frames
that reached a device but never reached its interval store (#112), or frames
from before the app existed (the Python tool's battery.db), can be turned into
the same `readings` rows the app writes. Ported from, and kept in step with:

  lib/battery_protocol.dart   BatteryParser + BatteryState (framing, resync,
                              scaling, truncating divisions, byte positions)
  lib/battery_connection.dart signedCurrent / signedPower, the session
                              throughput integrator behind `efc`
  lib/metrics.dart            which metrics are logged, in table order
  lib/battery_log.dart        IntervalRule (change / extend / gap), packFlags,
                              flagsComplete, integrateCurrentRows, foldLifetime
  lib/intervals.dart          abuts, sampleGapMs, GapPolicy

Things the raw log cannot carry and the port therefore cannot reproduce:
  * `rssi` comes from the BLE scan, not from a frame (not in the raw log).
  * `efc` is a per-connection-object running total that restarts with the
    app process; app restarts are not visible in the raw log.
  * The store's `end_ms` of an open row is flushed about once a minute; a row
    still open when the app was killed keeps an older end.

Temperatures follow the APP's byte mapping (battery_protocol.dart `_onTemp`):
temp0 = p0, temp1 = p1, temp3 = p2, temp2 = p3. The raw-log text "t2/t3" shows
state.temp2/state.temp3, i.e. p3/p2 (#114); this port decodes from the bytes.

Pure stdlib; no I/O. Unit-tested by scripts/test_clean_history.py.
"""
from __future__ import annotations

from dataclasses import dataclass, field

# --- intervals.dart ---------------------------------------------------------

GAP_MS = 10_000                      # BatteryLogger.gapMs
SAMPLE_GAP_MARGIN_MS = 60_000        # sampleGapMarginMs


def abuts(prev_end_ms: int, next_start_ms: int, gap_ms: int) -> bool:
    return next_start_ms - prev_end_ms <= gap_ms


def sample_gap_ms(interval_ms: int, base_gap_ms: int = GAP_MS,
                  margin_ms: int = SAMPLE_GAP_MARGIN_MS) -> int:
    return base_gap_ms if interval_ms <= 0 else interval_ms + margin_ms


class GapPolicy:
    """intervals.dart GapPolicy: the gap threshold in effect at each instant,
    from start-ordered `sampleIntervalS` rows [(start_ms, seconds), ...]."""

    def __init__(self, rows: list[tuple[int, float | None]] | None = None,
                 base_gap_ms: int = GAP_MS,
                 margin_ms: int = SAMPLE_GAP_MARGIN_MS):
        self.rows = rows or []
        self._starts = [r[0] for r in self.rows]
        self.base_gap_ms = base_gap_ms
        self.margin_ms = margin_ms

    def interval_at(self, ms: int) -> int:
        if not self.rows:
            return 0
        import bisect
        i = bisect.bisect_right(self._starts, ms) - 1
        if i < 0:
            return 0
        s = self.rows[i][1] or 0
        return 0 if s <= 0 else round(s * 1000)

    def gap_at(self, ms: int) -> int:
        return sample_gap_ms(self.interval_at(ms), self.base_gap_ms,
                             self.margin_ms)

    def gap_for(self, prev_end_ms: int, next_start_ms: int) -> int:
        return max(self.gap_at(prev_end_ms), self.gap_at(next_start_ms))

    def abuts(self, prev_end_ms: int, next_start_ms: int) -> bool:
        return next_start_ms - prev_end_ms <= self.gap_for(prev_end_ms,
                                                           next_start_ms)


# --- battery_log.dart: lifetime integration --------------------------------

@dataclass
class Row:
    """One interval row (the `readings` table shape, epoch ms)."""
    serial: str
    metric: str
    value_num: float | None
    value_text: str | None
    start_ms: int
    end_ms: int


def integrate_current_rows(rows: list[Row], watermark_ms: int = 0,
                           gap_ms: int = GAP_MS,
                           policy: GapPolicy | None = None
                           ) -> tuple[float, float, int]:
    """battery_log.dart integrateCurrentRows -> (charge_ah, discharge_ah,
    newest_end_ms). Each row is HELD until the next row's start, bounded by
    the gap threshold past its own end; the last row only to its own end.
    Only the part after `watermark_ms` counts."""
    charge = discharge = 0.0
    newest = watermark_ms
    for k, iv in enumerate(rows):
        if iv.end_ms > newest:
            newest = iv.end_ms
        i = iv.value_num
        if i is None:
            continue
        eff_start = iv.start_ms if iv.start_ms > watermark_ms else watermark_ms
        if k + 1 < len(rows):
            nxt = rows[k + 1].start_ms
            bound = iv.end_ms + (policy.gap_for(iv.end_ms, nxt)
                                 if policy is not None else gap_ms)
            hold_end = nxt if nxt < bound else bound
        else:
            hold_end = iv.end_ms
        dur_s = (hold_end - eff_start) / 1000.0
        if dur_s <= 0:
            continue
        ah = abs(i) * dur_s / 3600.0
        if i > 0:
            charge += ah
        elif i < 0:
            discharge += ah
    return charge, discharge, newest


# --- battery_protocol.dart -------------------------------------------------

def _u16le(b0: int, b1: int) -> int:
    return (b0 & 0xFF) | ((b1 & 0xFF) << 8)


def _u24le(b0: int, b1: int, b2: int) -> int:
    return (b0 & 0xFF) | ((b1 & 0xFF) << 8) | ((b2 & 0xFF) << 16)


def _s8(b: int) -> int:
    v = b & 0xFF
    return v - 256 if v > 127 else v


def _idiv(a: int, b: int) -> int:
    """Dart `~/` on non-negative ints (every use here is non-negative)."""
    return a // b


WARN_TEMP = {0: 'Chip over temperature protection',
             1: 'Chip under temperature protection',
             4: 'Under temperature discharge protection',
             5: 'Under temperature charge protection'}
WARN_CUR = {0: 'Over current discharge protection',
            1: 'Over current charge protection',
            2: 'Short circuit protection'}
WARN_VOL = {0: 'Single cell over charge protection',
            1: 'Single cell over discharge protection',
            3: 'Voltage difference alarm',
            6: 'Overall voltage over charge protection',
            7: 'Overall voltage over discharge protection'}

IDLE, CHARGING, DISCHARGING, UNKNOWN = 'idle', 'charging', 'discharging', 'unknown'


@dataclass
class BatteryState:
    pack_voltage: float | None = None
    pack_current: float | None = None      # magnitude
    power: float | None = None
    load_connected: bool | None = None
    charger_connected: bool | None = None
    chip_temperature: int | None = None
    cell_sum: float | None = None
    cell_max: float | None = None
    cell_min: float | None = None
    cell_diff: float | None = None
    cell_avg: float | None = None
    cycle_count: int | None = None
    cells_mv: list[int] = field(default_factory=list)
    temp0: int | None = None               # p0
    temp1: int | None = None               # p1
    temp2: int | None = None               # p3 (sic, app mapping)
    temp3: int | None = None               # p2 (sic, app mapping)
    soc_percent: int | None = None
    remaining_ah: float | None = None
    full_ah: float | None = None
    time_to_full_sec: int | None = None
    time_to_empty_sec: int | None = None
    mos_on: bool | None = None
    charge_state: str = UNKNOWN
    charge_mos: bool | None = None
    discharge_mos: bool | None = None
    passive_balancing: bool | None = None
    temp_control_gate: int | None = None
    smoke_gate: int | None = None
    heat_gate: int | None = None
    fault_current: bool = False
    fault_voltage: bool = False
    fault_temperature: bool = False
    over_temp_latched: bool = False
    temperature_alarm_seen: bool = False
    current_alarm_seen: bool = False
    voltage_alarm_seen: bool = False
    unknown_bytes: dict[str, int] = field(default_factory=dict)
    unrecognised_bytes: int = 0
    firmware_version: str | None = None
    sleep_mode_on: bool | None = None
    rssi: int | None = None


# Frame kinds (the app's event labels, as written to the raw log).
LABELS = {
    'vol': 'Cell voltages', 'temp': 'Temperatures', 'all': 'Battery data',
    'mos': 'MOS status', 'bal': 'Balancer status', 'soc': 'State of charge',
    'est': 'Time estimate', 'ver': 'Firmware version', 'sleep': 'Sleep',
    'setting': 'Setting ack', 'gate_set': 'Gate set', 'other': 'Other data',
    'warn_current': 'Current alarm', 'warn_voltage': 'Voltage alarm',
    'warn_temperature': 'Temperature alarm',
}
DECODED_LABELS = set(LABELS.values())


class Parser:
    """battery_protocol.dart BatteryParser: streaming framing with byte-level
    resync. `add_bytes` returns the frames decoded, as (kind, frame_bytes),
    and calls `on_event(kind, frame_bytes)` synchronously per frame (the
    Dart `onEvent`)."""

    AT_STATUS_BYTE = 0x30

    def __init__(self, state: BatteryState | None = None, on_event=None):
        self.state = state or BatteryState()
        self.on_event = on_event
        self.buf = bytearray()
        self.at_version_sent = False
        self.at_status_bytes = 0
        self._out: list[tuple[str, bytes]] = []
        s = self
        self._fixed = {
            (0xA1, 0x4F): (6, (0xB2, 0xE3), s._on_temp, 'temp'),
            (0xA2, 0x57): (24, (0xB3, 0x6C), s._on_all, 'all'),
            (0xA3, 0x9F): (8, (0xB4, 0xC7), s._on_mos, 'mos'),
            (0xA8, 0xAC): (9, (0xB9, 0x21), s._on_bal, 'bal'),
            (0xA9, 0x64): (9, (0xBA, 0x5E), s._on_soc, 'soc'),
            (0xAA, 0xAF): (8, (0xBB, 0x22), s._on_est, 'est'),
            (0xAC, 0x9A): (7, (0xBD, 0x10), s._on_ver, 'ver'),
            (0xA4, 0x8B): (7, (0xB5, 0xDD), s._on_warn_cur, 'warn_current'),
            (0xA5, 0x99): (11, (0xB6, 0x17), s._on_warn_vol, 'warn_voltage'),
            (0xA6, 0xC0): (9, (0xB7, 0x72), s._on_warn_temp,
                           'warn_temperature'),
            (0xAC, 0xCA): (3, (0xDE, 0xED), s._on_sleep, 'sleep'),
            (0xAB, 0xBA): (3, (0xCD, 0xDC), s._on_setting, 'setting'),
            (0xD2, 0x7E): (10, (0xFA, 0x4B), s._on_gate_set, 'gate_set'),
        }

    def reset(self) -> None:
        self.buf.clear()
        self.at_version_sent = False

    def add_bytes(self, data: bytes) -> list[tuple[str, bytes]]:
        self._out = []
        self.buf.extend(data)
        self._drain()
        return self._out

    def _emit(self, kind: str, frame: bytes) -> None:
        self._out.append((kind, frame))
        if self.on_event is not None:
            self.on_event(kind, frame)

    def _drain(self) -> None:
        buf = self.buf
        while len(buf) >= 2:
            consumed = self._try_frame_at0()
            if consumed == 0:
                return
            if consumed < 0:
                dropped = buf[0]
                if dropped == self.AT_STATUS_BYTE and self.at_version_sent:
                    self.at_status_bytes += 1
                else:
                    self.state.unrecognised_bytes += 1
                del buf[0]
                continue
            del buf[0:consumed]
        if (len(buf) == 1 and buf[0] == self.AT_STATUS_BYTE
                and self.at_version_sent):
            self.at_status_bytes += 1
            buf.clear()

    def _match(self, at: int, sentinel) -> bool:
        if at + len(sentinel) > len(self.buf):
            return False
        return all(self.buf[at + i] == b for i, b in enumerate(sentinel))

    def _try_frame_at0(self) -> int:
        begin = (self.buf[0], self.buf[1])
        fixed = self._fixed.get(begin)
        if fixed is not None:
            plen, end, handler, kind = fixed
            total = 2 + plen
            if len(self.buf) < total:
                return 0
            if not self._match(2 + plen - 2, end):
                return -1
            frame = bytes(self.buf[0:total])
            handler(frame[2:2 + plen])
            self._emit(kind, frame)
            return total
        if begin == (0xA0, 0xC1):
            return self._parse_vol()
        if begin == (0xA7, 0x4E):
            total = 11
            if len(self.buf) < total:
                return 0
            frame = bytes(self.buf[0:total])
            for i in range(9):
                self.state.unknown_bytes[f'unknownOtherB{i}'] = frame[2 + i]
            self._emit('other', frame)
            return total
        if begin in ((0xFE, 0xC9), (0xBD, 0x8A)):
            idx = self.buf.find(bytes([0xEA, 0x4F, 0x80, 0xDE]), 2)
            if idx < 0:
                return -1 if len(self.buf) > 1024 else 0
            return idx + 4                      # recognised, never an event
        return -1

    def _parse_vol(self) -> int:
        if len(self.buf) < 3:
            return 0
        count = self.buf[2]
        total = 2 + 1 + count * 2 + 2
        if len(self.buf) < total:
            return 0
        if not self._match(2 + 1 + count * 2, (0xB1, 0xD2)):
            return -1
        frame = bytes(self.buf[0:total])
        self.state.cells_mv = [_u16le(frame[3 + i * 2], frame[4 + i * 2])
                               for i in range(count)]
        self._emit('vol', frame)
        return total

    def _on_temp(self, p: bytes) -> None:
        s = self.state
        s.temp0 = _s8(p[0])
        s.temp1 = _s8(p[1])
        s.temp3 = _s8(p[2])
        s.temp2 = _s8(p[3])

    def _on_all(self, p: bytes) -> None:
        s = self.state
        s.pack_voltage = _u16le(p[0], p[1]) / 10.0
        s.pack_current = _idiv(_u24le(p[2], p[3], p[4]), 100) / 10.0
        s.load_connected = p[5] != 0
        s.charger_connected = p[6] != 0
        s.chip_temperature = p[7] & 0xFF
        s.cell_sum = _u16le(p[8], p[9]) / 10.0
        s.cell_max = _idiv(_u16le(p[10], p[11]), 10) / 100.0
        s.cell_min = _idiv(_u16le(p[12], p[13]), 10) / 100.0
        s.cell_diff = _idiv(_u16le(p[14], p[15]), 10) / 100.0
        s.power = _u16le(p[16], p[17]) / 10.0
        s.cycle_count = _u16le(p[18], p[19])
        s.cell_avg = _idiv(_u16le(p[20], p[21]), 10) / 100.0

    def _on_mos(self, p: bytes) -> None:
        s = self.state
        s.mos_on = p[0] == 1 and p[1] == 1
        for i in (2, 3, 4, 5):
            s.unknown_bytes[f'unknownMosB{i}'] = p[i]

    def _on_bal(self, p: bytes) -> None:
        s = self.state
        s.charge_state = {0: IDLE, 1: CHARGING, 2: DISCHARGING}.get(p[0],
                                                                    UNKNOWN)
        s.charge_mos = p[1] == 1
        s.discharge_mos = p[2] == 1
        s.passive_balancing = p[3] == 1
        s.temp_control_gate = p[4]
        s.smoke_gate = p[5]
        s.heat_gate = p[6]

    def _on_soc(self, p: bytes) -> None:
        s = self.state
        s.soc_percent = min(p[0], 100)
        s.remaining_ah = _u24le(p[4], p[5], p[6]) / 1000.0
        s.full_ah = _u24le(p[1], p[2], p[3]) / 1000.0

    def _on_est(self, p: bytes) -> None:
        self.state.time_to_full_sec = _u24le(p[0], p[1], p[2])
        self.state.time_to_empty_sec = _u24le(p[3], p[4], p[5])

    def _on_ver(self, p: bytes) -> None:
        # Dart String.fromCharCodes: one UTF-16 unit per byte (Latin-1).
        self.state.firmware_version = bytes(p[0:5]).decode('latin-1')

    def _on_sleep(self, p: bytes) -> None:
        self.state.sleep_mode_on = p[0] == 0

    def _on_setting(self, p: bytes) -> None:
        pass

    def _on_gate_set(self, p: bytes) -> None:
        pass

    @staticmethod
    def _collect(p: bytes, table: dict[int, str]) -> list[str]:
        return [t for i, t in table.items() if i < len(p) and p[i] == 1]

    def _on_warn_cur(self, p: bytes) -> None:
        s = self.state
        s.fault_current = bool(self._collect(p, WARN_CUR))
        s.current_alarm_seen = True
        s.unknown_bytes['unknownCurB3'] = p[3]
        s.unknown_bytes['unknownCurB4'] = p[4]

    def _on_warn_vol(self, p: bytes) -> None:
        s = self.state
        s.fault_voltage = bool(self._collect(p, WARN_VOL))
        s.voltage_alarm_seen = True
        for i in (2, 4, 5, 8):
            s.unknown_bytes[f'unknownVolB{i}'] = p[i]

    def _on_warn_temp(self, p: bytes) -> None:
        s = self.state
        s.fault_temperature = bool(self._collect(p, WARN_TEMP))
        s.over_temp_latched = p[2] == 1
        s.temperature_alarm_seen = True
        s.unknown_bytes['unknownTempB3'] = p[3]
        s.unknown_bytes['unknownTempB6'] = p[6]


# --- battery_log.dart: flags ------------------------------------------------

def flags_complete(s: BatteryState) -> bool:
    return (s.mos_on is not None and s.load_connected is not None
            and s.charger_connected is not None and s.charge_mos is not None
            and s.discharge_mos is not None
            and s.passive_balancing is not None
            and s.charge_state != UNKNOWN and s.current_alarm_seen
            and s.voltage_alarm_seen and s.temperature_alarm_seen)


def pack_flags(s: BatteryState) -> int | None:
    if not flags_complete(s):
        return None
    f = 0
    if s.mos_on:
        f |= 1 << 0
    if s.load_connected:
        f |= 1 << 1
    if s.charger_connected:
        f |= 1 << 2
    if s.charge_mos:
        f |= 1 << 3
    if s.discharge_mos:
        f |= 1 << 4
    if s.passive_balancing:
        f |= 1 << 5
    if s.sleep_mode_on is True:
        f |= 1 << 6
    if s.fault_current:
        f |= 1 << 7
    if s.fault_voltage:
        f |= 1 << 8
    if s.fault_temperature:
        f |= 1 << 9
    cs = {CHARGING: 1, DISCHARGING: 2}.get(s.charge_state, 0)
    return f | ((cs & 0x3) << 10)


def signed_current(s: BatteryState) -> float:
    i = s.pack_current if s.pack_current is not None else 0.0
    return {CHARGING: i, DISCHARGING: -i}.get(s.charge_state, 0.0)


def signed_power(s: BatteryState) -> float:
    p = s.power if s.power is not None else 0.0
    return {CHARGING: p, DISCHARGING: -p}.get(s.charge_state, 0.0)


# The metrics.dart table, in table order: (key, extractor). An extractor
# returns the number to log (None = nothing this event). `firmware` is the
# one text metric.
def _efc(sess: 'Session'):
    full = sess.state.full_ah
    if full is None or full <= 0:
        return None
    return sess.cumulative_throughput_ah / full


LOGGED_METRICS = [
    ('soc', lambda x: x.state.soc_percent),
    ('packV', lambda x: x.state.pack_voltage),
    ('packI', lambda x: signed_current(x.state)),
    ('power', lambda x: signed_power(x.state)),
    ('cycles', lambda x: x.state.cycle_count),
    ('efc', _efc),
    ('remAh', lambda x: x.state.remaining_ah),
    ('fullAh', lambda x: x.state.full_ah),
    ('timeToFullSec', lambda x: x.state.time_to_full_sec),
    ('timeToEmptySec', lambda x: x.state.time_to_empty_sec),
    ('cellSum', lambda x: x.state.cell_sum),
    ('cellAvg', lambda x: x.state.cell_avg),
    ('cellMax', lambda x: x.state.cell_max),
    ('cellMin', lambda x: x.state.cell_min),
    ('cellDelta', lambda x: x.state.cell_diff),
    ('temp1', lambda x: x.state.temp1),
    ('temp2', lambda x: x.state.temp2),
    ('temp0', lambda x: x.state.temp0),
    ('temp3', lambda x: x.state.temp3),
    ('chip', lambda x: x.state.chip_temperature),
    ('tempGate', lambda x: x.state.temp_control_gate),
    ('smokeGate', lambda x: x.state.smoke_gate),
    ('heatGate', lambda x: x.state.heat_gate),
    ('overTempLatched', lambda x: (1 if x.state.over_temp_latched else 0)
     if x.state.temperature_alarm_seen else None),
    ('firmware', None),                       # text: state.firmware_version
    ('rssi', lambda x: x.state.rssi),
]

# Metrics the raw log cannot reproduce (see the module note).
SESSION_ONLY_METRICS = {'rssi', 'efc'}


@dataclass
class Session:
    """What one BatteryConnection holds for a pack: its decoded state and the
    session throughput integrator (battery_connection.dart)."""
    serial: str
    state: BatteryState = field(default_factory=BatteryState)
    cumulative_throughput_ah: float = 0.0
    last_efc_ms: int | None = None
    max_integrate_gap_ms: int = GAP_MS

    def __post_init__(self):
        self.parser = Parser(self.state, on_event=None)

    def integrate(self, now_ms: int) -> None:
        last = self.last_efc_ms
        self.last_efc_ms = now_ms
        if last is None:
            return
        dt = now_ms - last
        if dt <= 0 or dt > self.max_integrate_gap_ms:
            return
        self.cumulative_throughput_ah += abs(signed_current(self.state)) * (
            dt / 3_600_000.0)


class IntervalLogger:
    """BatteryLogger's change / extend / gap fold, without SQLite. Rows are
    appended to `rows` when closed; call `close_all()` at the end."""

    def __init__(self, epsilon: float = 1e-9):
        self.epsilon = epsilon
        self.sample_interval_ms = 0
        self._open: dict[tuple[str, str], list] = {}
        self.rows: list[Row] = []

    @property
    def gap_ms(self) -> int:
        return sample_gap_ms(self.sample_interval_ms)

    def _same(self, a_num, a_text, b_num, b_text) -> bool:
        if a_text is not None or b_text is not None:
            return a_text == b_text
        if a_num is None or b_num is None:
            return a_num == b_num
        return abs(a_num - b_num) <= self.epsilon

    def observe_value(self, serial: str, metric: str, now: int,
                      value_num: float | None = None,
                      value_text: str | None = None) -> None:
        key = (serial, metric)
        o = self._open.get(key)
        if (o is not None and self._same(o[0], o[1], value_num, value_text)
                and abuts(o[3], now, self.gap_ms)):
            o[3] = now
            return
        if o is not None:
            self._close(key)
        self._open[key] = [value_num, value_text, now, now]

    def _close(self, key) -> None:
        o = self._open.pop(key)
        self.rows.append(Row(key[0], key[1], o[0], o[1], o[2], o[3]))

    def observe(self, sess: Session, now: int) -> None:
        """battery_log.dart `_onEvent`: every logged metric of the pack's
        current state, in table order."""
        serial = sess.serial
        s = sess.state
        for i, mv in enumerate(s.cells_mv):
            self.observe_value(serial, f'cell{i + 1}', now, mv / 1000.0)
        for key, extract in LOGGED_METRICS:
            if extract is None:
                if s.firmware_version:
                    self.observe_value(serial, key, now,
                                       value_text=s.firmware_version)
                continue
            v = extract(sess)
            if v is not None:
                self.observe_value(serial, key, now, float(v))
        for name, value in s.unknown_bytes.items():
            self.observe_value(serial, name, now, float(value))
        flags = pack_flags(s)
        if flags is not None:
            self.observe_value(serial, 'flags', now, float(flags))
        self.observe_value(serial, 'sampleMode', now,
                           1.0 if self.sample_interval_ms > 0 else 0.0)
        self.observe_value(serial, 'sampleIntervalS', now,
                           float(self.sample_interval_ms // 1000))

    def disconnect(self, serial: str) -> None:
        """`_onDisconnect`: finalize every open row of the pack."""
        for key in [k for k in self._open if k[0] == serial]:
            self._close(key)

    def close_all(self) -> None:
        for key in list(self._open):
            self._close(key)
