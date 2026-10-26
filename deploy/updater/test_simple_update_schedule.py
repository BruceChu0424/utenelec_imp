"""The retired scheduler must never read DB settings, launch an updater or access OSS."""
import importlib.util
import configparser
import io
import os
from contextlib import redirect_stdout
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ManualUpdateOnlyTest(unittest.TestCase):
    def test_retired_entry_has_no_network_database_or_process_capability(self):
        path = Path(__file__).parents[1] / 'simple' / 'update_schedule.py'
        source = path.read_text(encoding='utf-8-sig')
        spec = importlib.util.spec_from_file_location('retired_update_schedule', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for capability in ('subprocess', 'socket', 'urllib', 'psycopg', 'UPDATER'):
            self.assertNotIn(capability, module.__dict__)
        with redirect_stdout(io.StringIO()) as output:
            self.assertEqual(0, module.main())
        self.assertIn('"manualOnly": true', output.getvalue())
        self.assertNotIn('read_config(', source)

    def test_installation_disables_auto_timer_and_only_enables_local_bridge(self):
        path = Path(__file__).parents[1] / 'simple' / 'install-server-operations.sh'
        source = path.read_text()
        self.assertIn('systemctl disable --now uten-imp-updater.timer', source)
        self.assertIn('systemctl enable uten-imp-operations.service', source)
        self.assertIn('systemctl restart uten-imp-operations.service', source)
        self.assertNotIn('enable --now uten-imp-updater', source)
        self.assertNotIn('updater check', source)
        self.assertNotIn('updater activate', source)

    def test_both_legacy_timer_templates_cannot_activate_even_if_enabled(self):
        deploy = Path(__file__).parents[1]
        for relative in ('simple/units/uten-imp-updater.timer', 'updater/uten-imp-updater.timer'):
            with self.subTest(unit=relative):
                config = configparser.ConfigParser(interpolation=None)
                config.read(deploy / relative, encoding='utf-8-sig')
                condition = config['Unit']['ConditionPathExists']
                self.assertEqual('!/', condition)
                # systemd negates the existence check. The host root always
                # exists, so merely enabling the old unit cannot contact OSS.
                self.assertTrue(Path(condition[1:]).exists())

    def test_signed_installer_has_no_staging_start_or_enable_implementation(self):
        installer = Path(__file__).parents[1] / 'setup' / 'phase4-updater-nginx.sh'
        source = installer.read_text(encoding='utf-8-sig')
        self.assertNotIn('systemctl start uten-imp-updater.service', source)
        self.assertNotIn('systemctl enable --now uten-imp-updater.timer', source)
        self.assertNotIn('SIGNED_STAGING_ENABLED:', source)
        self.assertIn('automatic OSS checks are retired', source)

    @unittest.skipUnless(os.name == 'posix', 'native systemd checks run on Linux')
    def test_systemd_rejects_the_retired_timer_condition_and_accepts_the_units(self):
        executable = shutil.which('systemd-analyze')
        if executable is None:
            self.skipTest('systemd-analyze is unavailable')
        deploy = Path(__file__).parents[1]
        for relative in ('simple/units/uten-imp-updater.timer', 'updater/uten-imp-updater.timer'):
            with self.subTest(unit=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                timer = root / 'uten-imp-updater.timer'
                shutil.copyfile(deploy / relative, timer)
                # Validate only the retired timer and its condition; the real
                # downloader is deliberately replaced by an inert local fixture.
                (root / 'uten-imp-updater.service').write_text(
                    '[Service]\nType=oneshot\nExecStart=/bin/true\n')
                result = subprocess.run([executable, 'verify', '--man=no', str(timer)],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(0, result.returncode, result.stderr)
                config = configparser.ConfigParser(interpolation=None)
                config.read(timer, encoding='utf-8-sig')
                result = subprocess.run([executable, 'condition', 'ConditionPathExists=' +
                                         config['Unit']['ConditionPathExists']],
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(0, result.returncode)
                self.assertIn('failed', result.stderr.lower())

    @unittest.skipUnless(os.name == 'posix' and os.geteuid() == 0, 'installer preflight runs as root on Linux')
    def test_signed_installer_rejects_automatic_staging_before_any_host_changes(self):
        installer = Path(__file__).parents[1] / 'setup' / 'phase4-updater-nginx.sh'
        args = ['bash', str(installer)]
        for option in ('domain', 'office-cidr', 'vpn-cidr', 'tls-cert', 'tls-key', 'oss-public-host',
                       'release-public-key', 'expected-signing-fingerprint', 'wheelhouse',
                       'requirements-lock', 'wheelhouse-sha256s', 'wheelhouse-sbom',
                       'wheelhouse-attestation', 'wheelhouse-attestation-signature'):
            args.extend(['--' + option, 'fixture-unused'])
        args.extend(['--enable-staging', '--expected-candidate-version', 'v2.5.32',
                     '--confirm-oss-read-only', 'OSS DOWNLOADER GET-ONLY CONFIRMED'])
        result = subprocess.run(args, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(0, result.returncode)
        self.assertIn('automatic OSS checks are retired', result.stderr)
        self.assertNotIn('PHASE4_INSTALL_ONLY_COMPLETE', result.stdout)


if __name__ == '__main__':
    unittest.main()
