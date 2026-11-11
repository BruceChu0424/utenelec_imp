"""Preserve a UI-downloaded diagnostic as raw bytes with explicit provenance."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--file', required=True, type=Path)
p.add_argument('--tag', required=True)
p.add_argument('--revision', required=True)
p.add_argument('--first-error-at', required=True)
p.add_argument('--classification', required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
assert re.fullmatch(r'[a-z0-9-]+', a.tag)
assert re.fullmatch(r'[a-f0-9]{40}', a.revision)
subprocess.run(['git', '-C', str(root), 'cat-file', '-e', a.revision + '^{commit}'], check=True)
target = root / f'evidence/root/raw/{a.tag}.log'
receipt = target.with_suffix('.receipt.json')
assert not target.exists() and not receipt.exists(), 'Preserve previous evidence'
raw = a.file.read_bytes()
settings = json.loads((root / 'evidence/root/private/runtime.json').read_text(encoding='utf-8-sig'))
keys = [key for key in settings if any(term in key.lower() for term in ('password', 'secret', 'hmackey', 'pgpmasterkey'))]
assert not any(isinstance(settings[key], str) and len(settings[key]) >= 8 and settings[key].encode() in raw for key in keys), 'Secret content detected'
assert not re.search(rb'Bearer\s+[A-Za-z0-9_.-]+|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.', raw), 'Credential-like token detected'
events = [json.loads(line) for line in raw.decode('utf8').splitlines()]
errors = [event for event in events if event.get('event') == 'flutter.error']
assert errors and errors[0]['atUtc'] == a.first_error_at, 'First-error boundary differs'
target.parent.mkdir(parents=True, exist_ok=True)
with target.open('xb') as stream:
    stream.write(raw)
data = {
    'kind': 'actual Settings > Runtime logs UI download',
    'sourceRevision': a.revision, 'downloadPath': str(a.file.resolve()),
    'preservedPath': str(target), 'byteContract': 'raw downloaded bytes; no normalization',
    'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
    'flutterErrors': len(errors), 'firstError': errors[0],
    'knownRuntimeSecretsAndBearerJwtScan': '0 matches', 'classification': a.classification,
}
receipt.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf8')
print(json.dumps({key: value for key, value in data.items() if key != 'firstError'}, ensure_ascii=False))
