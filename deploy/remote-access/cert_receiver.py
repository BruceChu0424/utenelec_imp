#!/usr/bin/env python3
"""Forced-command DR certificate receiver. No shell, filenames, employee key or DNS access.

SSH identity may request only the existing admin-only CSR or publish a verified
public certificate chain matching the cloud's existing admin private key.
"""
from __future__ import annotations
import hashlib
import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

DOMAIN = "admin.justplayit.cn"
TLS = Path("/etc/uten-remote/tls")
SCRIPT = "/usr/local/lib/uten-remote/cert_receiver.py"
SAFE_ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/nonexistent", "LANG": "C.UTF-8"}
MAX_BYTES = 65536


def command(arguments, data=None):
    result = subprocess.run(arguments, input=data, capture_output=True, timeout=30, env=SAFE_ENV)
    if result.returncode:
        raise ValueError("certificate verification or dedicated gateway reload failed")
    return result.stdout


def exact_san(text):
    names = [name.strip() for name in text.strip().split(",")]
    if names != ["DNS:" + DOMAIN]:
        raise ValueError("certificate identity must contain only the independent DR name")


def csr_bytes():
    path = TLS / "dr.csr"
    raw, public = verify_csr_identity(path)
    local = command(["/usr/bin/openssl", "pkey", "-in", str(TLS / "dr.key"), "-pubout"])
    if public != local:
        raise ValueError("DR CSR does not match the locally held private key")
    return raw


def verify_csr_identity(path):
    raw = path.read_bytes()
    if len(raw) > MAX_BYTES:
        raise ValueError("CSR is oversized")
    command(["/usr/bin/openssl", "req", "-in", str(path), "-verify", "-noout"])
    text = command(["/usr/bin/openssl", "req", "-in", str(path), "-text", "-noout"]).decode()
    match = re.search(r"X509v3 Subject Alternative Name:\s*\n((?:[ \t]{16,}[^\n]+\n)+)", text)
    if not match:
        raise ValueError("explicit DR CSR subject alternative name required")
    exact_san(" ".join(match.group(1).split()))
    public = command(["/usr/bin/openssl", "req", "-in", str(path), "-pubkey", "-noout"])
    return raw, public


def split_chain(raw):
    if not raw or len(raw) > MAX_BYTES or b"PRIVATE KEY" in raw:
        raise ValueError("only a bounded public certificate chain is accepted")
    blocks = re.findall(rb"-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\s]+-----END CERTIFICATE-----", raw)
    remainder = raw
    for block in blocks:
        remainder = remainder.replace(block, b"", 1)
    if not 1 <= len(blocks) <= 6 or remainder.strip():
        raise ValueError("only PEM certificate blocks are accepted")
    return blocks


def publish(raw):
    blocks = split_chain(raw)
    with tempfile.TemporaryDirectory(prefix=".dr-cert-verify-", dir=TLS) as directory:
        directory = Path(directory)
        leaf, chain = directory / "leaf.pem", directory / "chain.pem"
        leaf.write_bytes(blocks[0] + b"\n")
        chain.write_bytes(b"\n".join(blocks[1:]) + b"\n")
        san = command(["/usr/bin/openssl", "x509", "-in", str(leaf), "-noout", "-ext", "subjectAltName"]).decode().splitlines()
        exact_san(" ".join(san[1:]))
        public = command(["/usr/bin/openssl", "x509", "-in", str(leaf), "-pubkey", "-noout"])
        expected = command(["/usr/bin/openssl", "pkey", "-in", str(TLS / "dr.key"), "-pubout"])
        if public != expected:
            raise ValueError("issued certificate does not match cloud DR key")
        args = ["/usr/bin/openssl", "verify", "-purpose", "sslserver", "-verify_hostname", DOMAIN]
        if len(blocks) > 1:
            args += ["-untrusted", str(chain)]
        command(args + [str(leaf)])  # OS public trust roots; no caller-provided CA.
        command(["/usr/bin/openssl", "x509", "-in", str(leaf), "-noout", "-checkend", "604800"])
        target = TLS / "dr-fullchain.crt"
        previous = target.read_bytes() if target.exists() else None
        staged = directory / "fullchain.pem"
        staged.write_bytes(b"\n".join(blocks) + b"\n")
        shutil.chown(staged, user="root", group="uten-remote"); staged.chmod(0o640)
        staged.replace(target)
        try:
            # ExecReload validates configuration as the real unprivileged
            # service identity before HUP. A root nginx -t would change cache ownership.
            command(["/usr/bin/systemctl", "reload", "uten-remote-nginx.service"])
        except ValueError:
            if previous is not None:
                staged.write_bytes(previous); shutil.chown(staged, user="root", group="uten-remote"); staged.chmod(0o640); staged.replace(target)
            raise
        receipt = {"domain": DOMAIN, "certificateSha256": hashlib.sha256(target.read_bytes()).hexdigest(), "publicChainVerified": True}
        (TLS / "dr-certificate-receipt.json").write_text(json.dumps(receipt) + "\n")
        print(json.dumps(receipt))


def publish_status(raw):
    if len(raw) > 8192:
        raise ValueError("bounded public TLS status required")
    value = json.loads(raw)
    if set(value) != {"schemaVersion", "updatedAt", "externalNotificationsConfigured", "employee", "dr"} \
            or value["schemaVersion"] != 1 or value["externalNotificationsConfigured"] is not False:
        raise ValueError("unsupported public TLS status schema")
    for name, domain in (("employee", "justplayit.cn"), ("dr", DOMAIN)):
        row = value[name]
        if set(row) != {"domain", "expiresAt", "lastSuccessAt", "lastFailureAt", "lastOutcome", "errorCode", "publicChainVerified"} \
                or row["domain"] != domain or row["lastOutcome"] not in ("NOT_ISSUED", "SUCCESS", "FAILED") \
                or type(row["publicChainVerified"]) is not bool or not re.fullmatch(r"[A-Z_]{0,64}", row["errorCode"]):
            raise ValueError("unsupported public TLS status value")
        for field in ("expiresAt", "lastSuccessAt", "lastFailureAt"):
            if row[field] is not None and (not isinstance(row[field], str) or len(row[field]) > 40 \
                    or dt.datetime.fromisoformat(row[field].replace("Z", "+00:00")).utcoffset() != dt.timedelta(0)):
                raise ValueError("explicit UTC certificate status required")
    if not isinstance(value["updatedAt"], str) or len(value["updatedAt"]) > 40 \
            or dt.datetime.fromisoformat(value["updatedAt"].replace("Z", "+00:00")).utcoffset() != dt.timedelta(0):
        raise ValueError("explicit UTC status freshness required")
    directory = Path("/var/lib/uten-remote-status")
    directory.mkdir(mode=0o755, exist_ok=True)
    if directory.is_symlink() or directory.stat().st_uid != 0 or directory.stat().st_mode & 0o022:
        raise ValueError("unsafe public TLS status directory")
    # The root helper runs with umask 077; the control service reads only these
    # deliberately public certificate metadata, never CA or private-key files.
    directory.chmod(0o755)
    temporary = directory / (".tls-" + str(os.getpid()) + ".json")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n"); temporary.chmod(0o644)
    temporary.replace(directory / "tls.json")
    print('{"publicTlsStatusStored":true}')


def operation(original):
    if original not in ("get-csr", "publish-cert", "publish-status"):
        raise ValueError("fixed certificate operation required")
    return original


def main():
    try:
        os.umask(0o077)
        if sys.argv[1:] == []:
            action = operation(os.environ.get("SSH_ORIGINAL_COMMAND", ""))
            return subprocess.call(["/usr/bin/sudo", "-n", "/usr/bin/python3", "-I", SCRIPT, "root", action], env=SAFE_ENV)
        if len(sys.argv) != 3 or sys.argv[1] != "root" or os.geteuid() != 0:
            raise ValueError("restricted root helper required")
        action = operation(sys.argv[2])
        if action == "get-csr":
            sys.stdout.buffer.write(csr_bytes())
        elif action == "publish-cert":
            publish(sys.stdin.buffer.read(MAX_BYTES + 1))
        else:
            publish_status(sys.stdin.buffer.read(8193))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Restricted DR certificate operation rejected.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
