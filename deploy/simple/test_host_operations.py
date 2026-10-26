"""Local fixtures only: root authority, secret writes, CAS and durable job lifecycle."""
import base64
import ast
import datetime as dt
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import socket
import unittest
import uuid
import zipfile
from zoneinfo import ZoneInfo
from unittest.mock import patch
from unittest.mock import Mock

if os.name == 'posix':
    spec = importlib.util.spec_from_file_location('host_operations', Path(__file__).with_name('host_operations.py'))
    host = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = host
    spec.loader.exec_module(host)


@unittest.skipUnless(os.name == 'posix', 'SO_PEERCRED and private Unix files require Linux')
class HostOperationsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.env = self.root / 'source.env'
        host.atomic(self.env, b'')
        self.source = host.ReleaseSource(self.env)
        self.public = 'ssh-ed25519 ' + base64.b64encode(b'\0\0\0\x0bssh-ed25519\0\0\0\x20' + bytes(range(32))).decode()
        self.actor = str(uuid.uuid4())
        self.calls = []
        self.media = self.root / 'media'
        self.media.mkdir()
        self.paired = self.root / 'paired'
        self.paired.mkdir()
        self.pg_socket = self.root / 'pg-socket'
        self.pg_socket.mkdir()
        self.operations_config = self.root / 'operations.json'
        host.write_json(self.operations_config, {'storage': {'uploads_root': str(self.media), 'paired_backup_root': str(self.paired)}})
        self.backup_config = self.root / 'paired-config.json'
        self.paired_values = {'database': 'uten_imp', 'port': 5432, 'socket_directory': str(self.pg_socket),
                              'media_root': str(self.media), 'backup_root': str(self.paired)}
        host.write_json(self.backup_config, self.paired_values)
        self.migrator_config = self.root / 'migrator.env'
        host.atomic(self.migrator_config, ('UTEN_MIGRATOR_DB_PASSWORD=' + 'fixture' * 5 + '\n').encode())
        for name, value in (('OPERATIONS_CONFIG', self.operations_config), ('BACKUP_CONFIG', str(self.backup_config)),
                            ('MIGRATOR_CONFIG', self.migrator_config), ('PG_SOCKET_DIRECTORY', str(self.pg_socket))):
            patcher = patch.object(host, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def payload(self):
        return {'expectedRevision': self.source.view()['revision'],
                'endpoint': 'oss-cn-example.aliyuncs.com', 'bucket': 'fixture-bucket',
                'objectPrefix': 'company/releases', 'accessKeyId': 'FIXTUREID',
                'accessKeySecret': 'fixturevalue123', 'signingPublicKey': self.public}

    def runner(self, args, timeout=15):
        self.calls.append(args)
        if args[0] == '/usr/sbin/runuser':
            return subprocess.CompletedProcess(args, 0, '{"postmasterStartedAt":"2026-10-15T00:00:00Z"}', '')
        return subprocess.CompletedProcess(args, 0, 'inactive\n', '')

    def operations(self):
        return host.Operations(self.state, self.source, self.runner)

    def request(self, operation, payload=None, request_id=None, actor=None):
        return {'operation': operation, 'actorId': actor or self.actor,
                'requestId': request_id or str(uuid.uuid4()), 'payload': payload or {}}

    def start_payload(self):
        status = self.operations().status()
        return {'mode': 'CHECK_AND_UPDATE', 'expectedSourceRevision': status['sourceRevision'],
                'expectedCurrentVersion': status['currentVersion'], 'runtimeBinding': {
                    'database': 'uten_imp', 'host': '127.0.0.1', 'port': 5432, 'storageProvider': 'internal',
                    'mediaRoot': str(self.media), 'legacyLocalEnabled': False, 'legacyLocalRoot': None,
                    'postmasterStartedAt': '2026-10-15T00:00:00Z'}}

    def test_save_reaches_root_source_and_never_returns_credentials(self):
        view = self.source.save(self.payload())
        self.assertTrue(view['accessKeyConfigured'])
        self.assertEqual('****REID', view['accessKeyIdHint'])
        self.assertEqual(self.public, view['signingPublicKey'])
        self.assertNotIn('fixturevalue123', json.dumps(view))
        self.assertNotIn('FIXTUREID', json.dumps(view))
        env = host.parse_env(host.read_private(self.env))
        self.assertEqual('fixturevalue123', env['UTEN_OSS_KEY_SECRET'])
        self.assertEqual('0', env['UTEN_AUTO_ACTIVATE_CODE_ONLY'])
        self.assertEqual(0o600, self.env.stat().st_mode & 0o777)
        self.assertEqual(view, host.ReleaseSource(self.env).view())

    def test_stale_save_leaves_both_source_and_signer_unchanged(self):
        old = self.payload()
        view = self.source.save(old)
        env = self.env.read_bytes()
        with self.assertRaisesRegex(host.OperationError, '已变化'):
            self.source.save(old)
        self.assertEqual(env, self.env.read_bytes())
        self.assertEqual(view, self.source.view())

    def test_after_commit_io_failure_records_unknown_with_no_credentials(self):
        ops = self.operations()
        req = self.request('CONFIG_SAVE', self.payload())
        original = self.source.save
        def after_commit(payload):
            original(payload)
            raise OSError('fixture raw error must not be persisted')
        with patch.object(self.source, 'save', side_effect=after_commit):
            with self.assertRaises(host.OperationError) as failed:
                ops.dispatch(req)
        self.assertEqual('OUTCOME_UNCERTAIN', failed.exception.code)
        receipt = host.read_json(self.state / ('source-change-' + req['requestId'] + '.json'))
        self.assertEqual('UNKNOWN', receipt['state'])
        self.assertEqual(self.source.view()['revision'], receipt['afterRevision'])
        self.assertNotIn('fixturevalue123', json.dumps(receipt))
        self.assertNotIn('raw error', json.dumps(receipt))

    def test_blank_keeps_secret_key_rotation_requires_pair_and_clear_is_explicit(self):
        self.source.save(self.payload())
        value = self.payload()
        value.update(accessKeyId='', accessKeySecret='')
        self.source.save(value)
        self.assertTrue(self.source.view()['accessKeyConfigured'])
        value = self.payload()
        value.update(accessKeyId='DIFFERENTID', accessKeySecret='')
        with self.assertRaises(host.OperationError):
            self.source.save(value)
        value = self.payload()
        value.update(accessKeyId='', accessKeySecret='', clearCredentials=True)
        self.assertFalse(self.source.save(value)['accessKeyConfigured'])

    def test_endpoint_and_paths_cannot_inject_shell_network_or_files(self):
        for changed in ({'endpoint': '127.0.0.1'}, {'endpoint': 'oss-cn-x.aliyuncs.com.attacker.test'},
                        {'endpoint': 'https://oss-cn-x.aliyuncs.com'}, {'objectPrefix': '../private'},
                        {'objectPrefix': 'a//b'}, {'bucket': 'x;whoami'}, {'command': 'echo private'},
                        {'accessKeyId': 'x\nHeader: value'}, {'clearCredentials': 'false'}):
            with self.subTest(changed=changed):
                value = self.payload()
                value.update(changed)
                with self.assertRaises(host.OperationError):
                    self.source.save(value)
                self.assertEqual(b'', self.env.read_bytes())

    def test_symlink_config_and_public_permissions_are_rejected(self):
        self.env.chmod(0o644)
        with self.assertRaises(host.OperationError):
            self.source.load()
        self.env.chmod(0o600)
        other = self.root / 'other'
        other.symlink_to(self.env)
        with self.assertRaises(OSError):
            host.ReleaseSource(other).load()

    def test_page_status_and_job_polling_never_execute_oss_updater(self):
        ops = self.operations()
        self.assertIsNone(ops.dispatch(self.request('UPDATE_JOB')))
        status = ops.dispatch(self.request('STATUS'))
        self.assertTrue(status['manualOnly'])
        self.assertFalse(status['sourceConfigured'])
        self.assertTrue(all(c[0] == '/usr/bin/systemctl' for c in self.calls))

    def test_repeated_ready_status_cache_and_job_reads_never_check_oss(self):
        self.source.save(self.payload())
        ops = self.operations()
        self.checked_version(ops)
        self.calls.clear()
        for _ in range(5):
            status = ops.dispatch(self.request('STATUS'))
            self.assertTrue(status['sourceConfigured'])
            self.assertTrue(status['updateAvailable'])
            self.assertEqual('v2.5.18', status['latestVersion'])
            self.assertIsNone(ops.dispatch(self.request('UPDATE_JOB')))
            self.assertTrue(ops.dispatch(self.request('CONFIG_READ'))['accessKeyConfigured'])
            self.assertEqual(0, ops.worker())
        self.assertTrue(self.calls)
        self.assertTrue(all(c[0] == '/usr/bin/systemctl' and 'start' not in c for c in self.calls))

    def test_start_persists_before_ack_and_is_idempotent_across_object_restart(self):
        self.source.save(self.payload())
        request_id = str(uuid.uuid4())
        req = self.request('UPDATE_START', self.start_payload(), request_id)
        first = self.operations().dispatch(req)
        self.assertEqual('QUEUED', first['state'])
        self.assertEqual(first, self.operations().dispatch(req))
        self.assertEqual(1, sum('start' in c for c in self.calls))
        self.assertEqual(first, host.read_json(self.state / f'job-{request_id}.json'))
        req['actorId'] = str(uuid.uuid4())
        with self.assertRaises(host.OperationError):
            self.operations().dispatch(req)

    def test_source_and_second_update_are_blocked_during_durable_job(self):
        self.source.save(self.payload())
        ops = self.operations()
        payload = self.start_payload()
        ops.dispatch(self.request('UPDATE_START', payload))
        with self.assertRaisesRegex(host.OperationError, '正在执行'):
            ops.dispatch(self.request('CONFIG_SAVE', self.payload()))
        with self.assertRaises(host.OperationError):
            ops.dispatch(self.request('UPDATE_START', payload))

    def test_lost_ack_retry_returns_durable_job_while_worker_holds_the_lock(self):
        self.source.save(self.payload())
        req = self.request('UPDATE_START', self.start_payload())
        job = self.operations().dispatch(req)
        with host.lock(self.state / 'operations.lock'):
            self.assertEqual(job, self.operations().dispatch(req))
            for changed in ({**req, 'actorId': str(uuid.uuid4())},
                            {**req, 'payload': {**req['payload'], 'expectedSourceRevision': 'changed'}}):
                with self.subTest(changed=changed), self.assertRaises(host.OperationError) as caught:
                    self.operations().dispatch(changed)
                self.assertEqual('REQUEST_CONFLICT', caught.exception.code)
            with self.assertRaises(host.OperationError) as caught:
                self.operations().dispatch({**req, 'requestId': str(uuid.uuid4())})
            self.assertEqual('BUSY', caught.exception.code)
        self.assertEqual(1, sum('start' in c for c in self.calls))

    def test_source_cas_and_running_version_checked_before_enqueuing(self):
        self.source.save(self.payload())
        payload = self.start_payload()
        payload['expectedSourceRevision'] = 'old'
        with self.assertRaises(host.OperationError):
            self.operations().dispatch(self.request('UPDATE_START', payload))
        self.assertFalse((self.state / 'active-job.json').exists())

    def test_start_failure_has_durable_failed_job_and_never_claims_success(self):
        self.source.save(self.payload())
        ops = self.operations()
        original = ops.runner
        def fail(args, timeout=15):
            if 'start' in args:
                raise subprocess.CalledProcessError(1, args)
            return original(args, timeout)
        ops.runner = fail
        result = ops.dispatch(self.request('UPDATE_START', self.start_payload()))
        self.assertEqual('FAILED', result['state'])
        self.assertEqual(result, ops.job())

    def test_worker_interruption_never_replays_activation(self):
        self.source.save(self.payload())
        ops = self.operations()
        job = ops.dispatch(self.request('UPDATE_START', self.start_payload()))
        job.update(state='RUNNING', phase='MIGRATING')
        ops.store_job(job)
        self.calls.clear()
        self.assertEqual(1, self.operations().worker())
        self.assertEqual('RECOVERY_REQUIRED', ops.job()['state'])
        self.assertEqual('WORKER_INTERRUPTED', ops.job()['failure']['code'])
        self.assertTrue(ops.job()['failure']['recoveryRequired'])
        self.assertFalse(ops.job()['failure']['retrySafe'])
        self.assertEqual([], self.calls)

    def test_new_check_update_and_schedule_cannot_replace_recovery_receipt(self):
        self.source.save(self.payload())
        ops = self.operations()
        original_request = self.request('UPDATE_START', self.start_payload())
        job = ops.dispatch(original_request)
        job.update(state='RECOVERY_REQUIRED', phase='MIGRATING', finishedAt=host.now())
        # Also covers a durable legacy recovery record with no failure field.
        ops.store_job(job)
        before = {p.name: p.read_bytes() for p in self.state.glob('*.json')}
        scheduled = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=2)).replace(hour=2, minute=0, second=0, microsecond=0)
        check = {k: v for k, v in original_request['payload'].items() if k != 'runtimeBinding'}
        check['mode'] = 'CHECK_ONLY'
        update = dict(original_request['payload'])
        schedule = {**update, 'mode': 'SCHEDULE_UPDATE', 'targetVersion': 'v2.5.18', 'scheduledAt': scheduled.isoformat()}
        self.calls.clear()
        for payload in (check, update, schedule):
            request = self.request('UPDATE_START', payload)
            with self.subTest(mode=payload['mode']), self.assertRaises(host.OperationError) as caught:
                ops.dispatch(request)
            self.assertEqual('RECOVERY_REQUIRED', caught.exception.code)
            self.assertEqual(before, {p.name: p.read_bytes() for p in self.state.glob('*.json')})
            self.assertEqual([], self.calls)
        self.assertEqual(job, ops.dispatch(original_request))
        self.assertEqual(job, ops.dispatch(self.request('UPDATE_JOB', {'jobId': job['id']})))
        self.assertEqual([], self.calls)
        self.assertEqual(job, ops.status()['latestJob'])
        self.assertFalse(any(args[0] == host.UPDATER or 'start' in args for args in self.calls))

    def test_new_request_also_blocks_after_local_dead_worker_observation_discovers_recovery(self):
        self.source.save(self.payload())
        ops = self.operations()
        job = ops.dispatch(self.request('UPDATE_START', self.start_payload()))
        new_request = self.request('UPDATE_START', self.start_payload())
        job.update(state='RUNNING', phase='MIGRATING', startedAt='2026-01-01T00:00:00+00:00')
        ops.store_job(job)
        self.calls.clear()
        with self.assertRaises(host.OperationError) as caught:
            ops.dispatch(new_request)
        self.assertEqual('RECOVERY_REQUIRED', caught.exception.code)
        self.assertEqual('RECOVERY_REQUIRED', ops.job()['state'])
        self.assertEqual(job['id'], ops.job()['id'])
        self.assertFalse((self.state / ('job-' + new_request['requestId'] + '.json')).exists())
        self.assertEqual(1, len(self.calls))
        self.assertEqual('/usr/bin/systemctl', self.calls[0][0])
        self.assertNotIn('start', self.calls[0])

    def test_dead_worker_is_reported_without_restarting_it(self):
        self.source.save(self.payload())
        ops = self.operations()
        job = ops.dispatch(self.request('UPDATE_START', self.start_payload()))
        job.update(state='RUNNING', phase='MIGRATING', startedAt='2026-01-01T00:00:00+00:00')
        ops.store_job(job)
        self.calls.clear()
        observed = ops.dispatch(self.request('UPDATE_JOB'))
        self.assertEqual('RECOVERY_REQUIRED', observed['state'])
        self.assertEqual('VERIFY_RECOVERY', observed['failure']['nextAction'])
        self.assertFalse(any('start' in c for c in self.calls))

    def test_matching_latest_has_no_backup_download_or_activation(self):
        self.source.save(self.payload())
        ops = self.operations()
        with patch.object(host, 'current_version', return_value='v2.5.16'):
            job = ops.dispatch(self.request('UPDATE_START', self.start_payload()))
            original = ops.runner
            ops.runner = lambda args, timeout=15: subprocess.CompletedProcess(args, 0, 'v2.5.16\n', '') if args[0] == host.UPDATER else original(args, timeout)
            self.calls.clear()
            self.assertEqual(0, ops.worker())
        self.assertEqual('SUCCEEDED', ops.job()['state'])
        self.assertEqual('UNCHANGED', ops.job()['health'])
        self.assertTrue(all(c[0] == '/usr/sbin/runuser' for c in self.calls))

    def test_backup_failure_does_not_enter_activation(self):
        self.source.save(self.payload())
        ops = self.operations()
        ops.dispatch(self.request('UPDATE_START', self.start_payload()))
        def fake(args, timeout=15):
            self.calls.append(args)
            if args[0] == '/usr/sbin/runuser':
                return subprocess.CompletedProcess(args, 0, '{"postmasterStartedAt":"2026-10-15T00:00:00Z"}', '')
            if args[:2] == [host.UPDATER, 'latest']:
                return subprocess.CompletedProcess(args, 0, 'v2.5.18\n', '')
            if args[:2] == [host.UPDATER, 'stage']:
                return subprocess.CompletedProcess(args, 0, '', '')
            raise subprocess.CalledProcessError(1, args, stderr='fixture credentials must stay private')
        ops.runner = fake
        self.assertEqual(1, ops.worker())
        result = ops.job()
        self.assertEqual('FAILED', result['state'])
        self.assertEqual('BACKING_UP', result['phase'])
        self.assertNotIn('fixture credentials', json.dumps(result))
        self.assertFalse(any(args[:2] == [host.UPDATER, 'activate'] for args in self.calls))

    def test_reenabled_timer_is_a_real_start_gate(self):
        self.source.save(self.payload())
        ops = self.operations()
        payload = self.start_payload()
        ops.runner = lambda args, timeout=15: subprocess.CompletedProcess(args, 0, 'enabled\n' if '--property=UnitFileState' in args else 'inactive\n', '')
        self.assertFalse(ops.status()['manualOnly'])
        with self.assertRaises(host.OperationError):
            ops.dispatch(self.request('UPDATE_START', payload))
        self.assertIsNone(ops.job())

    def checked_version(self, ops):
        host.write_json(self.state / 'latest-release.json', {
            'version': 'v2.5.18', 'checkedAt': host.now(), 'sourceRevision': self.source.view()['revision']})

    def scheduled_request(self, ops):
        self.checked_version(ops)
        payload = self.start_payload()
        payload.update(mode='SCHEDULE_UPDATE', targetVersion='v2.5.18',
                       scheduledAt=host.schedule_preview({'localDate': (dt.datetime.now(host.server_zone()) + dt.timedelta(days=2)).date().isoformat(), 'hour': 2})['scheduledAt'])
        return self.request('UPDATE_START', payload)

    def test_manual_check_only_caches_update_hint_without_downloading(self):
        self.source.save(self.payload())
        ops = self.operations()
        payload = self.start_payload()
        payload['mode'] = 'CHECK_ONLY'
        ops.dispatch(self.request('UPDATE_START', payload))
        def fake(args, timeout=15):
            self.calls.append(args)
            if args[:2] == [host.UPDATER, 'latest']:
                return subprocess.CompletedProcess(args, 0, 'v2.5.18\n', '')
            return subprocess.CompletedProcess(args, 0, 'inactive\n', '')
        ops.runner = fake
        self.calls.clear()
        self.assertEqual(0, ops.worker())
        status = ops.status()
        self.assertTrue(status['updateAvailable'])
        self.assertEqual('v2.5.18', status['latestVersion'])
        self.assertEqual([[host.UPDATER, 'latest']], [c for c in self.calls if c[0] == host.UPDATER])

    def test_scheduled_job_is_durable_and_has_no_worker_or_network_before_due(self):
        self.source.save(self.payload())
        ops = self.operations()
        req = self.scheduled_request(ops)
        self.calls.clear()
        job = ops.dispatch(req)
        self.assertEqual('SCHEDULED', job['state'])
        self.assertEqual(job, self.operations().dispatch(self.request('UPDATE_JOB')))
        self.assertFalse(any('start' in c or c[0] == host.UPDATER for c in self.calls))
        with self.assertRaises(host.OperationError):
            ops.dispatch(self.request('UPDATE_DISPATCH', {'jobId': job['id'], 'runtimeBinding': job['request']['runtimeBinding']}))
        self.assertEqual('SCHEDULED', ops.job()['state'])

    def test_due_dispatch_is_actor_bound_and_exactly_once(self):
        self.source.save(self.payload())
        ops = self.operations()
        job = ops.dispatch(self.scheduled_request(ops))
        job['scheduledAt'] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=60)).isoformat()
        ops.store_job(job)
        with self.assertRaises(host.OperationError):
            ops.dispatch(self.request('UPDATE_DISPATCH', {'jobId': job['id'], 'runtimeBinding': job['request']['runtimeBinding']}, actor=str(uuid.uuid4())))
        self.calls.clear()
        result = ops.dispatch(self.request('UPDATE_DISPATCH', {'jobId': job['id'], 'runtimeBinding': job['request']['runtimeBinding']}))
        self.assertEqual('QUEUED', result['state'])
        self.assertEqual(1, sum('start' in c for c in self.calls))
        with self.assertRaises(host.OperationError):
            ops.dispatch(self.request('UPDATE_DISPATCH', {'jobId': job['id'], 'runtimeBinding': job['request']['runtimeBinding']}))

    def test_missed_window_is_cancelled_instead_of_surprising_daytime_restart(self):
        self.source.save(self.payload())
        ops = self.operations()
        job = ops.dispatch(self.scheduled_request(ops))
        job['scheduledAt'] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=2)).isoformat()
        ops.store_job(job)
        self.calls.clear()
        result = ops.dispatch(self.request('UPDATE_DISPATCH', {'jobId': job['id'], 'runtimeBinding': job['request']['runtimeBinding']}))
        self.assertEqual('CANCELLED', result['state'])
        self.assertFalse(any('start' in c for c in self.calls))

    def test_revoked_authorization_can_cancel_schedule_without_executing(self):
        self.source.save(self.payload())
        ops = self.operations()
        job = ops.dispatch(self.scheduled_request(ops))
        self.calls.clear()
        result = ops.dispatch(self.request('UPDATE_CANCEL', {'jobId': job['id'], 'reason': 'AUTHORIZATION_REVOKED'}))
        self.assertEqual('CANCELLED', result['state'])
        self.assertIn('授权已失效', result['message'])
        self.assertEqual([], self.calls)

    def test_server_timezone_preview_has_real_utc_and_rejects_dst_gap_and_overlap(self):
        future = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=2)).date().isoformat()
        with patch.object(host, 'server_zone', return_value=ZoneInfo('Asia/Shanghai')):
            value = host.schedule_preview({'localDate': future, 'hour': 2})
        self.assertTrue(value['displayLocalTime'].endswith('T02:00:00+08:00'))
        self.assertTrue(value['scheduledAt'].endswith('T18:00:00+00:00'))
        for date in ('2026-03-29', '2026-10-25'):
            with self.subTest(date=date), patch.object(host, 'server_zone', return_value=ZoneInfo('Europe/Berlin')):
                with self.assertRaisesRegex(host.OperationError, '夏令时'):
                    host.schedule_preview({'localDate': date, 'hour': 2})

    def test_source_change_invalidates_cached_update_badge(self):
        self.source.save(self.payload())
        ops = self.operations()
        self.checked_version(ops)
        self.assertTrue(ops.status()['updateAvailable'])
        payload = self.payload()
        payload['objectPrefix'] = 'another-company'
        self.source.save(payload)
        self.assertFalse(ops.status()['updateAvailable'])

    def test_schedule_cannot_bypass_server_slot_validation_via_direct_api(self):
        self.source.save(self.payload())
        ops = self.operations()
        req = self.scheduled_request(ops)
        local = dt.datetime.now(host.server_zone()) + dt.timedelta(days=2)
        for changed in (local.replace(hour=14, minute=0, second=0, microsecond=0),
                        local.replace(hour=2, minute=30, second=0, microsecond=0)):
            req['payload']['scheduledAt'] = changed.isoformat()
            with self.assertRaises(host.OperationError):
                ops.dispatch(req)
            self.assertIsNone(ops.job())

    def test_stable_health_binds_pid_and_restart_baseline_without_requiring_lifetime_zero(self):
        ops = self.operations()
        client = Mock()
        client.open.side_effect = lambda *args, **kwargs: io.BytesIO(b'{"status":"UP"}')
        good = 'MainPID=1234\nNRestarts=9\nActiveState=active\nSubState=running\n'
        with patch.object(host.urllib.request, 'build_opener', return_value=client), patch.object(host.time, 'sleep'):
            ops.runner = lambda args, timeout=15: subprocess.CompletedProcess(args, 0, good, '')
            ops.stable_health({})
            self.assertEqual(14, client.open.call_count)
            for changed in (good.replace('1234', '1235'), good.replace('NRestarts=9', 'NRestarts=10'), good.replace('active', 'failed')):
                samples = iter((good, changed))
                ops.runner = lambda args, timeout=15: subprocess.CompletedProcess(args, 0, next(samples), '')
                with self.assertRaisesRegex(host.OperationError, '退出或重启'):
                    ops.stable_health({})

    def test_local_stability_preserves_existing_certificate_validated_https_cli_health(self):
        ops = self.operations()
        client = Mock()
        client.open.side_effect = lambda *args, **kwargs: io.BytesIO(b'{"status":"UP"}')
        good = 'MainPID=1234\nNRestarts=0\nActiveState=active\nSubState=running\n'
        ops.runner = lambda args, timeout=15: subprocess.CompletedProcess(args, 0, good, '')
        env = {'UTEN_HEALTH_URL': 'https://company.example/actuator/health/readiness'}
        with patch.object(host.urllib.request, 'build_opener', return_value=client), patch.object(host.time, 'sleep'):
            ops.stable_health(env)
        urls = [call.args[0].full_url for call in client.open.call_args_list]
        self.assertEqual({'http://127.0.0.1:8080/actuator/health/readiness',
                          'http://127.0.0.1:8080/actuator/health/liveness'}, set(urls))
        self.assertEqual('https://company.example/actuator/health/readiness', env['UTEN_HEALTH_URL'])
        for url in ('https://company.example/actuator/health/readiness',
                    'http://127.0.0.1:0/actuator/health/readiness',
                    'http://127.0.0.1:65536/actuator/health/readiness'):
            host.atomic(self.env, ('UTEN_OPERATIONS_HEALTH_URL=' + url + '\n').encode())
            with self.subTest(url=url), self.assertRaisesRegex(host.OperationError, '稳定性检查'):
                ops.backup_binding(self.start_payload()['runtimeBinding'])

    def test_real_unix_protocol_authenticates_peer_and_returns_only_safe_errors(self):
        path = str(self.root / 'control.sock')
        with host.Server(path, host.Handler) as server:
            server.app_uid = os.geteuid()
            server.operations = self.operations()
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                def call(payload):
                    with socket.socket(socket.AF_UNIX) as client:
                        client.connect(path)
                        client.sendall(json.dumps(payload).encode() + b'\n')
                        with client.makefile('rb') as source:
                            try:
                                raw = source.readline()
                            except ConnectionResetError:
                                return None
                            return json.loads(raw) if raw else None
                self.assertTrue(call(self.request('STATUS'))['ok'])
                failed = call(self.request('SHELL', {'secret': 'fixture-value-must-not-echo'}))
                self.assertFalse(failed['ok'])
                self.assertNotIn('fixture-value', json.dumps(failed))
                with patch.object(server.operations, 'dispatch', side_effect=host.OperationError(
                        'SOURCE_NOT_CONFIGURED', 'PRIVATE_SOURCE_SECRET https://user:pass@host/ <XML>')):
                    failed = call(self.request('UPDATE_START'))
                self.assertEqual('SOURCE_NOT_CONFIGURED', failed['failure']['code'])
                self.assertTrue(failed['failure']['originalServicePreserved'])
                self.assertNotIn('PRIVATE_SOURCE_SECRET', json.dumps(failed))
                self.assertNotIn('user:pass', json.dumps(failed))
                with patch.object(server.operations, 'dispatch', side_effect=RuntimeError('PRIVATE_UNKNOWN_SECRET')):
                    failed = call(self.request('UPDATE_START'))
                self.assertEqual('OUTCOME_UNCERTAIN', failed['failure']['code'])
                self.assertFalse(failed['failure']['retrySafe'])
                self.assertFalse(failed['failure']['originalServicePreserved'])
                self.assertNotIn('PRIVATE_UNKNOWN_SECRET', json.dumps(failed))
                with patch.object(server.operations, 'dispatch', side_effect=host.OperationError('PRIVATE_CODE_SECRET', 'private')):
                    failed = call(self.request('STATUS'))
                self.assertEqual('HOST_OPERATION_FAILED', failed['code'])
                self.assertEqual('UNKNOWN', failed['failure']['code'])
                self.assertNotIn('PRIVATE_CODE_SECRET', json.dumps(failed))
                server.app_uid += 1
                self.assertIsNone(call(self.request('STATUS')))
            finally:
                server.shutdown()
                thread.join(timeout=5)

    def test_complete_worker_orders_verified_backup_migration_catalog_and_health(self):
        self.source.save(self.payload())
        base = self.root / 'installation'
        for version, migrations in (('v2.5.16', (1,)), ('v2.5.18', (1, 2))):
            directory = base / 'releases' / version / 'server'
            directory.mkdir(parents=True)
            with zipfile.ZipFile(directory / 'uten-imp-server.jar', 'w') as jar:
                for migration in migrations:
                    jar.writestr(f'BOOT-INF/classes/db/migration/V{migration}__fixture.sql', f'SELECT {migration}')
        (base / 'current').symlink_to('releases/v2.5.16')
        (base / 'active-version.txt').write_text('v2.5.16')
        env = host.parse_env(host.read_private(self.env))
        env['UTEN_BASE'] = str(base)
        host.atomic(self.env, ''.join(f'{k}={v}\n' for k, v in env.items()).encode())
        paired = self.root / 'paired'
        published = paired / '20261015T010000Z-0123456789ab'
        published.mkdir(parents=True)
        (published / 'database.dump').write_bytes(b'fixture backup')
        config = self.root / 'paired-config.json'
        host.write_json(config, {**self.paired_values, 'backup_root': str(paired)})
        events = []
        ops = self.operations()
        ops.dispatch(self.request('UPDATE_START', self.start_payload()))
        def fake(args, timeout=15):
            if args[0] == '/usr/sbin/runuser' and 'pg_postmaster_start_time' in args[-1]:
                value = '{"postmasterStartedAt":"2026-10-15T00:00:00Z"}'
                events.append('instance-identity')
            elif args[:2] == [host.UPDATER, 'latest']:
                value = 'v2.5.18'
                events.append('latest')
            elif args[:2] == [host.UPDATER, 'stage']:
                value = ''
                events.append('stage')
            elif '--config' in args:
                value = json.dumps({'published': str(published)})
                events.append('backup')
            elif '--verify' in args:
                value = '{}'
                events.append('verify')
            elif '--list' in args:
                value = 'fixture catalog'
                events.append('backup-toc')
            elif args[0] == '/usr/sbin/runuser':
                value = json.dumps({'failed': 0, 'versions': ['1', '2']})
                events.append('database-catalog')
            else:
                raise AssertionError(args)
            return subprocess.CompletedProcess(args, 0, value, '')
        ops.runner = fake
        def activate(job, target):
            events.append('activate')
            self.assertTrue(job['migrationRequired'])
            self.assertEqual(str(published), job['backupPath'])
            (base / 'current').unlink()
            (base / 'current').symlink_to('releases/' + target)
            (base / 'active-version.txt').write_text(target)
        with patch.object(host, 'BACKUP_CONFIG', str(config)), patch.object(ops, 'activate', side_effect=activate), patch.object(ops, 'stable_health', side_effect=lambda env: events.append('stable-health')):
            self.assertEqual(0, ops.worker())
        self.assertEqual(['instance-identity', 'latest', 'stage', 'backup', 'verify', 'backup-toc', 'activate', 'database-catalog', 'stable-health'], events)
        self.assertEqual('SUCCEEDED', ops.job()['state'])
        self.assertEqual('UP', ops.job()['health'])

    def test_migration_history_must_match_the_whole_release_not_only_latest_version(self):
        path = self.root / 'release.jar'
        with zipfile.ZipFile(path, 'w') as jar:
            jar.writestr('BOOT-INF/classes/db/migration/V1__first.sql', 'SELECT 1')
            jar.writestr('BOOT-INF/classes/db/migration/V2__second.sql', 'SELECT 2')
        for data in ({'failed': 0, 'versions': ['2']}, {'failed': 1, 'versions': ['1', '2']},
                     {'failed': 0, 'versions': ['0', '2']}):
            ops = host.Operations(self.state, self.source, lambda args, timeout=15: subprocess.CompletedProcess(args, 0, json.dumps(data), ''))
            with self.subTest(data=data), self.assertRaises(host.OperationError):
                ops.validate_database({}, path)

    def test_preflight_refuses_a_successful_backup_of_the_wrong_database_or_media_root(self):
        binding = self.start_payload()['runtimeBinding']
        ops = self.operations()
        ops.backup_binding(binding)
        for key, value in (('database', 'another_company'), ('port', 5433), ('media_root', str(self.paired)),
                           ('backup_root', str(self.media))):
            host.write_json(self.backup_config, {**self.paired_values, key: value})
            with self.subTest(key=key), self.assertRaises(host.OperationError):
                ops.backup_binding(binding)
        host.write_json(self.backup_config, self.paired_values)
        for url in ('jdbc:postgresql://127.0.0.1:5432/another_company',
                    'jdbc:postgresql://192.0.2.1:5432/uten_imp',
                    'jdbc:postgresql://127.0.0.1:5432/uten_imp?currentSchema=wrong',
                    'jdbc:postgresql://127.0.0.1:5432/uten_imp?options=search_path%3Dwrong'):
            host.atomic(self.migrator_config, ('UTEN_MIGRATOR_DB_PASSWORD=' + 'fixture' * 5 + '\nUTEN_DB_URL=' + url + '\n').encode())
            with self.subTest(url=url), self.assertRaises(host.OperationError):
                ops.backup_binding(binding)

    def test_standalone_migrator_target_and_single_secret_contract_cannot_silently_drift(self):
        root = Path(host.__file__).parents[2]
        java = (root / 'server/src/main/java/com/uten/imp/migration/UtenImpMigrator.java').read_text()
        import re
        constants = dict(re.findall(r'static final String (DATABASE_URL|DATABASE_USER|PASSWORD_ENV) = "([^"]+)";', java))
        self.assertEqual(f'jdbc:postgresql://{host.MIGRATOR_HOST}:{host.MIGRATOR_PORT}/{host.MIGRATOR_DATABASE}', constants['DATABASE_URL'])
        self.assertEqual(host.MIGRATOR_USER, constants['DATABASE_USER'])
        self.assertEqual(host.MIGRATOR_PASSWORD_ENV, constants['PASSWORD_ENV'])
        self.assertIn('.defaultSchema("public")', java)
        self.assertIn('.schemas("public")', java)
        validator = (root / 'deploy/setup/validate-migrator-env.sh').read_text()
        self.assertIn('if (key != "' + host.MIGRATOR_PASSWORD_ENV + '") exit 13', validator)

    def test_legacy_originals_inventory_must_match_the_root_paired_backup_path(self):
        legacy = self.root / 'legacy-originals'
        legacy.mkdir()
        host.write_json(self.backup_config, {**self.paired_values, 'local_media_root': str(legacy)})
        binding = self.start_payload()['runtimeBinding']
        binding.update(legacyLocalEnabled=True, legacyLocalRoot=str(legacy))
        ops = self.operations()
        with self.assertRaisesRegex(host.OperationError, '历史上传目录'):
            ops.backup_binding(binding)
        config = host.read_json(self.operations_config)
        config['storage']['legacy_uploads_root'] = str(legacy)
        host.write_json(self.operations_config, config)
        ops.backup_binding(binding)
        config['storage']['legacy_uploads_root'] = str(self.paired)
        host.write_json(self.operations_config, config)
        with self.assertRaisesRegex(host.OperationError, '历史上传目录'):
            ops.backup_binding(binding)

    def test_runtime_changed_after_booking_cancels_without_starting_worker(self):
        self.source.save(self.payload())
        ops = self.operations()
        job = ops.dispatch(self.scheduled_request(ops))
        job['scheduledAt'] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=60)).isoformat()
        ops.store_job(job)
        changed = {**job['request']['runtimeBinding'], 'database': 'different_company'}
        self.calls.clear()
        result = ops.dispatch(self.request('UPDATE_DISPATCH', {'jobId': job['id'], 'runtimeBinding': changed}))
        self.assertEqual('CANCELLED', result['state'])
        self.assertFalse(any('start' in c for c in self.calls))

    def test_nondefault_update_target_is_explicitly_rejected_and_catalog_port_is_honest(self):
        binding = self.start_payload()['runtimeBinding']
        binding['port'] = 5433
        host.atomic(self.env, b'UTEN_PG_PORT=5433\n')
        host.write_json(self.backup_config, {**self.paired_values, 'port': 5433})
        ops = self.operations()
        with self.assertRaisesRegex(host.OperationError, '标准目标'):
            ops.backup_binding(binding)
        jar = self.root / 'port.jar'
        with zipfile.ZipFile(jar, 'w') as payload:
            payload.writestr('BOOT-INF/classes/db/migration/V1__fixture.sql', 'SELECT 1')
        def query(args, timeout=15):
            self.assertEqual('5433', args[args.index('-p') + 1])
            return subprocess.CompletedProcess(args, 0, '{"failed":0,"versions":["1"]}', '')
        ops.runner = query
        ops.validate_database({'UTEN_PG_PORT': '5433'}, jar)

    def test_same_name_and_port_cannot_substitute_another_postgres_instance(self):
        binding = self.start_payload()['runtimeBinding']
        ops = self.operations()
        ops.runner = lambda args, timeout=15: subprocess.CompletedProcess(args, 0,
            '{"postmasterStartedAt":"2026-10-14T00:00:00Z"}', '')
        with self.assertRaisesRegex(host.OperationError, '同一运行数据库实例'):
            ops.backup_binding(binding)
        # Even a correct backup peer does not authorize migrating the other IP
        # family when two loopback listeners use the same database name/port.
        ops.runner = self.runner
        binding['host'] = '::1'
        with self.assertRaisesRegex(host.OperationError, '标准目标'):
            ops.backup_binding(binding)

    def test_legitimate_postgres_restart_refreshes_appointment_identity_at_dispatch(self):
        self.source.save(self.payload())
        ops = self.operations()
        original = self.scheduled_request(ops)
        job = ops.dispatch(original)
        job['scheduledAt'] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=60)).isoformat()
        ops.store_job(job)
        changed = {**job['request']['runtimeBinding'], 'postmasterStartedAt': '2026-10-15T01:00:00Z'}
        result = ops.dispatch(self.request('UPDATE_DISPATCH', {'jobId': job['id'], 'runtimeBinding': changed}))
        self.assertEqual('QUEUED', result['state'])
        self.assertEqual(changed, result['request']['runtimeBinding'])
        with host.lock(self.state / 'operations.lock'):
            self.assertEqual(result, self.operations().dispatch(original))

    def test_command_timeout_terminates_only_its_owned_session(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            host.run([sys.executable, '-c', 'import time; time.sleep(60)'], timeout=0.05)

    def test_activation_timeout_is_bounded_and_retains_unsafe_phase(self):
        executable = self.root / 'fixture-updater'
        executable.write_text('#!/bin/sh\nprintf "UTEN_PHASE:MIGRATING\\n"\nexec sleep 60\n')
        executable.chmod(0o700)
        job = {'id': str(uuid.uuid4()), 'currentVersion': 'v2.5.16', 'phase': 'ACTIVATING'}
        with patch.object(host, 'UPDATER', str(executable)), patch.object(host, 'ACTIVATION_TIMEOUT_SECONDS', 0.05):
            with self.assertRaises(host.OperationError) as failed:
                self.operations().activate(job, 'v2.5.18')
        self.assertEqual('ACTIVATION_TIMEOUT', failed.exception.code)
        self.assertEqual('MIGRATING', job['phase'])

    def test_systemd_outer_budget_covers_all_bounded_prepare_and_cutover_stages(self):
        tree = ast.parse(Path(host.__file__).read_text())
        worker = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'worker')
        prepare = sum(keyword.value.value for node in ast.walk(worker) if isinstance(node, ast.Call)
                      and isinstance(node.func, ast.Attribute) and node.func.attr == 'runner'
                      for keyword in node.keywords if keyword.arg == 'timeout' and isinstance(keyword.value, ast.Constant))
        text = Path(host.__file__).with_name('units').joinpath('uten-imp-update-job.service').read_text()
        import re
        minutes = int(re.search(r'^TimeoutStartSec=([0-9]+)min$', text, re.MULTILINE).group(1))
        self.assertGreater(minutes * 60, prepare + host.ACTIVATION_TIMEOUT_SECONDS + 5 * 60)

    def test_migration_digest_binds_contents_and_rejects_empty_jar(self):
        paths = []
        for i, data in enumerate((b'CREATE TABLE a (id int)', b'CREATE TABLE a (id bigint)')):
            path = self.root / f'{i}.jar'
            with zipfile.ZipFile(path, 'w') as jar:
                jar.writestr('BOOT-INF/classes/db/migration/V1__fixture.sql', data)
            paths.append(path)
        self.assertNotEqual(host.migration_digest(paths[0]), host.migration_digest(paths[1]))
        with zipfile.ZipFile(self.root / 'empty.jar', 'w'):
            pass
        with self.assertRaises(host.OperationError):
            host.migration_digest(self.root / 'empty.jar')
        with self.assertRaises(host.OperationError):
            host.assert_forward_migrations(paths[0], paths[1])
        with self.assertRaises(host.OperationError):
            host.assert_forward_migrations(paths[0], self.root / 'empty.jar')

    def test_no_arbitrary_operation_or_non_uuid_identity(self):
        with self.assertRaises(host.OperationError):
            self.operations().dispatch(self.request('SHELL', {'command': 'whoami'}))
        with self.assertRaises(host.OperationError):
            self.operations().dispatch(self.request('STATUS', actor='root'))

    def test_real_identity_failure_is_durable_specific_and_does_not_reach_network(self):
        self.source.save(self.payload())
        ops = self.operations()
        ops.dispatch(self.request('UPDATE_START', self.start_payload()))
        self.calls.clear()
        private = 'runuser: cannot set user id: Operation not permitted\nAuthorization: OSS PRIVATE_TOKEN <AccessKeyId>PRIVATE_KEY</AccessKeyId>'
        def denied(args, timeout=15):
            self.calls.append(args)
            raise subprocess.CalledProcessError(1, args, stderr=private)
        ops.runner = denied
        self.assertEqual(1, ops.worker())
        result = ops.job()
        self.assertEqual(('FAILED', 'CHECKING'), (result['state'], result['phase']))
        failure = result['failure']
        self.assertEqual('HOST_IDENTITY_PERMISSION', failure['code'])
        self.assertEqual('CONTACT_ADMIN', failure['nextAction'])
        self.assertTrue(failure['originalServicePreserved'])
        self.assertFalse(failure['recoveryRequired'])
        self.assertFalse(failure['retrySafe'])
        self.assertEqual(1, failure['exitCode'])
        self.assertEqual(1, len(self.calls))
        self.assertEqual('/usr/sbin/runuser', self.calls[0][0])
        self.assertNotIn('PRIVATE_', json.dumps(result))
        self.assertNotIn('Authorization:', json.dumps(result))
        self.assertNotIn('cannot set user id', json.dumps(result))

    def test_failure_matrix_uses_fixed_codes_and_never_returns_private_diagnostics(self):
        samples = [
            ('CHECKING', 'LATEST', 1, 'curl: (6) Could not resolve host', 'SOURCE_DNS_FAILED'),
            ('CHECKING', 'LATEST', 1, 'curl: (7) Failed to connect', 'SOURCE_NETWORK_FAILED'),
            ('CHECKING', 'LATEST', 1, 'curl: (60) SSL certificate problem', 'SOURCE_TLS_FAILED'),
            ('CHECKING', 'LATEST', 1, 'curl: (22) The requested URL returned error: 403', 'SOURCE_FORBIDDEN'),
            ('CHECKING', 'LATEST', 1, '<Code>SignatureDoesNotMatch</Code>', 'SOURCE_FORBIDDEN'),
            ('CHECKING', 'LATEST', 1, 'curl: (22) The requested URL returned error: 404', 'SOURCE_NOT_FOUND'),
            ('CHECKING', 'LATEST', 1, 'curl: (28) Timeout was reached', 'OPERATION_TIMEOUT'),
            ('CHECKING', 'LATEST', 1, '[uten-imp-updater][ERROR] 版本号非法', 'SOURCE_METADATA_INVALID'),
            ('DOWNLOADING', 'STAGE', 1, '[uten-imp-updater][ERROR] 签名验证失败：v2.5.20', 'RELEASE_SIGNATURE_INVALID'),
            ('DOWNLOADING', 'STAGE', 1, '[uten-imp-updater][ERROR] SHA256SUMS 校验失败：private/path', 'RELEASE_CHECKSUM_INVALID'),
            ('DOWNLOADING', 'STAGE', 1, 'SHA256SUMS 含越界/可疑路径：private/file', 'RELEASE_CONTENT_INVALID'),
            ('DOWNLOADING', 'STAGE', 1, 'No space left on device', 'HOST_DISK_SPACE'),
            ('DOWNLOADING', 'STAGE', 126, 'Permission denied', 'HOST_COMPONENT_PERMISSION'),
            ('DOWNLOADING', 'STAGE', 127, 'command not found', 'HOST_COMPONENT_MISSING'),
            ('BACKING_UP', 'BACKUP', 1, 'Backup destination has insufficient reserved free space', 'BACKUP_SPACE'),
            ('BACKING_UP', 'BACKUP', 1, 'Private reference inventory is not completely covered', 'BACKUP_REFERENCE_INVALID'),
            ('BACKING_UP', 'BACKUP_VERIFY', 1, 'Stored backup digest changed', 'BACKUP_INTEGRITY_FAILED'),
            ('BACKING_UP', 'BACKUP_TOC', 1, 'pg_restore: error: invalid archive', 'BACKUP_INTEGRITY_FAILED'),
            ('BACKING_UP', 'BACKUP', 1, 'pg_dump failed; inspect private incomplete-set log', 'BACKUP_FAILED'),
        ]
        for phase, step, status, diagnostic, expected in samples:
            with self.subTest(code=expected, diagnostic=diagnostic):
                error = subprocess.CalledProcessError(status, ['PRIVATE_ARG'],
                    output='PRIVATE_BODY business data', stderr=diagnostic + '\nPRIVATE_SECRET https://user:pass@host/path <Signature>PRIVATE</Signature>')
                failure = host.job_failure({'state': 'FAILED', 'phase': phase}, error, step=step)
                self.assertEqual(expected, failure['code'])
                self.assertEqual(phase, failure['phase'])
                self.assertTrue(failure['title'] and failure['reason'] and failure['suggestion'])
                public = json.dumps(failure, ensure_ascii=False)
                for secret in ('PRIVATE', 'user:pass', 'private/path', 'private/file', '<Signature>', 'business data'):
                    self.assertNotIn(secret, public)
        self.assertEqual('BACKUP_SPACE', host.classify_failure(OSError(errno.ENOSPC, 'PRIVATE'), 'BACKING_UP'))
        self.assertEqual('BACKUP_REFERENCE_INVALID', host.classify_failure(ValueError('PRIVATE'), 'BACKING_UP', 'BACKUP_REFERENCE'))
        self.assertEqual('RELEASE_CONTENT_INVALID', host.classify_failure(host.OperationError('INVALID_RELEASE', 'PRIVATE'),
                                                                         'DOWNLOADING', 'MIGRATION_CATALOG'))

    def test_recovery_flags_override_even_a_normally_retryable_network_failure(self):
        for phase in ('ACTIVATING', 'MIGRATING', 'HEALTH_CHECK'):
            failure = host.job_failure({'state': 'RECOVERY_REQUIRED', 'phase': phase},
                                       host.OperationError('SOURCE_NETWORK_FAILED', 'PRIVATE'))
            self.assertFalse(failure['retrySafe'])
            self.assertTrue(failure['recoveryRequired'])
            self.assertFalse(failure['originalServicePreserved'])
            self.assertEqual('VERIFY_RECOVERY', failure['nextAction'])
            self.assertIn('不要再次更新、激活或回滚数据库', failure['suggestion'])
            self.assertNotIn('恢复后重新检查', failure['suggestion'])
        for code in ('CURRENT_VERSION_CHANGED', 'CUTOVER_BACKUP_FAILED_RECOVERED'):
            failure = host.failure_view(code, 'MIGRATING', recovery_required=True)
            self.assertEqual('更新需要恢复核对', failure['title'])
            self.assertNotIn('未停服', failure['reason'])
            self.assertNotIn('原服务已恢复', failure['reason'])
            self.assertFalse(failure['originalServicePreserved'])
            unconfirmed = host.failure_view(code, 'ACTIVATING', original_service_preserved=False)
            self.assertEqual('更新状态需要核对', unconfirmed['title'])
            self.assertNotIn('原服务已恢复', unconfirmed['reason'])
            self.assertFalse(unconfirmed['recoveryRequired'])
        blocked = host.failure_view('RECOVERY_REQUIRED')
        self.assertTrue(blocked['recoveryRequired'])
        self.assertFalse(blocked['retrySafe'])
        self.assertFalse(blocked['originalServicePreserved'])

    def test_unknown_failure_is_honest_and_bounds_the_optional_exit_status(self):
        unknown = host.job_failure({'state': 'FAILED', 'phase': 'CHECKING'}, RuntimeError('PRIVATE_UNKNOWN'))
        self.assertEqual('UNKNOWN', unknown['code'])
        self.assertIn('尚未确认', unknown['title'])
        self.assertFalse(unknown['retrySafe'])
        self.assertIsNone(unknown['exitCode'])
        self.assertEqual('UNKNOWN', host.classify_failure(host.OperationError([], 'PRIVATE'), 'CHECKING'))
        self.assertEqual('UNKNOWN', host.failure_view([])['code'])
        malformed = subprocess.CalledProcessError([], ['PRIVATE'], stderr='curl: (' + '9' * 5000 + ') PRIVATE')
        self.assertEqual('UNKNOWN', host.classify_failure(malformed, 'CHECKING', 'LATEST'))
        for value in (True, '1', 256, -256, 0):
            self.assertIsNone(host.failure_view('HOST_COMPONENT_MISSING', exit_code=value)['exitCode'])
        self.assertEqual(-9, host.failure_view('HOST_COMPONENT_MISSING', exit_code=-9)['exitCode'])

    def test_unknown_worker_failure_has_safe_request_correlated_private_log(self):
        self.source.save(self.payload())
        ops = self.operations()
        job = ops.dispatch(self.request('UPDATE_START', self.start_payload()))
        ops.runner = Mock(side_effect=RuntimeError('PRIVATE_UNRECOGNIZED_DETAIL https://user:password@host/'))
        with patch('sys.stderr', new_callable=io.StringIO) as diagnostic:
            self.assertEqual(1, ops.worker())
        failure = ops.job()['failure']
        self.assertEqual('UNKNOWN', failure['code'])
        self.assertIn('jobId=' + job['id'], diagnostic.getvalue())
        self.assertIn('code=UNKNOWN phase=CHECKING step=BINDING', diagnostic.getvalue())
        self.assertNotIn('PRIVATE_UNRECOGNIZED_DETAIL', diagnostic.getvalue())
        self.assertNotIn('user:password', diagnostic.getvalue())
        self.assertNotIn('PRIVATE_UNRECOGNIZED_DETAIL', json.dumps(ops.job()))

    def _prepared_failure_worker(self):
        self.source.save(self.payload())
        base = self.root / ('installation-' + uuid.uuid4().hex)
        for version, migrations in (('v2.5.16', (1,)), ('v2.5.18', (1, 2))):
            directory = base / 'releases' / version / 'server'
            directory.mkdir(parents=True)
            with zipfile.ZipFile(directory / 'uten-imp-server.jar', 'w') as jar:
                for migration in migrations:
                    jar.writestr(f'BOOT-INF/classes/db/migration/V{migration}__fixture.sql', f'SELECT {migration}')
        (base / 'current').symlink_to('releases/v2.5.16')
        (base / 'active-version.txt').write_text('v2.5.16')
        env = host.parse_env(host.read_private(self.env))
        env['UTEN_BASE'] = str(base)
        host.atomic(self.env, ''.join(f'{k}={v}\n' for k, v in env.items()).encode())
        published = self.paired / ('20261015T010000Z-' + uuid.uuid4().hex[:12])
        published.mkdir()
        (published / 'database.dump').write_bytes(b'fixture')
        ops = self.operations()
        ops.dispatch(self.request('UPDATE_START', self.start_payload()))
        def runner(args, timeout=15):
            self.calls.append(args)
            if args[0] == '/usr/sbin/runuser':
                value = '{"postmasterStartedAt":"2026-10-15T00:00:00Z"}'
            elif args[:2] == [host.UPDATER, 'latest']:
                value = 'v2.5.18'
            elif '--config' in args:
                value = json.dumps({'published': str(published)})
            else:
                value = '{}'
            return subprocess.CompletedProcess(args, 0, value, '')
        ops.runner = runner
        return ops, base

    def test_migration_failure_is_durable_recovery_and_is_never_replayed(self):
        ops, _ = self._prepared_failure_worker()
        def failed(job, target):
            ops.phase(job, 'MIGRATING')
            raise host.OperationError('MIGRATION_FAILED', 'PRIVATE_SQL', exit_code=3)
        with patch.object(ops, 'activate', side_effect=failed) as activate:
            self.assertEqual(1, ops.worker())
            receipt = ops.job()
            self.assertEqual(('RECOVERY_REQUIRED', 'MIGRATING'), (receipt['state'], receipt['phase']))
            self.assertEqual('MIGRATION_FAILED', receipt['failure']['code'])
            self.assertFalse(receipt['failure']['retrySafe'])
            self.assertFalse(receipt['failure']['originalServicePreserved'])
            self.assertEqual(3, receipt['failure']['exitCode'])
            self.assertEqual(0, ops.worker())
            activate.assert_called_once()
        self.assertNotIn('PRIVATE_SQL', json.dumps(receipt))

    def test_known_cutover_preconditions_remain_failed_without_false_recovery(self):
        for code in ('CURRENT_VERSION_CHANGED', 'CUTOVER_BACKUP_FAILED_RECOVERED'):
            with self.subTest(code=code):
                ops, _ = self._prepared_failure_worker()
                with patch.object(ops, 'activate', side_effect=host.OperationError(code, 'PRIVATE')):
                    self.assertEqual(1, ops.worker())
                receipt = ops.job()
                self.assertEqual('FAILED', receipt['state'])
                self.assertEqual(code, receipt['failure']['code'])
                self.assertFalse(receipt['failure']['recoveryRequired'])
                self.assertTrue(receipt['failure']['originalServicePreserved'])
                self.assertNotEqual('VERIFY_RECOVERY', receipt['failure']['nextAction'])

    def test_failed_backup_verification_has_no_activation_and_preserves_original(self):
        ops, _ = self._prepared_failure_worker()
        original = ops.runner
        def bad_verify(args, timeout=15):
            if '--verify' in args:
                raise subprocess.CalledProcessError(1, args, stderr='PRIVATE_BACKUP_TOKEN invalid digest')
            return original(args, timeout)
        ops.runner = bad_verify
        with patch.object(ops, 'activate') as activate:
            self.assertEqual(1, ops.worker())
            activate.assert_not_called()
        receipt = ops.job()
        self.assertEqual('BACKUP_INTEGRITY_FAILED', receipt['failure']['code'])
        self.assertTrue(receipt['failure']['originalServicePreserved'])
        self.assertNotIn('PRIVATE_BACKUP_TOKEN', json.dumps(receipt))

    def test_real_activation_child_failure_keeps_private_output_out_of_public_error(self):
        executable = self.root / 'fixture-failed-updater'
        for phase, code in (('MIGRATING', 'MIGRATION_FAILED'), ('HEALTH_CHECK', 'HEALTH_CHECK_FAILED')):
            with self.subTest(phase=phase):
                executable.write_text(f'#!/bin/sh\nprintf "UTEN_PHASE:{phase}\\nPRIVATE_SQL_TOKEN\\n"\nexit 3\n')
                executable.chmod(0o700)
                job = {'id': str(uuid.uuid4()), 'currentVersion': 'v2.5.16', 'phase': 'ACTIVATING'}
                with patch.object(host, 'UPDATER', str(executable)), self.assertRaises(host.OperationError) as caught:
                    self.operations().activate(job, 'v2.5.18')
                self.assertEqual(code, caught.exception.code)
                self.assertEqual(3, caught.exception.exit_code)
                self.assertNotIn('PRIVATE_SQL_TOKEN', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
