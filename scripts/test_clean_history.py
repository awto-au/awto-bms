"""Tests for bms_replay.py and clean_history.py (#116).

Run from projects/awto-bms:
    python -m unittest discover -s scripts -p "test_*.py"
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bms_replay as br  # noqa: E402
import clean_history as ch  # noqa: E402

H = bytes.fromhex
# Real frames from the phone raw log (21 Sep 2026, JS-2C14B8).
VOL = H('a0c104be0cc70cc30cb40cb1d2')
TEMP = H('a14f23272723b2e3')
ALL_89A = H('a2578200' '5f5c01010000' '8200c70cb40c1300792d0000bf0cb36c')
MOS = H('a39f010100000000b4c7')
WARN_CUR = H('a48b0000000000b5dd')
WARN_VOL = H('a599000000000000000000b617')
WARN_TEMP = H('a6c000000000000000b772')
OTHER = H('a74e00000000000000b829')
BAL_DIS = H('a8ac02010100010000b921')
SOC = H('a96463a08601b88201ba5e')
EST = H('aaaf000000780f00bb22')
CYCLE = [VOL, TEMP, ALL_89A, MOS, WARN_CUR, WARN_VOL, WARN_TEMP, OTHER,
         BAL_DIS, SOC, EST]
# An idle cycle as the Python tool stored it: no all-clear alarm frames.
ALL_IDLE = H('a2578500000000000000850007' '0d050d020000000000060db36c')
BAL_IDLE = H('a8ac00010100010000b921')
PY_CYCLE = [VOL, TEMP, ALL_IDLE, MOS, WARN_TEMP, OTHER, BAL_IDLE, SOC, EST]


class ParserTest(unittest.TestCase):
    def test_all_data_scaling_matches_the_app(self):
        p = br.Parser()
        p.add_bytes(ALL_89A)
        s = p.state
        # The app's decoded line for this frame: V=13.0 I=89.1A P=1164.1W
        # sum=13.0 max=3.27 min=3.25 ... chip=0C cyc=0
        self.assertEqual(s.pack_voltage, 13.0)
        self.assertEqual(s.pack_current, 89.1)
        self.assertEqual(s.power, 1164.1)
        self.assertEqual((s.cell_max, s.cell_min, s.cell_sum), (3.27, 3.25, 13.0))
        self.assertEqual((s.chip_temperature, s.cycle_count), (0, 0))
        self.assertTrue(s.load_connected)
        self.assertFalse(s.charger_connected)

    def test_temperature_bytes_follow_the_app_mapping(self):
        p = br.Parser()
        p.add_bytes(H('a14f211f2021b2e3'))   # p0..p3 = 33 31 32 33
        s = p.state
        self.assertEqual((s.temp0, s.temp1, s.temp2, s.temp3), (33, 31, 33, 32))

    def test_signed_temperature(self):
        p = br.Parser()
        p.add_bytes(H('a14ffbfe0001b2e3'))
        self.assertEqual((p.state.temp0, p.state.temp1), (-5, -2))

    def test_vol_is_count_prefixed(self):
        p = br.Parser()
        p.add_bytes(VOL)
        self.assertEqual(p.state.cells_mv, [3262, 3271, 3267, 3252])

    def test_split_and_coalesced_notifications(self):
        p = br.Parser()
        self.assertEqual(p.add_bytes(SOC[:5]), [])
        out = p.add_bytes(SOC[5:] + EST)
        self.assertEqual([k for k, _ in out], ['soc', 'est'])
        self.assertEqual(out[0][1], SOC)
        self.assertEqual((p.state.soc_percent, p.state.remaining_ah,
                          p.state.full_ah), (99, 99.0, 100.0))
        self.assertEqual(p.state.time_to_empty_sec, 3960)

    def test_resync_counts_stray_bytes_and_at_status(self):
        p = br.Parser()
        p.add_bytes(b'\x55' + MOS)
        self.assertEqual(p.state.unrecognised_bytes, 1)
        p.at_version_sent = True
        p.add_bytes(b'\x30')
        self.assertEqual(p.at_status_bytes, 1)
        self.assertEqual(p.state.unrecognised_bytes, 1)

    def test_bad_end_sentinel_resyncs(self):
        p = br.Parser()
        out = p.add_bytes(H('a39f010100000000b4c8') + MOS)
        self.assertEqual([k for k, _ in out], ['mos'])

    def test_soc_clamps_at_100(self):
        p = br.Parser()
        p.add_bytes(H('a964ffa08601a08601ba5e'))
        self.assertEqual(p.state.soc_percent, 100)

    def test_flags_need_every_category(self):
        p = br.Parser()
        for f in CYCLE:
            p.add_bytes(f)
        # discharging (2 << 10) + disMos + chgMos + load + mos = 2075, the
        # value the phone store has for this cycle.
        self.assertEqual(br.pack_flags(p.state), 2075)
        q = br.Parser()
        q.add_bytes(MOS + BAL_DIS + ALL_89A + WARN_TEMP)
        self.assertIsNone(br.pack_flags(q.state))   # no current/voltage alarm

    def test_signed_current_follows_charge_state(self):
        p = br.Parser()
        p.add_bytes(ALL_89A)
        self.assertEqual(br.signed_current(p.state), 0.0)   # unknown state
        p.add_bytes(BAL_DIS)
        self.assertEqual(br.signed_current(p.state), -89.1)
        self.assertEqual(br.signed_power(p.state), -1164.1)


class IntervalTest(unittest.TestCase):
    def test_extend_change_and_gap(self):
        lg = br.IntervalLogger()
        for t, v in [(0, 1.0), (1000, 1.0), (2000, 2.0), (13_001, 2.0),
                     (14_000, 2.0)]:
            lg.observe_value('S', 'm', t, v)
        lg.close_all()
        self.assertEqual([(r.value_num, r.start_ms, r.end_ms) for r in lg.rows],
                         [(1.0, 0, 1000), (2.0, 2000, 2000),
                          (2.0, 13_001, 14_000)])

    def test_sampling_widens_the_gap(self):
        lg = br.IntervalLogger()
        lg.sample_interval_ms = 300_000
        lg.observe_value('S', 'm', 0, 1.0)
        lg.observe_value('S', 'm', 300_000, 1.0)
        lg.close_all()
        self.assertEqual(len(lg.rows), 1)

    def test_disconnect_closes_rows(self):
        lg = br.IntervalLogger()
        lg.observe_value('S', 'm', 0, 1.0)
        lg.disconnect('S')
        lg.observe_value('S', 'm', 500, 1.0)
        lg.close_all()
        self.assertEqual(len(lg.rows), 2)

    def test_observe_logs_the_metric_table(self):
        sess = br.Session('S')
        for f in CYCLE:
            sess.parser.add_bytes(f)
        lg = br.IntervalLogger()
        lg.observe(sess, 1000)
        lg.close_all()
        got = {r.metric: r.value_num for r in lg.rows}
        self.assertEqual(got['packI'], -89.1)
        self.assertEqual(got['temp2'], 35.0)   # p3
        self.assertEqual(got['temp3'], 39.0)   # p2
        self.assertEqual(got['flags'], 2075.0)
        self.assertEqual(got['cell4'], 3.252)
        self.assertEqual(got['overTempLatched'], 0.0)
        self.assertNotIn('rssi', got)
        self.assertEqual(got['sampleIntervalS'], 0.0)


class LifetimeTest(unittest.TestCase):
    def rows(self, spec):
        return [br.Row('S', 'packI', v, None, a, b) for v, a, b in spec]

    def test_hold_to_next_row_bounded_by_gap(self):
        rows = self.rows([(-3.6, 0, 0), (-3.6, 1000, 1000), (0.0, 60_000,
                                                             60_000)])
        c, d, newest = br.integrate_current_rows(rows)
        # 1 s held to the next row + 10 s (gap bound) into the offline gap.
        self.assertAlmostEqual(d, 3.6 * 11 / 3600)
        self.assertEqual((c, newest), (0.0, 60_000))

    def test_watermark_counts_only_after_it(self):
        rows = self.rows([(7.2, 0, 1000), (7.2, 1000, 3000)])
        c, _, _ = br.integrate_current_rows(rows, watermark_ms=1000)
        self.assertAlmostEqual(c, 7.2 * 2 / 3600)

    def test_policy_hold_in_sampling(self):
        pol = br.GapPolicy([(0, 300.0)])
        rows = self.rows([(-2.5, 0, 0), (0.0, 1_000_000, 1_000_000)])
        _, d, _ = br.integrate_current_rows(rows, policy=pol)
        self.assertAlmostEqual(d, 2.5 * 360 / 3600)

    def test_per_row_split_sums_to_the_total(self):
        rows = self.rows([(-1.0, 0, 500), (2.0, 700, 900), (0.0, 20_000,
                                                            21_000)])
        pol = br.GapPolicy()
        parts = ch.per_row_ah(rows, pol)
        c, d, _ = br.integrate_current_rows(rows, policy=pol)
        self.assertAlmostEqual(sum(p[0] for p in parts), c)
        self.assertAlmostEqual(sum(p[1] for p in parts), d)


class HelpersTest(unittest.TestCase):
    def test_clock_fixed_offset_round_trip(self):
        c = ch.Clock(8)
        ms = c.to_ms('2026-09-20 02:23:41.258')
        self.assertEqual(ms, 1789842221258)   # the Windows store's start_ms
        self.assertEqual(c.fmt(ms), '2026-09-20 02:23:41.258')
        self.assertIsNone(c.to_ms('20 Sep'))

    def test_parse_raw_lines(self):
        n = ch.parse_raw_line('2026-09-21 15:07:26.161  JS-2C14B8  '
                              'Notification (raw)     a0 c1 04 be 0c c7 0c c3 '
                              '0c b4 0c b1 d2   13 bytes')
        self.assertEqual(n[2], 'notif')
        self.assertEqual(n[3], VOL)
        d = ch.parse_raw_line('2026-09-21 15:07:26.174  JS-2C14B8  '
                              'Temperatures           a1 4f 23 27 27 23 b2 e3'
                              '   t0=35C t1=39C t2=35C t3=39C')
        self.assertEqual((d[2], d[3]), ('decoded:Temperatures', TEMP))
        t = ch.parse_raw_line('2026-09-19 20:38:46.999  JS-2C14AA  TX: request '
                              'time estimate c4 7d f4 d5 86   sent')
        self.assertEqual((t[2], t[3]), ('tx:request time estimate',
                                        H('c47df4d586')))
        g = ch.parse_raw_line('2026-09-21 11:03:10.307  -  DIAG             '
                              '      BatteryManager: #53 background sampling '
                              'every 300 s — releasing every pack')
        self.assertEqual(g[2], 'diag')
        self.assertTrue(ch.SAMPLING_ON.search(g[4]))
        self.assertTrue(ch.SAMPLING_ON.search('background sampling every 60 s'))

    def test_spans(self):
        self.assertEqual(ch.merge_spans([(10, 20), (0, 5), (23, 30)], 4),
                         [[0, 5], [10, 30]])
        self.assertEqual(ch.subtract_spans([[0, 100]], [[10, 20], [50, 60]]),
                         [[0, 10], [20, 50], [60, 100]])
        self.assertEqual(ch.subtract_spans([[15, 15]], [[10, 20]]), [])
        self.assertEqual(ch.subtract_spans([[30, 30]], [[10, 20]]), [[30, 30]])
        self.assertEqual(ch.intersect_spans([[0, 10], [20, 30]], [[5, 25]]),
                         [[5, 10], [20, 25]])

    def test_python_early_frames_rebuild_losslessly(self):
        b, _ = ch.python_early_frame(
            'soc', '100% remaining=100.0Ah full=100.0Ah',
            {'soc': 100, 'full': 100.0, 'rem': 100.0})
        self.assertEqual(b, H('a96464a08601a08601ba5e'))
        b, _ = ch.python_early_frame('est', 'toFull=00:00:00 toEmpty=100:00:00',
                                     {})
        self.assertEqual(b, H('aaaf000000407e05bb22'))
        b, _ = ch.python_early_frame(
            'bal', 'state=idle chgMos=True disMos=True passiveBal=False '
                   'tempGate=1 smokeGate=0 heatGate=0', {})
        self.assertEqual(b, H('a8ac00010100010000b921'))
        self.assertEqual(ch.python_early_frame('temp', '', {})[0], None)

    def test_compare_rows(self):
        store = [(1, 'S', 'm', 1.0, None, '', '', 1000, 5000)]
        res = ch.compare_rows(store, [br.Row('S', 'm', 1.0, None, 1020, 9000)])
        self.assertEqual((res['start'], res['exact'],
                          res['end_store_earlier']), (1, 0, 1))
        res = ch.compare_rows(store, [br.Row('S', 'm', 2.0, None, 1000, 5000)])
        self.assertEqual((res['start'], res['point_agree']), (0, 0))


# ---------------------------------------------------------------------------
# End to end on a tiny fixture: freeze + build never touch the sources, keep
# store rows unchanged, flag demo rows and backfill what the store lacks.
# ---------------------------------------------------------------------------

STORE_SQL = """
CREATE TABLE readings (id INTEGER PRIMARY KEY, serial TEXT NOT NULL,
  metric TEXT NOT NULL, value_num REAL, value_text TEXT,
  start_time TEXT NOT NULL, end_time TEXT NOT NULL, start_ms INTEGER,
  end_ms INTEGER);
CREATE TABLE lifetime_totals (serial TEXT PRIMARY KEY,
  total_charge_ah REAL NOT NULL DEFAULT 0,
  total_discharge_ah REAL NOT NULL DEFAULT 0,
  total_efc REAL NOT NULL DEFAULT 0, aggregated_up_to TEXT,
  aggregated_up_to_ms INTEGER);
CREATE TABLE alarm_events (id INTEGER PRIMARY KEY, serial TEXT NOT NULL,
  at_ms INTEGER NOT NULL);
"""


def _line(clock, ms, serial, label, raw=b'', tail=''):
    hx = raw.hex(' ')
    body = f'{label.ljust(22)} {hx}' + (f'   {tail}' if tail else '')
    return f'{clock.fmt(ms)}  {serial}  {body}\n'


class EndToEndTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.clock = c = ch.Clock(8)
        t0 = c.to_ms('2026-09-21 15:00:00.000')
        pull = root / 'pull'
        for dev in ('phone', 'windows'):
            (pull / dev).mkdir(parents=True)
            db = sqlite3.connect(pull / dev / 'battery_intervals.db')
            db.executescript(STORE_SQL)
            if dev == 'phone':
                rows = [
                    # real B8 rows, covering t0 .. t0+2 s
                    (1, 'JS-2C14B8', 'soc', 99.0, t0, t0 + 2000),
                    (2, 'JS-2C14B8', 'packI', -89.1, t0, t0 + 2000),
                    # a demo window: demo-only serial + AA at t0+10 min
                    (3, 'JS-9F031B', 'soc', 9.0, t0 + 600_000, t0 + 601_000),
                    (4, 'JS-2C14AA', 'chip', 24.0, t0 + 600_004,
                     t0 + 601_000),
                    (5, 'JS-2C14AA', 'packI', -22.0, t0 + 600_004,
                     t0 + 601_000),
                ]
                db.executemany(
                    'INSERT INTO readings VALUES (?,?,?,?,NULL,?,?,?,?)',
                    [(i, s, m, v, c.fmt(a), c.fmt(b), a, b)
                     for i, s, m, v, a, b in rows])
                db.execute("INSERT INTO lifetime_totals VALUES "
                           "('JS-2C14B8', 0, 0.0496, 0, ?, ?)",
                           (c.fmt(t0 + 2000), t0 + 2000))
            db.commit()
            db.close()
        with (pull / 'phone' / 'battery_raw.log').open('w', newline='\n') as f:
            f.write(_line(c, t0 - 50, 'JS-2C14B8', 'TX: handshake begin',
                          H('fbc87c9d26ec'), 'sent'))
            # frames the store has (t0 .. t0+2 s) ...
            for k, ms in enumerate((t0, t0 + 1000, t0 + 2000)):
                for fr in CYCLE:
                    f.write(_line(c, ms, 'JS-2C14B8', 'Notification (raw)', fr,
                                  f'{len(fr)} bytes'))
                    f.write(_line(c, ms, 'JS-2C14B8', 'Battery data'
                                  if fr is ALL_89A else _label(fr), fr, 'x'))
            # ... then 30 s later a new link the store never wrote (#112)
            f.write(_line(c, t0 + 30_000, 'JS-2C14B8', 'TX: handshake begin',
                          H('fbc87c9d26ec'), 'sent'))
            for ms in (t0 + 30_100, t0 + 31_100):
                for fr in CYCLE:
                    f.write(_line(c, ms, 'JS-2C14B8', 'Notification (raw)', fr,
                                  f'{len(fr)} bytes'))
                    f.write(_line(c, ms, 'JS-2C14B8', _label(fr), fr, 'x'))
            # a demo decoded line: no notification before it
            f.write(_line(c, t0 + 600_000, 'JS-2C14AA', 'Temperatures',
                          H('a14f201c201eb2e3'), 'x'))
        (pull / 'windows' / 'battery_raw.log').write_text('', newline='\n')
        py = root / 'py'
        py.mkdir()
        db = sqlite3.connect(py / 'battery.db')
        db.execute('CREATE TABLE battery_frames (id INTEGER PRIMARY KEY '
                   'AUTOINCREMENT, ts TEXT NOT NULL, serial TEXT NOT NULL, '
                   'frame TEXT NOT NULL, message TEXT, data TEXT)')
        tp = t0 - 86_400_000
        db.execute("INSERT INTO battery_frames (ts, serial, frame, message, "
                   "data) VALUES (?, 'JS-2C14AA', 'TX_BEGIN', 'sent', '{}')",
                   (c.fmt(tp),))
        for k, fr in enumerate(PY_CYCLE):
            db.execute("INSERT INTO battery_frames (ts, serial, frame, message,"
                       " data) VALUES (?, 'JS-2C14AA', 'RX_X', '', ?)",
                       (c.fmt(tp + 10 * k), json.dumps({'_raw': fr.hex(' ')})))
        db.commit()
        db.close()
        self.root, self.pull, self.py = root, pull, py
        self.hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in list(pull.rglob('*')) + list(py.rglob('*'))
                       if p.is_file()}

    def tearDown(self):
        self.tmp.cleanup()

    def test_freeze_build_report(self):
        out = self.root / 'clean'
        args = ['all', '--out', str(out), '--pull', str(self.pull),
                '--python-logs', str(self.py)]
        quiet = contextlib.redirect_stdout(io.StringIO())
        with quiet:
            self.assertEqual(ch.main(args), 0)
        # sources untouched
        for p, h in self.hashes.items():
            self.assertEqual(hashlib.sha256(p.read_bytes()).hexdigest(), h, p)
        m = sqlite3.connect(out / 'master.db')
        # every store row kept, unchanged
        got = m.execute("SELECT orig_id, serial, metric, value_num, start_ms, "
                        "end_ms FROM readings WHERE source = 'phone_store' "
                        "ORDER BY orig_id").fetchall()
        src = sqlite3.connect(self.pull / 'phone' / 'battery_intervals.db')
        want = src.execute('SELECT id, serial, metric, value_num, start_ms, '
                           'end_ms FROM readings ORDER BY id').fetchall()
        src.close()
        self.assertEqual(got, want)
        # demo flags: the demo-only serial and AA inside its window
        demo = dict(m.execute('SELECT orig_id, demo FROM readings WHERE '
                              "source = 'phone_store'").fetchall())
        self.assertEqual(demo, {1: 0, 2: 0, 3: 1, 4: 1, 5: 1})
        # backfill: only the link the store never wrote
        b = m.execute("SELECT MIN(start_ms), MAX(end_ms), COUNT(*) FROM "
                      "readings WHERE source = 'phone_raw' AND backfilled = 1"
                      ).fetchone()
        t0 = self.clock.to_ms('2026-09-21 15:00:00.000')
        self.assertGreaterEqual(b[0], t0 + 30_000)
        self.assertEqual(b[1], t0 + 31_100)
        # the python period is backfilled, with flags although the tool kept
        # no current/voltage alarm frame (taken as clear, decision 3)
        self.assertEqual(m.execute(
            "SELECT COUNT(*) FROM readings WHERE source = 'python_db' AND "
            "metric = 'flags'").fetchone()[0], 1)
        # validation found the stored rows in the raw log
        v = m.execute("SELECT SUM(start_match), SUM(store_rows) FROM "
                      "validation_metric WHERE metric = 'packI' AND device = "
                      "'phone'").fetchone()
        self.assertEqual(v, (1, 1))
        # lifetime: store check reproduces what the store alone gives
        after = m.execute("SELECT total_discharge_ah FROM lifetime_after WHERE "
                          "serial = 'JS-2C14B8'").fetchone()[0]
        self.assertGreater(after, 0.0496)   # + the backfilled 89 A link
        self.assertEqual(m.execute(
            "SELECT total_discharge_ah FROM lifetime_after WHERE serial = "
            "'JS-2C14AA'").fetchone()[0], 0.0)   # demo current excluded
        self.assertTrue((out / 'REPORT.md').is_file())
        m.close()
        # a second freeze with changed input is refused
        with (self.pull / 'phone' / 'battery_raw.log').open('a') as f:
            f.write('extra\n')
        with contextlib.redirect_stdout(io.StringIO()),                 contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ch.main(['freeze'] + args[1:]), 2)


def _label(frame: bytes) -> str:
    return {0xA0: 'Cell voltages', 0xA1: 'Temperatures', 0xA2: 'Battery data',
            0xA3: 'MOS status', 0xA4: 'Current alarm', 0xA5: 'Voltage alarm',
            0xA6: 'Temperature alarm', 0xA7: 'Other data',
            0xA8: 'Balancer status', 0xA9: 'State of charge',
            0xAA: 'Time estimate'}[frame[0]]


if __name__ == '__main__':
    unittest.main()
