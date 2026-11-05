"""Hash the exact local server compile inputs; candidate history/credentials are not read."""
from pathlib import Path
import hashlib
import json
import sys

root=Path(__file__).resolve().parents[1]
out=root/'build/finance-closeout-20261104'
out.mkdir(parents=True,exist_ok=True)
phase=sys.argv[1]
if phase not in {'before','after'}:
    raise ValueError('Expected before or after')
inputs={root/'server/pom.xml'}
for folder in ('server/src/main/java','server/src/main/resources','server/src/test/java','server/src/test/resources'):
    inputs.update(path for path in (root/folder).rglob('*') if path.is_file())
files={str(path.relative_to(root)).replace('\\','/'):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(inputs)}
payload={'localOnly':True,'files':files,'fileCount':len(files)}
if phase=='after':
    before=json.loads((out/'backend-frozen-input-before.json').read_text(encoding='utf-8'))['files']
    payload['sourceDrift']=[name for name in sorted(set(before)|set(files)) if before.get(name)!=files.get(name)]
    (out/'backend-frozen-input-after.json').write_text(json.dumps(payload,indent=2),encoding='utf-8')
    if payload['sourceDrift']:
        raise RuntimeError('Server inputs changed during compilation: '+str(payload['sourceDrift']))
else:
    target=out/'backend-frozen-input-before.json'
    if target.exists():
        raise FileExistsError('Frozen input records are never overwritten')
    target.write_text(json.dumps(payload,indent=2),encoding='utf-8')
print(f'{phase}: {len(files)} server inputs'+('; zero drift' if phase=='after' else ' frozen'))
