"""Tests for build_import.py (#119).

Run from projects/awto-bms:
    python -m unittest discover -s scripts -p "test_*.py"
"""
from __future__ import annotations

import contextlib
import io
import json
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_import as bi  # noqa: E402
import clean_history as ch  # noqa: E402

CLOCK = ch.Clock(8.0)
T0 = CLOCK.to_ms('2026-09-21 13:00:00.000')

ANDROID_XML = """<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="flutter.fleet_records_v1">VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu![]</string>
    <boolean name="flutter.verbose_logging_v1" value="true" />
    <string name="flutter.battery_aliases_v1">{&quot;JS-2C14AA&quot;:&quot;Broke A@&quot;}</string>
    <string name="flutter.fleet_serials_v1">VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!["JS-2C14B8"]</string>
    <long name="flutter.background_sample_interval_v1" value="300" />
    <string name="flutter.scale_v1">VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu1.25</string>
    <string name="other.not_ours">x</string>
</map>
"""


class PrefsTest(unittest.TestCase):
    def test_android_xml_decodes_to_the_export_encoding(self):
        p = bi.prefs_from_android_xml(ANDROID_XML)
        self.assertEqual(p, {
            'background_sample_interval_v1': {'t': 'int', 'v': 300},
            'battery_aliases_v1': {'t': 'string',
                                   'v': '{"JS-2C14AA":"Broke A@"}'},
            'fleet_records_v1': {'t': 'stringList', 'v': []},
            'fleet_serials_v1': {'t': 'stringList', 'v': ['JS-2C14B8']},
            'scale_v1': {'t': 'double', 'v': 1.25},
            'verbose_logging_v1': {'t': 'bool', 'v': True},
        })

    def test_android_old_binary_list_is_refused(self):
        xml = ('<map><string name="flutter.x">VGhpcyBpcyB0aGUgcHJlZml4IGZvciBh'
               'IGxpc3Qurt0ABXNy</string></map>')
        with self.assertRaises(bi.BuildError):
            bi.prefs_from_android_xml(xml)

    def test_windows_json_types_and_window_bounds_never_imported(self):
        p = bi.prefs_from_windows_json(json.dumps({
            'flutter.fleet_serials_v1': ['JS-2C14AA'],
            'flutter.window_bounds_v1': '{"left":10.0}',
            'flutter.temp_fahrenheit_v1': False,
            'flutter.background_sample_interval_v1': 300,
            'flutter.scale_v1': 1.0,
        }))
        self.assertEqual(p['temp_fahrenheit_v1'], {'t': 'bool', 'v': False})
        self.assertEqual(p['background_sample_interval_v1'],
                         {'t': 'int', 'v': 300})
        self.assertEqual(p['scale_v1'], {'t': 'double', 'v': 1.0})
        keep, skipped = bi.importable_prefs(p)
        self.assertEqual(skipped, ['window_bounds_v1'])
        self.assertNotIn('window_bounds_v1', keep)


def _row(serial, metric, v, s, e):
    return (serial, metric, v, None, CLOCK.fmt(s), CLOCK.fmt(e), s, e)


class Fixture:
    """A small master.db (built with clean_history's own schema and lifetime
    recompute) and matching device stores."""

    def __init__(self, d: Path):
        self.d = d
        # phone store rows 1..6 (row 3 is demo-window AA, row 4 a demo pack)
        self.phone = [
            _row('JS-2C14B8', 'packI', -10.0, T0, T0 + 60_000),
            _row('JS-2C14B8', 'fullAh', 100.0, T0, T0 + 60_000),
            _row('JS-2C14AA', 'packI', -5.0, T0 + 200_000, T0 + 201_000),
            _row('JS-9F031B', 'packI', -5.0, T0 + 200_000, T0 + 201_000),
            _row('JS-2C14B8', 'packI', 2.0, T0 + 65_000, T0 + 120_000),
            _row('JS-2C14AA', 'soc', 90.0, T0 + 300_000, T0 + 310_000),
        ]
        self.windows = [_row('JS-2C14AA', 'soc', 91.0, T0 - 90_000,
                             T0 - 80_000)]
        self.master = d / 'master.db'
        m = sqlite3.connect(self.master)
        m.executescript(ch.SCHEMA)
        m.executescript(ch.VIEWS)
        for dev, rows in (('phone', self.phone), ('windows', self.windows)):
            for i, r in enumerate(rows, 1):
                demo = int(r[0] == 'JS-9F031B' or (dev == 'phone' and i == 3))
                m.execute(
                    'INSERT INTO readings (device, source, orig_id, serial, '
                    'metric, value_num, value_text, start_time, end_time, '
                    'start_ms, end_ms, demo, backfilled, shadow, note) VALUES '
                    '(?,?,?,?,?,?,?,?,?,?,?,?,0,0,?)',
                    (dev, f'{dev}_store', i, *r, demo,
                     'demo-mode row (#115)' if demo else None))
        # a Python-period backfilled flags row with its inferred-alarm note
        py = _row('JS-2C14B8', 'flags', 4.0, T0 - 3_600_000, T0 - 3_500_000)
        m.execute(
            'INSERT INTO readings (device, source, orig_id, serial, metric, '
            'value_num, value_text, start_time, end_time, start_ms, end_ms, '
            'demo, backfilled, shadow, note) VALUES '
            "('python','python_db',NULL,?,?,?,?,?,?,?,?,0,1,0,?)",
            (*py, 'derived from python frames (bms_replay); current/voltage '
             'alarm taken as clear'))
        m.execute("INSERT INTO meta VALUES ('observed_until', ?)",
                  (CLOCK.fmt(T0 + 400_000),))
        m.execute("INSERT INTO meta VALUES ('built_at', '2026-09-24 16:22:03')")
        ch.recompute_lifetime(m, CLOCK)
        m.commit()
        m.close()

    def store(self, name: str, rows, lifetime=()) -> Path:
        p = self.d / name
        if p.exists():
            p.unlink()
        db = sqlite3.connect(p)
        for ddl in bi.APP_DDL:
            db.execute(ddl)
        db.executemany(
            'INSERT INTO readings (id, serial, metric, value_num, value_text, '
            'start_time, end_time, start_ms, end_ms) VALUES (?,?,?,?,?,?,?,?,?)',
            [(i, *r) for i, r in enumerate(rows, 1)])
        db.executemany('INSERT INTO lifetime_totals VALUES (?,?,?,?,?,?)',
                       lifetime)
        db.execute('PRAGMA user_version = 4')
        db.commit()
        db.close()
        return p

    def inputs(self, phone_rows, windows_rows=None):
        prefs_p = self.d / 'phone.xml'
        prefs_p.write_text(ANDROID_XML, encoding='utf-8')
        prefs_w = self.d / 'shared_preferences.json'
        prefs_w.write_text(json.dumps({'flutter.window_bounds_v1': 'x',
                                       'flutter.fleet_serials_v1': []}),
                           encoding='utf-8')
        ps = self.store('phone.db', phone_rows)
        ws = self.store('windows.db', windows_rows or self.windows)
        with tempfile.TemporaryDirectory() as t:
            return {
                'phone': bi.device_input('phone', str(ps), str(prefs_p), None,
                                         Path(t)),
                'windows': bi.device_input('windows', str(ws), str(prefs_w),
                                           None, Path(t)),
            }


class BuildTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.d = Path(self._tmp.name)
        self.fx = Fixture(self.d)

    def tearDown(self):
        self._tmp.cleanup()

    def build(self, phone_rows, windows_rows=None):
        return bi.build(self.fx.master,
                        self.fx.inputs(phone_rows, windows_rows),
                        self.d / 'out', CLOCK)

    def test_master_only_gives_the_signed_off_totals_and_app_schema(self):
        res = self.build(self.fx.phone)
        m = sqlite3.connect(self.fx.master)
        want = m.execute('SELECT serial, total_charge_ah, total_discharge_ah, '
                         'aggregated_up_to_ms FROM lifetime_after').fetchall()
        n_clean = m.execute('SELECT COUNT(*) FROM clean_readings').fetchone()[0]
        m.close()
        db = sqlite3.connect(res.db)
        self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 4)
        self.assertEqual(db.execute('SELECT COUNT(*) FROM readings').fetchone(
            )[0], n_clean)
        got = db.execute('SELECT serial, total_charge_ah, total_discharge_ah, '
                         'aggregated_up_to_ms FROM lifetime_totals').fetchall()
        self.assertEqual(sorted(got), sorted(want))
        # no demo rows, ids 1..N in time order, the inferred-alarm note kept
        serials = {r[0] for r in db.execute('SELECT serial FROM readings')}
        self.assertNotIn('JS-9F031B', serials)
        starts = [r[0] for r in db.execute(
            'SELECT start_ms FROM readings ORDER BY id')]
        self.assertEqual(starts, sorted(starts))
        note = db.execute(
            "SELECT p.note FROM readings r JOIN import_provenance p USING (id) "
            "WHERE r.metric = 'flags'").fetchone()[0]
        self.assertIn('alarm taken as clear', note)
        self.assertGreater(db.execute(
            'SELECT COUNT(*) FROM import_lifetime_folds').fetchone()[0], 0)
        db.close()

    def test_zip_has_the_export_format_and_device_settings(self):
        res = self.build(self.fx.phone)
        with zipfile.ZipFile(res.zips['windows']) as z:
            self.assertEqual(set(z.namelist()), {
                'manifest.json', 'battery_intervals.db', 'readings.csv',
                'settings.json'})
            man = json.loads(z.read('manifest.json'))
            settings = json.loads(z.read('settings.json'))
            csv_lines = z.read('readings.csv').decode().splitlines()
        self.assertEqual((man['format'], man['formatVersion'],
                          man['schemaVersion']), ('awto-bms-export', 1, 4))
        self.assertEqual(man['database']['readings'],
                         man['cleanImport']['readings'])
        self.assertEqual(settings, {'fleet_serials_v1': {'t': 'stringList',
                                                         'v': []}})
        self.assertEqual(csv_lines[0], ','.join(bi.CSV_COLS))
        self.assertEqual(len(csv_lines) - 1, man['database']['readings'])
        with zipfile.ZipFile(res.zips['phone']) as z:
            phone_settings = json.loads(z.read('settings.json'))
        self.assertIn('battery_aliases_v1', phone_settings)

    def test_newer_device_rows_are_merged_and_folded(self):
        newer = self.fx.phone + [
            _row('JS-2C14B8', 'packI', -20.0, T0 + 500_000, T0 + 560_000),
            _row('RV-1180E2', 'soc', 40.0, T0 + 900_000, T0 + 901_000),
        ]
        base = self.build(self.fx.phone).lifetime['JS-2C14B8']
        res = self.build(newer)
        f = res.fresh['phone']
        self.assertEqual((len(f.new), f.demo_excluded), (1, 1))
        lt = res.lifetime['JS-2C14B8']
        self.assertAlmostEqual(lt.discharge_ah - base.discharge_ah,
                               20.0 * 60 / 3600)
        self.assertEqual(lt.up_to_ms, T0 + 560_000)
        self.assertEqual(len(lt.folds), len(base.folds) + 1)

    def test_a_grown_last_row_takes_its_new_end(self):
        grown = list(self.fx.phone)
        r = grown[5]
        grown[5] = (*r[:5], CLOCK.fmt(r[7] + 5000), r[6], r[7] + 5000)
        res = self.build(grown)
        self.assertEqual(len(res.fresh['phone'].extended), 1)
        db = sqlite3.connect(res.db)
        end = db.execute("SELECT end_ms FROM readings WHERE metric = 'soc' AND "
                         "value_num = 90.0").fetchone()[0]
        db.close()
        self.assertEqual(end, r[7] + 5000)

    def test_refuses_a_different_store_or_overlapping_rows(self):
        changed = list(self.fx.phone)
        changed[0] = _row('JS-2C14B8', 'packI', -11.0, T0, T0 + 60_000)
        with self.assertRaises(bi.BuildError):
            self.build(changed)
        overlap = self.fx.phone + [
            _row('JS-2C14B8', 'packI', -3.0, T0 + 30_000, T0 + 40_000)]
        with self.assertRaises(bi.BuildError):
            self.build(overlap)
        both = self.fx.phone + [
            _row('JS-2C14B8', 'soc', 80.0, T0 + 700_000, T0 + 710_000)]
        with self.assertRaises(bi.BuildError):
            self.build(both, self.fx.windows + [
                _row('JS-2C14B8', 'soc', 80.0, T0 + 705_000, T0 + 715_000)])

    def test_cli_writes_report_and_zips(self):
        self.fx.inputs(self.fx.phone)      # writes the input files
        out = self.d / 'cli'
        with contextlib.redirect_stdout(io.StringIO()):
            rc = bi.main([
                '--master', str(self.fx.master), '--out', str(out),
                '--phone-store', str(self.d / 'phone.db'),
                '--phone-prefs', str(self.d / 'phone.xml'),
                '--windows-store', str(self.d / 'windows.db'),
                '--windows-prefs', str(self.d / 'shared_preferences.json')])
        self.assertEqual(rc, 0)
        rep = (out / 'IMPORT-REPORT.md').read_text(encoding='utf-8')
        self.assertIn('Before and after', rep)
        self.assertTrue((out / 'awto-bms-import-phone.zip').is_file())
        self.assertTrue((out / 'awto-bms-import-windows.zip').is_file())


if __name__ == '__main__':
    unittest.main()
