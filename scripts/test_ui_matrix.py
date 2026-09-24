"""Tests for ui_matrix.py's command line (no Flutter run)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ui_matrix  # noqa: E402


class BuildCommandTest(unittest.TestCase):
    def test_direct(self):
        cmd = ui_matrix.build_command(None, None, flutter='flutter')
        self.assertEqual(cmd, ['flutter', 'test', ui_matrix.TEST,
                               '--dart-define=UI_MATRIX_PNG=true'])

    def test_through_the_lock(self):
        cmd = ui_matrix.build_command('lock.py', None)
        self.assertEqual(cmd[:4], [sys.executable, 'lock.py', 'flutter', 'test'])
        self.assertIn('--dart-define=UI_MATRIX_PNG=true', cmd)

    def test_only_filters_by_name(self):
        cmd = ui_matrix.build_command(None, '1280x800', flutter='flutter')
        self.assertEqual(cmd[-2:], ['--plain-name', '1280x800'])

    def test_output_is_git_ignored_build_dir(self):
        self.assertEqual(ui_matrix.OUT.relative_to(ui_matrix.PROJECT).parts,
                         ('build', 'ui_matrix'))


if __name__ == '__main__':
    unittest.main()
