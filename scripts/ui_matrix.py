#!/usr/bin/env python3
"""Run the UI size matrix (#100) and write its PNGs for review.

Runs `test/ui_matrix_100_test.dart` with `--dart-define=UI_MATRIX_PNG=true`:
the app's main screens in demo mode (DEMO-1..4) at 360x640, 400x800, 412x915,
900x600, 1280x800 and 1920x1080, at text scale 1.0 and (desktop sizes) the
Windows 0.75 scale, with real fonts. The test fails on any overflow / layout
error, naming the size and screen. PNGs go to `build/ui_matrix/` (git-ignored;
the test clears it first) and the folder is printed at the end.

Only widget tests run: no emulator, no app build, no connected device.

Run from `projects/awto-bms`:

    python scripts/ui_matrix.py
    python scripts/ui_matrix.py --only 1280x800
    python scripts/ui_matrix.py --lock <path to flutter_lock.py>

`--lock` (or the FLUTTER_LOCK environment variable) runs flutter through a
machine-wide lock script (`python <lock> flutter ...`), so it waits for any
other Flutter build or test on this machine to finish first.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
TEST = 'test/ui_matrix_100_test.dart'
OUT = PROJECT / 'build' / 'ui_matrix'
SDK_FLUTTER = Path(r'C:\src\flutter\bin\flutter.bat')


def find_flutter() -> str:
    """flutter on PATH, else the SDK at C:\\src\\flutter (this laptop)."""
    found = shutil.which('flutter')
    if found:
        return found
    if SDK_FLUTTER.exists():
        return str(SDK_FLUTTER)
    sys.exit('flutter not found: put it on PATH or pass --lock')


def build_command(lock: str | None, only: str | None,
                  flutter: str = 'flutter') -> list[str]:
    """The command line: `flutter test <matrix> --dart-define=...`, through
    the lock script when one is given."""
    args = ['test', TEST, '--dart-define=UI_MATRIX_PNG=true']
    if only:
        args += ['--plain-name', only]
    if lock:
        return [sys.executable, lock, 'flutter', *args]
    return [flutter, *args]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--lock', default=os.environ.get('FLUTTER_LOCK'),
                    help='flutter lock script (default: $FLUTTER_LOCK)')
    ap.add_argument('--only', metavar='TEXT',
                    help='run only the combinations whose name contains TEXT, '
                         'e.g. 1280x800 or win075')
    a = ap.parse_args(argv)
    if a.lock and not Path(a.lock).exists():
        sys.exit(f'lock script not found: {a.lock}')
    cmd = build_command(a.lock, a.only,
                        flutter='' if a.lock else find_flutter())
    print('+', ' '.join(cmd), flush=True)
    code = subprocess.call(cmd, cwd=PROJECT)
    pngs = sorted(OUT.glob('*.png')) if OUT.exists() else []
    print(f'\n{len(pngs)} PNGs in {OUT}')
    if code != 0:
        print('UI matrix FAILED (see the errors above: size, screen, message)')
    return code


if __name__ == '__main__':
    sys.exit(main())
