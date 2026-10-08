#!/usr/bin/env python3
"""Bounded, durable local alerts; no network, credentials, or raw host details."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time
import uuid

STATE = Path("/var/lib/uten-alert")
MAX_BYTES = 65536
MAX_EVENTS = 128
RETENTION = 7 * 86400
THROTTLE = 6 * 3600


def category(event):
    event = event.removesuffix(".service")
    exact = {
        "uten-pgbackup": ("CRITICAL", "每日数据库备份失败"),
        "uten-pgbackup-health": ("CRITICAL", "数据库备份与恢复点检查失败"),
        "uten-paired-internal-backup": ("CRITICAL", "数据库与附件的配套备份失败"),
        "uten-imp": ("CRITICAL", "ERP 后台停止运行"),
        "uten-imp-updater": ("WARNING", "自动更新检查失败"),
        "wal-archive": ("CRITICAL", "数据库日志归档失败"),
    }
    if event in exact:
        return event, *exact[event]
    for prefix, severity, title in (
        ("test", "WARNING", "服务器告警通道测试"),
        ("diskwarn-", "WARNING", "磁盘使用率超过八成"),
        ("disk-", "CRITICAL", "磁盘空间不足或未挂载"),
        ("raid-", "CRITICAL", "数据盘阵列异常"),
        ("smart-", "CRITICAL", "硬盘健康预警"),
        ("down-", "CRITICAL", "关键服务停止运行"),
        ("backup-stale", "CRITICAL", "备份未按时完成"),
    ):
        if event.startswith(prefix):
            key = prefix.rstrip("-") + "-" + hashlib.sha256(event.encode()).hexdigest()[:16]
            if prefix in ("disk-", "diskwarn-"):
                label = {"/": "系统盘", "/data": "数据盘", "/var/lib/uten-imp-media": "附件盘",
                         "/srv/uten-backup": "本机备份盘"}.get(event[len(prefix):], "磁盘")
                title = label + ("使用率超过八成" if prefix == "diskwarn-" else "空间不足或未挂载")
            elif prefix == "down-":
                label = {"uten-imp": "ERP 后台", "postgresql@16-main": "数据库",
                         "nginx": "网页入口", "clamav-daemon": "病毒扫描服务",
                         "uten-paddle-ocr": "发票识别服务"}.get(event[len(prefix):], "关键服务")
                title = label + "停止运行"
            elif event == "backup-stale-paired":
                title = "数据库与附件的配套备份未按时完成"
            return key, severity, title
    return "other-" + hashlib.sha256(event.encode()).hexdigest()[:16], "WARNING", "服务器出现需要检查的问题"


def record(directory, event, now, group=None):
    import fcntl
    directory = Path(directory)
    directory.mkdir(mode=0o750, parents=False, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
        raise ValueError("Unsafe alert directory")
    if group is not None:
        os.chown(directory, 0, group)
        os.chmod(directory, 0o750)
    lock = os.open(directory / "operation.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
            raise ValueError("Unsafe alert lock")
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = directory / "events.json"
        events = []
        if path.exists() or path.is_symlink():
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or info.st_mode & 0o022:
                    raise ValueError("Unsafe alert state")
                raw = source.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError("Oversized alert state")
            state = json.loads(raw)
            if state.get("format") != "uten-host-alerts-v1" or not isinstance(state.get("events"), list):
                raise ValueError("Invalid alert state")
            events = state["events"]
            if len(events) > MAX_EVENTS:
                raise ValueError("Too many alert events")
        key, severity, title = category(event)
        events = [item for item in events if now - item["occurredAt"] < RETENTION]
        if any(item["key"] == key and 0 <= now - item["occurredAt"] < THROTTLE for item in events):
            return False
        if len(events) >= MAX_EVENTS:
            raise ValueError("Alert queue is full; existing events preserved")
        events.append({"id": str(uuid.uuid4()), "key": key, "severity": severity,
                       "title": title, "occurredAt": now})
        raw = json.dumps({"format": "uten-host-alerts-v1", "events": events}, ensure_ascii=False).encode()
        if len(raw) > MAX_BYTES:
            raise ValueError("Alert queue byte limit reached")
        fd, temporary = tempfile.mkstemp(prefix=".events-", dir=directory)
        try:
            with os.fdopen(fd, "wb") as target:
                os.fchmod(target.fileno(), 0o640)
                if group is not None:
                    os.fchown(target.fileno(), 0, group)
                target.write(raw)
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary, path)
            parent = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return True
    finally:
        os.close(lock)


def main():
    import grp
    if os.geteuid() != 0:
        raise ValueError("Host alert recorder requires root")
    event = sys.argv[1] if len(sys.argv) > 1 else "unknown"
    if len(event) > 256:
        raise ValueError("Invalid event name")
    # Extra hook arguments may contain diagnostic output; never persist them.
    record(STATE, event, int(time.time()), grp.getgrnam("uten-imp").gr_gid)


if __name__ == "__main__":
    try:
        main()
    except Exception as failure:
        print("Host alert recording failed: " + type(failure).__name__, file=sys.stderr)
        sys.exit(1)
