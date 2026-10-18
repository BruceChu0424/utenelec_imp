#!/usr/bin/env python3
"""Real WireGuard and nft negative probes, ONLY in a disposable --network none container.

Creates two child network namespaces and veth links inside that container. A
deliberately compromised cloud peer adds a LAN route, then company forwarding
rules must still block it. No host network, Docker socket, production credentials
or published ports are used. Needs NET_ADMIN, SYS_ADMIN and ip_forward=1 in this
test container so the forwarding test cannot pass merely because routing is off.
"""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("contract", ROOT / "test_remote_access.py")
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


def run(args, *, input=None, check=True):
    result = subprocess.run(args, input=input, capture_output=True, text=True, timeout=10)
    if check and result.returncode:
        # Commands include paths/public topology, never private key values.
        raise AssertionError("isolated network command failed: " + args[0] + "\n" + result.stderr[:1000])
    return result


def ns(pid, args, **kwargs):
    return run(["nsenter", "-t", str(pid), "-n", "--", *args], **kwargs)


SERVER = """
import socket,sys,threading,time
def serve(port):
 s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('0.0.0.0',port)); s.listen()
 while True:
  c,a=s.accept(); c.sendall(b'isolated-test'); c.close()
for port in map(int,sys.argv[1:]): threading.Thread(target=serve,args=(port,),daemon=True).start()
time.sleep(300)
"""
CONNECT = "import socket,sys; s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=.7); assert s.recv(32)==b'isolated-test'; s.close()"


def reachable(pid, address, port):
    return ns(pid, ["python3", "-c", CONNECT, address, str(port)], check=False).returncode == 0


def main():
    if not Path("/.dockerenv").exists() or os.geteuid() != 0:
        raise SystemExit("Refusing outside the disposable root test container.")
    if Path("/proc/sys/net/ipv4/ip_forward").read_text().strip() != "1":
        raise SystemExit("Run test container with --sysctl net.ipv4.ip_forward=1.")
    children = []
    cloud = subprocess.Popen(["unshare", "--net", "--", "sleep", "300"])
    lan = subprocess.Popen(["unshare", "--net", "--", "sleep", "300"])
    children.extend([cloud, lan])
    try:
        time.sleep(.1)
        for process in (cloud, lan):
            assert process.poll() is None
            ns(process.pid, ["ip", "link", "set", "lo", "up"])
        run(["ip", "link", "add", "wan-test", "type", "veth", "peer", "name", "cloud-wan"])
        run(["ip", "link", "set", "cloud-wan", "netns", str(cloud.pid)])
        run(["ip", "addr", "add", "10.99.0.2/24", "dev", "wan-test"])
        run(["ip", "link", "set", "wan-test", "up"])
        ns(cloud.pid, ["ip", "addr", "add", "10.99.0.1/24", "dev", "cloud-wan"])
        ns(cloud.pid, ["ip", "link", "set", "cloud-wan", "up"])
        run(["ip", "link", "add", "company-lan", "type", "veth", "peer", "name", "lan-host"])
        run(["ip", "link", "set", "lan-host", "netns", str(lan.pid)])
        run(["ip", "addr", "add", "10.88.0.1/24", "dev", "company-lan"])
        run(["ip", "link", "set", "company-lan", "up"])
        ns(lan.pid, ["ip", "addr", "add", "10.88.0.2/24", "dev", "lan-host"])
        ns(lan.pid, ["ip", "link", "set", "lan-host", "up"])
        ns(lan.pid, ["ip", "route", "add", "10.77.0.1/32", "via", "10.88.0.1"])
        with tempfile.TemporaryDirectory(prefix="uten-wg-test-") as directory:
            directory = Path(directory)
            public = {}
            for role in ("cloud", "company"):
                private = run(["wg", "genkey"]).stdout
                path = directory / (role + ".key")
                path.write_text(private)
                path.chmod(0o600)
                public[role] = run(["wg", "pubkey"], input=private).stdout.strip()
            profile = contract.profile()
            profile["cloud_wireguard_public_key"] = public["cloud"]
            profile["company_wireguard_public_key"] = public["company"]
            rendered = contract.remote.files(profile)
            # Exercise the real private-key PostUp + peer-only route templates.
            for role in ("cloud", "company"):
                folder = directory / role
                folder.mkdir()
                configuration = rendered[f"{role}/wg-uten.conf"].replace(
                    "/etc/uten-remote/wireguard/private.key", str(directory / (role + ".key"))
                ).replace("8.8.8.8:51820", "10.99.0.1:51820")
                path = folder / "wg-uten.conf"
                path.write_text(configuration)
                path.chmod(0o600)
                if role == "cloud":
                    ns(cloud.pid, ["wg-quick", "up", str(path)])
                else:
                    run(["wg-quick", "up", str(path)])
            # Simulate root control of ECS: attacker expands only its own routes/AllowedIPs.
            # Company still accepts only the cloud source /32 but must deny forwarding.
            ns(cloud.pid, ["wg", "set", "wg-uten", "peer", public["company"], "allowed-ips", "10.77.0.2/32,10.88.0.0/24"])
            ns(cloud.pid, ["ip", "route", "add", "10.88.0.0/24", "dev", "wg-uten", "src", "10.77.0.1"])
            children.append(subprocess.Popen(["python3", "-c", SERVER, "22", "5432", "8080", "8443", "9443"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            children.append(subprocess.Popen(["nsenter", "-t", str(lan.pid), "-n", "--", "python3", "-c", SERVER, "5432"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            deadline = time.monotonic() + 8
            while not reachable(cloud.pid, "10.77.0.2", 8443):
                if time.monotonic() >= deadline:
                    raise AssertionError("real WireGuard baseline never became reachable")
                time.sleep(.1)
            # Prove the fixture can reach all prohibited services before enabling rules.
            assert all(reachable(cloud.pid, "10.77.0.2", port) for port in (22, 5432, 8080, 9443))
            assert reachable(cloud.pid, "10.88.0.2", 5432), "forwarding baseline is not working"
            content = contract.remote.files(contract.profile())["company/firewall.nft"]
            run(["nft", "-f", "-"], input=content)
            assert reachable(cloud.pid, "10.77.0.2", 8443)
            assert all(not reachable(cloud.pid, "10.77.0.2", port) for port in (22, 5432, 8080, 9443))
            assert not reachable(cloud.pid, "10.88.0.2", 5432), "compromised cloud forwarded into LAN"
            # Later input base chain emulates UFW default deny. Earlier accept is not final.
            run(["nft", "-f", "-"], input="""table inet simulated_ufw {
 chain input { type filter hook input priority 0; policy drop;
  iifname "lo" accept
  ct state established,related accept
  iifname "wan-test" ip saddr 10.99.0.1 udp dport 51820 accept
 }
}
""")
            assert not reachable(cloud.pid, "10.77.0.2", 8443), "later deny did not take effect"
            run(["nft", "add", "rule", "inet", "simulated_ufw", "input", "iifname", "wg-uten", "ip", "saddr", "10.77.0.1", "ip", "daddr", "10.77.0.2", "tcp", "dport", "8443", "accept"])
            assert reachable(cloud.pid, "10.77.0.2", 8443), "exact subsequent-chain allowance failed"
            assert all(not reachable(cloud.pid, "10.77.0.2", port) for port in (22, 5432, 8080, 9443))
            assert not reachable(cloud.pid, "10.88.0.2", 5432)
            print(json.dumps({"result": "PASS", "real_wireguard": True, "company_8443_allowed": True,
                              "company_22_5432_8080_9443_denied": True, "compromised_cloud_lan_forward_denied": True,
                              "later_default_deny_chain_requires_exact_allow": True,
                              "baseline_forbidden_ports_and_forwarding_were_reachable": True}))
    finally:
        for process in reversed(children):
            process.terminate()
        for process in children:
            process.wait(timeout=5)


if __name__ == "__main__":
    main()
