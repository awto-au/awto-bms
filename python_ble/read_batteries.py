#!/usr/bin/env python3
"""Read JoySuny batteries (Sphere / RV) over BLE. One script for one or many.

It scans for every JS*/RV* battery in range, connects to all of them at once
(concurrently, on one asyncio loop — the reliable way to do multi-device BLE in
Python), decodes every telemetry frame, and writes each battery's decoded stream
to its OWN log file: logs/<serial>.log. The console shows a live combined table.

Every decoded data point is also logged to a local SQLite database
(logs/battery.db) — lightweight, serverless, one file, no install. Disable with
--no-db or point elsewhere with --sqlite PATH.

Read-only: each link sends only the stream-start handshake (CMD_BEGIN,
CMD_GET_EST, AT+V). It never sends a gate / MOS / factory command.

Protocol: ../PROTOCOL.md
Usage:  python read_batteries.py
        python read_batteries.py --seconds 60
        python read_batteries.py --name JS-2C14AA      # just this one
        python read_batteries.py --no-db               # no database
"""

import argparse
import asyncio
import json
import os
import queue
import sqlite3
import sys
import threading
import time
from datetime import datetime

from bleak import BleakClient, BleakScanner

# --- BLE UUIDs -------------------------------------------------------------
SERVICE = "0000fcf0-0000-1000-8000-00805f9b34fb"
WRITE_CHAR = "0000fcf1-0000-1000-8000-00805f9b34fb"
NOTIFY_CHAR = "0000fcf2-0000-1000-8000-00805f9b34fb"

# --- TX handshake (read-only) ---------------------------------------------
CMD_BEGIN = bytes([0xFB, 0xC8, 0x7C, 0x9D, 0x26, 0xEC])
CMD_GET_EST = bytes([0xC4, 0x7D, 0xF4, 0xD5, 0x86])
CMD_GET_VERSION = bytes([0x41, 0x54, 0x2B, 0x56, 0x0D, 0x0A])  # "AT+V\r\n"
# Read request for the stored history log. Safe (read-only); distinct from
# CMD_CLEAR_HISTORY (C7 46 D8 82), which erases it and is never sent here.
CMD_GET_HISTORY = bytes([0xC6, 0x7C, 0xCF, 0x00, 0xD7, 0x52])

LOG_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")


# --- little-endian helpers (match ByteUtils.java) --------------------------
def u16(b0, b1):
    return (b0 & 0xFF) | ((b1 & 0xFF) << 8)


def u24(b0, b1, b2):
    return (b0 & 0xFF) | ((b1 & 0xFF) << 8) | ((b2 & 0xFF) << 16)


def s8(b):
    v = b & 0xFF
    return v - 256 if v > 127 else v


def hexs(data):
    return " ".join(f"{x:02x}" for x in data)


def hms(sec):
    h, r = divmod(int(sec), 3600)
    m, s = divmod(r, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


# NOTE (verified against decompiled BatteryManager.java, all three builds):
# the temperature alarm is a set of BOOLEAN flag bytes — there is NO numeric MOS
# temperature and NO MOS-temp threshold setting anywhere in the protocol
# (CMD_SETTING_TEMP is a dead constant; only capacity/type-4 is ever read/written).
# Bytes [2], [3] and [6] are three SEPARATE firmware flags the app cannot tell
# apart: it ORs [2]|[3] into one string and gives [6] a near-duplicate string.
# So "MOS temperature" here is an opaque boolean, not a reading. Which physical
# condition each of [2]/[3]/[6] is (charge vs discharge FET, warn vs protect)
# is undeterminable from the app and needs a live thermal test to resolve.
WARN_TEMP = {
    0: "Chip over temperature protection",
    1: "Chip under temperature protection",
    2: "MOS over temperature protection (warn_mos_over_temputer)",
    3: "MOS over temperature protection (warn_mos_over_temputer)",
    4: "Under temperature discharge protection",
    5: "Under temperature charge protection",
    6: "MOS over temperature protection (warn_mos_protect)",
}
WARN_CUR = {
    0: "Over current discharge protection",
    1: "Over current charge protection",
    2: "Short circuit protection",
}
WARN_VOLTAGE = {
    0: "Single cell over charge protection",
    1: "Single cell over discharge protection",
    3: "Voltage difference alarm",
    6: "Overall voltage over charge protection",
    7: "Overall voltage over discharge protection",
}


# Packed discrete-state bitfield. All the boolean states and the small
# chargeState enum live in ONE integer "flags" metric, LSB-first, each field at
# the running bit offset below. Rationale: these states rarely change, and when
# they do they tend to move together (connect, charge<->discharge, a fault
# tripping), so one packed row per change is smaller and collapses correlated
# flips that N separate metrics would each record. Unpack at read time with the
# same layout. NOTE: a 0 bit means "off", NOT "unknown" — a flags row is only
# written once at least one contributing state has been decoded.
#   field name -> (state key, bit width)
FLAG_LAYOUT = [
    ("mos", "mos", 1),
    ("load", "load", 1),
    ("charger", "charger", 1),
    ("chgMos", "chg_mos", 1),
    ("disMos", "dis_mos", 1),
    ("passiveBal", "passive_bal", 1),
    ("sleep", "sleep", 1),
    ("faultCurrent", "fault_current", 1),
    ("faultVoltage", "fault_voltage", 1),
    ("faultTemperature", "fault_temperature", 1),
    ("chargeState", "charge_state", 2),   # 0 idle / 1 charging / 2 discharging
]
CHARGE_STATE_CODE = {"idle": 0, "charging": 1, "discharging": 2}
# The streaming states that must ALL be decoded before a `flags` row is written,
# so an emitted 0 bit always means "off", never "not yet known". `sleep` is not
# required: a device that is streaming telemetry is by definition awake, so it
# defaults to off and is only set on by an explicit sleep frame. Genuinely
# unknown periods are the disconnect gaps between rows, not a bit value.
REQUIRED_FLAG_KEYS = ("mos", "load", "charger", "chg_mos", "dis_mos",
                      "passive_bal", "charge_state",
                      "fault_current", "fault_voltage", "fault_temperature")


def pack_flags(s):
    """Pack the discrete states in `s` into one integer per FLAG_LAYOUT, or None
    until every streaming state is known (so no bit is a false 0)."""
    if not all(k in s and s[k] is not None for k in REQUIRED_FLAG_KEYS):
        return None
    val = 0
    shift = 0
    for _name, key, width in FLAG_LAYOUT:
        raw = s.get(key)
        if key == "charge_state":
            raw = CHARGE_STATE_CODE.get(raw, 0)
        elif raw is None:
            raw = 0                       # sleep never observed -> awake
        elif isinstance(raw, bool):
            raw = 1 if raw else 0
        val |= (int(raw) & ((1 << width) - 1)) << shift
        shift += width
    return val


def unpack_flags(val):
    """Inverse of pack_flags: integer -> {field: value} (for readers/queries)."""
    out = {}
    shift = 0
    for name, _key, width in FLAG_LAYOUT:
        out[name] = (val >> shift) & ((1 << width) - 1)
        shift += width
    return out


def metrics_from_state(s):
    """Flatten a decoded battery state into {metric: (value_num, value_text)}.
    Continuous telemetry is one metric each (for graphing); the discrete
    boolean/enum states are packed into a single `flags` integer. Nothing is
    dropped — "dont skimp" — the states are just packed, not omitted."""
    m = {}

    def num(name, key, scale=1.0):
        v = s.get(key)
        if v is not None:
            m[name] = (float(v) * scale, None)

    cells = s.get("cells")
    if cells:
        for i, mv in enumerate(cells):
            m[f"cell{i + 1}"] = (mv / 1000.0, None)  # volts
    num("packVoltage", "volt"); num("packCurrent", "cur"); num("power", "power")
    num("cellSum", "sum"); num("cellMax", "max"); num("cellMin", "min")
    num("cellDiff", "diff"); num("cellAvg", "avg"); num("cycles", "cycles")
    num("chipTemp", "chip"); num("temp1", "t1"); num("temp2", "t2")
    num("soc", "soc"); num("remainingAh", "rem"); num("fullAh", "full")
    num("rssi", "rssi")
    # tempGate/smokeGate/heatGate are byte-valued (not single bits), so they
    # stay as their own numeric metrics.
    num("tempGate", "temp_gate"); num("smokeGate", "smoke_gate")
    num("heatGate", "heat_gate")
    packed = pack_flags(s)
    if packed is not None:
        m["flags"] = (float(packed), None)
    if "fw" in s:
        m["firmware"] = (None, s["fw"])
    return m


def _fmt_time(dt):
    """Full local date-and-time with millisecond precision, matching the text
    log (e.g. 2026-09-19 14:23:01.123)."""
    return dt.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


class IntervalStore:
    """Durable interval logger. One append-only row per run of a value:
    readings(serial, metric, value_num/text, start_time, end_time). A value
    holds from start_time to end_time (full date-and-time); a gap between
    consecutive rows is a known-offline window. Change-only (a new row on change
    or after a gap); an unchanged value's end_time is advanced at most once a
    minute. Nothing is ever deleted or downsampled. Work runs on a background
    thread. The packed `flags` metric is also exposed, one bit per column, via
    the flags_bits view so per-state queries stay plain WHEREs."""

    GAP_SECONDS = 10     # a gap larger than this ends the interval (offline)
    FLUSH_SECONDS = 60   # advance an unchanged interval's end_time at most this often
    DDL = (
        "CREATE TABLE IF NOT EXISTS readings ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " serial TEXT NOT NULL, metric TEXT NOT NULL,"
        " value_num REAL, value_text TEXT,"
        " start_time TEXT NOT NULL, end_time TEXT NOT NULL)"
    )
    INDEX = ("CREATE INDEX IF NOT EXISTS ix_readings "
             "ON readings (serial, metric, start_time)")

    @staticmethod
    def _view_sql():
        cols, shift = [], 0
        for name, _key, width in FLAG_LAYOUT:
            mask = (1 << width) - 1
            cols.append(f"(CAST(value_num AS INTEGER) >> {shift}) & {mask} AS {name}")
            shift += width
        return ("CREATE VIEW IF NOT EXISTS flags_bits AS SELECT"
                " serial, start_time, end_time, " + ", ".join(cols) +
                " FROM readings WHERE metric = 'flags'")

    def __init__(self, path):
        self.path = path
        self.q = queue.Queue()
        self._stop = False
        self._open = {}   # (serial, metric) -> {num, text, start, end, rowid, flushed}
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        print(f"[db] interval logging to sqlite {path} "
              f"(table readings; change-only, no deletion)")

    def observe_state(self, serial, state, now):
        for metric, (num, text) in metrics_from_state(state).items():
            if num is None and text is None:
                continue
            self.q.put(("obs", serial, metric, num, text, now))

    def flush(self, serial, now):
        self.q.put(("flush", serial, now))

    @staticmethod
    def _same(o, num, text):
        if o["text"] != text:
            return False
        a, b = o["num"], num
        if a is None or b is None:
            return a is b
        return abs(a - b) < 1e-9

    def _run(self):
        conn = sqlite3.connect(self.path)
        conn.execute(self.DDL)
        conn.execute(self.INDEX)
        conn.execute(self._view_sql())
        conn.commit()
        while not self._stop or not self.q.empty():
            try:
                item = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                self._handle(conn, item)
            except Exception as e:  # noqa: BLE001
                print(f"[db] error: {e}")
        for o in self._open.values():           # final flush
            conn.execute("UPDATE readings SET end_time=? WHERE id=?",
                         (_fmt_time(o["end"]), o["rowid"]))
        conn.commit()
        conn.close()

    def _handle(self, conn, item):
        if item[0] == "obs":
            _, serial, metric, num, text, now = item
            key = (serial, metric)
            o = self._open.get(key)
            gap = o is not None and (now - o["end"]).total_seconds() > self.GAP_SECONDS
            if o is None or gap or not self._same(o, num, text):
                if o is not None:                # finalize the previous run
                    conn.execute("UPDATE readings SET end_time=? WHERE id=?",
                                 (_fmt_time(o["end"]), o["rowid"]))
                ts = _fmt_time(now)
                cur = conn.execute(
                    "INSERT INTO readings"
                    " (serial, metric, value_num, value_text, start_time, end_time)"
                    " VALUES (?,?,?,?,?,?)", (serial, metric, num, text, ts, ts))
                conn.commit()
                self._open[key] = {"num": num, "text": text, "start": now,
                                   "end": now, "rowid": cur.lastrowid, "flushed": now}
            else:                                # same value, contiguous: extend
                o["end"] = now
                if (now - o["flushed"]).total_seconds() >= self.FLUSH_SECONDS:
                    conn.execute("UPDATE readings SET end_time=? WHERE id=?",
                                 (_fmt_time(now), o["rowid"]))
                    conn.commit()
                    o["flushed"] = now
        elif item[0] == "flush":                 # e.g. on disconnect
            _, serial, now = item
            for key, o in self._open.items():
                if key[0] == serial:
                    conn.execute("UPDATE readings SET end_time=? WHERE id=?",
                                 (_fmt_time(o["end"]), o["rowid"]))
                    o["flushed"] = o["end"]
            conn.commit()

    def close(self):
        self._stop = True
        self.thread.join(timeout=8)


class Parser:
    """Streaming frame parser with byte-level resync. Writes each decoded frame
    to this battery's own log file (and optionally echoes to the console)."""

    # Every RX frame in PROTOCOL.md / BatteryCMD.java: begin -> (payload_len
    # incl. end, end sentinel, handler). Fixed-length frames.
    FIXED = {
        (0xA1, 0x4F): (6, (0xB2, 0xE3), "temp"),        # CMD_TEMPUTER
        (0xA2, 0x57): (24, (0xB3, 0x6C), "all"),        # CMD_ALL_DATA
        (0xA3, 0x9F): (8, (0xB4, 0xC7), "mos"),         # CMD_MOS_STATUS
        (0xA8, 0xAC): (9, (0xB9, 0x21), "bal"),         # CMD_BAL_STATUS
        (0xA9, 0x64): (9, (0xBA, 0x5E), "soc"),         # CMD_SOC
        (0xAA, 0xAF): (8, (0xBB, 0x22), "est"),         # CMD_EST_TIME
        (0xAC, 0x9A): (7, (0xBD, 0x10), "ver"),         # CMD_VERSION
        (0xAC, 0xCA): (3, (0xDE, 0xED), "sleep"),       # CMD_SLEEP_SET_SUCCESS
        (0xA4, 0x8B): (7, (0xB5, 0xDD), "warn_cur"),    # CMD_WARN_CUR_ALARM
        (0xA5, 0x99): (11, (0xB6, 0x17), "warn_voltage"),  # CMD_WARN_VOL_ALARM
        (0xA6, 0xC0): (9, (0xB7, 0x72), "warn_temp"),   # CMD_WARN_TEMP_ALARM
        (0xAB, 0xBA): (3, (0xCD, 0xDC), "setting"),     # CMD_SETTING_RESPOND
        (0xD2, 0x7E): (10, (0xFA, 0x4B), "gate_set"),   # CMD_GATE_SET (gate ack)
    }
    # CMD_OTHER (A7 4E): 9-byte blob, no end sentinel.
    OTHER = (0xA7, 0x4E)
    # CMD_HISTORY: two possible begins, a 4-byte end. Variable length.
    HISTORY_BEGINS = {(0xFE, 0xC9), (0xBD, 0x8A)}
    HISTORY_END = bytes([0xEA, 0x4F, 0x80, 0xDE])
    # SETTING_RESPOND type byte -> what was set.
    SETTING_TYPE = {1: "voltage", 2: "current", 3: "temperature", 4: "capacity"}
    # CMD_GATE_SET payload bytes 0..7 -> gate names (see CMD_GATE_CONTROL).
    GATES = ["chgMos", "disMos", "tempGate", "smokeGate",
             "heatGate", "restart", "passiveBal", "factory"]

    def __init__(self, serial, logfile, echo=False, db=None):
        self.buf = bytearray()
        self.state = {}
        self.serial = serial
        self.log = logfile
        self.echo = echo
        self.db = db  # optional SqliteWriter
        self._skipped = bytearray()  # bytes dropped during resync
        self._raw = b""              # raw bytes of the frame currently being logged

    def add(self, data):
        self.buf.extend(data)
        self._drain()

    def _drain(self):
        while len(self.buf) >= 2:
            n = self._try()
            if n == 0:
                return  # need more bytes for a possible known frame
            if n < 0:
                # Unknown begin, or a known frame whose end sentinel failed.
                # Drop one byte and resync, remembering what we skipped.
                self._skipped.append(self.buf[0])
                del self.buf[0]
                continue
            # Good frame. Surface any bytes we had to skip to reach it. Every
            # frame in the spec is decoded above, so this is genuinely
            # unrecognised data (a stray byte or an undocumented frame).
            if self._skipped:
                self._raw = bytes(self._skipped)
                self.emit("UNRECOGNISED", "resync — dropped to next known frame")
                self.state["unrecognised_bytes"] = (
                    self.state.get("unrecognised_bytes", 0) + len(self._skipped)
                )
                self._skipped = bytearray()
            del self.buf[0:n]

    def _match(self, at, end):
        return self.buf[at] == end[0] and self.buf[at + 1] == end[1]

    def _try(self):
        key = (self.buf[0], self.buf[1])
        if key == (0xA0, 0xC1):                       # CMD_VOL (count-prefixed)
            return self._cell_voltages()
        if key in self.FIXED:
            plen, end, handler = self.FIXED[key]
            total = 2 + plen
            if len(self.buf) < total:
                return 0
            if not self._match(2 + plen - 2, end):
                return -1
            self._raw = bytes(self.buf[0:total])      # full frame for the log
            getattr(self, "_" + handler)(self.buf[2:2 + plen])
            return total
        if key == self.OTHER:                          # CMD_OTHER (9-byte blob)
            total = 2 + 9
            if len(self.buf) < total:
                return 0
            self._raw = bytes(self.buf[0:total])
            self.emit("RX_OTHER_DATA", "9 bytes read and discarded by the app")
            return total
        if key in self.HISTORY_BEGINS:                 # CMD_HISTORY (variable)
            return self._history()
        return -1

    def _history(self):
        idx = self.buf.find(self.HISTORY_END, 2)
        if idx == -1:
            return -1 if len(self.buf) > 1024 else 0   # give up / wait
        total = idx + len(self.HISTORY_END)
        self._raw = bytes(self.buf[0:total])
        self.emit("RX_HISTORY", "history frame (not decoded)")
        return total

    def emit(self, tag, msg):
        """Log one event. `self._raw` (if set) is the exact bytes on the wire,
        so the log shows raw -> decode and every line is traceable."""
        now = datetime.now()
        hx = hexs(self._raw) if self._raw else ""
        self._raw = b""                                # consume
        body = f"{hx}   {msg}" if hx else msg
        line = f"{now:%Y-%m-%d %H:%M:%S.%f}"[:-3] + f"  {tag:22} {body}"
        self.log.write(line + "\n")
        self.log.flush()
        if self.echo:
            print(f"{self.serial}  {line}")
        if self.db is not None:
            # Observe the whole current state as interval readings (change-only,
            # never deleted). TX_/UNRECOGNISED lines carry no new telemetry, so
            # only observe on decoded RX frames.
            if tag.startswith("RX_"):
                self.db.observe_state(self.serial, self.state, now)

    def log_tx(self, tag, raw):
        """Log a command we sent (TX_*), with its raw bytes."""
        self._raw = bytes(raw)
        self.emit(tag, "sent")

    def _cell_voltages(self):
        if len(self.buf) < 3:
            return 0
        count = self.buf[2]
        total = 2 + 1 + count * 2 + 2
        if len(self.buf) < total:
            return 0
        if not self._match(3 + count * 2, (0xB1, 0xD2)):
            return -1
        cells = [u16(self.buf[3 + i * 2], self.buf[4 + i * 2]) for i in range(count)]
        self.state["cells"] = cells
        self._raw = bytes(self.buf[0:total])
        self.emit("RX_CELL_VOLTAGES", " ".join(f"{c/1000:.3f}V" for c in cells))
        return total

    def _temp(self, p):
        self.state["t1"], self.state["t2"] = s8(p[1]), s8(p[3])
        self.emit("RX_TEMPERATURE",
                  f"t1=[1]={self.state['t1']}C  t2=[3]={self.state['t2']}C")

    def _all(self, p):
        st = self.state
        st["volt"] = u16(p[0], p[1]) / 10.0
        st["cur"] = (u24(p[2], p[3], p[4]) // 100) / 10.0
        st["load"] = p[5] != 0
        st["charger"] = p[6] != 0
        st["chip"] = p[7]
        st["sum"] = u16(p[8], p[9]) / 10.0
        st["max"] = (u16(p[10], p[11]) // 10) / 100.0
        st["min"] = (u16(p[12], p[13]) // 10) / 100.0
        st["diff"] = (u16(p[14], p[15]) // 10) / 100.0
        st["power"] = u16(p[16], p[17]) / 10.0
        st["cycles"] = u16(p[18], p[19])
        st["avg"] = (u16(p[20], p[21]) // 10) / 100.0
        self.emit(
            "RX_BATTERY_DATA",
            f"{st['volt']:.1f}V {st['cur']:.1f}A {st['power']:.0f}W "
            f"max={st['max']:.3f} min={st['min']:.3f} avg={st['avg']:.3f} "
            f"chip={st['chip']}C cyc={st['cycles']} "
            f"load={st['load']} chg={st['charger']}",
        )

    def _mos(self, p):
        self.state["mos"] = p[0] == 1 and p[1] == 1
        self.emit("RX_OUTPUT_MOS",
                  f"on={self.state['mos']} ([0]={p[0]} [1]={p[1]})")

    def _bal(self, p):
        cs = {0: "idle", 1: "charging", 2: "discharging"}.get(p[0], "?")
        self.state["charge_state"] = cs
        self.state["chg_mos"] = p[1] == 1
        self.state["dis_mos"] = p[2] == 1
        self.state["passive_bal"] = p[3] == 1
        self.state["temp_gate"] = p[4]
        self.state["smoke_gate"] = p[5]
        self.state["heat_gate"] = p[6]
        self.emit(
            "RX_BALANCER_STATUS",
            f"state=[0]={cs} chgMos=[1]={p[1]==1} disMos=[2]={p[2]==1} "
            f"passiveBal=[3]={p[3]==1} tempGate=[4]={p[4]} "
            f"smokeGate=[5]={p[5]} heatGate=[6]={p[6]}",
        )

    def _soc(self, p):
        soc = min(100, max(0, p[0]))
        full = u24(p[1], p[2], p[3]) / 1000.0
        rem = u24(p[4], p[5], p[6]) / 1000.0
        self.state.update(soc=soc, full=full, rem=rem)
        self.emit("RX_STATE_OF_CHARGE",
                  f"{soc}% ([0])  remaining=[4:6]={rem:.1f}Ah  full=[1:3]={full:.1f}Ah")

    def _est(self, p):
        self.emit(
            "RX_TIME_ESTIMATE",
            f"[0:2]={hms(u24(p[0],p[1],p[2]))}  [3:5]={hms(u24(p[3],p[4],p[5]))}",
        )

    def _ver(self, p):
        v = bytes(p[0:5]).decode("ascii", "replace")
        self.state["fw"] = v
        self.emit("RX_FIRMWARE_VERSION", v)

    def _warn_cur(self, p):
        self._warn("RX_CURRENT_ALARM", "current", p, WARN_CUR)

    def _warn_voltage(self, p):
        self._warn("RX_VOLTAGE_ALARM", "voltage", p, WARN_VOLTAGE)

    def _warn_temp(self, p):
        self._warn("RX_TEMPERATURE_ALARM", "temperature", p, WARN_TEMP)

    def _warn(self, tag, category, p, table):
        # show which payload byte tripped each alarm, for traceability
        hits = [f"[{i}]=1:{t}" for i, t in table.items()
                if i < len(p) and p[i] == 1]
        # Record the fault state every cycle (0 when clear) so a cleared alarm
        # is logged too; the packed `flags` metric picks it up on the next emit.
        self.state[f"fault_{category}"] = bool(hits)
        if hits:
            self.emit(tag, "  ".join(dict.fromkeys(hits)))

    def _sleep(self, p):
        on = p[0] == 0  # app: byte0 == 0 -> sleep mode on
        self.state["sleep"] = on
        self.emit("RX_SLEEP_ACK", f"{'on' if on else 'off'} ([0]={p[0]})")

    def _setting(self, p):
        self.emit("RX_SETTING_ACK",
                  f"ack [0]={p[0]} ({self.SETTING_TYPE.get(p[0], 'unknown')})")

    def _gate_set(self, p):
        on = [f"[{i}]:{g}" for i, (g, v) in enumerate(zip(self.GATES, p[:8]))
              if v == 1]
        self.emit("RX_GATE_SET", "on=" + (", ".join(on) if on else "none"))


def _matches(name, adv, name_filter):
    if name_filter:
        return name == name_filter
    if name.startswith("JS") or name.startswith("RV"):
        return True
    return SERVICE in [str(u).lower() for u in (adv.service_uuids or [])]


async def scan_all(name_filter, timeout):
    found = {}

    def cb(device, adv):
        nm = adv.local_name or device.name or ""
        if _matches(nm, adv, name_filter):
            # keep the latest RSSI seen in this scan window
            found[device.address] = (device, nm, adv.rssi)

    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    await asyncio.sleep(timeout)
    await scanner.stop()
    return list(found.values())


async def _sleep_interruptible(seconds, stop):
    end = time.monotonic() + seconds
    while time.monotonic() < end and not stop.is_set():
        await asyncio.sleep(0.25)


async def stream(device, name, parser, stop):
    """Keep this battery connected until stop: connect, stream, and on any
    drop or error, mark it offline and reconnect, until killed."""
    while not stop.is_set():
        try:
            async with BleakClient(device) as client:
                await client.start_notify(
                    NOTIFY_CHAR, lambda _s, d: parser.add(bytes(d))
                )

                async def tx(cmd):
                    try:
                        await client.write_gatt_char(
                            WRITE_CHAR, cmd, response=False)
                    except Exception:
                        await client.write_gatt_char(
                            WRITE_CHAR, cmd, response=True)

                # History is a dead end in every firmware build (stubbed, no
                # responder — 0 history frames ever seen), so we do NOT request
                # it. The parser still recognises a history frame defensively.
                handshake = [
                    ("TX_WAKE", CMD_BEGIN),
                    ("TX_REQUEST_ESTIMATE", CMD_GET_EST),
                    ("TX_REQUEST_VERSION", CMD_GET_VERSION),
                ]
                for tag, cmd in handshake:
                    await tx(cmd)
                    parser.log_tx(tag, cmd)     # log the command we sent
                    await asyncio.sleep(0.3)
                parser.state["connected"] = True
                print(f"[{name}] connected, logging to {name}.log")

                last_ver = time.monotonic()
                while not stop.is_set() and client.is_connected:
                    await asyncio.sleep(0.5)
                    # firmware is a one-shot reply to AT+V; re-ask until it lands
                    if "fw" not in parser.state and \
                            time.monotonic() - last_ver > 2:
                        await tx(CMD_GET_VERSION)
                        parser.log_tx("TX_REQUEST_VERSION", CMD_GET_VERSION)
                        last_ver = time.monotonic()
                await client.stop_notify(NOTIFY_CHAR)
        except Exception as e:  # noqa: BLE001
            print(f"[{name}] error: {e}")
        parser.state["connected"] = False
        # Close out this battery's open intervals at the moment of disconnect so
        # the gap until the next reading is recorded as a genuine offline window.
        if parser.db is not None:
            parser.db.flush(parser.serial, datetime.now())
        if stop.is_set():
            break
        print(f"[{name}] disconnected, reconnecting...")
        await _sleep_interruptible(3.0, stop)


def _signed(cs, value):
    return value if cs == "charging" else (-value if cs == "discharging" else 0.0)


def print_table(batteries):
    print(f"\n==== fleet @ {datetime.now():%H:%M:%S} ====")
    if not batteries:
        print("  (scanning — no batteries yet)")
        return
    total_full = total_rem = net_power = net_cur = 0.0
    live = 0
    for name, p in batteries:
        s = p.state
        online = s.get("connected", False)
        cs = s.get("charge_state", "-")
        cur = s.get("cur", 0.0)
        soc = s.get("soc")
        volt = s.get("volt")
        fw = s.get("fw", "")
        rssi = s.get("rssi")
        sc = _signed(cs, cur)
        status = "" if online else "  OFFLINE"
        rssi_s = "     " if rssi is None else f"{rssi:>4}dBm"
        print(
            f"  {name:12} {rssi_s}  "
            f"{('-' if soc is None else str(soc)+'%'):>5}  "
            f"{('  -  ' if volt is None else f'{volt:5.2f}')}V  "
            f"{sc:+6.1f}A  {cs:11} {fw}{status}"
        )
        # Only fold currently-connected batteries into the fleet total, so a
        # dropped battery's stale readings don't distort it.
        if not online:
            continue
        live += 1
        if s.get("full"):
            total_full += s["full"]
            total_rem += s.get("rem", 0.0)
        net_power += _signed(cs, s.get("power", 0.0))
        net_cur += sc
    csoc = round(total_rem / total_full * 100) if total_full > 0 else None
    fstate = (
        "charging" if net_power > 0.5
        else "discharging" if net_power < -0.5 else "idle"
    )
    print(
        f"  {'FLEET TOTAL':12} {('-' if csoc is None else str(csoc)+'%'):>5}  "
        f"cap={total_full:.0f}Ah  rem={total_rem:.0f}Ah  "
        f"net={net_power:+.0f}W {net_cur:+.1f}A  ({fstate}, {live} live)"
    )


async def controller(batteries, seconds, stop):
    # seconds <= 0 means run until killed (Ctrl+C); otherwise stop after seconds.
    end = None if seconds <= 0 else time.monotonic() + seconds
    while end is None or time.monotonic() < end:
        await asyncio.sleep(2.0)
        print_table(batteries)
    stop.set()


async def run(name_filter, seconds, scan_secs, rescan_secs, echo, db):
    os.makedirs(LOG_DIR, exist_ok=True)

    stop = asyncio.Event()
    batteries = []   # (name, parser), grows as new batteries are discovered
    logs = []
    tracked = {}     # address -> name (so we connect each battery only once)
    by_addr = {}     # address -> Parser (to refresh RSSI on re-scan)
    tasks = set()

    def add_device(device, name, rssi):
        # Existing battery: just refresh its RSSI (and log it).
        parser = by_addr.get(device.address)
        if parser is not None:
            if rssi is not None:
                parser.state["rssi"] = rssi
                parser.emit("RSSI", f"{rssi} dBm")
            return
        # New battery.
        tracked[device.address] = name
        path = os.path.join(LOG_DIR, f"{name}.log")
        # append, never overwrite — a monitoring log must not lose prior runs
        f = open(path, "a", encoding="utf-8", buffering=1)
        f.write(f"\n# ==== session start {name}  {device.address}  "
                f"{datetime.now():%Y-%m-%d %H:%M:%S} ====\n")
        logs.append(f)
        parser = Parser(name, f, echo=echo, db=db)
        if rssi is not None:
            parser.state["rssi"] = rssi
        by_addr[device.address] = parser
        batteries.append((name, parser))
        print(f"[SCAN] new battery: {name}  {device.address}  rssi={rssi}dBm")
        if rssi is not None:
            parser.emit("RSSI", f"{rssi} dBm")
        tasks.add(asyncio.create_task(
            stream(device, name, parser, stop)))

    async def discover():
        # Scan on start and then keep scanning, so batteries powered on or
        # brought into range later are picked up automatically, and so each
        # battery's RSSI (signal strength) is refreshed and logged.
        print(f"Scanning ({scan_secs} s)... (rescanning every {rescan_secs} s)")
        while not stop.is_set():
            for device, name, rssi in await scan_all(name_filter, scan_secs):
                add_device(device, name, rssi)
            await _sleep_interruptible(rescan_secs, stop)

    tasks.add(asyncio.create_task(discover()))
    tasks.add(asyncio.create_task(controller(batteries, seconds, stop)))

    try:
        await stop.wait()
    finally:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for f in logs:
            f.close()  # db writer is closed by main()

    if tracked:
        print("\nPer-battery logs:")
        for name in tracked.values():
            print(f"  {os.path.join(LOG_DIR, name + '.log')}")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Read JoySuny batteries over BLE.")
    ap.add_argument("--name", help="only this advertised name, e.g. JS-2C14AA")
    ap.add_argument("--seconds", type=int, default=30,
                    help="how long to stream; 0 = run until killed (Ctrl+C)")
    ap.add_argument("--scan-secs", type=int, default=8, help="scan window")
    ap.add_argument("--rescan-secs", type=int, default=20,
                    help="how often to re-scan for newly appeared batteries")
    ap.add_argument("--echo", action="store_true",
                    help="also echo each battery's frames to the console")
    # SQLite logging (lightweight: a single file, no server). On by default.
    ap.add_argument("--sqlite", nargs="?", const="__default__", metavar="PATH",
                    help="SQLite file to log every data point to "
                         "(default: logs/battery.db)")
    ap.add_argument("--no-db", action="store_true",
                    help="do not log to the database")
    args = ap.parse_args()

    # Build the database writer (SQLite, default logs/battery.db).
    db = None
    if not args.no_db:
        try:
            path = args.sqlite
            if path in (None, "__default__"):
                os.makedirs(LOG_DIR, exist_ok=True)
                path = os.path.join(LOG_DIR, "battery.db")
            db = IntervalStore(path)
        except Exception as e:  # noqa: BLE001
            print(f"[db] disabled (could not open database): {e}")
            db = None

    try:
        return asyncio.run(
            run(args.name, args.seconds, args.scan_secs, args.rescan_secs,
                args.echo, db))
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 0
    finally:
        if db is not None:
            db.close()


if __name__ == "__main__":
    sys.exit(main())
