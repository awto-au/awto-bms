#!/usr/bin/env python3
"""Build (and, only on explicit request, push) the public snapshot (#90).

The public repo awto-au/awto-bms carries a stripped copy of
projects/awto-bms. Vendor binaries, decompiled sources, the vendor PDFs and
captured data stay private (CLAUDE.md, "Private material").

Steps:

  export   `git archive <ref> -- projects/<project>`: committed files only,
           so git-ignored logs/, databases and build output never enter.
  strip    drop every path matching STRIP_RULES (recorded, with the rule).
  stage    write the kept files to <out>/tree/.
  verify   scan <out>/tree/ on its own: forbidden paths, forbidden file
           types by magic bytes (zip/apk, ELF, PDF, SQLite, Java class,
           dex), files over --max-file-bytes, and secret-looking strings.
           Any hit fails the run. A separate review list (email addresses,
           MAC addresses, vendor password constants) is printed for a human
           to judge; it does not fail the run.
  manifest <out>/manifest.json (every file, size, SHA-256; every stripped
           path and its rule; verify result) and a printed summary.

Nothing leaves this machine unless --push is given together with an explicit
--repo and --i-confirm-public. The push clones that repo into
<out>/public-clone, replaces its files with the staged tree, commits and
pushes a normal (non-force) commit. It re-runs verify first.

Usage (from projects/awto-bms):
    python scripts/publish_snapshot.py --project awto-bms
    python scripts/publish_snapshot.py --project awto-bms --ref HEAD \\
        --out logs/publish-staging/<name>
    # public push: never run without the user's say-so
    python scripts/publish_snapshot.py --project awto-bms \\
        --push --repo awto-au/awto-bms --i-confirm-public
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

SCRIPT_PROJECT = 'awto-bms'
PRIVATE_REPOS = {'awto-au/awto-apps', 'awto-au/awto-sphere'}
DEFAULT_MAX_FILE_BYTES = 1_000_000

# (glob on the project-relative POSIX path, reason). A path is stripped when
# it, or any parent folder of it, matches. fnmatch's `*` also crosses `/`,
# so `*.apk` covers every depth.
STRIP_RULES: list[tuple[str, str]] = [
    ('artifacts/*/jadx', 'decompiled vendor sources'),
    ('artifacts/*/apktool', 'decompiled vendor resources'),
    ('artifacts/*/unpacked-base', 'unpacked vendor APK'),
    ('artifacts/*/raw', 'vendor APK splits'),
    ('artifacts/_comparison', 'competitor APK evidence'),
    ('*.apk', 'vendor binary'),
    ('*.xapk', 'vendor binary'),
    ('*.so', 'native binary'),
    ('*.java', 'decompiled source'),
    ('*.class', 'compiled Java'),
    ('*.dex', 'compiled Android code'),
    ('*.pdf', 'vendor PDF'),
    ('*.zip', 'archive'),
    ('docs/Sphere_Battery_User_Guide.pdf', 'vendor PDF'),
    ('docs/Sphere_Lithium_Batteries_Brochure.pdf', 'vendor PDF'),
    # Private data: never committed, stripped anyway in case one is.
    ('logs', 'captured data'),
    ('python_ble/logs', 'captured data'),
    ('*.db', 'database'),
    ('*.db-journal', 'database'),
    ('*.db-wal', 'database'),
    ('*.db-shm', 'database'),
    ('*.sqlite', 'database'),
    ('*.sqlite3', 'database'),
    ('*.log', 'log'),
    ('*.jks', 'signing key'),
    ('*.keystore', 'signing key'),
    ('*.p12', 'signing key'),
    ('*.pfx', 'signing key'),
    ('*.pem', 'key material'),
    ('*.key', 'key material'),
    ('key.properties', 'signing config'),
    ('*/key.properties', 'signing config'),
    ('local.properties', 'machine-local config'),
    ('*/local.properties', 'machine-local config'),
    ('.env', 'environment secrets'),
    ('*/.env', 'environment secrets'),
    ('build', 'build output'),
    ('.dart_tool', 'build output'),
]

# Leading bytes of file types that must never be public, whatever the name.
FORBIDDEN_MAGIC: list[tuple[bytes, str]] = [
    (b'PK\x03\x04', 'zip/apk/xapk/jar archive'),
    (b'PK\x05\x06', 'zip archive (empty)'),
    (b'\x7fELF', 'ELF native binary (.so)'),
    (b'%PDF', 'PDF'),
    (b'SQLite format 3\x00', 'SQLite database'),
    (b'\xca\xfe\xba\xbe', 'Java class'),
    (b'dex\n', 'Android dex'),
]

# Secret-looking strings (text files only).
SECRET_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'), 'private key block'),
    (re.compile(r'\bAKIA[0-9A-Z]{16}\b'), 'AWS access key id'),
    (re.compile(r'\bgh[pousr]_[A-Za-z0-9]{36,}\b'), 'GitHub token'),
    (re.compile(r'\bgithub_pat_[A-Za-z0-9_]{22,}\b'), 'GitHub token'),
    (re.compile(r'\bxox[abprs]-[A-Za-z0-9-]{10,}'), 'Slack token'),
    (re.compile(r'\bAIza[0-9A-Za-z_-]{35}\b'), 'Google API key'),
    (re.compile(r'\bsk-(?:ant-)?[A-Za-z0-9_-]{32,}\b'), 'API secret key'),
    (re.compile(r'(?i)\b(?:store|key)Password\s*[=:]\s*\S+'),
     'signing password'),
    (re.compile(
        r'(?i)\b(?:api[_-]?key|secret|access[_-]?token|auth[_-]?token|'
        r'client[_-]?secret)\b\s*[:=]\s*[\'"][A-Za-z0-9/+_=-]{16,}[\'"]'),
     'hard-coded credential'),
]

# Worth a human look before going public; reported, never fatal.
REVIEW_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*'
                r'\.[A-Za-z]{2,}'), 'email address'),
    (re.compile(r'\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b'), 'MAC address'),
    (re.compile(r'\bDEFAULT_\w*(?:PSW|PASSWORD|PWD)\b'),
     'vendor password constant'),
]


class PublishError(Exception):
    """A refusal or failure; the message says what to do."""


@dataclass
class Snapshot:
    ref: str
    commit: str
    kept: dict[str, bytes] = field(default_factory=dict)
    stripped: list[tuple[str, str, str]] = field(default_factory=list)
    skipped: list[tuple[str, str]] = field(default_factory=list)


# --------------------------------------------------------------------------
# Rules

def strip_rule(rel: str) -> tuple[str, str] | None:
    """The first rule that strips `rel` (or a parent folder of it)."""
    parts = PurePosixPath(rel).parts
    candidates = ['/'.join(parts[:i]) for i in range(1, len(parts) + 1)]
    for pattern, reason in STRIP_RULES:
        for cand in candidates:
            if fnmatch.fnmatchcase(cand.lower(), pattern.lower()):
                return pattern, reason
    return None


# --------------------------------------------------------------------------
# Export + strip

def git(repo: Path, *args: str) -> bytes:
    proc = subprocess.run(['git', '-C', str(repo), *args],
                          capture_output=True, check=False)
    if proc.returncode != 0:
        raise PublishError(
            f'git {" ".join(args)} failed: '
            f'{proc.stderr.decode("utf-8", "replace").strip()}')
    return proc.stdout


def export(repo: Path, project: str, ref: str) -> Snapshot:
    """Read the committed project at `ref` and split it into kept/stripped."""
    commit = git(repo, 'rev-parse', '--verify', f'{ref}^{{commit}}') \
        .decode().strip()
    prefix = f'projects/{project}/'
    data = git(repo, 'archive', '--format=tar', commit, '--', prefix)
    return split_tar(data, prefix, ref, commit)


def split_tar(data: bytes, prefix: str, ref: str, commit: str) -> Snapshot:
    snap = Snapshot(ref=ref, commit=commit)
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as tar:
        for member in tar:
            if member.isdir():
                continue
            name = member.name
            if not name.startswith(prefix):
                snap.skipped.append((name, 'outside project'))
                continue
            rel = name[len(prefix):]
            if not rel:
                continue
            if not member.isfile():
                snap.skipped.append((rel, 'not a regular file (link)'))
                continue
            if '..' in PurePosixPath(rel).parts or rel.startswith('/'):
                raise PublishError(f'unsafe path in archive: {name}')
            rule = strip_rule(rel)
            if rule is not None:
                snap.stripped.append((rel, rule[0], rule[1]))
                continue
            fh = tar.extractfile(member)
            snap.kept[rel] = fh.read() if fh else b''
    return snap


def stage(snap: Snapshot, tree: Path) -> None:
    if tree.exists() and any(tree.iterdir()):
        raise PublishError(
            f'{tree} already has files. Pick a new --out; nothing is '
            f'overwritten or deleted.')
    for rel, content in sorted(snap.kept.items()):
        dest = tree / Path(*PurePosixPath(rel).parts)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
    tree.mkdir(parents=True, exist_ok=True)


# --------------------------------------------------------------------------
# Verify (independent of the strip: it looks only at the staged tree)

@dataclass
class Hit:
    path: str
    kind: str
    detail: str


def walk(tree: Path) -> list[Path]:
    return sorted(p for p in tree.rglob('*')
                  if p.is_file() and '.git' not in p.relative_to(tree).parts)


def looks_binary(head: bytes) -> bool:
    return b'\x00' in head


def verify(tree: Path, max_file_bytes: int = DEFAULT_MAX_FILE_BYTES
           ) -> list[Hit]:
    hits: list[Hit] = []
    for path in walk(tree):
        rel = path.relative_to(tree).as_posix()
        if path.is_symlink():
            hits.append(Hit(rel, 'symlink', 'links are not published'))
            continue
        rule = strip_rule(rel)
        if rule is not None:
            hits.append(Hit(rel, 'forbidden path', f'{rule[0]} ({rule[1]})'))
        size = path.stat().st_size
        if size > max_file_bytes:
            hits.append(Hit(rel, 'too large',
                            f'{size} bytes > {max_file_bytes}'))
        content = path.read_bytes()
        for magic, what in FORBIDDEN_MAGIC:
            if content.startswith(magic):
                hits.append(Hit(rel, 'forbidden content', what))
        if looks_binary(content[:8192]):
            continue
        text = content.decode('utf-8', 'replace')
        for lineno, line in enumerate(text.splitlines(), 1):
            for pattern, what in SECRET_PATTERNS:
                if pattern.search(line):
                    hits.append(Hit(rel, 'secret-looking string',
                                    f'line {lineno}: {what}'))
    return hits


def review(tree: Path) -> list[Hit]:
    """Non-fatal findings for a human: one Hit per file and kind."""
    found: list[Hit] = []
    for path in walk(tree):
        content = path.read_bytes()
        if looks_binary(content[:8192]):
            continue
        rel = path.relative_to(tree).as_posix()
        text = content.decode('utf-8', 'replace')
        for pattern, what in REVIEW_PATTERNS:
            matches = sorted(set(pattern.findall(text)))
            if matches:
                shown = ', '.join(matches[:5])
                more = f' (+{len(matches) - 5} more)' if len(matches) > 5                     else ''
                found.append(Hit(rel, what, shown + more))
    return found


# --------------------------------------------------------------------------
# Manifest

def build_manifest(snap: Snapshot, tree: Path, project: str,
                   hits: list[Hit], max_file_bytes: int,
                   notes: list[Hit] | None = None) -> dict:
    files = []
    for path in walk(tree):
        content = path.read_bytes()
        files.append({
            'path': path.relative_to(tree).as_posix(),
            'bytes': len(content),
            'sha256': hashlib.sha256(content).hexdigest(),
        })
    top: dict[str, dict[str, int]] = {}
    for f in files:
        head = f['path'].split('/', 1)[0] if '/' in f['path'] else '.'
        slot = top.setdefault(head, {'files': 0, 'bytes': 0})
        slot['files'] += 1
        slot['bytes'] += f['bytes']
    by_rule: dict[str, int] = {}
    for _, pattern, _ in snap.stripped:
        by_rule[pattern] = by_rule.get(pattern, 0) + 1
    return {
        'project': project,
        'ref': snap.ref,
        'commit': snap.commit,
        'built_at': dt.datetime.now(dt.timezone.utc).isoformat(
            timespec='seconds'),
        'max_file_bytes': max_file_bytes,
        'file_count': len(files),
        'total_bytes': sum(f['bytes'] for f in files),
        'top_level': dict(sorted(top.items())),
        'stripped_count': len(snap.stripped),
        'stripped_by_rule': dict(sorted(by_rule.items())),
        'verify': {
            'ok': not hits,
            'hits': [h.__dict__ for h in hits],
        },
        'review': [h.__dict__ for h in notes or []],
        'files': files,
        'stripped': [{'path': p, 'rule': r, 'reason': why}
                     for p, r, why in snap.stripped],
        'skipped': [{'path': p, 'reason': why} for p, why in snap.skipped],
    }


def human(n: int) -> str:
    size = float(n)
    for unit in ('B', 'KB', 'MB', 'GB'):
        if size < 1024 or unit == 'GB':
            return f'{size:.0f} {unit}' if unit == 'B' else \
                f'{size:.1f} {unit}'
        size /= 1024
    return f'{n} B'


def summary(manifest: dict, out: Path) -> str:
    lines = [
        f'Snapshot of projects/{manifest["project"]} at '
        f'{manifest["ref"]} ({manifest["commit"][:12]})',
        f'Staged: {out / "tree"}',
        f'Files: {manifest["file_count"]}   '
        f'Size: {human(manifest["total_bytes"])} '
        f'({manifest["total_bytes"]} bytes)',
        'Top level:',
    ]
    for name, slot in manifest['top_level'].items():
        lines.append(f'  {name:<24} {slot["files"]:>5} files  '
                     f'{human(slot["bytes"]):>10}')
    lines.append(f'Stripped: {manifest["stripped_count"]} files')
    for rule, count in manifest['stripped_by_rule'].items():
        lines.append(f'  {rule:<40} {count:>5}')
    for item in manifest['skipped']:
        lines.append(f'Skipped: {item["path"]} ({item["reason"]})')
    hits = manifest['verify']['hits']
    if hits:
        lines.append(f'VERIFY FAILED: {len(hits)} hit(s)')
        for h in hits:
            lines.append(f'  {h["kind"]}: {h["path"]}: {h["detail"]}')
    else:
        lines.append('VERIFY OK: no forbidden path, file type, oversize '
                     'file or secret-looking string.')
    if manifest['review']:
        lines.append(f'REVIEW (not fatal; judge before a public push): '
                     f'{len(manifest["review"])} item(s)')
        for h in manifest['review']:
            lines.append(f'  {h["kind"]}: {h["path"]}: {h["detail"]}')
    lines.append(f'Manifest: {out / "manifest.json"}')
    return '\n'.join(lines)


# --------------------------------------------------------------------------
# Push (explicit only)

def check_push_args(args: argparse.Namespace) -> None:
    if not args.push:
        return
    if not args.repo:
        raise PublishError('--push needs an explicit --repo OWNER/NAME.')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        raise PublishError(f'--repo must be OWNER/NAME, not {args.repo!r}.')
    if args.repo.lower() in PRIVATE_REPOS:
        raise PublishError(f'{args.repo} is a private repo; refusing.')
    if not args.i_confirm_public:
        raise PublishError(
            f'--push publishes to {args.repo} for anyone to read. Add '
            f'--i-confirm-public to confirm.')


def push(tree: Path, out: Path, repo: str, manifest: dict,
         max_file_bytes: int) -> None:
    hits = verify(tree, max_file_bytes)
    if hits:
        raise PublishError('verify failed just before push; not pushing.')
    clone = out / 'public-clone'
    if clone.exists():
        raise PublishError(f'{clone} exists; pick a new --out.')
    url = f'https://github.com/{repo}.git'
    proc = subprocess.run(['git', 'clone', '--quiet', url, str(clone)],
                          check=False)
    if proc.returncode != 0:
        raise PublishError(f'git clone {url} failed.')
    # Replace the clone's files with the staged tree (history is kept; the
    # removal is inside the throw-away clone only).
    for item in clone.iterdir():
        if item.name == '.git':
            continue
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()
    shutil.copytree(tree, clone, dirs_exist_ok=True)
    if verify(clone, max_file_bytes):
        raise PublishError('verify failed on the clone; not pushing.')
    git(clone, 'add', '--all')
    status = git(clone, 'status', '--porcelain').decode().strip()
    if not status:
        print(f'{repo} already matches this snapshot; nothing to push.')
        return
    message = (f'Snapshot of awto-apps projects/{manifest["project"]} at '
               f'{manifest["commit"][:12]}\n\n'
               f'{manifest["file_count"]} files, '
               f'{manifest["stripped_count"]} private files stripped '
               f'(scripts/publish_snapshot.py).\n')
    git(clone, 'commit', '--quiet', '-m', message)
    git(clone, 'push', '--quiet', 'origin', 'HEAD')
    print(f'Pushed to {repo}.')


# --------------------------------------------------------------------------
# CLI

def resolve_project(project: str | None) -> Path:
    if not project:
        raise PublishError(
            '--project is required (this script refuses to guess).')
    if project != SCRIPT_PROJECT:
        raise PublishError(
            f'this script publishes {SCRIPT_PROJECT} only, not {project!r}.')
    here = Path(__file__).resolve().parent.parent
    if here.name != project:
        raise PublishError(f'script is not inside projects/{project}.')
    return here


def default_out(project_dir: Path) -> Path:
    stamp = dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    return project_dir / 'logs' / 'publish-staging' / stamp


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description='Build, verify and (only when asked) push the public '
                    'snapshot of a project (#90).')
    p.add_argument('--project', help='project under projects/ (required)')
    p.add_argument('--ref', default='HEAD',
                   help='git ref to snapshot (committed files only)')
    p.add_argument('--out', type=Path,
                   help='staging folder (default: '
                        'logs/publish-staging/<timestamp>, git-ignored)')
    p.add_argument('--max-file-bytes', type=int,
                   default=DEFAULT_MAX_FILE_BYTES)
    p.add_argument('--push', action='store_true',
                   help='push the verified snapshot to --repo (public)')
    p.add_argument('--repo', help='public repo OWNER/NAME for --push')
    p.add_argument('--i-confirm-public', action='store_true',
                   help='required with --push')
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        project_dir = resolve_project(args.project)
        check_push_args(args)
        repo_root = Path(git(project_dir, 'rev-parse', '--show-toplevel')
                         .decode().strip())
        out = (args.out or default_out(project_dir)).resolve()
        snap = export(repo_root, args.project, args.ref)
        tree = out / 'tree'
        stage(snap, tree)
        hits = verify(tree, args.max_file_bytes)
        manifest = build_manifest(snap, tree, args.project, hits,
                                  args.max_file_bytes, review(tree))
        (out / 'manifest.json').write_text(
            json.dumps(manifest, indent=2) + '\n', encoding='utf-8',
            newline='\n')
        print(summary(manifest, out))
        if hits:
            return 1
        if args.push:
            push(tree, out, args.repo, manifest, args.max_file_bytes)
        else:
            print('Dry run: nothing was pushed.')
        return 0
    except PublishError as exc:
        print(f'publish_snapshot: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
