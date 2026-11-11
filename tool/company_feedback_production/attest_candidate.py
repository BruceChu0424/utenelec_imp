"""Read-only Git-blob comparison. Equality is per file, never inferred from the branch name."""
from pathlib import Path
import argparse
import json
import subprocess

BASELINE = '7b912287e53315228b469790ff066a9fab643e3c'
PATHS = ['server/src/main', 'server/src/test', 'server/pom.xml', 'contracts',
         'tool/company_feedback_production']


def collect(root: Path, revision: str) -> dict[str, str]:
    raw = subprocess.check_output(['git', 'ls-tree', '-r', '-z', revision, '--', *PATHS], cwd=root)
    result = {}
    for entry in raw.split(b'\0'):
        if not entry:
            continue
        metadata, path = entry.split(b'\t', 1)
        mode, kind, blob = metadata.split()
        if kind == b'blob':
            result[path.decode('utf-8')] = blob.decode('ascii')
    return result


def attest(root: Path, candidate: str, baseline: str = BASELINE) -> dict:
    before, after = collect(root, baseline), collect(root, candidate)
    entries = [{'path': path, 'baselineBlob': before.get(path), 'candidateBlob': after.get(path),
                'identical': before.get(path) == after.get(path)}
               for path in sorted(before.keys() | after.keys())]
    groups = {}
    for name, prefix in [('main', 'server/src/main/'), ('tests', 'server/src/test/'),
                         ('migrations', 'server/src/main/resources/db/migration/'),
                         ('tools', 'tool/company_feedback_production/'), ('contracts', 'contracts/'),
                         ('build', 'server/pom.xml')]:
        selected = [entry for entry in entries if entry['path'].startswith(prefix)]
        groups[name] = {'files': len(selected), 'identical': sum(entry['identical'] for entry in selected),
                        'changedPaths': [entry['path'] for entry in selected if not entry['identical']]}
    return {'baseline': baseline, 'candidate': candidate, 'fingerprintKind': 'canonical Git blobs, not runtime bytes',
            'groups': groups, 'changedPaths': [entry['path'] for entry in entries if not entry['identical']],
            'entries': entries, 'priorRunRelabelled': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--candidate', default='HEAD')
    parser.add_argument('--baseline', default=BASELINE)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    candidate = subprocess.check_output(['git', 'rev-parse', args.candidate], cwd=root, text=True).strip()
    result = attest(root, candidate, args.baseline)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        raise SystemExit('Choose a new output; prior attestation is retained')
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'candidate': candidate, 'groups': result['groups']}, ensure_ascii=False))
