#!/usr/bin/env python3
"""Local storage inventory and constrained deletion for the operations daemon.

Only the trusted installer supplies roots. RPC callers supply opaque identifiers,
never paths. DELETE must run inside the daemon's operations AND updater locks.
Attachment originals, database files and unleased caches are never deletable.
Recovery proofs are root-owned records of an actual restore, not verify_set output.
"""
from __future__ import annotations

import datetime as dt
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import time
import threading
import uuid

KINDS = {
    'SYSTEM': ('system_root', '系统目录'),
    'RELEASES': ('releases_root', '已安装版本'),
    'RELEASE_STAGING': ('releases_root', '下载暂存'),
    'PREACTIVATION_BACKUPS': ('preactivation_backup_root', '升级前数据库备份'),
    'PAIRED_BACKUPS': ('paired_backup_root', '数据库与上传文件配套备份'),
    'DATABASE': ('database_root', '数据库目录'),
    'UPLOADS': ('uploads_root', '当前上传目录'),
    'LEGACY_UPLOADS': ('legacy_uploads_root', '兼容旧上传目录'),
    'LOGS': ('logs_root', '运行日志'),
    'CACHE': ('cache_root', '派生缓存'),
}
VERSION = re.compile(r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)')
SET_NAME = re.compile(r'[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}')
STAGE = re.compile(r'\.stage-v[0-9]+\.[0-9]+\.[0-9]+\.[A-Za-z0-9]{6,32}')
DUMP = re.compile(r'[A-Za-z0-9_]+-v[0-9]+\.[0-9]+\.[0-9]+-[0-9]{8}-[0-9]{6}\.[A-Za-z0-9]{6,32}\.dump')
LOG = re.compile(r'[A-Za-z0-9_-]+\.log\.[0-9]{1,8}\.gz')
SHA = re.compile(r'[a-f0-9]{64}')
MAX_ENTRIES = 100000
MAX_RESOURCES = 2000
MAX_SECONDS = 8
PREVIEW_SECONDS = 300
_CACHE = {}
_CACHE_LOCK = threading.Lock()


class StorageError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def _fail(code='INVALID_REQUEST', message='存储操作参数无效。'):
    raise StorageError(code, message)


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def _digest(value):
    return hashlib.sha256(_canonical(value)).hexdigest()


def _now(context):
    return context.get('now', lambda: dt.datetime.now(dt.timezone.utc))()


def _at(value):
    parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('timezone required')
    return parsed.astimezone(dt.timezone.utc)


def _backup_created(kind, name):
    try:
        if kind == 'PAIRED_BACKUPS' and SET_NAME.fullmatch(name):
            stamp = name.split('-')[0]
            value = dt.datetime.strptime(stamp, '%Y%m%dT%H%M%SZ').replace(tzinfo=dt.timezone.utc)
            return value if value.strftime('%Y%m%dT%H%M%SZ') == stamp else None
        if kind == 'PREACTIVATION_BACKUPS' and DUMP.fullmatch(name):
            stamp = re.search(r'-([0-9]{8}-[0-9]{6})\.', name)[1]
            value = dt.datetime.strptime(stamp, '%Y%m%d-%H%M%S').replace(tzinfo=dt.timezone.utc)
            return value if value.strftime('%Y%m%d-%H%M%S') == stamp else None
    except (ValueError, TypeError):
        pass
    return None


def _uuid(value):
    try:
        if str(uuid.UUID(value)) == value:
            return value
    except (TypeError, AttributeError, ValueError):
        pass
    _fail()


def _uid():
    return os.geteuid() if hasattr(os, 'geteuid') else None


def _safe_root(value, private=False):
    if not isinstance(value, (str, Path)):
        _fail('UNAVAILABLE', '此存储目录尚未配置。')
    path = Path(value)
    if not path.is_absolute() or path == Path(path.anchor):
        _fail('UNSAFE_HOST_CONFIG', '存储目录配置不安全。')
    for part in [*reversed(path.parents), path]:
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            _fail('UNSAFE_HOST_CONFIG', '存储目录不能包含链接。')
        owners = {0, _uid()}
        if os.name == 'posix':
            import pwd
            for account in ('uten-imp', 'postgres'):
                try:
                    owners.add(pwd.getpwnam(account).pw_uid)
                except KeyError:
                    pass
        if _uid() is not None and (info.st_uid not in owners or info.st_mode & 0o022):
            # /tmp in tests is not an installation root. Production ancestors
            # must all be root-owned and non-writable by another account.
            _fail('UNSAFE_HOST_CONFIG', '存储目录权限不安全。')
    if private and (path.stat().st_mode & 0o077 or _uid() is not None and path.stat().st_uid != _uid()):
        _fail('UNSAFE_HOST_CONFIG', '操作记录目录权限不安全。')
    return path


def _read_json(path, limit=1048576, private=True):
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    with os.fdopen(os.open(path, flags), 'rb') as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_size > limit or info.st_nlink != 1
                or _uid() is not None and (info.st_uid != _uid() or info.st_mode & (0o077 if private else 0o022))):
            _fail('INVALID_STATE', '存储保护记录权限或内容异常。')
        value = json.loads(source.read(limit + 1))
    if not isinstance(value, dict):
        _fail('INVALID_STATE', '存储保护记录内容异常。')
    return value


def _write(path, value):
    fd, name = tempfile.mkstemp(prefix='.storage-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as target:
            if hasattr(os, 'fchmod'):
                os.fchmod(target.fileno(), 0o600)
            target.write(_canonical(value) + b'\n')
            target.flush()
            os.fsync(target.fileno())
        os.replace(name, path)
        if os.name == 'posix':
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def _hash_file(path, limit=8 * 1024**3):
    with os.fdopen(os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)), 'rb') as source:
        before = os.fstat(source.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_size > limit or before.st_nlink != 1
                or _uid() is not None and (before.st_uid != _uid() or before.st_mode & 0o077)):
            _fail('INVALID_STATE', '恢复证明对应文件不安全。')
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
        after = os.fstat(source.fileno())
        if _identity(before) != _identity(after):
            _fail('STALE_PREVIEW', '文件正在变化，请稍后重新核对。')
        return digest


def _identity(info):
    return [info.st_dev, info.st_ino, info.st_mode, info.st_uid if hasattr(info, 'st_uid') else None,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_nlink]


def _measure(path, deadline=None):
    """No link following; counts hardlinked allocation once and real reclaim separately."""
    started = time.monotonic()
    initial = path.lstat()
    entries, inodes, unsafe, directory_blocks = [], {}, False, 0
    stack = [(path, '')]
    while stack:
        current, relative = stack.pop()
        info = current.lstat()
        if len(entries) >= MAX_ENTRIES or time.monotonic() - started > MAX_SECONDS or deadline is not None and time.monotonic() > deadline:
            _fail('SCAN_LIMIT', '目录较大，暂未完成安全统计；不会据此删除。')
        entries.append((relative, _identity(info)))
        if info.st_dev != initial.st_dev or stat.S_ISLNK(info.st_mode):
            unsafe = True
            continue
        if stat.S_ISDIR(info.st_mode):
            blocks = getattr(info, 'st_blocks', None)
            directory_blocks = None if blocks is None or directory_blocks is None else directory_blocks + blocks * 512
            with os.scandir(current) as children:
                for child in children:
                    stack.append((Path(child.path), relative + '/' + child.name))
        elif stat.S_ISREG(info.st_mode):
            key = (info.st_dev, info.st_ino)
            row = inodes.setdefault(key, [info.st_size, getattr(info, 'st_blocks', None), info.st_nlink, 0])
            row[3] += 1
            if _uid() is not None and info.st_uid not in {0, _uid(), initial.st_uid}:
                unsafe = True
        else:
            unsafe = True
    logical = sum(info[4] for _, info in entries if stat.S_ISREG(info[2]))
    allocated = None if directory_blocks is None or any(row[1] is None for row in inodes.values()) else sum(row[1] * 512 for row in inodes.values()) + directory_blocks
    reclaimable = None if allocated is None else sum(row[1] * 512 for row in inodes.values() if row[2] == row[3]) + directory_blocks
    normalized = [(relative, identity[:6] + ([0] if relative == '' else identity[6:7]) + identity[7:])
                  for relative, identity in entries]
    return {'logicalBytes': logical, 'allocatedBytes': allocated, 'reclaimableBytes': reclaimable,
            'fileCount': sum(row[3] for row in inodes.values()), 'fingerprint': _digest(sorted(entries)),
            'contentFingerprint': _digest(sorted(normalized)),
            'newestMtimeNs': max(identity[5] for _, identity in entries),
            'directoryAllocatedBytes': directory_blocks,
            'unsafe': unsafe, 'hardlinked': any(row[2] > 1 for row in inodes.values()),
            'identity': _identity(initial), 'inodes': list(inodes),
            'inodeRows': [[*key, row[1], row[2], row[3]] for key, row in inodes.items()]}


def _reclaimable_union(resources, last_link_only=True):
    nodes = {}
    directories = 0
    for resource in resources:
        blocks = resource['measure']['directoryAllocatedBytes']
        if blocks is None:
            return None
        directories += blocks
        for device, inode, blocks, links, seen in resource['measure']['inodeRows']:
            row = nodes.setdefault((device, inode), [blocks, links, 0])
            row[2] += seen
    if any(row[0] is None for row in nodes.values()):
        return None
    return sum(row[0] * 512 for row in nodes.values() if not last_link_only or row[1] == row[2]) + directories


def _proofs(context, roots, path=None):
    """Missing/invalid proof disables backup deletion; it does not guess restore success."""
    try:
        value = _read_json(path or _safe_root(context['host_state_dir'], True) / 'recovery-proofs.json')
        if (value.get('format') != 'uten-operations-recovery-proofs-v1' or not isinstance(value.get('proofs'), list)
                or not 1 <= len(value['proofs']) <= 128):
            raise ValueError()
        candidates = []
        for proof in value['proofs']:
            kind, name = proof['kind'], proof['resourceName']
            if kind not in ('PAIRED_BACKUPS', 'PREACTIVATION_BACKUPS') or not isinstance(name, str):
                raise ValueError()
            pattern = SET_NAME if kind == 'PAIRED_BACKUPS' else DUMP
            if (not pattern.fullmatch(name) or _backup_created(kind, name) is None
                    or type(proof.get('restoreExitCode')) is not int or proof.get('restoreExitCode') != 0
                    or not VERSION.fullmatch(proof.get('sourceVersion', ''))
                    or not str(proof.get('flywayVersion', '')).isdigit()
                    or type(proof.get('flywayCount')) is not int or proof['flywayCount'] < 1
                    or not SHA.fullmatch(proof.get('dumpSha256', ''))
                    or proof.get('verificationMethod') != 'ISOLATED_POSTGRES_RESTORE'
                    or not SHA.fullmatch(proof.get('restoreReceiptSha256', ''))
                    or str(proof.get('restoredFlywayVersion')) != str(proof.get('flywayVersion'))
                    or proof.get('restoredFlywayCount') != proof.get('flywayCount')
                    or type(proof.get('restoredFlywayFailed')) is not int or proof.get('restoredFlywayFailed') != 0
                    or _at(proof['verifiedAt']) > _now(context)):
                raise ValueError()
            candidates.append(proof)
        required = value.get('requiredRollbackResources')
        versions = value.get('requiredReleaseVersions')
        if (not isinstance(required, list) or len(required) > 128 or not isinstance(versions, list)
                or not 1 <= len(versions) <= 64
                or len({(p['kind'], p['resourceName']) for p in candidates}) != len(candidates)):
            raise ValueError()
        for item in required:
            if item.get('kind') not in ('PAIRED_BACKUPS', 'PREACTIVATION_BACKUPS') or not any(
                    p['kind'] == item['kind'] and p['resourceName'] == item.get('resourceName') for p in candidates):
                raise ValueError()
        if any(not isinstance(v, str) or not VERSION.fullmatch(v) for v in versions):
            raise ValueError()
        # Old proof history may refer to an already-expired set. Only the latest
        # actual restore per kind and explicit rollback dependencies stay live.
        selected = {(p['kind'], p['resourceName']) for p in required}
        for kind in ('PAIRED_BACKUPS', 'PREACTIVATION_BACKUPS'):
            own = [p for p in candidates if p['kind'] == kind]
            if own:
                latest = max(own, key=lambda p: _at(p['verifiedAt']))
                selected.add((kind, latest['resourceName']))
        verified = []
        for proof in candidates:
            kind, name = proof['kind'], proof['resourceName']
            if (kind, name) not in selected:
                continue
            target = roots[kind] / name
            if kind == 'PAIRED_BACKUPS':
                _safe_root(target, True)
                if not SHA.fullmatch(proof.get('manifestSha256', '')):
                    raise ValueError()
                if _hash_file(target / 'manifest.json', 65536) != proof['manifestSha256']:
                    raise ValueError()
                manifest = _read_json(target / 'manifest.json', 65536)
                if (manifest.get('format') != 'uten-paired-internal-v2' or manifest.get('set_id') != name
                        or manifest.get('database_dump_sha256') != proof['dumpSha256']
                        or manifest.get('database_dump_bytes') != (target / 'database.dump').stat().st_size):
                    raise ValueError()
                target = target / 'database.dump'
            if _hash_file(target) != proof['dumpSha256']:
                raise ValueError()
            verified.append(proof)
        return value, verified
    except (OSError, ValueError, TypeError, KeyError, AttributeError, StorageError):
        return None, []


def _open_inodes():
    """Unknown process access is fail-closed, never a false claim that a file is unused."""
    if os.name != 'posix' or not Path('/proc').is_dir():
        _fail('UNAVAILABLE', '当前环境无法安全核对文件是否正在使用。')
    result = set()
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            for fd in (process / 'fd').iterdir():
                try:
                    info = fd.stat()
                    result.add((info.st_dev, info.st_ino))
                except FileNotFoundError:
                    continue
        except FileNotFoundError:
            continue
        except PermissionError:
            _fail('UNAVAILABLE', '暂时不能核对所有运行进程，清理已保护。')
    return result


def _inventory(context):
    config = context['config']
    roots = {}
    categories, resources, volumes = [], [], {}
    quarantine_present = False
    now = _now(context)
    deadline = time.monotonic() + MAX_SECONDS
    for kind, (key, label) in KINDS.items():
        # Optional, installer-bound legacy local originals. Absence means the
        # deployment has no configured second root, not an unknown zero total.
        if kind == 'LEGACY_UPLOADS' and not config.get(key):
            continue
        try:
            category_deadline = min(deadline, time.monotonic() + MAX_SECONDS / len(KINDS))
            root = _safe_root(config.get(key))
            roots[kind] = root
            info = root.stat()
            volume = os.statvfs(root) if hasattr(os, 'statvfs') else None
            volume_id = _digest(['volume', info.st_dev])[:24]
            if volume:
                total, free = volume.f_blocks * volume.f_frsize, volume.f_bavail * volume.f_frsize
                volumes.setdefault(volume_id, {'id': volume_id, 'label': '存储卷 ' + str(len(volumes) + 1),
                                               'totalBytes': total, 'usedBytes': total - free, 'freeBytes': free})
            # SYSTEM is an overview root and can overlap releases: never add category sizes.
            candidates = []
            for item in sorted(root.iterdir(), key=lambda p: p.name):
                name = item.name
                abandoned = name.startswith('.operations-trash-')
                if abandoned:
                    quarantine_present = True
                if not abandoned and kind == 'RELEASES' and not VERSION.fullmatch(name):
                    continue
                if not abandoned and kind == 'RELEASE_STAGING' and not STAGE.fullmatch(name):
                    continue
                partial_dump = kind == 'PREACTIVATION_BACKUPS' and name.endswith('.partial') and DUMP.fullmatch(name.removesuffix('.partial'))
                partial_set = kind == 'PAIRED_BACKUPS' and any(name.startswith(prefix) and SET_NAME.fullmatch(name[len(prefix):])
                                                                            for prefix in ('.incomplete-', '.expired-'))
                if not abandoned and kind == 'PREACTIVATION_BACKUPS' and not DUMP.fullmatch(name) and not partial_dump:
                    continue
                if not abandoned and kind == 'PAIRED_BACKUPS' and not SET_NAME.fullmatch(name) and not partial_set:
                    continue
                candidates.append(item)
                if len(candidates) > MAX_RESOURCES:
                    _fail('SCAN_LIMIT', '条目较多，暂未完成安全统计。')
            measurements = []
            for item in candidates:
                measured = _measure(item, category_deadline)
                resource_id = _digest([kind, item.name, measured['identity']])
                public = {'id': resource_id, 'kind': kind, 'label': '未完成清理隔离项' if item.name.startswith('.operations-trash-') else item.name,
                          'logicalBytes': measured['logicalBytes'], 'allocatedBytes': measured['allocatedBytes'],
                          'reclaimableBytes': 0, 'modifiedAt': dt.datetime.fromtimestamp(item.lstat().st_mtime, dt.timezone.utc).isoformat(),
                          'canDelete': False, 'protectionReasons': [], 'detail': ''}
                resources.append({'public': public, 'root': str(root), 'name': item.name, 'measure': measured})
                measurements.append(measured)
            # Count physical blocks only once across resources, including hardlinked backup sets.
            whole = _measure(root, category_deadline) if kind not in ('RELEASES', 'RELEASE_STAGING') else None
            category_resources = [r for r in resources if r['public']['kind'] == kind]
            detail = '数量为目录直属条目；目录占用与卷容量分别统计，不同类别可能共用同一卷。'
            if kind == 'UPLOADS':
                detail += ' 仅统计当前配置的上传目录，不包含兼容旧 local 目录；附件登记量另行统计，不能将各目录占用直接相加。'
            elif kind == 'LEGACY_UPLOADS':
                detail += ' 仅统计正式配套备份配置中保留的兼容旧 local 原件目录；可能仍被历史业务引用，永不提供文件级清理。各类别可能重叠，不能直接相加。'
            categories.append({'kind': kind, 'label': label, 'status': 'NORMAL',
                               'logicalBytes': whole['logicalBytes'] if whole else sum(m['logicalBytes'] for m in measurements),
                               'allocatedBytes': whole['allocatedBytes'] if whole else _reclaimable_union(category_resources, False),
                               'reclaimableBytes': 0, 'count': len(candidates), 'canList': True,
                               'detail': detail, 'volumeId': volume_id})
        except (OSError, StorageError):
            categories.append({'kind': kind, 'label': label, 'status': 'UNKNOWN', 'logicalBytes': None,
                               'allocatedBytes': None, 'reclaimableBytes': None, 'count': None,
                               'canList': False, 'detail': '目录未配置、不可读或超出本次安全统计上限。', 'volumeId': None})
            resources = [r for r in resources if r['public']['kind'] != kind]
    proof_registry, proofs = _proofs(context, roots)
    protected = set()
    if proof_registry:
        protected.update((p['kind'], p['resourceName']) for p in proof_registry['requiredRollbackResources'])
        for kind in ('PAIRED_BACKUPS', 'PREACTIVATION_BACKUPS'):
            own = [p for p in proofs if p['kind'] == kind]
            if own:
                p = max(own, key=lambda p: _at(p['verifiedAt']))
                protected.add((kind, p['resourceName']))
    # Current link is observed, never followed for directory enumeration.
    current = None
    try:
        current_link = roots['RELEASES'].parent / 'current'
        current_path = current_link.resolve(strict=True)
        if current_link.is_symlink() and current_path.parent == roots['RELEASES'] and VERSION.fullmatch(current_path.name):
            current = current_path.name
    except (KeyError, OSError, RuntimeError):
        pass
    versions = sorted([r['name'] for r in resources if r['public']['kind'] == 'RELEASES' and VERSION.fullmatch(r['name'])],
                      key=lambda name: tuple(map(int, name[1:].split('.'))), reverse=True)
    release_keep = set(versions[:max(3, int(config.get('release_min_versions', 3)))])
    if current:
        release_keep.add(current)
        prior = [v for v in versions if tuple(map(int, v[1:].split('.'))) < tuple(map(int, current[1:].split('.')))]
        if prior:
            release_keep.add(prior[0])
    if proof_registry:
        release_keep.update(proof_registry['requiredReleaseVersions'])
        # A protected recovery point also protects its matching application,
        # even if a human omitted that version from the extra rollback list.
        release_keep.update(p['sourceVersion'] for p in proofs)
    complete = set()
    for resource in resources:
        kind, name = resource['public']['kind'], resource['name']
        try:
            if kind == 'PAIRED_BACKUPS':
                manifest = _read_json(Path(resource['root']) / name / 'manifest.json', 65536)
                if (_backup_created(kind, name) is not None and manifest.get('format') == 'uten-paired-internal-v2' and manifest.get('set_id') == name
                        and SHA.fullmatch(manifest.get('database_dump_sha256', ''))
                        and (Path(resource['root']) / name / 'database.dump').is_file()
                        and (Path(resource['root']) / name / 'database.dump').stat().st_size == manifest.get('database_dump_bytes')):
                    complete.add((kind, name))
            elif (kind == 'PREACTIVATION_BACKUPS' and _backup_created(kind, name) is not None
                  and stat.S_ISREG(resource['measure']['identity'][2]) and resource['measure']['logicalBytes'] > 0):
                complete.add((kind, name))
        except (OSError, ValueError, StorageError):
            pass
    for kind in ('PAIRED_BACKUPS', 'PREACTIVATION_BACKUPS'):
        own = sorted([r for r in resources if (kind, r['name']) in complete and r['public']['kind'] == kind],
                     key=lambda r: (_backup_created(kind, r['name']), r['name']), reverse=True)
        protected.update((kind, r['name']) for r in own[:max(3, int(config.get('min_complete_sets', 3)))])
    latest = None
    try:
        latest = _read_json(roots['PAIRED_BACKUPS'] / 'latest-success.json')['set_id']
        if not SET_NAME.fullmatch(latest) or ('PAIRED_BACKUPS', latest) not in complete:
            raise ValueError()
        protected.add(('PAIRED_BACKUPS', latest))
    except (KeyError, OSError, ValueError, StorageError):
        latest = None
    for resource in resources:
        public, measured, name = resource['public'], resource['measure'], resource['name']
        kind = public['kind']
        reasons = public['protectionReasons']
        if context.get('active_jobs'):
            reasons.append('已有预约或执行中的运维作业，完成或取消后才能清理。')
        if quarantine_present:
            reasons.append('存在上次未完成清理的隔离条目，需管理员先核对。')
        age = (now - _at(public['modifiedAt'])).total_seconds()
        if measured['unsafe']:
            reasons.append('存在链接、跨卷、特殊文件或非受控所有者，需人工核对。')
        if kind in ('SYSTEM', 'DATABASE', 'UPLOADS', 'LEGACY_UPLOADS', 'CACHE'):
            reasons.append({'SYSTEM': '系统目录只读。', 'DATABASE': '数据库文件由数据库管理，禁止文件级删除。',
                            'UPLOADS': '上传原件及私有文档可能被业务或历史记录引用，必须走业务核对流程。',
                            'LEGACY_UPLOADS': '兼容旧上传原件可能仍被业务或历史记录引用，永不提供文件级清理。',
                            'CACHE': '尚无完整的使用租约证据，缓存受保护。'}[kind])
        elif kind == 'RELEASES':
            age = min(age, now.timestamp() - measured['newestMtimeNs'] / 1_000_000_000)
            if name == current:
                reasons.append('当前运行版本。')
            elif not current or not proof_registry:
                reasons.append('缺少可信的当前版本或回滚保护清单。')
            elif name in release_keep:
                reasons.append('回滚所需版本或最新至少三个版本保护。')
            if not stat.S_ISDIR(measured['identity'][2]) or _uid() is not None and measured['identity'][3] != _uid():
                reasons.append('版本目录身份或所有者不符合要求。')
            if age < max(14, int(config.get('release_retention_days', 14))) * 86400:
                reasons.append('仍在版本保留期内（至少 14 天）。')
        elif kind == 'RELEASE_STAGING':
            if not stat.S_ISDIR(measured['identity'][2]):
                reasons.append('下载暂存必须是受控目录。')
            newest_age = now.timestamp() - measured['newestMtimeNs'] / 1_000_000_000
            if age < 86400 or newest_age < 86400:
                reasons.append('下载暂存仍在观察期（24 小时）。')
            if measured['hardlinked']:
                reasons.append('暂存包含硬链接，需人工核对。')
            if _uid() is not None and measured['identity'][3] != _uid():
                reasons.append('暂存所有者不属于主机更新服务。')
        elif kind == 'LOGS':
            if not LOG.fullmatch(name) or not stat.S_ISREG(measured['identity'][2]) or age < 7 * 86400 or measured['hardlinked']:
                reasons.append('仅支持超过 7 天且已压缩闭合的轮转日志。')
        elif kind in ('PAIRED_BACKUPS', 'PREACTIVATION_BACKUPS'):
            recorded = next((p for p in (proof_registry or {}).get('proofs', [])
                             if p['kind'] == kind and p['resourceName'] == name), None)
            verified = next((p for p in proofs if p['kind'] == kind and p['resourceName'] == name), None)
            public['verificationLevel'] = 'RESTORE_VERIFIED' if verified else 'RESTORE_RECORDED' if recorded else 'UNVERIFIED'
            public['detail'] = ('实际隔离恢复已核对，时间：' + verified['verifiedAt'] + '。') if verified else (
                '留有历史恢复记录；本次未重新核对该记录的文件哈希。' if recorded else '没有登记实际隔离恢复证明；备份完整性检查不等于恢复成功。')
            created = _backup_created(kind, name)
            if created is not None:
                age = min(age, (now - created).total_seconds())
            if _uid() is not None and (measured['identity'][3] != _uid() or measured['identity'][2] & 0o077):
                reasons.append('备份所有者或私有权限不符合要求。')
            if not proof_registry or not any(p['kind'] == kind for p in proofs):
                reasons.append('缺少绑定原始备份哈希的实际恢复证明，禁止删除备份。')
            if (kind, name) in protected:
                reasons.append('最新恢复点、成功指针、回滚所需或至少三套完整备份保护。')
            if (kind, name) not in complete:
                reasons.append('备份完整身份未确认。')
            if kind == 'PAIRED_BACKUPS':
                try:
                    manifest = _read_json(Path(resource['root']) / name / 'manifest.json', 65536)
                    if manifest.get('format') != 'uten-paired-internal-v2' or manifest.get('set_id') != name or not latest:
                        raise ValueError()
                except (OSError, ValueError, StorageError):
                    reasons.append('备份完整身份或成功指针未确认。')
            keep = max(14, int(config.get('backup_retention_days', 14)))
            if age < keep * 86400:
                reasons.append('仍在备份保留期内（至少 14 天）。')
        if os.name != 'posix':
            reasons.append('此环境不提供受控主机清理。')
        public['canDelete'] = not reasons
        public['reclaimableBytes'] = measured['reclaimableBytes'] if not reasons else 0
    for category in categories:
        if quarantine_present:
            category['detail'] += ' 存在未完成清理的隔离项，需管理员核对；清理已保护。'
            if category['status'] == 'NORMAL':
                category['status'] = 'WARNING'
        if category['status'] == 'NORMAL':
            category['reclaimableBytes'] = _reclaimable_union([r for r in resources
                                                              if r['public']['kind'] == category['kind'] and r['public']['canDelete']])
    protection = {'proofs': proof_registry, 'current': current, 'latestSuccess': latest,
                  'releaseKeep': sorted(release_keep), 'protected': sorted(protected),
                  'quarantine': quarantine_present, 'activeJobs': context.get('active_jobs', [])}
    revision = _digest({'resources': [(r['public']['id'], r['measure']['fingerprint']) for r in resources if r['public']['canDelete']], 'protection': protection,
                        'config': config})
    return {'sampledAt': now.isoformat(), 'status': 'NORMAL' if all(c['status'] == 'NORMAL' for c in categories) else 'UNKNOWN',
            'revision': revision, 'capabilities': {'available': True, 'canCleanup': os.name == 'posix' and not context.get('active_jobs'),
                                                 'unavailableReason': '已有预约或执行中的运维作业。' if context.get('active_jobs') else None},
            'volumes': list(volumes.values()), 'categories': categories}, resources


def _select(resources, ids):
    if (not isinstance(ids, list) or not 1 <= len(ids) <= 50
            or any(not isinstance(i, str) or not SHA.fullmatch(i) for i in ids) or len(set(ids)) != len(ids)):
        _fail()
    selected = {r['public']['id']: r for r in resources}
    if any(i not in selected for i in ids):
        _fail('STALE_PREVIEW', '所选文件已变化，请刷新列表。')
    result = [selected[i] for i in ids]
    if any(not r['public']['canDelete'] for r in result):
        _fail('PROTECTED', '所选条目受保护，不能清理。')
    open_inodes = _open_inodes()
    if any(set(map(tuple, r['measure']['inodes'])) & open_inodes for r in result):
        _fail('BUSY', '所选文件正在使用，请稍后重新预览。')
    return result


def _remove_tree(parent_fd, name, expected, device):
    info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if _identity(info) != expected or info.st_dev != device or stat.S_ISLNK(info.st_mode):
        _fail('STALE_PREVIEW', '文件身份发生变化，已停止清理。')
    if stat.S_ISDIR(info.st_mode):
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            if _identity(os.fstat(fd)) != expected:
                _fail('STALE_PREVIEW', '文件身份发生变化，已停止清理。')
            for child in os.listdir(fd):
                child_info = os.stat(child, dir_fd=fd, follow_symlinks=False)
                _remove_tree(fd, child, _identity(child_info), device)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.rmdir(name, dir_fd=parent_fd)
    elif stat.S_ISREG(info.st_mode):
        os.unlink(name, dir_fd=parent_fd)
    else:
        _fail('PROTECTED', '特殊文件不能清理。')


def _prepare_one(resource, request_id, stack):
    root = _safe_root(resource['root'])
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    stack.callback(os.close, fd)
    quarantined = '.operations-trash-' + request_id + '-' + uuid.uuid4().hex
    actual = _measure(root / resource['name'])
    if actual['fingerprint'] != resource['measure']['fingerprint']:
        _fail('STALE_PREVIEW', '文件内容发生变化，已停止清理。')
    os.rename(resource['name'], quarantined, src_dir_fd=fd, dst_dir_fd=fd)
    os.fsync(fd)
    # All selected resources are quarantined and verified before any unlink.
    # This keeps valid hardlinks shared by selected backup sets from looking
    # like external mutations after the first set is removed.
    after = _measure(root / quarantined)
    if after['identity'][:6] != actual['identity'][:6] or after['contentFingerprint'] != actual['contentFingerprint']:
        _fail('RECOVERY_REQUIRED', '隔离后的文件身份异常，需管理员核对；没有继续删除。')
    return fd, quarantined, after


def _delete_one(resource, request_id, prepared):
    fd, quarantined, after = prepared
    reclaimable = _measure(Path(resource['root']) / quarantined)['reclaimableBytes']
    _remove_tree(fd, quarantined, after['identity'], after['identity'][0])
    os.fsync(fd)
    return reclaimable


@contextlib.contextmanager
def _paired_lock(context):
    import fcntl
    root = _safe_root(context['config'].get('paired_backup_root'))
    fd = os.open(root / '.backup.lock', os.O_RDWR | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != _uid() or info.st_mode & 0o077 or info.st_nlink != 1:
            _fail('UNSAFE_HOST_CONFIG', '配套备份锁权限不安全。')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            _fail('BUSY', '配套备份正在运行，请稍后重试。')
        yield
    finally:
        os.close(fd)


def record_restore_proof(payload: dict, context: dict) -> dict:
    """Root CLI only. Caller attests a real isolated restore; HTTP cannot call this.

    Daemon owns operations/updater locks; this function also excludes formal paired
    backup retention. Evidence must bind both source and restored Flyway catalogs.
    No configured path, execution command, or restore target is accepted in payload.
    """
    if (os.name != 'posix' or _uid() != 0 or not context.get('lock_held') or context.get('active_jobs')
            or not isinstance(payload, dict)
            or set(payload) != {'proof', 'requiredReleaseVersions', 'requiredRollbackResources'}):
        _fail('FORBIDDEN', '恢复证明只能由主机管理员在受控锁内登记。')
    proof = payload['proof']
    proof_fields = {'kind', 'resourceName', 'manifestSha256', 'dumpSha256', 'verifiedAt', 'restoreExitCode',
                    'sourceVersion', 'flywayVersion', 'flywayCount', 'verificationMethod', 'restoreReceiptSha256',
                    'restoredFlywayVersion', 'restoredFlywayCount', 'restoredFlywayFailed'}
    if not isinstance(proof, dict) or set(proof) - proof_fields:
        _fail()
    if proof.get('kind') not in ('PAIRED_BACKUPS', 'PREACTIVATION_BACKUPS'):
        _fail()
    with contextlib.ExitStack() as locks:
        if proof['kind'] == 'PAIRED_BACKUPS':
            locks.enter_context(_paired_lock(context))
        state = _safe_root(context['host_state_dir'], True)
        path = state / 'recovery-proofs.json'
        try:
            old = _read_json(path)
            if old.get('format') != 'uten-operations-recovery-proofs-v1' or not isinstance(old.get('proofs'), list):
                _fail('INVALID_STATE', '原恢复证明记录异常，禁止覆盖。')
        except FileNotFoundError:
            old = {'format': 'uten-operations-recovery-proofs-v1', 'proofs': []}
        proofs = list(old['proofs'])
        matches = [p for p in proofs if p.get('kind') == proof.get('kind') and p.get('resourceName') == proof.get('resourceName')]
        if any(p.get('dumpSha256') != proof.get('dumpSha256') or p.get('manifestSha256') != proof.get('manifestSha256') for p in matches):
            _fail('CONFLICT', '同一备份身份已登记不同哈希，禁止覆盖恢复证明。')
        proofs = [p for p in proofs if p not in matches] + [proof]
        value = {'format': 'uten-operations-recovery-proofs-v1', 'proofs': proofs,
                 'requiredReleaseVersions': payload['requiredReleaseVersions'],
                 'requiredRollbackResources': payload['requiredRollbackResources']}
        # Reuse the same validator against exact current backup bytes before publish.
        candidate = state / ('recovery-candidate-' + uuid.uuid4().hex + '.json')
        _write(candidate, value)
        try:
            roots = {}
            for kind in ('PAIRED_BACKUPS', 'PREACTIVATION_BACKUPS'):
                try:
                    roots[kind] = _safe_root(context['config'].get(KINDS[kind][0]))
                except (StorageError, OSError):
                    pass
            registry, verified = _proofs(context, roots, candidate)
            if registry is None or not any(p == proof for p in verified):
                _fail('VALIDATION_FAILED', '实际恢复证据、目录哈希或目录版本不一致，未登记。')
            releases = _safe_root(context['config'].get('releases_root'))
            current = releases.parent / 'current'
            resolved = current.resolve(strict=True)
            if (not current.is_symlink() or resolved.parent != releases
                    or resolved.name not in value['requiredReleaseVersions']):
                _fail('VALIDATION_FAILED', '恢复保护清单必须包含当前运行版本。')
            os.replace(candidate, path)
            directory = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
            with _CACHE_LOCK:
                _CACHE.clear()
            return {'recorded': True, 'kind': proof['kind'], 'resourceName': proof['resourceName'],
                    'verifiedAt': proof['verifiedAt'], 'proofRevision': _digest(value)}
        finally:
            if candidate.exists():
                candidate.unlink()


def dispatch(operation: str, payload: dict, context: dict) -> dict:
    if not isinstance(payload, dict):
        _fail()
    allowed = {'STORAGE_SUMMARY': set(), 'STORAGE_LIST': {'kind', 'cursor', 'limit'},
               'STORAGE_PREVIEW_DELETE': {'resourceIds'}, 'STORAGE_DELETE': {'previewId', 'requestId'},
               'STORAGE_RESULT': {'requestId'}}
    if operation not in allowed or set(payload) - allowed[operation]:
        _fail()
    if operation == 'STORAGE_RESULT':
        return _read_result(payload, context)
    if operation == 'STORAGE_DELETE':
        if not context.get('lock_held') or context.get('active_jobs'):
            _fail('BUSY', '服务器正在更新或未取得安全操作锁。')
        actor, request = _uuid(context.get('actor_id')), _uuid(payload.get('requestId'))
        if context.get('request_id') != request:
            _fail()
        state = _safe_root(context['host_state_dir'], True)
        receipt_path = state / ('storage-result-' + request + '.json')
        if receipt_path.exists():
            receipt = _read_json(receipt_path)
            if receipt.get('actorId') != actor or receipt.get('previewId') != payload.get('previewId'):
                _fail('CONFLICT', '操作标识已用于另一次清理。')
            return receipt['result']
        preview = _read_json(state / ('storage-preview-' + _uuid(payload.get('previewId')) + '.json'))
        if preview.get('actorId') != actor or _at(preview['expiresAt']) <= _now(context):
            _fail('STALE_PREVIEW', '清理预览已过期或不属于当前账号，请重新预览。')
        receipt = {'actorId': actor, 'previewId': payload['previewId'], 'result': {
            'requestId': request, 'status': 'RUNNING', 'deletedCount': 0, 'reclaimedBytes': 0,
            'detail': '清理请求已保存，正在重新核对保护状态；请通过本次回执查看结果。'}}
        _write(receipt_path, receipt)
        # A formal paired backup has its own lock, independent of the update lock.
        # Hold it through revalidation, pruning and receipt persistence.
        execution_started = False
        try:
            with contextlib.ExitStack() as locks:
                if 'PAIRED_BACKUPS' in preview.get('kinds', []):
                    locks.enter_context(_paired_lock(context))
                execution_started = True
                result = _execute_preview(payload, context, preview, receipt_path, actor, request)
        except (StorageError, OSError):
            if execution_started:
                try:
                    receipt = _read_json(receipt_path)
                except (OSError, StorageError, ValueError):
                    pass
                receipt['result'].update(status='RECOVERY_REQUIRED', detail='执行结果未能完整保存，请管理员核对；不会自动重复清理。')
            else:
                receipt['result'].update(status='FAILED', detail='清理前核对未通过；没有开始删除，请刷新后重新预览。')
            _write(receipt_path, receipt)
            return receipt['result']
        finally:
            with _CACHE_LOCK:
                _CACHE.clear()
        return result
    if operation == 'STORAGE_PREVIEW_DELETE':
        summary, resources = _inventory(context)
    else:
        key = _digest([context['config'], str(context.get('host_state_dir'))])
        with _CACHE_LOCK:
            cached = _CACHE.get(key)
            if cached is None or time.monotonic() - cached[0] >= 60:
                _CACHE.clear()
                summary, resources = _inventory(context)
                _CACHE[key] = (time.monotonic(), summary, resources)
            else:
                _, summary, resources = cached
    if operation == 'STORAGE_SUMMARY':
        return summary
    if operation == 'STORAGE_LIST':
        kind, limit = payload.get('kind'), payload.get('limit', 50)
        if kind not in KINDS or type(limit) is not int or not 1 <= limit <= 100:
            _fail()
        rows = [r['public'] for r in resources if r['public']['kind'] == kind]
        offset = 0
        cursor = payload.get('cursor')
        if cursor:
            if not isinstance(cursor, str) or not re.fullmatch(r'[a-f0-9]{64}:[0-9]{1,6}', cursor):
                _fail()
            revision, index = cursor.split(':')
            if revision != summary['revision']:
                _fail('STALE_PREVIEW', '存储列表已变化，请从第一页重新读取。')
            offset = int(index)
        page, used = [], 0
        for row in rows[offset:offset + limit]:
            size = len(_canonical(row))
            if page and used + size > 48000:
                break
            page.append(row)
            used += size
        return {'sampledAt': summary['sampledAt'], 'revision': summary['revision'], 'kind': kind,
                'items': page, 'total': len(rows),
                'nextCursor': summary['revision'] + ':' + str(offset + len(page)) if offset + len(page) < len(rows) else None}
    actor = _uuid(context.get('actor_id'))
    selected = _select(resources, payload.get('resourceIds'))
    preview_id = str(uuid.uuid4())
    expires = (_now(context) + dt.timedelta(seconds=PREVIEW_SECONDS)).isoformat()
    record = {'actorId': actor, 'revision': summary['revision'], 'resourceIds': payload['resourceIds'],
              'kinds': sorted({r['public']['kind'] for r in selected}), 'expiresAt': expires}
    _write(_safe_root(context['host_state_dir'], True) / ('storage-preview-' + preview_id + '.json'), record)
    return {'previewId': preview_id, 'expiresAt': expires, 'revision': summary['revision'],
            'resources': [r['public'] for r in selected],
            'totalReclaimableBytes': _reclaimable_union(selected),
            'confirmationText': '确认清理', 'warnings': ['清理会永久删除所选文件；正在使用、业务引用及恢复保护条目不能删除。']}


def prune_preactivation_backups(context: dict) -> dict:
    """One bounded post-update batch, using the same protected UI delete path.

    The successful update worker owns both operations/updater locks and records
    its durable cleanup intent before calling this non-RPC entry. No new age,
    count, proof or rollback policy is defined here. Excess beyond the protocol's
    50-resource batch limit is reported for a later update or manual cleanup.
    """
    if not context.get('lock_held') or context.get('active_jobs'):
        _fail('BUSY', '服务器正在更新或未取得安全操作锁。')
    _, resources = _inventory(context)
    candidates = sorted(
        (r for r in resources if r['public']['kind'] == 'PREACTIVATION_BACKUPS' and r['public']['canDelete']),
        key=lambda r: (_backup_created('PREACTIVATION_BACKUPS', r['name']), r['name']),
    )
    if not candidates:
        return {'status': 'SKIPPED', 'deletedCount': 0, 'reclaimedBytes': 0,
                'deferredCount': 0, 'detail': '没有符合保留期与恢复保护规则的升级前备份可清理。'}
    selected = candidates[:50]
    preview = dispatch('STORAGE_PREVIEW_DELETE', {'resourceIds': [r['public']['id'] for r in selected]}, context)
    result = dispatch('STORAGE_DELETE', {'previewId': preview['previewId'], 'requestId': context['request_id']}, context)
    return {**result, 'previewId': preview['previewId'], 'deferredCount': len(candidates) - len(selected)}


def _execute_preview(payload, context, preview, receipt_path, actor, request):
    receipt = _read_json(receipt_path)
    try:
        summary, resources = _inventory(context)
        if summary['revision'] != preview['revision']:
            _fail('STALE_PREVIEW', '存储内容或保护状态已变化，请重新预览。')
        selected = _select(resources, preview['resourceIds'])
    except (StorageError, OSError):
        receipt['result'].update(status='FAILED', detail='所选文件或保护状态已变化，未开始删除，请刷新后重新预览。')
        _write(receipt_path, receipt)
        return receipt['result']
    count, reclaimed = 0, 0
    try:
        with contextlib.ExitStack() as files:
            prepared = [_prepare_one(resource, request, files) for resource in selected]
            opened = _open_inodes()
            if any(set(map(tuple, after['inodes'])) & opened for _, _, after in prepared):
                _fail('RECOVERY_REQUIRED', '隔离后的文件仍在使用，已停止清理。')
            for resource, entry in zip(selected, prepared):
                freed = _delete_one(resource, request, entry)
                count += 1
                reclaimed += freed or 0
                receipt['result'].update(deletedCount=count, reclaimedBytes=reclaimed)
                _write(receipt_path, receipt)
        receipt['result'].update(status='SUCCEEDED', detail='所选文件已按保护规则完成清理。')
    except (OSError, StorageError):
        receipt['result'].update(status='PARTIAL' if count else 'FAILED', detail='清理已停止；请核对结果并重新刷新，不能重复提交旧预览。')
    _write(receipt_path, receipt)
    return receipt['result']

def _read_result(payload, context):
    actor, request = _uuid(context.get('actor_id')), _uuid(payload.get('requestId'))
    state = _safe_root(context['host_state_dir'], True)
    path = state / ('storage-result-' + request + '.json')
    try:
        receipt = _read_json(path)
    except FileNotFoundError:
        _fail('NOT_FOUND', '尚未找到本次清理回执；不能据此认定请求没有执行。')
    if receipt.get('actorId') != actor:
        _fail('FORBIDDEN', '无权读取其他账号的清理回执。')
    if receipt['result']['status'] != 'RUNNING':
        return receipt['result']
    # Never wait on a running cleanup. A nonblocking lock observation distinguishes
    # an active worker from a durable intent abandoned by an interrupted daemon.
    if os.name != 'posix':
        return receipt['result']
    import fcntl
    try:
        fd = os.open(state / 'operations.lock', os.O_RDWR | os.O_NOFOLLOW)
    except FileNotFoundError:
        return receipt['result']
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != _uid() or info.st_mode & 0o077 or info.st_nlink != 1:
            _fail('INVALID_STATE', '运维锁状态异常，请由管理员核对。')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return receipt['result']
        latest = _read_json(path)
        if latest['result']['status'] == 'RUNNING':
            latest['result'].update(status='RECOVERY_REQUIRED', detail='执行进程已中断，结果需要管理员核对；不会自动重复清理。')
            _write(path, latest)
        return latest['result']
    finally:
        os.close(fd)
