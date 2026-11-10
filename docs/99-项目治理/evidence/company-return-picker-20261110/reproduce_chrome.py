import json
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path.cwd()
sys.path.insert(0, str(root / '.github/scripts'))
import isolated_flutter_web_tools as web_tools

flutter = shutil.which('flutter')
version = subprocess.run([flutter, '--version', '--machine'], cwd=root, capture_output=True, text=True, encoding='utf-8', check=True)
sdk = json.loads(version.stdout[version.stdout.find('{'):])
with (root / 'build/company-return-picker/chrome.log').open('w', encoding='utf-8') as log:
    prefix, proof, environment = web_tools.prepare(flutter, sdk, root / 'build/return-picker-web-tools', log, log)
    command = [*prefix, 'test', '--no-pub', '--platform', 'chrome', '--reporter', 'expanded',
               'test/features/subcontract/subcontract_goods_multi_picker_test.dart',
               'test/features/purchase/purchase_goods_multi_pick_test.dart',
               '--name', '实际选择器反复开关均显示全部分类']
    log.write(json.dumps(command, ensure_ascii=False) + '\n')
    log.flush()
    result = subprocess.run(command, cwd=root, env=environment, stdout=log, stderr=log)
    web_tools.confirm_sdk_unchanged(proof)
proof['test_exit_code'] = result.returncode
(root / 'build/company-return-picker/chrome-isolation.json').write_text(json.dumps(proof, indent=2), encoding='utf-8')
print(json.dumps({'exit_code': result.returncode, 'sdk_unchanged': proof['sdk_unchanged']}))
sys.exit(result.returncode)
