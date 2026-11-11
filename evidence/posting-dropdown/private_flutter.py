"""Run repository-owned private Flutter tools without changing the shared SDK."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / '.github/scripts'))
import isolated_flutter_web_tools as tooling

tag, *arguments = sys.argv[1:]
out = root / 'evidence/posting-dropdown'
(out/'logs').mkdir(parents=True, exist_ok=True)
(out/'tmp').mkdir(parents=True, exist_ok=True)
log = out / 'logs' / f'private-flutter-{tag}.log'
if log.exists():
    raise SystemExit(f'Preserve existing run: {log}')
os.environ.update(TMP=str(out/'tmp'), TEMP=str(out/'tmp'), FLUTTER_SUPPRESS_ANALYTICS='true',
                  PUB_HOSTED_URL='https://pub.dev')
flutter = shutil.which('flutter')
raw = subprocess.check_output([flutter, '--version', '--machine'], cwd=root)
version = json.loads(raw[raw.index(b'{'):])
with log.open('wb') as stream:
    command, proof, environment = tooling.prepare(flutter, version, out/'private-tools', stream, stream)
    command += arguments
    receipt = {'command': command, 'source': subprocess.check_output(['git','rev-parse','HEAD'],cwd=root).decode().strip(),
               'working_tree': subprocess.check_output(['git','status','--porcelain'],cwd=root).decode('utf8')}
    code = subprocess.run(command, cwd=root, env=environment, stdout=stream, stderr=stream).returncode
tooling.confirm_sdk_unchanged(proof)
receipt.update(exit=code, sdk=proof)
(out / f'private-flutter-{tag}.json').write_text(json.dumps(receipt, indent=2), encoding='utf8')
raise SystemExit(code)
