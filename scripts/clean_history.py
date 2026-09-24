#!/usr/bin/env python3
"""One cleaned, complete master history for the AWTO BMS packs (#116).

Builds an ANALYSIS database from every history source there is, without
touching any source and without deleting anything:

  freeze   copy every input into <out>/sources/ with a SHA-256 manifest
  build    <out>/master.db from the frozen copies:
             * every interval-store row, unchanged, tagged with its source
             * readings re-derived from raw frames with the app's own rules
               (bms_replay.py), kept where the device's store has none
               (`backfilled`): phone/Windows raw logs and the Python tool DB
             * flags, never deletions: `demo` (demo-mode rows under real
               serials, #115), `backfilled`, `shadow` (the losing device where
               two devices hold readings for the same pack at the same time)
             * validation of the port: phone and Windows raw logs re-derived
               and compared metric by metric with their stores
             * lifetime totals recomputed from the clean rows, every fold
               recorded (#97), set against the per-device stored totals
  report   <out>/REPORT.md from master.db (for the user's sign-off)
  all      freeze + build + report

Nothing is imported into the apps. The clean history is the `clean_readings`
view (demo = 0 AND shadow = 0).

Times: raw-log lines and the Python DB carry local time only; they are read
at a FIXED offset (--utc-offset, default +8 = AWST, no DST) so the result does
not depend on the machine running it.

Usage (from projects/awto-bms):
    python scripts/clean_history.py all --out logs/clean-20260924 \\
        --pull logs/pull-20260924-1458 --old-pull logs/pull-20260924 \\
        --python-logs C:/git/awto-sphere/python_ble/logs
    python scripts/clean_history.py build --out logs/clean-20260924
    python scripts/clean_history.py report --out logs/clean-20260924
"""
from __future__ import annotations

import argparse
import bisect
import datetime as dt
import hashlib
import json
import re
import shutil
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bms_replay as br  # noqa: E402

REAL_SERIALS = ('JS-2C14AA', 'JS-2C14B8')
# Demo-mode seeds before 80899d7 (#115): one real serial plus three invented.
DEMO_ONLY_SERIALS = ('JS-9F031B', 'JS-5A77C0', 'RV-1180E2')
DEVICES = ('phone', 'windows', 'python')
# Values only the demo generator produces (demo_source.dart): chip byte 24
# and cycles 7 (real packs report chip 0 and cycles 0/1).
DEMO_SIGNATURE = {('chip', 24.0), ('cycles', 7.0)}

# A store's coverage edge is widened by this much before deciding that a
# derived row is "not in the store" (timestamp jitter between the raw-log line
# and the store write is a few ms; a flush can lag up to 60 s and that tail
# IS backfilled).
EDGE_TOL_MS = 1000
# Validation: a store row and a derived row are the same row when their values
# are equal and their starts (and ends, for an exact match) are this close.
MATCH_TOL_MS = 50
# Raw-log silence longer than this before a handshake is read as "the app was
# not running" (a new connection object, empty state) in the hybrid replay.
SILENT_RESTART_MS = 5 * 60_000
# Raw-log lines closer than this belong to one span of "the log was running".
ACTIVITY_GAP_MS = 10 * 60_000
# Validation: rows starting this soon after a handshake are "link start" rows.
LINK_START_MS = 3000

TS_RE = re.compile(r'^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3})$')
HEX_TOKEN = re.compile(r'^[0-9a-f]{2}$')
SAMPLING_ON = re.compile(r'(?:#\d+ )?background sampling every (\d+) s')
SAMPLING_OFF = re.compile(r'(?:#\d+ )?foreground: continuous again')


# ---------------------------------------------------------------------------
# time helpers
# ---------------------------------------------------------------------------

class Clock:
    """Local 'YYYY-MM-DD HH:MM:SS.mmm' <-> epoch ms at a fixed UTC offset."""

    def __init__(self, utc_offset_h: float = 8.0):
        self.tz = dt.timezone(dt.timedelta(hours=utc_offset_h))
        self.offset_ms = int(round(utc_offset_h * 3_600_000))
        self._day_cache: dict[str, int] = {}

    def to_ms(self, local: str) -> int | None:
        m = TS_RE.match(local)
        if not m:
            return None
        day = local[:10]
        base = self._day_cache.get(day)
        if base is None:
            y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
            base = int(dt.datetime(y, mo, d, tzinfo=dt.timezone.utc)
                       .timestamp()) * 1000 - self.offset_ms
            self._day_cache[day] = base
        return (base + int(m.group(4)) * 3_600_000 + int(m.group(5)) * 60_000
                + int(m.group(6)) * 1000 + int(m.group(7)))

    def fmt(self, ms: int | None) -> str | None:
        if ms is None:
            return None
        t = dt.datetime.fromtimestamp(ms / 1000, self.tz)
        return t.strftime('%Y-%m-%d %H:%M:%S.') + f'{ms % 1000:03d}'

    def day(self, ms: int) -> str:
        return dt.datetime.fromtimestamp(ms / 1000, self.tz).strftime('%Y-%m-%d')

    def day_start(self, day: str) -> int:
        return self.to_ms(day + ' 00:00:00.000')


# ---------------------------------------------------------------------------
# freeze
# ---------------------------------------------------------------------------

def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def freeze_plan(pull: Path, old_pull: Path | None,
                python_logs: Path) -> list[tuple[Path, str]]:
    """(source file, path under sources/) for every input file."""
    plan: list[tuple[Path, str]] = []
    for dev in ('phone', 'windows'):
        for f in sorted((pull / dev).iterdir()):
            if f.is_file():
                plan.append((f, f'{dev}/{f.name}'))
    for f in sorted(python_logs.iterdir()):
        if f.is_file():
            plan.append((f, f'python/{f.name}'))
    if old_pull is not None:
        for dev in ('phone', 'windows'):
            for f in sorted((old_pull / dev).iterdir()):
                if f.is_file():
                    plan.append((f, f'old-pull-20260924/{dev}/{f.name}'))
    return plan


def cmd_freeze(args: argparse.Namespace) -> int:
    out = Path(args.out)
    src_dir = out / 'sources'
    plan = freeze_plan(Path(args.pull),
                       Path(args.old_pull) if args.old_pull else None,
                       Path(args.python_logs))
    manifest = []
    for src, rel in plan:
        dest = src_dir / rel
        digest = sha256_of(src)
        if dest.exists():
            have = sha256_of(dest)
            if have != digest:
                print(f'REFUSING: {dest} exists with a different SHA-256 '
                      f'({have[:12]} vs source {digest[:12]}). Frozen copies '
                      'are never overwritten; use a new --out.',
                      file=sys.stderr)
                return 2
        else:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            if sha256_of(dest) != digest:
                print(f'copy of {src} does not match its source', file=sys.stderr)
                return 2
        st = src.stat()
        manifest.append({
            'path': rel, 'sha256': digest, 'bytes': st.st_size,
            'original': str(src).replace('\\', '/'),
            'original_mtime': dt.datetime.fromtimestamp(st.st_mtime)
            .strftime('%Y-%m-%d %H:%M:%S'),
        })
        print(f'{digest[:12]}  {st.st_size:>10}  {rel}')
    with (src_dir / 'SHA256SUMS').open('w', encoding='utf-8', newline='\n') as f:
        for m in manifest:
            f.write(f"{m['sha256']}  {m['path']}\n")
    with (src_dir / 'manifest.json').open('w', encoding='utf-8',
                                          newline='\n') as f:
        json.dump({'frozen_at': dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                   'files': manifest}, f, indent=1)
        f.write('\n')
    print(f'-> {src_dir} ({len(manifest)} files)')
    return 0


def verify_manifest(src_dir: Path) -> list[str]:
    """Problems found re-hashing the frozen copies (empty = all good)."""
    bad = []
    with (src_dir / 'SHA256SUMS').open(encoding='utf-8') as f:
        for line in f:
            digest, rel = line.rstrip('\n').split('  ', 1)
            p = src_dir / rel
            if not p.is_file():
                bad.append(f'missing {rel}')
            elif sha256_of(p) != digest:
                bad.append(f'changed {rel}')
    return bad


# ---------------------------------------------------------------------------
# raw-log replay
# ---------------------------------------------------------------------------

def parse_raw_line(line: str):
    """-> (local_time, serial, kind, hex_bytes or None, text) or None.
    kind: 'notif', 'decoded:<label>', 'tx:<name>', 'diag', 'other:<label>'."""
    if len(line) < 27 or line[23:25] != '  ':
        return None
    ts = line[:23]
    rest = line[25:]
    sp = rest.find('  ')
    if sp < 0:
        return None
    serial = rest[:sp]
    body = rest[sp + 2:]
    if body.startswith('Notification (raw)'):
        return ts, serial, 'notif', _hex_head(body[18:]), ''
    if body.startswith('TX: '):
        name, hx = _split_label_hex(body[4:])
        return ts, serial, 'tx:' + name, hx, ''
    if body.startswith('DIAG'):
        return ts, serial, 'diag', None, body[4:].strip()
    for label in br.DECODED_LABELS:
        if body.startswith(label) and body[len(label):len(label) + 1] == ' ':
            return ts, serial, 'decoded:' + label, _hex_head(body[len(label):]), ''
    return ts, serial, 'other:' + body.split('  ')[0].strip(), None, body


def _hex_head(s: str) -> bytes | None:
    toks = []
    for t in s.strip().split(' '):
        if HEX_TOKEN.match(t):
            toks.append(t)
        else:
            break
    return bytes.fromhex(''.join(toks)) if toks else None


TX_BODY = re.compile(r'^(.*?)\s+((?:[0-9a-f]{2} )*[0-9a-f]{2})(?:   .*)?$')


def _split_label_hex(s: str) -> tuple[str, bytes | None]:
    """'request time estimate c4 7d f4 d5 86   sent' -> (name, bytes)."""
    mm = TX_BODY.match(s)
    if not mm:
        return s.strip(), None
    return mm.group(1).strip(), bytes.fromhex(mm.group(2).replace(' ', ''))


class Replay:
    """Emulates one app install: a Session per pack, the shared logger."""

    def __init__(self, device: str, fresh_state_per_link: bool = True):
        self.device = device
        self.fresh_state_per_link = fresh_state_per_link
        self.sessions: dict[str, br.Session] = {}
        self.logger = br.IntervalLogger()
        self.stats = Counter()
        self.frame_times: dict[str, list[int]] = defaultdict(list)
        self.handshakes: dict[str, list[int]] = defaultdict(list)
        self.unpaired: list[tuple[int, str, str, str]] = []
        self.sampling_changes: list[tuple[int, int]] = []
        self.activity: list[list[int]] = []   # spans with raw-log lines

    def note_line(self, ms: int) -> None:
        if self.activity and ms - self.activity[-1][1] <= ACTIVITY_GAP_MS:
            self.activity[-1][1] = max(self.activity[-1][1], ms)
        else:
            self.activity.append([ms, ms])

    def new_link(self, serial: str, fresh: bool | None = None
                 ) -> br.Session:
        """A handshake: the logger closes the pack's open rows (the
        disconnect before it) and the parser buffer is reset. Whether the
        pack's decoded state starts empty (a new BatteryConnection object:
        app start, demo toggle, startLive) or carries over (a reconnect of the
        same object) is `fresh`, defaulting to `fresh_state_per_link`."""
        self.logger.disconnect(serial)
        if fresh is None:
            fresh = self.fresh_state_per_link
        if fresh and serial in self.sessions:
            old = self.sessions.pop(serial)
            s = self.session(serial)
            s.state.rssi = old.state.rssi
            return s
        s = self.session(serial)
        s.parser.reset()
        return s

    def session(self, serial: str) -> br.Session:
        s = self.sessions.get(serial)
        if s is None:
            s = self.sessions[serial] = br.Session(serial)
        s.max_integrate_gap_ms = br.sample_gap_ms(self.logger.sample_interval_ms)
        return s

    def set_sampling(self, interval_ms: int, at_ms: int) -> None:
        self.logger.sample_interval_ms = interval_ms
        self.sampling_changes.append((at_ms, interval_ms))

    def rows(self) -> list[br.Row]:
        self.logger.close_all()
        return self.logger.rows


def replay_raw_log(path: Path, device: str, clock: Clock,
                   fresh_state_per_link: bool | str = True) -> Replay:
    """Re-derive the readings a device's app stored, from its raw log.

    Each `Notification (raw)` line is fed to that pack's parser. The app
    decodes a notification synchronously (and writes one decoded-frame line per
    frame right after it) but its logger hears about the frames through an
    ASYNC stream, so it observes the state AFTER the whole notification, once
    per frame, at about the time of the last decoded line. The pairing of
    parsed frames with the decoded lines that follow also checks the framing
    port: a decoded line with no matching parsed frame was never a received
    notification (demo mode feeds its parser directly, #115).

    `fresh_state_per_link`: True = every link starts with an empty state,
    False = the state carries over, 'hybrid' (used for the master) = empty
    after a demo episode or after the raw log fell silent for more than
    SILENT_RESTART_MS (the app was not running or the log was off), carried
    over otherwise (a reconnect of the same connection object, as the app
    does even across long sampling gaps)."""
    hybrid = fresh_state_per_link == 'hybrid'
    rp = Replay(device, bool(fresh_state_per_link) and not hybrid)
    pending: dict[str, list] = {}   # serial -> [frames, next_idx, t_ms]
    demo_since: dict[str, bool] = {}
    last_line_ms = 0

    def finalize(serial: str) -> None:
        g = pending.pop(serial, None)
        if g is None:
            return
        rp.stats['frames_without_decoded_line'] += len(g[0]) - g[1]
        rp.logger.observe(rp.sessions[serial], g[2])
        rp.stats['observations'] += 1

    def finalize_all() -> None:
        for s in list(pending):
            finalize(s)

    with path.open(encoding='utf-8', errors='replace') as f:
        for line in f:
            p = parse_raw_line(line.rstrip('\n'))
            if p is None:
                rp.stats['unparsed_lines'] += 1
                continue
            ts, serial, kind, hx, text = p
            ms = clock.to_ms(ts)
            if ms is None:
                rp.stats['bad_time'] += 1
                continue
            silent = last_line_ms and ms - last_line_ms > SILENT_RESTART_MS
            last_line_ms = ms
            rp.note_line(ms)
            if kind == 'notif':
                rp.stats['notifications'] += 1
                finalize(serial)
                if hx is None:
                    continue
                if silent and hybrid:
                    # Frames after a long silence with no handshake line: the
                    # raw log was switched off mid-link (#109) or the app was
                    # not running. Nothing carries over from before.
                    rp.new_link(serial, True)
                    rp.stats['links_after_silence'] += 1
                sess = rp.session(serial)
                frames = sess.parser.add_bytes(hx)
                for _ in frames:
                    sess.integrate(ms)
                if frames:
                    rp.stats['frames'] += len(frames)
                    rp.frame_times[serial].append(ms)
                    pending[serial] = [frames, 0, ms]
            elif kind.startswith('decoded:'):
                rp.stats['decoded_lines'] += 1
                g = pending.get(serial)
                if g is not None and g[1] < len(g[0]) and g[0][g[1]][1] == hx:
                    g[1] += 1
                    g[2] = ms
                    rp.stats['decoded_paired'] += 1
                else:
                    rp.stats['decoded_unpaired'] += 1
                    for other in list(rp.sessions) + list(REAL_SERIALS):
                        demo_since[other] = True
                    rp.unpaired.append((ms, serial, kind[8:],
                                        hx.hex(' ') if hx else ''))
            elif kind.startswith('tx:'):
                name = kind[3:]
                if name == 'handshake begin':
                    finalize(serial)
                    fresh = None
                    if hybrid:
                        # A new connection object is certain after a demo
                        # episode (startLive disposes every row) and likely
                        # after the log fell silent (the app was not running).
                        fresh = bool(demo_since.pop(serial, False) or silent)
                    rp.new_link(serial, fresh)
                    rp.handshakes[serial].append(ms)
                    rp.stats['handshakes'] += 1
                elif name == 'request firmware version':
                    rp.session(serial).parser.at_version_sent = True
            elif kind == 'diag':
                m = SAMPLING_ON.search(text)
                if m:
                    finalize_all()
                    rp.set_sampling(int(m.group(1)) * 1000, ms)
                elif SAMPLING_OFF.search(text):
                    finalize_all()
                    rp.set_sampling(0, ms)
    finalize_all()
    rp.last_line_ms = last_line_ms
    return rp


# ---------------------------------------------------------------------------
# Python-tool replay
# ---------------------------------------------------------------------------

def _hms_to_s(t: str) -> int:
    h, m, s = t.split(':')
    return int(h) * 3600 + int(m) * 60 + int(s)


def _u24(v: int) -> list[int]:
    return [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF]


# Constant frames: in the Python DB's raw era every MOS / temperature-alarm
# frame was exactly this (5 200 / 5 198 frames, both packs).
PY_MOS_ON = bytes.fromhex('a39f010100000000b4c7')
PY_WARN_TEMP_LATCHED = bytes.fromhex('a6c0000001000000' '00b772')


def python_early_frame(frame: str, message: str, data: dict) -> tuple[
        bytes | None, str]:
    """Rebuild the frame bytes of an early (18 Sep, pre-raw) Python DB row
    from its decoded text/JSON, where the decode is lossless. Returns
    (bytes or None, note). None = apply as a state patch instead."""
    if frame == 'cells':
        cells = data['cells']
        b = [0xA0, 0xC1, len(cells)]
        for mv in cells:
            b += [mv & 0xFF, (mv >> 8) & 0xFF]
        return bytes(b + [0xB1, 0xD2]), 'rebuilt (lossless)'
    if frame == 'soc':
        return bytes([0xA9, 0x64, data['soc'], *_u24(round(data['full'] * 1000)),
                      *_u24(round(data['rem'] * 1000)), 0xBA, 0x5E]), \
            'rebuilt (lossless)'
    if frame == 'est':
        m = re.match(r'toFull=(\S+) toEmpty=(\S+)', message)
        return bytes([0xAA, 0xAF, *_u24(_hms_to_s(m.group(1))),
                      *_u24(_hms_to_s(m.group(2))), 0xBB, 0x22]), \
            'rebuilt (lossless)'
    if frame == 'bal':
        m = re.match(r'state=(\w+) chgMos=(\w+) disMos=(\w+) passiveBal=(\w+) '
                     r'tempGate=(\d+) smokeGate=(\d+) heatGate=(\d+)', message)
        cs = {'idle': 0, 'charging': 1, 'discharging': 2}[m.group(1)]
        tf = [1 if m.group(i) == 'True' else 0 for i in (2, 3, 4)]
        return bytes([0xA8, 0xAC, cs, *tf, int(m.group(5)), int(m.group(6)),
                      int(m.group(7)), 0xB9, 0x21]), 'rebuilt (lossless)'
    if frame == 'other':
        return bytes([0xA7, 0x4E]) + bytes.fromhex(message.replace(' ', '')), \
            'rebuilt (lossless)'
    if frame == 'sleep':
        return bytes([0xAC, 0xCA, 1 if message.startswith('off') else 0,
                      0xDE, 0xED]), 'rebuilt (lossless)'
    if frame == 'version':
        return bytes([0xAC, 0x9A]) + message.encode('latin-1')[:5] + \
            bytes([0xBD, 0x10]), 'rebuilt (lossless)'
    if frame == 'mos' and message.startswith('on=True'):
        return PY_MOS_ON, 'rebuilt from the raw-era constant frame'
    if frame == 'warn_temp' and 'MOS over temperature' in message:
        return PY_WARN_TEMP_LATCHED, 'rebuilt from the raw-era constant frame'
    return None, 'state patch'


def python_state_patch(frame: str, data: dict, state: br.BatteryState) -> bool:
    """Early rows whose bytes cannot be rebuilt: set only what the JSON
    decode carries. Returns True when it was an event."""
    if frame == 'temp':
        # The tool decoded only p1 ("t1") and p3 ("t2"); app: temp1=p1, temp2=p3.
        state.temp1 = data.get('t1')
        state.temp2 = data.get('t2')
        return True
    if frame == 'all':
        state.pack_voltage = data['volt']
        state.pack_current = data['cur']
        state.load_connected = data['load']
        state.charger_connected = data['charger']
        state.chip_temperature = data['chip']
        state.cell_sum = data['sum']
        state.cell_max = data['max']
        state.cell_min = data['min']
        state.cell_diff = data['diff']
        state.power = data['power']
        state.cycle_count = data['cycles']
        state.cell_avg = data['avg']
        return True
    return False


def replay_python_db(path: Path, clock: Clock,
                     infer_clear_alarms: bool = True,
                     fresh_state_per_link: bool = True) -> Replay:
    """Re-derive app readings from the Python tool's battery_frames table.

    Each RX row is ONE frame (its `_raw` hex) at its own timestamp; early rows
    (18 Sep before 22:00) have no raw bytes and are rebuilt from their decoded
    text where that is lossless (see python_early_frame).

    The tool logged an alarm frame only when a bit was set (`if hits:` in its
    `_warn`), so all-clear current/voltage alarm frames were received but
    never stored. With `infer_clear_alarms` those two categories are taken as
    reported-and-clear from the first frame of each link, so the packed
    `flags` row (charge state, load, charger, MOS) can be written; without it
    the app's M8 gate would never write `flags` for this period."""
    rp = Replay('python', fresh_state_per_link)
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    early_notes = Counter()
    try:
        cur = db.execute('SELECT id, ts, serial, frame, message, data '
                         'FROM battery_frames ORDER BY id')
        for _id, ts, serial, frame, message, data in cur:
            ms = clock.to_ms(ts)
            if ms is None:
                rp.stats['bad_time'] += 1
                continue
            try:
                d = json.loads(data) if data else {}
            except json.JSONDecodeError:
                d = {}
            if frame in ('TX_BEGIN',):
                rp.new_link(serial)
                rp.handshakes[serial].append(ms)
                rp.stats['handshakes'] += 1
                continue
            if frame in ('RSSI', 'rssi'):
                m = re.match(r'(-?\d+)', message or '')
                if m:
                    rp.session(serial).state.rssi = int(m.group(1))
                continue
            if frame.startswith('TX_') or frame in ('UNRECOGNISED',
                                                    'unrecognised'):
                continue
            last = rp.frame_times.get(serial)
            hs = rp.handshakes.get(serial)
            if last and ms - last[-1] > br.GAP_MS and                     not (hs and hs[-1] > last[-1]):
                # A new run of the tool (one process per run in the early
                # era, which logged no TX lines): a new link, empty state.
                rp.new_link(serial)
                rp.stats['links_by_gap'] += 1
            sess = rp.session(serial)
            if infer_clear_alarms and not sess.state.current_alarm_seen:
                sess.state.current_alarm_seen = True
                sess.state.voltage_alarm_seen = True
                rp.stats['alarm_clear_inferred'] += 1
            if frame.startswith('RX_'):
                raw = d.get('_raw')
                if not raw:
                    rp.stats['rx_without_raw'] += 1
                    continue
                frames = sess.parser.add_bytes(bytes.fromhex(raw.replace(' ', '')))
                if not frames:
                    rp.stats['rx_not_a_frame'] += 1
                    continue
            else:
                b, note = python_early_frame(frame, message or '', d)
                early_notes[f'{frame}: {note}'] += 1
                if b is not None:
                    frames = sess.parser.add_bytes(b)
                    if not frames:
                        rp.stats['early_not_a_frame'] += 1
                        continue
                elif python_state_patch(frame, d, sess.state):
                    frames = [(frame, b'')]
                else:
                    rp.stats[f'early_skipped_{frame}'] += 1
                    continue
                rp.stats['early_rows'] += 1
            for _ in frames:
                sess.integrate(ms)
            rp.stats['frames'] += len(frames)
            rp.frame_times[serial].append(ms)
            rp.logger.observe(sess, ms)
            rp.stats['observations'] += 1
    finally:
        db.close()
    rp.early_notes = early_notes
    return rp


# ---------------------------------------------------------------------------
# span helpers
# ---------------------------------------------------------------------------

def merge_spans(spans, gap_ms: int = br.GAP_MS, policy: br.GapPolicy | None = None
                ) -> list[list[int]]:
    """intervals.dart mergeCoverage over (start, end) pairs."""
    spans = sorted(spans)
    out: list[list[int]] = []
    for s, e in spans:
        if out and (policy.abuts(out[-1][1], s) if policy
                    else br.abuts(out[-1][1], s, gap_ms)):
            if e > out[-1][1]:
                out[-1][1] = e
        else:
            out.append([s, e])
    return out


def subtract_spans(a: list[list[int]], b: list[list[int]]) -> list[list[int]]:
    """Parts of spans `a` not covered by spans `b` (both sorted, merged)."""
    out = []
    j = 0
    for s, e in a:
        cur = s
        while j < len(b) and b[j][1] < cur:
            j += 1
        k = j
        while k < len(b) and b[k][0] <= e:
            if b[k][0] > cur:
                out.append([cur, b[k][0]])
            cur = max(cur, b[k][1])
            k += 1
        if cur < e:
            out.append([cur, e])
        elif cur == e == s:
            # a zero-length span entirely uncovered
            if not any(bs <= s <= be for bs, be in b[j:k]):
                out.append([s, e])
    return out


def intersect_spans(a: list[list[int]], b: list[list[int]]) -> list[list[int]]:
    out = []
    i = j = 0
    while i < len(a) and j < len(b):
        s = max(a[i][0], b[j][0])
        e = min(a[i][1], b[j][1])
        if s < e:
            out.append([s, e])
        if a[i][1] < b[j][1]:
            i += 1
        else:
            j += 1
    return out


def in_spans(spans: list[list[int]], starts: list[int], t: int) -> int | None:
    """Index of the span containing t (spans sorted, non-overlapping)."""
    i = bisect.bisect_right(starts, t) - 1
    if i >= 0 and spans[i][0] <= t <= spans[i][1]:
        return i
    return None


def overlaps_spans(spans: list[list[int]], starts: list[int], a: int,
                   b: int) -> bool:
    """True iff [a, b] touches any span (spans sorted, non-overlapping)."""
    i = bisect.bisect_right(starts, b) - 1
    return i >= 0 and spans[i][1] >= a


def policy_from_rows(rows) -> br.GapPolicy:
    """GapPolicy from rows with .metric == 'sampleIntervalS' (start order)."""
    si = sorted((r.start_ms, r.value_num) for r in rows
                if r.metric == 'sampleIntervalS')
    return br.GapPolicy(si)


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE sources (
  source TEXT PRIMARY KEY, device TEXT, kind TEXT, path TEXT, sha256 TEXT,
  bytes INTEGER, used INTEGER, note TEXT);
CREATE TABLE readings (
  rid INTEGER PRIMARY KEY,
  device TEXT NOT NULL,          -- phone | windows | python
  source TEXT NOT NULL,          -- phone_store | phone_raw | windows_store | windows_raw | python_db
  orig_id INTEGER,               -- the row id in its store (NULL when derived)
  serial TEXT NOT NULL, metric TEXT NOT NULL, value_num REAL, value_text TEXT,
  start_time TEXT, end_time TEXT, start_ms INTEGER, end_ms INTEGER,
  demo INTEGER NOT NULL DEFAULT 0,
  backfilled INTEGER NOT NULL DEFAULT 0,
  shadow INTEGER NOT NULL DEFAULT 0,
  note TEXT);
CREATE TABLE derived_readings (
  device TEXT NOT NULL, serial TEXT NOT NULL, metric TEXT NOT NULL,
  value_num REAL, value_text TEXT, start_time TEXT, end_time TEXT,
  start_ms INTEGER, end_ms INTEGER, in_store INTEGER NOT NULL);
CREATE TABLE alarm_events_src (device TEXT NOT NULL, data TEXT NOT NULL);
CREATE TABLE lifetime_before (
  device TEXT, serial TEXT, total_charge_ah REAL, total_discharge_ah REAL,
  total_efc REAL, aggregated_up_to TEXT, aggregated_up_to_ms INTEGER);
CREATE TABLE lifetime_check (
  device TEXT, serial TEXT, up_to_ms INTEGER, what TEXT,
  charge_ah REAL, discharge_ah REAL, note TEXT);
CREATE TABLE lifetime_folds (
  serial TEXT, fold INTEGER, from_ms INTEGER, to_ms INTEGER,
  from_time TEXT, to_time TEXT, rows INTEGER, sources TEXT,
  charge_ah REAL, discharge_ah REAL, efc_added REAL,
  cum_charge_ah REAL, cum_discharge_ah REAL, cum_efc REAL);
CREATE TABLE lifetime_after (
  serial TEXT PRIMARY KEY, total_charge_ah REAL, total_discharge_ah REAL,
  total_efc REAL, rated_full_ah REAL, aggregated_up_to TEXT,
  aggregated_up_to_ms INTEGER, folds INTEGER);
CREATE TABLE demo_windows (
  device TEXT, from_ms INTEGER, to_ms INTEGER, from_time TEXT, to_time TEXT,
  demo_only_rows INTEGER, real_serial_rows INTEGER, aa_start_times INTEGER,
  aa_starts_within_20ms INTEGER, aa_signature_rows INTEGER);
CREATE TABLE overlaps (
  serial TEXT, from_ms INTEGER, to_ms INTEGER, from_time TEXT, to_time TEXT,
  devices TEXT, winner TEXT, rule TEXT, shadow_rows INTEGER);
CREATE TABLE coverage_daily (
  serial TEXT, day TEXT, source TEXT, covered_s REAL);
CREATE TABLE unobserved_gaps (
  serial TEXT, from_ms INTEGER, to_ms INTEGER, from_time TEXT, to_time TEXT,
  minutes REAL, context TEXT);
CREATE TABLE raw_log_activity (
  device TEXT, from_ms INTEGER, to_ms INTEGER, from_time TEXT, to_time TEXT);
CREATE TABLE lifetime_row_diffs (
  device TEXT, serial TEXT, start_time TEXT, value REAL,
  store_only_ah REAL, master_ah REAL, next_row TEXT);
CREATE TABLE link_events (
  device TEXT, serial TEXT, at_ms INTEGER, kind TEXT);
CREATE TABLE contact_daily (
  device TEXT, serial TEXT, day TEXT, handshakes INTEGER, frames INTEGER);
CREATE TABLE validation_windows (
  device TEXT, serial TEXT, from_ms INTEGER, to_ms INTEGER,
  from_time TEXT, to_time TEXT);
CREATE TABLE validation_metric (
  device TEXT, serial TEXT, metric TEXT, store_rows INTEGER,
  derived_rows INTEGER, start_match INTEGER, exact INTEGER,
  end_store_earlier INTEGER, end_store_later INTEGER,
  link_rows INTEGER, link_start_match INTEGER,
  point_agree INTEGER, point_checked INTEGER, derived_unmatched INTEGER,
  derived_unmatched_link INTEGER);
CREATE TABLE validation_examples (
  device TEXT, serial TEXT, metric TEXT, kind TEXT, store_start TEXT,
  store_end TEXT, store_value TEXT, derived_start TEXT, derived_end TEXT,
  derived_value TEXT);
CREATE TABLE replay_stats (device TEXT, key TEXT, value INTEGER);
CREATE TABLE unpaired_decoded (
  device TEXT, at_ms INTEGER, at_time TEXT, serial TEXT, label TEXT,
  hex TEXT, demo_signature INTEGER);
CREATE TABLE known_batteries (
  serial TEXT PRIMARY KEY, alias TEXT, is_demo INTEGER, first_seen TEXT,
  last_seen TEXT, last_soc REAL, last_pack_v REAL, last_rem_ah REAL,
  last_full_ah REAL, firmware TEXT, devices TEXT);
"""

VIEWS = """
CREATE INDEX ix_readings ON readings(serial, metric, start_ms);
CREATE INDEX ix_readings_dev ON readings(device, serial, start_ms);
CREATE INDEX ix_derived ON derived_readings(device, serial, metric, start_ms);
CREATE INDEX ix_link ON link_events(serial, at_ms);
CREATE VIEW clean_readings AS
  SELECT * FROM readings WHERE demo = 0 AND shadow = 0;
CREATE VIEW flag_counts AS
  SELECT serial, source, COUNT(*) AS rows, SUM(demo) AS demo,
         SUM(backfilled) AS backfilled, SUM(shadow) AS shadow
  FROM readings GROUP BY serial, source;
"""


def load_store(path: Path, clock: Clock) -> tuple[list[tuple], list[tuple],
                                                   list[dict]]:
    """(readings rows, lifetime rows, alarm_events rows) of one store."""
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    try:
        ok = db.execute('PRAGMA integrity_check').fetchone()[0]
        if ok != 'ok':
            print(f'WARNING {path}: integrity_check {ok!r}', file=sys.stderr)
        rows = db.execute(
            'SELECT id, serial, metric, value_num, value_text, start_time, '
            'end_time, start_ms, end_ms FROM readings ORDER BY id').fetchall()
        fixed = []
        for r in rows:
            s_ms = r[7] if r[7] is not None else clock.to_ms(r[5])
            e_ms = r[8] if r[8] is not None else clock.to_ms(r[6])
            fixed.append((*r[:7], s_ms, e_ms))
        lt = db.execute(
            'SELECT serial, total_charge_ah, total_discharge_ah, total_efc, '
            'aggregated_up_to, aggregated_up_to_ms FROM lifetime_totals'
        ).fetchall()
        try:
            cols = [c[1] for c in db.execute('PRAGMA table_info(alarm_events)')]
            alarms = [dict(zip(cols, a))
                      for a in db.execute('SELECT * FROM alarm_events')]
        except sqlite3.DatabaseError:
            alarms = []
    finally:
        db.close()
    return fixed, lt, alarms


def demo_windows_for(rows: list[tuple]) -> list[list[int]]:
    """Spans (gap 10 s) where a demo-only serial has rows."""
    spans = [(r[7], r[8]) for r in rows if r[1] in DEMO_ONLY_SERIALS]
    return merge_spans(spans, br.GAP_MS)


def build(out: Path, clock: Clock, infer_clear_alarms: bool = True) -> Path:
    src = out / 'sources'
    problems = verify_manifest(src)
    if problems:
        raise SystemExit('frozen sources do not match SHA256SUMS: '
                         + '; '.join(problems))
    master_path = out / 'master.db'
    if master_path.exists():
        master_path.unlink()   # our own derived output, rebuilt every run
    m = sqlite3.connect(master_path)
    m.executescript(SCHEMA)
    meta = {'built_at': dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            'utc_offset_ms': str(clock.offset_ms),
            'infer_clear_alarms_python': str(infer_clear_alarms),
            'edge_tol_ms': str(EDGE_TOL_MS), 'match_tol_ms': str(MATCH_TOL_MS)}

    manifest = json.loads((src / 'manifest.json').read_text(encoding='utf-8'))
    by_rel = {f['path']: f for f in manifest['files']}

    def add_source(name, device, kind, rel, used, note=''):
        f = by_rel.get(rel, {})
        m.execute('INSERT INTO sources VALUES (?,?,?,?,?,?,?,?)',
                  (name, device, kind, rel, f.get('sha256'), f.get('bytes'),
                   used, note))

    # ---- 1. stores ---------------------------------------------------------
    stores: dict[str, list[tuple]] = {}
    for dev in ('phone', 'windows'):
        rows, lt, alarms = load_store(src / dev / 'battery_intervals.db', clock)
        stores[dev] = rows
        for r in lt:
            m.execute('INSERT INTO lifetime_before VALUES (?,?,?,?,?,?,?)',
                      (dev, *r))
        for a in alarms:
            m.execute('INSERT INTO alarm_events_src VALUES (?,?)',
                      (dev, json.dumps(a)))
        add_source(f'{dev}_store', dev, 'interval store',
                   f'{dev}/battery_intervals.db', 1,
                   f'{len(rows)} rows, {len(alarms)} alarm events')
    # Earlier pull and the Python text logs: kept, not merged (verified).
    for rel, f in by_rel.items():
        if rel.startswith('old-pull-20260924/'):
            newer = by_rel.get(rel.split('/', 1)[1])
            if newer and newer['sha256'] == f['sha256']:
                note = 'byte-identical to the 14:58 pull; not merged'
            elif newer and rel.endswith('.log'):
                a = (src / rel).read_bytes()
                b = (src / newer['path']).read_bytes()
                note = ('strict prefix of the 14:58 pull; not merged'
                        if b.startswith(a) else
                        'DIFFERS from the 14:58 pull (not a prefix); not merged')
            else:
                note = 'older prefs snapshot; not merged'
            add_source(rel, rel.split('/')[1], 'earlier pull', rel, 0, note)

    # ---- 2. replays ---------------------------------------------------------
    replays: dict[str, Replay] = {}
    for dev in ('phone', 'windows'):
        replays[dev] = replay_raw_log(src / dev / 'battery_raw.log', dev, clock,
                                      'hybrid')
        add_source(f'{dev}_raw', dev, 'raw log', f'{dev}/battery_raw.log', 1,
                   f"{replays[dev].stats['notifications']} notifications")
    replays['python'] = replay_python_db(src / 'python' / 'battery.db', clock,
                                         infer_clear_alarms)
    add_source('python_db', 'python', 'python tool frames',
               'python/battery.db', 1,
               f"{replays['python'].stats['frames']} frames")
    py_log_check = check_python_text_logs(src / 'python', clock)
    for rel, f in by_rel.items():
        if rel.startswith('python/') and rel != 'python/battery.db':
            add_source(rel, 'python', 'python tool text log', rel, 0,
                       py_log_check.get(rel.split('/')[1],
                                        'console/fleet log; no frame bytes'))
    for dev, rp in replays.items():
        for k, v in sorted(rp.stats.items()):
            m.execute('INSERT INTO replay_stats VALUES (?,?,?)', (dev, k, v))
        for k, v in sorted(getattr(rp, 'early_notes', {}).items()):
            m.execute('INSERT INTO replay_stats VALUES (?,?,?)',
                      (dev, 'early ' + k, v))
        for ms, serial, label, hx in rp.unpaired:
            sig = int('20 1c 20 1e' in hx or _is_demo_all(hx))
            m.execute('INSERT INTO unpaired_decoded VALUES (?,?,?,?,?,?,?)',
                      (dev, ms, clock.fmt(ms), serial, label, hx, sig))
        for serial, times in rp.frame_times.items():
            per_day = Counter(clock.day(t) for t in times)
            hs_day = Counter(clock.day(t) for t in rp.handshakes.get(serial, []))
            for day in sorted(set(per_day) | set(hs_day)):
                m.execute('INSERT INTO contact_daily VALUES (?,?,?,?,?)',
                          (dev, serial, day, hs_day.get(day, 0),
                           per_day.get(day, 0)))
        m.executemany('INSERT INTO raw_log_activity VALUES (?,?,?,?,?)',
                      [(dev, a, b, clock.fmt(a), clock.fmt(b))
                       for a, b in rp.activity])
        m.executemany('INSERT INTO link_events VALUES (?,?,?,?)',
                      [(dev, serial, t, 'handshake')
                       for serial, times in rp.handshakes.items()
                       for t in times])
        for serial, times in rp.handshakes.items():
            if serial in rp.frame_times:
                continue
            for day, n in sorted(Counter(clock.day(t) for t in times).items()):
                m.execute('INSERT INTO contact_daily VALUES (?,?,?,?,?)',
                          (dev, serial, day, n, 0))
    derived = {dev: rp.rows() for dev, rp in replays.items()}

    # ---- 3. demo windows (per device, from the demo-only serials) ----------
    demo_spans: dict[str, list[list[int]]] = {}
    for dev in ('phone', 'windows'):
        rows = stores[dev]
        spans = demo_windows_for(rows)
        demo_spans[dev] = spans
        starts = [s for s, _ in spans]
        for s, e in spans:
            inside = [r for r in rows if s - EDGE_TOL_MS <= r[7] <= e + EDGE_TOL_MS]
            demo_t = sorted({r[7] for r in inside if r[1] in DEMO_ONLY_SERIALS})
            aa_t = sorted({r[7] for r in inside if r[1] == 'JS-2C14AA'})
            near = sum(1 for t in aa_t if _count_between(demo_t, t - 20, t + 20))
            synth = sum(1 for r in inside if r[1] == 'JS-2C14AA' and
                        (r[2], r[3]) in DEMO_SIGNATURE)
            m.execute('INSERT INTO demo_windows VALUES (?,?,?,?,?,?,?,?,?,?)', (
                dev, s, e, clock.fmt(s), clock.fmt(e),
                sum(1 for r in inside if r[1] in DEMO_ONLY_SERIALS),
                sum(1 for r in inside if r[1] in REAL_SERIALS),
                len(aa_t), near, synth))
        demo_spans[dev + '_starts'] = starts
        # The synthetic values never occur in a real (non-window) row.
        meta[f'{dev}_signature_rows_outside_demo_windows'] = str(sum(
            1 for r in rows if r[1] in REAL_SERIALS
            and (r[2], r[3]) in DEMO_SIGNATURE
            and not any(a - EDGE_TOL_MS <= r[7] <= b + EDGE_TOL_MS
                        for a, b in spans)))

    def is_demo(dev: str, serial: str, start_ms: int) -> bool:
        if serial in DEMO_ONLY_SERIALS:
            return True
        spans = demo_spans.get(dev, [])
        starts = demo_spans.get(dev + '_starts', [])
        i = bisect.bisect_right(starts, start_ms + EDGE_TOL_MS) - 1
        return i >= 0 and spans[i][0] - EDGE_TOL_MS <= start_ms <= \
            spans[i][1] + EDGE_TOL_MS

    # ---- 4. insert store rows (unchanged, flagged) --------------------------
    for dev in ('phone', 'windows'):
        batch = []
        for (rid, serial, metric, vn, vt, st, et, s_ms, e_ms) in stores[dev]:
            demo = int(is_demo(dev, serial, s_ms))
            batch.append((dev, f'{dev}_store', rid, serial, metric, vn, vt,
                          st, et, s_ms, e_ms, demo, 0, 0,
                          'demo-mode row (#115)' if demo else None))
        m.executemany(
            'INSERT INTO readings (device, source, orig_id, serial, metric, '
            'value_num, value_text, start_time, end_time, start_ms, end_ms, '
            'demo, backfilled, shadow, note) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'
            '?,?,?)', batch)

    # ---- 5. backfill: derived rows where the device's own store has none ----
    for dev in ('phone', 'windows', 'python'):
        drows = derived[dev]
        store_rows = stores.get(dev, [])
        by_serial_store = defaultdict(list)
        for r in store_rows:
            by_serial_store[r[1]].append(r)
        by_serial_der = defaultdict(list)
        for r in drows:
            by_serial_der[r.serial].append(r)
        batch = []
        dbatch = []
        for serial, rows in by_serial_der.items():
            srows = by_serial_store.get(serial, [])
            spol = br.GapPolicy(sorted(
                (r[7], r[3]) for r in srows if r[2] == 'sampleIntervalS'))
            cover = merge_spans([(r[7], r[8]) for r in srows], policy=spol)
            wide = merge_spans([(s - EDGE_TOL_MS, e + EDGE_TOL_MS)
                                for s, e in cover], gap_ms=0)
            for r in rows:
                pieces = subtract_spans([[r.start_ms, r.end_ms]], wide)
                in_store = int(not pieces)
                dbatch.append((dev, serial, r.metric, r.value_num, r.value_text,
                               clock.fmt(r.start_ms), clock.fmt(r.end_ms),
                               r.start_ms, r.end_ms, in_store))
                if serial not in REAL_SERIALS:
                    continue      # a raw-log demo pack is never backfilled
                for s, e in pieces:
                    clipped = (s, e) != (r.start_ms, r.end_ms)
                    note = f'derived from {dev} frames (bms_replay)'
                    if dev == 'python' and r.metric == 'flags' and \
                            infer_clear_alarms:
                        note += '; current/voltage alarm taken as clear'
                    if clipped:
                        note += (f'; clipped to the part outside the store '
                                 f'(row {clock.fmt(r.start_ms)} .. '
                                 f'{clock.fmt(r.end_ms)})')
                    batch.append((dev, 'python_db' if dev == 'python'
                                  else f'{dev}_raw', None, serial, r.metric,
                                  r.value_num, r.value_text, clock.fmt(s),
                                  clock.fmt(e), s, e, 0, 1, 0, note))
        m.executemany('INSERT INTO derived_readings VALUES (?,?,?,?,?,?,?,?,?,?)',
                      dbatch)
        m.executemany(
            'INSERT INTO readings (device, source, orig_id, serial, metric, '
            'value_num, value_text, start_time, end_time, start_ms, end_ms, '
            'demo, backfilled, shadow, note) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'
            '?,?,?)', batch)
    m.executescript(VIEWS)

    # ---- 6. overlaps between devices -> shadow ------------------------------
    resolve_overlaps(m, clock, replays)

    # ---- 7. validation ------------------------------------------------------
    for dev in ('phone', 'windows'):
        validate_device(m, clock, dev, stores[dev], derived[dev],
                        lambda s, t, d=dev: is_demo(d, s, t),
                        replays[dev].handshakes)

    # ---- 8. lifetime totals, coverage, known batteries ----------------------
    recompute_lifetime(m, clock)
    store_lifetime_checks(m, clock, stores, demo_fn=is_demo)
    observed_until = max(getattr(replays[d], 'last_line_ms', 0)
                         for d in ('phone', 'windows'))
    meta['observed_until'] = clock.fmt(observed_until)
    coverage(m, clock, observed_until)
    known_batteries(m, clock, src)
    for k, v in meta.items():
        m.execute('INSERT INTO meta VALUES (?,?)', (k, v))
    m.commit()
    m.close()
    return master_path


def _is_demo_all(hx: str) -> bool:
    """A demo ALL_DATA frame: chip byte (p7) = 24 and cycles (p18,p19) = 7."""
    b = hx.split(' ')
    return (len(b) == 26 and b[:2] == ['a2', '57'] and b[9] == '18'
            and b[20:22] == ['07', '00'])


def check_python_text_logs(pydir: Path, clock: Clock) -> dict[str, str]:
    """Are the per-pack .log files subsets of battery.db? (by time + bytes)"""
    db = sqlite3.connect(f'file:{pydir / "battery.db"}?mode=ro', uri=True)
    out = {}
    try:
        for serial in REAL_SERIALS:
            f = pydir / f'{serial}.log'
            if not f.is_file():
                continue
            have_ms = set()
            have_s = set()
            for ts, data in db.execute(
                    "SELECT ts, data FROM battery_frames WHERE serial = ? AND "
                    "frame LIKE 'RX_%'", (serial,)):
                raw = json.loads(data).get('_raw', '')
                have_ms.add((ts, raw))
                have_s.add((ts[:19], raw))
            n = missing = 0
            day = None
            for line in f.open(encoding='utf-8', errors='replace'):
                mm = re.match(r'^# .*?(\d{4}-\d\d-\d\d) \d\d:', line)
                if mm:
                    day = mm.group(1)
                    continue
                mm = re.match(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\s+RX_\S+'
                              r'\s+((?:[0-9a-f]{2} )+)', line)
                if mm:
                    n += 1
                    missing += (mm.group(1), mm.group(2).strip()) not in have_ms
                    continue
                mm = re.match(r'^(\d\d:\d\d:\d\d)\s+RX_\S+\s+((?:[0-9a-f]{2} )+)',
                              line)
                if mm and day:
                    n += 1
                    missing += (f'{day} {mm.group(1)}',
                                mm.group(2).strip()) not in have_s
            out[f.name] = (f'{n} RX lines, {missing} not in battery.db'
                           + ('; subset of battery.db, not merged'
                              if missing == 0 else '; NOT a subset'))
    finally:
        db.close()
    return out


def resolve_overlaps(m: sqlite3.Connection, clock: Clock,
                     replays: dict[str, Replay]) -> None:
    """Where two devices hold non-demo readings for one pack at the same time,
    the device holding the live link wins; the other's rows become `shadow`.

    "Holding the link" is judged from frames: the device that received more
    frames for the pack inside the overlap (a second central that also got
    frames would be a co-holder; ties go to the device whose link started
    first)."""
    for serial in REAL_SERIALS:
        cover = {}
        for dev in DEVICES:
            rows = m.execute(
                'SELECT start_ms, end_ms, metric, value_num FROM readings '
                'WHERE serial = ? AND device = ? AND demo = 0', (serial, dev)
            ).fetchall()
            si = sorted((r[0], r[3]) for r in rows if r[2] == 'sampleIntervalS')
            cover[dev] = merge_spans([(r[0], r[1]) for r in rows],
                                     policy=br.GapPolicy(si))
        devs = [d for d in DEVICES if cover[d]]
        for i, a in enumerate(devs):
            for b in devs[i + 1:]:
                for s, e in intersect_spans(cover[a], cover[b]):
                    fa = _count_between(replays[a].frame_times.get(serial, []),
                                        s, e)
                    fb = _count_between(replays[b].frame_times.get(serial, []),
                                        s, e)
                    if fa != fb:
                        winner, rule = (a, b) if fa > fb else (b, a), \
                            f'more frames in the overlap ({max(fa, fb)} vs ' \
                            f'{min(fa, fb)})'
                    else:
                        sa = _span_start(cover[a], s)
                        sb = _span_start(cover[b], s)
                        winner = (a, b) if sa <= sb else (b, a)
                        rule = 'equal frames; the earlier link holds'
                    win, lose = winner
                    cur = m.execute(
                        'UPDATE readings SET shadow = 1, note = COALESCE(note '
                        "|| '; ', '') || ? WHERE serial = ? AND device = ? AND "
                        'demo = 0 AND start_ms >= ? AND start_ms <= ?',
                        (f'overlap with {win}: shadow', serial, lose, s, e))
                    m.execute('INSERT INTO overlaps VALUES (?,?,?,?,?,?,?,?,?)',
                              (serial, s, e, clock.fmt(s), clock.fmt(e),
                               f'{a}+{b}', win, rule, cur.rowcount))


def _count_between(times: list[int], s: int, e: int) -> int:
    return bisect.bisect_right(times, e) - bisect.bisect_left(times, s)


def _span_start(spans, t):
    for s, e in spans:
        if s <= t <= e:
            return s
    return t


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def validate_device(m: sqlite3.Connection, clock: Clock, dev: str,
                    store_rows: list[tuple], derived_rows: list[br.Row],
                    is_demo, handshakes: dict[str, list[int]]) -> None:
    """Compare the rows a device's app stored with the rows re-derived from
    the same device's raw log, inside the windows where both exist.

    A store row is included when it STARTS inside such a window (a row that
    began before the raw log was switched on cannot be re-derived); derived
    rows are included when they touch a window."""
    st_by = defaultdict(list)
    for r in store_rows:
        if r[1] in REAL_SERIALS and not is_demo(r[1], r[7]):
            st_by[(r[1], r[2])].append(r)
    de_by = defaultdict(list)
    for r in derived_rows:
        if r.serial in REAL_SERIALS:
            de_by[(r.serial, r.metric)].append(r)
    for serial in REAL_SERIALS:
        srows = [r for (s, _), rs in st_by.items() if s == serial for r in rs]
        drows = [r for (s, _), rs in de_by.items() if s == serial for r in rs]
        if not srows or not drows:
            continue
        spol = br.GapPolicy(sorted((r[7], r[3]) for r in srows
                                   if r[2] == 'sampleIntervalS'))
        dpol = policy_from_rows(drows)
        sc = merge_spans([(r[7], r[8]) for r in srows], policy=spol)
        dc = merge_spans([(r.start_ms, r.end_ms) for r in drows], policy=dpol)
        win = intersect_spans(sc, dc)
        if not win:
            continue
        for s, e in win:
            m.execute('INSERT INTO validation_windows VALUES (?,?,?,?,?,?)',
                      (dev, serial, s, e, clock.fmt(s), clock.fmt(e)))
        wstarts = [s for s, _ in win]
        # "Link start": a handshake, or a window start (the raw log was
        # switched on, or began, in the middle of a link).
        hs = sorted(set(handshakes.get(serial, [])) | set(wstarts))
        metrics = sorted({k[1] for k in st_by if k[0] == serial}
                         | {k[1] for k in de_by if k[0] == serial})
        # #114: the same comparison with temp2/temp3 SWAPPED on the derived
        # side (stored temp2 vs byte p2) tests the byte mapping.
        pairs = [(mt, mt) for mt in metrics] + [('temp2', 'temp3'),
                                                  ('temp3', 'temp2')]
        for metric, dmetric in pairs:
            sr = [r for r in st_by.get((serial, metric), [])
                  if in_spans(win, wstarts, r[7]) is not None]
            dr = [r for r in de_by.get((serial, dmetric), [])
                  if overlaps_spans(win, wstarts, r.start_ms, r.end_ms)]
            res = compare_rows(sr, dr, hs, max_examples=0
                               if metric != dmetric else 6)
            if metric != dmetric:
                metric = f'{metric} vs derived {dmetric} (swap test)'
            m.execute(
                'INSERT INTO validation_metric VALUES '
                '(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                (dev, serial, metric, len(sr), len(dr), res['start'],
                 res['exact'], res['end_store_earlier'], res['end_store_later'],
                 res['link_rows'], res['link_start'], res['point_agree'],
                 res['point_checked'], res['derived_unmatched'],
                 res['derived_unmatched_link']))
            for kind, srow, drow in res['examples']:
                m.execute(
                    'INSERT INTO validation_examples VALUES '
                    '(?,?,?,?,?,?,?,?,?,?)',
                    (dev, serial, metric, kind,
                     clock.fmt(srow[7]) if srow else None,
                     clock.fmt(srow[8]) if srow else None,
                     _val(srow[3], srow[4]) if srow else None,
                     clock.fmt(drow.start_ms) if drow else None,
                     clock.fmt(drow.end_ms) if drow else None,
                     _val(drow.value_num, drow.value_text) if drow else None))


def _val(num, text):
    return text if text is not None else (None if num is None else repr(num))


def _same(a_num, a_text, b_num, b_text) -> bool:
    if a_text is not None or b_text is not None:
        return a_text == b_text
    if a_num is None or b_num is None:
        return a_num == b_num
    return abs(a_num - b_num) <= 1e-9


def near_link_start(hs: list[int], t: int) -> bool:
    """True when t falls in the first LINK_START_MS of a link (handshake)."""
    i = bisect.bisect_right(hs, t) - 1
    return i >= 0 and t - hs[i] < LINK_START_MS


def compare_rows(store: list[tuple], derived: list[br.Row],
                 handshakes: list[int] | None = None,
                 tol: int = MATCH_TOL_MS, max_examples: int = 6) -> dict:
    """Pair store rows (tuples as loaded) with derived rows (one metric).

    start: same value and start within `tol`; exact: the end too. Rows that
    start in a link's first seconds are counted apart (`link_*`): there the
    app's state may be carried over from the previous link, seeded from the
    last-known record, or empty, and the raw log does not say which."""
    hs = handshakes or []
    derived = sorted(derived, key=lambda r: r.start_ms)
    dstarts = [r.start_ms for r in derived]
    used = [False] * len(derived)
    res = Counter()
    examples = []
    kinds_seen = Counter()

    def example(kind, s, d):
        if kinds_seen[kind] < max_examples:
            kinds_seen[kind] += 1
            examples.append((kind, s, d))

    for r in store:
        s_ms, e_ms = r[7], r[8]
        link = near_link_start(hs, s_ms)
        res['link_rows'] += link
        lo = bisect.bisect_left(dstarts, s_ms - tol)
        hi = bisect.bisect_right(dstarts, s_ms + tol)
        best = None
        for k in range(lo, hi):
            d = derived[k]
            if not used[k] and _same(r[3], r[4], d.value_num, d.value_text):
                if best is None or abs(d.start_ms - s_ms) < \
                        abs(derived[best].start_ms - s_ms):
                    best = k
        if best is not None:
            used[best] = True
            res['start'] += 1
            res['link_start'] += link
            de = derived[best].end_ms
            if abs(de - e_ms) <= tol:
                res['exact'] += 1
            elif e_ms < de:
                res['end_store_earlier'] += 1
                example('end: store earlier', r, derived[best])
            else:
                res['end_store_later'] += 1
                example('end: store later', r, derived[best])
        # the derived value in effect at the middle of the store row
        mid = (s_ms + e_ms) // 2
        i = bisect.bisect_right(dstarts, mid + tol) - 1
        hit = None
        while i >= 0 and derived[i].start_ms >= mid - 6 * 3_600_000:
            d = derived[i]
            if d.start_ms - tol <= mid <= d.end_ms + tol:
                hit = d
                break
            i -= 1
        res['point_checked'] += 1
        if hit is not None and _same(r[3], r[4], hit.value_num, hit.value_text):
            res['point_agree'] += 1
        if best is None:
            example(('link start: ' if link else '')
                    + ('no derived row' if hit is None else 'value/start differs'),
                    r, hit)
    for k, d in enumerate(derived):
        if not used[k]:
            res['derived_unmatched'] += 1
            link = near_link_start(hs, d.start_ms)
            res['derived_unmatched_link'] += link
            example('derived only' + (' (link start)' if link else ''), None, d)
    out = dict(res)
    for key in ('start', 'exact', 'end_store_earlier', 'end_store_later',
                'link_rows', 'link_start', 'point_agree', 'point_checked',
                'derived_unmatched', 'derived_unmatched_link'):
        out.setdefault(key, 0)
    out['examples'] = examples
    return out


# ---------------------------------------------------------------------------
# lifetime totals
# ---------------------------------------------------------------------------

def _rows_for(m, serial, metric, where='demo = 0 AND shadow = 0'):
    return [br.Row(serial, metric, r[0], None, r[1], r[2]) for r in m.execute(
        f'SELECT value_num, start_ms, end_ms, source FROM readings WHERE '
        f'serial = ? AND metric = ? AND {where} ORDER BY start_ms, rid',
        (serial, metric))]


def per_row_ah(rows: list[br.Row], policy: br.GapPolicy) -> list[tuple[float,
                                                                         float]]:
    """(charge, discharge) contribution of each row, exactly as
    integrate_current_rows splits it (watermark 0)."""
    out = []
    for k, iv in enumerate(rows):
        i = iv.value_num
        if k + 1 < len(rows):
            nxt = rows[k + 1].start_ms
            hold_end = min(nxt, iv.end_ms + policy.gap_for(iv.end_ms, nxt))
        else:
            hold_end = iv.end_ms
        dur_s = (hold_end - iv.start_ms) / 1000.0
        if i is None or dur_s <= 0 or i == 0:
            out.append((0.0, 0.0))
            continue
        ah = abs(i) * dur_s / 3600.0
        out.append((ah, 0.0) if i > 0 else (0.0, ah))
    return out


def recompute_lifetime(m: sqlite3.Connection, clock: Clock) -> None:
    """Recompute each real pack's lifetime totals from the clean rows (all
    devices, non-demo, non-shadow) with the app's integrator, one fold per
    session (a run of abutting rows), every fold recorded (#97)."""
    for serial in REAL_SERIALS:
        rows = _rows_for(m, serial, 'packI')
        if not rows:
            continue
        srcs = [r[0] for r in m.execute(
            'SELECT source FROM readings WHERE serial = ? AND metric = ? AND '
            'demo = 0 AND shadow = 0 ORDER BY start_ms, rid', (serial, 'packI'))]
        si = _rows_for(m, serial, 'sampleIntervalS')
        policy = br.GapPolicy([(r.start_ms, r.value_num) for r in si])
        full = m.execute(
            "SELECT value_num FROM readings WHERE serial = ? AND metric = "
            "'fullAh' AND demo = 0 AND shadow = 0 AND value_num IS NOT NULL "
            "ORDER BY end_ms DESC LIMIT 1", (serial,)).fetchone()
        full_ah = full[0] if full else None
        contrib = per_row_ah(rows, policy)
        # runs: consecutive rows that abut per the policy
        runs, cur = [], None
        for k, r in enumerate(rows):
            if cur is not None and policy.abuts(rows[cur[-1]].end_ms, r.start_ms):
                cur.append(k)
            else:
                cur = [k]
                runs.append(cur)
        cc = cd = 0.0
        for n, run in enumerate(runs, 1):
            c = sum(contrib[k][0] for k in run)
            d = sum(contrib[k][1] for k in run)
            cc += c
            cd += d
            efc_add = (c + d) / full_ah if full_ah else 0.0
            a, b = rows[run[0]].start_ms, max(rows[k].end_ms for k in run)
            m.execute('INSERT INTO lifetime_folds VALUES (?,?,?,?,?,?,?,?,?,?,?,'
                      '?,?,?)',
                      (serial, n, a, b, clock.fmt(a), clock.fmt(b), len(run),
                       ','.join(sorted({srcs[k] for k in run})), c, d, efc_add,
                       cc, cd, (cc + cd) / full_ah if full_ah else 0.0))
        total_c, total_d, newest = br.integrate_current_rows(rows, policy=policy)
        m.execute('INSERT INTO lifetime_after VALUES (?,?,?,?,?,?,?,?)',
                  (serial, total_c, total_d,
                   (total_c + total_d) / full_ah if full_ah else 0.0, full_ah,
                   clock.fmt(newest), newest, len(runs)))


def store_lifetime_checks(m: sqlite3.Connection, clock: Clock,
                          stores: dict[str, list[tuple]], demo_fn) -> None:
    """Explain each stored per-device total: recompute it from that device's
    own store rows up to its watermark (all rows, as the app did), and the
    demo-only share of it."""
    for dev, rows in stores.items():
        for serial, c0, d0, _efc, _t, wm in m.execute(
                'SELECT serial, total_charge_ah, total_discharge_ah, total_efc,'
                ' aggregated_up_to, aggregated_up_to_ms FROM lifetime_before '
                'WHERE device = ?', (dev,)).fetchall():
            def rows_of(metric, keep=lambda r: True):
                return [br.Row(r[1], r[2], r[3], r[4], r[7], r[8])
                        for r in sorted(rows, key=lambda r: (r[7], r[0]))
                        if r[1] == serial and r[2] == metric and keep(r)]
            pol = br.GapPolicy([(r.start_ms, r.value_num)
                                for r in rows_of('sampleIntervalS')])
            cur = [r for r in rows_of('packI') if r.end_ms <= (wm or 0)]
            c, d, _ = br.integrate_current_rows(cur, policy=pol)
            m.execute('INSERT INTO lifetime_check VALUES (?,?,?,?,?,?,?)',
                      (dev, serial, wm, 'store rows up to its watermark',
                       c, d, 'app integrator, all rows (as the app counted)'))
            real = [r for r in cur if not demo_fn(dev, serial, r.start_ms)]
            if len(real) != len(cur):
                c, d, _ = br.integrate_current_rows(real, policy=pol)
                m.execute('INSERT INTO lifetime_check VALUES (?,?,?,?,?,?,?)',
                          (dev, serial, wm, 'same, demo rows removed', c, d,
                           f'{len(cur) - len(real)} demo packI rows removed'))
            allrows = rows_of('packI')
            store_row_diffs(m, clock, dev, serial, allrows, pol)
            c, d, _ = br.integrate_current_rows(allrows, policy=pol)
            m.execute('INSERT INTO lifetime_check VALUES (?,?,?,?,?,?,?)',
                      (dev, serial, allrows[-1].end_ms if allrows else None,
                       'store rows, all (past the watermark too)', c, d,
                       'what the device would show after its next fold'))


def store_row_diffs(m, clock, dev, serial, store_rows, store_policy) -> None:
    """Store rows whose Ah differs between the store alone and the master
    (the hold to the NEXT reading changes when the master has a reading the
    store lacks). Recorded with the next master reading as the reason."""
    master = m.execute(
        "SELECT value_num, start_ms, end_ms, source FROM readings WHERE "
        "serial = ? AND metric = 'packI' AND demo = 0 AND shadow = 0 "
        'ORDER BY start_ms, rid', (serial,)).fetchall()
    mrows = [br.Row(serial, 'packI', r[0], None, r[1], r[2]) for r in master]
    mpol = br.GapPolicy([(r.start_ms, r.value_num)
                         for r in _rows_for(m, serial, 'sampleIntervalS')])
    mc = per_row_ah(mrows, mpol)
    idx = {(r.start_ms, r.value_num): k for k, r in enumerate(mrows)}
    sc = per_row_ah(store_rows, store_policy)
    for r, (c, d) in zip(store_rows, sc):
        k = idx.get((r.start_ms, r.value_num))
        if k is None:
            continue
        diff = (mc[k][0] + mc[k][1]) - (c + d)
        if abs(diff) >= 0.001:
            nxt = master[k + 1] if k + 1 < len(master) else None
            m.execute('INSERT INTO lifetime_row_diffs VALUES (?,?,?,?,?,?,?)',
                      (dev, serial, clock.fmt(r.start_ms), r.value_num, c + d,
                       mc[k][0] + mc[k][1],
                       f'{nxt[3]} at {clock.fmt(nxt[1])}' if nxt else None))


# ---------------------------------------------------------------------------
# coverage + gaps
# ---------------------------------------------------------------------------

def coverage(m: sqlite3.Connection, clock: Clock, observed_until: int,
             min_gap_min: float = 30) -> None:
    """Hours covered per pack, day and source (clean rows), and the gaps
    longer than `min_gap_min` that no source covers, including the stretch
    from a pack's last reading to the end of the raw logs (the pull)."""
    for serial in REAL_SERIALS:
        rows = m.execute(
            'SELECT source, start_ms, end_ms, metric, value_num FROM readings '
            'WHERE serial = ? AND demo = 0 AND shadow = 0', (serial,)).fetchall()
        if not rows:
            continue
        si = sorted((r[1], r[4]) for r in rows if r[3] == 'sampleIntervalS')
        pol = br.GapPolicy(si)
        by_src = defaultdict(list)
        for r in rows:
            by_src[r[0]].append((r[1], r[2]))
        allspans = merge_spans([(r[1], r[2]) for r in rows], policy=pol)
        lo, hi = allspans[0][0], allspans[-1][1]
        days = []
        d = clock.day(lo)
        while clock.day_start(d) <= hi:
            days.append(d)
            d = (dt.date.fromisoformat(d) + dt.timedelta(days=1)).isoformat()
        for src, spans in sorted(by_src.items()) + [('ALL', None)]:
            merged = allspans if spans is None else merge_spans(spans, policy=pol)
            for day in days:
                a = clock.day_start(day)
                b = a + 86_400_000
                secs = sum(max(0, min(e, b) - max(s, a))
                           for s, e in merged) / 1000
                if secs > 0 or src == 'ALL':
                    m.execute('INSERT INTO coverage_daily VALUES (?,?,?,?)',
                              (serial, day, src, secs))
        bounds = [(e0, s1) for (_s0, e0), (s1, _e1)
                  in zip(allspans, allspans[1:])]
        bounds.append((hi, max(hi, observed_until)))
        for k, (e0, s1) in enumerate(bounds):
            if s1 - e0 > min_gap_min * 60_000:
                trailing = k == len(bounds) - 1
                ctx = gap_context(m, serial, e0, s1 + (15_000 if trailing
                                                        else 0))
                if trailing:
                    ctx = 'after the last reading, up to the pull; ' + ctx
                m.execute('INSERT INTO unobserved_gaps VALUES (?,?,?,?,?,?,?)',
                          (serial, e0, s1, clock.fmt(e0), clock.fmt(s1),
                           (s1 - e0) / 60_000, ctx))


def gap_context(m, serial, a, b) -> str:
    """What the devices did for this pack inside an unobserved gap: link
    attempts (handshakes) that produced no stored or derived reading."""
    parts = []
    # The handshake that opens the next session (just before b) is not "in"
    # the gap.
    for dev, n in m.execute(
            'SELECT device, COUNT(*) FROM link_events WHERE serial = ? AND '
            'at_ms > ? AND at_ms < ? GROUP BY device',
            (serial, a, b - 15_000)):
        parts.append(f'{dev}: {n} handshakes, no telemetry')
    for dev in ('phone', 'windows'):
        on = sum(max(0, min(e, b) - max(s, a)) for s, e in m.execute(
            'SELECT from_ms, to_ms FROM raw_log_activity WHERE device = ? AND '
            'to_ms >= ? AND from_ms <= ?', (dev, a, b)))
        if on >= 60_000:
            parts.append(f'{dev} raw log running {on / 60_000:.0f} of '
                         f'{(b - a) / 60_000:.0f} min')
    return '; '.join(parts) or 'no raw log running, no link attempt logged'


# ---------------------------------------------------------------------------
# known batteries (#110)
# ---------------------------------------------------------------------------

def read_aliases(src: Path) -> dict[str, str]:
    aliases: dict[str, str] = {}
    xml = src / 'phone' / 'FlutterSharedPreferences.xml'
    if xml.is_file():
        import html
        mm = re.search(r'name="flutter\.battery_aliases_v1">([^<]*)<',
                       xml.read_text(encoding='utf-8'))
        if mm:
            aliases.update(json.loads(html.unescape(mm.group(1))))
    js = src / 'windows' / 'shared_preferences.json'
    if js.is_file():
        d = json.loads(js.read_text(encoding='utf-8'))
        raw = d.get('flutter.battery_aliases_v1')
        if isinstance(raw, str):
            for k, v in json.loads(raw).items():
                aliases.setdefault(k, v)
    return aliases


def known_batteries(m: sqlite3.Connection, clock: Clock, src: Path) -> None:
    aliases = read_aliases(src)
    serials = [r[0] for r in m.execute(
        'SELECT DISTINCT serial FROM readings ORDER BY serial')]
    for serial in serials:
        demo = int(serial in DEMO_ONLY_SERIALS)
        where = 'serial = ?' + ('' if demo else ' AND demo = 0 AND shadow = 0')
        first, last = m.execute(
            f'SELECT MIN(start_ms), MAX(end_ms) FROM readings WHERE {where}',
            (serial,)).fetchone()

        def last_val(metric):
            r = m.execute(
                f'SELECT value_num, value_text FROM readings WHERE {where} AND '
                'metric = ? ORDER BY end_ms DESC LIMIT 1',
                (serial, metric)).fetchone()
            return r
        fw = last_val('firmware')
        devs = ','.join(r[0] for r in m.execute(
            f'SELECT DISTINCT device FROM readings WHERE {where} ORDER BY 1',
            (serial,)))
        m.execute('INSERT INTO known_batteries VALUES (?,?,?,?,?,?,?,?,?,?,?)', (
            serial, aliases.get(serial), demo, clock.fmt(first),
            clock.fmt(last), *(v[0] if v else None for v in (
                last_val('soc'), last_val('packV'), last_val('remAh'),
                last_val('fullAh'))),
            fw[1] if fw else None, devs))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_build(args: argparse.Namespace) -> int:
    clock = Clock(args.utc_offset)
    p = build(Path(args.out), clock, not args.no_infer_clear_alarms)
    print(f'-> {p}')
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    import clean_report
    p = clean_report.write_report(Path(args.out), Clock(args.utc_offset))
    print(f'-> {p}')
    return 0


def cmd_all(args: argparse.Namespace) -> int:
    for fn in (cmd_freeze, cmd_build, cmd_report):
        rc = fn(args)
        if rc:
            return rc
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    def common(p, freeze=False):
        p.add_argument('--out', required=True,
                       help='output folder, e.g. logs/clean-20260924')
        p.add_argument('--utc-offset', type=float, default=8.0,
                       help='hours east of UTC for local timestamps (AWST 8)')
        if freeze:
            p.add_argument('--pull', required=True,
                           help='pull folder with phone/ and windows/')
            p.add_argument('--old-pull', help='an earlier pull, kept as-is')
            p.add_argument('--python-logs', required=True,
                           help='awto-sphere/python_ble/logs')
        p.add_argument('--no-infer-clear-alarms', action='store_true',
                       help='Python period: do not treat unlogged '
                            'current/voltage alarms as clear')

    f = sub.add_parser('freeze', help='copy inputs + SHA-256 manifest')
    common(f, freeze=True)
    f.set_defaults(fn=cmd_freeze)
    b = sub.add_parser('build', help='build master.db from the frozen sources')
    common(b)
    b.set_defaults(fn=cmd_build)
    r = sub.add_parser('report', help='write REPORT.md from master.db')
    common(r)
    r.set_defaults(fn=cmd_report)
    a = sub.add_parser('all', help='freeze + build + report')
    common(a, freeze=True)
    a.set_defaults(fn=cmd_all)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == '__main__':
    raise SystemExit(main())
