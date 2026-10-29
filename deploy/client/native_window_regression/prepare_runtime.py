"""Copy a completed matching Flutter payload into a new task-only harness runtime."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--project', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.output.is_symlink() or args.output.is_junction():
    raise RuntimeError('Test output cannot be a link or junction')
target = args.output.resolve()
if target.exists():
    raise RuntimeError('Refusing to replace an existing task runtime')
source_path = args.project.resolve(strict=True) / 'build/windows/x64/runner/Profile'
if source_path.is_symlink() or source_path.is_junction():
    raise RuntimeError('Input bundle cannot be a link or junction')
source = source_path.resolve(strict=True)
if target == source or source in target.parents:
    raise RuntimeError('Test runtime must be outside the input bundle')
manifest_path = target.parent / (target.name + '-manifest.json')
if manifest_path.exists() or manifest_path.is_symlink() or manifest_path.is_junction():
    raise RuntimeError('Refusing to replace an existing test manifest')
for name in ('flutter_windows.dll', 'data/app.so', 'uten_imp.exe'):
    if not (source / name).is_file():
        raise RuntimeError(f'Missing completed Flutter payload file: {name}')
for entry in source.rglob('*'):
    if entry.is_symlink() or entry.is_junction():
        raise RuntimeError('Test payload cannot contain links or junctions')
shutil.copytree(source, target)
manifest = {'project': str(args.project.resolve()), 'runtime': str(target),
            'payloadCopiedWithoutRecompilingDart': True,
            'files': {str(path.relative_to(target)): hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in target.rglob('*') if path.is_file()}}
manifest_path.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print(json.dumps({k: v for k, v in manifest.items() if k != 'files'}, indent=2))
