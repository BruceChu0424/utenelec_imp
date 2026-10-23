#!/usr/bin/env python3
"""Company-only Certbot DNS-01 hook for two fixed names in one AliDNS zone.

Uses the documented AliDNS RPC signature protocol over verified HTTPS. Credentials,
signatures, challenge values and provider response bodies are never logged.
"""
from __future__ import annotations
import base64
import datetime as dt
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ZONE = "justplayit.cn"
RECORDS = {ZONE: "_acme-challenge", "admin." + ZONE: "_acme-challenge.admin"}
CREDENTIALS = Path("/etc/uten-remote-ca/dns01.json")
STATE = Path("/var/lib/uten-remote-acme/challenges")
ACCOUNTS = Path("/etc/uten-remote-ca/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory")
ENDPOINT = "https://alidns.aliyuncs.com/"


def pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError("duplicate configuration property")
        result[key] = value
    return result


def secure_json(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077 or info.st_nlink != 1:
        raise ValueError("protected root-only regular configuration required")
    return json.loads(path.read_text(), object_pairs_hook=pairs)


def credentials():
    value = secure_json(CREDENTIALS)
    if set(value) != {"access_key_id", "access_key_secret"}:
        raise ValueError("unsupported credential configuration")
    for key, minimum in (("access_key_id", 16), ("access_key_secret", 24)):
        item = value[key]
        if not isinstance(item, str) or len(item) < minimum or not re.fullmatch(r"[A-Za-z0-9]+", item) \
                or any(marker in item.lower() for marker in ("replace", "changeme", "placeholder")):
            raise ValueError("non-placeholder credential required")
    return value


def encode(value):
    return urllib.parse.quote(str(value), safe="~")


def signed_parameters(values, secret, method="POST"):
    canonical = "&".join(encode(key) + "=" + encode(value) for key, value in sorted(values.items()))
    message = method + "&%2F&" + encode(canonical)
    signature = base64.b64encode(hmac.new((secret + "&").encode(), message.encode(), hashlib.sha1).digest()).decode()
    return dict(values, Signature=signature)


def api(action, **parameters):
    if action not in {"DescribeDomainRecords", "AddDomainRecord", "DeleteDomainRecord"}:
        raise ValueError("unsupported DNS operation")
    auth = credentials()
    values = {"Action": action, "Version": "2015-01-09", "Format": "JSON",
              "AccessKeyId": auth["access_key_id"], "SignatureMethod": "HMAC-SHA1", "SignatureVersion": "1.0",
              "SignatureNonce": str(uuid.uuid4()), "Timestamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), **parameters}
    body = urllib.parse.urlencode(signed_parameters(values, auth["access_key_secret"])).encode()
    request = urllib.request.Request(ENDPOINT, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
    except (OSError, urllib.error.HTTPError, ValueError):
        raise ValueError("DNS provider request failed") from None
    if not isinstance(result, dict) or "Code" in result:
        raise ValueError("DNS provider did not accept the restricted operation")
    return result


def records():
    result = []
    for page in range(1, 21):
        response = api("DescribeDomainRecords", DomainName=ZONE, PageSize=100, PageNumber=page)
        result.extend(response.get("DomainRecords", {}).get("Record", []))
        if len(result) >= int(response.get("TotalCount", 0)):
            return result
    raise ValueError("DNS inventory exceeds the bounded zone policy")


def identifier(environment):
    domain = environment.get("CERTBOT_IDENTIFIER") or environment.get("CERTBOT_DOMAIN")
    token = environment.get("CERTBOT_VALIDATION", "")
    if domain not in RECORDS or not re.fullmatch(r"[A-Za-z0-9_-]{20,128}", token):
        raise ValueError("DNS challenge is outside the fixed certificate names")
    return domain, token


def state_path(domain, token):
    return STATE / (hashlib.sha256((domain + "|" + token).encode()).hexdigest() + ".json")


def cleanup(domain, token):
    path = state_path(domain, token)
    if not path.exists():
        return
    saved = secure_json(path)
    found = [row for row in records() if str(row.get("RecordId")) == saved["recordId"]]
    if not found:
        path.unlink()
        return
    if len(found) != 1:
        raise ValueError("challenge record identity is ambiguous")
    current = found[0]
    if (current.get("DomainName"), current.get("RR"), current.get("Type"), current.get("Value")) != (ZONE, RECORDS[domain], "TXT", token):
        raise ValueError("challenge record changed; refusing an unrelated deletion")
    api("DeleteDomainRecord", RecordId=saved["recordId"])
    path.unlink()


def wait_for_dns(domain, token, timeout=300):
    def recursive(kind, name):
        # Public certificate names only. Do not depend on an unavailable local
        # stub listener, and do not change the host's resolver configuration.
        for resolver in ("223.5.5.5", "1.1.1.1"):
            result = subprocess.run(["/usr/bin/dig", "+short", "+time=3", "+tries=1", kind, name, "@" + resolver], capture_output=True, text=True, timeout=10)
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.split()
        raise ValueError("public authoritative DNS discovery failed")
    servers = [name.rstrip(".") for name in recursive("NS", ZONE)]
    if not servers or any(not re.fullmatch(r"[A-Za-z0-9.-]+", name) for name in servers):
        raise ValueError("authoritative DNS servers unavailable")
    addresses = []
    for server in servers:
        found = [value for value in recursive("A", server) if re.fullmatch(r"[0-9.]+", value)]
        if not found or any(not ipaddress.IPv4Address(value).is_global for value in found):
            raise ValueError("authoritative DNS address must be public")
        addresses.extend(found)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        observed = True
        for server in addresses:
            result = subprocess.run(["/usr/bin/dig", "+short", "+time=3", "+tries=1", "TXT", "_acme-challenge." + domain, "@" + server], capture_output=True, text=True, timeout=10)
            if result.returncode or token not in shlex.split(result.stdout):
                observed = False
                break
        if observed:
            return
        time.sleep(5)
    raise ValueError("DNS challenge did not propagate to every authoritative server")


def authenticate(domain, token):
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = state_path(domain, token)
    if not path.exists():
        matches = [row for row in records() if (row.get("RR"), row.get("Type"), row.get("Value")) == (RECORDS[domain], "TXT", token)]
        if len(matches) > 1:
            raise ValueError("challenge record inventory is ambiguous")
        record = matches[0]["RecordId"] if matches else api("AddDomainRecord", DomainName=ZONE, RR=RECORDS[domain], Type="TXT", Value=token, TTL=600)["RecordId"]
        path.write_text(json.dumps({"recordId": str(record)}))
        path.chmod(0o600)
    try:
        wait_for_dns(domain, token)
    except (OSError, ValueError, subprocess.SubprocessError):
        cleanup(domain, token)
        raise


def account_uri():
    paths = list(ACCOUNTS.glob("*/regr.json"))
    if len(paths) != 1:
        raise ValueError("one new company ACME account required")
    uri = json.loads(paths[0].read_text())["uri"]
    if not re.fullmatch(r"https://acme-v02\.api\.letsencrypt\.org/acme/acct/[1-9][0-9]{0,30}", uri):
        raise ValueError("production company ACME identity required")
    return uri


def ensure_caa():
    expected = {f'0 issue "letsencrypt.org;validationmethods=dns-01;accounturi={account_uri()}"', '0 issuewild ";"'}
    before = records()
    # Preserve every A/AAAA/MX/TXT record. Remove only conflicting issuance grants
    # at the two certificate names, after preserving the complete public zone snapshot.
    snapshot = STATE.parent / ("dns-before-caa-" + str(time.time_ns()) + ".json")
    snapshot.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    snapshot.write_text(json.dumps(before, indent=2)); snapshot.chmod(0o600)
    present = {row.get("Value") for row in before if row.get("Type") == "CAA" and row.get("RR") == "@"}
    # Publish the restrictive grants first. An interrupted operation must not
    # remove the last CAA restriction before the replacement exists.
    for value in sorted(expected - present):
        api("AddDomainRecord", DomainName=ZONE, RR="@", Type="CAA", Value=value, TTL=600)
    for row in before:
        if row.get("Type") != "CAA" or row.get("RR") not in ("@", "admin"):
            continue
        if row["RR"] == "@" and row.get("Value") in expected:
            continue
        elif re.match(r'^\s*[0-9]+\s+issue(?:wild)?\s+', row.get("Value", "")):
            api("DeleteDomainRecord", RecordId=row["RecordId"])
    after = records()
    issuance = {(r.get("RR"), r.get("Value")) for r in after if r.get("Type") == "CAA"
                and r.get("RR") in ("@", "admin") and re.match(r'^\s*[0-9]+\s+issue(?:wild)?\s+', r.get("Value", ""))}
    if issuance != {("@", value) for value in expected}:
        raise ValueError("CAA issuer inventory is not restricted to the company account")
    if sorted((r.get("RR"), r.get("Value")) for r in after if r.get("Type") == "A") != sorted((r.get("RR"), r.get("Value")) for r in before if r.get("Type") == "A"):
        raise ValueError("A record inventory changed concurrently; operator review required")
    return account_uri()


def main():
    try:
        if os.geteuid() != 0:
            raise ValueError("root-only company DNS operation")
        os.umask(0o077)
        if sys.argv[1:] == ["caa"]:
            print(json.dumps({"caaAccountUri": ensure_caa(), "zone": ZONE, "aRecordsPreserved": True}))
        elif sys.argv[1:] in (["auth"], ["cleanup"]):
            domain, token = identifier(os.environ)
            (authenticate if sys.argv[1] == "auth" else cleanup)(domain, token)
        else:
            raise ValueError("unsupported fixed DNS hook operation")
        return 0
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print("Restricted company DNS-01 operation failed; no credentials or provider response emitted.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
