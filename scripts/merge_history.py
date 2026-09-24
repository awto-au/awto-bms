#!/usr/bin/env python3
"""Merge AWTO BMS history from several devices into one analysis database.

Each app install (phone, Windows PC, ...) keeps its own interval store
(battery_intervals.db) and raw BLE log (battery_raw.log). A pack is often
watched by two devices at once, or by one while the other is away, so the full
story of a pack only exists across all of them. This tool copies every row
from every source into one SQLite file, tagged with the source name, and adds
the raw-log lines as a table so readings, alarm events and raw frames can be
queried on one timeline.

Analysis only: rows are kept side by side, never deduplicated, so the output
is NOT for importing back into the app (overlapping intervals would
double-count lifetime totals).

Times: the stores hold local-time strings plus epoch ms written by the device.
Raw-log lines carry local time only; their epoch ms is computed in THIS
machine's time zone, so run it in the same zone as the devices (AWST here).

Usage (from projects/awto-bms):
    python scripts/merge_history.py merge --out logs/merged.db \\
        --db phone=logs/pull/phone/battery_intervals.db \\
        --db windows=logs/pull/windows/battery_intervals.db \\
        --raw phone=logs/pull/phone/battery_raw.log \\
        --raw windows=logs/pull/windows/battery_raw.log
    python scripts/merge_history.py gaps --db logs/merged.db --min-minutes 30
    python scripts/merge_history.py timeline --db logs/merged.db \\
        --serial JS-2C14AA --from "2026-09-20 06:50" --to "2026-09-20 07:20"
"""
from __future__ import annotations

import argparse
import datetime as dt
import re
import sqlite3
import sys
from pathlib import Path

# Raw-log line: "2026-09-20 07:03:18.484  JS-2C14AA  Battery data     a2 57 ..."
# Fields are separated by two or more spaces; the kind column is padded.
RAW_LINE = re.compile(
    r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\s{2,}(\S+)\s{2,}(.+?)(?:\s{2,}(.*))?$"
)
TIME_FMT = "%Y-%m-%d %H:%M:%S.%f"


def parse_source(spec: str) -> tuple[str, Path]:
    name, sep, path = spec.partition("=")
    if not sep or not name or not path:
        raise argparse.ArgumentTypeError(f"expected NAME=PATH, got {spec!r}")
    p = Path(path)
    if not p.is_file():
        raise argparse.ArgumentTypeError(f"no such file: {p}")
    return name, p


def to_ms(local: str) -> int | None:
    try:
        return int(dt.datetime.strptime(local, TIME_FMT).timestamp() * 1000)
    except ValueError:
        return None


def full_time(t: str) -> str:
    """Accept 'YYYY-MM-DD HH:MM' or '... HH:MM:SS' as well as the full form."""
    t = t.strip()
    if len(t) == 16:
        return t + ":00.000"
    if len(t) == 19:
        return t + ".000"
    return t


def create_schema(out: sqlite3.Connection) -> None:
    out.executescript(
        """
        CREATE TABLE readings (
          source TEXT NOT NULL, id INTEGER, serial TEXT NOT NULL,
          metric TEXT NOT NULL, value_num REAL, value_text TEXT,
          start_time TEXT, end_time TEXT, start_ms INTEGER, end_ms INTEGER);
        CREATE TABLE lifetime_totals (
          source TEXT NOT NULL, serial TEXT, total_charge_ah REAL,
          total_discharge_ah REAL, total_efc REAL, aggregated_up_to TEXT,
          aggregated_up_to_ms INTEGER);
        CREATE TABLE raw_log (
          source TEXT NOT NULL, at_time TEXT NOT NULL, at_ms INTEGER,
          serial TEXT, kind TEXT, detail TEXT);
        CREATE TABLE sources (
          source TEXT NOT NULL, kind TEXT NOT NULL, path TEXT NOT NULL,
          rows INTEGER NOT NULL);
        """
    )


def copy_db(out: sqlite3.Connection, name: str, path: Path) -> int:
    src = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        ok = src.execute("PRAGMA integrity_check").fetchone()[0]
        if ok != "ok":
            print(f"WARNING: {path}: integrity_check says {ok!r}", file=sys.stderr)
        n = 0
        rows = src.execute(
            "SELECT id, serial, metric, value_num, value_text, start_time,"
            " end_time, start_ms, end_ms FROM readings")
        for batch in iter(lambda: rows.fetchmany(5000), []):
            out.executemany(
                "INSERT INTO readings VALUES (?,?,?,?,?,?,?,?,?,?)",
                [(name, *r) for r in batch])
            n += len(batch)
        for r in src.execute(
                "SELECT serial, total_charge_ah, total_discharge_ah, total_efc,"
                " aggregated_up_to, aggregated_up_to_ms FROM lifetime_totals"):
            out.execute("INSERT INTO lifetime_totals VALUES (?,?,?,?,?,?,?)",
                        (name, *r))
        n += copy_alarm_events(out, src, name)
        return n
    finally:
        src.close()


def copy_alarm_events(out: sqlite3.Connection, src: sqlite3.Connection,
                      name: str) -> int:
    """alarm_events has many columns and grew over versions: copy whatever
    columns the source has, adding any the merged table lacks."""
    try:
        cols = [r[1] for r in src.execute("PRAGMA table_info(alarm_events)")]
    except sqlite3.DatabaseError:
        return 0
    if not cols:
        return 0
    have = {r[1] for r in out.execute("PRAGMA table_info(alarm_events)")}
    if not have:
        out.execute("CREATE TABLE alarm_events (source TEXT NOT NULL)")
        have = {"source"}
    for c in cols:
        if c not in have:
            out.execute(f'ALTER TABLE alarm_events ADD COLUMN "{c}"')
    quoted = ", ".join(f'"{c}"' for c in cols)
    rows = src.execute(f"SELECT {quoted} FROM alarm_events").fetchall()
    out.executemany(
        f'INSERT INTO alarm_events (source, {quoted}) VALUES '
        f'({", ".join("?" * (len(cols) + 1))})',
        [(name, *r) for r in rows])
    return len(rows)


def copy_raw(out: sqlite3.Connection, name: str, path: Path) -> int:
    n = skipped = 0
    batch = []
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            m = RAW_LINE.match(line.rstrip("\n"))
            if not m:
                skipped += 1
                continue
            at, serial, kind, detail = m.groups()
            batch.append((name, at, to_ms(at), serial, kind.strip(),
                          (detail or "").strip()))
            if len(batch) >= 10000:
                out.executemany("INSERT INTO raw_log VALUES (?,?,?,?,?,?)", batch)
                n += len(batch)
                batch.clear()
    out.executemany("INSERT INTO raw_log VALUES (?,?,?,?,?,?)", batch)
    n += len(batch)
    if skipped:
        print(f"{name}: {skipped} raw-log lines did not parse (kept out)",
              file=sys.stderr)
    return n


def cmd_merge(args: argparse.Namespace) -> int:
    if not args.db and not args.raw:
        print("nothing to merge: give --db and/or --raw", file=sys.stderr)
        return 2
    out_path = Path(args.out)
    if out_path.exists():
        if not args.force:
            print(f"{out_path} exists; pass --force to replace it", file=sys.stderr)
            return 2
        out_path.unlink()
    out = sqlite3.connect(out_path)
    try:
        create_schema(out)
        for name, path in args.db:
            n = copy_db(out, name, path)
            out.execute("INSERT INTO sources VALUES (?,?,?,?)",
                        (name, "db", str(path), n))
            print(f"db  {name:<10} {n:>8} rows  {path}")
        for name, path in args.raw:
            n = copy_raw(out, name, path)
            out.execute("INSERT INTO sources VALUES (?,?,?,?)",
                        (name, "raw", str(path), n))
            print(f"raw {name:<10} {n:>8} lines {path}")
        out.executescript(
            """
            CREATE INDEX ix_r ON readings(serial, start_ms);
            CREATE INDEX ix_raw ON raw_log(serial, at_ms);
            CREATE INDEX ix_raw_ms ON raw_log(at_ms);
            """)
        out.commit()
    finally:
        out.close()
    print(f"-> {out_path}")
    return 0


def cmd_gaps(args: argparse.Namespace) -> int:
    """Per source and serial: spans with no reading and no raw-log line longer
    than --min-minutes. A gap on every source is a window nobody observed."""
    db = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    min_ms = int(args.min_minutes * 60_000)
    q = """
        SELECT source, serial, start_ms AS a, end_ms AS b FROM readings
        WHERE start_ms IS NOT NULL {f}
        UNION ALL
        SELECT source, serial, at_ms, at_ms FROM raw_log
        WHERE at_ms IS NOT NULL {f}
        ORDER BY 1, 2, 3"""
    f = "AND serial = :serial" if args.serial else ""
    cur = db.execute(q.format(f=f), {"serial": args.serial})
    last: dict[tuple[str, str], int] = {}
    for source, serial, a, b in cur:
        key = (source, serial)
        prev = last.get(key)
        if prev is not None and a - prev > min_ms:
            print(f"{source:<8} {serial:<10} {fmt(prev)} -> {fmt(a)}"
                  f"  ({(a - prev) / 60000:.0f} min)")
        last[key] = max(prev or 0, b or a)
    return 0


def cmd_timeline(args: argparse.Namespace) -> int:
    """Every value change, alarm event and raw-log line for one pack in a time
    window, from all sources, in time order."""
    db = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    a, b = to_ms(full_time(args.start)), to_ms(full_time(args.end))
    if a is None or b is None:
        print("--from/--to must look like 'YYYY-MM-DD HH:MM'", file=sys.stderr)
        return 2
    rows = [
        (r[0], r[1], "reading", f"{r[2]} = {r[3] if r[3] is not None else r[4]}"
         f"  (until {r[5][11:23] if r[5] else '?'})")
        for r in db.execute(
            "SELECT start_ms, source, metric, value_num, value_text, end_time"
            " FROM readings WHERE serial = ? AND start_ms BETWEEN ? AND ?",
            (args.serial, a, b))
        if not args.metrics or r[2] in args.metrics
    ]
    if not args.no_raw:
        rows += [(r[0], r[1], r[2], r[3]) for r in db.execute(
            "SELECT at_ms, source, kind, detail FROM raw_log"
            " WHERE (serial = ? OR serial NOT LIKE '%-%') AND at_ms BETWEEN ? AND ?",
            (args.serial, a, b))]
    has_alarms = db.execute(
        "SELECT 1 FROM sqlite_master WHERE name = 'alarm_events'").fetchone()
    if has_alarms:
        rows += [(r[0], r[1], "ALARM", f"{r[2]} {r[3]}") for r in db.execute(
            "SELECT at_ms, source, bit_name, transition FROM alarm_events"
            " WHERE serial = ? AND at_ms BETWEEN ? AND ?", (args.serial, a, b))]
    rows.sort(key=lambda r: (r[0], r[1]))
    for ms, source, kind, detail in rows[: args.limit]:
        print(f"{fmt(ms)}  {source:<8} {kind:<22} {detail}")
    if len(rows) > args.limit:
        print(f"... {len(rows) - args.limit} more (raise --limit)")
    return 0


def fmt(ms: int) -> str:
    return dt.datetime.fromtimestamp(ms / 1000).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("merge", help="build the merged analysis database")
    m.add_argument("--out", required=True)
    m.add_argument("--db", type=parse_source, action="append", default=[],
                   metavar="NAME=PATH", help="a battery_intervals.db")
    m.add_argument("--raw", type=parse_source, action="append", default=[],
                   metavar="NAME=PATH", help="a battery_raw.log")
    m.add_argument("--force", action="store_true", help="replace --out")
    m.set_defaults(fn=cmd_merge)

    g = sub.add_parser("gaps", help="list unobserved spans per source/pack")
    g.add_argument("--db", required=True)
    g.add_argument("--serial")
    g.add_argument("--min-minutes", type=float, default=30)
    g.set_defaults(fn=cmd_gaps)

    t = sub.add_parser("timeline", help="one pack's merged timeline")
    t.add_argument("--db", required=True)
    t.add_argument("--serial", required=True)
    t.add_argument("--from", dest="start", required=True)
    t.add_argument("--to", dest="end", required=True)
    t.add_argument("--metrics", nargs="*", help="only these reading metrics")
    t.add_argument("--no-raw", action="store_true", help="omit raw-log lines")
    t.add_argument("--limit", type=int, default=400)
    t.set_defaults(fn=cmd_timeline)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
