#!/usr/bin/env python3
"""Bind an offline import to exact reviewed Flyway identities and checksums."""
from __future__ import annotations

import importlib.util
import pathlib
import re
import subprocess
import sys
import zlib

VERSION_CONTRACT_PATH = pathlib.PurePosixPath('deploy/updater/release_guard.py')
GIT_PATH_BATCH_SIZE = 60
CHECKSUM_HEADER = '# uten-imp-flyway-checksums-v1'


def version_contract(root: pathlib.Path):
    """Load the single existing trusted contract by fixed repository path, also under -I."""
    root = root.resolve(strict=True)
    path = root / VERSION_CONTRACT_PATH
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
        raise ValueError('Flyway version contract must be a regular reviewed repository file')
    spec = importlib.util.spec_from_file_location('_uten_legacy_flyway_version_contract', path)
    if spec is None or spec.loader is None:
        raise ValueError('Flyway version contract cannot be loaded')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for name in ('parse_flyway_version', 'flyway_version_from_filename',
                 'require_integer_flyway_head', 'flyway_raw_version_from_filename',
                 'validate_flyway_history_version'):
        if not callable(getattr(module, name, None)):
            raise ValueError('Reviewed Flyway version contract API is unavailable')
    return module


def flyway_checksum(content: bytes) -> int:
    text = content.decode('utf-8-sig')
    checksum = 0
    for line in re.split(r'\r\n|\n|\r', text):
        checksum = zlib.crc32(line.encode('utf-8'), checksum)
    return checksum if checksum < 2**31 else checksum - 2**32


def require_reviewed_files(root: pathlib.Path, controlled, *, extra_status_paths=()) -> str:
    """Keep the same committed/clean authority gate within Windows command-line limits."""
    root = root.resolve(strict=True)
    relative = []
    for path in sorted(set(controlled)):
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            raise ValueError('candidate contains a missing or non-regular file')
        relative.append(path.relative_to(root).as_posix())
    for start in range(0, len(relative), GIT_PATH_BATCH_SIZE):
        batch = relative[start:start + GIT_PATH_BATCH_SIZE]
        subprocess.run(['git', '-C', str(root), 'ls-files', '--error-unmatch', '--', *batch],
                       check=True, stdout=subprocess.DEVNULL)
        dirty = subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain=v1',
                                         '--untracked-files=all', '--', *batch], text=True)
        if dirty.strip():
            raise ValueError('reviewed importer/Flyway candidate has uncommitted bytes')
    if extra_status_paths:
        dirty = subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain=v1',
                                         '--untracked-files=all', '--', *extra_status_paths], text=True)
        if dirty.strip():
            raise ValueError('reviewed importer/Flyway candidate has uncommitted bytes')
    return subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()


def migration_inventory(root: pathlib.Path) -> list[tuple[str, str, int]]:
    contract = version_contract(root)
    records = []
    versions = set()
    migrations = root / 'server/src/main/resources/db/migration'
    for path in sorted(migrations.iterdir()):
        if path.suffix != '.sql':
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError('invalid or non-regular migration resource')
        # Keep the importer's existing description policy; the shared contract
        # decides only canonical version identity and filename separators.
        if re.fullmatch(r'V[0-9]+(?:[._][0-9]+)*__[A-Za-z0-9_]+\.sql', path.name) is None:
            raise ValueError('invalid or non-regular migration resource')
        version = contract.flyway_version_from_filename(path.name)
        identity = contract.parse_flyway_version(version)
        if identity in versions:
            raise ValueError('duplicate Flyway source version')
        versions.add(identity)
        records.append((version, path.name, flyway_checksum(path.read_bytes())))
    if not records:
        raise ValueError('reviewed Flyway source inventory is empty')
    return sorted(records, key=lambda row: contract.parse_flyway_version(row[0]))


def history_rows_sql() -> str:
    """Read original installed values; comparison never rewrites raw audit identities."""
    return "SELECT version, script, checksum FROM flyway_schema_history WHERE version IS NOT NULL ORDER BY string_to_array(version, '.')::numeric[]"


def history_state_sql() -> str:
    return """SELECT COUNT(*), COUNT(*) FILTER (WHERE success), COUNT(DISTINCT version),
COALESCE((SELECT array_to_string(string_to_array(version, '.')::numeric[], '.') FROM flyway_schema_history WHERE version IS NOT NULL
ORDER BY string_to_array(version, '.')::numeric[] DESC LIMIT 1), '0')
FROM flyway_schema_history"""


def history_projection(root: pathlib.Path, records) -> list[tuple[str, str, int]]:
    """Recover expected original DB text from the admitted script, not by canonicalizing DB rows."""
    contract = version_contract(root)
    result = []
    for canonical, filename, checksum in records:
        raw = contract.flyway_raw_version_from_filename(filename)
        if contract.validate_flyway_history_version(raw, filename) != contract.parse_flyway_version(canonical):
            raise ValueError('Flyway canonical identity and original script identity differ')
        result.append((raw, filename, checksum))
    return result


def _verified_inventory(root: pathlib.Path, manifest: pathlib.Path):
    root = root.resolve(strict=True)
    legacy = root / 'server/legacy_migration'
    migrations = root / 'server/src/main/resources/db/migration'
    controlled = [legacy / name for name in (
        'migrate.sh', 'export_legacy.ps1', 'verify_candidate.py', 'reconcile_modules.py',
        'compose_bootstrap.py', 'mapping-version.txt', 'prepare_source_authority.py',
        'prepare_hr_keys.py', 'cleanup_hr_keep_admin.sql', 'warehouse_crosswalk.csv')]
    controlled.append(root / VERSION_CONTRACT_PATH)
    controlled.extend(sorted(legacy.glob('migrate_*.sql')))
    controlled.extend(path for path in sorted(migrations.iterdir()) if path.suffix == '.sql')
    # The imported shared version module is admitted by the same source gate;
    # neither dirty bytes nor an untracked helper can authorize an import.
    require_reviewed_files(root, controlled,
                           extra_status_paths=('server/src/main/resources/db/migration',))
    records = migration_inventory(root)
    if not manifest.is_file() or manifest.is_symlink():
        raise ValueError('Flyway manifest must be a regular file')
    expected = [CHECKSUM_HEADER, *[
        f'{version}\t{name}\t{checksum}' for version, name, checksum in records]]
    if manifest.read_text(encoding='utf-8').splitlines() != expected:
        raise ValueError('Flyway manifest is not the exact reviewed source inventory')
    mapping = (legacy / 'mapping-version.txt').read_text(encoding='ascii').strip()
    if not re.fullmatch(r'bootstrap-v[1-9][0-9]*', mapping):
        raise ValueError('invalid independent import mapping version')
    head = version_contract(root).require_integer_flyway_head(row[0] for row in records)
    return records, head, mapping


def verify(root: pathlib.Path, manifest: pathlib.Path) -> tuple[int, int, str]:
    records, head, mapping = _verified_inventory(root, manifest)
    return len(records), head, mapping


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--history-state-sql']:
            print(history_state_sql())
        elif sys.argv[1:] == ['--history-rows-sql']:
            print(history_rows_sql())
        elif len(sys.argv) == 4 and sys.argv[3] == '--expected-history-rows':
            root = pathlib.Path(sys.argv[1])
            records, _, _ = _verified_inventory(root, pathlib.Path(sys.argv[2]))
            for row in history_projection(root, records):
                print('\t'.join(map(str, row)))
        elif len(sys.argv) == 3:
            print('|'.join(map(str, verify(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])))))
        else:
            raise ValueError('Expected repository and manifest, or one fixed read-only history SQL selector')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'Candidate rejected: {error}', file=sys.stderr)
        sys.exit(66)
