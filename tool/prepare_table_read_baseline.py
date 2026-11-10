"""Use the same synthetic fixture against the pre-change public table API."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', type=Path, required=True)
args = parser.parse_args()
candidate = Path(__file__).resolve().parents[1]
baseline = args.baseline.resolve(strict=True)
if baseline == candidate:
    raise SystemExit('Baseline must be a separate worktree')
sha = subprocess.check_output(['git', '-C', str(baseline), 'rev-parse', 'HEAD'], text=True).strip()
if sha != '69e35d96bf0ddd9c8ba7992bf0a609ee9191ef98':
    raise SystemExit('Baseline must remain at the reviewed pre-change commit')
dirty = subprocess.check_output(['git', '-C', str(baseline), 'diff', 'HEAD', '--name-only'], text=True).strip()
if dirty:
    raise SystemExit('Baseline tracked sources must be clean: ' + dirty)
source = candidate/'tool/table_complete_read_harness.dart'
text = source.read_text(encoding='utf-8')
for expression in (r'\s*immutableRows:\s*true,\s*// OPTIMIZED_CONTRACT\s*\n',
                   r'\s*presentationRevision:\s*_presentationRevision,\s*// OPTIMIZED_CONTRACT\s*\n'):
    text, count = re.subn(expression, '\n', text)
    if count != 1:
        raise SystemExit('Expected exactly one candidate-only opt-in parameter')
text = text.replace('  final _presentationRevision = Object();\n', '')
target = baseline/'tool/table_complete_read_harness.dart'
target.write_text(text, encoding='utf-8')
print(json.dumps({'baselineCommit': sha, 'target': str(target),
                  'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                  'adaptation': 'Only remove the two new opt-in parameters and their unused token; all data, diagnostics and interactions are identical.'}))
