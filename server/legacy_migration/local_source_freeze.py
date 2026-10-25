"""Explicit SHA freeze for a user-authorized local import without a Git commit.

The Git parent remains a parent, not a claim that local bytes were committed.
Every loader and migration byte is verified before preparation and execution.
The manifest and its external digest are both mandatory for this local mode.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory(root):
    here = root / 'server/legacy_migration'
    paths = set()
    for pattern in ('*.py', '*.sql', '*.ps1', '*.sh', '*.json', '*.txt', '*.csv', 'java/*.java'):
        paths.update(here.glob(pattern))
    paths.update((root / 'server/src/main/resources/db/migration').glob('V*__*.sql'))
    result = {}
    for path in sorted(paths):
        if path.is_symlink() or not path.is_file():
            raise ValueError('Frozen source must be a regular file')
        result[path.relative_to(root).as_posix()] = sha(path)
    return result


def parent(root):
    return subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()


def capture(root, output, authority):
    root = Path(root).resolve()
    output = Path(output)
    if not authority or output.exists() or output.is_symlink():
        raise ValueError('An explicit authority and a new freeze file are required')
    data = dict(format='uten-local-import-source-freeze-v1', root=str(root),
                gitParent=parent(root), authority=authority, committedSource=False,
                files=inventory(root))
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x', encoding='utf-8') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
    return sha(output)


def verify(root, path, expected_sha):
    root, path = Path(root).resolve(), Path(path)
    if not expected_sha or not path.is_file() or path.is_symlink() or sha(path) != expected_sha:
        raise ValueError('Local source freeze digest differs')
    data = json.loads(path.read_text(encoding='utf-8'))
    if (data.get('format') != 'uten-local-import-source-freeze-v1'
            or Path(data.get('root', '')).resolve() != root
            or data.get('gitParent') != parent(root)
            or not data.get('authority') or data.get('committedSource') is not False
            or data.get('files') != inventory(root)):
        raise ValueError('Local importer or complete migration inventory changed after freeze')
    return dict(manifest=str(path.resolve()), sha256=expected_sha,
                gitParent=data['gitParent'], authority=data['authority'], committedSource=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--authority', required=True)
    args = parser.parse_args()
    print(capture(args.root, args.output, args.authority))
