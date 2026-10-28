#!/usr/bin/env python3
"""Fixed local operations protocol. No HTTP listener, arbitrary command or caller path.

The unprivileged ERP authenticates users; SO_PEERCRED authenticates that ERP here.
Update jobs belong to a separate systemd unit and survive ERP restarts. Only explicit
UPDATE_START contacts OSS. STATUS and all page polling read local state only.
"""
from __future__ import annotations

import base64
import contextlib
import datetime as dt
import errno
import fcntl
import grp
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import signal
import shlex
import socket
import socketserver
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from zoneinfo import ZoneInfo

STATE = Path('/var/lib/uten-imp-operations')
PUBLIC_STATE = Path('/var/lib/uten-imp-public')
UPDATE_NOTICE_SECONDS = 10 * 60
SOCKET = Path('/run/uten-imp-operations/control.sock')
CONFIG = Path('/etc/uten-imp-updater/source.env')
UPDATER = '/usr/local/sbin/uten-imp-updater'
UPDATER_LOCK = Path('/run/uten-imp-updater/updater.lock')
SERVICE = 'uten-imp-update-job.service'
BACKUP = '/usr/local/lib/uten-imp/paired_internal_backup.py'
BACKUP_CONFIG = '/etc/uten-imp/paired-internal-backup.json'
OPERATIONS_CONFIG = Path('/etc/uten-imp/operations.json')
MIGRATOR_CONFIG = Path('/etc/uten-imp/migrator.env')
PG_SOCKET_DIRECTORY = '/var/run/postgresql'
ACTIVATION_TIMEOUT_SECONDS = 45 * 60
MIGRATOR_DATABASE = 'uten_imp'
MIGRATOR_HOST = '127.0.0.1'
MIGRATOR_PORT = 5432
MIGRATOR_USER = 'uten_migrator'
MIGRATOR_PASSWORD_ENV = 'UTEN_MIGRATOR_DB_PASSWORD'
VERSION = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')
PHASES = {'CHECKING', 'DOWNLOADING', 'BACKING_UP', 'NOTIFYING', 'MIGRATING', 'ACTIVATING', 'HEALTH_CHECK', 'DONE'}
TERMINAL = {'SUCCEEDED', 'FAILED', 'RECOVERY_REQUIRED', 'CANCELLED'}
# Public failure text is selected here; subprocess/config text is never public.
# retrySafe permits a new explicit check after the stated remedy, never replaying
# the old update request. Job state and activation boundaries remain authoritative.
FAILURE_CATALOG = {
    'UNKNOWN': ('原因尚未确认', '本次操作未完成，现有信息不足以确认具体原因。', '请保留任务标识联系管理员查看本机诊断；确认原因前不要重复更新。', 'CONTACT_ADMIN', False),
    'HOST_IDENTITY_PERMISSION': ('主机账号切换权限不足', '更新组件无法切换到数据库或应用系统账号，本阶段未通过。', '请管理员核对更新服务的受限身份切换能力；不要关闭安全沙箱或修改业务账号权限。', 'CONTACT_ADMIN', False),
    'HOST_COMPONENT_MISSING': ('主机更新组件不完整', '必需的本机更新程序未找到，操作无法继续。', '请管理员核对已安装的运维组件及程序版本，再重新检查。', 'CONTACT_ADMIN', False),
    'HOST_COMPONENT_PERMISSION': ('主机文件访问被拒绝', '更新组件无法访问必需的受保护文件或目录。', '请管理员核对程序、备份与发布目录的属主和权限，不要放宽为公开可写。', 'CONTACT_ADMIN', False),
    'HOST_CONFIGURATION_INVALID': ('主机配置未通过校验', '更新或迁移配置的格式、权限或可信边界不符合要求。', '请管理员核对本机受保护配置和安装步骤，不要通过关闭校验继续更新。', 'CONTACT_ADMIN', False),
    'SOURCE_NOT_CONFIGURED': ('发布来源尚未配置完成', '发布来源、只读访问凭据或可信签名公钥尚未准备好。', '请超级管理员完成发布来源配置后，显式重新检查版本。', 'CHECK_SOURCE', False),
    'SOURCE_CHANGED': ('运行信息已变化', '发布来源、可用版本或当前运行版本已与本次请求不一致。', '请刷新状态并重新检查版本，核对后再提交新的操作。', 'REFRESH_STATUS', True),
    'BUSY': ('已有运维任务正在执行', '另一个更新或清理任务仍持有执行权，本次没有开始。', '请查看当前任务并等待完成，不要并行或重复提交更新。', 'WAIT_FOR_JOB', False),
    'FORBIDDEN': ('当前操作未获授权', '当前账号或主机调用身份不允许执行此操作。', '请联系有对应权限的管理员；不要借用账号或绕过授权。', 'CONTACT_ADMIN', False),
    'SOURCE_DNS_FAILED': ('无法解析发布来源', '服务器未能解析发布来源的域名。', '请管理员核对发布区域配置和服务器 DNS，恢复后重新检查。', 'CHECK_SOURCE', True),
    'SOURCE_NETWORK_FAILED': ('无法连接发布来源', '服务器与发布来源之间的网络连接未能完成。', '请管理员核对出口网络、代理及区域配置，恢复后重新检查。', 'CHECK_SOURCE', True),
    'SOURCE_TLS_FAILED': ('发布来源安全连接失败', '发布来源的 TLS 连接或证书校验未通过。', '请管理员核对系统时间、可信 CA 与发布源证书；不要跳过证书校验。', 'CHECK_SOURCE', False),
    'SOURCE_FORBIDDEN': ('发布来源拒绝访问', '发布来源拒绝了只读请求，访问凭据、请求签名或读取权限可能不匹配。', '请超级管理员核对只读凭据、区域、对象前缀和读取权限，并由管理员核对服务器时间。', 'CHECK_SOURCE', False),
    'SOURCE_NOT_FOUND': ('发布文件未找到', '发布来源没有返回所需的版本通道或发布文件。', '请管理员核对发布是否完整及对象前缀；修正后重新检查，不要手工跳过缺失文件。', 'CHECK_SOURCE', True),
    'SOURCE_METADATA_INVALID': ('版本通道内容无效', '版本通道返回的内容不符合支持的版本格式或大小限制。', '请发布管理员核对通道文件与对应版本，修正后重新检查。', 'CHECK_SOURCE', False),
    'RELEASE_SIGNATURE_INVALID': ('发布签名验证失败', '发布包未通过已配置可信公钥的签名验证，未被接受。', '请发布管理员核对签名公钥与发布文件；不要跳过验签或临时信任未知密钥。', 'CONTACT_ADMIN', False),
    'RELEASE_CHECKSUM_INVALID': ('发布文件完整性校验失败', '发布文件与签名清单中的校验值不一致。', '请发布管理员核对完整上传与文件内容，确认后重新检查；不要使用未通过校验的暂存文件。', 'CONTACT_ADMIN', False),
    'RELEASE_CONTENT_INVALID': ('发布包内容不符合要求', '发布清单、文件路径或必要内容未通过安全检查。', '请发布管理员重新核对完整发布包，保留任务标识协助定位。', 'CONTACT_ADMIN', False),
    'MIGRATIONS_NOT_FORWARD_ONLY': ('发布迁移不满足向前升级要求', '发布包修改、删除或缺少已使用的数据库迁移。', '请发布管理员提供只追加且与当前库兼容的版本，禁止直接跳过迁移检查。', 'CONTACT_ADMIN', False),
    'INVALID_RUNTIME_BINDING': ('运行环境身份无法确认', '当前数据库与附件存储身份不完整，更新没有获得执行许可。', '请管理员核对当前运行环境及存储信息，再刷新状态重新检查。', 'CONTACT_ADMIN', False),
    'BACKUP_BINDING_MISMATCH': ('备份目标与运行环境不一致', '数据库、附件目录与可信备份或迁移配置未能对应。', '请管理员先核对备份覆盖的数据库、附件和历史目录；不要跳过配套备份。', 'CONTACT_ADMIN', False),
    'HOST_DISK_SPACE': ('主机可用空间不足', '当前操作所需的存储空间不足，无法继续。', '请管理员检查对应磁盘容量及挂载状态，通过受控清理释放空间后重新检查。', 'CONTACT_ADMIN', False),
    'BACKUP_SPACE': ('备份空间不足', '备份磁盘未满足可用空间安全要求。', '请管理员检查备份盘挂载与空间，按保留策略清理；不要删除当前恢复所需的备份。', 'CONTACT_ADMIN', False),
    'BACKUP_REFERENCE_INVALID': ('配套备份引用未通过校验', '备份的数据库与附件引用或发布位置未能形成可信对应。', '请管理员核对数据库和附件备份覆盖范围及本机诊断，修复前不要继续激活。', 'CONTACT_ADMIN', False),
    'BACKUP_INTEGRITY_FAILED': ('配套备份完整性校验失败', '备份内容、校验值或数据库备份目录未通过复核。', '请管理员检查备份完整性与数据库备份可读性；必须形成已验证备份后才能更新。', 'CONTACT_ADMIN', False),
    'BACKUP_FAILED': ('配套备份未能完成', '数据库和附件配套备份没有成功完成，具体原因需要本机诊断确认。', '请管理员保留失败记录并核对备份程序、磁盘及文件权限，不要绕过备份继续更新。', 'CONTACT_ADMIN', False),
    'OPERATION_TIMEOUT': ('操作超过等待时限', '本阶段未在限定时间内完成，执行结果需要按任务状态核对。', '请先刷新任务状态并联系管理员核对网络、资源与本机诊断，不要重复提交更新。', 'REFRESH_STATUS', True),
    'MIGRATION_FAILED': ('数据库迁移未能完成', '数据库迁移阶段未能通过，当前数据状态需要管理员核对。', '请管理员结合任务标识、迁移记录和已验证备份完成恢复检查；不要再次激活或回滚数据库。', 'VERIFY_RECOVERY', False),
    'ACTIVATION_FAILED': ('版本激活未能完成', '版本切换或启动阶段没有完成全部验证。', '请管理员核对当前代码、数据库、备份与进程状态，确认恢复路径后处理。', 'VERIFY_RECOVERY', False),
    'HEALTH_CHECK_FAILED': ('后端健康检查未通过', '更新后的后端未通过连续健康验证。', '请管理员核对启动日志、数据库连接和当前运行版本，完成恢复检查后再操作。', 'VERIFY_RECOVERY', False),
    'DATABASE_CATALOG_MISMATCH': ('数据库迁移记录不一致', '运行数据库的迁移记录与发布包要求不一致。', '请管理员核对完整迁移记录与已验证备份，不要补写成功记录或重复执行迁移。', 'VERIFY_RECOVERY', False),
    'PROCESS_UNSTABLE': ('后端进程未稳定运行', '后端在观察期内退出、重启或未保持同一健康进程。', '请管理员核对服务日志和重启原因，确认恢复状态后处理。', 'VERIFY_RECOVERY', False),
    'WORKER_INTERRUPTED': ('更新任务已中断', '负责本次操作的主机任务已退出或被中断，没有自动重放。', '请管理员结合当前版本、数据库与备份核对结果；不要直接重放旧更新请求。', 'CONTACT_ADMIN', False),
    'WORKER_START_FAILED': ('更新任务无法启动', '主机未能启动独立的更新服务，本次任务没有进入执行。', '请管理员核对运维服务安装、系统服务状态及本机执行权限。', 'CONTACT_ADMIN', False),
    'CURRENT_VERSION_CHANGED': ('当前版本已被其他操作改变', '执行前发现运行版本已变化，本次未停服或迁移。', '请刷新当前状态并重新检查版本，核对后再提交新的操作。', 'REFRESH_STATUS', True),
    'UPDATE_NOTICE_REQUIRED': ('更新预告尚未获得确认', '当前激活没有匹配正在执行的授权任务和完整十分钟预告，未停服或迁移。', '请从服务器运维页面重新检查并发起更新，不要直接重放激活命令。', 'CONTACT_ADMIN', False),
    'CUTOVER_BACKUP_FAILED_RECOVERED': ('最终备份失败，原服务已恢复', '切换前的最终数据库备份未成功；没有执行迁移，原服务已恢复健康。', '请管理员核对最终备份失败原因与备份磁盘，修复后重新检查，不要重放旧任务。', 'CONTACT_ADMIN', False),
    'HOST_HELPER_UNAVAILABLE': ('无法连接主机运维助手', '后端未能与本机运维服务建立可信连接。', '请管理员核对运维助手服务、受保护连接与组件安装状态。', 'CONTACT_ADMIN', False),
    'HOST_RESPONSE_INVALID': ('主机响应未通过安全校验', '主机运维响应不符合当前支持的协议，不能据此确认操作结果。', '请管理员核对后端与主机组件版本并查看本机诊断；不要再次提交尚未确认的更新。', 'REFRESH_STATUS', False),
    'OUTCOME_UNCERTAIN': ('操作结果尚未确认', '请求可能已经被主机接收，当前连接没有返回可确认的结果。', '请使用原任务标识刷新任务或配置状态，不要更换标识重复提交。', 'REFRESH_STATUS', False),
    'RECOVERY_REQUIRED': ('当前更新需要先完成恢复核对', '已有更新在迁移或切换后未完成验证，尚不能确认可安全开始新的操作。', '请管理员结合任务标识和已验证备份完成恢复核对；不要再次更新、激活或回滚数据库。', 'VERIFY_RECOVERY', False),
    'INVALID_REQUEST': ('操作参数未通过校验', '本次参数或预约时间不符合支持的操作要求。', '请核对页面提示和服务器时区，刷新状态后重新确认操作。', 'REFRESH_STATUS', True),
    'AUTOMATIC_UPDATES_ENABLED': ('自动更新尚未停用', '主机仍配置了自动更新任务，当前手动执行条件未满足。', '请管理员完成手动更新组件安装并核对自动任务已停用。', 'CONTACT_ADMIN', False),
}
PUBLIC_OPERATION_CODES = frozenset(FAILURE_CATALOG) | frozenset({
    'UNAVAILABLE', 'TIMEOUT', 'INVALID_RESPONSE', 'CONFLICT', 'REVISION_CONFLICT',
    'VALIDATION_FAILED', 'NOT_FOUND', 'RECOVERY_REQUIRED', 'UNSAFE_HOST_CONFIG',
    'INVALID_STATE', 'SCAN_LIMIT', 'STALE_PREVIEW', 'PROTECTED', 'STALE_CONFIG',
    'REQUEST_CONFLICT', 'RUNTIME_MISMATCH', 'INVALID_HOST_CONFIG', 'INVALID_ENDPOINT',
    'INVALID_BUCKET', 'INVALID_PREFIX', 'INVALID_CREDENTIALS', 'INVALID_PUBLIC_KEY',
    'INVALID_SCHEDULE', 'AMBIGUOUS_SCHEDULE', 'STALE_RELEASE', 'INVALID_JOB_STATE',
    'NOT_DUE', 'INVALID_OPERATION', 'HOST_OPERATION_FAILED',
})


def failure_view(code, phase='CHECKING', *, recovery_required=False,
                 original_service_preserved=True, exit_code=None):
    code = code if isinstance(code, str) and code in FAILURE_CATALOG else 'UNKNOWN'
    phase = phase if isinstance(phase, str) and phase in PHASES else 'CHECKING'
    title, reason, suggestion, action, retry = FAILURE_CATALOG[code]
    recovery = bool(recovery_required or code == 'RECOVERY_REQUIRED')
    if recovery:
        suggestion = '请管理员结合任务标识和已验证备份完成恢复核对；不要再次更新、激活或回滚数据库。'
        if code in {'CURRENT_VERSION_CHANGED', 'CUTOVER_BACKUP_FAILED_RECOVERED'}:
            title = '更新需要恢复核对'
            reason = '本次更新未获得可确认的恢复结果，当前代码、数据库与服务状态需要管理员核对。'
    # These flags are display guidance, never execution authorization.
    preserved = bool(original_service_preserved) and not recovery
    if not preserved and not recovery and code in {'CURRENT_VERSION_CHANGED', 'CUTOVER_BACKUP_FAILED_RECOVERED'}:
        title = '更新状态需要核对'
        reason = '尚未获得可确认的原服务保持或恢复结果，当前代码、数据库与服务状态需要管理员核对。'
    return {'code': code, 'phase': phase, 'title': title, 'reason': reason,
            'suggestion': suggestion, 'nextAction': 'VERIFY_RECOVERY' if recovery else action,
            'retrySafe': bool(retry and not recovery), 'recoveryRequired': recovery,
            'originalServicePreserved': preserved,
            'exitCode': exit_code if code != 'UNKNOWN' and type(exit_code) is int and -255 <= exit_code <= 255 and exit_code != 0 else None}


def classify_failure(error, phase, step=None):
    """Use private diagnostics only to select a fixed public code, never text."""
    if isinstance(error, OperationError):
        if not isinstance(error.code, str):
            return 'UNKNOWN'
        if error.code == 'INVALID_RELEASE' and step in {'STAGE', 'MIGRATION_CATALOG', 'ACTIVATE'}:
            return 'RELEASE_CONTENT_INVALID'
        aliases = {
            'STALE_CONFIG': 'SOURCE_CHANGED', 'STALE_RELEASE': 'SOURCE_CHANGED',
            'RUNTIME_MISMATCH': 'SOURCE_CHANGED', 'REQUEST_CONFLICT': 'SOURCE_CHANGED',
            'INVALID_HOST_CONFIG': 'HOST_CONFIGURATION_INVALID', 'UNSAFE_HOST_CONFIG': 'HOST_CONFIGURATION_INVALID',
            'INVALID_RELEASE': 'SOURCE_METADATA_INVALID', 'BACKUP_FAILED': 'BACKUP_REFERENCE_INVALID',
            'ACTIVATION_TIMEOUT': 'OPERATION_TIMEOUT', 'UNHEALTHY': 'HEALTH_CHECK_FAILED',
            'UNSTABLE_PROCESS': 'PROCESS_UNSTABLE', 'MIGRATION_STATE_MISMATCH': 'DATABASE_CATALOG_MISMATCH',
            'INVALID_ENDPOINT': 'SOURCE_NOT_CONFIGURED', 'INVALID_BUCKET': 'SOURCE_NOT_CONFIGURED',
            'INVALID_PREFIX': 'SOURCE_NOT_CONFIGURED', 'INVALID_CREDENTIALS': 'SOURCE_NOT_CONFIGURED',
            'INVALID_PUBLIC_KEY': 'SOURCE_NOT_CONFIGURED', 'INVALID_SCHEDULE': 'INVALID_REQUEST',
            'AMBIGUOUS_SCHEDULE': 'INVALID_REQUEST', 'INVALID_JOB_STATE': 'SOURCE_CHANGED', 'NOT_DUE': 'INVALID_REQUEST',
            'INVALID_OPERATION': 'INVALID_REQUEST',
        }
        return aliases.get(error.code, error.code if error.code in FAILURE_CATALOG else 'UNKNOWN')
    if isinstance(error, subprocess.TimeoutExpired):
        return 'OPERATION_TIMEOUT'
    if step == 'BACKUP_REFERENCE' and isinstance(error, (OSError, ValueError, KeyError, TypeError)):
        return 'BACKUP_REFERENCE_INVALID'
    if isinstance(error, OSError):
        number = error.errno if type(error.errno) is int else None
        if number == errno.ENOSPC:
            return 'BACKUP_SPACE' if phase == 'BACKING_UP' else 'HOST_DISK_SPACE'
        if number == errno.ENOENT:
            return 'HOST_COMPONENT_MISSING'
        if number in {errno.EACCES, errno.EPERM}:
            return 'HOST_COMPONENT_PERMISSION'
    if isinstance(error, subprocess.CalledProcessError):
        def private_text(value):
            return value.decode('utf-8', errors='replace')[:16384] if isinstance(value, bytes) else value[:16384] if isinstance(value, str) else ''
        private = (private_text(error.stderr) + '\n' + private_text(error.output)).lower()
        if ('runuser: cannot set user id' in private or 'runuser: cannot set groups' in private) and any(
                marker in private for marker in ('operation not permitted', 'permission denied')):
            return 'HOST_IDENTITY_PERMISSION'
        if any(word in private for word in ('no space left on device', 'insufficient free space', 'insufficient reserved free space', 'free-space gate')):
            return 'BACKUP_SPACE' if phase == 'BACKING_UP' else 'HOST_DISK_SPACE'
        if step in {'LATEST', 'STAGE'}:
            if step == 'LATEST' and any(word in private for word in ('版本号非法', 'latest.txt 内容非法', 'release metadata is too large')):
                return 'SOURCE_METADATA_INVALID'
            curl = re.search(r'curl:\s*\((\d{1,3})\)', private)
            status = int(curl.group(1)) if curl else error.returncode if type(error.returncode) is int else None
            if status == 6:
                return 'SOURCE_DNS_FAILED'
            if status in {5, 7, 52, 55, 56}:
                return 'SOURCE_NETWORK_FAILED'
            if status in {35, 51, 58, 60, 77, 83, 90, 91}:
                return 'SOURCE_TLS_FAILED'
            if status == 28:
                return 'OPERATION_TIMEOUT'
            if re.search(r'(?:returned error:\s*|http[^\n]{0,24}\s)403\b', private) or any(
                    word in private for word in ('<code>accessdenied', '<code>signaturedoesnotmatch', '<code>invalidaccesskeyid', '<code>requesttimetoolskewed')):
                return 'SOURCE_FORBIDDEN'
            if re.search(r'(?:returned error:\s*|http[^\n]{0,24}\s)404\b', private) or '<code>nosuchkey' in private:
                return 'SOURCE_NOT_FOUND'
            if '签名验证失败' in private:
                return 'RELEASE_SIGNATURE_INVALID'
            if 'sha256sums 校验失败' in private or 'sha256sum:' in private and 'did not match' in private:
                return 'RELEASE_CHECKSUM_INVALID'
            if 'sha256sums' in private and any(word in private for word in ('格式', '路径', '越界', '绝对')):
                return 'RELEASE_CONTENT_INVALID'
            if error.returncode == 127:
                return 'HOST_COMPONENT_MISSING'
            if error.returncode == 126 or 'permission denied' in private or 'read-only file system' in private:
                return 'HOST_COMPONENT_PERMISSION'
        if phase == 'BACKING_UP':
            if step in {'BACKUP_VERIFY', 'BACKUP_TOC'}:
                return 'BACKUP_INTEGRITY_FAILED'
            if any(word in private for word in ('reference', '引用', 'pending physical-delete', 'media provider')):
                return 'BACKUP_REFERENCE_INVALID'
            return 'BACKUP_FAILED'
    if step == 'MIGRATION_CATALOG':
        return 'RELEASE_CONTENT_INVALID'
    if step == 'HEALTH':
        return 'HEALTH_CHECK_FAILED'
    return 'UNKNOWN'


def job_failure(job, error, *, step=None, recovery_required=None, preserved=None):
    recovery = job.get('state') == 'RECOVERY_REQUIRED' if recovery_required is None else recovery_required
    code = classify_failure(error, job.get('phase', 'CHECKING'), step)
    if preserved is None:
        preserved = not recovery
    return failure_view(code, job.get('phase', 'CHECKING'), recovery_required=recovery,
                        original_service_preserved=preserved,
                        exit_code=error.returncode if isinstance(error, subprocess.CalledProcessError) else getattr(error, 'exit_code', None))


def attach_failure(job, error, *, step=None, preserved=None):
    job['failure'] = job_failure(job, error, step=step, preserved=preserved)
    job['message'] = job['failure']['title'] + '：' + job['failure']['reason']
MESSAGES = {
    'CHECKING': '正在检查发布通道。', 'DOWNLOADING': '正在下载并验证发布签名和文件。',
    'BACKING_UP': '正在创建和核验数据库及上传文件配套备份。',
    'NOTIFYING': '已通知在线用户，请保存工作；十分钟预告结束后才会切换版本。',
    'MIGRATING': '正在执行数据库迁移；请勿关闭服务器。',
    'ACTIVATING': '正在激活新版本，后端会短暂重启。',
    'HEALTH_CHECK': '正在检查后端启动、数据库和健康状态。', 'DONE': '更新已完成。',
}


class OperationError(Exception):
    def __init__(self, code: str, message: str, *, exit_code=None):
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def process_parent(pid: int) -> int:
    # /proc comm can contain spaces and parentheses; split after its final ')'.
    return int(Path('/proc/' + str(pid) + '/stat').read_text().rsplit(') ', 1)[1].split()[1])


def interrupted_state(job):
    return 'FAILED' if job.get('phase') in {'CHECKING', 'DOWNLOADING', 'BACKING_UP', 'NOTIFYING'} else 'RECOVERY_REQUIRED'


def identifier(value) -> str:
    try:
        canonical = str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise OperationError('INVALID_REQUEST', '操作标识无效。') from None
    if canonical != value:
        raise OperationError('INVALID_REQUEST', '操作标识无效。')
    return canonical


def atomic(path: Path, value: bytes, mode: int = 0o600) -> None:
    fd, name = tempfile.mkstemp(prefix='.operations-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            os.fchmod(output.fileno(), mode)
            output.write(value)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_json(path: Path, value: dict) -> None:
    atomic(path, (json.dumps(value, ensure_ascii=False) + '\n').encode())


def read_private(path: Path, limit: int = 65536) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_mode & 0o077 or info.st_size > limit):
            raise OperationError('UNSAFE_HOST_CONFIG', '主机配置权限或内容不安全，请联系服务器管理员。')
        return source.read(limit + 1)


def read_json(path: Path) -> dict:
    value = json.loads(read_private(path))
    if not isinstance(value, dict):
        raise OperationError('INVALID_STATE', '主机操作记录损坏，请联系管理员。')
    return value


@contextlib.contextmanager
def lock(path: Path):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise OperationError('UNSAFE_HOST_CONFIG', '主机锁文件权限不安全。')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise OperationError('BUSY', '服务器正在执行更新或清理，请稍后重试。') from None
        yield
    finally:
        os.close(fd)


def parse_env(raw: bytes) -> dict[str, str]:
    result = {}
    for line in raw.decode('utf-8').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        words = shlex.split(line, comments=True)
        if words and words[0] == 'export':
            words = words[1:]
        if len(words) != 1 or not re.fullmatch(r'[A-Z][A-Z0-9_]*=.*', words[0]):
            raise OperationError('INVALID_HOST_CONFIG', '发布配置须使用静态 KEY=value 格式。')
        key, value = words[0].split('=', 1)
        if key in result or any(c in value for c in ('\n', '\r', '\x00')):
            raise OperationError('INVALID_HOST_CONFIG', '发布配置含重复或无效条目。')
        result[key] = value
    return result


def public_key(value: str) -> str:
    try:
        parts = value.strip().split()
        if len(parts) not in (2, 3) or parts[0] != 'ssh-ed25519':
            raise ValueError()
        blob = base64.b64decode(parts[1], validate=True)
        if blob[:19] != b'\0\0\0\x0bssh-ed25519\0\0\0\x20' or len(blob) != 51:
            raise ValueError()
        return 'ssh-ed25519 ' + parts[1]
    except (ValueError, TypeError, AttributeError):
        raise OperationError('INVALID_PUBLIC_KEY', '请输入有效的 Ed25519 发布签名公钥。') from None


class ReleaseSource:
    def __init__(self, path: Path = CONFIG):
        self.path = path

    def load(self) -> tuple[bytes, dict]:
        try:
            raw = read_private(self.path)
        except FileNotFoundError:
            return b'', {}
        return raw, parse_env(raw)

    def key(self, env: dict) -> str | None:
        path = Path(env.get('UTEN_ALLOWED_SIGNERS', '/etc/uten-imp-updater/allowed_signers'))
        # Only read a root-controlled regular signer file, never execute/source it.
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as source:
                info = os.fstat(source.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                        or info.st_mode & 0o022 or info.st_size > 4096):
                    raise OperationError('UNSAFE_HOST_CONFIG', '发布签名文件权限不安全。')
                raw = source.read(4097)
            lines = [line for line in raw.decode().splitlines() if line and not line.startswith('#')]
            principal = env.get('UTEN_SIGNER_ID', 'uten-imp-release')
            if len(lines) != 1:
                return None
            head, key = lines[0].split(' ', 1)
            return public_key(key) if head == principal else None
        except (FileNotFoundError, ValueError, UnicodeError):
            return None

    def view(self) -> dict:
        raw, env = self.load()
        key = self.key(env)
        key_id = env.get('UTEN_OSS_KEY_ID', '')
        endpoint, bucket = env.get('UTEN_OSS_ENDPOINT', ''), env.get('UTEN_OSS_BUCKET', '')
        prefix = env.get('UTEN_OSS_OBJECT_PREFIX', '')
        return {
            'revision': hashlib.sha256(raw + (key or '').encode()).hexdigest(),
            'endpoint': endpoint, 'bucket': bucket, 'objectPrefix': prefix,
            'accessKeyConfigured': bool(key_id and env.get('UTEN_OSS_KEY_SECRET')),
            'accessKeyIdHint': ('****' + key_id[-4:]) if key_id else '',
            'signingPublicKey': key,
            'signingKeyFingerprint': ('SHA256:' + base64.b64encode(hashlib.sha256(
                base64.b64decode(key.split()[1])).digest()).decode().rstrip('=')) if key else None,
            'sourceUrl': f'https://{bucket}.{endpoint}/' + (prefix + '/' if prefix else '')
                         if bucket and endpoint else None,
        }

    def save(self, payload: dict) -> dict:
        allowed = {'expectedRevision', 'endpoint', 'bucket', 'objectPrefix', 'accessKeyId',
                   'accessKeySecret', 'clearCredentials', 'signingPublicKey'}
        if set(payload) - allowed:
            raise OperationError('INVALID_REQUEST', '配置包含不支持的字段。')
        before = self.view()
        if payload.get('expectedRevision') != before['revision']:
            raise OperationError('STALE_CONFIG', '发布配置已变化，请刷新后重新保存。')
        raw, env = self.load()
        endpoint, bucket, prefix = (payload.get(k) for k in ('endpoint', 'bucket', 'objectPrefix'))
        if not isinstance(endpoint, str) or not re.fullmatch(r'oss-[a-z0-9-]+\.aliyuncs\.com', endpoint):
            raise OperationError('INVALID_ENDPOINT', '填写阿里云 OSS 区域域名，例如 oss-cn-hangzhou.aliyuncs.com。')
        if not isinstance(bucket, str) or not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,61}[a-z0-9]', bucket):
            raise OperationError('INVALID_BUCKET', 'OSS Bucket 名称无效。')
        if not isinstance(prefix, str) or not re.fullmatch(r'(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]*', prefix) or len(prefix) > 256:
            raise OperationError('INVALID_PREFIX', '对象前缀仅允许字母、数字、下划线、连字符和目录分隔符。')
        key_id, secret = payload.get('accessKeyId') or '', payload.get('accessKeySecret') or ''
        if not isinstance(key_id, str) or not isinstance(secret, str):
            raise OperationError('INVALID_CREDENTIALS', '访问凭据格式无效。')
        clear = payload.get('clearCredentials', False)
        if not isinstance(clear, bool) or clear and (key_id or secret):
            raise OperationError('INVALID_CREDENTIALS', '清除凭据与填写新凭据不能同时执行。')
        if key_id and not secret:
            raise OperationError('INVALID_CREDENTIALS', '更换 AccessKey ID 时须同时填写新 Secret。')
        if key_id and not re.fullmatch(r'[A-Za-z0-9]{1,128}', key_id) or secret and not re.fullmatch(r'[A-Za-z0-9/+=]{1,256}', secret):
            raise OperationError('INVALID_CREDENTIALS', '访问凭据格式无效。')
        if clear:
            env.pop('UTEN_OSS_KEY_ID', None)
            env.pop('UTEN_OSS_KEY_SECRET', None)
        else:
            if key_id:
                env['UTEN_OSS_KEY_ID'] = key_id
            if secret:
                if not (key_id or env.get('UTEN_OSS_KEY_ID')):
                    raise OperationError('INVALID_CREDENTIALS', '请同时填写 AccessKey ID。')
                env['UTEN_OSS_KEY_SECRET'] = secret
        env.update(UTEN_OSS_ENDPOINT=endpoint, UTEN_OSS_BUCKET=bucket,
                   UTEN_OSS_OBJECT_PREFIX=prefix.rstrip('/'), UTEN_AUTO_ACTIVATE_CODE_ONLY='0')
        key = public_key(payload['signingPublicKey']) if payload.get('signingPublicKey') else before['signingPublicKey']
        if key is None:
            raise OperationError('INVALID_PUBLIC_KEY', '请配置发布签名公钥。')
        # A single atomic env pointer commits source AND signer together. Retain the
        # old signer so a failed write/crash never invalidates the previous revision.
        signer = self.path.parent / ('uten-imp-source-signers-' + str(uuid.uuid4()))
        atomic(signer, ('uten-imp-release ' + key + '\n').encode())
        env.update(UTEN_ALLOWED_SIGNERS=str(signer), UTEN_SIGNER_ID='uten-imp-release', UTEN_NAMESPACE='uten-imp-release')
        if raw:
            atomic(self.path.parent / ('uten-imp-source-before-' + str(uuid.uuid4()) + '.env'), raw)
        rendered = '# Managed deployment source; credentials are never returned by the ERP API.\n'
        rendered += ''.join(f'{key}={shlex.quote(value)}\n' for key, value in sorted(env.items()))
        atomic(self.path, rendered.encode())
        return self.view()


def current_version(env: dict) -> str | None:
    base = Path(env.get('UTEN_BASE', '/opt/uten-imp'))
    try:
        value = (base / 'active-version.txt').read_text().strip()
        target = (base / 'current').resolve(strict=True)
    except FileNotFoundError:
        return None
    if not VERSION.fullmatch(value) or target != base / 'releases' / value:
        raise OperationError('RUNTIME_MISMATCH', '运行版本记录与实际目录不一致，请联系管理员。')
    return value


def run(args: list[str], timeout: int = 15) -> subprocess.CompletedProcess:
    with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          start_new_session=True,
                          env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'}) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate_group(process)
            raise
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, args, stdout, stderr)
        return subprocess.CompletedProcess(args, 0, stdout, stderr)


def terminate_group(process):
    # Only an unreaped, newly-created session belonging to this worker. Never a
    # process found by name, nor the independently managed application service.
    if process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)


def server_zone():
    path = Path('/etc/localtime')
    try:
        name = str(path.resolve(strict=True).relative_to('/usr/share/zoneinfo'))
    except ValueError:
        name = 'server-local'
    with path.open('rb') as source:
        return ZoneInfo.from_file(source, key=name)


def future_instant(value):
    try:
        parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            raise ValueError()
        seconds = (parsed - dt.datetime.now(dt.timezone.utc)).total_seconds()
        if not UPDATE_NOTICE_SECONDS <= seconds <= 30 * 86400:
            raise ValueError()
        return parsed.astimezone(dt.timezone.utc).isoformat()
    except (ValueError, TypeError, AttributeError):
        raise OperationError('INVALID_SCHEDULE', '预约时间须在十分钟后、三十天内，以便提醒在线用户。') from None


def schedule_preview(payload):
    if set(payload) != {'localDate', 'hour'} or type(payload['hour']) is not int or payload['hour'] not in {2, 3}:
        raise OperationError('INVALID_SCHEDULE', '请选择日期及凌晨 02:00 或 03:00。')
    try:
        if not isinstance(payload['localDate'], str) or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', payload['localDate']):
            raise ValueError()
        date = dt.date.fromisoformat(payload['localDate'])
    except (ValueError, TypeError):
        raise OperationError('INVALID_SCHEDULE', '预约日期无效。') from None
    zone = server_zone()
    local = dt.datetime.combine(date, dt.time(payload['hour']))
    candidates = {}
    for fold in (0, 1):
        zoned = local.replace(tzinfo=zone, fold=fold)
        instant = zoned.astimezone(dt.timezone.utc)
        if instant.astimezone(zone).replace(tzinfo=None) == local:
            candidates[instant] = zoned
    if len(candidates) != 1:
        raise OperationError('AMBIGUOUS_SCHEDULE', '该时间受夏令时影响，请选择另一个时段。')
    instant, zoned = next(iter(candidates.items()))
    return {'scheduledAt': future_instant(instant.isoformat()), 'serverTimeZone': zone.key,
            'displayLocalTime': zoned.isoformat()}


def load_maintenance_recovery():
    name = 'uten_maintenance_recovery'
    loaded = sys.modules.get(name)
    if loaded is None:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name('maintenance_recovery.py'))
        loaded = importlib.util.module_from_spec(spec)
        sys.modules[name] = loaded
        spec.loader.exec_module(loaded)
    return loaded


def load_storage():
    # -I omits cwd/script directory from sys.path; use the installed sibling only.
    if 'uten_operations_storage' in sys.modules:
        return sys.modules['uten_operations_storage']
    spec = importlib.util.spec_from_file_location('uten_operations_storage', Path(__file__).with_name('operations_storage.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Operations:
    def __init__(self, state: Path = STATE, source: ReleaseSource | None = None, runner=run):
        self.state, self.source, self.runner = state, source or ReleaseSource(), runner

    def job(self, job_id=None) -> dict | None:
        if job_id is None:
            try:
                job_id = read_json(self.state / 'active-job.json')['id']
            except FileNotFoundError:
                return None
        return read_json(self.state / ('job-' + identifier(job_id) + '.json'))

    def store_job(self, job: dict):
        write_json(self.state / ('job-' + identifier(job['id']) + '.json'), job)
        self.publish_maintenance(job)

    def recovery_confirmed(self, job: dict) -> bool:
        try:
            receipt = read_json(self.state / ('service-restored-' + identifier(job['id']) + '.json'))
            env = self.source.load()[1]
            version = current_version(env)
            if not isinstance(version, str) or not VERSION.fullmatch(version):
                return False
            base = Path(env.get('UTEN_BASE', '/opt/uten-imp'))
            # This records a completed recovery event. A later ordinary source
            # change, same-version app restart or PostgreSQL restart must not
            # resurrect the old incident and interrupt every active client.
            return (receipt.get('format') == 'uten-service-restored-v1' and receipt.get('jobId') == job['id']
                    and receipt.get('verifiedVersion') == version and receipt.get('health') == 'UP'
                    and receipt.get('jobSha256') == hashlib.sha256(read_private(self.state / ('job-' + job['id'] + '.json'))).hexdigest()
                    and receipt.get('manifestSha256') == hashlib.sha256((base / 'releases' / version / 'SHA256SUMS').read_bytes()).hexdigest())
        except (OSError, ValueError, OperationError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
            return False

    def assert_activation_authorized(self, version: str, expected: str):
        """Lower activator guard: a direct CLI cannot bypass the common window.

        This is deliberately not an RPC or HTTP operation. The shell must be a
        direct child of the live independent worker, not a replay of an old job.
        """
        try:
            main_pid = int(self.runner(['/usr/bin/systemctl', 'show', SERVICE, '--property=MainPID', '--value']).stdout.strip())
            if main_pid <= 0 or process_parent(os.getppid()) != main_pid:
                raise ValueError()
            job = self.job()
            if (not job or job.get('state') != 'RUNNING' or job.get('phase') != 'ACTIVATING'
                    or job.get('mode') not in {'CHECK_AND_UPDATE', 'SCHEDULE_UPDATE'}
                    or job.get('targetVersion') != version or (job.get('currentVersion') or 'none') != expected):
                raise ValueError()
            starts = job.get('noticeStartsAt') or job.get('scheduledAt')
            published = job.get('noticePublishedAt') or (job.get('startedAt') if job.get('mode') == 'SCHEDULE_UPDATE' else None)
            starts_at, published_at = (dt.datetime.fromisoformat(value.replace('Z', '+00:00')) for value in (starts, published))
            if (starts_at.tzinfo is None or published_at.tzinfo is None
                    or (starts_at - published_at).total_seconds() < UPDATE_NOTICE_SECONDS
                    or starts_at > dt.datetime.now(dt.timezone.utc)):
                raise ValueError()
            # JSON and gate must name the same window already exposed to users.
            fd = os.open(PUBLIC_STATE / 'maintenance.json', os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022 or info.st_size > 4096:
                    raise ValueError()
                public = json.loads(stream.read(4097))
            marker = (PUBLIC_STATE / 'updating').lstat()
            if (public.get('state') != 'updating' or public.get('noticeId') != job['id']
                    or public.get('targetVersion') != version or not stat.S_ISREG(marker.st_mode)
                    or marker.st_uid != os.geteuid() or marker.st_mode & 0o022):
                raise ValueError()
        except (OSError, ValueError, TypeError, AttributeError, OperationError, subprocess.SubprocessError):
            raise OperationError('INVALID_JOB_STATE', '激活必须由已完成十分钟预告的服务器运维任务执行；请从运维页面发起，不要直接重放激活命令。') from None

    def publish_maintenance(self, job: dict | None):
        """Allowlisted projection; never expose private jobs, actors, sources or diagnostics."""
        # Serialize the heartbeat and worker, then reread durable state so a stale
        # heartbeat cannot clear the gate after activation has already begun.
        fd = os.open(PUBLIC_STATE / '.maintenance.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise OperationError('UNSAFE_HOST_CONFIG', '维护状态锁权限不安全。')
            fcntl.flock(fd, fcntl.LOCK_EX)
            if job:
                job = self.job(job['id'])
            active = self.job()
            if active and (not job or active.get('startedAt', '') >= job.get('startedAt', '')):
                job = active
            if job is None and (PUBLIC_STATE / 'updating').exists():
                # Missing private evidence never proves recovery after reboot.
                return
            self._publish_maintenance_locked(job)
        finally:
            os.close(fd)

    def _publish_maintenance_locked(self, job: dict | None):
        state, starts_at = 'available', None
        if job and job.get('mode') != 'CHECK_ONLY':
            if job.get('state') == 'RECOVERY_REQUIRED' and not self.recovery_confirmed(job):
                state = 'recovery_required'
            elif job.get('state') == 'RUNNING' and job.get('phase') in {'ACTIVATING', 'MIGRATING', 'HEALTH_CHECK'}:
                state = 'updating'
            elif job.get('state') not in TERMINAL:
                starts_at = job.get('noticeStartsAt') or job.get('scheduledAt')
                if starts_at:
                    state = 'scheduled'
        version = job.get('targetVersion') if job else None
        version = version if isinstance(version, str) and VERSION.fullmatch(version) else None
        value = {'schemaVersion': 1, 'state': state, 'noticeId': job['id'] if job and state != 'available' else None,
                 'serverTime': now(), 'startsAt': starts_at, 'targetVersion': version, 'retryAfterSeconds': 10}
        marker = PUBLIC_STATE / 'updating'
        # Gate first, before activation effects. Clear only after a safe receipt.
        if state in {'updating', 'recovery_required'}:
            atomic(marker, b'updating\n', 0o644)
        atomic(PUBLIC_STATE / 'maintenance.json', (json.dumps(value) + '\n').encode(), 0o644)
        if state in {'available', 'scheduled'}:
            try:
                marker.unlink()
            except FileNotFoundError:
                pass

    def notify_before_activation(self, job: dict):
        # An appointment is advertised when saved. An immediate update grants a
        # full ten minutes after the release and backup have been verified.
        if job.get('mode') == 'SCHEDULE_UPDATE' and job.get('scheduledAt'):
            scheduled = dt.datetime.fromisoformat(job['scheduledAt'].replace('Z', '+00:00'))
            created = dt.datetime.fromisoformat(job['startedAt'].replace('Z', '+00:00'))
            if (scheduled - created).total_seconds() >= UPDATE_NOTICE_SECONDS:
                return
        published = dt.datetime.now(dt.timezone.utc)
        job['noticePublishedAt'] = published.isoformat()
        job['noticeStartsAt'] = (published + dt.timedelta(seconds=UPDATE_NOTICE_SECONDS)).isoformat()
        self.phase(job, 'NOTIFYING')
        deadline = time.monotonic() + UPDATE_NOTICE_SECONDS
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            time.sleep(min(10, remaining))
            self.publish_maintenance(job)

    def no_running_job(self):
        existing = self.observe_job(lock_held=True)
        if existing and existing['state'] not in TERMINAL:
            raise OperationError('BUSY', '已有更新作业正在执行，请查看进度。')
        return existing

    def observe_job(self, lock_held=False):
        job = self.job()
        if job is None or job['state'] in TERMINAL or job['state'] == 'SCHEDULED':
            return job
        # A dead worker must not leave a permanent RUNNING spinner. This is local
        # reconciliation only; it never restarts/replays an update.
        age = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(job.get('dispatchedAt', job['startedAt']))).total_seconds()
        if job['state'] == 'QUEUED' and age < 30:
            return job
        active = self.runner(['/usr/bin/systemctl', 'show', SERVICE, '--property=ActiveState', '--value']).stdout.strip()
        if active in {'active', 'activating', 'deactivating', 'reloading'}:
            return job
        try:
            with contextlib.nullcontext() if lock_held else lock(self.state / 'operations.lock'):
                latest = self.job()
                if latest and latest['id'] == job['id'] and latest['state'] not in TERMINAL:
                    latest.update(state=interrupted_state(latest) if latest['state'] == 'RUNNING' else 'FAILED',
                                  finishedAt=now(), message='更新服务已中断；未自动重试。请管理员检查当前版本、数据库和备份。')
                    attach_failure(latest, OperationError('WORKER_INTERRUPTED', ''))
                    self.store_job(latest)
                    job = latest
        except OperationError as error:
            if error.code != 'BUSY':
                raise
        return job

    def status(self) -> dict:
        view = self.source.view()
        env = self.source.load()[1]
        try:
            timer = self.runner(['/usr/bin/systemctl', 'show', 'uten-imp-updater.timer', '--property=ActiveState', '--value']).stdout.strip()
            enabled = self.runner(['/usr/bin/systemctl', 'show', 'uten-imp-updater.timer', '--property=UnitFileState', '--value']).stdout.strip() in {'enabled', 'enabled-runtime'}
        except subprocess.CalledProcessError:
            # Fresh manual-only installations need not install a retired timer.
            # Only an absent definition AND absent loaded unit prove it is absent;
            # DBus/systemd failures still propagate instead of faking disabled.
            defined = self.runner(['/usr/bin/systemctl', 'list-unit-files', '--type=timer', '--no-legend', '--plain', 'uten-imp-updater.timer']).stdout.strip()
            loaded = self.runner(['/usr/bin/systemctl', 'list-units', '--all', '--type=timer', '--no-legend', '--plain', 'uten-imp-updater.timer']).stdout.strip()
            if defined or loaded:
                raise
            timer, enabled = 'inactive', False
        current = current_version(env)
        try:
            latest = read_json(self.state / 'latest-release.json')
        except FileNotFoundError:
            latest = {}
        valid_latest = latest.get('sourceRevision') == view['revision']
        version = latest.get('version') if valid_latest else None
        available = bool(version and (not current or version_tuple(version) > version_tuple(current)))
        zone = server_zone()
        return {'available': True, 'manualOnly': timer != 'active' and not enabled,
                'timerActive': timer == 'active', 'timerEnabled': enabled,
                'currentVersion': current, 'sourceRevision': view['revision'],
                'latestVersion': version, 'lastCheckedAt': latest.get('checkedAt') if valid_latest else None,
                'updateAvailable': available, 'serverTimeZone': zone.key,
                'serverTime': dt.datetime.now(zone).isoformat(),
                'sourceConfigured': bool(view['accessKeyConfigured'] and view['signingPublicKey']
                                         and view['endpoint'] and view['bucket']), 'latestJob': self.observe_job()}

    def start(self, payload: dict, actor: str, request_id: str) -> dict:
        required = {'mode', 'expectedSourceRevision', 'expectedCurrentVersion'}
        mode = payload.get('mode')
        allowed = required | {'runtimeBinding'} | ({'targetVersion', 'scheduledAt'} if mode == 'SCHEDULE_UPDATE' else {'targetVersion'} if mode == 'CHECK_AND_UPDATE' else set())
        if not required <= set(payload) or set(payload) - allowed or mode not in {'CHECK_ONLY', 'CHECK_AND_UPDATE', 'SCHEDULE_UPDATE'}:
            raise OperationError('INVALID_REQUEST', '更新请求无效。')
        if mode != 'CHECK_ONLY':
            validate_runtime_binding(payload.get('runtimeBinding'))
        def existing_request():
            try:
                old = self.job(request_id)
            except FileNotFoundError:
                return None
            if old is None:
                return None
            def meaning(value):
                result = dict(value)
                binding = result.get('runtimeBinding')
                if isinstance(binding, dict):
                    # This is server-owned evidence, refreshed at dispatch or a
                    # retried HTTP request after a normal PostgreSQL restart.
                    result['runtimeBinding'] = {k: v for k, v in binding.items() if k != 'postmasterStartedAt'}
                return result
            if old['actorId'] != actor or meaning(old['request']) != meaning(payload):
                raise OperationError('REQUEST_CONFLICT', '操作标识已用于其他请求。')
            return old
        # A running worker holds the mutation lock. Reading its atomic durable
        # receipt must still work after a lost ACK, without starting it again.
        old = existing_request()
        if old is not None:
            return old
        with lock(self.state / 'operations.lock'):
            # Recheck under the lock to serialize concurrent first submissions.
            old = existing_request()
            if old is not None:
                return old
            existing = self.no_running_job()
            if existing and existing['state'] == 'RECOVERY_REQUIRED' and not self.recovery_confirmed(existing):
                raise OperationError('RECOVERY_REQUIRED', '上次更新需要先完成恢复核对，未启动新的检查或更新。')
            status = self.status()
            if not status['manualOnly']:
                raise OperationError('AUTOMATIC_UPDATES_ENABLED', '自动更新定时器尚未停用，请先完成手动更新组件安装。')
            if not status['sourceConfigured']:
                raise OperationError('SOURCE_NOT_CONFIGURED', '请由超级管理员先配置发布来源、只读凭据和签名公钥。')
            if (payload['expectedSourceRevision'] != status['sourceRevision']
                    or payload['expectedCurrentVersion'] != status['currentVersion']):
                raise OperationError('STALE_CONFIG', '运行版本或发布配置已变化，请刷新后再更新。')
            target = payload.get('targetVersion')
            if target is not None and (target != status['latestVersion'] or not status['updateAvailable']):
                raise OperationError('STALE_RELEASE', '已检查的可用版本发生变化，请重新检查。')
            scheduled = mode == 'SCHEDULE_UPDATE'
            if scheduled:
                if not target or 'scheduledAt' not in payload:
                    raise OperationError('INVALID_SCHEDULE', '请先检查版本并选择预约时间。')
                canonical = future_instant(payload['scheduledAt'])
                local = dt.datetime.fromisoformat(canonical).astimezone(server_zone())
                if local.hour not in {2, 3} or local.minute or local.second or local.microsecond:
                    raise OperationError('INVALID_SCHEDULE', '请选择服务器当地凌晨 02:00 或 03:00。')
                slot = schedule_preview({'localDate': local.date().isoformat(), 'hour': local.hour})
                if dt.datetime.fromisoformat(slot['scheduledAt']) != dt.datetime.fromisoformat(canonical):
                    raise OperationError('INVALID_SCHEDULE', '预约时间与服务器核对结果不一致。')
            job = {'id': request_id, 'requestId': request_id, 'actorId': actor, 'request': payload,
                   'mode': mode, 'state': 'SCHEDULED' if scheduled else 'QUEUED', 'phase': 'CHECKING',
                   'startedAt': now(), 'finishedAt': None, 'scheduledAt': payload.get('scheduledAt'),
                   'currentVersion': status['currentVersion'], 'targetVersion': None,
                   'message': '预约已保存，到点重新校验授权后执行。' if scheduled else '更新请求已保存，等待服务器执行。',
                   'migrationRequired': None, 'health': None}
            if scheduled:
                job['targetVersion'] = target
                job['displayLocalTime'] = dt.datetime.fromisoformat(payload['scheduledAt'].replace('Z', '+00:00')).astimezone(server_zone()).isoformat()
                job['scheduledTimeZone'] = server_zone().key
            self.store_job(job)
            write_json(self.state / 'active-job.json', {'id': request_id})
            if scheduled:
                return job
            try:
                self.runner(['/usr/bin/systemctl', 'start', '--no-block', SERVICE])
            except (OSError, subprocess.SubprocessError) as error:
                job.update(state='FAILED', finishedAt=now(), message='无法启动更新服务；请联系管理员检查主机组件。')
                attach_failure(job, OperationError('WORKER_START_FAILED', '',
                               exit_code=error.returncode if isinstance(error, subprocess.CalledProcessError) else None))
                self.store_job(job)
            return job

    def dispatch(self, request: dict) -> dict:
        if set(request) != {'operation', 'actorId', 'requestId', 'payload'} or not isinstance(request['payload'], dict):
            raise OperationError('INVALID_REQUEST', '操作请求无效。')
        actor, request_id = identifier(request['actorId']), identifier(request['requestId'])
        operation, payload = request['operation'], request['payload']
        if operation == 'STATUS':
            return self.status()
        if operation == 'CONFIG_READ':
            return self.source.view()
        if operation == 'CONFIG_SAVE':
            with lock(self.state / 'operations.lock'):
                self.no_running_job()
                audit_path = self.state / ('source-change-' + request_id + '.json')
                before = self.source.view()['revision']
                audit = {'actorId': actor, 'requestId': request_id, 'operation': 'SOURCE_CONFIG_SAVE',
                         'startedAt': now(), 'finishedAt': None, 'state': 'STARTED',
                         'beforeRevision': before, 'afterRevision': None,
                         'changedFields': sorted(k for k in payload if k != 'expectedRevision')}
                # No credentials (or full request) ever enter operational receipts.
                try:
                    old = read_json(audit_path)
                except FileNotFoundError:
                    old = None
                if old:
                    raise OperationError('REQUEST_CONFLICT', '配置操作标识已使用，请读取实际配置后再确认。')
                write_json(audit_path, audit)
                try:
                    result = self.source.save(payload)
                    audit.update(state='SUCCEEDED', finishedAt=now(), afterRevision=result['revision'])
                    write_json(audit_path, audit)
                    return result
                except Exception as error:
                    try:
                        observed = self.source.view()['revision']
                    except Exception:
                        observed = None
                    uncertain = observed is None or observed != before
                    audit.update(state='UNKNOWN' if uncertain else 'FAILED', finishedAt=now(), afterRevision=observed)
                    write_json(audit_path, audit)
                    if uncertain or not isinstance(error, OperationError):
                        raise OperationError('OUTCOME_UNCERTAIN', '配置保存结果尚未确认，请重新读取实际配置。') from None
                    raise
        if operation == 'UPDATE_START':
            return self.start(payload, actor, request_id)
        if operation == 'SCHEDULE_PREVIEW':
            return schedule_preview(payload)
        if operation in {'UPDATE_DISPATCH', 'UPDATE_CANCEL'}:
            with lock(self.state / 'operations.lock'):
                job = self.job(payload.get('jobId'))
                if not job or self.job()['id'] != job['id'] or job['state'] != 'SCHEDULED':
                    raise OperationError('INVALID_JOB_STATE', '预约已取消或已开始，请刷新状态。')
                if operation == 'UPDATE_CANCEL':
                    if set(payload) - {'jobId', 'reason'} or payload.get('reason', 'USER_REQUEST') not in {'USER_REQUEST', 'AUTHORIZATION_REVOKED'}:
                        raise OperationError('INVALID_REQUEST', '取消原因无效。')
                    job.update(state='CANCELLED', finishedAt=now(), cancelledBy=actor,
                               message='预约已取消：操作人授权已失效。' if payload.get('reason') == 'AUTHORIZATION_REVOKED' else '预约已取消。')
                else:
                    if set(payload) != {'jobId', 'runtimeBinding'} or actor != job['actorId']:
                        raise OperationError('INVALID_REQUEST', '预约操作人不一致。')
                    if dt.datetime.fromisoformat(job['scheduledAt'].replace('Z', '+00:00')) > dt.datetime.now(dt.timezone.utc):
                        raise OperationError('NOT_DUE', '预约时间尚未到。')
                    late = (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(job['scheduledAt'].replace('Z', '+00:00'))).total_seconds()
                    if late > 15 * 60:
                        job.update(state='CANCELLED', finishedAt=now(), message='服务器错过预约时间超过十五分钟，未执行更新，请重新预约。')
                        self.store_job(job)
                        return job
                    validate_runtime_binding(payload['runtimeBinding'])
                    stable = lambda value: {k: v for k, v in value.items() if k != 'postmasterStartedAt'}
                    if stable(payload['runtimeBinding']) != stable(job['request'].get('runtimeBinding', {})):
                        job.update(state='CANCELLED', finishedAt=now(), message='服务器数据或存储配置已变化，未执行更新，请重新预约。')
                        self.store_job(job)
                        return job
                    job['request']['runtimeBinding'] = payload['runtimeBinding']
                    job.update(state='QUEUED', dispatchedAt=now(), message='预约到期，已重新校验授权，等待执行。')
                self.store_job(job)
                if operation == 'UPDATE_DISPATCH':
                    try:
                        self.runner(['/usr/bin/systemctl', 'start', '--no-block', SERVICE])
                    except (OSError, subprocess.SubprocessError) as error:
                        job.update(state='FAILED', finishedAt=now(), message='无法启动预约更新服务，请联系管理员。')
                        attach_failure(job, OperationError('WORKER_START_FAILED', '',
                                       exit_code=error.returncode if isinstance(error, subprocess.CalledProcessError) else None))
                        self.store_job(job)
                return job
        if operation == 'UPDATE_JOB':
            if payload.get('jobId') is None:
                return self.observe_job()
            latest = self.observe_job()
            return latest if latest and latest['id'] == payload['jobId'] else self.job(payload['jobId'])
        if operation in {'STORAGE_SUMMARY', 'STORAGE_LIST', 'STORAGE_PREVIEW_DELETE', 'STORAGE_DELETE', 'STORAGE_RESULT'}:
            operations_storage = load_storage()
            config = read_json(OPERATIONS_CONFIG)
            context = {'config': config['storage'], 'host_state_dir': self.state,
                       'actor_id': actor, 'request_id': request_id, 'lock_held': False,
                       'active_jobs': [j for j in [self.job()] if j and j['state'] not in TERMINAL]}
            if operation == 'STORAGE_DELETE':
                with lock(self.state / 'operations.lock'):
                    self.no_running_job()
                    # updater's root-only lock also excludes manual CLI activation.
                    with lock(UPDATER_LOCK):
                        context.update(lock_held=True, active_jobs=[])
                        try:
                            return operations_storage.dispatch(operation, payload, context)
                        except operations_storage.StorageError as error:
                            raise OperationError(error.code, str(error)) from None
            try:
                return operations_storage.dispatch(operation, payload, context)
            except operations_storage.StorageError as error:
                raise OperationError(error.code, str(error)) from None
        raise OperationError('INVALID_OPERATION', '不支持此服务器操作。')

    def phase(self, job: dict, phase: str):
        job.update(phase=phase, message=MESSAGES[phase])
        self.store_job(job)

    def worker(self) -> int:
        # Fail closed after an interrupted worker. Never automatically replay a
        # partially executed migration/activation or a queued request after reboot.
        with lock(self.state / 'operations.lock'):
            job = self.job()
            if job is None or job['state'] in TERMINAL:
                return 0
            if job['state'] != 'QUEUED':
                job.update(state=interrupted_state(job), finishedAt=now(),
                           message='上次更新中断，禁止自动重试；请管理员检查数据库和当前版本。')
                attach_failure(job, OperationError('WORKER_INTERRUPTED', ''))
                self.store_job(job)
                return 1
            job.update(state='RUNNING', executionStartedAt=now())
            self.phase(job, 'CHECKING')
            activation_started = False
            step = 'CHECK_PRECONDITIONS'
            try:
                if self.source.view()['revision'] != job['request']['expectedSourceRevision']:
                    raise OperationError('STALE_CONFIG', '发布来源已变化，请重新发起更新。')
                current = current_version(self.source.load()[1])
                if current != job['currentVersion']:
                    raise OperationError('RUNTIME_MISMATCH', '运行版本已变化，请刷新后重新检查。')
                if job['request']['mode'] != 'CHECK_ONLY':
                    step = 'BINDING'
                    self.backup_binding(job['request']['runtimeBinding'])
                step = 'LATEST'
                latest = self.runner([UPDATER, 'latest'], timeout=360).stdout.strip()
                if not VERSION.fullmatch(latest):
                    raise OperationError('INVALID_RELEASE', '发布通道返回了无效版本。')
                write_json(self.state / 'latest-release.json', {'version': latest, 'checkedAt': now(),
                           'sourceRevision': job['request']['expectedSourceRevision']})
                target = job['request'].get('targetVersion', latest)
                job['targetVersion'] = target
                if job['request']['mode'] == 'CHECK_ONLY':
                    available = not current or version_tuple(latest) > version_tuple(current)
                    job.update(state='SUCCEEDED', phase='DONE', finishedAt=now(), health='UNCHANGED',
                               message=f'发现新版本 {latest}，可立即或预约更新。' if available else '当前已是最新版本。')
                    self.store_job(job)
                    return 0
                if current and version_tuple(target) <= version_tuple(current):
                    job.update(state='SUCCEEDED', phase='DONE', finishedAt=now(), health='UNCHANGED',
                               message='当前已是最新版本，无需下载或重启。')
                    self.store_job(job)
                    return 0
                self.phase(job, 'DOWNLOADING')
                step = 'STAGE'
                self.runner([UPDATER, 'stage', target], timeout=3600)
                base = Path(self.source.load()[1].get('UTEN_BASE', '/opt/uten-imp'))
                candidate_jar = base / 'releases' / target / 'server/uten-imp-server.jar'
                if current:
                    step = 'MIGRATION_CATALOG'
                    assert_forward_migrations(base / 'current/server/uten-imp-server.jar', candidate_jar)
                self.phase(job, 'BACKING_UP')
                step = 'BACKUP'
                result = self.runner(['/usr/bin/python3', '-I', BACKUP, '--config', BACKUP_CONFIG], timeout=2400)
                step = 'BACKUP_REFERENCE'
                published = Path(json.loads(result.stdout)['published'])
                # Backup program is root-owned, and must return a published child
                # of its configured root. Verification rereads every stored object.
                backup_config = read_json(Path(BACKUP_CONFIG))
                backup_root = Path(backup_config['backup_root']).resolve(strict=True)
                if published.parent.resolve(strict=True) != backup_root or published.is_symlink():
                    raise OperationError('BACKUP_FAILED', '备份目录与配置不一致，已中止更新。')
                step = 'BACKUP_VERIFY'
                self.runner(['/usr/bin/python3', '-I', BACKUP, '--verify', str(published)], timeout=2400)
                step = 'BACKUP_TOC'
                self.runner(['/usr/bin/pg_restore', '--list', str(published / 'database.dump')], timeout=60)
                job['backupPath'] = str(published)
                env = self.source.load()[1]
                job['migrationRequired'] = migration_digest(candidate_jar) != migration_digest(base / 'current/server/uten-imp-server.jar') if current else True
                step = 'NOTIFYING'
                self.notify_before_activation(job)
                # The warning is a real delay. Recheck source, running version
                # and database/storage binding after it, before stopping writes.
                step = 'CHECK_PRECONDITIONS'
                if self.source.view()['revision'] != job['request']['expectedSourceRevision']:
                    raise OperationError('STALE_CONFIG', '发布来源已变化，未执行停服。')
                if current_version(self.source.load()[1]) != job['currentVersion']:
                    raise OperationError('CURRENT_VERSION_CHANGED', '运行版本已变化，未执行停服。')
                self.backup_binding(job['request']['runtimeBinding'])
                self.phase(job, 'ACTIVATING')
                activation_started = True
                step = 'ACTIVATE'
                self.activate(job, target)
                if current_version(env) != target:
                    raise OperationError('ACTIVATION_FAILED', '激活后的运行版本核对失败。')
                self.phase(job, 'HEALTH_CHECK')
                step = 'DATABASE_CATALOG'
                self.validate_database(env, base / 'releases' / target / 'server/uten-imp-server.jar')
                step = 'HEALTH'
                self.stable_health(env)
                job.update(state='SUCCEEDED', phase='DONE', finishedAt=now(), health='UP', message='更新完成，数据库迁移和后端健康检查通过。')
                job.pop('failure', None)
                self.store_job(job)
                # Cleanup follows the durable successful update receipt, while
                # this worker still owns operations.lock. Cleanup failure must
                # never turn a verified healthy activation into a failed update.
                try:
                    self.prune_successful_update_backups(job)
                except Exception as error:
                    print('Post-update backup cleanup receipt unavailable: ' + type(error).__name__
                          + ' jobId=' + job['id'], file=sys.stderr)
                return 0
            except Exception as error:
                # Details stay private. Never return subprocess output, config,
                # provider XML or exception strings which might contain a secret.
                precondition = isinstance(error, OperationError) and isinstance(error.code, str) and error.code in {
                    'CURRENT_VERSION_CHANGED', 'CUTOVER_BACKUP_FAILED_RECOVERED', 'UPDATE_NOTICE_REQUIRED'}
                job.update(state='RECOVERY_REQUIRED' if activation_started and not precondition else 'FAILED', finishedAt=now())
                attach_failure(job, error, step=step, preserved=not activation_started or precondition)
                self.store_job(job)
                # A copied task ID can be matched to private host diagnostics.
                # Do not log the exception string, argv, stdout or stderr.
                safe_id = job.get('id')
                safe_id = safe_id if isinstance(safe_id, str) and re.fullmatch(r'[0-9a-f-]{36}', safe_id) else 'invalid-id'
                status = getattr(error, 'returncode', getattr(error, 'exit_code', None))
                status = status if type(status) is int and -255 <= status <= 255 else 'unknown'
                print('Server update failed: ' + type(error).__name__ + ' jobId=' + safe_id
                      + ' code=' + job['failure']['code'] + ' phase=' + job['failure']['phase']
                      + ' step=' + step + ' exitCode=' + str(status), file=sys.stderr)
                return 1

    def prune_successful_update_backups(self, job: dict) -> dict:
        """Caller holds operations.lock; never replay an existing cleanup intent."""
        job_id = identifier(job['id'])
        path = self.state / ('post-update-backup-cleanup-' + job_id + '.json')
        try:
            return read_json(path)
        except FileNotFoundError:
            pass
        request_id = str(uuid.uuid5(uuid.UUID(job_id), 'post-update-preactivation-backups'))
        receipt = {'jobId': job_id, 'requestId': request_id, 'kind': 'PREACTIVATION_BACKUPS',
                   'state': 'RUNNING', 'startedAt': now(), 'finishedAt': None}
        # A lost/interrupted invocation retains its original intent and storage
        # request ID. Neither worker restart nor a second call repeats deletion.
        write_json(path, receipt)
        try:
            with lock(UPDATER_LOCK):
                active = self.job()
                if (not active or active['id'] != job_id or active.get('state') != 'SUCCEEDED'
                        or active.get('phase') != 'DONE' or active.get('health') != 'UP'
                        or active.get('mode') not in {'CHECK_AND_UPDATE', 'SCHEDULE_UPDATE'}):
                    raise OperationError('BUSY', '本次健康升级成功记录已变化，未清理备份。')
                target = active.get('targetVersion')
                if (not isinstance(target, str) or not VERSION.fullmatch(target)
                        or current_version(self.source.load()[1]) != target):
                    raise OperationError('CURRENT_VERSION_CHANGED', '运行版本已变化，未清理备份。')
                config = read_json(OPERATIONS_CONFIG)
                context = {'config': config['storage'], 'host_state_dir': self.state,
                           'actor_id': identifier(active['actorId']), 'request_id': request_id,
                           'lock_held': True, 'active_jobs': []}
                result = load_storage().prune_preactivation_backups(context)
                receipt.update(state=result['status'], result=result)
        except Exception as error:
            code = getattr(error, 'code', None)
            code = code if code in PUBLIC_OPERATION_CODES else 'UNKNOWN'
            receipt.update(state='SKIPPED' if code in {'BUSY', 'CURRENT_VERSION_CHANGED'} else 'FAILED',
                           errorCode=code, errorType=type(error).__name__)
        receipt['finishedAt'] = now()
        write_json(path, receipt)
        return receipt

    def activate(self, job: dict, target: str):
        with subprocess.Popen([UPDATER, 'activate', target, '--expected-current', job['currentVersion'] or 'none'], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, start_new_session=True,
                              env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'}) as process:
            deadline, pending = time.monotonic() + ACTIVATION_TIMEOUT_SECONDS, b''
            private_tail = b''
            try:
                with selectors.DefaultSelector() as poller:
                    poller.register(process.stdout, selectors.EVENT_READ)
                    while True:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise OperationError('ACTIVATION_TIMEOUT', '激活作业超过限定时间，请管理员核对数据库和当前服务，禁止盲目重试。')
                        if not poller.select(min(1, remaining)):
                            continue
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk:
                            break
                        pending += chunk
                        while b'\n' in pending:
                            line, pending = pending.split(b'\n', 1)
                            # Private, bounded classifier input only. Never store
                            # or return child output, including provider XML.
                            private_tail = (private_tail + line[-4096:] + b'\n')[-16384:]
                            if line.startswith(b'UTEN_PHASE:'):
                                phase = line.strip().split(b':', 1)[1].decode('ascii', errors='ignore')
                                if phase in PHASES:
                                    self.phase(job, phase)
                        if len(pending) > 4096:
                            pending = b''
                process.wait(timeout=max(0.1, deadline - time.monotonic()))
            except BaseException:
                terminate_group(process)
                raise
            code = process.wait()
            if code == 42:
                raise OperationError('CURRENT_VERSION_CHANGED', '当前版本已变化；未停服、未执行迁移，请重新检查。')
            if code == 43:
                raise OperationError('CUTOVER_BACKUP_FAILED_RECOVERED', '最终备份未通过，数据库未迁移，原服务已恢复。')
            if code == 44:
                raise OperationError('UPDATE_NOTICE_REQUIRED', '当前激活未获得已预告授权任务的确认，未停服或迁移。')
            if code != 0:
                classified = classify_failure(subprocess.CalledProcessError(code, [UPDATER, 'activate'],
                                                stderr=private_tail), job.get('phase'), 'ACTIVATE')
                if classified == 'UNKNOWN':
                    classified = {'MIGRATING': 'MIGRATION_FAILED', 'HEALTH_CHECK': 'HEALTH_CHECK_FAILED'}.get(
                        job.get('phase'), 'ACTIVATION_FAILED')
                raise OperationError(classified, '激活或健康检查失败，请管理员核查备份、数据库迁移和服务恢复状态。', exit_code=code)

    def validate_database(self, env: dict, jar: Path):
        database = env.get('UTEN_PG_DATABASE', 'uten_imp')
        port = env.get('UTEN_PG_PORT', '5432')
        if not re.fullmatch(r'[A-Za-z0-9_]+', database):
            raise OperationError('INVALID_HOST_CONFIG', '主机数据库名称无效。')
        if not re.fullmatch(r'[1-9][0-9]{0,4}', port) or int(port) > 65535:
            raise OperationError('INVALID_HOST_CONFIG', '主机数据库端口无效。')
        query = "SELECT json_build_object('failed', count(*) FILTER (WHERE NOT success), 'versions', coalesce(json_agg(version) FILTER (WHERE success AND version IS NOT NULL), '[]')) FROM public.flyway_schema_history"
        result = self.runner(['/usr/sbin/runuser', '-u', 'postgres', '--', '/usr/bin/psql',
                              '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', PG_SOCKET_DIRECTORY,
                              '-p', port, '-d', database, '-c', 'SET default_transaction_read_only=on; SET statement_timeout=5000; ' + query], timeout=15)
        actual = json.loads(result.stdout)
        import zipfile
        with zipfile.ZipFile(jar) as release:
            expected = [match.group(1).replace('_', '.') for name in release.namelist()
                        if (match := re.fullmatch(r'BOOT-INF/classes/db/migration/V([0-9][0-9._]*)__.*\.sql', name))]
        def normalized(value):
            return tuple(map(int, value.split('.')))
        if (not expected or actual['failed'] != 0 or len(actual['versions']) != len(expected)
                or {normalized(v) for v in actual['versions']} != {normalized(v) for v in expected}):
            raise OperationError('MIGRATION_STATE_MISMATCH', '数据库迁移记录与新版本不一致，请管理员检查；禁止重复激活。')

    def backup_binding(self, binding):
        validate_runtime_binding(binding)
        if (binding['database'], binding['host'], binding['port']) != (MIGRATOR_DATABASE, MIGRATOR_HOST, MIGRATOR_PORT):
            raise OperationError('BACKUP_BINDING_MISMATCH', '当前运行数据库不匹配独立迁移程序固定的本机标准目标，未执行更新，请管理员核对部署。')
        env = self.source.load()[1]
        local_health_url(env)
        paired = read_json(Path(BACKUP_CONFIG))
        storage = read_json(OPERATIONS_CONFIG)['storage']
        def same_path(left, right):
            if not isinstance(left, str) or not isinstance(right, str):
                return False
            a, b = Path(left), Path(right)
            return a.is_absolute() and b.is_absolute() and a.resolve(strict=True) == b.resolve(strict=True)
        database = env.get('UTEN_PG_DATABASE', 'uten_imp')
        port = env.get('UTEN_PG_PORT', '5432')
        if not re.fullmatch(r'[1-9][0-9]{0,4}', port) or int(port) != binding['port']:
            raise OperationError('BACKUP_BINDING_MISMATCH', '更新器数据库端口与当前后端不一致，已中止更新。')
        if (binding['database'] != database or paired.get('database', 'uten_imp') != database
                or paired.get('port', 5432) != binding['port']
                or not same_path(paired.get('socket_directory', '/run/postgresql'), PG_SOCKET_DIRECTORY)
                or not same_path(paired.get('backup_root', '/data/uten-imp-backups/paired'), storage.get('paired_backup_root'))
                or not same_path(binding['mediaRoot'], storage.get('uploads_root'))):
            raise OperationError('BACKUP_BINDING_MISMATCH', '运行数据库、附件目录与备份或存储配置不一致，已在停服前中止，请管理员核对。')
        media_key = 'media_root' if binding['storageProvider'] == 'internal' else 'local_media_root'
        configured_media = paired.get(media_key, '/var/lib/uten-imp-media/attachments' if media_key == 'media_root' else None)
        if not same_path(binding['mediaRoot'], configured_media):
            raise OperationError('BACKUP_BINDING_MISMATCH', '配套备份未覆盖当前上传目录，已中止更新。')
        if binding['legacyLocalEnabled'] and not same_path(binding['legacyLocalRoot'], paired.get('local_media_root')):
            raise OperationError('BACKUP_BINDING_MISMATCH', '配套备份未覆盖历史上传目录，已中止更新。')
        legacy = paired.get('local_media_root')
        inventoried_legacy = storage.get('legacy_uploads_root')
        if ((inventoried_legacy is not None and not same_path(inventoried_legacy, legacy))
                or (legacy is not None and not same_path(legacy, binding['mediaRoot'])
                    and not same_path(legacy, inventoried_legacy))):
            raise OperationError('BACKUP_BINDING_MISMATCH', '兼容历史上传目录与可信备份及存储统计配置不一致，已中止更新。')
        identity = self.runner(['/usr/sbin/runuser', '-u', 'postgres', '--', '/usr/bin/psql',
                                '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', PG_SOCKET_DIRECTORY,
                                '-p', str(binding['port']), '-d', database, '-c',
                                "SET default_transaction_read_only=on; SET statement_timeout=5000; SELECT json_build_object('postmasterStartedAt',pg_postmaster_start_time())"], timeout=15)
        identity = json.loads(identity.stdout)
        if dt.datetime.fromisoformat(identity['postmasterStartedAt'].replace('Z', '+00:00')) != dt.datetime.fromisoformat(binding['postmasterStartedAt'].replace('Z', '+00:00')):
            raise OperationError('BACKUP_BINDING_MISMATCH', '当前应用与备份连接不属于同一运行数据库实例，已中止更新。')
        migrator = parse_env(read_private(Path(env.get('UTEN_MIGRATOR_ENV', str(MIGRATOR_CONFIG)))))
        # UtenImpMigrator is NOT Spring: URL/user/schema are compiled constants,
        # and the reviewed dedicated environment accepts one credential only.
        if set(migrator) != {MIGRATOR_PASSWORD_ENV} or not re.fullmatch(r'[A-Za-z0-9]{20,512}', migrator.get(MIGRATOR_PASSWORD_ENV, '')):
            raise OperationError('INVALID_HOST_CONFIG', '独立迁移环境须仅包含有效的专用数据库凭据，不接受地址或启动覆盖。')

    def stable_health(self, env: dict):
        url = local_health_url(env)
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        service = env.get('UTEN_APP_SERVICE', 'uten-imp')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9@._-]{0,127}', service):
            raise OperationError('INVALID_HOST_CONFIG', '应用服务名称无效。')
        baseline = None
        for attempt in range(7):
            unit = self.runner(['/usr/bin/systemctl', 'show', service, '--property=MainPID',
                                '--property=NRestarts', '--property=ActiveState', '--property=SubState']).stdout
            values = dict(line.split('=', 1) for line in unit.splitlines() if '=' in line)
            try:
                identity = int(values['MainPID']), int(values['NRestarts'])
                if identity[0] <= 0 or values.get('ActiveState') != 'active' or values.get('SubState') != 'running':
                    raise ValueError()
                if baseline is not None and identity != baseline:
                    raise ValueError()
                baseline = identity
            except (ValueError, KeyError):
                raise OperationError('UNSTABLE_PROCESS', '后端进程在观察期内退出或重启，更新未通过稳定性验收。') from None
            for endpoint in (url, url.removesuffix('readiness') + 'liveness'):
                request = urllib.request.Request(endpoint, headers={'X-Forwarded-Proto': 'https'})
                with client.open(request, timeout=5) as response:
                    body = response.read(65537)
                    if len(body) > 65536 or json.loads(body).get('status') != 'UP':
                        raise OperationError('UNHEALTHY', '后端稳定性检查未通过，请管理员核查运行状态。')
            if attempt < 6:
                time.sleep(10)


def local_health_url(env):
    # The legacy CLI health URL may intentionally be certificate-validated
    # public HTTPS. Keep it unchanged; process stability uses the local backend.
    url = env.get('UTEN_OPERATIONS_HEALTH_URL', 'http://127.0.0.1:8080/actuator/health/readiness')
    match = re.fullmatch(r'http://127\.0\.0\.1:([0-9]{1,5})/actuator/health/readiness', url)
    if match is None or not 1 <= int(match[1]) <= 65535:
        raise OperationError('INVALID_HOST_CONFIG', '主机稳定性检查地址必须为本机 readiness 端点。')
    return url


def version_tuple(value):
    match = VERSION.fullmatch(value)
    if not match:
        raise OperationError('INVALID_RELEASE', '版本号无效。')
    return tuple(map(int, match.groups()))


def validate_runtime_binding(value):
    required = {'database', 'host', 'port', 'storageProvider', 'mediaRoot', 'legacyLocalEnabled', 'legacyLocalRoot', 'postmasterStartedAt'}
    if (not isinstance(value, dict) or set(value) != required
            or not isinstance(value['database'], str) or not re.fullmatch(r'[A-Za-z0-9_]+', value['database'])
            or not isinstance(value['host'], str) or value['host'] not in {'127.0.0.1', '::1', 'unix'}
            or type(value['port']) is not int or not 1 <= value['port'] <= 65535
            or not isinstance(value['storageProvider'], str) or value['storageProvider'] not in {'internal', 'local'}
            or not isinstance(value['mediaRoot'], str) or not value['mediaRoot'].startswith('/')
            or type(value['legacyLocalEnabled']) is not bool
            or value['legacyLocalEnabled'] and (not isinstance(value['legacyLocalRoot'], str) or not value['legacyLocalRoot'].startswith('/'))):
        raise OperationError('INVALID_RUNTIME_BINDING', '无法确认当前数据库与上传存储身份，未启动更新，请管理员核对本机部署。')
    try:
        if not isinstance(value['postmasterStartedAt'], str) or dt.datetime.fromisoformat(value['postmasterStartedAt'].replace('Z', '+00:00')).tzinfo is None:
            raise ValueError()
    except (ValueError, TypeError):
        raise OperationError('INVALID_RUNTIME_BINDING', '无法确认当前数据库实例身份，未启动更新。') from None


def migration_digest(path: Path) -> str:
    import zipfile
    digest = hashlib.sha256()
    with zipfile.ZipFile(path) as jar:
        names = sorted(n for n in jar.namelist() if n.startswith('BOOT-INF/classes/db/migration/') and not n.endswith('/'))
        if not names:
            raise OperationError('INVALID_RELEASE', '发布程序缺少数据库迁移资源。')
        for name in names:
            digest.update(name.encode() + b'\0' + hashlib.sha256(jar.read(name)).digest())
    return digest.hexdigest()


def assert_forward_migrations(previous: Path, candidate: Path):
    import zipfile
    def entries(path):
        with zipfile.ZipFile(path) as jar:
            return {name: hashlib.sha256(jar.read(name)).digest() for name in jar.namelist()
                    if re.fullmatch(r'BOOT-INF/classes/db/migration/V[0-9][0-9._]*__.*\.sql', name)}
    old, new = entries(previous), entries(candidate)
    if not old or not new or any(new.get(name) != digest for name, digest in old.items()):
        raise OperationError('MIGRATIONS_NOT_FORWARD_ONLY', '发布包修改或删除了已有数据库迁移，已在停服前拒绝更新。')


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(15)
        peer = struct.unpack('3i', self.connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if peer[1] != self.server.app_uid:
            return
        request = None
        try:
            raw = self.rfile.readline(65538)
            if len(raw) > 65536 or not raw.endswith(b'\n'):
                raise OperationError('INVALID_REQUEST', '请求过大或格式无效。')
            request = json.loads(raw)
            if not isinstance(request, dict):
                raise OperationError('INVALID_REQUEST', '请求格式无效。')
            result = {'ok': True, 'data': self.server.operations.dispatch(request)}
        except OperationError as error:
            failure = failure_view(classify_failure(error, 'CHECKING'),
                                   original_service_preserved=error.code != 'OUTCOME_UNCERTAIN')
            result = {'ok': False, 'code': error.code if isinstance(error.code, str) and error.code in PUBLIC_OPERATION_CODES else 'HOST_OPERATION_FAILED',
                      'message': failure['title'] + '：' + failure['reason'] + failure['suggestion'],
                      'failure': failure}
        except Exception:
            mutation = isinstance(request, dict) and request.get('operation') in {
                'CONFIG_SAVE', 'UPDATE_START', 'UPDATE_DISPATCH', 'UPDATE_CANCEL', 'STORAGE_DELETE'}
            result = {'ok': False, 'code': 'OUTCOME_UNCERTAIN' if mutation else 'HOST_OPERATION_FAILED',
                      'message': '操作结果尚未确认，请读取本机作业或配置状态。' if mutation else '服务器操作失败，请联系管理员检查主机组件。'}
            result['failure'] = failure_view('OUTCOME_UNCERTAIN' if mutation else 'UNKNOWN',
                                             original_service_preserved=not mutation)
        encoded = (json.dumps(result, ensure_ascii=False) + '\n').encode()
        if len(encoded) > 65536:
            encoded = b'{"ok":false,"code":"RESPONSE_TOO_LARGE","message":"Please narrow the result."}\n'
        self.wfile.write(encoded)


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def secure_directory(path: Path, mode: int, gid: int):
    path.mkdir(mode=mode, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise RuntimeError('Unsafe operations directory')
    os.chown(path, 0, gid)
    os.chmod(path, mode)


def main() -> int:
    commands = {'serve': 2, 'worker': 2, 'record-restore-proof': 2,
                'assert-activation-authorized': 4, 'confirm-service-restored': 4}
    if os.geteuid() != 0 or len(sys.argv) != commands.get(sys.argv[1] if len(sys.argv) > 1 else '', -1):
        raise SystemExit('Use root-owned operations service.')
    secure_directory(STATE, 0o700, 0)
    secure_directory(PUBLIC_STATE, 0o755, 0)
    secure_directory(Path('/run/uten-imp-updater'), 0o700, 0)
    operations = Operations()
    if sys.argv[1] == 'assert-activation-authorized':
        try:
            operations.assert_activation_authorized(sys.argv[2], sys.argv[3])
        except OperationError:
            print('UTEN_ACTIVATION_BLOCKED:UPDATE_NOTICE_REQUIRED', file=sys.stderr)
            return 44
        return 0
    if sys.argv[1] == 'confirm-service-restored':
        try:
            module = load_maintenance_recovery()
            receipt = module.confirm_service_restored(operations, sys.argv[2], sys.argv[3])
        except OperationError as error:
            code = error.code if error.code in PUBLIC_OPERATION_CODES else 'RECOVERY_REQUIRED'
            print('RECOVERY_NOT_CONFIRMED:' + code + ' ' + ' '.join(str(error).split())[:1000], file=sys.stderr)
            return 1
        except Exception:
            # Paths, argv and provider diagnostics must never escape a failed
            # local confirmation. The gate remains tied to durable evidence.
            print('RECOVERY_NOT_CONFIRMED:UNAVAILABLE', file=sys.stderr)
            return 1
        print(json.dumps(receipt))
        return 0
    if sys.argv[1] == 'worker':
        return operations.worker()
    if sys.argv[1] == 'record-restore-proof':
        # Root-only local attestation after a real isolated PostgreSQL restore.
        # This operation is deliberately absent from the Unix/HTTP protocol.
        raw = sys.stdin.buffer.read(65537)
        if len(raw) > 65536:
            raise SystemExit('Restore receipt is too large.')
        storage = load_storage()
        with lock(STATE / 'operations.lock'):
            operations.no_running_job()
            config = read_json(OPERATIONS_CONFIG)
            context = {'config': config['storage'], 'host_state_dir': STATE, 'lock_held': True,
                       'active_jobs': [], 'actor_id': str(uuid.UUID(int=0)), 'request_id': str(uuid.uuid4())}
            try:
                result = storage.record_restore_proof(json.loads(raw), context)
            except storage.StorageError as error:
                raise SystemExit(str(error)) from None
            print(json.dumps(result))
        return 0
    app_uid = pwd.getpwnam('uten-imp').pw_uid
    app_gid = grp.getgrnam('uten-imp').gr_gid
    secure_directory(SOCKET.parent, 0o750, app_gid)
    if SOCKET.exists():
        if not stat.S_ISSOCK(SOCKET.lstat().st_mode) or SOCKET.lstat().st_uid != 0:
            raise RuntimeError('Unsafe socket path')
        SOCKET.unlink()
    load_storage()
    # Anonymous polls read one fixed file, without authenticating or executing
    # systemctl once per user. Keep the timestamp fresh while appointments wait.
    def refresh_public_status():
        while True:
            try:
                operations.publish_maintenance(operations.observe_job())
            except Exception as error:
                print('Maintenance status refresh unavailable: ' + type(error).__name__, file=sys.stderr)
            time.sleep(10)
    threading.Thread(target=refresh_public_status, daemon=True).start()
    with Server(str(SOCKET), Handler) as server:
        os.chmod(SOCKET, 0o660)
        os.chown(SOCKET, 0, app_gid)
        server.operations, server.app_uid = operations, app_uid
        server.serve_forever(poll_interval=1)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
