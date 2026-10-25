"""Root-private fixtures with real OpenSSH signatures; no production DB access."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).parent / 'host/cutover-start-guard.py'
REAL_CWD = Path.cwd
spec = importlib.util.spec_from_file_location('cutover_start_guard', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


@unittest.skipUnless(os.name == 'posix' and os.geteuid() == 0 and shutil.which('ssh-keygen'),
                     'root-private Unix and real OpenSSH fixtures require Linux root')
class CutoverStartGuardTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='uten-cutover-guard-test-', dir='/run')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.releases = self.root / 'opt/releases'
        self.releases.mkdir(parents=True)
        self.current = self.root / 'opt/current'
        self.signer_root = self.root / 'etc/uten-imp-updater'
        self.signer_root.mkdir(parents=True)
        self.key = self.root / 'fixture-signing-key'
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)], check=True)
        self.signers = self.signer_root / 'allowed_signers'
        self.signers.write_text('uten-imp-release ' + self.key.with_suffix('.pub').read_text())
        self.signers.chmod(0o600)
        self.config = {'format': 'uten-imp-cutover-guard-v2', 'runtimeProfile': 'prod',
            'maintenanceId': '00000000-0000-0000-0000-000000000001',
            'systemIdentifier': '7672666251697880435', 'dataDirectory': guard.PGDATA,
            'allowedSigners': str(self.signers), 'allowedSignersSha256': self.sha(self.signers),
            'signerIdentity': 'uten-imp-release', 'namespace': 'uten-imp-release', 'pairs': {}}
        for label, version, commit, oid in [('old', 'v2.5.29', 'a' * 40, 1685044), ('new', 'v2.5.30', 'b' * 40, 1801072)]:
            release = self.releases / version
            (release / 'web').mkdir(parents=True)
            (release / 'server').mkdir()
            (release / 'web/version.json').write_text(json.dumps({'schemaVersion': 1, 'product': 'uten-imp',
                'version': version, 'commitSha': commit, 'releaseSequence': 100002005030}))
            (release / 'server/uten-imp-server.jar').write_bytes(('synthetic-app-' + label).encode())
            (release / 'server/uten-imp-migrator.jar').write_bytes(('synthetic-migrator-' + label).encode())
            self.sign_release(release)
            self.config['pairs'][label] = {'databaseOid': oid, 'version': version, 'commitSha': commit,
                'releaseDirectory': str(release), 'sumsSha256': self.sha(release / 'SHA256SUMS'),
                'signatureSha256': self.sha(release / 'SHA256SUMS.sig')}
        self.environment = {'UTEN_DB_URL': 'jdbc:postgresql://127.0.0.1:5432/uten_imp', 'UTEN_DB_USER': 'uten',
                            'UTEN_PROFILE': 'prod'}
        self.current.symlink_to(self.releases / 'v2.5.29')
        for key, value in [('CURRENT', self.current), ('RELEASES', self.releases), ('SIGNERS_ROOT', self.signer_root)]:
            context = patch.object(guard, key, value)
            context.start(); self.addCleanup(context.stop)
        context = patch.object(guard.Path, 'cwd', side_effect=lambda: self.current.resolve(strict=True))
        context.start(); self.addCleanup(context.stop)

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def sign_release(self, release):
        sums = release / 'SHA256SUMS'
        sums.write_text(''.join(self.sha(release / name) + '  ./' + name + '\n' for name in guard.REQUIRED_PAYLOADS))
        sums.with_suffix('.sig').unlink(missing_ok=True)
        subprocess.run(['/usr/bin/ssh-keygen', '-Y', 'sign', '-f', str(self.key), '-n', 'uten-imp-release', str(sums)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def database(self, label='old', **updates):
        result = {'database': 'uten_imp', 'databaseOid': self.config['pairs'][label]['databaseOid'], 'port': 5432,
            'dataDirectory': guard.PGDATA, 'systemIdentifier': self.config['systemIdentifier'],
            'databaseAllowsConnections': True, 'runtimeConnect': True, 'runtimeLogin': True,
            'runtimePasswordUnexpired': True, 'observer': 'postgres'}
        return {**result, **updates}

    def point(self, label):
        self.current.unlink()
        self.current.symlink_to(self.config['pairs'][label]['releaseDirectory'])

    def check(self, label='old', **updates):
        return guard.evaluate(self.config, self.environment, lambda: self.database(label, **updates))

    def test_old_release_old_database_and_new_release_new_database_are_allowed(self):
        self.check()
        self.point('new')
        self.check('new')

    def test_both_crossed_pairings_are_rejected(self):
        with self.assertRaises(guard.Rejected): self.check('new')
        self.point('new')
        with self.assertRaises(guard.Rejected): self.check('old')

    def test_cluster_oid_port_pgdata_and_observer_must_match(self):
        for values in [{'systemIdentifier': '9' * 19}, {'databaseOid': 99}, {'databaseOid': True},
                       {'port': 5433}, {'port': '5432'}, {'dataDirectory': '/wrong'}, {'observer': 'uten'}]:
            with self.subTest(values=values), self.assertRaises(guard.Rejected): self.check(**values)

    def test_database_and_effective_runtime_login_and_connect_are_required(self):
        for key in ['databaseAllowsConnections', 'runtimeConnect', 'runtimeLogin', 'runtimePasswordUnexpired']:
            for value in [False, 'true', 1]:
                with self.subTest(key=key, value=value), self.assertRaises(guard.Rejected): self.check(**{key: value})

    def test_signature_and_signed_inventory_cannot_be_replaced(self):
        release = Path(self.config['pairs']['old']['releaseDirectory'])
        (release / 'SHA256SUMS.sig').write_bytes(b'replaced signature')
        with self.assertRaises(guard.Rejected): self.check()

    def test_same_pinned_invalid_signature_is_not_accepted(self):
        release = Path(self.config['pairs']['old']['releaseDirectory'])
        signature = release / 'SHA256SUMS.sig'
        signature.write_bytes(b'not an OpenSSH signature')
        self.config['pairs']['old']['signatureSha256'] = self.sha(signature)
        with self.assertRaises(subprocess.CalledProcessError): self.check()

    def test_jar_and_commit_and_version_tampering_are_rejected(self):
        pair = self.config['pairs']['old']
        jar = Path(pair['releaseDirectory']) / 'server/uten-imp-server.jar'
        original = jar.read_bytes(); jar.write_bytes(b'replaced jar')
        with self.assertRaises(guard.Rejected): self.check()
        jar.write_bytes(original)
        pair['commitSha'] = 'c' * 40
        with self.assertRaises(guard.Rejected): self.check()

    def test_unknown_current_and_current_replacement_during_observation_are_rejected(self):
        def replaced():
            self.point('new')
            return self.database()
        with self.assertRaises(guard.Rejected): guard.evaluate(self.config, self.environment, replaced)
        self.current.unlink(); self.current.symlink_to(self.root)
        with self.assertRaises(guard.Rejected): self.check()

    def test_runtime_database_url_and_user_cannot_drift_or_override_target(self):
        for url in ['jdbc:postgresql://localhost:5432/uten_imp', 'jdbc:postgresql://127.0.0.1:5433/uten_imp',
                    'jdbc:postgresql://127.0.0.1:5432/candidate', 'jdbc:postgresql://evil@127.0.0.1:5432/uten_imp',
                    'jdbc:postgresql://127.0.0.1:5432/uten_imp?PGHOST=elsewhere']:
            with self.subTest(url=url), self.assertRaises(guard.Rejected): guard.runtime_environment({**self.environment, 'UTEN_DB_URL': url}, 'prod')
        with self.assertRaises(guard.Rejected): guard.runtime_environment({**self.environment, 'UTEN_DB_USER': 'postgres'}, 'prod')

    def test_explicit_local_runtime_profile_is_bound_without_cloud_composite_or_default(self):
        for profile in ['prod', 'internal-test']:
            guard.runtime_environment({**self.environment, 'UTEN_PROFILE': profile}, profile)
        for profile in ['cloud', 'prod,cloud', 'prod,internal-test', '', 'prod ', 'PROD', None]:
            with self.subTest(profile=profile), self.assertRaises(guard.Rejected):
                guard.runtime_environment({**self.environment, 'UTEN_PROFILE': profile}, 'prod')
        with self.assertRaises(guard.Rejected): guard.runtime_environment({key: value for key, value in self.environment.items() if key != 'UTEN_PROFILE'}, 'prod')
        with self.assertRaises(guard.Rejected): guard.runtime_environment(self.environment, 'internal-test')
        with self.assertRaises(guard.Rejected): guard.validate_config({**self.config, 'runtimeProfile': 'cloud'})
        with self.assertRaises(guard.Rejected): guard.validate_config({key: value for key, value in self.config.items() if key != 'runtimeProfile'})

    def test_known_spring_and_automatic_jvm_environment_overrides_are_rejected(self):
        for name in ['SPRING_DATASOURCE_URL', 'SPRING_DATASOURCE_USERNAME', 'SPRING_DATASOURCE_HIKARI_JDBC_URL',
                     'spring.datasource.url', 'SPRING_APPLICATION_JSON', 'spring.application.json',
                     'SPRING_CONFIG_LOCATION', 'SPRING_CONFIG_ADDITIONAL_LOCATION', 'SPRING_CONFIG_IMPORT',
                     'SPRING_PROFILES_ACTIVE', 'SPRING_PROFILES_DEFAULT', 'SPRING_PROFILES_INCLUDE',
                     'SPRING_MAIN_SOURCES', 'SPRING_MAIN_ADDITIONAL_PROFILES',
                     'JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS', 'JDK_JAVA_OPTIONS']:
            for value in ['', 'fixture-override']:
                with self.subTest(name=name, value=value), self.assertRaises(guard.Rejected):
                    guard.runtime_environment({**self.environment, name: value}, 'prod')
        # The reviewed launcher execs absolute /usr/bin/java with fixed argv;
        # JAVA_OPTS is not consumed there, and heap flags remain in ExecStart.
        guard.runtime_environment({**self.environment, 'JAVA_OPTS': '-Xms512m -Xmx4g'}, 'prod')

    def invoke_main_in_real_cwd(self, directory, label):
        config = self.root / 'main-config.json'
        config.write_text(json.dumps(self.config)); config.chmod(0o600)
        original = guard.evaluate
        observed = []
        def observe():
            observed.append(True)
            return self.database(label)
        previous = os.getcwd()
        try:
            os.chdir(directory)
            with patch.object(guard.Path, 'cwd', side_effect=REAL_CWD), patch.object(guard, 'CONFIG', config), \
                 patch.object(guard, 'evaluate', side_effect=lambda cfg, env: original(cfg, env, observe)), \
                 patch.dict(os.environ, self.environment, clear=True), patch.object(sys, 'argv', [str(SOURCE)]), \
                 patch('sys.stdout', new_callable=io.StringIO), patch('sys.stderr', new_callable=io.StringIO):
                return guard.main(), observed
        finally:
            os.chdir(previous)

    def test_main_actual_working_directory_allows_signed_old_and_new(self):
        for label in ['old', 'new']:
            self.point(label)
            result, observed = self.invoke_main_in_real_cwd(self.config['pairs'][label]['releaseDirectory'], label)
            self.assertEqual(0, result); self.assertEqual([True], observed)

    def test_main_actual_stale_working_directory_skips_before_database_probe(self):
        for physical, stale in [('new', 'old'), ('old', 'new')]:
            self.point(physical)
            result, observed = self.invoke_main_in_real_cwd(self.config['pairs'][stale]['releaseDirectory'], physical)
            self.assertEqual(1, result); self.assertEqual([], observed)

    def test_private_config_rejects_permissions_symlinks_duplicates_and_unknown_fields(self):
        config = self.root / 'config.json'; config.write_text(json.dumps(self.config)); config.chmod(0o600)
        guard.read_owned(config, 16384, private=True)
        config.chmod(0o644)
        with self.assertRaises(guard.Rejected): guard.read_owned(config, 16384, private=True)
        link = self.root / 'config-link'; link.symlink_to(config)
        with self.assertRaises(guard.Rejected): guard.read_owned(link, 16384, private=True)
        with self.assertRaises(guard.Rejected): guard.unique_json(b'{"pairs":{},"pairs":{}}')
        with self.assertRaises(guard.Rejected): guard.validate_config({**self.config, 'ignoredOverride': True})

    def test_untrusted_payload_parent_and_symlink_are_rejected(self):
        release = Path(self.config['pairs']['old']['releaseDirectory'])
        (release / 'server').chmod(0o777)
        with self.assertRaises(guard.Rejected): self.check()
        (release / 'server').chmod(0o755)
        jar = release / 'server/uten-imp-server.jar'; data = jar.read_bytes(); jar.unlink()
        substitute = self.root / 'substitute.jar'; substitute.write_bytes(data); jar.symlink_to(substitute)
        with self.assertRaises(guard.Rejected): self.check()

    def test_fixed_postgres_peer_query_does_not_inherit_runtime_secrets(self):
        completed = subprocess.CompletedProcess([], 0, json.dumps(self.database()).encode())
        with patch.object(guard.subprocess, 'run', return_value=completed) as run:
            with patch.dict(os.environ, {'UTEN_DB_PASSWORD': 'never-forward', 'PGHOST': 'evil'}):
                self.assertEqual(self.database(), guard.database_identity())
        args, kwargs = run.call_args
        self.assertEqual(['/usr/sbin/runuser', '-u', 'postgres', '--', '/usr/bin/psql'], args[0][:5])
        self.assertIn('BEGIN READ ONLY', args[0][-1]); self.assertIn('pg_control_system()', args[0][-1])
        self.assertNotIn('UTEN_DB_PASSWORD', kwargs['env']); self.assertNotIn('PGHOST', kwargs['env'])

    def test_main_errors_skip_with_one_generic_line_and_no_secret(self):
        with patch.object(guard, 'CONFIG', self.root / 'missing'), patch.object(sys, 'argv', [str(SOURCE)]), patch('sys.stderr', new_callable=io.StringIO) as output:
            self.assertEqual(1, guard.main())
            self.assertEqual('UTEN_CUTOVER_GUARD: startup skipped; verify maintenance pairing\n', output.getvalue())

    def test_maintenance_dropin_uses_root_condition_without_changing_execstart(self):
        unit = (SOURCE.parent.parent / 'units/99-database-cutover-guard.conf.example').read_text()
        self.assertIn('ExecCondition=+/usr/bin/setpriv --bounding-set=-all,+setuid,+setgid '
                      '--inh-caps=-all --ambient-caps=-all --no-new-privs '
                      '/usr/bin/python3 -I /usr/local/lib/uten-imp/cutover-start-guard.py', unit)
        self.assertIn('\nRestart=no\n', unit)
        self.assertNotIn('\nExecStart=', unit)
        self.assertNotIn('\nUser=', unit)


if __name__ == '__main__':
    unittest.main()
