#!/usr/bin/env python3
"""Bind an offline import to exact reviewed Flyway identities and checksums."""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import zlib

VERSION_CONTRACT_PATH = pathlib.PurePosixPath('deploy/contracts/flyway_version_contract.py')
VERSION_CONTRACT_INPUTS = (VERSION_CONTRACT_PATH,
    pathlib.PurePosixPath('contracts/flyway-version/fixtures.json'),
    pathlib.PurePosixPath('tool/sync_flyway_version_contract.py'))
GIT_PATH_BATCH_SIZE = 60
CHECKSUM_HEADER = '# uten-imp-flyway-checksums-v1'


# BEGIN GENERATED FLYWAY VERSION CONTRACT
# Source: deploy/contracts/flyway_version_contract.py
# SHA-256: 39d4279fdc1e117f18456bfcf230d45c3e2c27d75dd6f4a92947123084063d5f
_FLYWAY_CONTRACT_ERROR = ValueError

# These immutable, already-applied basenames predate canonical wire versions.
# This is not permission to add another leading-zero source or accept an alias
# in a manifest/API field. Script name and CRC/source hashes remain exact.
_FLYWAY_LEGACY_INTEGER_SCRIPTS = {
    "V01__enable_pgcrypto.sql": "01",
    "V02__departments_positions.sql": "02",
    "V03__employees.sql": "03",
    "V04__auth_rbac.sql": "04",
    "V05__audit.sql": "05",
    "V06__seed_rbac.sql": "06",
    "V07__seed_org.sql": "07",
    "V08__seed_admin.sql": "08",
    "V09__audit_redact_password.sql": "09",
}

_FLYWAY_SEMANTIC_RE = __import__("re").compile(r"[0-9]+(?:[._][0-9]+)*")
_FLYWAY_SCRIPT_RE = __import__("re").compile(
    r"V(?P<version>[0-9]+(?:[._][0-9]+)*)__"
    r"(?P<description>[^\x00-\x1f\x7f-\x9f/\\]{1,200})\.sql"
)


def _flyway_semantic_key(value: object) -> tuple[int, ...]:
    if type(value) is not str or len(value) > 50 or not _FLYWAY_SEMANTIC_RE.fullmatch(value):
        raise _FLYWAY_CONTRACT_ERROR("Flyway version must contain bounded ASCII integer components")
    parts = tuple(int(part) for part in value.replace("_", ".").split("."))
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def _flyway_version_key(value: object) -> tuple[int, ...]:
    parts = _flyway_semantic_key(value)
    if parts <= (0,) or value != ".".join(str(part) for part in parts):
        raise _FLYWAY_CONTRACT_ERROR("Flyway version is not a canonical positive dotted identity")
    return parts


def _flyway_script_parts(filename: object) -> tuple[tuple[int, ...], str, str]:
    if type(filename) is not str:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script must be a bounded exact basename")
    try:
        encoded = filename.encode("utf-8")
    except UnicodeError:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script basename is not valid UTF-8") from None
    if len(encoded) > 255:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script must be a bounded exact basename")
    match = _FLYWAY_SCRIPT_RE.fullmatch(filename)
    if match is None:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script basename is not canonical")
    token = match.group("version")
    if "." in token and "_" in token:
        raise _FLYWAY_CONTRACT_ERROR("Flyway script version mixes component separators")
    key = (_flyway_semantic_key(token) if filename in _FLYWAY_LEGACY_INTEGER_SCRIPTS
           else _flyway_version_key(token.replace("_", ".")))
    raw_description = match.group("description")
    return key, raw_description, raw_description.replace("_", " ")


def _flyway_history_version_key(value: object, script: object) -> tuple[int, ...]:
    script_key, _, _ = _flyway_script_parts(script)
    if script in _FLYWAY_LEGACY_INTEGER_SCRIPTS and value == _FLYWAY_LEGACY_INTEGER_SCRIPTS[script]:
        key = _flyway_semantic_key(value)
    else:
        key = _flyway_version_key(value)
    if key != script_key:
        raise _FLYWAY_CONTRACT_ERROR("Flyway history version differs from its exact script")
    return key


def _flyway_history_order_frontier(
    version_key: tuple[int, ...], seen: set, prior_integer: tuple[int, ...]
) -> tuple[int, ...]:
    if version_key in seen:
        raise _FLYWAY_CONTRACT_ERROR("Flyway history versions are duplicated")
    if len(version_key) == 1:
        if version_key <= prior_integer:
            raise _FLYWAY_CONTRACT_ERROR(
                "Flyway integer history versions are not strictly increasing"
            )
        return version_key
    return prior_integer


def _flyway_wire_version(value: object, script: object) -> str:
    return ".".join(str(part) for part in _flyway_history_version_key(value, script))


def _flyway_head_identity(version: object) -> int | str:
    key = _flyway_version_key(version)
    return key[0] if len(key) == 1 else str(version)


def _flyway_head_key(value: object) -> tuple[int, ...]:
    if type(value) is int and value > 0 and len(str(value)) <= 50:
        return (value,)
    if type(value) is str and "." in value:
        return _flyway_version_key(value)
    raise _FLYWAY_CONTRACT_ERROR("Flyway database head must be an integer or canonical dotted string")

_FLYWAY_CONTRACT_ERROR = ValueError
# END GENERATED FLYWAY VERSION CONTRACT

def canonical_source_head(scripts):
    keys = [_flyway_script_parts(script)[0] for script in scripts]
    if not keys or len(set(keys)) != len(keys):
        raise ValueError('Flyway inventory is empty or contains duplicate canonical versions')
    return _flyway_head_identity('.'.join(map(str, max(keys))))


def _integer_head(versions):
    keys = [_flyway_version_key(version) for version in versions]
    if not keys or len(set(keys)) != len(keys):
        raise ValueError('Flyway inventory is empty or contains duplicate canonical versions')
    head = max(keys)
    if len(head) != 1:
        raise ValueError('This integer-schema business protocol requires an integer Flyway head')
    return head[0]


def _raw_version(filename):
    key, _, _ = _flyway_script_parts(filename)
    return _FLYWAY_LEGACY_INTEGER_SCRIPTS.get(filename, '.'.join(map(str, key)))


class _VersionContract:
    parse_flyway_version = staticmethod(_flyway_version_key)
    flyway_version_from_filename = staticmethod(lambda filename: '.'.join(map(str, _flyway_script_parts(filename)[0])))
    require_integer_flyway_head = staticmethod(_integer_head)
    flyway_raw_version_from_filename = staticmethod(_raw_version)
    validate_flyway_history_version = staticmethod(_flyway_history_version_key)


def version_contract(root: pathlib.Path):
    # Compatibility surface only. No runtime module loading or second parser.
    root.resolve(strict=True)
    return _VersionContract


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
    controlled.extend(root / path for path in VERSION_CONTRACT_INPUTS)
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
    head = canonical_source_head(row[1] for row in records)
    return records, head, mapping


def verify(root: pathlib.Path, manifest: pathlib.Path) -> tuple[int, int | str, str]:
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
