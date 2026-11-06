"""Shared real source inputs for isolated legacy test candidates."""
from pathlib import Path, PurePosixPath
import shutil

import verify_candidate

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / 'server/src/test/resources/legacy-bootstrap-fixture/reviewed-shared-sources.txt'


def reviewed_shared_paths():
    paths = tuple(PurePosixPath(line.strip()) for line in MANIFEST.read_text(encoding='utf-8').splitlines()
                  if line.strip() and not line.lstrip().startswith('#'))
    if not paths or len(set(paths)) != len(paths):
        raise AssertionError('Shared test sources must be nonempty and unique')
    if any(path.is_absolute() or '..' in path.parts or '\\' in str(path) for path in paths):
        raise AssertionError('Shared test sources must remain repository-relative regular files')
    if not set(verify_candidate.VERSION_CONTRACT_INPUTS).issubset(paths):
        raise AssertionError('Shared test sources omit a current Flyway contract authority')
    return paths


def copy_reviewed_shared_sources(candidate_root, *, legacy_directory=None):
    for relative in reviewed_shared_paths():
        source = ROOT / relative
        if source.is_symlink() or not source.is_file():
            raise AssertionError(f'Shared reviewed source is not a regular file: {relative}')
        if legacy_directory is not None and relative.is_relative_to('server/legacy_migration'):
            target = Path(legacy_directory) / relative.relative_to('server/legacy_migration')
        else:
            target = Path(candidate_root) / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
