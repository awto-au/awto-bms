#!/usr/bin/env python3
"""Build per-device import zips from the signed-off master history (#119).

Input: the #116 `master.db` (its `clean_readings` view only: demo rows and
shadow rows are left out, backfilled rows and the inferred all-clear alarm
rows of the Python-tool period are kept), plus, for each device, its CURRENT
interval store and preferences (a fresh pull, or the device's own
"Export all data" zip).

Output (in --out, which should be under the git-ignored logs/):

  awto-bms-import-phone.zip     the #104 export format (manifest.json v1,
  awto-bms-import-windows.zip   battery_intervals.db, settings.json,
                                readings.csv) that `stageImport` accepts
  battery_intervals.db          the store both zips carry
  IMPORT-REPORT.md              before/after per pack and device, the device
                                steps

The store is written at the app's CURRENT schema (BatteryLogger.schemaVersion
4, the DDL of `_onCreate`), ids 1..N in (start_ms, source order) order and
both the text and epoch-ms columns filled. `lifetime_totals` holds the clean
figures, recomputed here with the app's integrator over the same rows the
store holds; every fold is kept in the side table `import_lifetime_folds`
(#97; the app's `lifetime_totals` has no column for it). `import_provenance`
keeps each row's source and note (e.g. "current/voltage alarm taken as
clear"), `import_meta` how the file was built. The app never reads the
`import_*` tables.

Newest rows: a device keeps recording after the master was frozen. Rows in a
device's current store that the master does not hold (id beyond the store
rows the master copied) are merged in at build time, after the same demo
checks, and their Ah is folded into the totals. So: re-pull (or export) each
device right before importing and rebuild. Rows that overlap the master or
the other device's new rows stop the build (no guessing).

Settings: each zip carries THAT device's current preferences, so battery
names, the fleet list and settings stay as they are. `window_bounds_v1` is
never written. Nothing is sent to a device and nothing is deleted.

Usage (from projects/awto-bms):
    python scripts/build_import.py \\
        --master logs/clean-20260924/master.db \\
        --phone-store logs/pull-20260924-signoff/battery_intervals.db \\
        --phone-prefs logs/pull-20260924-1458/phone/FlutterSharedPreferences.xml \\
        --windows-store logs/pull-20260924-1458/windows/battery_intervals.db \\
        --windows-prefs logs/pull-20260924-1458/windows/shared_preferences.json \\
        --out logs/import-20260924
    # or, from each app's own "Export all data" zip (store + settings):
    python scripts/build_import.py --master ... \\
        --phone-export awto-bms-export-....zip \\
        --windows-export awto-bms-export-....zip --out ...
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import io
import json
import shutil
import sqlite3
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bms_replay as br  # noqa: E402
import clean_history as ch  # noqa: E402

# --- the app's export format (lib/data_export.dart) --------------------------
EXPORT_FORMAT = 'awto-bms-export'
EXPORT_FORMAT_VERSION = 1
DB_NAME = 'battery_intervals.db'
MANIFEST_NAME = 'manifest.json'
SETTINGS_NAME = 'settings.json'
CSV_NAME = 'readings.csv'
IMPORT_SKIP_PREFS = {'window_bounds_v1'}        # kImportSkipPrefs
CSV_COLS = ['serial', 'metric', 'value_num', 'value_text', 'start_time',
            'end_time', 'start_ms', 'end_ms']

# --- the app's store (lib/battery_log.dart) ----------------------------------
SCHEMA_VERSION = 4                               # BatteryLogger.schemaVersion
APP_DDL = [
    'CREATE TABLE readings ( id INTEGER PRIMARY KEY, serial TEXT NOT NULL,'
    ' metric TEXT NOT NULL, value_num REAL, value_text TEXT,'
    ' start_time TEXT NOT NULL, end_time TEXT NOT NULL, start_ms INTEGER,'
    ' end_ms INTEGER)',
    'CREATE INDEX ix_readings ON readings (serial, metric, start_time)',
    'CREATE INDEX IF NOT EXISTS ix_readings_ms ON readings '
    '(serial, metric, start_ms)',
    "CREATE VIEW IF NOT EXISTS flags_bits AS SELECT serial, start_time,"
    " end_time, (CAST(value_num AS INTEGER) >> 0) & 1 AS mos,"
    " (CAST(value_num AS INTEGER) >> 1) & 1 AS load,"
    " (CAST(value_num AS INTEGER) >> 2) & 1 AS charger,"
    " (CAST(value_num AS INTEGER) >> 3) & 1 AS chgMos,"
    " (CAST(value_num AS INTEGER) >> 4) & 1 AS disMos,"
    " (CAST(value_num AS INTEGER) >> 5) & 1 AS passiveBal,"
    " (CAST(value_num AS INTEGER) >> 6) & 1 AS sleep,"
    " (CAST(value_num AS INTEGER) >> 7) & 1 AS faultCurrent,"
    " (CAST(value_num AS INTEGER) >> 8) & 1 AS faultVoltage,"
    " (CAST(value_num AS INTEGER) >> 9) & 1 AS faultTemperature,"
    " (CAST(value_num AS INTEGER) >> 10) & 3 AS chargeState"
    " FROM readings WHERE metric = 'flags'",
    'CREATE TABLE IF NOT EXISTS lifetime_totals ( serial TEXT PRIMARY KEY,'
    ' total_charge_ah REAL NOT NULL DEFAULT 0,'
    ' total_discharge_ah REAL NOT NULL DEFAULT 0,'
    ' total_efc REAL NOT NULL DEFAULT 0, aggregated_up_to TEXT,'
    ' aggregated_up_to_ms INTEGER)',
    'CREATE TABLE IF NOT EXISTS alarm_events ( id INTEGER PRIMARY KEY,'
    ' serial TEXT NOT NULL, at_ms INTEGER NOT NULL, at_time TEXT NOT NULL,'
    ' frame TEXT NOT NULL, byte_index INTEGER NOT NULL,'
    ' bit_name TEXT NOT NULL, transition TEXT NOT NULL, from_value INTEGER,'
    ' to_value INTEGER, duration_ms INTEGER, pack_i REAL, pack_v REAL,'
    ' cell_min REAL, cell_max REAL, cell_delta REAL, temp0 INTEGER,'
    ' temp1 INTEGER, temp2 INTEGER, temp3 INTEGER, chip INTEGER, soc INTEGER,'
    ' charge_state TEXT, chg_mos INTEGER, dis_mos INTEGER,'
    ' temp_gate INTEGER, smoke_gate INTEGER, heat_gate INTEGER,'
    ' over_temp_latched INTEGER, standby_on INTEGER, last_tx_label TEXT,'
    ' last_tx_hex TEXT, since_last_tx_ms INTEGER, since_connect_ms INTEGER)',
    'CREATE INDEX IF NOT EXISTS ix_alarm_events ON alarm_events '
    '(serial, at_ms)',
]
ALARM_COLS = [
    'serial', 'at_ms', 'at_time', 'frame', 'byte_index', 'bit_name',
    'transition', 'from_value', 'to_value', 'duration_ms', 'pack_i', 'pack_v',
    'cell_min', 'cell_max', 'cell_delta', 'temp0', 'temp1', 'temp2', 'temp3',
    'chip', 'soc', 'charge_state', 'chg_mos', 'dis_mos', 'temp_gate',
    'smoke_gate', 'heat_gate', 'over_temp_latched', 'standby_on',
    'last_tx_label', 'last_tx_hex', 'since_last_tx_ms', 'since_connect_ms']

# Side tables: provenance and the folds (#97). The app never reads them.
SIDE_DDL = [
    'CREATE TABLE import_meta (key TEXT PRIMARY KEY, value TEXT)',
    'CREATE TABLE import_provenance (id INTEGER PRIMARY KEY, device TEXT,'
    ' source TEXT, master_rid INTEGER, orig_id INTEGER,'
    ' backfilled INTEGER NOT NULL DEFAULT 0, note TEXT)',
    'CREATE TABLE import_lifetime_folds (serial TEXT, fold INTEGER,'
    ' from_ms INTEGER, to_ms INTEGER, from_time TEXT, to_time TEXT,'
    ' rows INTEGER, sources TEXT, charge_ah REAL, discharge_ah REAL,'
    ' efc_added REAL, cum_charge_ah REAL, cum_discharge_ah REAL,'
    ' cum_efc REAL)',
]

DEVICES = ('phone', 'windows')
FRESH_ORDER_BASE = 10 ** 12     # fresh rows sort after master rows on a tie
AH_TOL = 1e-9


class BuildError(Exception):
    """The inputs cannot be combined without a decision; nothing written."""


# ---------------------------------------------------------------------------
# preferences
# ---------------------------------------------------------------------------

ANDROID_LIST_PREFIX = 'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu'
ANDROID_DOUBLE_PREFIX = 'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu'
ANDROID_BIGINT_PREFIX = 'VGhpcyBpcyB0aGUgcHJlZml4IGZvciBCaWdJbnRlZ2Vy'
FLUTTER_PREFIX = 'flutter.'


def _entry(t: str, v) -> dict:
    return {'t': t, 'v': v}


def prefs_from_android_xml(text: str) -> dict[str, dict]:
    """FlutterSharedPreferences.xml -> the app's settings.json encoding
    (`{key: {"t": type, "v": value}}`, keys without the `flutter.` prefix,
    as `SharedPreferences.getKeys()` returns them)."""
    root = ET.fromstring(text)
    out: dict[str, dict] = {}
    for el in root:
        name = el.get('name') or ''
        if not name.startswith(FLUTTER_PREFIX):
            continue
        key = name[len(FLUTTER_PREFIX):]
        tag = el.tag
        if tag == 'boolean':
            out[key] = _entry('bool', el.get('value') == 'true')
        elif tag in ('long', 'int'):
            out[key] = _entry('int', int(el.get('value')))
        elif tag == 'float':
            out[key] = _entry('double', float(el.get('value')))
        elif tag == 'string':
            s = el.text or ''
            if s.startswith(ANDROID_LIST_PREFIX):
                rest = s[len(ANDROID_LIST_PREFIX):]
                if not rest.startswith('!'):
                    raise BuildError(f'{key}: old binary list encoding; '
                                     'use the app export instead')
                lst = json.loads(rest[1:])
                out[key] = _entry('stringList', [str(x) for x in lst])
            elif s.startswith(ANDROID_DOUBLE_PREFIX):
                out[key] = _entry('double',
                                  float(s[len(ANDROID_DOUBLE_PREFIX):]))
            elif s.startswith(ANDROID_BIGINT_PREFIX):
                out[key] = _entry('int',
                                  int(s[len(ANDROID_BIGINT_PREFIX):], 36))
            else:
                out[key] = _entry('string', s)
        else:
            raise BuildError(f'{key}: unknown preference type <{tag}>')
    return dict(sorted(out.items()))


def prefs_from_windows_json(text: str) -> dict[str, dict]:
    """shared_preferences.json (Windows) -> settings.json encoding."""
    raw = json.loads(text)
    out: dict[str, dict] = {}
    for name, v in raw.items():
        if not name.startswith(FLUTTER_PREFIX):
            continue
        key = name[len(FLUTTER_PREFIX):]
        if isinstance(v, bool):
            out[key] = _entry('bool', v)
        elif isinstance(v, int):
            out[key] = _entry('int', v)
        elif isinstance(v, float):
            out[key] = _entry('double', v)
        elif isinstance(v, str):
            out[key] = _entry('string', v)
        elif isinstance(v, list):
            out[key] = _entry('stringList', [str(x) for x in v])
        else:
            raise BuildError(f'{key}: unknown preference value {v!r}')
    return dict(sorted(out.items()))


def load_prefs(path: Path) -> dict[str, dict]:
    text = path.read_text(encoding='utf-8')
    if path.suffix.lower() == '.xml':
        return prefs_from_android_xml(text)
    if path.name == SETTINGS_NAME:          # already the export encoding
        return dict(sorted(json.loads(text).items()))
    return prefs_from_windows_json(text)


def importable_prefs(prefs: dict[str, dict]) -> tuple[dict, list[str]]:
    """Drop what the import must never write (window bounds)."""
    keep = {k: v for k, v in prefs.items() if k not in IMPORT_SKIP_PREFS}
    return keep, sorted(set(prefs) - set(keep))


# ---------------------------------------------------------------------------
# rows
# ---------------------------------------------------------------------------

@dataclass
class Rec:
    """One row for the import store, with where it came from."""
    serial: str
    metric: str
    value_num: float | None
    value_text: str | None
    start_time: str
    end_time: str
    start_ms: int
    end_ms: int
    device: str
    source: str
    master_rid: int | None
    orig_id: int | None
    backfilled: int
    note: str | None
    order: int = 0

    def row(self) -> br.Row:
        return br.Row(self.serial, self.metric, self.value_num,
                      self.value_text, self.start_ms, self.end_ms)


@dataclass
class Master:
    rows: list[Rec]
    alarms: list[dict]
    lifetime_after: dict[str, tuple]
    folds: dict[str, int]
    meta: dict[str, str]
    max_orig: dict[str, int]
    store_rows: dict[str, dict[int, tuple]]
    sha256: str
    demo_rows: int


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def load_master(path: Path) -> Master:
    m = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    try:
        rows = [Rec(serial=r[4], metric=r[5], value_num=r[6], value_text=r[7],
                    start_time=r[8], end_time=r[9], start_ms=r[10],
                    end_ms=r[11], device=r[1], source=r[2], master_rid=r[0],
                    orig_id=r[3], backfilled=r[12], note=r[13], order=r[0])
                for r in m.execute(
                    'SELECT rid, device, source, orig_id, serial, metric, '
                    'value_num, value_text, start_time, end_time, start_ms, '
                    'end_ms, backfilled, note FROM clean_readings')]
        demo_rows = m.execute(
            'SELECT COUNT(*) FROM readings WHERE demo = 1').fetchone()[0]
        alarms = []
        for dev, data in m.execute('SELECT device, data FROM alarm_events_src'):
            a = json.loads(data)
            a['_device'] = dev
            alarms.append(a)
        la = {r[0]: r[1:] for r in m.execute(
            'SELECT serial, total_charge_ah, total_discharge_ah, total_efc, '
            'rated_full_ah, aggregated_up_to, aggregated_up_to_ms, folds '
            'FROM lifetime_after')}
        folds = dict(m.execute(
            'SELECT serial, COUNT(*) FROM lifetime_folds GROUP BY serial'))
        meta = dict(m.execute('SELECT key, value FROM meta'))
        max_orig = {}
        store_rows: dict[str, dict[int, tuple]] = {}
        for dev in DEVICES:
            src = f'{dev}_store'
            max_orig[dev] = m.execute(
                'SELECT COALESCE(MAX(orig_id), 0) FROM readings WHERE '
                'source = ?', (src,)).fetchone()[0]
            store_rows[dev] = {r[0]: r[1:] for r in m.execute(
                'SELECT orig_id, serial, metric, value_num, value_text, '
                'start_time, end_time, start_ms, end_ms, rid, demo FROM '
                'readings WHERE source = ?', (src,))}
    finally:
        m.close()
    for r in rows:
        if r.start_ms is None or r.end_ms is None or not r.start_time \
                or not r.end_time:
            raise BuildError(f'master row {r.master_rid} has no time')
    return Master(rows, alarms, la, folds, meta, max_orig, store_rows,
                  sha256_of(path), demo_rows)


@dataclass
class Store:
    """A device's current interval store (read-only)."""
    path: Path
    rows: list[tuple]                 # id, serial, metric, vn, vt, st, et, s, e
    lifetime: list[tuple]
    alarms: list[dict]
    user_version: int


def load_store(path: Path) -> Store:
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    try:
        uv = db.execute('PRAGMA user_version').fetchone()[0]
    finally:
        db.close()
    rows, lt, alarms = ch.load_store(path, ch.Clock())
    return Store(path, rows, lt, alarms, uv)


@dataclass
class Fresh:
    """What a device's current store adds to the master."""
    device: str
    new: list[Rec] = field(default_factory=list)
    # (master rid, new end_ms, store id, new end_time)
    extended: list[tuple[int, int, int, str]] = field(default_factory=list)
    demo_excluded: int = 0
    unchanged: int = 0
    missing: int = 0
    alarms: list[dict] = field(default_factory=list)


def fresh_rows(master: Master, dev: str, store: Store,
               since_ms: int) -> Fresh:
    """Rows of `store` the master does not hold. A row the master copied
    (same id) must be unchanged, or the same row with a later end (it was
    still growing at the pull): that extension is taken. Anything else means
    this is not the store the master was built from."""
    out = Fresh(dev)
    known = master.store_rows[dev]
    max_id = master.max_orig[dev]
    new_raw = []
    for r in store.rows:
        rid, serial, metric, vn, vt, st, et, s_ms, e_ms = r
        if rid <= max_id:
            k = known.get(rid)
            if k is None:
                raise BuildError(f'{dev} store row {rid} is not in the master')
            ks, km, kvn, kvt, kst, ket, ksm, kem, mrid, kdemo = k
            if (serial, metric, vn, vt, st, s_ms) != (ks, km, kvn, kvt, kst,
                                                      ksm):
                raise BuildError(
                    f'{dev} store row {rid} differs from the master copy: '
                    'not the same store (was the device re-imported?)')
            if e_ms == kem:
                out.unchanged += 1
            elif e_ms > kem:
                if not kdemo:
                    out.extended.append((mrid, e_ms, rid, et))
            else:
                raise BuildError(f'{dev} store row {rid}: end moved back')
            continue
        new_raw.append(r)
    out.missing = len(set(known) - {r[0] for r in store.rows})
    # Demo checks, as the master's (#115): demo-only serials, and real
    # serials inside a demo window (a span where demo-only serials have rows).
    windows = ch.demo_windows_for(new_raw)
    for r in new_raw:
        rid, serial, metric, vn, vt, st, et, s_ms, e_ms = r
        demo = serial in ch.DEMO_ONLY_SERIALS or any(
            a - ch.EDGE_TOL_MS <= s_ms <= b + ch.EDGE_TOL_MS
            for a, b in windows)
        if demo:
            out.demo_excluded += 1
            continue
        if s_ms is None or e_ms is None:
            raise BuildError(f'{dev} store row {rid} has no epoch-ms time')
        out.new.append(Rec(serial, metric, vn, vt, st, et, s_ms, e_ms, dev,
                           f'{dev}_store', None, rid, 0,
                           'recorded after the master was built',
                           FRESH_ORDER_BASE + rid))
    for a in store.alarms:
        if a.get('at_ms', 0) > since_ms and \
                a.get('serial') not in ch.DEMO_ONLY_SERIALS:
            b = dict(a)
            b['_device'] = dev
            out.alarms.append(b)
    return out


def check_overlaps(master_rows: list[Rec], fresh: list[Fresh]) -> None:
    """New rows must not share time with the master or with the other
    device's new rows for the same pack (that needs the #116 shadow rule)."""
    def spans(rows):
        by = defaultdict(list)
        for r in rows:
            by[r.serial].append((r.start_ms, r.end_ms))
        return {k: ch.merge_spans(v, 0) for k, v in by.items()}
    base = spans(master_rows)
    new = [spans(f.new) for f in fresh]
    problems = []
    for f, sp in zip(fresh, new):
        for serial, s in sp.items():
            hit = ch.intersect_spans(s, base.get(serial, []))
            if hit:
                problems.append(f'{f.device} new rows of {serial} overlap the '
                                f'master at {len(hit)} spans')
    if len(fresh) == 2:
        for serial in set(new[0]) & set(new[1]):
            hit = ch.intersect_spans(new[0][serial], new[1][serial])
            if hit:
                problems.append(f'new rows of {serial} from both devices '
                                f'overlap at {len(hit)} spans')
    if problems:
        raise BuildError('; '.join(problems))


# ---------------------------------------------------------------------------
# lifetime (the app's integrator, one fold per session, #97)
# ---------------------------------------------------------------------------

@dataclass
class Lifetime:
    serial: str
    charge_ah: float
    discharge_ah: float
    efc: float
    full_ah: float | None
    up_to_ms: int
    folds: list[tuple]


def compute_lifetime(rows: list[Rec], clock: ch.Clock) -> dict[str, Lifetime]:
    """Per pack: the same computation as clean_history.recompute_lifetime,
    over `rows` (already in store order)."""
    by: dict[str, dict[str, list[Rec]]] = defaultdict(lambda: defaultdict(list))
    for r in rows:
        if r.metric in ('packI', 'sampleIntervalS', 'fullAh'):
            by[r.serial][r.metric].append(r)
    out = {}
    for serial in sorted(by):
        cur_rows = by[serial]['packI']
        if not cur_rows:
            continue
        si = by[serial]['sampleIntervalS']
        policy = br.GapPolicy([(r.start_ms, r.value_num) for r in si])
        fulls = [r for r in by[serial]['fullAh'] if r.value_num is not None]
        full_ah = max(fulls, key=lambda r: (r.end_ms, r.order)).value_num \
            if fulls else None
        brows = [r.row() for r in cur_rows]
        contrib = ch.per_row_ah(brows, policy)
        runs, run = [], None
        for k, r in enumerate(brows):
            if run is not None and policy.abuts(brows[run[-1]].end_ms,
                                                r.start_ms):
                run.append(k)
            else:
                run = [k]
                runs.append(run)
        folds = []
        cc = cd = 0.0
        for n, run in enumerate(runs, 1):
            c = sum(contrib[k][0] for k in run)
            d = sum(contrib[k][1] for k in run)
            cc += c
            cd += d
            a = brows[run[0]].start_ms
            b = max(brows[k].end_ms for k in run)
            folds.append((serial, n, a, b, clock.fmt(a), clock.fmt(b),
                          len(run),
                          ','.join(sorted({cur_rows[k].source for k in run})),
                          c, d, (c + d) / full_ah if full_ah else 0.0,
                          cc, cd, (cc + cd) / full_ah if full_ah else 0.0))
        tc, td, newest = br.integrate_current_rows(brows, policy=policy)
        out[serial] = Lifetime(serial, tc, td,
                               (tc + td) / full_ah if full_ah else 0.0,
                               full_ah, newest, folds)
    return out


# ---------------------------------------------------------------------------
# the import store and zips
# ---------------------------------------------------------------------------

def write_store(path: Path, rows: list[Rec], lifetime: dict[str, Lifetime],
                alarms: list[dict], meta: dict[str, str],
                clock: ch.Clock) -> None:
    if path.exists():
        path.unlink()
    db = sqlite3.connect(path)
    try:
        for ddl in APP_DDL + SIDE_DDL:
            db.execute(ddl)
        db.executemany(
            'INSERT INTO readings (id, serial, metric, value_num, value_text, '
            'start_time, end_time, start_ms, end_ms) VALUES (?,?,?,?,?,?,?,?,?)',
            [(i, r.serial, r.metric, r.value_num, r.value_text, r.start_time,
              r.end_time, r.start_ms, r.end_ms)
             for i, r in enumerate(rows, 1)])
        db.executemany(
            'INSERT INTO import_provenance VALUES (?,?,?,?,?,?,?)',
            [(i, r.device, r.source, r.master_rid, r.orig_id, r.backfilled,
              r.note) for i, r in enumerate(rows, 1)])
        for lt in lifetime.values():
            db.execute(
                'INSERT INTO lifetime_totals VALUES (?,?,?,?,?,?)',
                (lt.serial, lt.charge_ah, lt.discharge_ah, lt.efc,
                 clock.fmt(lt.up_to_ms), lt.up_to_ms))
            db.executemany('INSERT INTO import_lifetime_folds VALUES '
                           '(?,?,?,?,?,?,?,?,?,?,?,?,?,?)', lt.folds)
        alarms = sorted(alarms, key=lambda a: (a['at_ms'], a.get('id', 0)))
        db.executemany(
            f'INSERT INTO alarm_events (id, {", ".join(ALARM_COLS)}) VALUES '
            f'({", ".join("?" * (len(ALARM_COLS) + 1))})',
            [(i, *(a.get(c) for c in ALARM_COLS))
             for i, a in enumerate(alarms, 1)])
        db.executemany('INSERT INTO import_meta VALUES (?,?)',
                       sorted(meta.items()))
        db.execute(f'PRAGMA user_version = {SCHEMA_VERSION}')
        db.commit()
        ok = db.execute('PRAGMA integrity_check').fetchone()[0]
        if ok != 'ok':
            raise BuildError(f'integrity_check: {ok}')
        db.execute('VACUUM')
    finally:
        db.close()


def csv_field(v) -> str:
    """data_export.dart csvField (Dart prints a double as 90.0, as Python)."""
    if v is None:
        return ''
    s = f'{v}'
    if any(c in s for c in ',"\r\n'):
        return '"' + s.replace('"', '""') + '"'
    return s


def readings_csv(rows: list[Rec]) -> bytes:
    buf = io.StringIO()
    buf.write(','.join(CSV_COLS) + '\n')
    for r in rows:
        buf.write(','.join(csv_field(getattr(r, c)) for c in CSV_COLS) + '\n')
    return buf.getvalue().encode('utf-8')


def db_info(path: Path) -> dict:
    """The manifest's `database` block, as _describeAndCsv writes it."""
    db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
    try:
        return {
            'included': True,
            'userVersion': db.execute('PRAGMA user_version').fetchone()[0],
            'readings': db.execute('SELECT COUNT(*) FROM readings').fetchone()[0],
            'lifetimeTotals': db.execute(
                'SELECT COUNT(*) FROM lifetime_totals').fetchone()[0],
            'alarmEvents': db.execute(
                'SELECT COUNT(*) FROM alarm_events').fetchone()[0],
            'serials': [r[0] for r in db.execute(
                'SELECT DISTINCT serial FROM readings ORDER BY serial')],
        }
    finally:
        db.close()


def write_zip(path: Path, db_path: Path, csv_bytes: bytes,
              settings: dict, manifest_extra: dict, device: str,
              now: dt.datetime) -> dict:
    settings_bytes = json.dumps(settings, indent=2).encode('utf-8')
    files = [(DB_NAME, db_path.read_bytes()), (CSV_NAME, csv_bytes),
             (SETTINGS_NAME, settings_bytes)]
    manifest = {
        'format': EXPORT_FORMAT,
        'formatVersion': EXPORT_FORMAT_VERSION,
        'app': 'AWTO BMS',
        'exportedAt': now.isoformat(timespec='milliseconds'),
        'exportedAtUtcMs': int(now.timestamp() * 1000),
        'platform': f'clean history for the {device}',
        'osVersion': 'build_import.py',
        'schemaVersion': SCHEMA_VERSION,
        'database': db_info(db_path),
        'files': [{'name': n, 'bytes': len(b),
                   'sha256': hashlib.sha256(b).hexdigest()} for n, b in files],
        'cleanImport': manifest_extra,
    }
    if path.exists():
        path.unlink()
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr(MANIFEST_NAME, json.dumps(manifest, indent=2))
        for n, b in files:
            z.writestr(n, b)
    return manifest


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

@dataclass
class DeviceInput:
    device: str
    store: Store
    prefs: dict
    store_src: str
    prefs_src: str


def device_input(dev: str, store_path: str | None, prefs_path: str | None,
                 export_zip: str | None, tmp: Path) -> DeviceInput:
    if export_zip:
        if store_path or prefs_path:
            raise BuildError(f'--{dev}-export replaces --{dev}-store/-prefs')
        d = tmp / dev
        d.mkdir(parents=True)
        with zipfile.ZipFile(export_zip) as z:
            names = set(z.namelist())
            for n in (DB_NAME, SETTINGS_NAME, MANIFEST_NAME):
                if n not in names:
                    raise BuildError(f'{export_zip}: no {n}')
            man = json.loads(z.read(MANIFEST_NAME))
            if man.get('format') != EXPORT_FORMAT:
                raise BuildError(f'{export_zip}: not an AWTO BMS export')
            z.extract(DB_NAME, d)
            z.extract(SETTINGS_NAME, d)
        return DeviceInput(dev, load_store(d / DB_NAME),
                           load_prefs(d / SETTINGS_NAME), export_zip,
                           f'{export_zip} (settings.json)')
    if not (store_path and prefs_path):
        raise BuildError(f'{dev}: give --{dev}-export, or both '
                         f'--{dev}-store and --{dev}-prefs')
    return DeviceInput(dev, load_store(Path(store_path)),
                       load_prefs(Path(prefs_path)), store_path, prefs_path)


def pack_counts(rows) -> Counter:
    return Counter(r[1] if isinstance(r, tuple) else r.serial for r in rows)


@dataclass
class Result:
    out: Path
    db: Path
    zips: dict[str, Path]
    rows: list[Rec]
    lifetime: dict[str, Lifetime]
    master: Master
    fresh: dict[str, Fresh]
    inputs: dict[str, DeviceInput]
    skipped_prefs: dict[str, list[str]]
    manifests: dict[str, dict]
    alarms: int


def build(master_path: Path, inputs: dict[str, DeviceInput], out: Path,
          clock: ch.Clock, now: dt.datetime | None = None) -> Result:
    now = now or dt.datetime.now(clock.tz)
    master = load_master(master_path)

    # 1. the master alone must give the signed-off totals
    base = sorted(master.rows, key=lambda r: (r.start_ms, r.order))
    check = compute_lifetime(base, clock)
    for serial, la in master.lifetime_after.items():
        lt = check.get(serial)
        if lt is None or abs(lt.charge_ah - la[0]) > AH_TOL or \
                abs(lt.discharge_ah - la[1]) > AH_TOL or \
                lt.up_to_ms != la[5] or len(lt.folds) != master.folds[serial]:
            raise BuildError(f'{serial}: recomputed totals differ from the '
                             'master lifetime_after')

    # 2. newest device rows
    since = clock.to_ms(master.meta.get('observed_until', '')) or 0
    fresh = {dev: fresh_rows(master, dev, inp.store, since)
             for dev, inp in inputs.items()}
    check_overlaps(master.rows, list(fresh.values()))
    rows = list(master.rows)
    ext = {}
    for f in fresh.values():
        for mrid, e_ms, _rid, et in f.extended:
            ext[mrid] = (e_ms, et)
        rows.extend(f.new)
    for r in rows:
        if r.master_rid in ext:
            r.end_ms, r.end_time = ext[r.master_rid]
            r.note = ((r.note + '; ') if r.note else '') + \
                'end extended from the current store'
    rows.sort(key=lambda r: (r.start_ms, r.order))
    lifetime = compute_lifetime(rows, clock)

    # 3. alarm events (master sources + new), demo packs never
    alarms = [a for a in master.alarms
              if a.get('serial') not in ch.DEMO_ONLY_SERIALS]
    for f in fresh.values():
        alarms.extend(f.alarms)

    out.mkdir(parents=True, exist_ok=True)
    db_path = out / DB_NAME
    meta = {
        'built_at': now.isoformat(timespec='seconds'),
        'built_by': 'scripts/build_import.py (#119)',
        'master': str(master_path),
        'master_sha256': master.sha256,
        'master_built_at': master.meta.get('built_at', ''),
        'master_observed_until': master.meta.get('observed_until', ''),
        'rows_from_master': str(len(master.rows)),
        'infer_clear_alarms_python': master.meta.get(
            'infer_clear_alarms_python', ''),
    }
    for dev, f in fresh.items():
        meta[f'{dev}_store'] = inputs[dev].store_src
        meta[f'{dev}_new_rows'] = str(len(f.new))
        meta[f'{dev}_extended_rows'] = str(len(f.extended))
        meta[f'{dev}_demo_excluded'] = str(f.demo_excluded)
    write_store(db_path, rows, lifetime, alarms, meta, clock)
    csv_bytes = readings_csv(rows)

    expect = {
        'readings': len(rows),
        'perSerial': dict(sorted(pack_counts(rows).items())),
        'alarmEvents': len(alarms),
        'lifetime': {s: {'chargeAh': lt.charge_ah,
                         'dischargeAh': lt.discharge_ah, 'efc': lt.efc,
                         'aggregatedUpToMs': lt.up_to_ms,
                         'folds': len(lt.folds)}
                     for s, lt in lifetime.items()},
        'masterSha256': master.sha256,
    }
    zips, manifests, skipped = {}, {}, {}
    for dev, inp in inputs.items():
        settings, skipped[dev] = importable_prefs(inp.prefs)
        z = out / f'awto-bms-import-{dev}.zip'
        manifests[dev] = write_zip(z, db_path, csv_bytes, settings,
                                   {**expect, 'device': dev,
                                    'settingsKeys': sorted(settings)},
                                   dev, now)
        zips[dev] = z
    return Result(out, db_path, zips, rows, lifetime, master, fresh, inputs,
                  skipped, manifests, len(alarms))


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

def _ah(v: float | None) -> str:
    return '' if v is None else f'{v:.3f}'


def write_report(res: Result, clock: ch.Clock, argv: list[str]) -> Path:
    L = []
    w = L.append
    m = res.master
    w('# AWTO BMS: import of the clean history (#119)')
    w('')
    w(f'Built {res.manifests[next(iter(res.manifests))]["exportedAt"]} by '
      '`scripts/build_import.py` from the signed-off master '
      f'(`{m.sha256[:12]}`, built {m.meta.get("built_at")}, observed until '
      f'{m.meta.get("observed_until")}). Times are local AWST. **Nothing has '
      'been imported yet**; the steps are in section 5.')
    w('')
    w('## 1. What each zip holds')
    w('')
    w('Both zips carry the same history store; each carries its own '
      "device's current settings.")
    w('')
    w(f'- Readings: **{len(res.rows):,}** = {len(m.rows):,} from '
      '`clean_readings` (demo and shadow rows left out: '
      f'{m.demo_rows:,} demo rows stay in the master only)'
      + ''.join(f' + {len(f.new):,} newer {d} rows'
                for d, f in res.fresh.items()) + '.')
    ext = sum(len(f.extended) for f in res.fresh.values())
    if ext:
        w(f'- {ext} master rows had grown since the pull; their newer end '
          'is taken.')
    dex = {d: f.demo_excluded for d, f in res.fresh.items() if f.demo_excluded}
    if dex:
        w(f'- Demo rows in the newer device rows, left out: {dex}.')
    w(f'- Alarm events: {res.alarms}.')
    w('- Store: schema version 4 (the app\'s current), ids 1..N, text and '
      'epoch-ms times. Side tables the app does not read: '
      '`import_provenance` (source and note of every row, e.g. the Python '
      'period\'s inferred all-clear alarms), `import_lifetime_folds` (every '
      'fold, #97), `import_meta`.')
    for dev, z in res.zips.items():
        w(f'- `{z.name}`: {z.stat().st_size:,} bytes, settings from '
          f'`{res.inputs[dev].prefs_src}`'
          + (f'; not written: {", ".join(res.skipped_prefs[dev])}'
             if res.skipped_prefs[dev] else '') + '.')
    w('')
    w('## 2. Before and after, per device and pack')
    w('')
    serials = sorted({r.serial for r in res.rows} |
                     {r[1] for inp in res.inputs.values()
                      for r in inp.store.rows})
    after = pack_counts(res.rows)
    w('| device | pack | readings before | readings after | lifetime before '
      '(in / out Ah, EFC) | lifetime after (in / out Ah, EFC) |')
    w('|---|---|---|---|---|---|')
    for dev, inp in res.inputs.items():
        before = pack_counts(inp.store.rows)
        lt_b = {r[0]: r for r in inp.store.lifetime}
        for s in serials:
            b = lt_b.get(s)
            a = res.lifetime.get(s)
            demo = ' (demo pack)' if s in ch.DEMO_ONLY_SERIALS else ''
            w(f'| {dev} | {s}{demo} | {before.get(s, 0):,} | '
              f'{after.get(s, 0):,} | '
              + (f'{_ah(b[1])} / {_ah(b[2])}, {b[3]:.4f} to {b[4]}'
                 if b else '(none)') + ' | '
              + (f'{_ah(a.charge_ah)} / {_ah(a.discharge_ah)}, {a.efc:.4f} '
                 f'to {clock.fmt(a.up_to_ms)} ({len(a.folds)} folds)'
                 if a else '(none)') + ' |')
        w(f'| {dev} | **all** | **{len(inp.store.rows):,}** | '
          f'**{len(res.rows):,}** | | |')
    w('')
    w('Signed-off master totals (before newer rows): ' + '; '.join(
        f'{s} {_ah(v[0])} in / {_ah(v[1])} out, EFC {v[2]:.4f} to {v[4]}'
        for s, v in sorted(m.lifetime_after.items())) + '.')
    w('')
    w('## 3. Newer device rows merged at build time')
    w('')
    w('| device | store | rows unchanged | rows grown | new rows | demo left '
      'out | master rows no longer in the store | new span |')
    w('|---|---|---|---|---|---|---|---|')
    for dev, f in res.fresh.items():
        span = (f'{clock.fmt(min(r.start_ms for r in f.new))} .. '
                f'{clock.fmt(max(r.end_ms for r in f.new))}'
                if f.new else '')
        w(f'| {dev} | `{res.inputs[dev].store_src}` | {f.unchanged:,} | '
          f'{len(f.extended)} | {len(f.new):,} | {f.demo_excluded} | '
          f'{f.missing} | {span} |')
    w('')
    w('## 4. What you will see after the import')
    w('')
    w('- Both apps show the same history for JS-2C14AA and JS-2C14B8 from '
      '18 Sep (Python-tool period) to the newest merged reading, including '
      'the rows backfilled from raw logs (e.g. 21 Sep 13:19-13:22, the '
      '89 A load that no store had).')
    w('- The demo packs (JS-9F031B, JS-5A77C0, RV-1180E2) have no history '
      'any more, and the demo rows under JS-2C14AA are gone.')
    w('- Lifetime totals show the figures in section 2 (JS-2C14AA drops '
      'the 0.128 Ah out that came from demo current on the phone). The app '
      'adds new readings to them from there as usual.')
    w('- Battery names, the fleet list and every setting stay as they are '
      'on that device (each zip carries that device\'s own current '
      'settings). The phone fleet list is empty today (#110); this import '
      'does not rebuild it. Window size and position are never imported.')
    w('- The previous store is kept next to the new one as '
      '`battery_intervals.db.before-import-<date-time>`; nothing is deleted.')
    w('')
    w('## 5. Device steps (one device at a time)')
    w('')
    w('1. **Backup / re-pull.** In the app: Settings -> Data -> **Export all '
      'data**. Keep that zip (it is the backup) and copy it to the PC. On the '
      'phone, Export shares the zip: save it to Files or send it to the PC.')
    w('2. **Rebuild with the newest rows** (on the PC, from `projects/awto-bms`):')
    w('')
    w('   ```')
    w('   python scripts/build_import.py --master logs/clean-20260924/master.db \\')
    w('       --phone-export <phone export zip> \\')
    w('       --windows-export <windows export zip> --out logs/import-<date>')
    w('   ```')
    w('')
    w('   This merges every reading recorded since the master was built and '
      'takes the settings from the exports. It stops (and writes nothing) if '
      'new rows overlap the master or each other. Then check the report and '
      'validate the zip with the app\'s own import code:')
    w('')
    w('   ```')
    w("   $env:AWTO_IMPORT_ZIP = '<phone zip>;<windows zip>'   # PowerShell")
    w('   flutter test test/clean_import_119_test.dart')
    w('   ```')
    w('')
    w('3. **Import.** Copy `awto-bms-import-<device>.zip` to the device. '
      'Settings -> Data -> **Import data…**, pick the zip, check the dialog '
      '(readings count and packs as in section 2), tap **Import**, then '
      '**Exit now**.')
    w('4. **Restart** the app. The import is applied before the store opens.')
    w('5. **Verify** on the device: the lifetime totals per pack as in '
      'section 2; the history chart of 21 Sep for JS-2C14B8 shows the ~89 A '
      'load at 13:19-13:22 and 15:05-15:08; history reaches back to 18 Sep; '
      'the demo packs are gone; names and settings unchanged. The console '
      '(Windows) or `adb logcat` (phone) shows `[IMPORT] import applied: '
      'database replaced (previous kept as battery_intervals.db.before-import-'
      '...)`. For a row-count check, Export all data once more: its '
      '`manifest.json` `database.readings` is the zip\'s count plus what was '
      'recorded since the restart.')
    w('')
    w('Readings a device records between its export (step 1) and the '
      'restart (step 4) stay in the `before-import` file and the raw log, '
      'not in the new store. Keep that window short (do steps 1-4 together), '
      'or disconnect the packs from that device while doing it.')
    w('')
    w('## 6. Reproduce')
    w('')
    w('```')
    w('python scripts/build_import.py ' + ' '.join(argv))
    w('python -m unittest discover -s scripts -p "test_*.py"')
    w('```')
    p = res.out / 'IMPORT-REPORT.md'
    p.write_text('\n'.join(L) + '\n', encoding='utf-8', newline='\n')
    return p


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--master', required=True, help='the #116 master.db')
    ap.add_argument('--out', required=True,
                    help='output folder, e.g. logs/import-20260924')
    ap.add_argument('--utc-offset', type=float, default=8.0,
                    help='hours east of UTC for local timestamps (AWST 8)')
    for dev in DEVICES:
        ap.add_argument(f'--{dev}-store', help=f'{dev} battery_intervals.db')
        ap.add_argument(f'--{dev}-prefs',
                        help=f'{dev} preferences (Android XML / Windows JSON)')
        ap.add_argument(f'--{dev}-export',
                        help=f'{dev} "Export all data" zip (store + settings)')
    args = ap.parse_args(argv)
    clock = ch.Clock(args.utc_offset)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            inputs = {}
            for dev in DEVICES:
                a = vars(args)
                if any(a[f'{dev}_{k}'] for k in ('store', 'prefs', 'export')):
                    inputs[dev] = device_input(
                        dev, a[f'{dev}_store'], a[f'{dev}_prefs'],
                        a[f'{dev}_export'], Path(tmp))
            if not inputs:
                raise BuildError('give at least one device')
            res = build(Path(args.master), inputs, Path(args.out), clock)
    except BuildError as e:
        print(f'build_import: {e}', file=sys.stderr)
        return 2
    rep = write_report(res, clock, argv)
    for z in res.zips.values():
        print(f'-> {z}')
    print(f'-> {rep}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
