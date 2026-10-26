"""Root-only recovery acknowledgement; never migrates, restarts or replays a job."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys

PROC_ROOT = Path('/proc')


def running_application(host, operations, env, release):
    """Check the actual JVM, rather than the mutable current symlink alone."""
    service = env.get('UTEN_APP_SERVICE', 'uten-imp')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9@._-]{0,127}', service):
        raise host.OperationError('RECOVERY_REQUIRED', '应用服务名称无效。')
    unit = operations.runner(['/usr/bin/systemctl', 'show', service, '--property=MainPID',
                              '--property=NRestarts', '--property=ActiveState', '--property=SubState']).stdout
    try:
        values = dict(line.split('=', 1) for line in unit.splitlines() if '=' in line)
        pid, restarts = int(values['MainPID']), int(values['NRestarts'])
        if pid <= 0 or restarts < 0 or values['ActiveState'] != 'active' or values['SubState'] != 'running':
            raise ValueError()
        args = (PROC_ROOT / str(pid) / 'cmdline').read_bytes().split(b'\0')
        if args.count(b'-jar') != 1:
            raise ValueError()
        jar = Path(os.fsdecode(args[args.index(b'-jar') + 1]))
        expected = release / 'server/uten-imp-server.jar'
        # Startup pins the physical release path. Resolving /current here could
        # otherwise mistake an old JVM for the newly selected code.
        if not jar.is_absolute() or jar != expected or jar.resolve(strict=True) != expected:
            raise ValueError()
        process_stat = (PROC_ROOT / str(pid) / 'stat').read_text().rsplit(') ', 1)[1].split()
        started = int(process_stat[19])
        if started <= 0:
            raise ValueError()
        return {'pid': pid, 'nRestarts': restarts, 'startedTicks': started}
    except (OSError, ValueError, KeyError, IndexError):
        raise host.OperationError('RECOVERY_REQUIRED', '实际运行进程与已核验发布版本不一致，未解除维护。') from None


def _release_inventory(host, release, env):
    manifest = release / 'SHA256SUMS'
    signature = release / 'SHA256SUMS.sig'
    for path in (release, manifest, signature):
        info = path.lstat()
        if path.is_symlink() or info.st_uid != 0 or info.st_mode & 0o022:
            raise host.OperationError('RECOVERY_REQUIRED', '恢复版本文件权限未通过检查。')
    if not stat.S_ISDIR(release.stat().st_mode) or not manifest.is_file() or not signature.is_file():
        raise host.OperationError('RECOVERY_REQUIRED', '恢复版本缺少签名清单。')
    if manifest.stat().st_size > 4 * 1024 * 1024 or signature.stat().st_size > 65536:
        raise host.OperationError('RECOVERY_REQUIRED', '恢复版本签名清单大小无效。')
    raw = manifest.read_bytes()
    try:
        result = subprocess.run(
            ['/usr/bin/ssh-keygen', '-Y', 'verify', '-f',
             env.get('UTEN_ALLOWED_SIGNERS', '/etc/uten-imp-updater/allowed_signers'),
             '-I', env.get('UTEN_SIGNER_ID', 'uten-imp-release'),
             '-n', env.get('UTEN_NAMESPACE', 'uten-imp-release'), '-s', str(signature)],
            input=raw, capture_output=True, timeout=15,
            env={'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'}, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise host.OperationError('RECOVERY_REQUIRED', '无法验证恢复版本签名，未解除维护。') from None
    if result.returncode != 0:
        raise host.OperationError('RECOVERY_REQUIRED', '恢复版本签名未通过验证。')
    entries = set()
    try:
        lines = raw.decode('utf8').splitlines()
    except UnicodeDecodeError:
        raise host.OperationError('RECOVERY_REQUIRED', '恢复版本清单格式无效。') from None
    for line in lines:
        match = re.fullmatch(r'([a-f0-9]{64}) [ *](.+)', line)
        if not match:
            raise host.OperationError('RECOVERY_REQUIRED', '恢复版本清单格式无效。')
        digest, name = match.groups()
        name = name.removeprefix('./')
        if (not name or '\\' in name or PurePosixPath(name).is_absolute()
                or any(part in {'', '.', '..'} for part in name.split('/')) or name in entries):
            raise host.OperationError('RECOVERY_REQUIRED', '恢复版本清单路径无效。')
        entries.add(name)
        path = release
        for part in name.split('/'):
            path = path / part
            info = path.lstat()
            if path.is_symlink() or info.st_uid != 0 or info.st_mode & 0o022:
                raise host.OperationError('RECOVERY_REQUIRED', '恢复版本文件路径或权限无效。')
        if not path.is_file():
            raise host.OperationError('RECOVERY_REQUIRED', '恢复版本文件缺失。')
        actual = hashlib.sha256()
        with path.open('rb') as source:
            for block in iter(lambda: source.read(1024 * 1024), b''):
                actual.update(block)
        if actual.hexdigest() != digest:
            raise host.OperationError('RECOVERY_REQUIRED', '恢复版本文件与签名清单不一致。')
    if not {'server/uten-imp-server.jar', 'server/uten-imp-migrator.jar', 'web/version.json'} <= entries:
        raise host.OperationError('RECOVERY_REQUIRED', '恢复版本缺少必要文件。')
    metadata_path = release / 'web/version.json'
    if metadata_path.stat().st_size > 65536:
        raise host.OperationError('RECOVERY_REQUIRED', '恢复版本元数据大小无效。')
    try:
        metadata = json.loads(metadata_path.read_bytes())
        if (not isinstance(metadata, dict) or metadata.get('schemaVersion') != 1
                or metadata.get('product') != 'uten-imp' or metadata.get('version') != release.name
                or not isinstance(metadata.get('commitSha'), str)
                or not re.fullmatch(r'[a-f0-9]{40}', metadata['commitSha'])):
            raise ValueError()
    except (ValueError, UnicodeDecodeError):
        raise host.OperationError('RECOVERY_REQUIRED', '签名版本元数据与确认目标不一致。') from None
    return {'manifestSha256': hashlib.sha256(raw).hexdigest(), 'commitSha': metadata['commitSha']}


def confirm_service_restored(operations, expected_job_id, expected_version):
    # Reuse the owning host's locks, private-file checks and durable writer,
    # including when it is executed as __main__; do not import a second host.
    host = sys.modules[type(operations).__module__]
    if os.geteuid() != 0:
        raise host.OperationError('RECOVERY_REQUIRED', '仅允许服务器管理员在本机确认恢复。')
    job_id = host.identifier(expected_job_id)
    if not isinstance(expected_version, str) or not host.VERSION.fullmatch(expected_version):
        raise host.OperationError('RECOVERY_REQUIRED', '必须明确指定已核验的运行版本。')
    with host.lock(operations.state / 'operations.lock'):
        job = operations.job()
        if not job or job['id'] != job_id or job.get('state') != 'RECOVERY_REQUIRED':
            raise host.OperationError('RECOVERY_REQUIRED', '待确认的恢复任务已变化或不需要恢复。')
        job_path = operations.state / ('job-' + job_id + '.json')
        original = host.read_private(job_path)
        source_revision = operations.source.view()['revision']
        env = operations.source.load()[1]
        if host.current_version(env) != expected_version:
            raise host.OperationError('RECOVERY_REQUIRED', '运行版本与恢复确认目标不一致。')
        release = Path(env.get('UTEN_BASE', '/opt/uten-imp')) / 'releases' / expected_version
        inventory = _release_inventory(host, release, env)
        binding = job['request']['runtimeBinding']
        operations.backup_binding(binding)
        jar = release / 'server/uten-imp-server.jar'
        operations.validate_database(env, jar)
        process = running_application(host, operations, env, release)
        operations.stable_health(env)
        operations.backup_binding(binding)
        # Health observation can take time. Do not approve a different current,
        # job, release inventory or source than the one that was just verified.
        if (operations.source.view()['revision'] != source_revision
                or host.current_version(operations.source.load()[1]) != expected_version
                or operations.job().get('id') != job_id
                or host.read_private(job_path) != original
                or running_application(host, operations, env, release) != process
                or hashlib.sha256((release / 'SHA256SUMS').read_bytes()).hexdigest() != inventory['manifestSha256']):
            raise host.OperationError('RECOVERY_REQUIRED', '恢复核验期间环境已变化，未解除维护。')
        receipt = {
            'format': 'uten-service-restored-v1', 'jobId': job_id,
            'verifiedVersion': expected_version, 'confirmedAt': host.now(), 'health': 'UP',
            'migrationDigest': host.migration_digest(jar), 'manifestSha256': inventory['manifestSha256'],
            'jobSha256': hashlib.sha256(original).hexdigest(),
            'sourceRevision': source_revision, 'verifiedCommit': inventory['commitSha'],
            'runtimeBindingSha256': hashlib.sha256(json.dumps(binding, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
            'processIdentity': process,
        }
        receipt_path = operations.state / ('service-restored-' + job_id + '.json')
        host.write_json(receipt_path, receipt)
        # The original failed job remains byte-for-byte intact. Its separate,
        # evidence-bound receipt authorizes the publisher to release the gate.
        operations.publish_maintenance(job)
        return receipt
