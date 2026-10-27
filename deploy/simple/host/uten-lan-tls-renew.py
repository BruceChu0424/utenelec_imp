#!/usr/bin/env python3
"""Renew only the reviewed office HTTPS identity, using a constrained issuer.

The root private key is neither required nor accessible to the systemd service.
Certificate contents and status are public metadata; private keys never leave
their existing root-only files. Only Nginx is gracefully reloaded.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import ssl
import stat
import subprocess
import tempfile
import time

ROOT = Path('/usr/local/share/ca-certificates/uten-imp-root-ca.crt')
ISSUER = Path('/etc/uten-lan-tls/issuer.crt')
ISSUER_KEY = Path('/etc/uten-lan-tls/issuer.key')
CERT = Path('/etc/ssl/certs/uten-imp-lan.crt')
KEY = Path('/etc/ssl/private/uten-imp-lan.key')
STATE = Path('/var/lib/uten-lan-tls')
OPENSSL = '/usr/bin/openssl'
NGINX = '/usr/sbin/nginx'
SYSTEMCTL = '/usr/bin/systemctl'
ROOT_SHA256 = 'E7945DE9BD75A272E04EF77F9A14538AB42C97A63A71B67FE66C12A123406994'
DNS_NAMES = ('imp.utenelec', 'erp.utenelec.lan', 'utenelec-imp-server')
# Render from the reviewed site identity before installation. Repository copies
# deliberately contain no production network address.
IP_ADDRESS = '__LAN_IP_ADDRESS__'
RENEW_SECONDS = 30 * 86400
ISSUER_MIN_SECONDS = 400 * 86400
CERT_DAYS = 365


class RenewalError(RuntimeError):
    pass


class RenewalTerminated(RenewalError):
    pass


def terminate_renewal(_signal: int, _frame) -> None:
    # Raising inside renew() reaches its certificate rollback transaction.
    # KeyboardInterrupt/SystemExit remain untouched.
    raise RenewalTerminated('renewal termination requested')


def command(args: list[str], *, input: bytes | None = None) -> bytes:
    result = subprocess.run(args, input=input, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=45, check=False)
    if result.returncode:
        # Do not echo command output; provider errors may contain sensitive data.
        raise RenewalError(f'{Path(args[0]).name} operation failed ({result.returncode})')
    return result.stdout


def x509(path: Path, *args: str) -> str:
    return command([OPENSSL, 'x509', '-in', str(path), '-noout', *args]).decode('ascii')


def expires(path: Path) -> dt.datetime:
    value = x509(path, '-enddate').strip().split('=', 1)[1]
    return dt.datetime.strptime(value, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=dt.timezone.utc)


def remaining(path: Path) -> float:
    return (expires(path) - dt.datetime.now(dt.timezone.utc)).total_seconds()


def fingerprint(path: Path) -> str:
    der = command([OPENSSL, 'x509', '-in', str(path), '-outform', 'DER'])
    return hashlib.sha256(der).hexdigest().upper()


def private_file(path: Path) -> None:
    mode = path.lstat()
    if not stat.S_ISREG(mode.st_mode) or mode.st_uid != 0 or mode.st_mode & 0o077:
        raise RenewalError('private key must be a root-owned regular file with mode 0600')


def ensure_inputs() -> None:
    try:
        reviewed_ip = ipaddress.IPv4Address(IP_ADDRESS)
    except ipaddress.AddressValueError as error:
        raise RenewalError('render one reviewed office IPv4 address before installation') from error
    if str(reviewed_ip) != IP_ADDRESS or reviewed_ip.is_loopback or reviewed_ip.is_multicast or reviewed_ip.is_unspecified:
        raise RenewalError('render one canonical office IPv4 address before installation')
    for path in (ROOT, ISSUER, CERT):
        mode = path.lstat()
        if not stat.S_ISREG(mode.st_mode) or mode.st_uid != 0 or mode.st_mode & 0o022:
            raise RenewalError('certificate input must be root-owned and not writable by others')
    private_file(KEY)
    private_file(ISSUER_KEY)
    if fingerprint(ROOT) != ROOT_SHA256:
        raise RenewalError('internal root fingerprint differs from reviewed authority')
    command([OPENSSL, 'verify', '-CAfile', str(ROOT), str(ISSUER)])
    if remaining(ROOT) < ISSUER_MIN_SECONDS or remaining(ISSUER) < ISSUER_MIN_SECONDS:
        raise RenewalError('root or constrained issuer expires within 400 days; renew the issuer under administrator control')
    constraints = x509(ISSUER, '-ext', 'basicConstraints')
    if 'critical' not in constraints or 'CA:TRUE, pathlen:0' not in constraints:
        raise RenewalError('issuer must have critical CA TRUE with pathlen zero')
    constraints = x509(ISSUER, '-ext', 'nameConstraints')
    # Dart's BoringSSL rejects IP nameConstraints. Constrain issuer DNS names;
    # this root-owned fixed signer and validate_leaf enforce the exact reviewed
    # IP SAN. Refuse legacy IP constraints instead of shipping an unusable chain.
    expected = {f'DNS:{name}' for name in DNS_NAMES}
    actual = {line.strip() for line in constraints.splitlines()[2:] if line.strip() != 'Permitted:'}
    if 'critical' not in constraints or actual != expected:
        raise RenewalError('issuer name constraints differ from reviewed office identity')
    public_key = command([OPENSSL, 'x509', '-in', str(ISSUER), '-pubkey', '-noout'])
    actual_key = command([OPENSSL, 'pkey', '-in', str(ISSUER_KEY), '-pubout'])
    if public_key != actual_key:
        raise RenewalError('issuer certificate and private key do not match')


def validate_leaf(path: Path) -> None:
    command([OPENSSL, 'verify', '-CAfile', str(ROOT), '-untrusted', str(ISSUER),
             '-purpose', 'sslserver', '-verify_ip', IP_ADDRESS, str(path)])
    actual = set(re.findall(r'(DNS:[^,\s]+|IP Address:[^,\s]+)', x509(path, '-ext', 'subjectAltName')))
    expected = {f'DNS:{name}' for name in DNS_NAMES} | {f'IP Address:{IP_ADDRESS}'}
    if actual != expected:
        raise RenewalError('leaf SAN differs from reviewed office identity')
    if 'CA:FALSE' not in x509(path, '-ext', 'basicConstraints'):
        raise RenewalError('server certificate must not be a CA')
    public_key = command([OPENSSL, 'x509', '-in', str(path), '-pubkey', '-noout'])
    actual_key = command([OPENSSL, 'pkey', '-in', str(KEY), '-pubout'])
    if public_key != actual_key:
        raise RenewalError('server certificate and existing private key do not match')


def atomic_write(path: Path, content: bytes, mode: int) -> None:
    descriptor, name = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def verify_served(expected: str) -> None:
    context = ssl.create_default_context(cafile=str(ROOT))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    last_error: Exception | None = None
    # Graceful reload can briefly leave a worker accepting with the old context.
    for _ in range(12):
        try:
            with socket.create_connection(('127.0.0.1', 443), timeout=4) as connection:
                with context.wrap_socket(connection, server_hostname=IP_ADDRESS) as secured:
                    if hashlib.sha256(secured.getpeercert(binary_form=True)).hexdigest().upper() == expected:
                        return
                    last_error = RenewalError('served leaf does not yet match the installed certificate')
        except (OSError, ssl.SSLError) as error:
            last_error = error
        time.sleep(0.5)
    raise RenewalError('live office HTTPS certificate verification failed') from last_error


def issue(directory: Path) -> Path:
    config = directory / 'leaf.ext'
    config.write_text('basicConstraints=critical,CA:FALSE\n'
                      'keyUsage=critical,digitalSignature,keyEncipherment\n'
                      'extendedKeyUsage=serverAuth\n'
                      'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
                      'subjectAltName=' + ','.join(f'DNS:{name}' for name in DNS_NAMES)
                      + f',IP:{IP_ADDRESS}\n', encoding='ascii')
    csr, leaf = directory / 'leaf.csr', directory / 'leaf.crt'
    command([OPENSSL, 'req', '-new', '-sha256', '-key', str(KEY),
             '-subj', '/C=CN/O=UtenElec/CN=imp.utenelec', '-out', str(csr)])
    command([OPENSSL, 'x509', '-req', '-in', str(csr), '-CA', str(ISSUER),
             '-CAkey', str(ISSUER_KEY), '-set_serial', '0x' + secrets.token_hex(16),
             '-days', str(CERT_DAYS), '-sha256', '-extfile', str(config), '-out', str(leaf)])
    validate_leaf(leaf)
    if remaining(leaf) < (CERT_DAYS - 1) * 86400:
        raise RenewalError('new certificate validity is unexpectedly short')
    return leaf


def renew(force: bool = False, check_only: bool = False) -> dict:
    ensure_inputs()
    # The old certificate may be expired; only a new candidate must validate now.
    # A healthy leaf is fully verified before skipping a renewal.
    if check_only or (not force and remaining(CERT) > RENEW_SECONDS):
        validate_leaf(CERT)
        result = 'checked'
        try:
            verify_served(fingerprint(CERT))
        except RenewalTerminated:
            raise
        except RenewalError:
            if check_only:
                raise
            # Recover a previous process/power interruption after atomic file
            # installation and before graceful reload, without another signing.
            command([NGINX, '-t'])
            command([SYSTEMCTL, 'reload', 'nginx.service'])
            verify_served(fingerprint(CERT))
            result = 'reloaded'
        return {'result': result, 'renewed': False, 'notAfter': expires(CERT).isoformat(),
                'certificateSha256': fingerprint(CERT), 'servedVerified': True}
    old = CERT.read_bytes()
    old_fingerprint = fingerprint(CERT)
    atomic_write(STATE / 'previous-fullchain.crt', old, 0o600)
    installed = False
    try:
        with tempfile.TemporaryDirectory(prefix='issue-', dir=STATE) as temporary:
            leaf = issue(Path(temporary))
            candidate = leaf.read_bytes().rstrip() + b'\n' + ISSUER.read_bytes().strip() + b'\n'
            # Mark before replace so a termination after os.replace but before
            # fsync/return also enters rollback with the captured preimage.
            installed = True
            atomic_write(CERT, candidate, 0o644)
            command([NGINX, '-t'])
            command([SYSTEMCTL, 'reload', 'nginx.service'])
            verify_served(fingerprint(CERT))
    except Exception as error:
        if installed:
            atomic_write(CERT, old, 0o644)
            try:
                command([NGINX, '-t'])
                command([SYSTEMCTL, 'reload', 'nginx.service'])
                # If the old leaf is expired the rollback remains necessary,
                # but its expiry must not hide the original renewal failure.
                if remaining(CERT) > 0:
                    verify_served(old_fingerprint)
            except Exception as rollback_error:
                raise RenewalError('renewal failed; old certificate restored but Nginx rollback needs administrator attention') from rollback_error
        raise RenewalError('renewal failed; previous certificate retained or restored') from error
    return {'result': 'renewed', 'renewed': True, 'notAfter': expires(CERT).isoformat(),
            'certificateSha256': fingerprint(CERT), 'servedVerified': True}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument('--force', action='store_true')
    choice.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    if os.geteuid() != 0:
        print('Run the fixed renewal service as root.')
        return 1
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    mode = STATE.lstat()
    if not stat.S_ISDIR(mode.st_mode) or mode.st_uid != 0 or mode.st_mode & 0o077:
        print('Renewal state directory ownership or mode is invalid.')
        return 1
    with (STATE / 'renewal.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        history = {}
        try:
            previous = json.loads((STATE / 'status.json').read_text(encoding='utf-8'))
            for field in ('lastSuccessAt', 'lastRenewedAt'):
                value = previous.get(field)
                if isinstance(value, str) and len(value) <= 50:
                    history[field] = value
        except (OSError, ValueError, AttributeError):
            pass
        try:
            previous_handler = signal.signal(signal.SIGTERM, terminate_renewal)
            try:
                status = renew(force=args.force, check_only=args.check_only)
            finally:
                signal.signal(signal.SIGTERM, previous_handler)
            status.update(history)
            status.update({'schemaVersion': 1, 'lastCheckAt': now, 'lastSuccessAt': now,
                           'rootNotAfter': expires(ROOT).isoformat(),
                           'issuerNotAfter': expires(ISSUER).isoformat(), 'renewBeforeDays': 30})
            if status['renewed']:
                status['lastRenewedAt'] = now
            atomic_write(STATE / 'status.json', (json.dumps(status, sort_keys=True) + '\n').encode(), 0o600)
            print(json.dumps(status, sort_keys=True))
            return 0
        except Exception as error:
            # Exception text is from fixed local operations and never provider output.
            status = {'schemaVersion': 1, 'result': 'failed', 'lastCheckAt': now,
                      'error': str(error) if isinstance(error, RenewalError) else type(error).__name__}
            status.update(history)
            atomic_write(STATE / 'status.json', (json.dumps(status, sort_keys=True) + '\n').encode(), 0o600)
            print(json.dumps(status, sort_keys=True))
            return 1


if __name__ == '__main__':
    raise SystemExit(main())
