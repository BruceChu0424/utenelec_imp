#!/usr/bin/env python3
"""Root-only initial configuration; creates no rescue user or usable admin session.

Tokens are written to protected files, never stdout. The user must complete a
short enrollment through the live ERP's local super-admin step-up endpoint.
"""
import argparse
import fcntl
import grp
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import stat
import time


def initialize(config_path, origin, broker_path, agent_path, master_path, *,
               broker_group="root", agent_id="backup-publisher", target_id="cloud-archive",
               enrollment_minutes=0, fail_after=None):
    if os.geteuid() != 0 or not 0 <= enrollment_minutes <= 15:
        raise ValueError("root and an enrollment window of 0..15 minutes required")
    paths = [Path(p).absolute() for p in (config_path, broker_path, agent_path, master_path)]
    directory = paths[0].parent
    if directory.name != "uten-dr-control" or len(set(paths)) != 4 or any(p.parent != directory for p in paths):
        raise ValueError("four distinct files inside the explicit uten-dr-control configuration directory required")
    group = grp.getgrnam("uten-dr-control").gr_gid
    broker_gid = grp.getgrnam(broker_group).gr_gid  # Resolve before creating any file.
    directory.mkdir(parents=True, exist_ok=True, mode=0o750)
    if directory.is_symlink() or directory.resolve() != directory or directory.stat().st_uid != 0 \
            or stat.S_IMODE(directory.stat().st_mode) & 0o022:
        raise ValueError("root-owned non-writable real configuration directory required")
    os.chown(directory, 0, group)
    os.chmod(directory, 0o750)
    lock = os.open(directory / ".provision.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        present = [os.path.lexists(p) for p in paths]
        if any(present):
            if not all(present):
                raise ValueError("partial initialization exists; existing secrets were preserved")
            for index, path in enumerate(paths):
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & (0o027 if index == 0 else 0o077):
                    raise ValueError("existing initialization permissions are unsafe; preserved unchanged")
            config = json.loads(paths[0].read_text())
            broker, agent, master = [p.read_text().strip() for p in paths[1:]]
            if config.get("allowedOrigins") != [origin] or config.get("enrollmentBrokerSha256") != hashlib.sha256(broker.encode()).hexdigest() \
                    or config.get("agents", {}).get(agent_id, {}).get("tokenSha256") != hashlib.sha256(agent.encode()).hexdigest() \
                    or len(master) != 64 or any(c not in "0123456789abcdef" for c in master):
                raise ValueError("existing initialization differs; no secret was overwritten")
            return False
        broker, agent, master = secrets.token_urlsafe(48), secrets.token_urlsafe(48), secrets.token_hex(32)
        config = {"allowedOrigins": [origin], "enrollmentBrokerSha256": hashlib.sha256(broker.encode()).hexdigest(),
                  "enrollmentEnabledUntil": time.time() + enrollment_minutes * 60 if enrollment_minutes else 0,
                  "agents": {agent_id: {"tokenSha256": hashlib.sha256(agent.encode()).hexdigest(),
                                        "targetIds": [target_id], "canDrill": False}}}
        spec = importlib.util.spec_from_file_location("uten_dr_configuration", Path(__file__).with_name("control_plane.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.validate_config(config)
        contents = [json.dumps(config, indent=2) + "\n", broker + "\n", agent + "\n", master + "\n"]
        staged, committed = [], []
        try:
            for index, content in enumerate(contents):
                temp = directory / (".provision-" + secrets.token_hex(16))
                fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                staged.append(temp)
                try:
                    os.fchown(fd, 0, group if index == 0 else broker_gid if index == 1 else 0)
                    os.fchmod(fd, 0o640 if index == 0 else 0o600)
                    with os.fdopen(fd, "wb", closefd=False) as stream:
                        stream.write(content.encode())
                        stream.flush()
                    os.fsync(fd)
                finally:
                    os.close(fd)
            # Configuration is the commit marker and is linked last. O_EXCL-like
            # links never replace an existing target, including a symlink.
            for index in (1, 2, 3, 0):
                if index == 0:
                    previous_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        os.fsync(previous_fd)  # All secret names durable before the commit marker.
                    finally:
                        os.close(previous_fd)
                os.link(staged[index], paths[index], follow_symlinks=False)
                committed.append(paths[index])
                if fail_after is not None and len(committed) == fail_after:
                    raise OSError("synthetic provisioning interruption")
            parent_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent_fd)
            finally:
                os.close(parent_fd)
        except Exception:
            for path in reversed(committed):
                path.unlink()
            raise
        finally:
            for path in staged:
                path.unlink(missing_ok=True)
        return True
    finally:
        os.close(lock)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--origin", required=True)
    parser.add_argument("--broker-token-file", required=True)
    parser.add_argument("--broker-group", default="root")
    parser.add_argument("--agent-token-file", required=True)
    parser.add_argument("--master-key-file", required=True)
    parser.add_argument("--agent-id", default="backup-publisher")
    parser.add_argument("--target-id", default="cloud-archive")
    parser.add_argument("--enrollment-minutes", type=int, default=0)
    args = parser.parse_args()
    created = initialize(args.config, args.origin, args.broker_token_file, args.agent_token_file,
                         args.master_key_file, broker_group=args.broker_group, agent_id=args.agent_id,
                         target_id=args.target_id, enrollment_minutes=args.enrollment_minutes)
    print("Protected configuration created." if created else "Existing protected initialization verified; secrets unchanged.")
    print("Rescue identity readiness must be verified separately; no administrator was created.")


if __name__ == "__main__":
    main()
