"""Legacy age-only pruning must not bypass the operations recovery registry."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from test_simple_release_retention import SCRIPT, bash_path


class ManualCleanupProtectionTest(unittest.TestCase):
    def test_operations_installation_disables_both_legacy_pruners(self):
        source = SCRIPT.read_text(encoding='utf-8')
        with tempfile.TemporaryDirectory(prefix='uten-prune-protection-') as directory:
            config = Path(directory) / 'operations.json'
            config.write_text('{}')
            retained = Path(directory) / 'old-backup.dump'
            retained.write_bytes(b'actual fixture bytes must stay')
            for name in ('prune_database_backups', 'prune_old'):
                function = re.search(r'(?ms)^' + name + r'\(\) \{.*?^\}', source).group(0)
                function = function.replace('/etc/uten-imp/operations.json', config.as_posix())
                command = "set -euo pipefail\nlog() { printf '%s\\n' \"$*\"; }\nrm() { exit 91; }\n"
                result = subprocess.run([bash_path(), '-c', command + function + '\n' + name],
                                        text=True, capture_output=True)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn('服务器存储页面', result.stdout)
                self.assertEqual(b'actual fixture bytes must stay', retained.read_bytes())

    def test_cli_staging_takes_the_same_lock_and_cannot_auto_activate(self):
        source = SCRIPT.read_text(encoding='utf-8')
        self.assertRegex(source, r'check\)\s+exec 9>"\$LOCK_FILE"; flock -n 9')
        self.assertRegex(source, r'(?s)stage\).*?exec 9>"\$LOCK_FILE"; flock -n 9.*?do_check "\$2"')
        check = re.search(r'(?ms)^do_check\(\) \{.*?^\}', source).group(0)
        self.assertNotIn('do_activate', check)
        status = re.search(r'(?ms)^do_status\(\) \{.*?^\}', source).group(0)
        self.assertNotIn('oss_get', status)


if __name__ == '__main__':
    unittest.main()
