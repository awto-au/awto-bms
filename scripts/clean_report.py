#!/usr/bin/env python3
"""Write <out>/REPORT.md from <out>/master.db (built by clean_history.py).

Every table and count is read from master.db. The interpretive notes in
section 8 were written after inspecting this data (the 24 Sep 2026 pull) and
name the evidence they rest on. Run through
`clean_history.py report --out <folder>`.
"""
from __future__ import annotations

import datetime as dt
import sqlite3
from pathlib import Path

REAL = ('JS-2C14AA', 'JS-2C14B8')
EXCLUDED = ('rssi', 'efc')


def pct(a, b) -> str:
    return '—' if not b else f'{100.0 * a / b:.2f} %'


def ah(x) -> str:
    return '—' if x is None else f'{x:.3f}'


def table(headers: list[str], rows: list[list]) -> list[str]:
    out = ['| ' + ' | '.join(headers) + ' |',
           '|' + '|'.join('---' for _ in headers) + '|']
    for r in rows:
        out.append('| ' + ' | '.join('' if c is None else str(c) for c in r)
                   + ' |')
    return out


def q(m, sql, *args):
    return m.execute(sql, args).fetchall()


def one(m, sql, *args):
    r = m.execute(sql, args).fetchone()
    return r[0] if r else None


def write_report(out: Path, clock) -> Path:
    m = sqlite3.connect(f'file:{out / "master.db"}?mode=ro', uri=True)
    meta = dict(q(m, 'SELECT key, value FROM meta'))
    L: list[str] = []
    add = L.append

    add('# AWTO BMS data clean-up: master history report (#116)')
    add('')
    add(f'Built {meta.get("built_at")} by `scripts/clean_history.py` from the '
        f'frozen copies in `sources/`. Times are local AWST (UTC+8). The '
        f'master is `master.db`; the clean history is its `clean_readings` '
        f'view (`demo = 0 AND shadow = 0`). **Nothing was imported into the '
        f'apps and no source was changed or deleted.**')
    add('')

    # ---- summary ------------------------------------------------------------
    total = one(m, 'SELECT COUNT(*) FROM readings')
    store = one(m, "SELECT COUNT(*) FROM readings WHERE source LIKE '%_store'")
    demo = one(m, 'SELECT SUM(demo) FROM readings')
    back = one(m, 'SELECT SUM(backfilled) FROM readings')
    shadow = one(m, 'SELECT SUM(shadow) FROM readings')
    add('## 1. Summary for sign-off')
    add('')
    add(f'- `readings`: {total:,} rows = {store:,} original store rows '
        f'(unchanged) + {back:,} backfilled rows derived from raw frames.')
    add(f'- Flags: {demo:,} `demo`, {back:,} `backfilled`, {shadow:,} '
        f'`shadow`. No row was deleted.')
    v = validation_headline(m)
    add(f'- Decoder port validated against both stores: {v}')
    for serial in REAL:
        b = before_totals(m, serial)
        a = q(m, 'SELECT total_charge_ah, total_discharge_ah, total_efc, '
                 'aggregated_up_to FROM lifetime_after WHERE serial = ?',
              serial)
        if a:
            a = a[0]
            add(f'- {serial} lifetime: before {b}; after {ah(a[0])} Ah in / '
                f'{ah(a[1])} Ah out, EFC {a[2]:.4f} (to {a[3]}).')
    add('- Decisions for you are in section 9.')
    add('')

    # ---- sources ------------------------------------------------------------
    add('## 2. Sources (frozen, SHA-256 in `sources/SHA256SUMS`)')
    add('')
    rows = [[r[0], f'`{r[3]}`', (r[4] or '')[:12], f'{r[5]:,}' if r[5] else '',
             'yes' if r[6] else 'no', r[7]]
            for r in q(m, 'SELECT source, device, kind, path, sha256, bytes, '
                          'used, note FROM sources ORDER BY used DESC, source')]
    L += table(['source', 'file', 'sha256', 'bytes', 'merged', 'note'], rows)
    add('')
    add('Not included: the old desktop CWD store (#4). The issue lists it as '
        'the same rows as the Windows store and no copy was supplied. The '
        '`merged.db` files in the pull folders are outputs of '
        '`merge_history.py`, not sources.')
    add('')

    # ---- method -------------------------------------------------------------
    add('## 3. Method')
    add('')
    add('- **Store rows** are copied as they are (`orig_id` = the row id in '
        'its store) and tagged `device`/`source`.')
    add('- **Derived rows** come from `scripts/bms_replay.py`, a port of the '
        "app's parser (`battery_protocol.dart`), metric table "
        '(`metrics.dart`), signed current (`battery_connection.dart`), '
        'interval rule and flags packing (`battery_log.dart`) and gap rules '
        '(`intervals.dart`). Raw logs: each `Notification (raw)` is parsed; '
        'the logger observes the state once per notification at the time of '
        'its last decoded-frame line (the app logs through an async stream). '
        'A handshake closes the open rows. Background-sampling mode is '
        'followed from the `background sampling every N s` / `continuous '
        'again` DIAG lines (with or without the old `#NN` tag).')
    add('- **Backfilled** = a derived row in a span where the same '
        "device's store has no row for that pack (store coverage widened by "
        '1 s). A row that straddles the store edge is clipped to the part '
        'outside and says so in `note`. The whole Python-tool period is '
        'backfilled (the tool wrote no app-style rows).')
    add('- **Demo** = every row of JS-9F031B, JS-5A77C0, RV-1180E2, and every '
        'JS-2C14AA row that starts inside a demo window (a span where those '
        'serials have rows, ±1 s). Demo frames were fed straight into the '
        'parser, so they have decoded lines in the raw log but no '
        '`Notification (raw)` line; they are never backfilled.')
    add('- **Shadow** = the losing device where two devices hold non-demo rows '
        'for one pack at the same time. The device that received more frames '
        'in the overlap holds the link and wins.')
    add('- **Lifetime totals** = the app integrator (`integrateCurrentRows`, '
        'each `packI` row held to the next row, bounded by the gap rule in '
        'effect) over the clean rows of all devices together, one fold per '
        'session, every fold in `lifetime_folds`.')
    add('')

    validation_section(m, L)
    for k, serial in enumerate(REAL):
        pack_section(m, L, serial, 'ab'[k])
    demo_section(m, L)
    overlap_section(m, L)
    findings_section(m, L)
    known_section(m, L)
    decisions_section(m, L, meta)
    reproduce_section(L)

    path = out / 'REPORT.md'
    with path.open('w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(L) + '\n')
    m.close()
    return path


def before_totals(m, serial) -> str:
    parts = []
    for dev, c, d, upto in q(m, 'SELECT device, total_charge_ah, '
                                'total_discharge_ah, aggregated_up_to FROM '
                                'lifetime_before WHERE serial = ? ORDER BY 1',
                             serial):
        parts.append(f'{dev} {ah(c)} in / {ah(d)} out (to {upto})')
    return '; '.join(parts) or 'none stored'


def validation_totals(m, device=None, serial=None):
    w = ["metric NOT IN ('rssi', 'efc')", "metric NOT LIKE '%swap test%'"]
    args = []
    if device:
        w.append('device = ?')
        args.append(device)
    if serial:
        w.append('serial = ?')
        args.append(serial)
    return m.execute(
        'SELECT SUM(store_rows), SUM(start_match), SUM(exact), '
        'SUM(end_store_earlier), SUM(end_store_later), SUM(link_rows), '
        'SUM(link_start_match), SUM(point_agree), SUM(point_checked), '
        'SUM(derived_rows), SUM(derived_unmatched), '
        'SUM(derived_unmatched_link) FROM validation_metric WHERE '
        + ' AND '.join(w), args).fetchone()


def validation_headline(m) -> str:
    n, st, ex, ee, el, lr, lm, pa, pc, dn, du, dul = validation_totals(m)
    return (f'{pct(st, n)} of {n:,} store rows re-derived with the same value '
            f'and start (±50 ms); {pct(st - lm, n - lr)} away from link starts; '
            f'{pct(pa, pc)} agree on the value at mid-row (section 4).')


def validation_section(m, L):
    add = L.append
    add('## 4. Validation of the decoder port')
    add('')
    add('Each device\'s raw log was re-derived and compared with the same '
        "device's store, metric by metric, inside the windows where both "
        'exist (`validation_windows`). Demo rows are left out; `rssi` (from '
        'the BLE scan, not in any frame) and `efc` (a per-connection running '
        'total) cannot be re-derived and are shown apart. A store row '
        '**matches** when a derived row has the same value and a start '
        'within 50 ms; **exact** when the end is also within 50 ms. A '
        '**link start** row starts in the first 3 s of a link (or of a '
        'window).')
    add('')
    rows = []
    for dev, serial in q(m, 'SELECT DISTINCT device, serial FROM '
                            'validation_metric ORDER BY 1, 2'):
        n, st, ex, ee, el, lr, lm, pa, pc, dn, du, dul = \
            validation_totals(m, dev, serial)
        rows.append([dev, serial, f'{n:,}', pct(st, n), pct(ex, n),
                     f'{pct(st - lm, n - lr)} ({st - lm:,}/{n - lr:,})',
                     f'{pct(lm, lr)} ({lm:,}/{lr:,})', pct(pa, pc),
                     f'{du:,} ({dul:,} at link start)'])
    L += table(['device', 'pack', 'store rows', 'match', 'exact',
                'match away from link starts', 'match at link starts',
                'value at mid-row', 'derived rows unmatched'], rows)
    add('')
    n, st, ex, ee, el, lr, lm, pa, pc, dn, du, dul = validation_totals(m)
    add(f'**All together:** {pct(st, n)} match ({st:,}/{n:,}), '
        f'{pct(ex, n)} exact; away from link starts {pct(st - lm, n - lr)}; '
        f'value at mid-row {pct(pa, pc)}.')
    add('')
    add('**Why rows differ (every category was inspected):**')
    add('')
    add(f'1. *Link starts* ({lr - lm:,} store rows unmatched, {dul:,} derived '
        'rows unmatched). At a new link the app\'s state is either carried '
        'over from the previous link (same connection object), seeded from '
        'the last-known record (#71 placeholders), or empty (a new object '
        'after an app start or demo toggle). The raw log does not say which. '
        'The replay starts empty after a demo episode or a >5 min silence of '
        'the log and carries over otherwise; either way the difference is '
        'the first second of a link, before every frame kind has arrived.')
    add(f'2. *Store end earlier than derived* ({ee:,} rows): the app writes an '
        'unchanged row\'s end about once a minute; when the app was killed or '
        'the store stopped writing, the frames of the last seconds reached '
        'the raw log but not the store. Those tails are backfilled.')
    add(f'3. *Store end later than derived* ({el:,} rows): the raw log was '
        'switched off (or lost its last buffered lines) while the store kept '
        'writing (#109).')
    add('4. *Away from link starts*: the few unmatched rows are at the raw-log '
        'holes in section 8 (lines the raw log lost, e.g. the 2 s write '
        'buffer at an app restart) and at two sampling-mode reconnects where '
        'the store split a row the raw log shows no reason to split.')
    add('')
    add('Per metric (all devices, excluding `rssi`/`efc` unless listed):')
    add('')
    rows = []
    for r in q(m, 'SELECT metric, SUM(store_rows), SUM(start_match), '
                  'SUM(exact), SUM(point_agree), SUM(point_checked), '
                  'SUM(link_rows), SUM(link_start_match) FROM validation_metric '
                  'GROUP BY metric ORDER BY metric'):
        metric, n, st, ex, pa, pc, lr, lm = r
        rows.append([metric, f'{n:,}', pct(st, n), pct(ex, n),
                     pct(st - lm, n - lr), pct(pa, pc)])
    L += table(['metric', 'store rows', 'match', 'exact',
                'match away from link starts', 'value at mid-row'], rows)
    add('')
    # temperatures (#114)
    t2 = q(m, "SELECT SUM(point_agree), SUM(point_checked) FROM "
              "validation_metric WHERE metric = 'temp2'")[0]
    t2s = q(m, "SELECT SUM(point_agree), SUM(point_checked) FROM "
               "validation_metric WHERE metric LIKE 'temp2 vs derived temp3%'")[0]
    t3 = q(m, "SELECT SUM(point_agree), SUM(point_checked) FROM "
              "validation_metric WHERE metric = 'temp3'")[0]
    t3s = q(m, "SELECT SUM(point_agree), SUM(point_checked) FROM "
               "validation_metric WHERE metric LIKE 'temp3 vs derived temp2%'")[0]
    add('**Temperature mapping (#114).** The port decodes from the bytes with '
        "the app's mapping temp0 = p0, temp1 = p1, temp3 = p2, temp2 = p3. "
        f'Stored temp2 agrees with p3 at {pct(*t2)} of rows and with p2 at '
        f'{pct(*t2s)}; stored temp3 agrees with p2 at {pct(*t3)} and with p3 '
        f'at {pct(*t3s)}. So the stored `temp2`/`temp3` keys hold p3/p2, the '
        'same swap as the raw-log text. Keys stay as they are (#114); read '
        'temp2 as byte p3 and temp3 as byte p2.')
    chip = q(m, "SELECT value_num, COUNT(*) FROM readings WHERE metric = "
                "'chip' AND demo = 0 GROUP BY value_num")
    chip_demo = q(m, "SELECT value_num, COUNT(*) FROM readings WHERE metric = "
                     "'chip' AND demo = 1 GROUP BY value_num")
    add('')
    add(f'**Chip temperature.** Non-demo `chip` rows by value: {chip}; demo '
        f'rows: {chip_demo}. The firmware leaves the byte at 0.')
    add('')
    sess = q(m, "SELECT metric, SUM(store_rows), SUM(start_match), "
                "SUM(point_agree), SUM(point_checked) FROM validation_metric "
                "WHERE metric IN ('rssi', 'efc') GROUP BY metric")
    for metric, n, st, pa, pc in sess:
        add(f'- `{metric}`: {n:,} store rows, {pct(st, n)} matched, '
            f'{pct(pa, pc)} at mid-row (not reproducible; see above). '
            + ('Raw-log backfilled rows carry no `rssi`; the Python period '
               'has the tool’s scan RSSI.' if metric == 'rssi' else
               'Backfilled `efc` restarts at 0 on each replay session.'))
    add('')
    st = dict(q(m, "SELECT device || ' ' || key, value FROM replay_stats"))
    add('**Framing check.** Frames parsed from notifications that also have '
        'the matching decoded-frame line the app wrote: phone '
        f'{st.get("phone decoded_paired", 0):,} of '
        f'{st.get("phone frames", 0):,}, Windows '
        f'{st.get("windows decoded_paired", 0):,} of '
        f'{st.get("windows frames", 0):,}. Decoded lines with no '
        f'notification: phone {st.get("phone decoded_unpaired", 0):,}, Windows '
        f'{st.get("windows decoded_unpaired", 0):,}, all inside the demo '
        'windows (section 6).')
    add('')
    add('Examples of every kind are in `validation_examples`.')
    add('')


def pack_section(m, L, serial, letter):
    add = L.append
    add(f'## 5{letter}. {serial}' + (' (alias "' + (one(m, 'SELECT alias FROM '
        'known_batteries WHERE serial = ?', serial) or '') + '")'
        if one(m, 'SELECT alias FROM known_batteries WHERE serial = ?',
               serial) else ''))
    add('')
    add('### Coverage by day (hours with readings, clean rows)')
    add('')
    srcs = [r[0] for r in q(m, "SELECT DISTINCT source FROM coverage_daily "
                               "WHERE serial = ? AND source <> 'ALL' "
                               "ORDER BY 1", serial)]
    days = [r[0] for r in q(m, 'SELECT DISTINCT day FROM coverage_daily WHERE '
                               'serial = ? ORDER BY 1', serial)]
    rows = []
    for day in days:
        vals = dict(q(m, 'SELECT source, covered_s FROM coverage_daily WHERE '
                         'serial = ? AND day = ?', serial, day))
        rows.append([day] + [f'{vals.get(s, 0) / 3600:.2f}' if vals.get(s)
                             else '' for s in srcs]
                    + [f'{vals.get("ALL", 0) / 3600:.2f}'])
    L += table(['day'] + srcs + ['any source'], rows)
    add('')
    add('Sources overlap in time only where noted in section 7; "any source" '
        'is their union. Hours are spans of readings joined by the gap rule '
        '(10 s, or the sample interval + 60 s in background sampling).')
    add('')
    add('### Flagged rows')
    add('')
    rows = [[r[0], f'{r[1]:,}', f'{r[2]:,}', f'{r[3]:,}', f'{r[4]:,}']
            for r in q(m, 'SELECT source, rows, demo, backfilled, shadow FROM '
                          'flag_counts WHERE serial = ? ORDER BY 1', serial)]
    L += table(['source', 'rows', 'demo', 'backfilled', 'shadow'], rows)
    add('')
    bw = backfill_windows(m, serial)
    if bw:
        add('### Backfilled from raw logs (the store has no rows there)')
        add('')
        L += table(['source', 'from', 'to', 'seconds', 'rows', 'clipped rows'],
                   bw)
        add('')
    py = q(m, "SELECT MIN(start_time), MAX(end_time), COUNT(*) FROM readings "
              "WHERE serial = ? AND source = 'python_db'", serial)[0]
    if py[2]:
        add(f'Python tool period: {py[2]:,} rows from {py[0]} to {py[1]}, '
            'all backfilled.')
        add('')
    add('### Gaps nobody observed (> 30 min)')
    add('')
    rows = [[r[0], r[1], f'{r[2]:,.0f}', r[3]] for r in q(
        m, 'SELECT from_time, to_time, minutes, context FROM unobserved_gaps '
           'WHERE serial = ? ORDER BY from_ms', serial)]
    L += table(['from', 'to', 'minutes', 'raw logs running / link attempts'],
               rows)
    add('')
    add('### Lifetime totals')
    add('')
    rows = []
    for dev, c, d, efc, upto in q(m, 'SELECT device, total_charge_ah, '
                                     'total_discharge_ah, total_efc, '
                                     'aggregated_up_to FROM lifetime_before '
                                     'WHERE serial = ? ORDER BY 1', serial):
        rows.append([f'before: {dev} store', ah(c), ah(d), f'{efc:.4f}', upto])
    for what, c, d, note in q(m, 'SELECT device || \': \' || what, charge_ah, '
                                 'discharge_ah, note FROM lifetime_check WHERE '
                                 'serial = ? ORDER BY device, what', serial):
        rows.append([f'check, {what}', ah(c), ah(d), '', note])
    a = q(m, 'SELECT total_charge_ah, total_discharge_ah, total_efc, '
             'aggregated_up_to, folds, rated_full_ah FROM lifetime_after '
             'WHERE serial = ?', serial)
    if a:
        c, d, efc, upto, folds, full = a[0]
        rows.append([f'**after: clean master ({folds} folds)**', f'**{ah(c)}**',
                     f'**{ah(d)}**', f'**{efc:.4f}**', upto])
    L += table(['', 'Ah in', 'Ah out', 'EFC', 'up to / note'], rows)
    add('')
    by_src = q(m, 'SELECT sources, SUM(charge_ah), SUM(discharge_ah), COUNT(*) '
                  'FROM lifetime_folds WHERE serial = ? GROUP BY sources '
                  'ORDER BY 1', serial)
    add('Where the clean total comes from (folds grouped by source):')
    add('')
    L += table(['sources in the fold', 'Ah in', 'Ah out', 'folds'],
               [[s, ah(c), ah(d), n] for s, c, d, n in by_src])
    add('')
    nz = q(m, 'SELECT fold, from_time, to_time, rows, sources, charge_ah, '
              'discharge_ah FROM lifetime_folds WHERE serial = ? AND '
              'charge_ah + discharge_ah >= 0.01 ORDER BY fold', serial)
    if nz:
        add('Folds that moved the total by 0.01 Ah or more (all folds are in '
            '`lifetime_folds`):')
        add('')
        L += table(['fold', 'from', 'to', 'rows', 'sources', 'Ah in',
                    'Ah out'], [[f, a, b, r, s, ah(c), ah(d)]
                                for f, a, b, r, s, c, d in nz])
        add('')
    explain_lifetime(m, L, serial)


def backfill_windows(m, serial):
    rows = q(m, "SELECT source, start_ms, end_ms, start_time, end_time, note "
                "FROM readings WHERE backfilled = 1 AND serial = ? AND source "
                "<> 'python_db' ORDER BY source, start_ms", serial)
    out = []
    cur = None
    for src, s, e, st, et, note in rows:
        clipped = 'clipped' in (note or '')
        if cur and cur[0] == src and s - cur[2] <= 10_000:
            cur[2] = max(cur[2], e)
            cur[4] = max(cur[4], et) if et else cur[4]
            cur[5] += 1
            cur[6] += clipped
        else:
            if cur:
                out.append(cur)
            cur = [src, s, e, st, et, 1, int(clipped)]
    if cur:
        out.append(cur)
    return [[c[0], c[3], c[4], f'{(c[2] - c[1]) / 1000:.1f}', c[5], c[6]]
            for c in out]


def explain_lifetime(m, L, serial):
    add = L.append
    demo_rows = q(m, "SELECT device, COUNT(*), MIN(value_num), MAX(value_num) "
                     "FROM readings WHERE serial = ? AND metric = 'packI' AND "
                     "demo = 1 GROUP BY device", serial)
    nonzero_real = one(m, "SELECT COUNT(*) FROM readings WHERE serial = ? AND "
                          "metric = 'packI' AND demo = 0 AND value_num <> 0",
                       serial)
    add('**Differences explained:**')
    add('')
    for dev, c0, d0 in q(m, 'SELECT device, total_charge_ah, '
                            'total_discharge_ah FROM lifetime_before WHERE '
                            'serial = ? ORDER BY 1', serial):
        chk = q(m, "SELECT charge_ah, discharge_ah FROM lifetime_check WHERE "
                   "device = ? AND serial = ? AND what = 'store rows up to its "
                   "watermark'", dev, serial)
        if chk:
            c, d = chk[0]
            same = abs(c - c0) < 1e-6 and abs(d - d0) < 1e-6
            add(f'- {dev}: the port recomputes the stored total from the '
                f"{dev} store's own rows as {ah(c)} / {ah(d)} Ah"
                + (' — identical, so the integrator port is exact.' if same
                   else f' (stored {ah(c0)} / {ah(d0)}).'))
    for dev, n, lo, hi in demo_rows:
        add(f'- {dev}: {n} demo `packI` rows ({lo} … {hi} A) under this '
            'serial; they are excluded from the clean total.')
    if nonzero_real == 0:
        add('- No non-demo `packI` row of this pack is non-zero: every Ah the '
            'devices stored for it came from demo mode, and the clean total '
            'is 0.')
    wnz = one(m, "SELECT COUNT(*) FROM readings WHERE serial = ? AND "
                 "source = 'windows_store' AND metric = 'packI' AND demo = 0 "
                 "AND value_num <> 0", serial)
    wwm = one(m, "SELECT aggregated_up_to FROM lifetime_before WHERE "
                 "device = 'windows' AND serial = ?", serial)
    wdemo = one(m, "SELECT MIN(start_time) FROM readings WHERE serial = ? AND "
                   "source = 'windows_store' AND demo = 1", serial)
    add(f'- Windows: {wnz} non-zero real `packI` rows, so its total is 0.'
        + (f' Its watermark ({wwm}) is the first demo reading ({wdemo}): the '
           'one fold that ran stopped there, so the demo current never '
           'reached the Windows total.' if wdemo else ''))
    for dev, st, v, so, ma, nxt in q(
            m, 'SELECT device, start_time, value, store_only_ah, master_ah, '
               'next_row FROM lifetime_row_diffs WHERE serial = ? ORDER BY '
               'start_time', serial):
        add(f'- {dev} row {st} ({v} A): {ah(so)} Ah in the store alone, '
            f'{ah(ma)} Ah in the master. In the store it is the last reading, '
            f'held only to its own end; in the master the next reading is '
            f'{nxt}, so the app rule holds it up to the gap threshold in '
            'effect (sample interval + 60 s in background sampling). The '
            'phone would add the same on its next fold.')
    back = q(m, "SELECT SUM(charge_ah), SUM(discharge_ah) FROM lifetime_folds "
                "WHERE serial = ? AND sources LIKE '%raw%'", serial)[0]
    py = q(m, "SELECT SUM(charge_ah), SUM(discharge_ah) FROM lifetime_folds "
              "WHERE serial = ? AND sources LIKE '%python%'", serial)[0]
    add(f'- Folds that include backfilled raw-log rows add {ah(back[0])} Ah in '
        f'/ {ah(back[1])} Ah out; the Python-tool period adds {ah(py[0])} / '
        f'{ah(py[1])} Ah.')
    add('')


def demo_section(m, L):
    add = L.append
    add('## 6. Demo rows (#115)')
    add('')
    rows = [list(r) for r in q(
        m, 'SELECT device, from_time, to_time, demo_only_rows, '
           'real_serial_rows, aa_start_times, aa_starts_within_20ms, '
           'aa_signature_rows FROM demo_windows ORDER BY device, from_ms')]
    L += table(['device', 'from', 'to', 'demo-serial rows',
                'JS-2C14AA rows (flagged demo)', 'JS-2C14AA row start times',
                '… within 20 ms of a demo-serial row start',
                'JS-2C14AA rows with chip 24 / cycles 7'], rows)
    add('')
    meta = dict(q(m, 'SELECT key, value FROM meta'))
    add('Chip 24 and cycles 7 are demo-generator constants '
        '(`demo_source.dart`); real rows of either pack carry them '
        f'{meta.get("phone_signature_rows_outside_demo_windows")} times on '
        f'the phone and {meta.get("windows_signature_rows_outside_demo_windows")}'
        ' times on Windows outside these windows. Correction to #115/#116: '
        'the four serials do not start rows at the *same* millisecond (each '
        'demo pack has its own 1 s timer); they start within about 20 ms of '
        'each other.')
    add('')
    sig = q(m, 'SELECT device, COUNT(*), SUM(demo_signature), MIN(at_time), '
               'MAX(at_time) FROM unpaired_decoded GROUP BY device')
    add('Evidence: the demo generator\'s frames (temperatures `20 1c 20 1e` = '
        '[32, 28, 32, 30], chip byte 24, cycles 7) appear in the raw logs '
        'only as decoded lines with no `Notification (raw)` before them: '
        + '; '.join(f'{d} {n} lines ({s} carry the temperature/ALL_DATA '
                    f'signature) {a} … {b}' for d, n, s, a, b in sig) + '.')
    add('The stores\' demo rows before the raw log began (phone, 19 Sep '
        '18:24–18:25) are identified by the demo-only serials alone.')
    add('')


def overlap_section(m, L):
    add = L.append
    add('## 7. Overlaps between devices (shadow)')
    add('')
    rows = q(m, 'SELECT serial, from_time, to_time, devices, winner, rule, '
                'shadow_rows FROM overlaps ORDER BY serial, from_ms')
    if not rows:
        add('No two devices hold non-demo readings for the same pack at the '
            'same time, so no row is `shadow`. The packs moved between '
            'devices (hand-offs), e.g. phone → Windows → phone for JS-2C14B8 '
            'on 20 Sep 20:19–20:42. The rule is implemented and will flag '
            'rows if a later pull has real overlaps.')
    else:
        L += table(['pack', 'from', 'to', 'devices', 'winner', 'rule',
                    'shadow rows'], [list(r) for r in rows])
    add('')


def findings_section(m, L):
    add = L.append
    add('## 8. Findings and anything suspicious')
    add('')
    # store-write losses: backfilled raw windows that are not clipped tails
    losses = []
    for serial in REAL:
        for src, a, b, secs, n, clipped in backfill_windows(m, serial):
            if clipped == 0:
                losses.append([serial, src, a, b, secs, n])
    if losses:
        add('**Frames received but never written to the store (#112).** The '
            'phone store has no rows at all in these spans (checked: the store '
            'row ids are consecutive across each span, and nothing was '
            'written after 23 Sep 11:24), while the raw log has the frames. '
            'This happened on several days, not only 24 Sep:')
        add('')
        L += table(['pack', 'source', 'from', 'to', 'seconds', 'rows'], losses)
        add('')
    big = q(m, "SELECT serial, source, MIN(value_num), MIN(start_time), "
               "MAX(end_time) FROM readings WHERE metric = 'packI' AND demo = 0 "
               "AND value_num < -50 GROUP BY serial, source")
    if big:
        add('**Heavy discharges.** Clean rows with more than 50 A out: '
            + '; '.join(f'{s} ({src}) down to {v} A between {a} and {b}'
                        for s, src, v, a, b in big)
            + '. They count in the lifetime totals; the backfilled one was '
            'missing from every store.')
        add('')
    hole = q(m, "SELECT device, serial, SUM(store_rows - start_match - "
                "(link_rows - link_start_match)) FROM validation_metric "
                "WHERE metric NOT IN ('rssi','efc') AND metric NOT LIKE "
                "'%swap%' GROUP BY 1, 2")
    add('**Raw-log holes.** Store rows away from link starts that the raw log '
        'cannot reproduce: ' + ', '.join(f'{d} {s}: {n}' for d, s, n in hole)
        + '. Inspected one by one. Phone: 8 rows at 21 Sep 15:07:28.6–.7 '
        '(JS-2C14B8, during an 89 A discharge) — the raw log jumps from '
        '15:07:28.128 to 15:07:36 and the app then reconnects from scratch, '
        'consistent with the app restarting and losing its 2 s raw-log write '
        'buffer; and 4 `sampleMode`/`sampleIntervalS` rows at 21 Sep 08:10:22 '
        'and 08:24:57 where the store split a row with no handshake in the '
        'raw log. Windows: 1 `firmware` row 3 s after a link start (that '
        "link began with an empty state in the app; the replay carried the "
        'firmware over). The raw log '
        'also has no lines from 19 Sep 21:21 to 20 Sep 20:09 (logging '
        'switched off, #109) and none before 19 Sep 20:38 (phone) — the '
        'store is the only record there.')
    add('')
    add('**JS-2C14AA has sent no telemetry since 20 Sep 07:03:18** (last '
        'reading in any source); every later contact is a handshake without '
        'frames (see its trailing gap and WAKE-INVESTIGATION.md §0).')
    add('')
    add('**Python tool.** It stored an alarm frame only when a bit was set '
        '(`if hits:` in its `_warn`), so all-clear current/voltage alarm '
        'frames were received but not kept; see decision 3. Its per-pack '
        '`.log` files are exact subsets of `battery.db`. Its early rows '
        '(18 Sep, before 22:00) have no raw bytes; they were rebuilt from the '
        'decoded text where that is lossless, and `temp0`/`temp3` are '
        'missing there because the tool decoded only p1 and p3.')
    add('')
    add('**Stored `efc` and `rssi`** are session values (a running total per '
        'connection object; the scan RSSI). They are kept as stored but '
        'should not be read as history.')
    add('')


def known_section(m, L):
    add = L.append
    add('## 8a. Known batteries (for #110)')
    add('')
    rows = [list(r) for r in q(m, 'SELECT serial, alias, is_demo, first_seen, '
                                  'last_seen, last_soc, last_pack_v, '
                                  'last_full_ah, firmware, devices FROM '
                                  'known_batteries ORDER BY is_demo, serial')]
    L += table(['serial', 'alias', 'demo', 'first seen', 'last seen',
                'last SOC', 'last V', 'full Ah', 'firmware', 'devices'], rows)
    add('')
    add('Demo serials (demo = 1) must not appear in a "known batteries" list.')
    add('')


def decisions_section(m, L, meta):
    add = L.append
    add('## 9. Decisions for you')
    add('')
    add('1. **Sign off this master** (or name what to change). Nothing is '
        'imported until you decide.')
    add('2. **Import into the apps?** The #104 import could load the clean '
        'history into the phone and Windows (backup kept). Proposed: yes, '
        'as a later step, using `clean_readings` only, and resetting each '
        "device's `lifetime_totals` to the clean figures with the folds "
        'recorded (#97).')
    add('3. **Python period `flags`.** The tool never stored all-clear '
        'current/voltage alarm frames. This build '
        + ('TAKES THEM AS CLEAR' if meta.get('infer_clear_alarms_python') ==
           'True' else 'does NOT take them as clear')
        + ' so the packed `flags` row (charge state, load, charger, MOS, '
        'faults) exists for 18–19 Sep; those rows say so in `note`. The '
        'alternative (`--no-infer-clear-alarms`) is what the app itself would '
        'have done: no `flags` rows for that period.')
    add('4. **Overlap rule.** Implemented as "more frames in the overlap '
        'wins"; it flagged nothing in this data. Confirm it for the future.')
    add('5. **Demo rows** stay in `readings` flagged `demo = 1` (keep-all-data '
        'rule). Confirm they should also be left out of any import.')
    add('')


def reproduce_section(L):
    add = L.append
    add('## 10. Reproduce')
    add('')
    add('From `projects/awto-bms`:')
    add('')
    add('```')
    add('python scripts/clean_history.py all --out logs/clean-20260924 \\')
    add('    --pull logs/pull-20260924-1458 --old-pull logs/pull-20260924 \\')
    add('    --python-logs C:/git/awto-sphere/python_ble/logs')
    add('python -m unittest discover -s scripts -p "test_*.py"')
    add('```')
    add('')
    add('`freeze` refuses to overwrite a frozen file with different content; '
        '`build` re-hashes `sources/` against `SHA256SUMS` before it reads '
        'anything and rebuilds `master.db` from scratch.')


if __name__ == '__main__':
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from clean_history import Clock
    print(write_report(Path(sys.argv[1]), Clock(8)))
