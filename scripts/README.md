# awto-bms scripts

Python only, stdlib only. Run from `projects/awto-bms`. Captured data lives
under `logs/` (git-ignored); never commit it.

| Script | What it does |
|---|---|
| `merge_history.py` | Side-by-side merge of device stores and raw logs into one query DB (#108). Rows are not deduplicated or flagged. |
| `clean_history.py` | The single data clean-up (#116): freeze inputs with SHA-256, build `master.db` (store rows unchanged + backfill from raw frames, flags `demo` / `backfilled` / `shadow`), validate the decoder port, recompute lifetime totals with every fold recorded, write `REPORT.md`. |
| `bms_replay.py` | Port of the app's frame parser, metric table, interval rule, flags packing and Ah integrator. Used by `clean_history.py`. |
| `clean_report.py` | Writes `REPORT.md` from `master.db`. Called by `clean_history.py report`. |
| `ui_matrix.py` | Runs the UI size matrix widget test (#100) with PNGs on: main screens in demo mode at phone and desktop sizes, both text scales, real fonts; fails on any overflow. PNGs in `build/ui_matrix/` (git-ignored). |
| `build_import.py` | Per-device import zips (the app's #104 export format) from the signed-off `master.db`, with each device's newest rows merged in and its own settings kept (#119). Writes `IMPORT-REPORT.md`. |
| `publish_snapshot.py` | Builds and verifies the public snapshot of this project (#90) in `logs/publish-staging/`. Pushes only with `--push --repo ... --i-confirm-public`. |

## Clean-up (#116)

```
python scripts/clean_history.py all --out logs/clean-20260924 \
    --pull logs/pull-20260924-1458 --old-pull logs/pull-20260924 \
    --python-logs C:/git/awto-sphere/python_ble/logs
```

`freeze` copies every input to `<out>/sources/` and writes `SHA256SUMS` and
`manifest.json`; it refuses to overwrite a frozen file with different content.
`build` re-checks the hashes, then rebuilds `<out>/master.db` from the frozen
copies only. `report` writes `<out>/REPORT.md`. Nothing is imported into the
apps.

In `master.db`, `clean_readings` (a view: `demo = 0 AND shadow = 0`) is the
clean history. Other tables: `lifetime_before` / `lifetime_after` /
`lifetime_folds`, `validation_*`, `coverage_daily`, `unobserved_gaps`,
`demo_windows`, `overlaps`, `known_batteries`, `derived_readings` (every row
re-derived from raw frames, with `in_store`).

Keep `bms_replay.py` in step with `lib/battery_protocol.dart`,
`lib/metrics.dart`, `lib/battery_log.dart` and `lib/intervals.dart` when those
change.

## Import into the apps (#119)

Right before importing, re-pull each device: in the app, Settings → Data →
Export all data (that zip is also the backup). Then rebuild, so every reading
recorded since the master was built is merged in:

```
python scripts/build_import.py --master logs/clean-20260924/master.db \
    --phone-export <phone export zip> --windows-export <windows export zip> \
    --out logs/import-<date>
```

`--<device>-store` + `--<device>-prefs` (an adb pull: `battery_intervals.db`
and `FlutterSharedPreferences.xml` / `shared_preferences.json`) work instead
of `--<device>-export`. Output: `awto-bms-import-phone.zip`,
`awto-bms-import-windows.zip`, the store they carry and `IMPORT-REPORT.md`
(before/after per pack and device, the device steps). Only `clean_readings`
goes in; `lifetime_totals` holds the clean figures, the folds (#97) and each
row's source and note go in the side tables `import_lifetime_folds` and
`import_provenance`. Each zip keeps that device's own settings;
`window_bounds_v1` is never written. The build stops, writing nothing, when a
device store is not the one the master was built from, or its new rows
overlap the master or the other device's new rows.

Check each zip with the app's own import code (stage, apply, open with
`BatteryLogger`, compare counts and totals, re-fold the totals):

```
$env:AWTO_IMPORT_ZIP = '<phone zip>;<windows zip>'   # PowerShell
flutter test test/clean_import_119_test.dart
```

## UI size matrix (#100)

```
python scripts/ui_matrix.py                     # all sizes, PNGs to build/ui_matrix/
python scripts/ui_matrix.py --only 1280x800     # one size
python scripts/ui_matrix.py --lock <flutter_lock.py>   # wait for other Flutter runs
```

The same test runs in the normal `flutter test` suite without writing PNGs.
Widget tests only: no emulator, app build or connected device.

## Public snapshot (#90)

The public repo awto-au/awto-bms carries a stripped copy of this project
(CLAUDE.md, "Private material"). Dry run (the default; nothing leaves the
machine):

```
python scripts/publish_snapshot.py --project awto-bms [--ref HEAD] [--out logs/publish-staging/<name>]
```

It takes `git archive <ref>` of `projects/awto-bms` (committed files only;
uncommitted work and git-ignored `logs/`, databases and build output never
enter), strips `artifacts/*/{jadx,apktool,unpacked-base,raw}`,
`artifacts/_comparison`, `*.apk *.xapk *.so *.java *.class *.dex *.pdf *.zip`
(the vendor PDFs included), `logs/`, databases, logs, signing keys and
`key.properties` / `local.properties` / `.env`, and writes the rest to
`<out>/tree/`. Then VERIFY scans the staged tree on its own and fails (exit 1)
on any forbidden path, a zip/APK, ELF, PDF, SQLite, class or dex file under
any name (magic bytes), a file over `--max-file-bytes` (default 1 MB), or a
secret-looking string (private key, GitHub/AWS/Slack/Google tokens, signing
passwords, hard-coded credentials). A REVIEW list (email addresses, MAC
addresses, vendor `DEFAULT_*PSW/PASSWORD/PWD` constants) is printed for a
human to judge; it does not fail the run. `<out>/manifest.json` lists every
file with size and SHA-256, every stripped path with its rule, and the verify
and review results. An existing, non-empty `--out` is refused.

Public push, only with the user's decision to keep publishing:

```
python scripts/publish_snapshot.py --project awto-bms \
    --push --repo awto-au/awto-bms --i-confirm-public
```

It refuses without an explicit `--repo` and `--i-confirm-public`, and refuses
the private repos (awto-au/awto-apps, awto-au/awto-sphere). It re-verifies,
clones the repo into `<out>/public-clone`, replaces its files with the staged
tree and pushes one ordinary commit (no force push; history is kept).

## Tests

```
python -m unittest discover -s scripts -p "test_*.py"
```
