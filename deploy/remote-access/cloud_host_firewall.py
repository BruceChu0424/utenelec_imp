#!/usr/bin/env python3
"""Cloud-only host ingress guard, separate from the Uten tunnel firewall.

Rendering is offline. A live trial requires the current authorized SSH TCP
session and an independently armed rollback timer. SSH source control can stay
with the cloud security group, so a dynamic admin IP needs no OS console password.
Only a new SSH TCP connection can confirm and persist the candidate.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE / "templates/cloud-host-firewall.nft.tmpl"
TABLE = "uten_cloud_host"
NFT = "/usr/sbin/nft"
SS = "/usr/sbin/ss"
SYSTEMCTL = "/usr/bin/systemctl"
SYSTEMD_RUN = "/usr/bin/systemd-run"
HELPER = "/usr/local/lib/uten-remote/cloud_host_firewall.py"
UNIT = "uten-cloud-host-firewall.service"
STATE = Path("/var/lib/uten-remote/cloud-host-firewall")
MAX_JSON = 128 * 1024


class UnsafeChange(ValueError):
    pass


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise UnsafeChange("duplicate JSON field")
        result[key] = value
    return result


def decode(raw):
    if len(raw) > MAX_JSON:
        raise UnsafeChange("firewall configuration exceeds its size limit")
    return json.loads(raw, object_pairs_hook=_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(UnsafeChange("invalid JSON number")))


def _sources(values, *, public_udp=False):
    if not isinstance(values, list) or not 1 <= len(values) <= 8 or not all(isinstance(v, str) for v in values):
        raise UnsafeChange("explicit approved IPv4 sources are required")
    result = []
    for value in values:
        try:
            network = ipaddress.IPv4Network(value, strict=True)
        except ValueError as error:
            raise UnsafeChange("sources must be canonical public IPv4 /32 addresses") from error
        if public_udp and value == "0.0.0.0/0" and len(values) == 1:
            result.append(value)
        elif value != str(network) or network.prefixlen != 32 or not network.network_address.is_global:
            raise UnsafeChange("SSH sources must be public IPv4 /32; broad management access is forbidden")
        else:
            result.append(str(network))
    if len(set(result)) != len(result):
        raise UnsafeChange("duplicate approved source")
    return sorted(result)


def validate_policy(value):
    fields = {"schema_version", "role", "public_interface", "ssh_source_policy", "admin_ipv4_cidrs", "wireguard_ipv4_cidrs", "dhcpv4"}
    if not isinstance(value, dict) or set(value) != fields or type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise UnsafeChange("unexpected host firewall policy fields or schema")
    if value["role"] != "cloud":
        raise UnsafeChange("the host ingress policy is exclusively for the cloud proxy")
    interface = value["public_interface"]
    if not isinstance(interface, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.:-]{0,14}", interface) or "REPLACE" in interface:
        raise UnsafeChange("a verified Linux ingress interface is required")
    if type(value["dhcpv4"]) is not bool:
        raise UnsafeChange("DHCP must be explicitly reviewed as true or false")
    mode = value["ssh_source_policy"]
    if mode == "host-allowlist":
        admins = _sources(value["admin_ipv4_cidrs"])
    elif mode == "security-group" and value["admin_ipv4_cidrs"] == []:
        admins = []
    else:
        raise UnsafeChange("choose explicit SSH ownership; security-group mode must not carry a stale host allowlist")
    return {**value, "admin_ipv4_cidrs": admins,
            "wireguard_ipv4_cidrs": _sources(value["wireguard_ipv4_cidrs"], public_udp=True)}


def render_policy(value):
    policy = validate_policy(value)
    content = TEMPLATE.read_text(encoding="utf-8")
    values = {"PUBLIC_INTERFACE": policy["public_interface"],
              "WIREGUARD_IPV4_SOURCES": ", ".join(policy["wireguard_ipv4_cidrs"]),
              "DHCPV4_RULE": ('        iifname "' + policy["public_interface"] + '" udp sport 67 udp dport 68 accept\n') if policy["dhcpv4"] else ""}
    source_rule = ("meta nfproto ipv4" if policy["ssh_source_policy"] == "security-group" else
                   "ip saddr { " + ", ".join(policy["admin_ipv4_cidrs"]) + " }")
    values["SSH_RULE"] = ('        iifname "' + policy["public_interface"] + '" ' + source_rule + ' tcp dport 22 ct state new accept')
    for key, replacement in values.items():
        content = content.replace("@@" + key + "@@", replacement)
    if "@@" in content:
        raise UnsafeChange("unexpanded firewall template")
    validate_table(content)
    return content


def validate_table(content):
    if not isinstance(content, str) or len(content.encode("utf-8")) > MAX_JSON:
        raise UnsafeChange("invalid owned table snapshot")
    # Inspect structure outside comments/quoted strings, including same-line
    # extra statements. Line-prefix checks alone permit a second table after a
    # closing brace on the same line. The kernel still validates full syntax.
    structural = []
    index = 0
    while index < len(content):
        char = content[index]
        if char == "#":
            end = content.find("\n", index)
            index = len(content) if end == -1 else end
        elif char == '"':
            structural.append('"quoted"')
            index += 1
            while index < len(content) and content[index] != '"':
                index += 2 if content[index] == "\\" else 1
            if index >= len(content):
                raise UnsafeChange("unterminated firewall string")
            index += 1
        else:
            structural.append(char)
            index += 1
    text = "".join(structural).strip()
    header = re.match(r"table\s+inet\s+" + TABLE + r"\s*\{", text)
    if header is None:
        raise UnsafeChange("only the dedicated cloud host table may change")
    depth = 1
    end = header.end()
    while end < len(text) and depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    if depth or text[end:].strip():
        raise UnsafeChange("only one complete owned firewall table is permitted")
    if set(re.findall(r"[A-Za-z_][A-Za-z0-9_.-]*", text)) & {"include", "delete", "flush", "destroy", "add", "insert", "rename", "define"}:
        raise UnsafeChange("imperative/global firewall statements are forbidden")


def transaction(content, exists):
    if content is not None:
        validate_table(content)
    return (f"delete table inet {TABLE}\n" if exists else "") + (content or "")


def ssh_session(raw):
    parts = raw.split() if isinstance(raw, str) else []
    try:
        if len(parts) != 4:
            raise ValueError()
        client, server = ipaddress.IPv4Address(parts[0]), ipaddress.IPv4Address(parts[2])
        client_port, server_port = int(parts[1]), int(parts[3])
        if not client.is_global or not 1 <= client_port <= 65535 or server_port != 22 or server.is_unspecified or server.is_multicast:
            raise ValueError()
        return [str(client), str(client_port), str(server), str(server_port)]
    except (ValueError, TypeError) as error:
        raise UnsafeChange("a direct public-IPv4 SSH_CONNECTION to port 22 is required") from error


def approve_session(policy, session):
    policy = validate_policy(policy)
    if policy["ssh_source_policy"] == "host-allowlist" and session[0] + "/32" not in policy["admin_ipv4_cidrs"]:
        raise UnsafeChange("candidate omits the current SSH source; update approved sources before trial")


def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != 0 or info.st_mode & 0o022:
        raise UnsafeChange("firewall files must be root-owned regular files, without group/other write access")
    if info.st_size > MAX_JSON:
        raise UnsafeChange("firewall file exceeds its size limit")
    return path.read_bytes()


def atomic_json(path, value):
    raw = (json.dumps(value, sort_keys=True, allow_nan=False) + "\n").encode("utf-8")
    if len(raw) > MAX_JSON:
        raise UnsafeChange("firewall transaction receipt exceeds its size limit")
    descriptor, temporary = tempfile.mkstemp(prefix=".cloud-host-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Controller:
    def __init__(self, state=STATE, runner=subprocess.run):
        self.state, self.runner = Path(state), runner
        self.pending = self.state / "pending.json"
        self.active = self.state / "active.json"

    @contextmanager
    def locked(self, *, wait=False):
        import fcntl
        for parent in reversed((self.state, *self.state.parents)):
            if parent.exists() and parent.is_symlink():
                raise UnsafeChange("state directory links are forbidden")
        self.state.mkdir(parents=True, mode=0o700, exist_ok=True)
        info = self.state.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
            raise UnsafeChange("cloud host firewall state must be a private root directory")
        descriptor = os.open(self.state / "guard.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != 0 or info.st_mode & 0o077:
                raise UnsafeChange("unsafe cloud host firewall guard")
            # The independent rollback service must wait for an in-flight
            # confirm/trial to release its short guard, rather than lose the
            # recovery attempt to a transient LOCK_NB contention.
            fcntl.flock(descriptor, fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(descriptor)

    def run(self, command, *, input=None, allowed=(0,)):
        result = self.runner(command, input=input, text=True, capture_output=True, timeout=15)
        if result.returncode not in allowed:
            raise UnsafeChange("host firewall command failed: " + Path(command[0]).name)
        return result

    def current_table(self):
        listing = json.loads(self.run([NFT, "-j", "list", "tables"]).stdout)
        exists = any(row.get("table", {}).get("family") == "inet" and row.get("table", {}).get("name") == TABLE
                     for row in listing["nftables"])
        if not exists:
            return None
        content = self.run([NFT, "list", "table", "inet", TABLE]).stdout
        validate_table(content)
        return content

    def replace(self, content):
        batch = transaction(content, self.current_table() is not None)
        if batch:
            self.run([NFT, "--check", "-f", "-"], input=batch)
            self.run([NFT, "-f", "-"], input=batch)

    def sessions(self):
        output = self.run([SS, "-4", "-Htn", "state", "established", "( sport = :22 )"]).stdout
        result = []
        for line in output.splitlines():
            parts = line.split()
            if len(parts) < 4:
                raise UnsafeChange("cannot inspect existing SSH sessions")
            local, peer = parts[-2].rsplit(":", 1), parts[-1].rsplit(":", 1)
            ipaddress.IPv4Address(local[0]); ipaddress.IPv4Address(peer[0])
            result.append([peer[0], peer[1], local[0], local[1]])
        return result

    def unit_enabled(self):
        result = self.run([SYSTEMCTL, "is-enabled", UNIT], allowed=(0, 1))
        if result.stdout.strip() not in {"enabled", "disabled"}:
            raise UnsafeChange("install the reviewed host firewall unit before a trial")
        return result.stdout.strip() == "enabled"

    def stop_timer(self, token):
        timer = self.timer(token) + ".timer"
        result = self.run([SYSTEMCTL, "is-active", timer], allowed=(0, 3, 4))
        if result.returncode == 0:
            self.run([SYSTEMCTL, "stop", timer])

    @staticmethod
    def reviewed_content(policy):
        private_file(TEMPLATE)
        return render_policy(policy)

    def load_pending(self, token):
        if not re.fullmatch(r"[0-9a-f]{32}", token):
            raise UnsafeChange("invalid trial token")
        value = decode(private_file(self.pending))
        if value.get("schema_version") != 1 or value.get("token") != token or value.get("status") not in {"trial", "confirmed"}:
            raise UnsafeChange("pending trial does not match")
        validate_policy(value["policy"])
        if value["previous_table"] is not None:
            validate_table(value["previous_table"])
        if value["previous_active"] is not None:
            validate_policy(value["previous_active"])
        if type(value["previous_enabled"]) is not bool or not math.isfinite(value["deadline"]):
            raise UnsafeChange("invalid pending trial state")
        return value

    @staticmethod
    def timer(token):
        return "uten-cloud-host-firewall-rollback-" + token

    def trial(self, policy, connection, *, recovery_verified=False, security_group_console_verified=False, rollback_seconds=180):
        policy, session = validate_policy(policy), ssh_session(connection)
        approve_session(policy, session)
        if policy["ssh_source_policy"] == "host-allowlist" and not recovery_verified:
            raise UnsafeChange("verify an independent OS recovery shell before a host-allowlist trial")
        if policy["ssh_source_policy"] == "security-group" and not security_group_console_verified:
            raise UnsafeChange("verify independent cloud-console security-group management before trial")
        if type(rollback_seconds) is not int or not 120 <= rollback_seconds <= 600:
            raise UnsafeChange("rollback interval must be 120..600 seconds")
        with self.locked():
            if self.pending.exists() or self.pending.is_symlink():
                raise UnsafeChange("finish or roll back the previous trial first")
            # The installed helper is the timer's recovery authority, not a
            # mutable checkout path or command supplied by the SSH client.
            if private_file(Path(HELPER)) != Path(__file__).read_bytes():
                raise UnsafeChange("install this exact reviewed helper before trial")
            content = self.reviewed_content(policy)
            peers = self.sessions()
            if session not in peers:
                raise UnsafeChange("SSH_CONNECTION is not an established server-side TCP session")
            value = {"schema_version": 1, "token": uuid.uuid4().hex, "status": "trial", "policy": policy,
                     "helper_sha256": hashlib.sha256(private_file(Path(HELPER))).hexdigest(),
                     "rendered_sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
                     "previous_table": self.current_table(),
                     "previous_active": validate_policy(decode(private_file(self.active))) if self.active.exists() or self.active.is_symlink() else None,
                     "previous_enabled": self.unit_enabled(), "existing_sessions": peers,
                     "applied_table": None,
                     "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                     "deadline": time.monotonic() + rollback_seconds}
            atomic_json(self.pending, value)
            timer = self.timer(value["token"])
            self.run([SYSTEMD_RUN, "--quiet", "--unit=" + timer, "--on-active=" + str(rollback_seconds) + "s",
                      "--timer-property=AccuracySec=1s", "--property=Type=oneshot", "--property=UMask=0077",
                      "--property=NoNewPrivileges=yes", "--property=ProtectSystem=strict",
                      "--property=ReadWritePaths=" + str(self.state), "--property=CapabilityBoundingSet=CAP_NET_ADMIN",
                      "/usr/bin/python3", HELPER, "rollback", "--token", value["token"]])
            self.run([SYSTEMCTL, "is-active", timer + ".timer"])
            # A failed check/apply leaves the timer and pending receipt intact.
            # Its rollback only restores this owned table/configuration.
            self.replace(content)
            value["applied_table"] = self.current_table()
            if value["applied_table"] is None:
                raise UnsafeChange("the trial table was not installed")
            atomic_json(self.pending, value)
            return {"state": "TRIAL", "token": value["token"], "rollbackAfterSeconds": rollback_seconds,
                    "requiresNewSSHConnection": True, "persistent": False}

    def _rollback(self, value):
        self.replace(value["previous_table"])
        if value["previous_active"] is None:
            if self.active.exists() or self.active.is_symlink():
                private_file(self.active)
                self.active.unlink()
        else:
            atomic_json(self.active, value["previous_active"])
        self.run([SYSTEMCTL, "enable" if value["previous_enabled"] else "disable", UNIT])
        value["status"] = "rolled_back"
        atomic_json(self.state / "last-change.json", value)
        self.pending.unlink()
        self.stop_timer(value["token"])
        return {"state": "ROLLED_BACK", "otherTablesPreserved": True}

    def rollback(self, token):
        with self.locked(wait=True):
            if not self.pending.exists():
                return {"state": "NO_PENDING_TRIAL"}
            value = self.load_pending(token)
            if value["status"] == "confirmed":
                self.stop_timer(token)
                atomic_json(self.state / "last-change.json", value)
                self.pending.unlink()
                return {"state": "ALREADY_CONFIRMED"}
            return self._rollback(value)

    def confirm(self, token, connection):
        session = ssh_session(connection)
        with self.locked():
            value = self.load_pending(token)
            if value["status"] != "trial" or value["boot_id"] != Path("/proc/sys/kernel/random/boot_id").read_text().strip() or time.monotonic() >= value["deadline"]:
                raise UnsafeChange("trial expired or belongs to a different boot")
            approve_session(value["policy"], session)
            if session in value["existing_sessions"] or session not in self.sessions():
                raise UnsafeChange("confirm through a new SSH TCP connection; connection multiplexing is insufficient")
            # Recheck before persistence; never confirm a missing or drifted
            # candidate just because an old established SSH session survived.
            current = self.current_table()
            if current is None or current != value["applied_table"]:
                raise UnsafeChange("the trial table is missing or changed; roll back and revalidate")
            if (hashlib.sha256(private_file(Path(HELPER))).hexdigest() != value["helper_sha256"]
                    or hashlib.sha256(self.reviewed_content(value["policy"]).encode("utf-8")).hexdigest() != value["rendered_sha256"]):
                raise UnsafeChange("the reviewed helper/template changed during trial")
            atomic_json(self.active, value["policy"])
            self.run([SYSTEMCTL, "enable", UNIT])
            value["status"] = "confirmed"
            atomic_json(self.pending, value)
            self.stop_timer(token)
            atomic_json(self.state / "last-change.json", value)
            self.pending.unlink()
            return {"state": "CONFIRMED", "persistent": True, "otherTablesPreserved": True}

    def boot(self):
        with self.locked(wait=True):
            if self.pending.exists():
                value = decode(private_file(self.pending))
                value = self.load_pending(value["token"])
                if value["status"] == "trial":
                    return self._rollback(value)
                self.stop_timer(value["token"])
                atomic_json(self.state / "last-change.json", value)
                self.pending.unlink()
            policy = validate_policy(decode(private_file(self.active)))
            self.replace(self.reviewed_content(policy))
            return {"state": "CONFIRMED_POLICY_LOADED"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    render = actions.add_parser("render")
    render.add_argument("--policy", type=Path, required=True)
    render.add_argument("--output", type=Path, required=True)
    trial = actions.add_parser("trial")
    trial.add_argument("--policy", type=Path, required=True)
    trial.add_argument("--recovery-access-verified", action="store_true")
    trial.add_argument("--security-group-console-verified", action="store_true")
    trial.add_argument("--rollback-seconds", type=int, default=180)
    for name in ("confirm", "rollback"):
        action = actions.add_parser(name)
        action.add_argument("--token", required=True)
    actions.add_parser("boot")
    args = parser.parse_args(argv)
    try:
        if args.action == "render":
            content = render_policy(decode(args.policy.read_bytes()))
            with args.output.open("x", encoding="utf-8", newline="\n") as stream:
                stream.write(content)
            if os.name == "posix":
                args.output.chmod(0o600)
            result = {"state": "OFFLINE_CANDIDATE", "installed": False}
        else:
            if os.name != "posix" or os.geteuid() != 0:
                raise UnsafeChange("live host firewall operations require Linux root")
            controller = Controller()
            if args.action == "trial":
                result = controller.trial(decode(private_file(args.policy)), os.environ.get("SSH_CONNECTION"),
                                          recovery_verified=args.recovery_access_verified,
                                          security_group_console_verified=args.security_group_console_verified,
                                          rollback_seconds=args.rollback_seconds)
            elif args.action == "confirm":
                result = controller.confirm(args.token, os.environ.get("SSH_CONNECTION"))
            elif args.action == "rollback":
                result = controller.rollback(args.token)
            else:
                result = controller.boot()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("Cloud host firewall change refused: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
