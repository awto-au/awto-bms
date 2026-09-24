"""Tests for publish_snapshot.py (#90). No network; nothing is pushed.

Run from projects/awto-bms:
    python -m unittest discover -s scripts -p "test_*.py"
"""
from __future__ import annotations

import argparse
import contextlib
import io
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import publish_snapshot as ps  # noqa: E402

PREFIX = 'projects/awto-bms/'

# A fake project: what must survive and what must be stripped.
KEEP = {
    'README.md': b'# AWTO BMS\n',
    'lib/main.dart': b'void main() {}\n',
    'lib/sections/fleet.dart': b'// password gates are not used\n',
    'android/app/build.gradle.kts': b'android {}\n',
    'artifacts/rv-battery-1.0.4/PROVENANCE.md': b'# provenance\n',
    'artifacts/rv-battery-1.0.4/screenshots/01.png': b'\x89PNG\r\n\x1a\n\x00',
    'docs/PROTOCOL.md': b'# protocol\n',
    'scripts/merge_history.py': b'print(1)\n',
}
STRIP = {
    'artifacts/rv-battery-1.0.4/jadx/sources/a/B.java': 'artifacts/*/jadx',
    'artifacts/rv-battery-1.0.4/jadx/resources/res/x.xml': 'artifacts/*/jadx',
    'artifacts/rv-battery-1.0.4/apktool/AndroidManifest.xml':
        'artifacts/*/apktool',
    'artifacts/rv-battery-1.0.4/unpacked-base/classes.dex':
        'artifacts/*/unpacked-base',
    'artifacts/rv-battery-1.0.4/raw/manifest.json': 'artifacts/*/raw',
    'artifacts/_comparison/other.txt': 'artifacts/_comparison',
    'artifacts/rv-battery-1.0.4/RVBattery-1.0.4.xapk': '*.xapk',
    'somewhere/deep/thing.apk': '*.apk',
    'windows/libfoo.so': '*.so',
    'docs/extra/Notes.java': '*.java',
    'docs/Sphere_Battery_User_Guide.pdf': '*.pdf',
    'docs/Sphere_Lithium_Batteries_Brochure.PDF': '*.pdf',
    'docs/bundle.zip': '*.zip',
    'logs/pull/battery_intervals.db': 'logs',
    'python_ble/logs/run.csv': 'python_ble/logs',
    'data/history.db': '*.db',
    'android/key.properties': '*/key.properties',
    'android/upload.jks': '*.jks',
}


def make_tar(files: dict[str, bytes], prefix: str = PREFIX,
             links: dict[str, str] | None = None) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as tar:
        for rel, content in files.items():
            info = tarfile.TarInfo(prefix + rel)
            info.size = len(content)
            tar.addfile(info, io.BytesIO(content))
        for rel, target in (links or {}).items():
            info = tarfile.TarInfo(prefix + rel)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            tar.addfile(info)
    return buf.getvalue()


def all_files() -> dict[str, bytes]:
    files = dict(KEEP)
    files.update({rel: b'private\n' for rel in STRIP})
    return files


class TmpCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix='publish-test-'))

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, tree: Path, rel: str, content: bytes) -> None:
        path = tree / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)


class StripRuleTest(unittest.TestCase):
    def test_every_private_path_is_stripped_by_its_rule(self):
        for rel, rule in STRIP.items():
            with self.subTest(rel=rel):
                hit = ps.strip_rule(rel)
                self.assertIsNotNone(hit)
                self.assertEqual(hit[0], rule)

    def test_public_paths_are_kept(self):
        for rel in KEEP:
            with self.subTest(rel=rel):
                self.assertIsNone(ps.strip_rule(rel))

    def test_build_rule_is_top_level_only(self):
        self.assertIsNotNone(ps.strip_rule('build/app/out.txt'))
        self.assertIsNone(ps.strip_rule('android/app/build.gradle.kts'))


class SplitTarTest(TmpCase):
    def test_split_keeps_public_and_records_stripped(self):
        data = make_tar(all_files(), links={'lib/link.dart': 'main.dart'})
        snap = ps.split_tar(data, PREFIX, 'HEAD', 'abc123')
        self.assertEqual(set(snap.kept), set(KEEP))
        self.assertEqual({p for p, _, _ in snap.stripped}, set(STRIP))
        self.assertEqual(snap.skipped,
                         [('lib/link.dart', 'not a regular file (link)')])
        self.assertEqual(snap.kept['lib/main.dart'], KEEP['lib/main.dart'])

    def test_outside_project_is_skipped(self):
        data = make_tar({'projects/other/x.txt': b'x'}, prefix='')
        snap = ps.split_tar(data, PREFIX, 'HEAD', 'abc')
        self.assertEqual(snap.kept, {})
        self.assertEqual(snap.skipped, [('projects/other/x.txt',
                                         'outside project')])

    def test_unsafe_path_refused(self):
        data = make_tar({'../escape.txt': b'x'})
        with self.assertRaises(ps.PublishError):
            ps.split_tar(data, PREFIX, 'HEAD', 'abc')

    def test_stage_writes_tree_and_refuses_non_empty(self):
        snap = ps.split_tar(make_tar(all_files()), PREFIX, 'HEAD', 'abc')
        tree = self.tmp / 'out' / 'tree'
        ps.stage(snap, tree)
        staged = {p.relative_to(tree).as_posix() for p in ps.walk(tree)}
        self.assertEqual(staged, set(KEEP))
        self.assertEqual(ps.verify(tree), [])
        with self.assertRaises(ps.PublishError):
            ps.stage(snap, tree)


class ExportFromGitTest(TmpCase):
    def test_export_reads_committed_files_only(self):
        repo = self.tmp / 'repo'
        project = repo / 'projects' / 'awto-bms'
        for rel, content in all_files().items():
            self.write(project, rel, content)
        self.write(repo, 'projects/other/secret.txt', b'other project\n')

        def git(*args: str) -> None:
            subprocess.run(['git', '-C', str(repo), *args], check=True,
                           capture_output=True)

        git('init', '--quiet')
        git('add', '--all')
        git('-c', 'user.name=t', '-c', 'user.email=t@example.com',
            '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', 'x')
        # Uncommitted: must not appear.
        self.write(project, 'lib/uncommitted.dart', b'// wip\n')

        snap = ps.export(repo, 'awto-bms', 'HEAD')
        self.assertEqual(set(snap.kept), set(KEEP))
        self.assertEqual({p for p, _, _ in snap.stripped}, set(STRIP))
        self.assertEqual(len(snap.commit), 40)


class VerifyTest(TmpCase):
    def tree_with(self, rel: str, content: bytes) -> Path:
        tree = self.tmp / 'tree'
        self.write(tree, 'lib/main.dart', b'void main() {}\n')
        self.write(tree, rel, content)
        return tree

    def kinds(self, tree: Path, **kw) -> list[tuple[str, str]]:
        return [(h.path, h.kind) for h in ps.verify(tree, **kw)]

    def test_clean_tree_passes(self):
        tree = self.tree_with('docs/a.md', b'# fine\npassword = input()\n')
        self.assertEqual(ps.verify(tree), [])

    def test_forbidden_path(self):
        tree = self.tree_with('artifacts/x/jadx/A.java', b'class A {}\n')
        self.assertIn(('artifacts/x/jadx/A.java', 'forbidden path'),
                      self.kinds(tree))

    def test_renamed_archive_caught_by_magic(self):
        tree = self.tree_with('assets/icon.png', b'PK\x03\x04rest')
        self.assertIn(('assets/icon.png', 'forbidden content'),
                      self.kinds(tree))

    def test_renamed_elf_pdf_sqlite_caught(self):
        for magic in (b'\x7fELF\x02', b'%PDF-1.7', b'SQLite format 3\x00'):
            with self.subTest(magic=magic):
                tree = self.tmp / f'tree-{magic[:2].hex()}'
                self.write(tree, 'docs/readme.txt', magic + b'\x00')
                self.assertIn(('docs/readme.txt', 'forbidden content'),
                              self.kinds(tree))

    def test_oversize(self):
        tree = self.tree_with('assets/big.bin', b'x' * 2000)
        self.assertIn(('assets/big.bin', 'too large'),
                      self.kinds(tree, max_file_bytes=1000))
        self.assertEqual(ps.verify(tree, max_file_bytes=5000), [])

    def test_secrets(self):
        # Built by concatenation so this file never trips the real verify.
        token = 'ghp' + '_' + 'A1b2C3d4' * 5
        samples = {
            'a.pem.txt': ('-----BEGIN RSA ' + 'PRIVATE KEY-----\n').encode(),
            'b.dart': f"const t = '{token}';\n".encode(),
            'c.properties': ('store' + 'Password=hunter2hunter2\n').encode(),
            'd.py': ('API' + "_KEY = 'abcdefghijklmnop1234'\n").encode(),
            'e.txt': ('AKIA' + 'ABCDEFGHIJKLMNOP\n').encode(),
        }
        for rel, content in samples.items():
            with self.subTest(rel=rel):
                tree = self.tmp / f'tree-{rel}'
                self.write(tree, rel, content)
                self.assertIn((rel, 'secret-looking string'),
                              self.kinds(tree))

    def test_review_is_listed_not_fatal(self):
        tree = self.tree_with(
            'docs/a.md',
            b'mail x@example.com, mac 00:11:22:33:44:55, DEFAULT_BACK_PSW\n')
        self.assertEqual(ps.verify(tree), [])
        kinds = {h.kind for h in ps.review(tree)}
        self.assertEqual(kinds, {'email address', 'MAC address',
                                 'vendor password constant'})


class PushGuardTest(unittest.TestCase):
    def ns(self, **kw) -> argparse.Namespace:
        base = dict(push=True, repo='awto-au/awto-bms', i_confirm_public=True)
        base.update(kw)
        return argparse.Namespace(**base)

    def test_dry_run_needs_nothing(self):
        ps.check_push_args(self.ns(push=False, repo=None,
                                   i_confirm_public=False))

    def test_full_confirmation_passes(self):
        ps.check_push_args(self.ns())

    def test_refusals(self):
        for kw in (dict(repo=None), dict(repo='awto-bms'),
                   dict(repo='awto-au/awto-apps'),
                   dict(repo='awto-au/awto-sphere'),
                   dict(i_confirm_public=False)):
            with self.subTest(kw=kw):
                with self.assertRaises(ps.PublishError):
                    ps.check_push_args(self.ns(**kw))


class CliTest(unittest.TestCase):
    def run_main(self, argv: list[str]) -> tuple[int, str]:
        err = io.StringIO()
        with contextlib.redirect_stderr(err), \
                contextlib.redirect_stdout(io.StringIO()):
            code = ps.main(argv)
        return code, err.getvalue()

    def test_project_required(self):
        code, err = self.run_main([])
        self.assertEqual(code, 2)
        self.assertIn('--project is required', err)

    def test_other_project_refused(self):
        code, err = self.run_main(['--project', 'awto-leveller'])
        self.assertEqual(code, 2)
        self.assertIn('awto-bms only', err)

    def test_push_without_confirmation_refused_before_any_work(self):
        code, err = self.run_main(['--project', 'awto-bms', '--push',
                                   '--repo', 'awto-au/awto-bms'])
        self.assertEqual(code, 2)
        self.assertIn('--i-confirm-public', err)


if __name__ == '__main__':
    unittest.main()
