"""Preserve the actual UI-exported runtime log without changing its bytes."""
from pathlib import Path
import hashlib
import json
import re

root = Path(__file__).resolve().parents[2]
source = Path('C:/Users/bruce/Downloads/UTEN-2.5.52-1794396334299.log')
target = root / 'evidence/root/raw/layout47-runtime-original.log'
receipt = target.with_suffix('.receipt.json')
if target.exists() or receipt.exists():
    raise SystemExit('Preserve previous evidence; do not overwrite')
raw = source.read_bytes()
settings = json.loads((root / 'evidence/root/private/runtime.json').read_text(encoding='utf-8-sig'))
secret_keys = [key for key in settings if any(term in key.lower() for term in ('password', 'secret', 'hmackey', 'pgpmasterkey'))]
matches = [key for key in secret_keys if isinstance(settings[key], str) and len(settings[key]) >= 8 and settings[key].encode() in raw]
assert not matches, 'Runtime secret content detected; keep original private'
assert not re.search(rb'Bearer\s+[A-Za-z0-9_.-]+|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.', raw), 'Credential-like token detected'
events = [json.loads(line) for line in raw.decode('utf8').splitlines()]
errors = [event for event in events if event.get('event') == 'flutter.error']
assert errors and errors[0]['atUtc'] == '2026-11-11T11:09:54.036Z'
assert 'SemanticsNode._replaceChildren' in errors[0]['stack']
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(raw)
data = {
    'kind': 'actual Web UI Settings > Runtime logs download; original failed source',
    'sourceRevision': '47c96198ae10ab21a4f2d6d63b206e721214458c',
    'downloadPath': str(source), 'preservedPath': str(target),
    'byteContract': 'raw downloaded bytes; no normalization',
    'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
    'flutterErrors': len(errors), 'firstError': errors[0],
    'knownRuntimeSecretsAndBearerJwtScan': '0 matches',
    'classification': 'local red, semantics ownership assertion on actual menu open; independent of the original layout mutation',
}
receipt.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf8')
print(json.dumps({key: value for key, value in data.items() if key != 'firstError'}, ensure_ascii=False))
