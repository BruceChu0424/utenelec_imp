"""Build or run the production Windows bootstrap on a fresh private test root.

No credential values enter command arguments or this process. The test reads
the synthetic password from the explicitly supplied private runtime JSON.
"""
from pathlib import Path
import argparse, hashlib, importlib.util, json, os, re, subprocess as sp
from feedback_windows_native_window import NativeWindowEvidenceDriver

parser = argparse.ArgumentParser()
parser.add_argument('stage', choices=['build', 'run'])
parser.add_argument('--run-tag', required=True)
parser.add_argument('--runtime-config', type=Path, required=True)
parser.add_argument('--account', default='feedback-mould-win-qa')
parser.add_argument('--returns-account', default='')
parser.add_argument('--runtime-ready', action='store_true')
parser.add_argument('--backend-source-head', default='')
parser.add_argument('--sdk-root', type=Path, default=Path('D:/Software/Flutter/flutter'))
a = parser.parse_args()
if a.backend_source_head and not re.fullmatch(r'[0-9a-f]{40}', a.backend_source_head):
    parser.error('backend-source-head must be the declared complete source SHA')
root = Path(__file__).resolve().parents[1]
if os.name != 'nt' or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}', a.run_tag):
    raise SystemExit('Windows and a bounded owned run tag are required')
out = root / 'evidence' / a.run_tag
runtime = out / 'private/windows-runtime'
for candidate in [root / 'evidence', out, out / 'private', runtime]:
    if candidate.is_symlink() or getattr(candidate, 'is_junction', lambda: False)():
        raise SystemExit('Private acceptance paths cannot traverse directory links')
assert runtime.resolve().is_relative_to((root / 'evidence').resolve())
runtime.mkdir(parents=True, exist_ok=True)
tmp = out / 'private/tmp'
tmp.mkdir(exist_ok=True)
config = a.runtime_config.resolve(strict=True)
if any((out / (a.stage + suffix)).exists() for suffix in ['-receipt.json', '-command.json', '.log', '-private-tool-preparation.log']):
    raise SystemExit('Evidence for this stage exists; choose a fresh run tag')


def git(*args):
    return sp.check_output(['git', *args], cwd=root, text=True, encoding='utf8').strip()


head = git('rev-parse', 'HEAD')
tracked_dirty = git('diff', 'HEAD', '--name-only')
new_source = git('ls-files', '--others', '--exclude-standard', '--', 'lib', 'windows', 'tool', 'test', 'integration_test')
if a.stage == 'run' and (tracked_dirty or new_source or not a.runtime_ready):
    raise SystemExit('Run requires committed source and explicit runtime-ready coordination')
if a.stage == 'run' and any(runtime.iterdir()):
    raise SystemExit('Use a fresh runtime root; previous logs, credentials and drafts are retained')

sdk = a.sdk_root.resolve(strict=True)
dart = sdk / 'bin/cache/dart-sdk/bin/dart.exe'
env = dict(os.environ, FLUTTER_ROOT=str(sdk), TMP=str(tmp), TEMP=str(tmp),
           PUB_HOSTED_URL='https://pub.dev', FLUTTER_SUPPRESS_ANALYTICS='true')
version = sp.run([str(dart), str(sdk / 'bin/cache/flutter_tools.snapshot'), '--version', '--machine'],
                 cwd=root, env=env, capture_output=True, check=True)
identity = json.loads(version.stdout[version.stdout.find(b'{'):])
spec = importlib.util.spec_from_file_location('feedback_private_flutter', root / '.github/scripts/isolated_flutter_web_tools.py')
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)
os.environ.update(TMP=str(tmp), TEMP=str(tmp), PUB_HOSTED_URL='https://pub.dev', FLUTTER_SUPPRESS_ANALYTICS='true')
with (out / (a.stage + '-private-tool-preparation.log')).open('wb') as log:
    prefix, tool_evidence, env = tools.prepare(str(sdk / 'bin/flutter.bat'), identity,
                                              root / 'build/feedback-private-tools', log, log)
env.update(TMP=str(tmp), TEMP=str(tmp), PUB_HOSTED_URL='https://pub.dev')
(out / (a.stage + '-private-flutter-tools.json')).write_text(json.dumps(tool_evidence, indent=2), encoding='utf8')

defines = {
    'UTEN_LOCAL_TEST': 'true', 'API_BASE_URL': 'http://127.0.0.1:28630/api',
    'CLOUD_API_BASE_URL': 'http://127.0.0.1:28630/api', 'DR_CONTROL_PLANE_URL': '',
    'UTEN_FEEDBACK_RUNTIME_ROOT': str(runtime), 'UTEN_FEEDBACK_EVIDENCE_DIR': str(out),
    'UTEN_FEEDBACK_PRIVATE_CONFIG': str(config), 'UTEN_FEEDBACK_ACCOUNT': a.account,
    'UTEN_FEEDBACK_RETURNS_ACCOUNT': a.returns_account,
    'UTEN_FEEDBACK_SOURCE_SHA': head,
    'UTEN_FEEDBACK_BACKEND_SOURCE_SHA': a.backend_source_head,
}
target = 'integration_test/company_feedback_actual_windows_test.dart'
command = [*prefix]
if a.stage == 'build':
    command += ['build', 'windows', '--debug', '--no-pub', '--target=' + target]
else:
    command += ['test', '--no-pub', '--device-id=windows', '--reporter=expanded', target]
command += ['--dart-define=' + key + '=' + value for key, value in defines.items()]
(out / (a.stage + '-command.json')).write_text(json.dumps(command, indent=2), encoding='utf8')
exe = root / 'build/windows/x64/runner/Debug/uten_imp.exe'
native_window = NativeWindowEvidenceDriver(out, exe, head) if a.stage == 'run' else None
if native_window is not None:
    native_window.start()
try:
    with (out / (a.stage + '.log')).open('wb') as log:
        result = sp.run(command, cwd=root, env=env, stdout=log, stderr=log, check=False)
finally:
    if native_window is not None:
        native_window.close()
tools.confirm_sdk_unchanged(tool_evidence)
manifest = root / 'build/windows/x64/runner/generated-runtime/uten-runtime-profile.json'
native = json.loads(manifest.read_text(encoding='utf-8-sig')) if manifest.exists() else None
if result.returncode == 0:
    assert native and native['buildProfile'] == 'local_test'
    assert Path(native['acceptanceNativeLogDirectory']).resolve().is_relative_to(runtime.resolve())
receipt = {
    'stage': a.stage, 'sourceHead': head, 'sourceWasDirty': bool(tracked_dirty or new_source),
    'sourceHeadAfter': git('rev-parse', 'HEAD'), 'canonicalSourceDiffAfter': git('diff', 'HEAD', '--name-only'), 'exitCode': result.returncode,
    'surface': 'windows-engine-real-http' if a.stage == 'run' else 'windows-debug-compile-only',
    'sdkUnchanged': True, 'nativeProfile': native,
    'executableSha256ActualBytes': hashlib.sha256(exe.read_bytes()).hexdigest() if exe.exists() else None,
    'credentialsInCommand': False,
    'declaredBackendSourceHead': a.backend_source_head or None,
    'backendIdentityVerifiedByThisHarness': False,
    'firstFlutterErrorFilePresent': (out / 'first-flutter-error.json').exists(),
    'firstFlutterErrorSha256': hashlib.sha256((out / 'first-flutter-error.json').read_bytes()).hexdigest() if (out / 'first-flutter-error.json').exists() else None,
    'nativeGeometryMethod': 'owned process executable + user32.SetWindowPos' if a.stage == 'run' else None,
}
(out / (a.stage + '-receipt.json')).write_text(json.dumps(receipt, indent=2), encoding='utf8')
(out / (a.stage + '-private-flutter-tools.json')).write_text(json.dumps(tool_evidence, indent=2), encoding='utf8')
print(json.dumps({'stage': a.stage, 'exitCode': result.returncode, 'sourceHead': head,
                  'evidence': str(out), 'clientLaunched': a.stage == 'run'}, ensure_ascii=False))
if a.stage == 'run' and (receipt['sourceHeadAfter'] != head or receipt['canonicalSourceDiffAfter']):
    raise SystemExit('Source changed during the real run; preserve this evidence and rebuild the final SHA')
raise SystemExit(result.returncode)
