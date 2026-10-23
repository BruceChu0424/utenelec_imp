#!/usr/bin/env python3
"""Company-owned employee ACME lifecycle and CSR-only independent DR certificates."""
from __future__ import annotations
import datetime as dt
import fcntl
import grp
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

BASE = Path("/etc/uten-remote-ca")
CONFIG = BASE / "letsencrypt"
WORK = Path("/var/lib/uten-remote-acme")
LOGS = Path("/var/log/uten-remote-acme")
CERTBOT = "/opt/uten-remote-acme/venv/bin/certbot"
DOMAIN = "justplayit.cn"
DR_DOMAIN = "admin.justplayit.cn"
TLS = Path("/etc/uten-remote/tls")
SAFE_ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/root", "LANG": "C.UTF-8"}


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def command(args, data=None, timeout=600):
    result = subprocess.run(args, input=data, capture_output=True, timeout=timeout, env=SAFE_ENV)
    with (LOGS / "renewal-operations.log").open("ab") as log:
        log.write(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError("REMOTE_TLS_OPERATION_FAILED")
    return result.stdout


def ssh(action, data=None):
    if action not in ("get-csr", "publish-cert", "publish-status"):
        raise ValueError("UNSUPPORTED_CERTIFICATE_OPERATION")
    return command(["/usr/bin/ssh", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                    "-o", "ForwardAgent=no", "-o", "ConnectTimeout=15", "-o", "UserKnownHostsFile=" + str(BASE / "cloud-known-hosts"),
                    "-i", str(BASE / "dr-cert-publish.key"), "uten-cert-receiver@218.244.155.87", action], data, timeout=60)


def expires(path):
    value = command(["/usr/bin/openssl", "x509", "-in", str(path), "-noout", "-enddate"]).decode().strip().partition("=")[2]
    return dt.datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc).isoformat()


def common():
    return [CERTBOT, "certonly", "--manual", "--preferred-challenges", "dns", "--non-interactive", "--agree-tos",
            "--config-dir", str(CONFIG), "--work-dir", str(WORK), "--logs-dir", str(LOGS),
            "--server", "https://acme-v02.api.letsencrypt.org/directory",
            "--manual-auth-hook", "/usr/bin/python3 -I /usr/local/lib/uten-remote/dns01_hook.py auth",
            "--manual-cleanup-hook", "/usr/bin/python3 -I /usr/local/lib/uten-remote/dns01_hook.py cleanup"]


def install_employee():
    source = CONFIG / "live/uten-erp-employee"
    # The lineage must be exactly the employee name; no key is ever sent to cloud.
    text = command(["/usr/bin/openssl", "x509", "-in", str(source / "fullchain.pem"), "-noout", "-ext", "subjectAltName"]).decode().splitlines()
    if " ".join(text[1:]).strip() != "DNS:" + DOMAIN:
        raise ValueError("EMPLOYEE_CERTIFICATE_IDENTITY_INVALID")
    command(["/usr/bin/openssl", "verify", "-purpose", "sslserver", "-verify_hostname", DOMAIN,
             "-untrusted", str(source / "chain.pem"), str(source / "cert.pem")])
    command(["/usr/bin/openssl", "x509", "-in", str(source / "cert.pem"), "-noout", "-checkend", "604800"])
    previous = {name: (TLS / name).read_bytes() if (TLS / name).exists() else None for name in ("employee-fullchain.crt", "employee.key")}
    gid = grp.getgrnam("uten-remote").gr_gid
    try:
        for origin, target in (("fullchain.pem", "employee-fullchain.crt"), ("privkey.pem", "employee.key")):
            candidate = TLS / ("." + target + ".new")
            candidate.write_bytes((source / origin).read_bytes()); os.chown(candidate, 0, gid); candidate.chmod(0o640); candidate.replace(TLS / target)
        # The unit's first ExecReload performs nginx -t as uten-remote, then HUP.
        command(["/usr/bin/systemctl", "reload", "uten-remote-nginx.service"])
    except ValueError:
        for name, raw in previous.items():
            if raw is not None:
                path = TLS / ("." + name + ".rollback"); path.write_bytes(raw); os.chown(path, 0, gid); path.chmod(0o640); path.replace(TLS / name)
        raise


def employee():
    lineage = CONFIG / "live/uten-erp-employee/fullchain.pem"
    previous = lineage.read_bytes() if lineage.exists() else None
    if lineage.exists():
        command([CERTBOT, "renew", "--cert-name", "uten-erp-employee", "--non-interactive", "--config-dir", str(CONFIG),
                 "--work-dir", str(WORK), "--logs-dir", str(LOGS)])
    else:
        command(common() + ["--cert-name", "uten-erp-employee", "-d", DOMAIN, "--key-type", "ecdsa"])
    install_employee()
    return expires(lineage), previous != lineage.read_bytes()


def dr():
    receiver = module("cert_receiver")
    current = WORK / "dr-current-fullchain.pem"
    if current.exists() and subprocess.run(["/usr/bin/openssl", "x509", "-in", str(current), "-noout", "-checkend", "2592000"], env=SAFE_ENV, capture_output=True).returncode == 0:
        # Reconcile the fixed remote destination after a lost publish response or
        # restore; do not assume a local cached chain is still installed on cloud.
        ssh("publish-cert", current.read_bytes())
        return expires(current), False
    folder = WORK / ("dr-issue-" + str(time.time_ns())); folder.mkdir(mode=0o700)
    csr = folder / "admin.csr"; csr.write_bytes(ssh("get-csr")); csr.chmod(0o600)
    receiver.verify_csr_identity(csr)
    fullchain = folder / "fullchain.pem"
    command(common() + ["--csr", str(csr), "--cert-path", str(folder / "cert.pem"), "--chain-path", str(folder / "chain.pem"), "--fullchain-path", str(fullchain)])
    raw = fullchain.read_bytes(); receiver.split_chain(raw)
    receipt = json.loads(ssh("publish-cert", raw))
    expected = hashlib.sha256(b"\n".join(receiver.split_chain(raw)) + b"\n").hexdigest()
    if not receipt.get("publicChainVerified") or receipt.get("certificateSha256") != expected:
        raise ValueError("CLOUD_CERTIFICATE_RECEIPT_INVALID")
    current.write_bytes(raw); current.chmod(0o600)
    return expires(current), True


def state():
    path = WORK / "tls-status.json"
    if path.exists():
        return json.loads(path.read_text())
    return {"schemaVersion": 1, "updatedAt": utc(), "externalNotificationsConfigured": False,
            **{key: {"domain": domain, "expiresAt": None, "lastSuccessAt": None, "lastFailureAt": None,
                     "lastOutcome": "NOT_ISSUED", "errorCode": "", "publicChainVerified": False}
               for key, domain in (("employee", DOMAIN), ("dr", DR_DOMAIN))}}


def save_state(snapshot):
    temporary = WORK / (".tls-status-" + str(os.getpid()) + ".json")
    with temporary.open("w") as output:
        json.dump(snapshot, output, indent=2)
        output.flush(); os.fsync(output.fileno())
    temporary.chmod(0o600)
    temporary.replace(WORK / "tls-status.json")


def transport_certificates_current():
    # These are public leaf certificates retained at the company CA. Rotation
    # stays a company-authorized operation; the cloud never receives CA keys.
    records = []
    for role, path in (("companyTransport", TLS / "transport-server.crt"),
                       ("cloudClient", BASE / "cloud-client.crt")):
        expiry = expires(path)
        remaining = (dt.datetime.fromisoformat(expiry) - dt.datetime.now(dt.timezone.utc)).total_seconds() / 86400
        outcome = "EXPIRED" if remaining <= 0 else "DUE_7_DAYS" if remaining <= 7 else "DUE_14_DAYS" if remaining <= 14 else "DUE_30_DAYS" if remaining <= 30 else "CURRENT"
        records.append({"role": role, "expiresAt": expiry, "daysRemaining": int(remaining), "status": outcome})
    temporary = WORK / (".transport-status-" + str(os.getpid()) + ".json")
    temporary.write_text(json.dumps({"checkedAt": utc(), "certificates": records}, indent=2)); temporary.chmod(0o600)
    temporary.replace(WORK / "transport-status.json")
    current = all(row["status"] == "CURRENT" for row in records)
    if not current:
        print("Machine TLS certificate rotation is due; inspect company-only transport-status.json.", file=sys.stderr)
    return current


def main():
    try:
        if os.geteuid() != 0 or sys.argv[1:] not in ([], ["renew"], ["install-employee"]):
            raise ValueError("ROOT_FIXED_TLS_OPERATION_REQUIRED")
        os.umask(0o077)
        WORK.mkdir(mode=0o700, exist_ok=True); LOGS.mkdir(mode=0o700, exist_ok=True)
        if sys.argv[1:] == ["install-employee"]:
            install_employee(); return 0
        with (WORK / "renewal.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            snapshot = state(); failed = False
            try:
                failed = not transport_certificates_current()
            except (OSError, ValueError, subprocess.SubprocessError):
                failed = True
                print("Machine TLS certificate expiry verification failed.", file=sys.stderr)
            try:
                module("dns01_hook").ensure_caa()
            except (OSError, ValueError, subprocess.SubprocessError):
                for name in ("employee", "dr"):
                    snapshot[name].update(lastFailureAt=utc(), lastOutcome="FAILED", errorCode="DNS_POLICY_NOT_READY")
                snapshot["updatedAt"] = utc(); save_state(snapshot)
                ssh("publish-status", json.dumps(snapshot).encode())
                return 1
            for name, action in (("employee", employee), ("dr", dr)):
                try:
                    expiry, renewed = action()
                    snapshot[name].update(expiresAt=expiry, lastOutcome="SUCCESS", errorCode="", publicChainVerified=True)
                    if renewed:
                        snapshot[name]["lastSuccessAt"] = utc()
                except (OSError, ValueError, subprocess.SubprocessError):
                    snapshot[name].update(lastFailureAt=utc(), lastOutcome="FAILED", errorCode="CERTIFICATE_RENEWAL_FAILED")
                    failed = True
                snapshot["updatedAt"] = utc(); save_state(snapshot)
            ssh("publish-status", json.dumps(snapshot).encode())
            return 1 if failed else 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Company-owned remote certificate lifecycle failed; protected status/logs retained.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
