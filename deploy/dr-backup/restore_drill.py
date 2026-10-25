#!/usr/bin/python3
"""Restore a sealed paired backup into an isolated, disposable, memory-only PostgreSQL.

Runs on a trusted recovery workstation. GPG passphrase arrives on stdin; no
private key or plaintext backup is sent to either production or archive hosts.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import shutil
import stat
import resource
import fcntl
import re
import shlex
import struct
import subprocess
import sys
import tarfile
import time
import uuid
import tempfile
from contextlib import contextmanager

PHASE = "INITIALIZING"
SAFE_COUNTS = {}
MAX_METADATA_BYTES = 64 * 1024**2
MAX_PLAIN_BYTES = 2 * 1024**3
MAX_ARCHIVE_CIPHER_BYTES = 3 * 1024**3
MAX_RECOVERY_WORKSPACES = 4

RESOURCE_PROFILES = {
    'small': {'pgdataBytes': 2 * 1024**3, 'memoryBytes': 3 * 1024**3, 'minimumAvailableBytes': 0},
    'large-memory': {'pgdataBytes': 12 * 1024**3, 'memoryBytes': 14 * 1024**3,
                     'minimumAvailableBytes': 18 * 1024**3},
}
DEFAULT_POSTGRES_IMAGE = 'docker.io/library/postgres:16'
APPARMOR_PROFILE_PATH = Path('/etc/apparmor.d/uten-dr-recovery')
APPARMOR_PROFILES_PATH = Path('/sys/kernel/security/apparmor/profiles')


def official_postgres_image(value):
    if not isinstance(value, str) or not re.fullmatch(
            r'docker\.io/library/postgres(?::16(?:\.[0-9]+)?(?:-(?:bookworm|bullseye|trixie))?|@sha256:[a-f0-9]{64})', value):
        raise ValueError('Pin a fully qualified official PostgreSQL 16 Debian tag or repository digest')
    return value


def runtime_image_identity(value):
    if not isinstance(value, str) or not re.fullmatch(r'(?:sha256:)?[a-f0-9]{64}', value):
        raise ValueError('Invalid observed OCI runtime image identity')
    return value.removeprefix('sha256:')


def recovery_apparmor_evidence(label):
    plain = 'uten-dr-recovery (enforce)'
    stacked = {'uten-dr-recovery//&crun (enforce)', 'crun//&uten-dr-recovery (enforce)',
               'uten-dr-recovery//&crun (mixed)', 'crun//&uten-dr-recovery (mixed)'}
    if label != plain and label not in stacked:raise ValueError('Unknown recovery AppArmor label')
    loaded = set(APPARMOR_PROFILES_PATH.read_text().splitlines())
    if plain not in loaded:raise ValueError('The recovery profile itself is not enforcing in the host kernel')
    if label in stacked and 'crun (unconfined)' not in loaded:
        raise ValueError('The exact documented crun stack is not present in the host kernel')
    info = APPARMOR_PROFILE_PATH.lstat()
    expected = Path(__file__).with_name('uten-dr-recovery.apparmor').read_bytes()
    if (APPARMOR_PROFILE_PATH.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_uid != 0
            or info.st_mode & 0o022 or APPARMOR_PROFILE_PATH.read_bytes() != expected):
        raise ValueError('Installed dedicated AppArmor policy differs from this reviewed source')
    return {'actualLabel': label, 'recoveryProfileMode': 'enforce',
            'crunProfileMode': 'unconfined' if label in stacked else None,
            'profileSourceSha256': hashlib.sha256(expected).hexdigest()}


def memory_available():
    values = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemAvailable:'):
            fields = line.split()
            if len(fields) != 3 or fields[2] != 'kB':raise ValueError('Unknown host memory units')
            values['host'] = int(fields[1]) * 1024
    if 'host' not in values:raise ValueError('Host available memory is unavailable')
    entries = [line.split(':', 2)[2] for line in Path('/proc/self/cgroup').read_text().splitlines()
               if line.startswith('0::')]
    if len(entries) != 1 or '..' in Path(entries[0]).parts:
        raise ValueError('Large recovery requires an observable unified memory cgroup')
    parent = Path('/sys/fs/cgroup')
    current = parent / entries[0].lstrip('/')
    observed = False
    while True:
        maximum, usage = current / 'memory.max', current / 'memory.current'
        if maximum.exists():
            observed = True
            raw = maximum.read_text().strip()
            if raw != 'max':values[str(current)] = max(0, int(raw) - int(usage.read_text().strip()))
        if current == parent:break
        current = current.parent
        if not current.is_relative_to(parent):raise ValueError('Unobservable memory cgroup ancestry')
    if not observed:raise ValueError('Memory controller ancestry is not observable')
    return min(values.values())


def resource_profile(name='small'):
    if name not in RESOURCE_PROFILES:raise ValueError('Unknown fixed recovery resource profile')
    profile = dict(RESOURCE_PROFILES[name], name=name)
    if name == 'large-memory':
        available = memory_available()
        if available < profile['minimumAvailableBytes']:
            raise ValueError('Insufficient host or parent-cgroup memory for large isolated recovery')
        profile['observedAvailableBytes'] = available
    return profile


def configuration_audit(environment):
    """Audit recovered configuration values in RAM; return names/outcomes only.

    Core checks mirror RuntimeSecretPolicy. Unknown empty secret-looking fields
    fail review instead of assuming that an external integration is disabled.
    No API request is made by this local material/inventory check.
    """
    def strong(value, minimum=32):
        if not isinstance(value, str) or len(value.encode()) < minimum or len(set(value)) < 8:
            return False
        normalized = re.sub(r'[-_\s]', '', value.lower())
        if (any(part in normalized for part in ('replace', 'changeme', 'placeholder', 'yourpassword',
                'yoursecret', 'yourkey', 'example', '${')) or ('<' in normalized and '>' in normalized)
                or any(char.isspace() or ord(char) < 32 or ord(char) == 127 for char in value)):
            return False
        return not any(len(value) >= period * 2 and all(value[i] == value[i % period]
                       for i in range(period, len(value))) for period in range(1, 9))
    required = {'UTEN_JWT_SECRET': environment.get('UTEN_JWT_SECRET'),
                'UTEN_PGP_MASTER_KEY': environment.get('UTEN_PGP_MASTER_KEY') or environment.get('UTEN_CRYPTO_PGPMASTERKEY'),
                'UTEN_HMAC_KEY': environment.get('UTEN_HMAC_KEY') or environment.get('UTEN_CRYPTO_HMACKEY'),
                'UTEN_DB_PASSWORD': environment.get('UTEN_DB_PASSWORD')}
    invalid = [name for name, value in required.items() if not strong(value, 16 if name == 'UTEN_DB_PASSWORD' else 32)]
    if environment.get('UTEN_PROFILE') not in {'prod', 'internal-test'}:invalid.append('UTEN_PROFILE')
    if environment.get('UTEN_DB_USER') != 'uten':invalid.append('UTEN_DB_USER')
    if environment.get('UTEN_DB_URL') not in {'jdbc:postgresql://127.0.0.1:5432/uten_imp',
            'jdbc:postgresql://127.0.0.1:5432/uten_imp?currentSchema=public'}:invalid.append('UTEN_DB_URL')
    inventory = []
    for name, value in sorted(environment.items()):
        if name in required or not re.search(r'PASSWORD|SECRET|(?:^|_)TOKEN(?:_|$)|MASTER_?KEY|HMAC_?KEY|API_?KEY|PGPLEGACYKEYS', name):
            continue
        if re.search(r'TOKEN_(BUDGET|LIMIT|TTL|COUNT|DURATION)', name):continue
        disabled = name == 'UTEN_WEBSITE_INQUIRY_INGEST_TOKEN' and not value
        valid = disabled or strong(value)
        inventory.append({'name': name, 'state': 'DISABLED_BY_APPLICATION_CONTRACT' if disabled else 'VERIFIED' if valid else 'BLOCKED'})
        if not valid:invalid.append(name)
    return {'format': 'uten-restored-configuration-audit-v1', 'state': 'BLOCKED' if invalid else 'VERIFIED',
            'invalidNames': sorted(set(invalid)), 'requiredSecretNames': sorted(required),
            'externalCredentialInventory': inventory, 'externalApiCallsPerformed': False}


def remaining_budget(deadline):
    if deadline is None:return None
    remaining = deadline - time.monotonic()
    if remaining <= 0:raise TimeoutError('Recovery job budget exceeded')
    return remaining


def phase_timeout(deadline, maximum):
    remaining = remaining_budget(deadline)
    return maximum if remaining is None else min(maximum, remaining)


class DeadlineReader:
    def __init__(self, stream, deadline):
        self.stream, self.deadline = stream, deadline

    def read(self, size=-1):
        remaining_budget(self.deadline)
        return self.stream.read(size)

    def __getattr__(self, key):
        return getattr(self.stream, key)


@contextmanager
def content_stream(value):
    if isinstance(value, (bytes, bytearray)):
        with io.BytesIO(value) as stream:
            yield stream
    elif isinstance(value, Path):
        if value.is_symlink() or not value.is_file():
            raise ValueError('Recovery input must be a regular file')
        with value.open('rb') as stream:
            yield stream
    else:
        raise ValueError('Unsupported recovery input')


def content_bytes(value, maximum=MAX_METADATA_BYTES):
    with content_stream(value) as stream:
        raw = stream.read(maximum + 1)
    if len(raw) > maximum:
        raise ValueError('Recovery metadata exceeds its bounded budget')
    return raw


def content_identity(value, maximum=MAX_PLAIN_BYTES, *, deadline=None):
    size, digest = 0, hashlib.sha256()
    with content_stream(value) as stream:
        while block := stream.read(1024 * 1024):
            remaining_budget(deadline)
            size += len(block)
            if size > maximum:
                raise ValueError('Recovery file exceeds the plaintext budget')
            digest.update(block)
    return size, digest.hexdigest()


def json_lines(value, *, deadline=None):
    total = 0
    with content_stream(value) as stream:
        while line := stream.readline(1024 * 1024 + 1):
            remaining_budget(deadline)
            total += len(line)
            if total > MAX_METADATA_BYTES or len(line) > 1024 * 1024:
                raise ValueError('Recovery inventory exceeds its metadata budget')
            yield json.loads(line)


def private_directory(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:raise ValueError('Recovery spool must be absolute')
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise ValueError('Linked recovery spool is forbidden')
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('Recovery spool is not private')
    return path


def process_start_token(pid):
    try:return Path('/proc').joinpath(str(pid),'stat').read_text().rsplit(')',1)[1].split()[19]
    except FileNotFoundError:return None


def remove_abandoned_recovery_spools(parent):
    """Only stale, inode-bound leases created by this recovery implementation."""
    retained = 0
    for directory in parent.iterdir():
        if not re.fullmatch(r'\.uten-(?:full-)?recovery-[a-z0-9_]+',directory.name):continue
        private_directory(directory)
        marker=directory/'.recovery-lease.json'
        if not marker.exists():
            if any(directory.iterdir()):
                raise ValueError('Unknown nonempty recovery spool prevents new allocation')
            retained += 1
            continue
        if marker.is_symlink():raise ValueError('Linked recovery lease is forbidden')
        info=marker.stat()
        if info.st_uid != os.geteuid() or info.st_mode & 0o077:raise ValueError('Recovery lease is not private')
        lease=json.loads(content_bytes(marker,16384));current=directory.stat()
        if (set(lease)!={'format','pid','start','uid','device','inode'}
                or lease['format']!='uten-private-recovery-spool-v1' or lease['uid']!=os.geteuid()
                or (lease['device'],lease['inode'])!=(current.st_dev,current.st_ino)
                or type(lease['pid']) is not int or lease['pid']<=0
                or not isinstance(lease['start'],str) or not lease['start'].isdigit()):
            raise ValueError('Recovery lease identity is invalid')
        if process_start_token(lease['pid'])==lease['start']:
            retained += 1
            continue
        shutil.rmtree(directory)
    return retained


@contextmanager
def recovery_workspace(parent, *, required_bytes=0, prefix='.uten-recovery-'):
    parent=private_directory(parent)
    if prefix not in ('.uten-recovery-','.uten-full-recovery-'):raise ValueError('Invalid recovery namespace')
    temporary = None
    # Lock the existing directory itself, leaving no persistent lock file. The
    # count, cleanup, mkdir and lease publication form one bounded allocation.
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:fcntl.flock(parent_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Recovery spool allocation is already in progress') from None
        if remove_abandoned_recovery_spools(parent) >= MAX_RECOVERY_WORKSPACES:
            raise ValueError('Recovery workspace concurrency limit reached')
        if required_bytes<0 or shutil.disk_usage(parent).free < required_bytes+1024**3:
            raise ValueError('Recovery spool free-space reserve would be crossed')
        temporary = tempfile.TemporaryDirectory(prefix=prefix,dir=parent)
        root=Path(temporary.name);root.chmod(0o700);info=root.stat()
        marker=root/'.recovery-lease.json'
        fd=os.open(marker,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'w',encoding='utf-8') as output:
            json.dump({'format':'uten-private-recovery-spool-v1','pid':os.getpid(),
                'start':process_start_token(os.getpid()),'uid':os.geteuid(),
                'device':info.st_dev,'inode':info.st_ino},output)
            output.flush();os.fsync(output.fileno())
    except BaseException:
        if temporary is not None:temporary.cleanup()
        raise
    finally:
        os.close(parent_fd)
    with temporary:
        yield root


def extract_verified_tar(path, directory, *, deadline=None):
    """Called only after the sealed inventory and GPG authentication are verified."""
    directory = private_directory(directory)
    if any(directory.iterdir()):raise ValueError('Recovery target must be empty')
    result, total = {}, 0
    with tarfile.open(path, mode='r|') as archive:
        for member in archive:
            remaining_budget(deadline)
            name = member.name;relative = PurePosixPath(name)
            if (member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) or name in result
                    or relative.is_absolute() or str(relative) != name or '..' in relative.parts
                    or '\\' in name or ':' in name or len(name.encode('utf-8')) > 4096
                    or any(ord(char) < 32 or ord(char) == 127 for char in name)
                    or any(part.endswith(('.', ' ')) for part in relative.parts)
                    or not 0 <= member.size <= MAX_PLAIN_BYTES or len(result) >= 201024):
                raise ValueError('Invalid verified plaintext tar member')
            total += member.size
            # The export inventory is metadata in addition to the paired payload.
            if total > MAX_PLAIN_BYTES + MAX_METADATA_BYTES:
                raise ValueError('Verified plaintext tar exceeds its spool budget')
            target = directory
            for part in relative.parts[:-1]:
                target = target / part
                if not target.exists():target.mkdir(mode=0o700)
                private_directory(target)
            target = target / relative.name
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            size = 0
            with os.fdopen(fd, 'wb') as output, archive.extractfile(member) as original:
                while block := original.read(1024 * 1024):
                    remaining_budget(deadline)
                    size += len(block)
                    if size > member.size:raise ValueError('Plaintext tar member grew')
                    output.write(block)
            if size != member.size:raise ValueError('Plaintext tar member is truncated')
            result[name] = target
    return result


def run_isolated_command(arguments, data=None, timeout=180, spool_directory=None, *, deadline=None):
    """Stream file input; cap private command output before it can fill a volume."""
    maximum = 2 * 1024**2
    timeout = phase_timeout(deadline, timeout)
    def output_limit():
        inherited = resource.getrlimit(resource.RLIMIT_FSIZE)[1]
        limit = maximum + 1 if inherited == resource.RLIM_INFINITY else min(maximum + 1,inherited)
        resource.setrlimit(resource.RLIMIT_FSIZE, (limit, limit))
    with tempfile.TemporaryFile(dir=spool_directory) as output:
        if isinstance(data, Path):
            with content_stream(data) as stream:
                result = subprocess.run(arguments, stdin=stream, stdout=output,
                    stderr=subprocess.DEVNULL, timeout=timeout, preexec_fn=output_limit)
        else:
            result = subprocess.run(arguments, input=data, stdout=output,
                stderr=subprocess.DEVNULL, timeout=timeout, preexec_fn=output_limit)
        if result.returncode:
            raise RuntimeError('Isolated restore command failed')
        output.seek(0);raw = output.read(maximum + 1)
        if len(raw) > maximum:raise ValueError('Isolated query output exceeds its bounded budget')
        return raw


def sql_literal(value):
    return "'" + value.replace("'", "''") + "'"


def parse_env(raw):
    result = {}
    for line in raw.decode("utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        tokens = shlex.split(line, comments=False)
        if len(tokens) != 1 or "=" not in tokens[0]:
            raise ValueError("Recovery environment syntax is unsupported")
        key, value = tokens[0].split("=", 1)
        if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) or key in result:
            raise ValueError("Recovery environment key is invalid")
        result[key] = value
    return result


def validate_media(contents, prefix, manifest, *, deadline=None):
    objects = list(json_lines(contents[prefix + "objects.jsonl"], deadline=deadline))
    references = list(json_lines(contents[prefix + "references.jsonl"], deadline=deadline))
    if content_identity(contents[prefix + "objects.jsonl"],deadline=deadline)[1] != manifest["objects_manifest_sha256"]:
        raise ValueError("Object inventory binding failed")
    if content_identity(contents[prefix + "references.jsonl"],deadline=deadline)[1] != manifest["references_manifest_sha256"]:
        raise ValueError("Reference inventory binding failed")
    identities = lambda values: {tuple(row.get(k) for k in ("storage_provider", "storage_key", "storage_version",
        "sha256", "size_bytes")) for row in values}
    if identities(objects) != identities(references):
        raise ValueError("Logical original references are incomplete")
    for row in objects:
        folder = "media/local/final/" if row["storage_provider"] == "local" else "media/final/"
        value = contents[prefix + folder + row["relative_path"]]
        stored_size, stored_digest = content_identity(value,deadline=deadline)
        if stored_digest != row["storage_sha256"] or stored_size != row["stored_size_bytes"]:
            raise ValueError("Stored original binding failed")
        original_size, original_digest = 0, hashlib.sha256()
        with content_stream(value) as stream:
            decoded = stream
            expected = None
            if row["storage_provider"] == "internal":
                header = stream.read(57)
                if len(header) != 57:raise ValueError('Internal original header is truncated')
                magic, codec, declared_size, encoded_size, expected = struct.unpack('>8sBqq32s', header)
                if (magic != b'UTENINT\x01' or codec not in (0, 1) or encoded_size != stored_size - 57
                        or not 0 <= declared_size <= MAX_PLAIN_BYTES):
                    raise ValueError('Internal original envelope is invalid')
                if codec:decoded = gzip.GzipFile(fileobj=stream)
            try:
                while block := decoded.read(1024 * 1024):
                    remaining_budget(deadline)
                    original_size += len(block)
                    if original_size > row['size_bytes'] or original_size > MAX_PLAIN_BYTES:
                        raise ValueError('Decoded original exceeds its bounded size')
                    original_digest.update(block)
            finally:
                if decoded is not stream:decoded.close()
        if expected is not None and (original_size != declared_size or original_digest.digest() != expected):
            raise ValueError('Decoded original binding failed')
        if original_size != row["size_bytes"] or original_digest.hexdigest() != row["sha256"]:
            raise ValueError("Original plaintext binding failed")
    return {"mediaObjectsVerified": len(objects), "logicalReferencesVerified": len(references)}


OWNER_LABEL = 'org.utenelec.dr.verifier-owner'


def remove_owned_clone(docker, name, *, primary_error=False):
    """Never mask the restore failure; never report success with a live clone."""
    if not re.fullmatch(r'uten-drill-[a-f0-9]{12}', name):raise ValueError('Unknown owned clone identity')
    try:
        result = subprocess.run([str(docker), 'rm', '--force', name], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=30)
        removed = result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):removed = False
    if not removed:
        SAFE_COUNTS['ownedContainerCleanupFailed'] = 1
        if not primary_error:raise RuntimeError('Owned isolated container cleanup failed')
    return removed


def cleanup_owned_containers(docker, owner, spool_directory, *, require_idle=True, runtime='docker'):
    """Recover only this root instance's labeled, isolated, no-longer-live clones."""
    if str(uuid.UUID(owner)) != owner:raise ValueError('Invalid verifier container owner')
    identifiers = run_isolated_command([str(docker), 'ps', '--all', '--quiet', '--filter',
        'label=' + OWNER_LABEL + '=' + owner], timeout=30, spool_directory=spool_directory).decode().split()
    if len(identifiers) > 4:raise ValueError('Owned recovery-container bound requires review')
    removed = active = 0
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    for identifier in identifiers:
        if not re.fullmatch(r'[a-f0-9]{12,64}', identifier):raise ValueError('Unknown recovery container identity')
        info = json.loads(run_isolated_command([str(docker), 'inspect', identifier], timeout=30,
                                               spool_directory=spool_directory))[0]
        name = info.get('Name', '').removeprefix('/')
        view = isolation_view(info, name, runtime)
        host = view.get('HostConfig', {})
        if (not re.fullmatch(r'uten-drill-[a-f0-9]{12}', name) or view.get('Name') != '/' + name
                or view.get('Config', {}).get('User') != '999:999' or host.get('NetworkMode') != 'none'
                or host.get('ReadonlyRootfs') is not True or host.get('Privileged')
                or host.get('Binds') or host.get('Mounts') or host.get('VolumesFrom') or host.get('Devices')
                or host.get('PidMode') == 'host' or any(row.get('Type') != 'tmpfs' for row in view.get('Mounts', []))):
            raise ValueError('Unknown or nonisolated labeled container requires manual review')
        labels = info.get('Config', {}).get('Labels', {})
        pid, start = labels.get(OWNER_LABEL + '.pid', ''), labels.get(OWNER_LABEL + '.start', '')
        if (labels.get(OWNER_LABEL) != owner or not pid.isdigit() or int(pid) <= 0
                or not start.isdigit()):raise ValueError('Owned recovery process binding differs')
        alive = labels.get(OWNER_LABEL + '.boot') == boot and process_start_token(int(pid)) == start
        if alive:
            active += 1
            if require_idle:raise ValueError('A live owned recovery process still holds its clone')
            continue
        run_isolated_command([str(docker), 'rm', '--force', identifier], timeout=30, spool_directory=spool_directory)
        removed += 1
    return {'removedStaleOwnedContainers': removed, 'activeOwnedContainers': active}


@contextmanager
def recovery_admission(docker, restore_profile, candidate_options=None, spool_directory=None, runtime='docker'):
    owner = (candidate_options or {}).get('verification_owner_id')
    descriptor = None
    try:
        if restore_profile == 'large-memory' or owner:
            if os.geteuid() != 0:raise ValueError('Large unattended recovery requires its root-owned runtime')
            admission = Path('/run/uten-imp-dr-recovery')
            admission.mkdir(mode=0o700, exist_ok=True)
            private_directory(admission)
            lock_path = admission / 'large-recovery.lock'
            descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            info = os.fstat(descriptor)
            if info.st_uid != 0 or info.st_mode & 0o077:raise ValueError('Large recovery admission lock is unsafe')
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if owner:cleanup_owned_containers(docker, owner, spool_directory, runtime=runtime)
        yield
    finally:
        if descriptor is not None:os.close(descriptor)


def container_run_arguments(name, restore_profile, owner=None, image=DEFAULT_POSTGRES_IMAGE, runtime='docker'):
    if not re.fullmatch(r'uten-drill-[a-f0-9]{12}', name) or restore_profile not in RESOURCE_PROFILES:
        raise ValueError('Unknown isolated container identity/profile')
    if runtime not in {'docker', 'podman'}:raise ValueError('Unknown explicitly selected OCI runtime contract')
    labels = []
    if owner:
        if str(uuid.UUID(owner)) != owner:raise ValueError('Invalid verifier owner identity')
        labels = ['--label', OWNER_LABEL + '=' + owner, '--label', OWNER_LABEL + '.pid=' + str(os.getpid()),
                  '--label', OWNER_LABEL + '.start=' + process_start_token(os.getpid()),
                  '--label', OWNER_LABEL + '.boot=' + Path('/proc/sys/kernel/random/boot_id').read_text().strip()]
    mounts = []
    sizes = [('/var/lib/postgresql/data', RESOURCE_PROFILES[restore_profile]['pgdataBytes']),
             ('/var/run/postgresql', 16 * 1024**2), ('/tmp', 64 * 1024**2)]
    if runtime == 'podman':
        # Podman 4.9 rejects uid/gid in --tmpfs. Its documented type=tmpfs
        # mount + U chowns only a new memory mount to the fixed user 999.
        mounts += ['--read-only-tmpfs=false']
        mounts += ['--security-opt', 'apparmor=uten-dr-recovery']
        for destination, size in (*sizes, ('/dev/shm', 64 * 1024**2)):
            mounts += ['--mount', 'type=tmpfs,destination=' + destination + ',tmpfs-size=' + str(size) + ',tmpfs-mode=0700,U=true']
    else:
        for destination, size in sizes:
            mounts += ['--tmpfs', destination + ':rw,nosuid,nodev,size=' + str(size // 1024**2)
                       + 'm,uid=999,gid=999,mode=0700']
    return ['run', '--pull', 'never', '--detach', '--rm', '--name', name, *labels,
        '--network', 'none', '--read-only', '--user', '999:999', '--cap-drop', 'ALL',
        '--security-opt', 'no-new-privileges', '--memory', '3g' if restore_profile == 'small' else '14g',
        *(['--memory-swap', '14g'] if restore_profile == 'large-memory' else []), '--pids-limit', '100',
        *mounts,
        '--env', 'POSTGRES_HOST_AUTH_METHOD=trust', '--env', 'POSTGRES_DB=drill', official_postgres_image(image),
        '-c', 'listen_addresses=', '-c', 'unix_socket_permissions=0700', '-c', 'shared_buffers=64MB', '-c', 'max_connections=20',
        '-c', 'max_wal_size=256MB', '-c', 'log_statement=none', '-c', 'log_min_error_statement=panic']


def isolation_view(info, name, runtime):
    """Normalize only documented metadata shape; never remove a host mount."""
    if runtime == 'docker':return info
    if runtime != 'podman':raise ValueError('Unknown OCI runtime contract')
    result = json.loads(json.dumps(info))
    if result.get('Name') == name:result['Name'] = '/' + name
    host = result.get('HostConfig', {})
    mounts = host.get('Mounts') or []
    if not isinstance(mounts, list) or any(row.get('Type') != 'tmpfs' for row in mounts):
        raise ValueError('Podman contains a non-memory host-config mount')
    if mounts:host['Mounts'] = []  # Same tmpfs mounts remain in the normalized inventory below.
    known = dict(host.get('Tmpfs') or {})
    for row in result.get('Mounts', []):
        if row.get('Type') != 'tmpfs':raise ValueError('Podman contains a host or persistent mount')
        destination = row.get('Destination')
        if not isinstance(destination, str):raise ValueError('Unknown Podman mount destination')
        known[destination] = ','.join(row.get('Options', []))
    host['Tmpfs'] = known
    return result


def inspected_isolation(command, name, resources, runtime='docker', expected_image=None):
    raw = json.loads(command(['inspect', name]))[0]
    if expected_image is not None and runtime_image_identity(raw.get('Image')) != runtime_image_identity(expected_image):
        raise ValueError('Unreviewed OCI image is rejected before any backup/key enters the clone')
    view = isolation_view(raw, name, runtime)
    status = dict(line.split(':', 1) for line in command(['exec', name, '/bin/cat', '/proc/1/status']).decode().splitlines() if ':' in line)
    if (status.get('Uid', '').split() != ['999'] * 4 or status.get('Gid', '').split() != ['999'] * 4
            or status.get('NoNewPrivs', '').strip() != '1'
            or any(int(status.get(key, '-1').strip(), 16) != 0 for key in ('CapEff', 'CapPrm', 'CapInh', 'CapBnd', 'CapAmb'))):
        raise ValueError('Actual OCI init identity/capability/NNP isolation failed')
    if runtime == 'podman':view['HostConfig']['CapDrop'] = ['ALL']  # Proven by all actual kernel capability sets above.
    if runtime == 'podman':
        label = command(['exec', name, '/bin/cat', '/proc/1/attr/current']).decode().strip()
        view['_verifiedAppArmor'] = recovery_apparmor_evidence(label)
    # The official entrypoint chmods its socket directory to 03775 even when
    # started as 999. Tighten it again before any backup or key enters the clone.
    # GNU chmod's four-digit directory mode preserves an existing setgid bit.
    # Five digits explicitly clear it instead of accepting 2700 as "close enough".
    command(['exec', name, '/bin/chmod', '00700', '/var/run/postgresql'])
    kernel = {}
    if resources['name'] == 'large-memory':
        maximum = command(['exec', name, '/bin/cat', '/sys/fs/cgroup/memory.max']).decode().strip()
        swap = command(['exec', name, '/bin/cat', '/sys/fs/cgroup/memory.swap.max']).decode().strip()
        if not maximum.isdigit() or int(maximum) != resources['memoryBytes'] or swap != '0':
            raise ValueError('Actual container memory/swap controller differs from the fixed profile')
        kernel = {'memoryMaxBytes': int(maximum), 'swapMaxBytes': 0,
                  'runtimeReportedMemorySwap': raw.get('HostConfig', {}).get('MemorySwap')}
        if runtime == 'podman':view['HostConfig']['MemorySwap'] = resources['memoryBytes']
    host = view.get('HostConfig', {})
    if host.get('Memory') != resources['memoryBytes'] or (resources['name'] == 'large-memory' and host.get('MemorySwap') != resources['memoryBytes']):
        raise ValueError('OCI runtime did not enforce the fixed memory/swap profile')
    spec = importlib.util.spec_from_file_location('uten_runtime_isolation', Path(__file__).with_name('clone_integrity_candidate.py'))
    isolation = importlib.util.module_from_spec(spec); spec.loader.exec_module(isolation); isolation.assert_isolated(view, name)
    for destination in ('/var/lib/postgresql/data', '/var/run/postgresql', '/tmp'):
        filesystem = command(['exec', name, '/usr/bin/stat', '-f', '-c', '%T', destination]).decode().strip()
        if filesystem != 'tmpfs':raise ValueError('The effective recovery path is not a private memory filesystem')
        actual = command(['exec', name, '/usr/bin/stat', '-c', '%u:%g:%a', destination]).decode().strip()
        if actual != '999:999:700':raise ValueError('Actual private memory-mount ownership or mode failed')
    capacity = command(['exec', name, '/bin/df', '-k', '/var/lib/postgresql/data']).decode().splitlines()
    if len(capacity) != 2 or int(capacity[1].split()[1]) * 1024 != resources['pgdataBytes']:
        raise ValueError('Actual PGDATA memory filesystem capacity differs from the fixed profile')
    view['_verifiedKernelLimits'] = kernel
    return view


def restore_contents(contents, source_set_id, docker, candidate_options=None, *, spool_directory=None, deadline=None,
                     restore_profile='small', image=DEFAULT_POSTGRES_IMAGE, runtime='docker'):
    with recovery_admission(docker, restore_profile, candidate_options, spool_directory, runtime):
        return _restore_contents(contents, source_set_id, docker, candidate_options,
            spool_directory=spool_directory, deadline=deadline, restore_profile=restore_profile, image=image,runtime=runtime)


def _restore_contents(contents, source_set_id, docker, candidate_options=None, *, spool_directory=None, deadline=None,
                      restore_profile='small', image=DEFAULT_POSTGRES_IMAGE, runtime='docker'):
    """Consume verified bytes or private disk files without buffering the dump."""
    global PHASE, SAFE_COUNTS
    SAFE_COUNTS = {}
    resources = resource_profile(restore_profile)
    started = time.monotonic()
    PHASE = "DATABASE_ARCHIVE_BINDING"
    prefix = "paired/" + source_set_id + "/"
    manifest = json.loads(content_bytes(contents[prefix + "manifest.json"]))
    dump = contents[prefix + "database.dump"]
    with content_stream(dump) as stream:
        magic = stream.read(5)
    if magic != b"PGDMP" or content_identity(dump,deadline=deadline)[1] != manifest["database_dump_sha256"]:
        raise ValueError("PostgreSQL archive binding failed")
    PHASE = "MEDIA_REFERENCE_BINDING"
    media = validate_media(contents, prefix, manifest,deadline=deadline)
    PHASE = "RECOVERY_ENVIRONMENT_PARSING"
    environment = parse_env(content_bytes(contents["recovery/etc/uten-imp/server.env"]))
    current_version = environment.get("UTEN_PGP_KEY_VERSION", "1")
    keyring = {match.group(1): value for key, value in environment.items()
               if (match := re.fullmatch(r"UTEN_CRYPTO_PGPLEGACYKEYS_([A-Za-z0-9_.-]+)", key))}
    keyring[current_version] = environment.get("UTEN_PGP_MASTER_KEY") or environment.get("UTEN_CRYPTO_PGPMASTERKEY", "")
    hmac_key = environment.get("UTEN_HMAC_KEY") or environment.get("UTEN_CRYPTO_HMACKEY", "")
    unversioned = environment.get("UTEN_PGP_UNVERSIONED_KEY_VERSION", "1")
    PHASE = "CORE_KEY_MATERIAL_CHECK"
    if not all(keyring.values()) or not hmac_key:
        raise ValueError("Core recovery key material is missing")
    name = "uten-drill-" + uuid.uuid4().hex[:12]
    common = [str(docker)]
    def command(arguments, data=None, timeout=180):
        # Error output can contain database values: discard it, and bound the
        # deliberate query results independently of the size of the dump.
        return run_isolated_command(common + arguments, data, timeout, spool_directory,deadline=deadline)
    try:
        PHASE = "ISOLATED_CONTAINER_START"
        owner = (candidate_options or {}).get('verification_owner_id')
        command(container_run_arguments(name, restore_profile, owner, image, runtime))
        startup_deadline = time.monotonic() + phase_timeout(deadline,90)
        while time.monotonic() < startup_deadline:
            result = subprocess.run(common + ["exec", name, "pg_isready", "-q", "-U", "postgres", "-d", "drill"],
                                    capture_output=True, timeout=phase_timeout(deadline,10))
            if result.returncode == 0 and command(['exec', name, '/bin/cat', '/proc/1/comm']).decode().strip() == 'postgres':
                break
            time.sleep(.5)
        else:
            raise TimeoutError("Isolated database startup failed")
        expected_image = (candidate_options or {}).get('expected_image_id')
        inspection = inspected_isolation(command, name, resources, runtime, expected_image)
        # The fixed container-local sampler records observed PGDATA high water.
        # No host mounts, business values or unbounded logging are involved.
        sampler = """set -eu
peak=0
while ! test -e /tmp/uten-dr-resource-stop; do
 used=$(df -k /var/lib/postgresql/data | awk 'NR==2 {print $3}')
 test "$used" -le "$peak" || peak=$used
 printf '%s\\n' "$peak" > /tmp/uten-dr-pgdata-peak.tmp
 mv /tmp/uten-dr-pgdata-peak.tmp /tmp/uten-dr-pgdata-peak
 sleep 1
done
"""
        command(['exec', '--detach', name, '/bin/sh', '-c', sampler])
        psql = ["exec", "--interactive", name, "psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
                "-U", "postgres", "-d", "drill"]
        PHASE = "RESTORE_ROLES"
        command(psql, b"CREATE ROLE uten NOLOGIN; CREATE ROLE uten_migrator NOLOGIN; CREATE ROLE uten_repl NOLOGIN;\n")
        PHASE = "ACTUAL_DATABASE_RESTORE"
        command(["exec", "--interactive", name, "pg_restore", "--exit-on-error", "--no-owner", "--no-privileges",
                 "--username", "postgres", "--dbname", "drill"], dump,
                timeout=600 if restore_profile == 'small' else 2400)
        PHASE = "RESTORED_DATABASE_ORIGINAL_REFERENCES"
        references = list(json_lines(contents[prefix + "references.jsonl"],deadline=deadline))
        allowed_tables = {"attachments", "goods_cost_imports", "sales_quote_template_candidates",
            "sales_quote_template_versions", "sales_quote_template_candidate_history", "ai_input_originals"}
        for row in references:
            table = row["source_table"]
            if table not in allowed_tables:
                raise ValueError("Unreviewed original reference producer")
            identifier = row["id"]
            if table == "sales_quote_template_versions":
                template, version = identifier.split(":")
                uuid.UUID(template)
                if not re.fullmatch(r"[1-9][0-9]*", version):raise ValueError("Invalid original version identity")
                predicate = "template_id=" + sql_literal(template) + "::uuid AND version=" + version
            elif table == "sales_quote_template_candidate_history":
                if not re.fullmatch(r"[1-9][0-9]*", identifier):raise ValueError("Invalid original history identity")
                predicate = "id=" + identifier
            else:
                uuid.UUID(identifier)
                column = "job_id" if table in ("sales_quote_template_candidates", "ai_input_originals") else "id"
                predicate = column + "=" + sql_literal(identifier) + "::uuid"
            size, digest = ("size_bytes", "sha256") if table == "attachments" else ("storage_size", "storage_sha256")
            if table == "sales_quote_template_candidate_history":
                size, digest = "(payload->>'storage_size')::bigint", "payload->>'storage_sha256'"
            query = "SELECT json_build_object('storage_provider',storage_provider,'storage_key',storage_key," \
                "'storage_version',storage_version,'size_bytes'," + size + ",'sha256'," + digest + ") FROM public." + table + " WHERE " + predicate + ";"
            raw = command(psql, query.encode()).decode().strip()
            actual = json.loads(raw)
            if any(actual[key] != row[key] for key in ("storage_provider", "storage_key", "storage_version", "size_bytes", "sha256")):
                raise ValueError("Restored database does not bind its original bytes")
        media["restoredDatabaseOriginalBindingsVerified"] = len(references)
        # Private keys/ciphertexts and decrypted values never leave this isolated DB process.
        verify_sql = """
CREATE TEMP TABLE dr_keyring(version text PRIMARY KEY, secret text NOT NULL);
INSERT INTO dr_keyring VALUES KEY_VALUES;
CREATE TEMP TABLE dr_crypto_results(verified bigint, failed bigint, hmac_verified bigint, hmac_failed bigint);
DO $dr$
DECLARE c record; r record; value text; body text; key_version text; secret text; plain text;
 good bigint := 0; bad bigint := 0; hg bigint := 0; hb bigint := 0;
BEGIN
 FOR c IN SELECT table_name,column_name FROM information_schema.columns
   WHERE table_schema='public' AND data_type IN ('text','character varying') AND column_name LIKE '%\\_enc' ESCAPE '\\'
 LOOP
   FOR r IN EXECUTE format('SELECT %I AS cipher FROM public.%I WHERE %I IS NOT NULL AND btrim(%I) <> ''''%s',
     c.column_name,c.table_name,c.column_name,c.column_name,
     CASE WHEN c.table_name='profile_change_requests' THEN ' AND value_encoding <> ''PLAIN''' ELSE '' END)
   LOOP
    value := r.cipher;
    IF value ~ '^[A-Za-z0-9_.-]+:' THEN key_version := split_part(value,':',1); body := substr(value,strpos(value,':')+1);
    ELSE key_version := UNVERSIONED; body := value; END IF;
    SELECT k.secret INTO secret FROM dr_keyring k WHERE k.version=key_version;
    BEGIN
     IF secret IS NULL THEN RAISE EXCEPTION 'Missing version'; END IF;
     plain := pgp_sym_decrypt(decode(body,'base64'),secret); good := good+1;
    EXCEPTION WHEN OTHERS THEN bad := bad+1;
    END;
   END LOOP;
 END LOOP;
 FOR r IN SELECT id_card_enc AS cipher,id_card_hash AS digest FROM employee_sensitive
   WHERE id_card_enc IS NOT NULL AND id_card_hash IS NOT NULL
   UNION ALL SELECT phone_enc,phone_hash FROM employee_sensitive WHERE phone_enc IS NOT NULL AND phone_hash IS NOT NULL
 LOOP
  value := r.cipher;
  IF value ~ '^[A-Za-z0-9_.-]+:' THEN key_version := split_part(value,':',1); body := substr(value,strpos(value,':')+1);
  ELSE key_version := UNVERSIONED; body := value; END IF;
  SELECT k.secret INTO secret FROM dr_keyring k WHERE k.version=key_version;
  BEGIN
   plain := pgp_sym_decrypt(decode(body,'base64'),secret);
   IF encode(hmac(plain,HMAC_KEY,'sha256'),'hex')=r.digest THEN hg:=hg+1; ELSE hb:=hb+1; END IF;
  EXCEPTION WHEN OTHERS THEN hb:=hb+1;
  END;
 END LOOP;
 INSERT INTO dr_crypto_results VALUES(good,bad,hg,hb);
END $dr$;
SELECT json_build_object('tables',(SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'),
 'flywayVersion',(SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1),
 'piiVerified',verified,'piiFailed',failed,'hmacIndexesVerified',hmac_verified,'hmacIndexesFailed',hmac_failed) FROM dr_crypto_results;
"""
        verify_sql = verify_sql.replace("KEY_VALUES", ",".join("(" + sql_literal(key) + "," + sql_literal(value) + ")"
                                                                for key, value in keyring.items()))
        verify_sql = verify_sql.replace("UNVERSIONED", sql_literal(unversioned)).replace("HMAC_KEY", sql_literal(hmac_key))
        PHASE = "PII_AND_HMAC_VALIDATION"
        stats = json.loads(command(psql, verify_sql.encode(), timeout=120).decode().strip().splitlines()[-1])
        SAFE_COUNTS = stats
        if stats["piiFailed"] or stats["piiVerified"] < 1:
            raise ValueError("Restored PGP cryptography verification failed")
        hmac_verified = stats["hmacIndexesFailed"] == 0
        report = {"state": ("ISOLATED_DATABASE_AND_ORIGINALS_RESTORED" if hmac_verified else
                          "ISOLATED_RESTORE_WITH_HISTORICAL_HMAC_GAPS"), "sourceSetId": source_set_id,
            "databaseRestored": True, "attachmentsVerified": True, "corePgpVerified": True,
            "corePgpAndHmacVerified": hmac_verified, "keysVerified": hmac_verified,
            "isolated": True, "sideEffectsDisabled": True,
            "plaintextWrittenOutsideTmpfs": any(isinstance(value, Path) for value in contents.values()),
            "durationSeconds": round(time.monotonic() - started, 3), **media, **stats,
            "knownAncillaryCredentialIssuesCleared": False,
            "reasonCode": "CORE_PGP_HMAC_VERIFIED" if hmac_verified else "HISTORICAL_HMAC_MISMATCH"}
        report['sourceManifestSha256']=content_identity(contents[prefix+'manifest.json'],deadline=deadline)[1]
        report['restoredConfigurationAudit'] = configuration_audit(environment)
        inventory=[]
        for path,value in sorted(contents.items()):
            size,digest=content_identity(value,deadline=deadline);inventory.append({'path':path,'size':size,'sha256':digest})
        report['pairedRecoveryInputBindingSha256']=hashlib.sha256(json.dumps(inventory,sort_keys=True,
            separators=(',',':')).encode()).hexdigest()
        if candidate_options is not None:
            PHASE = "ISOLATED_HISTORICAL_INTEGRITY_CANDIDATE"
            spec=importlib.util.spec_from_file_location('uten_clone_integrity_candidate',
                Path(__file__).with_name('clone_integrity_candidate.py'))
            candidate=importlib.util.module_from_spec(spec);spec.loader.exec_module(candidate)
            inspection=inspected_isolation(command,name,resources,runtime,expected_image)
            def run_sql(query):
                # The optional candidate performs one bounded Node step (30s,
                # plus at most 5s for wslpath) after collecting its SQL inputs.
                # Preserve that remaining budget without changing its module.
                remaining = remaining_budget(deadline)
                if remaining is not None and remaining <= 35:
                    raise TimeoutError('Insufficient integrity-candidate budget')
                timeout = 120 if remaining is None else min(120, remaining - 35)
                return command(psql,query.encode(),timeout=timeout)
            def seal_proposal(raw):
                output=candidate_options['preimage']
                result=subprocess.run(['/usr/bin/gpg','--no-options','--batch','--no-tty','--homedir',
                    str(candidate_options['gpg_home']),'--trust-model','always','--recipient',
                    candidate_options['recipient'],'--compress-algo','zlib','--encrypt'],
                    input=raw,capture_output=True,timeout=phase_timeout(deadline,60))
                if result.returncode or not result.stdout:raise ValueError('Candidate preimage encryption failed')
                with output.open('xb') as stream:
                    stream.write(result.stdout);stream.flush();os.fsync(stream.fileno())
                return hashlib.sha256(result.stdout).hexdigest()
            legacy_hmac = candidate_options.get('legacy_hmac')
            if candidate_options.get('use_verified_restored_current_hmac') is True:
                if not hmac_verified or stats['hmacIndexesVerified'] < 1:
                    raise ValueError('Unattended candidate needs actual current HMAC index verification')
                legacy_hmac = hmac_key
            if not isinstance(legacy_hmac, str) or not legacy_hmac:raise ValueError('Missing candidate HMAC evidence')
            report['integrityCandidate']=candidate.exercise(run_sql,inspection,name,environment,
                legacy_hmac,candidate_options['node'],
                content_identity(contents['recovery/etc/uten-imp/server.env'],deadline=deadline)[1],seal_proposal,
                ai_only=candidate_options.get('ai_only',False))
        clone=json.loads(command(psql,b"SELECT json_build_object('cloneDatabaseSystemIdentifier',"
            b"(pg_control_system()).system_identifier::text,'cloneRestoredLsn',pg_current_wal_lsn()::text);").decode().strip())
        report.update(clone)
        physical = json.loads(command(psql, b"SELECT json_build_object('databaseBytes',pg_database_size(current_database()),"
            b"'serverVersionNum',current_setting('server_version_num')::integer);").decode().strip())
        if not 160000 <= physical['serverVersionNum'] < 170000:raise ValueError('Recovery requires PostgreSQL 16')
        usage = command(['exec', name, 'du', '-sk', '/var/lib/postgresql/data']).decode().split()
        observed = command(['exec', name, '/bin/sh', '-c',
            'touch /tmp/uten-dr-resource-stop; cat /tmp/uten-dr-pgdata-peak']).decode().strip()
        peak = command(['exec', name, '/bin/sh', '-c',
            'if test -r /sys/fs/cgroup/memory.peak; then cat /sys/fs/cgroup/memory.peak; else printf unavailable; fi']).decode().strip()
        if restore_profile == 'large-memory' and not peak.isdigit():
            raise ValueError('Large recovery requires observable container memory high water')
        allocated = int(usage[0]) * 1024
        report['recoveryResources'] = {**resources, **physical, 'pgdataAllocatedBytes': allocated,
            'observedPgdataPeakBytes': max(allocated, int(observed) * 1024), 'pgdataSamplingIntervalSeconds': 1,
            'containerMemoryPeakBytes': int(peak) if peak.isdigit() else None,
            'containerImageId': inspection.get('Image'), 'containerImageName': official_postgres_image(image),
            'runtime': runtime, 'verifiedKernelLimits': inspection['_verifiedKernelLimits'],
            'appArmorEvidence': inspection.get('_verifiedAppArmor'),
            'containerNetwork': 'none', 'hostMounts': False}
        report['cloneIdentityRepresentsSourceWalPosition']=False
        return report
    finally:
        removed = remove_owned_clone(docker, name, primary_error=sys.exc_info()[0] is not None)
        if removed and 'report' in locals():report['ownedContainerRemoved'] = True


def main():
    global PHASE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--source-receipt", required=True, type=Path)
    parser.add_argument("--gpg-home", required=True, type=Path)
    parser.add_argument("--docker", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument('--spool-directory', required=True, type=Path,
                        help='Existing private recovery-workstation directory with at least 6GiB available')
    parser.add_argument('--budget-seconds',type=int,default=3600,
                        help='One total 60..3600 second recovery budget with 30 seconds reserved for cleanup')
    parser.add_argument('--restore-profile',choices=tuple(RESOURCE_PROFILES),default='small')
    parser.add_argument('--image',type=official_postgres_image,default=DEFAULT_POSTGRES_IMAGE)
    parser.add_argument('--runtime',choices=('docker','podman'),default='docker')
    args = parser.parse_args()
    if not 60 <= args.budget_seconds <= 3600:raise ValueError('Recovery budget must be 60..3600 seconds')
    deadline = time.monotonic() + args.budget_seconds - 30
    os.umask(0o077)
    secret = sys.stdin.buffer.read(256).strip()
    PHASE = "CIPHERTEXT_BINDING"
    source_receipt = json.loads(args.source_receipt.read_text())
    cipher_size, cipher_digest = content_identity(args.archive, MAX_ARCHIVE_CIPHER_BYTES,deadline=deadline)
    if cipher_digest != source_receipt["ciphertextSha256"] or cipher_size != source_receipt['ciphertextBytes']:
        raise ValueError("Ciphertext receipt mismatch")
    PHASE = "AUTHENTICATED_DECRYPTION"
    parent = private_directory(args.spool_directory)
    with recovery_workspace(parent,required_bytes=MAX_ARCHIVE_CIPHER_BYTES+MAX_PLAIN_BYTES,
                            prefix='.uten-full-recovery-') as workspace:
        plaintext_tar = workspace / 'authenticated.tar'
        key_fd = os.memfd_create("uten-drill-passphrase", os.MFD_CLOEXEC)
        try:
            os.write(key_fd, secret + b"\n"); os.lseek(key_fd, 0, os.SEEK_SET)
            with plaintext_tar.open('xb') as output:
                result = subprocess.run(["/usr/bin/gpg", "--no-options", "--batch", "--no-tty", "--homedir", str(args.gpg_home),
                    "--pinentry-mode", "loopback", "--passphrase-fd", str(key_fd), '--max-output', str(MAX_ARCHIVE_CIPHER_BYTES),
                    "--decrypt", str(args.archive)], stdout=output, stderr=subprocess.DEVNULL,
                    pass_fds=(key_fd,), timeout=phase_timeout(deadline,120))
            if result.returncode or plaintext_tar.stat().st_size > MAX_ARCHIVE_CIPHER_BYTES:
                raise ValueError("Authenticated archive decryption failed")
        finally:
            os.close(key_fd)
        helper = Path(__file__).resolve().parents[1] / "postgres/backup/sealed_paired_export.py"
        spec = importlib.util.spec_from_file_location("uten_drill_sealed_verify", helper)
        sealed = importlib.util.module_from_spec(spec); spec.loader.exec_module(sealed)
        PHASE = "DECRYPTED_INVENTORY_VALIDATION"
        with plaintext_tar.open('rb') as stream:sealed.verify_plaintext_tar(DeadlineReader(stream,deadline), source_receipt)
        plain_root = workspace / 'plain';plain_root.mkdir(mode=0o700)
        contents = extract_verified_tar(plaintext_tar, plain_root,deadline=deadline)
        report = restore_contents(contents, source_receipt["sourceSetId"], args.docker,
                                  spool_directory=workspace,deadline=deadline,restore_profile=args.restore_profile,image=args.image,runtime=args.runtime)
        report['restoreInputMode'] = 'PRIVATE_DISK'
        report.update(recoveryBudgetSeconds=args.budget_seconds,cleanupReservedSeconds=30)
    report["ciphertextSha256"] = source_receipt["ciphertextSha256"]
    with args.report.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2); stream.write("\n")
    print(json.dumps(report))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"state": "RESTORE_DRILL_FAILED", "errorType": type(error).__name__,
                          "phase": PHASE, "counts": SAFE_COUNTS}), file=sys.stderr)
        raise SystemExit(1)
