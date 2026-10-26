"""Real signed release fixtures for the root-only maintenance recovery path."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid
import zipfile


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


if os.name == 'posix':
    host = load('maintenance_recovery_host_fixture', Path(__file__).with_name('host_operations.py'))
    recovery = load('maintenance_recovery_fixture', Path(__file__).with_name('maintenance_recovery.py'))


@unittest.skipUnless(os.name == 'posix', 'Root ownership and Unix file locks require Linux')
class MaintenanceRecoveryTest(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0:
            self.skipTest('Run in the isolated root-owned Linux contract container')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.version = 'v2.5.32'
        self.base = self.root / 'application'
        self.release = self.base / 'releases' / self.version
        (self.release / 'server').mkdir(parents=True)
        (self.release / 'web').mkdir()
        with zipfile.ZipFile(self.release / 'server/uten-imp-server.jar', 'w') as jar:
            jar.writestr('BOOT-INF/classes/db/migration/V1__fixture.sql', 'SELECT 1;')
        (self.release / 'server/uten-imp-migrator.jar').write_bytes(b'fixture migrator')
        (self.release / 'web/version.json').write_text(json.dumps({
            'version': self.version, 'schemaVersion': 1, 'product': 'uten-imp', 'commitSha': 'a' * 40}))
        key = self.root / 'signer'
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True, capture_output=True)
        self.signers = self.root / 'allowed_signers'
        self.signers.write_text('uten-imp-release ' + key.with_suffix('.pub').read_text())
        self.signers.chmod(0o600)
        self.key = key
        self.sign_inventory()
        (self.base / 'current').symlink_to(self.release)
        (self.base / 'active-version.txt').write_text(self.version + '\n')
        self.job_id = str(uuid.uuid4())
        self.job = {'id': self.job_id, 'state': 'RECOVERY_REQUIRED', 'phase': 'HEALTH_CHECK',
                    'startedAt': '2026-10-26T22:00:00Z',
                    'failure': {'code': 'HEALTH_CHECK_FAILED'},
                    'request': {'runtimeBinding': {'fixture': 'original database binding'}}}
        self.job_path = self.state / ('job-' + self.job_id + '.json')
        host.write_json(self.job_path, self.job)
        host.write_json(self.state / 'active-job.json', {'id': self.job_id})
        self.original = self.job_path.read_bytes()
        self.env = {'UTEN_BASE': str(self.base), 'UTEN_ALLOWED_SIGNERS': str(self.signers)}
        source = Mock()
        source.view.return_value = {'revision': 'fixture revision'}
        source.load.return_value = (b'', self.env)
        self.ops = host.Operations(self.state, source, Mock())
        self.ops.backup_binding = Mock()
        self.ops.validate_database = Mock()
        self.ops.stable_health = Mock()
        self.ops.publish_maintenance = Mock()
        self.process = {'pid': 31337, 'nRestarts': 0, 'startedTicks': 123456}
        self.real_running_application = recovery.running_application
        process_patcher = patch.object(recovery, 'running_application', return_value=self.process)
        self.process_mock = process_patcher.start()
        self.addCleanup(process_patcher.stop)

    @property
    def receipt_path(self):
        return self.state / ('service-restored-' + self.job_id + '.json')

    def sign_inventory(self, extra=None):
        entries = []
        for path in sorted(self.release.rglob('*')):
            if path.is_file() and path.name not in {'SHA256SUMS', 'SHA256SUMS.sig'}:
                entries.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.relative_to(self.release).as_posix())
        if extra:
            entries.append(extra)
        manifest = self.release / 'SHA256SUMS'
        manifest.write_text('\n'.join(entries) + '\n')
        signature = self.release / 'SHA256SUMS.sig'
        signature.unlink(missing_ok=True)
        subprocess.run(['/usr/bin/ssh-keygen', '-Y', 'sign', '-f', str(self.key), '-n', 'uten-imp-release', str(manifest)], check=True, capture_output=True)

    def confirm(self):
        return recovery.confirm_service_restored(self.ops, self.job_id, self.version)

    def assert_closed(self):
        self.assertFalse(self.receipt_path.exists())
        self.ops.publish_maintenance.assert_not_called()

    def test_signed_complete_release_and_health_create_private_receipt_without_changing_failure(self):
        receipt = self.confirm()
        self.assertEqual('uten-service-restored-v1', receipt['format'])
        self.assertEqual(self.job_id, receipt['jobId'])
        self.assertEqual('UP', receipt['health'])
        self.assertEqual(hashlib.sha256(self.original).hexdigest(), receipt['jobSha256'])
        self.assertEqual(self.original, self.job_path.read_bytes())
        self.assertEqual(0o600, self.receipt_path.stat().st_mode & 0o777)
        self.assertEqual(2, self.ops.backup_binding.call_count)
        self.ops.backup_binding.assert_called_with(self.job['request']['runtimeBinding'])
        self.ops.validate_database.assert_called_once_with(self.env, self.release / 'server/uten-imp-server.jar')
        self.ops.stable_health.assert_called_once_with(self.env)
        self.ops.publish_maintenance.assert_called_once_with(self.job)
        self.ops.runner.assert_not_called()
        self.assertEqual('fixture revision', receipt['sourceRevision'])
        self.assertEqual('a' * 40, receipt['verifiedCommit'])
        self.assertEqual(self.process, receipt['processIdentity'])

    def test_non_root_and_wrong_job_cannot_acknowledge_recovery(self):
        with patch.object(recovery.os, 'geteuid', return_value=1000):
            with self.assertRaises(host.OperationError):
                self.confirm()
        with self.assertRaises(host.OperationError):
            recovery.confirm_service_restored(self.ops, str(uuid.uuid4()), self.version)
        self.assert_closed()

    def test_signature_or_payload_tampering_never_releases_gate(self):
        (self.release / 'server/uten-imp-migrator.jar').write_bytes(b'tampered')
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()
        self.ops.stable_health.assert_not_called()

    def test_untrusted_signature_never_releases_gate(self):
        (self.release / 'SHA256SUMS.sig').write_bytes(b'invalid signature')
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()

    def test_signed_unsafe_manifest_path_is_rejected(self):
        self.sign_inventory('0' * 64 + '  ../outside')
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()

    def test_database_or_health_failure_does_not_create_a_recovery_receipt(self):
        for name in ('backup_binding', 'validate_database', 'stable_health'):
            with self.subTest(check=name):
                getattr(self.ops, name).side_effect = host.OperationError('RECOVERY_REQUIRED', 'fixture validation failure')
                with self.assertRaises(host.OperationError):
                    self.confirm()
                self.assert_closed()
                getattr(self.ops, name).side_effect = None

    def test_current_or_job_changes_during_health_observation_fail_closed(self):
        def change_job(_):
            host.write_json(self.job_path, {**self.job, 'changed': True})
        self.ops.stable_health.side_effect = change_job
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()
        host.write_json(self.job_path, self.job)
        def change_current(_):
            (self.base / 'active-version.txt').write_text('v2.5.31\n')
        self.ops.stable_health.side_effect = change_current
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()

    def test_other_or_running_job_and_mutable_payload_are_rejected(self):
        host.write_json(self.job_path, {**self.job, 'state': 'RUNNING'})
        with self.assertRaises(host.OperationError):
            self.confirm()
        host.write_json(self.job_path, self.job)
        (self.release / 'server/uten-imp-migrator.jar').chmod(0o666)
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()

    def test_signed_old_release_cannot_be_relabelled_as_the_recovered_version(self):
        (self.release / 'web/version.json').write_text(json.dumps({
            'version': 'v2.5.31', 'schemaVersion': 1, 'product': 'uten-imp', 'commitSha': 'b' * 40}))
        self.sign_inventory()
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()

    def test_source_or_database_instance_change_during_health_is_not_approved(self):
        self.ops.source.view.side_effect = [{'revision': 'fixture revision'}, {'revision': 'changed'}]
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()
        self.ops.source.view.side_effect = None
        self.ops.backup_binding.side_effect = [None, host.OperationError('BACKUP_BINDING_MISMATCH', 'database restarted')]
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()

    def test_running_jvm_must_use_physical_verified_release_and_remain_the_same_process(self):
        self.process_mock.side_effect = [self.process, {**self.process, 'startedTicks': 999999}]
        with self.assertRaises(host.OperationError):
            self.confirm()
        self.assert_closed()
        proc = self.root / 'proc'
        (proc / '31337').mkdir(parents=True)
        process_stat = ['S'] + ['0'] * 18 + ['123456']
        (proc / '31337/stat').write_text('31337 (fixture java) ' + ' '.join(process_stat))
        self.ops.runner.return_value = subprocess.CompletedProcess([], 0,
            'MainPID=31337\nNRestarts=0\nActiveState=active\nSubState=running\n', '')
        with patch.object(recovery, 'PROC_ROOT', proc):
            for jar in (self.base / 'current/server/uten-imp-server.jar',
                        self.base / 'releases/v2.5.31/server/uten-imp-server.jar'):
                (proc / '31337/cmdline').write_bytes(b'java\0-jar\0' + os.fsencode(jar) + b'\0')
                with self.assertRaises(host.OperationError):
                    self.real_running_application(host, self.ops, self.env, self.release)
            (proc / '31337/cmdline').write_bytes(b'java\0-jar\0' + os.fsencode(self.release / 'server/uten-imp-server.jar') + b'\0')
            self.assertEqual(self.process, self.real_running_application(host, self.ops, self.env, self.release))


if __name__ == '__main__':
    unittest.main()
