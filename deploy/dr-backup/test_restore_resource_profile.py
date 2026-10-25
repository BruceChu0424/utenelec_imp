"""No production material: fixed profile admission and recovered-config policy."""
import os
import json
import subprocess
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import restore_drill as drill


class RecoveryResourceProfileTest(unittest.TestCase):
    def test_default_small_is_unchanged_and_never_requires_large_host(self):
        with patch.object(drill, 'memory_available', side_effect=AssertionError('small profile must stay usable')):
            profile = drill.resource_profile()
        self.assertEqual(2 * 1024**3, profile['pgdataBytes'])
        self.assertEqual(3 * 1024**3, profile['memoryBytes'])

    def test_large_profile_requires_actual_headroom_not_a_boolean_bypass(self):
        for available in (0, 8 * 1024**3, 18 * 1024**3 - 1):
            with self.subTest(available=available), patch.object(drill, 'memory_available', return_value=available), self.assertRaises(ValueError):
                drill.resource_profile('large-memory')
        with patch.object(drill, 'memory_available', return_value=24 * 1024**3):
            profile = drill.resource_profile('large-memory')
        self.assertEqual(12 * 1024**3, profile['pgdataBytes'])
        self.assertEqual(14 * 1024**3, profile['memoryBytes'])
        self.assertEqual(24 * 1024**3, profile['observedAvailableBytes'])
        for unknown in ('large', 'unlimited', None, '../large-memory'):
            with self.subTest(unknown=unknown), self.assertRaises(ValueError):drill.resource_profile(unknown)

    def test_runtime_specific_private_mounts_and_real_id_types_are_explicit(self):
        name = 'uten-drill-'+'a'*12
        docker = drill.container_run_arguments(name, 'small')
        self.assertIn('3g', docker); self.assertTrue(any('size=2048m,uid=999,gid=999,mode=0700' in value for value in docker))
        podman = drill.container_run_arguments(name, 'large-memory', image='docker.io/library/postgres:16.15', runtime='podman')
        self.assertIn('apparmor=uten-dr-recovery', podman); self.assertIn('--read-only-tmpfs=false', podman)
        mounts = [podman[index+1] for index, value in enumerate(podman) if value == '--mount']
        self.assertEqual(4, len(mounts)); self.assertTrue(all('type=tmpfs,' in value and 'tmpfs-mode=0700,U=true' in value for value in mounts))
        self.assertFalse(any('uid=999' in value or 'type=bind' in value for value in mounts))
        self.assertEqual('1'*64, drill.runtime_image_identity('1'*64))
        self.assertEqual('1'*64, drill.runtime_image_identity('sha256:'+'1'*64))
        for value in ('postgres:16', 'evil.invalid/postgres:16', 'docker.io/library/postgres:16.15-alpine', 'docker.io/library/postgres:17'):
            with self.subTest(image=value), self.assertRaises(ValueError):drill.official_postgres_image(value)

    def test_exact_mixed_stack_needs_both_kernel_modes_and_identical_owned_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); root.chmod(0o700)
            policy = root/'policy'; policy.write_bytes(Path(drill.__file__).with_name('uten-dr-recovery.apparmor').read_bytes()); policy.chmod(0o600)
            loaded = root/'profiles'; loaded.write_text('uten-dr-recovery (enforce)\ncrun (unconfined)\n')
            with patch.object(drill, 'APPARMOR_PROFILE_PATH', policy), patch.object(drill, 'APPARMOR_PROFILES_PATH', loaded):
                value = drill.recovery_apparmor_evidence('crun//&uten-dr-recovery (mixed)')
                self.assertEqual('crun//&uten-dr-recovery (mixed)', value['actualLabel']); self.assertEqual('enforce', value['recoveryProfileMode'])
                for bad in ('other//&uten-dr-recovery (mixed)', 'crun//&other (mixed)', 'uten-dr-recovery (complain)'):
                    with self.subTest(label=bad), self.assertRaises(ValueError):drill.recovery_apparmor_evidence(bad)
                loaded.write_text('uten-dr-recovery (complain)\ncrun (unconfined)\n')
                with self.assertRaises(ValueError):drill.recovery_apparmor_evidence('crun//&uten-dr-recovery (mixed)')
                loaded.write_text('uten-dr-recovery (enforce)\ncrun (enforce)\n')
                with self.assertRaises(ValueError):drill.recovery_apparmor_evidence('crun//&uten-dr-recovery (mixed)')

    def test_cleanup_failure_never_masks_primary_and_never_returns_success(self):
        name = 'uten-drill-'+'a'*12
        with patch.object(drill.subprocess, 'run', return_value=SimpleNamespace(returncode=1)):
            self.assertFalse(drill.remove_owned_clone('/usr/bin/unused', name, primary_error=True))
            self.assertEqual(1, drill.SAFE_COUNTS['ownedContainerCleanupFailed'])
            with self.assertRaises(RuntimeError):drill.remove_owned_clone('/usr/bin/unused', name)

    def test_gnu_directory_mode_explicitly_clears_entrypoint_setgid(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory); path.chmod(0o3775)
            subprocess.run(['/bin/chmod', '00700', str(path)], check=True)
            self.assertEqual(0o700, path.stat().st_mode & 0o7777)

    def test_actual_gid_cannot_be_replaced_by_a_metadata_user_claim(self):
        name = 'uten-drill-'+'a'*12
        status = 'Uid:\t999\t999\t999\t999\nGid:\t0\t0\t0\t0\nNoNewPrivs:\t1\n'
        status += ''.join(key+':\t0000000000000000\n' for key in ('CapEff','CapPrm','CapInh','CapBnd','CapAmb'))
        def command(arguments):
            if arguments == ['inspect', name]:return json.dumps([{'Config': {'User': '999:999'}}]).encode()
            if arguments[-1] == '/proc/1/status':return status.encode()
            raise AssertionError('No backup may enter a wrong-identity clone')
        with self.assertRaises(ValueError):drill.inspected_isolation(command,name,drill.resource_profile())

    def test_host_and_every_finite_parent_cgroup_bound_admission(self):
        files = {'/proc/meminfo': 'MemAvailable: 25165824 kB\n', '/proc/self/cgroup': '0::/parent/job\n',
                 '/sys/fs/cgroup/parent/job/memory.max': 'max',
                 '/sys/fs/cgroup/parent/memory.max': str(20 * 1024**3),
                 '/sys/fs/cgroup/parent/memory.current': str(4 * 1024**3),
                 '/sys/fs/cgroup/memory.max': 'max'}
        def read(path, *_, **__):return files[str(path)]
        with patch.object(Path, 'read_text', read), patch.object(Path, 'exists', lambda path: str(path) in files):
            self.assertEqual(16 * 1024**3, drill.memory_available())
            with self.assertRaises(ValueError):drill.resource_profile('large-memory')

    def test_configuration_audit_uses_material_not_old_cleared_flag(self):
        env = {'UTEN_PROFILE': 'prod', 'UTEN_DB_USER': 'uten',
            'UTEN_DB_URL': 'jdbc:postgresql://127.0.0.1:5432/uten_imp',
            **{name: os.urandom(32).hex() for name in ('UTEN_JWT_SECRET', 'UTEN_PGP_MASTER_KEY', 'UTEN_HMAC_KEY', 'UTEN_DB_PASSWORD')},
            'UTEN_WEBSITE_INQUIRY_INGEST_TOKEN': '', 'UTEN_AI_DAILY_TOKEN_BUDGET': '3000000'}
        result = drill.configuration_audit(env)
        self.assertEqual('VERIFIED', result['state']); self.assertFalse(result['externalApiCallsPerformed'])
        for secret in env.values():
            if len(secret) > 32:self.assertNotIn(secret, repr(result))
        for value in ('change-me-' * 8, 'abcd' * 16, 'x' * 64, '${UTEN_SECRET}', 'with space' * 9):
            with self.subTest(value=value):
                result = drill.configuration_audit({**env, 'UTEN_JWT_SECRET': value})
                self.assertEqual('BLOCKED', result['state']); self.assertIn('UTEN_JWT_SECRET', result['invalidNames'])
        result = drill.configuration_audit({**env, 'UNREVIEWED_EXTERNAL_API_KEY': ''})
        self.assertEqual('BLOCKED', result['state'])


if __name__ == '__main__':unittest.main()
