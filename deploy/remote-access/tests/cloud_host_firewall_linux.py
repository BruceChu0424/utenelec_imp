#!/usr/bin/env python3
"""Real nft/network-namespace regression. No host rules or public ports change.

Run as Linux root with iproute2, util-linux and nftables. The script first enters
a fresh network namespace and refuses an already configured namespace. Fake
TCP/UDP listeners are fixture services, not SSH authentication or ERP UAT.
systemd command scheduling is stubbed; an independent timed subprocess executes
the real rollback controller against the real isolated nft table.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
TCP_PORTS = (22, 80, 443, 5432, 8080, 8082, 8443, 9087, 9443, 15443, 19443)
HOST = "8.8.4.10"
ADMIN = "8.8.4.1"
OTHER = "8.8.4.2"


def command(args, *, timeout=15, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, **kwargs)
    if result.returncode:
        raise RuntimeError("fixture command failed: " + repr(args) + "\n" + result.stderr)
    return result


def load(path):
    spec = importlib.util.spec_from_file_location("isolated_cloud_host_firewall", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Echo:
    def __init__(self, port, *, udp=False, ipv6=False):
        self.socket = socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET,
                                    socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if ipv6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        self.socket.bind(("::" if ipv6 else "0.0.0.0", port))
        if not udp:
            self.socket.listen(30)

        def accepted(stream):
            with stream:
                while value := stream.recv(100):
                    stream.sendall(value)

        def serve():
            while True:
                try:
                    if udp:
                        value, peer = self.socket.recvfrom(100)
                        self.socket.sendto(value, peer)
                    else:
                        stream, _ = self.socket.accept()
                        threading.Thread(target=accepted, args=(stream,), daemon=True).start()
                except OSError:
                    return
        threading.Thread(target=serve, daemon=True).start()

    def close(self):
        self.socket.close()


def inside(nft, parent_namespace):
    if os.geteuid() != 0 or os.stat("/proc/self/ns/net").st_ino == parent_namespace or socket.if_nameindex() != [(1, "lo")]:
        raise RuntimeError("refusing network tests outside a fresh isolated root network namespace")
    children, listeners = [], []
    command(["ip", "link", "set", "lo", "up"])
    command(["ip", "link", "add", "eth-test", "type", "bridge"])
    command(["ip", "addr", "add", HOST + "/24", "dev", "eth-test"])
    command(["ip", "-6", "addr", "add", "fd77::10/64", "dev", "eth-test", "nodad"])
    command(["ip", "link", "set", "eth-test", "up"])

    def namespace(name, address, address6=None, *, routed=False):
        holder = subprocess.Popen(["unshare", "--net", "--", sys.executable, "-c", "import time; time.sleep(180)"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        children.append(holder)
        end = time.monotonic() + 5
        while os.stat(f"/proc/{holder.pid}/ns/net").st_ino == os.stat("/proc/self/ns/net").st_ino:
            if time.monotonic() > end:
                raise AssertionError("client network namespace did not initialize")
            time.sleep(.01)
        peer, local = name + "-peer", name + "-host"
        command(["ip", "link", "add", local, "type", "veth", "peer", "name", peer])
        command(["ip", "link", "set", peer, "netns", str(holder.pid)])
        if routed:
            command(["ip", "addr", "add", "10.123.0.1/24", "dev", local])
        else:
            command(["ip", "link", "set", local, "master", "eth-test"])
        command(["ip", "link", "set", local, "up"])
        prefix = ["nsenter", "-t", str(holder.pid), "--net", "--"]
        command(prefix + ["ip", "link", "set", "lo", "up"])
        command(prefix + ["ip", "addr", "add", address, "dev", peer])
        if address6:
            command(prefix + ["ip", "-6", "addr", "add", address6, "dev", peer, "nodad"])
        command(prefix + ["ip", "link", "set", peer, "up"])
        if routed:
            command(prefix + ["ip", "route", "add", "8.8.4.0/24", "via", "10.123.0.1"])
        else:
            command(prefix + ["ip", "route", "add", "10.123.0.0/24", "via", HOST])
        return prefix

    def probe(prefix, port, *, target=HOST, udp=False, ipv6=False, source_port=0):
        script = ("import socket,sys; s=socket.socket(socket.AF_INET6 if sys.argv[4]=='1' else socket.AF_INET,"
                  "socket.SOCK_DGRAM if sys.argv[3]=='1' else socket.SOCK_STREAM); s.settimeout(.4);"
                  "s.bind(('::' if sys.argv[4]=='1' else '0.0.0.0',int(sys.argv[5])));"
                  "s.connect((sys.argv[1],int(sys.argv[2]))); s.send(b'ok'); assert s.recv(2)==b'ok'")
        result = subprocess.run(prefix + [sys.executable, "-c", script, target, str(port), str(int(udp)), str(int(ipv6)), str(source_port)],
                                capture_output=True, timeout=4)
        return result.returncode == 0

    def persistent(prefix):
        script = ("import socket,sys,json; s=socket.create_connection((sys.argv[1],22),timeout=2);"
                  "s.sendall(b'hi'); assert s.recv(2)==b'hi'; print(json.dumps(s.getsockname()),flush=True);"
                  "sys.stdin.readline(); s.sendall(b'ok'); assert s.recv(2)==b'ok'; print('PRESERVED',flush=True)")
        process = subprocess.Popen(prefix + [sys.executable, "-u", "-c", script, HOST], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        children.append(process)
        peer = json.loads(process.stdout.readline())
        return process, f"{peer[0]} {peer[1]} {HOST} 22"

    try:
        admin = namespace("adm", ADMIN + "/24", "fd77::1/64")
        other = namespace("oth", OTHER + "/24", "fd77::2/64")
        internal = namespace("lan", "10.123.0.2/24", routed=True)
        Path("/proc/sys/net/ipv4/ip_forward").write_text("1")
        for port in TCP_PORTS:
            listeners.append(Echo(port))
        for port in (22, 443):
            listeners.append(Echo(port, ipv6=True))
        for port in (53, 68, 51820):
            listeners.append(Echo(port, udp=True))
        internal_server = subprocess.Popen(internal + [sys.executable, "-u", "-c",
            "import socket; s=socket.socket(); s.bind(('0.0.0.0',5432)); s.listen(); print('READY',flush=True)\n"
            "while True:\n c,_=s.accept(); c.sendall(c.recv(2)); c.close()"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        children.append(internal_server)
        assert internal_server.stdout.readline().strip() == "READY"
        for port in TCP_PORTS:
            assert probe(other, port), f"negative fixture was not initially reachable: {port}"
        assert probe(admin, 5432, target="10.123.0.2"), "initial routed fixture was not reachable"
        with tempfile.TemporaryDirectory(prefix="uten-cloud-host-netns-") as temporary:
            root = Path(temporary)
            installed = root / "cloud_host_firewall.py"
            shutil.copyfile(ROOT / "cloud_host_firewall.py", installed)
            (root / "templates").mkdir()
            shutil.copyfile(ROOT / "templates/cloud-host-firewall.nft.tmpl", root / "templates/cloud-host-firewall.nft.tmpl")
            module = load(installed)
            module.HELPER = str(installed)
            module.NFT = nft
            module.SS = shutil.which("ss")
            # Both pre-existing tables survive every candidate and rollback.
            existing = ("table inet uten_remote {\n set sentinel {\n type inet_service\n elements = { 8443 }\n }\n"
                        " chain input {\n type filter hook input priority -10; policy accept;\n ct state established,related accept\n }\n}\n"
                        "table inet operator_existing {\n chain input {\n type filter hook input priority -5; policy accept;\n tcp dport 8080 accept\n }\n}\n")
            command([nft, "-f", "-"], input=existing)
            before_remote = command([nft, "list", "table", "inet", "uten_remote"]).stdout
            before_operator = command([nft, "list", "table", "inet", "operator_existing"]).stdout
            current_admin, old_connection = persistent(admin)
            prior_other, _ = persistent(other)

            class Manager:
                enabled = False
                timer_active = False
                preapply_connection = None
                preapply_process = None
                fail_postcapture = False

                def __call__(self, args, **kwargs):
                    if args[0] == module.SYSTEMD_RUN:
                        self.timer_active = True
                        if self.preapply_connection is None:
                            self.preapply_process, self.preapply_connection = persistent(admin)
                        return subprocess.CompletedProcess(args, 0, "", "")
                    if args[0] == module.SS and "all" in args and self.fail_postcapture:
                        return subprocess.CompletedProcess(args, 1, "", "test post-apply capture failure")
                    if args[0] == module.SYSTEMCTL:
                        op = args[1]
                        if op == "is-enabled":
                            return subprocess.CompletedProcess(args, 0 if self.enabled else 1, "enabled" if self.enabled else "disabled", "")
                        if op == "is-active":
                            return subprocess.CompletedProcess(args, 0 if self.timer_active else 4, "active" if self.timer_active else "unknown", "")
                        if op in {"enable", "disable"}:
                            self.enabled = op == "enable"
                        elif op == "stop":
                            self.timer_active = False
                        else:
                            raise AssertionError(args)
                        return subprocess.CompletedProcess(args, 0, "", "")
                    return subprocess.run(args, **kwargs)

            manager = Manager()
            controller = module.Controller(root / "state", manager)
            candidate = {"schema_version": 1, "role": "cloud", "public_interface": "eth-test", "dhcpv4": False,
                         "ssh_source_policy": "host-allowlist",
                         "admin_ipv4_cidrs": [ADMIN + "/32"], "wireguard_ipv4_cidrs": ["0.0.0.0/0"]}
            trial = controller.trial(candidate, old_connection, recovery_verified=True)
            assert not controller.active.exists() and manager.timer_active
            try:
                controller.confirm(trial["token"], manager.preapply_connection)
                raise AssertionError("a TCP connection created while the timer armed confirmed the new policy")
            except module.UnsafeChange:
                pass
            assert not controller.active.exists() and manager.timer_active
            assert probe(admin, 22) and probe(admin, 443) and probe(other, 443)
            assert not probe(other, 22), "unapproved NEW SSH remained reachable"
            for port in set(TCP_PORTS) - {22, 443}:
                assert not probe(admin, port) and not probe(other, port), f"unexpected public port: {port}"
            assert probe(other, 51820, udp=True)
            assert not probe(other, 53, udp=True)
            assert not probe(other, 68, udp=True, source_port=67), "DHCP was opened despite an explicit false policy"
            assert not probe(admin, 5432, target="10.123.0.2"), "host still routed traffic into the private fixture"
            assert probe([], 9087, target="127.0.0.1"), "loopback recovery/application traffic broke"
            assert not probe(admin, 22, target="fd77::10", ipv6=True)
            assert not probe(admin, 443, target="fd77::10", ipv6=True), "unaudited public IPv6 application ingress opened"
            neighbors = command(admin + ["ip", "-6", "neigh", "show"]).stdout
            assert "fd77::10" in neighbors and "FAILED" not in neighbors, "necessary IPv6 neighbor discovery broke"
            for process in (current_admin, prior_other, manager.preapply_process):
                output, error = process.communicate(input="continue\n", timeout=5)
                assert process.returncode == 0 and "PRESERVED" in output, error
            # Re-open an independently new management TCP connection after trial.
            second, new_connection = persistent(admin)
            assert controller.confirm(trial["token"], new_connection)["state"] == "CONFIRMED"
            assert manager.enabled and not manager.timer_active
            assert controller.boot()["state"] == "CONFIRMED_POLICY_LOADED"
            # Later-chain drop remains final even when this table accepts 443.
            command([nft, "-f", "-"], input="table inet later_operator_deny {\n chain input {\n type filter hook input priority 20; policy accept;\n tcp dport 443 drop\n }\n}\n")
            assert not probe(admin, 443)
            command([nft, "delete", "table", "inet", "later_operator_deny"])
            assert probe(admin, 443)
            confirmed = command([nft, "list", "table", "inet", module.TABLE]).stdout
            malformed = module.transaction(module.render_policy(candidate), True).replace("tcp dport 443", "tcp dport INVALID_PORT")
            failed = subprocess.run([nft, "-f", "-"], input=malformed, text=True, capture_output=True, timeout=10)
            assert failed.returncode != 0
            assert confirmed == command([nft, "list", "table", "inet", module.TABLE]).stdout, "failed batch partially deleted the live table"
            restrictive = {**candidate, "dhcpv4": True, "wireguard_ipv4_cidrs": [ADMIN + "/32"]}
            pending = controller.trial(restrictive, new_connection, recovery_verified=True)
            assert not probe(other, 51820, udp=True)
            assert probe(other, 68, udp=True, source_port=67), "reviewed DHCP reply traffic was blocked"
            # Independent timed process executes the actual rollback controller.
            # It shares this test namespace, not the WSL/runner host namespace.
            rollback_script = f"""
import importlib.util, subprocess, time
from pathlib import Path
spec=importlib.util.spec_from_file_location('rollback_fixture', {str(installed)!r})
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.NFT={nft!r}
def runner(args, **kw):
    if args[0]==m.SYSTEMCTL:
        return subprocess.CompletedProcess(args, 4 if args[1]=='is-active' else 0, 'unknown' if args[1]=='is-active' else '', '')
    return subprocess.run(args, **kw)
time.sleep(.3)
assert m.Controller(Path({str(controller.state)!r}),runner).rollback({pending['token']!r})['state']=='ROLLED_BACK'
"""
            rollback = subprocess.Popen([sys.executable, "-c", rollback_script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            children.append(rollback)
            _, error = rollback.communicate(timeout=10)
            assert rollback.returncode == 0, error
            assert probe(other, 51820, udp=True), "rollback did not recover prior WireGuard ingress"
            assert json.loads(controller.active.read_text())["policy"] == candidate
            assert before_remote == command([nft, "list", "table", "inet", "uten_remote"]).stdout
            assert before_operator == command([nft, "list", "table", "inet", "operator_existing"]).stdout
            # The alternative mode intentionally leaves SSH SOURCE enforcement
            # to the separately verified cloud security group. Its host layer
            # permits a different IPv4 management IP without a password/VNC.
            delegated = {**candidate, "ssh_source_policy": "security-group", "admin_ipv4_cidrs": []}
            delegated_trial = controller.trial(delegated, new_connection, security_group_console_verified=True)
            assert probe(other, 22), "SG-owned SSH mode accidentally retained an obsolete host /32"
            assert not probe(other, 5432), "delegating SSH opened an unrelated service"
            third, delegated_connection = persistent(admin)
            assert controller.confirm(delegated_trial["token"], delegated_connection)["state"] == "CONFIRMED"
            # A confirmed boot receipt is bound to exact rendered bytes and
            # the reviewed implementation. A mutable template cannot silently
            # remove SSH at the next start.
            bound_active = controller.active.read_bytes()
            bound_table = command([nft, "list", "table", "inet", module.TABLE]).stdout
            original_template = module.TEMPLATE.read_bytes()
            module.TEMPLATE.write_bytes(original_template.replace(b"@@SSH_RULE@@", b"# @@SSH_RULE@@"))
            try:
                controller.boot()
                raise AssertionError("an unreviewed boot template was accepted")
            except module.UnsafeChange:
                pass
            assert controller.active.read_bytes() == bound_active
            assert command([nft, "list", "table", "inet", module.TABLE]).stdout == bound_table
            module.TEMPLATE.write_bytes(original_template)
            assert controller.boot()["state"] == "CONFIRMED_POLICY_LOADED"

            manager.fail_postcapture = True
            try:
                controller.trial({**delegated, "dhcpv4": True}, delegated_connection,
                                 security_group_console_verified=True)
                raise AssertionError("failed post-apply TCP capture reported a successful trial")
            except module.UnsafeChange:
                pass
            failed_pending = json.loads(controller.pending.read_text())
            assert failed_pending["confirmation_ready"] is False and manager.timer_active
            assert controller.active.read_bytes() == bound_active
            manager.fail_postcapture = False
            fourth, failed_connection = persistent(admin)
            try:
                controller.confirm(failed_pending["token"], failed_connection)
                raise AssertionError("an incomplete trial was confirmed from a later valid TCP connection")
            except module.UnsafeChange:
                pass
            controller.rollback(failed_pending["token"])
            assert controller.active.read_bytes() == bound_active
            output, error = fourth.communicate(input="continue\n", timeout=5)
            assert fourth.returncode == 0 and "PRESERVED" in output, error
            output, error = third.communicate(input="continue\n", timeout=5)
            assert third.returncode == 0 and "PRESERVED" in output, error
            output, error = second.communicate(input="continue\n", timeout=5)
            assert second.returncode == 0 and "PRESERVED" in output, error
            print(json.dumps({"state": "CLOUD_HOST_NETNS_PASSED", "hostNetworkUntouched": True,
                              "approvedSSHAndHTTPSReachable": True, "hostAllowlistNewUnauthorizedSSHDenied": True,
                              "securityGroupModeDelegatesSSHSourceControl": True,
                              "existingConnectionsPreserved": True, "unneededPortsAndForwardingDenied": True,
                              "loopbackAndIPv6NeighborDiscoveryPreserved": True, "explicitDHCPPolicyVerified": True,
                              "otherTablesPreserved": True, "atomicFailurePreservedLiveTable": True,
                              "newTCPConfirmationVerified": True, "independentTimedRollbackExecuted": True,
                              "preapplyTCPRejected": True, "postApplyCaptureFailureUnconfirmable": True,
                              "confirmedBootTemplateDriftRejectedWithoutMutation": True,
                              "systemdManagerCommandsStubbed": True}))
    finally:
        for listener in listeners:
            listener.close()
        for child in children:
            if child.poll() is None:
                child.terminate()
            try:
                child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill(); child.communicate(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nft", required=True, type=Path)
    parser.add_argument("--inside", type=int)
    args = parser.parse_args()
    if os.name != "posix" or os.geteuid() != 0 or not args.nft.is_absolute():
        raise SystemExit("requires Linux root and an absolute trusted nft executable")
    if args.inside is None:
        # Docker deliberately makes its inherited /proc/sys read-only. A new
        # private mount namespace and proc mount let this fresh network
        # namespace configure forwarding without changing the container parent.
        result = command(["unshare", "--net", "--mount", "--mount-proc", "--", sys.executable, str(Path(__file__).resolve()),
                          "--nft", str(args.nft), "--inside", str(os.stat("/proc/self/ns/net").st_ino)], timeout=120)
        print(result.stdout, end="")
    else:
        inside(str(args.nft), args.inside)


if __name__ == "__main__":
    main()
