"""Independent read-only source and raw-evidence audit; output only below this folder."""
from pathlib import Path
import collections
import hashlib
import json
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OLD = Path('D:/Projects/uten_imp_worktrees/feedback-audit-20261110')
BASE = 'fdeda88b3d73b24b8691ad132caa765196b19a3d'

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def blob(revision, path):
    return git('show', revision + ':' + path)

def digest(value):
    return hashlib.sha256(value).hexdigest()

def main():
    tag, revision = sys.argv[1:]
    revision = git('rev-parse', revision).decode().strip()
    destination = HERE / tag
    destination.mkdir(exist_ok=False)
    old_manifest = json.loads((ROOT / 'evidence/root/baseline-provenance.json').read_text(encoding='utf-8'))
    raw_deltas = []
    for name, expected in old_manifest['originalEvidence'].items():
        path = OLD / name
        actual = digest(path.read_bytes()) if path.is_file() else None
        if actual != expected['sha256']:
            raw_deltas.append({'path': name, 'expected': expected['sha256'], 'actual': actual})
    ledger = 'clients/windows_legacy/progress/work-items.json'
    before = {row['id']: row for row in json.loads(blob(BASE, ledger))['tasks']}
    after = {row['id']: row for row in json.loads(blob(revision, ledger))['tasks']}
    fields = ['status', 'owner', 'definitionOfDone', 'dependencies', 'nativeTargets']
    protected_deltas = [(key, field) for key in before for field in fields
                        if key not in after or before[key][field] != after[key][field]]
    notes_lost = [key for key in before if key not in after
                  or any(line not in after[key]['notes'] for line in before[key]['notes'].splitlines())
                  or not set(before[key]['evidence']).issubset(after[key]['evidence'])]
    history = 'clients/windows_legacy/progress/history.jsonl'
    baseline_history, candidate_history = blob(BASE, history), blob(revision, history)
    migrations = git('ls-tree', '-r', '--name-only', revision, 'server/src/main/resources/db/migration').decode().splitlines()
    original_migrations = git('ls-tree', '-r', '--name-only', BASE, 'server/src/main/resources/db/migration').decode().splitlines()
    migration_deltas = [path for path in original_migrations if path not in migrations or blob(BASE, path) != blob(revision, path)]
    import re
    versions = [re.search(r'/V([^/]+?)__', path).group(1) for path in migrations if re.search(r'/V([^/]+?)__', path)]
    duplicates = [version for version, count in collections.Counter(versions).items() if count > 1]
    prior = json.loads((OLD / 'audit/root/provenance.json').read_text(encoding='utf-8'))
    scopes = {}
    for name in ['readSession', 'noticeStorage']:
        paths = prior['comparisons'][name]['paths']
        changed = [path for path in paths if blob(BASE, path) != blob(revision, path)]
        scopes[name] = {'originalPaths': len(paths), 'changedPaths': changed,
                        'candidateExactBlobSha256': {path: digest(blob(revision, path)) for path in changed}}
    attributes = {}
    manifest_path = 'docs/99-项目治理/evidence/company-feedback-20261110/verification.json'
    for path, recorded in json.loads(blob(BASE, manifest_path))['evidenceSha256'].items():
        if path.endswith('.gitattributes'):
            full_path = 'docs/99-项目治理/evidence/company-feedback-20261110/' + path
            attributes[path] = {'originalRecorded': recorded, 'baselineExactBlobSha256': digest(blob(BASE, full_path)),
                                'candidateExactBlobSha256': digest(blob(revision, full_path)),
                                'originalCheckoutRawSha256': digest((OLD / full_path).read_bytes())}
    result = {'reviewedRevision': revision, 'actualMain': git('rev-parse', 'main').decode().strip(),
              'byteContract': {'source': 'exact Git blob bytes', 'originalEvidence': 'exact raw file bytes'},
              'originalRawFilesChecked': len(old_manifest['originalEvidence']), 'originalRawDeltas': raw_deltas,
              'ancestors': {rev: subprocess.run(['git', 'merge-base', '--is-ancestor', rev, revision], cwd=ROOT).returncode == 0
                            for rev in ['d73f86e1e', '45bf87fc9', BASE]},
              'wpf': {'baselineTasks': len(before), 'candidateTasks': len(after), 'protectedFieldDeltas': protected_deltas,
                      'lostNotesOrEvidence': notes_lost, 'baselineHistoryRows': len(baseline_history.splitlines()),
                      'candidateHistoryRows': len(candidate_history.splitlines()),
                      'baselineHistoryExactPrefix': candidate_history.startswith(baseline_history)},
              'appliedMigrationDeltas': migration_deltas, 'newMigrationPaths': sorted(set(migrations) - set(original_migrations)),
              'duplicateMigrationVersions': duplicates, 'protectedScopes': scopes, 'attributes': attributes}
    (destination / 'source-audit.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    errors = len(raw_deltas) + len(protected_deltas) + len(notes_lost) + len(migration_deltas) + len(duplicates)
    errors += int(not result['wpf']['baselineHistoryExactPrefix']) + sum(not value for value in result['ancestors'].values())
    print(json.dumps({'reviewedRevision': revision, 'originalRawFilesChecked': result['originalRawFilesChecked'],
                      'wpfTasks': len(after), 'protectedDeltaCount': len(protected_deltas),
                      'appliedMigrationDeltaCount': len(migration_deltas), 'errors': errors}, ensure_ascii=False))
    return int(errors != 0)

if __name__ == '__main__':
    sys.exit(main())
