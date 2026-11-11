"""Read-only provenance: Git source hashes use blob bytes; artifacts use raw bytes."""
from pathlib import Path
import collections
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ORIGINAL = Path('D:/Projects/uten_imp_worktrees/feedback-audit-20261110')
BASE = 'fdeda88b3d73b24b8691ad132caa765196b19a3d'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def blob(revision, path):
    return git('show', f'{revision}:{path}')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(mode):
    out = Path(__file__).parent / f'{mode}-provenance.json'
    if out.exists():
        raise SystemExit(f'Preserve previous evidence: {out} already exists')
    data = {'fingerprintContract': {'gitSource': 'SHA-256 of exact Git blob bytes (no EOL conversion)',
                                   'binaryAndLog': 'SHA-256 of exact filesystem bytes (no normalization)'},
            'baseline': BASE, 'candidate': git('rev-parse', 'HEAD').decode().strip(),
            'branch': git('branch', '--show-current').decode().strip(),
            'main': git('rev-parse', 'main').decode().strip()}
    if mode == 'baseline':
        files = {}
        # Compiled outputs and running temp profiles are not original evidence.
        for directory, subdirs, names in os.walk(ORIGINAL / 'audit'):
            subdirs[:] = [d for d in subdirs if not (d in {'build', 'mvn', 'web', 'node_modules',
                            'target', 'classes', 'test-classes'} or d.startswith(('tmp', 'probes-', 'chrome-profile')))]
            for name in names:
                path = Path(directory) / name
                files[path.relative_to(ORIGINAL).as_posix()] = {'byteSource': 'raw-file',
                            'bytes': path.stat().st_size, 'sha256': sha(path.read_bytes())}
        data['originalEvidence'] = files
    else:
        old = json.loads((Path(__file__).parent / 'baseline-provenance.json').read_text(encoding='utf8'))
        data['originalEvidenceChanged'] = [p for p, value in old['originalEvidence'].items()
            if not (ORIGINAL / p).is_file() or sha((ORIGINAL / p).read_bytes()) != value['sha256']]
    revisions = ['d73f86e1e', '45bf87fc9', BASE, 'HEAD']
    ledgers = [json.loads(blob(r, 'clients/windows_legacy/progress/work-items.json'))['tasks'] for r in revisions]
    protected = ['status', 'owner', 'definitionOfDone', 'dependencies', 'nativeTargets']
    expected = {t['id']: t for t in ledgers[2]}
    actual = {t['id']: t for t in ledgers[3]}
    data['wpf'] = {'counts': dict(zip(revisions, map(len, ledgers))),
        'protectedChanges': [(key, field) for key in expected for field in protected
                            if key not in actual or actual[key][field] != expected[key][field]],
        'lostNotesOrEvidence': [key for key in expected if key not in actual or
            any(line not in actual[key]['notes'] for line in expected[key]['notes'].splitlines()) or
            not set(expected[key]['evidence']).issubset(actual[key]['evidence'])],
        'historyBaselinePreserved': blob('HEAD', 'clients/windows_legacy/progress/history.jsonl').startswith(
            blob(BASE, 'clients/windows_legacy/progress/history.jsonl')),
        'historyCounts': {r: len(blob(r, 'clients/windows_legacy/progress/history.jsonl').splitlines()) for r in revisions}}
    evidence = 'docs/99-项目治理/evidence/company-feedback-20261110/'
    manifest = json.loads(blob(BASE, evidence + 'verification.json'))
    data['oldAttributeFingerprints'] = {}
    for path, recorded in manifest['evidenceSha256'].items():
        if not path.endswith('.gitattributes'):
            continue
        rel = evidence + path
        data['oldAttributeFingerprints'][path] = {'oldRecorded': recorded,
                'gitBlob': sha(blob(BASE, rel)), 'oldCheckoutRaw': sha((ORIGINAL / rel).read_bytes()),
                'originalUnmodified': blob('HEAD', rel) == blob(BASE, rel)}
    paths = git('ls-tree', '-r', '--name-only', 'HEAD', 'server/src/main/resources/db/migration').decode().splitlines()
    versions = [m.group(1) for p in paths if (m := re.search(r'/V(\d+(?:_\d+)*)__', p))]
    data['migrations'] = {'count': len(versions), 'duplicates': [v for v,n in collections.Counter(versions).items() if n>1]}
    data['preservedAncestors'] = {r: subprocess.run(['git', 'merge-base', '--is-ancestor', r, 'HEAD'], cwd=ROOT).returncode == 0
                                  for r in revisions[:3]}
    prior = json.loads((ORIGINAL / 'audit/root/provenance.json').read_text(encoding='utf8'))
    data['protectedProductScopes'] = {}
    changed = set(git('diff', '--name-only', BASE, 'HEAD').decode().splitlines())
    for name in ['readSession', 'noticeStorage']:
        paths = prior['comparisons'][name]['paths']
        evolved = sorted(changed.intersection(paths))
        data['protectedProductScopes'][name] = {'originalScopeCount':len(paths),
            'unchangedSinceAuditedDelivery':len(paths)-len(evolved),
            'legitimateRemediationDeltaNeedsReview': evolved,
            'baselineBlobs': {p:sha(blob(BASE,p)) for p in evolved},
            'candidateBlobs': {p:sha(blob('HEAD',p)) for p in evolved}}
    out.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf8')
    print(json.dumps({k:v for k,v in data.items() if k != 'originalEvidence'},ensure_ascii=False,indent=2))


if __name__ == '__main__':
    run(sys.argv[1])
