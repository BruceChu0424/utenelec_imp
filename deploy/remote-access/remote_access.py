#!/usr/bin/env python3
"""Render the one-app remote transport without reading, generating or printing secrets.

No command in this module contacts a server or installs a configuration. Unknown
fields (including inline credentials) fail closed. Output is a new directory.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import ipaddress
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent
FIELDS = {
    "schema_version", "public_domain", "transport_server_name", "cloud_public_ipv4",
    "cloud_wireguard_ipv4", "company_wireguard_ipv4", "cloud_wireguard_public_key",
    "company_wireguard_public_key", "admin_ipv4_cidr", "acme_account_uri",
    "remote_backend_port",
}
OPTIONAL_FIELDS = {"cloud_nginx_stream_module", "company_nginx_stream_module", "dr_public_domain"}
COMMISSIONING_FIELDS = FIELDS - {"public_domain", "acme_account_uri", "remote_backend_port"}
STREAM_MODULE_PATHS = {
    "/usr/lib/nginx/modules/ngx_stream_module.so",
    "/usr/lib64/nginx/modules/ngx_stream_module.so",
    "builtin",
}
RFC1918 = tuple(ipaddress.ip_network(v) for v in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
DNS = re.compile(r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")


class InvalidProfile(ValueError):
    pass


def fail(field: str, message: str) -> None:
    # Never echo an input value: an operator might accidentally paste a secret.
    raise InvalidProfile(f"{field}: {message}")


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidProfile("profile: duplicate JSON property")
        result[key] = value
    return result


def load_profile(path: Path, *, commissioning_only: bool = False) -> dict:
    try:
        if path.stat().st_size > 16384:
            raise InvalidProfile("profile: exceeds 16 KiB")
        data = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_pairs)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise InvalidProfile("profile: cannot read valid UTF-8 JSON") from exc
    return validate(data, commissioning_only=commissioning_only)


def validate(data: object, *, commissioning_only: bool = False) -> dict:
    required = COMMISSIONING_FIELDS if commissioning_only else FIELDS
    if (not isinstance(data, dict) or not required.issubset(data)
            or not set(data).issubset(required | OPTIONAL_FIELDS)):
        raise InvalidProfile("profile: missing or unsupported properties; credentials are not accepted")
    if type(data["schema_version"]) is not int or data["schema_version"] != 1:
        fail("schema_version", "must be 1")
    for field in required - {"schema_version", "remote_backend_port"}:
        if not isinstance(data[field], str) or not data[field] or len(data[field]) > 253:
            fail(field, "must be a bounded non-empty string")
    for field in (("transport_server_name",) if commissioning_only else ("public_domain", "transport_server_name")):
        if not DNS.fullmatch(data[field]):
            fail(field, "must be a lowercase ASCII DNS name, without URLs or directives")
    if not commissioning_only and data["public_domain"] == data["transport_server_name"]:
        fail("transport_server_name", "must differ from the employee TLS name")
    for field in ("cloud_public_ipv4", "cloud_wireguard_ipv4", "company_wireguard_ipv4"):
        try:
            address = ipaddress.IPv4Address(data[field])
        except ipaddress.AddressValueError:
            fail(field, "must be an IPv4 address")
        if field == "cloud_public_ipv4":
            if not address.is_global:
                fail(field, "must be a public EIP; example/documentation addresses are not deployable")
        elif not any(address in network for network in RFC1918):
            fail(field, "must be a private RFC1918 host address")
    if data["cloud_wireguard_ipv4"] == data["company_wireguard_ipv4"]:
        fail("company_wireguard_ipv4", "must differ from cloud host")
    for field in ("cloud_wireguard_public_key", "company_wireguard_public_key"):
        try:
            decoded = base64.b64decode(data[field], validate=True)
        except (ValueError, binascii.Error):
            fail(field, "must be a canonical WireGuard public key")
        if len(decoded) != 32 or not any(decoded) or base64.b64encode(decoded).decode() != data[field]:
            fail(field, "must be a nonzero 32-byte canonical public key")
    if data["cloud_wireguard_public_key"] == data["company_wireguard_public_key"]:
        fail("company_wireguard_public_key", "must differ from cloud public key")
    try:
        admin = ipaddress.IPv4Network(data["admin_ipv4_cidr"], strict=True)
    except ValueError:
        fail("admin_ipv4_cidr", "must be a single public IPv4 /32")
    if admin.prefixlen != 32 or not admin.network_address.is_global:
        fail("admin_ipv4_cidr", "must be a single public IPv4 /32; never open SSH to all")
    if not commissioning_only and not re.fullmatch(r"https://acme-v02\.api\.letsencrypt\.org/acme/acct/[1-9][0-9]{0,30}", data["acme_account_uri"]):
        fail("acme_account_uri", "must identify the company-held production ACME account")
    if not commissioning_only and (type(data["remote_backend_port"]) is not int or data["remote_backend_port"] != 8082):
        fail("remote_backend_port", "this deployment contract requires the loopback-only 8082 connector")
    result = dict(data)
    for field in OPTIONAL_FIELDS - {"dr_public_domain"}:
        value = data.get(field, "/usr/lib/nginx/modules/ngx_stream_module.so")
        if not isinstance(value, str) or value not in STREAM_MODULE_PATHS:
            fail(field, "must be a supported distribution module path or verified builtin")
        result[field] = value
    if "dr_public_domain" in data:
        domain = data["dr_public_domain"]
        if not isinstance(domain, str) or not DNS.fullmatch(domain) \
                or domain in (data.get("public_domain"), data["transport_server_name"]):
            fail("dr_public_domain", "must be a distinct lowercase DNS name")
        result["dr_public_domain"] = domain
    return result


def template(name: str, values: dict) -> str:
    content = (ROOT / "templates" / name).read_text(encoding="utf-8")
    for key, value in values.items():
        content = content.replace("@@" + key.upper() + "@@", str(value))
    if re.search(r"@@[A-Z_]+@@", content):
        raise InvalidProfile("template: unresolved substitution")
    return content


def files(profile: dict, *, commissioning_only: bool = False) -> dict[str, str]:
    p = validate(profile, commissioning_only=commissioning_only)
    if commissioning_only:
        # This reserved name can never be mistaken for an approved public employee domain.
        # The operator must supply a private test certificate and keep remote policy OFF.
        p.update(public_domain="remote-commissioning.invalid", remote_backend_port=8082)
    output = {}
    for role, own, peer in (("cloud", "cloud", "company"), ("company", "company", "cloud")):
        values = dict(p, role=role, own_wireguard_ipv4=p[own + "_wireguard_ipv4"],
                      peer_wireguard_ipv4=p[peer + "_wireguard_ipv4"],
                      peer_wireguard_public_key=p[peer + "_wireguard_public_key"])
        values["wireguard_endpoint"] = (
            f"Endpoint = {p['cloud_public_ipv4']}:51820\nPersistentKeepalive = 25"
            if role == "company" else "# The company peer initiates; its roaming endpoint is learned."
        )
        values["nginx_capability"] = "CAP_NET_BIND_SERVICE" if role == "cloud" else ""
        values["nginx_cpu_quota"] = "150%" if role == "cloud" else "100%"
        values["nginx_allowed_ip"] = p[peer + "_wireguard_ipv4"]
        values["cloud_ipaddress_allow"] = "IPAddressAllow=0.0.0.0/0" if role == "cloud" else ""
        # Reuse the existing release publisher's public-Web-only read group.
        # The account itself never joins the application/database/backup groups.
        values["company_web_group"] = "SupplementaryGroups=uten-web" if role == "company" else ""
        dr_enabled = "dr_public_domain" in p
        values["dr_sni_route"] = (f"        {p['dr_public_domain']} 127.0.0.1:19443;" if dr_enabled else "")
        values["dr_gateway_block"] = template("dr-gateway.conf.tmpl", values) if role == "cloud" and dr_enabled else ""
        values["cloud_loopback_rules"] = (
            '        meta skuid "uten-remote" ip daddr 127.0.0.1 tcp dport { 15443, 19443, 9087 } accept'
            if dr_enabled else '        meta skuid "uten-remote" ip daddr 127.0.0.1 tcp dport 15443 accept'
        )
        stream_module = p[role + "_nginx_stream_module"]
        values["stream_module_directive"] = (
            "# Stream module is built into the verified Nginx binary."
            if stream_module == "builtin" else f"load_module {stream_module};"
        )
        for source, target in ((role + "-nginx.conf.tmpl", "nginx.conf"),
                               (role + "-firewall.nft.tmpl", "firewall.nft"),
                               ("wg-uten.conf.tmpl", "wg-uten.conf"),
                               ("uten-remote-nginx.service.tmpl", "uten-remote-nginx.service")):
            output[f"{role}/{target}"] = template(source, values)
        for source in ("uten-remote-firewall.service", "uten-remote-tunnel-watchdog.service",
                       "uten-remote-tunnel-watchdog.timer"):
            output[f"{role}/{source}"] = (ROOT / "units" / source).read_text(encoding="utf-8")
        output[f"{role}/logrotate.conf"] = (ROOT / "units" / "logrotate.conf").read_text(encoding="utf-8")
    output["company/backend.env"] = "UTEN_REMOTE_INGRESS_ENABLED=true\nUTEN_REMOTE_INGRESS_PORT=8082\n"
    if commissioning_only:
        output["COMMISSIONING-ONLY.txt"] = (
            "PRIVATE TRANSPORT TEST ONLY. Employee public HTTPS is NOT configured.\n"
            "Use a private test CA for remote-commissioning.invalid; never bypass certificate verification.\n"
            "Keep the application remote-access policy OFF and do not authorize employees.\n"
            "Before employee activation, render a separate final profile with the approved domain and ACME account,\n"
            "install the company-held public certificate and validate DNS/CAA and full negative tests.\n"
        )
    else:
        output["dns-records.txt"] = (
        f"{p['public_domain']} A {p['cloud_public_ipv4']}\n"
        f"{p['public_domain']} CAA 0 issue \"letsencrypt.org;validationmethods=dns-01;accounturi={p['acme_account_uri']}\"\n"
        f"{p['public_domain']} CAA 0 issuewild \";\"\n"
        "# Publish only after reviewing inherited CAA and removing conflicting issuance grants.\n"
        "# DNS / ACME account credentials stay at the company; never put them on ECS.\n"
    )
    output["cloud/security-group-checklist.txt"] = (
        "Inbound TCP 443: approved employee networks or 0.0.0.0/0 if mobile users require it.\n"
        "Inbound UDP 51820: company public IPv4 /32 if fixed; otherwise 0.0.0.0/0 for roaming WireGuard only.\n"
        f"Inbound TCP 22: {p['admin_ipv4_cidr']} only, key authentication.\n"
        "No TCP 80, 8080, 8082, 8443, 9443, 5432, LAN subnet routes or cloud IAM roles.\n"
        "No public IPv6/AAAA until an equivalent IPv6 firewall and reachability audit is complete.\n"
        "Default-deny other inbound. Keep the existing outbound policy under review; never open company inbound NAT.\n"
    )
    return output


def render(profile: dict, destination: Path, *, commissioning_only: bool = False) -> None:
    rendered = files(profile, commissioning_only=commissioning_only)  # validate before creating anything
    if destination.exists() or destination.is_symlink():
        raise InvalidProfile("output: destination already exists; refusing to overwrite")
    destination.mkdir(mode=0o700, parents=False)
    for relative, content in rendered.items():
        target = destination / relative
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        # No secret content. Restrictive permissions also protect network metadata.
        with target.open("x", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        if os.name != "nt":
            target.chmod(0o600)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "render", "render-private-test"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        commissioning_only = args.command == "render-private-test"
        profile = load_profile(args.config, commissioning_only=commissioning_only)
        if args.command in ("render", "render-private-test"):
            if args.output is None:
                raise InvalidProfile("output: required for render")
            render(profile, args.output, commissioning_only=commissioning_only)
        elif args.output is not None:
            raise InvalidProfile("output: not valid for validate")
    except InvalidProfile as exc:
        # Only our own fixed messages/field names, never supplied values.
        print("Remote-access configuration rejected: " + str(exc), file=sys.stderr)
        return 2
    except OSError:
        # Do not include exception text from OS libraries or supplied paths.
        print("Remote-access configuration rejected; check the documented schema and safe output directory.", file=sys.stderr)
        return 2
    if args.command == "render-private-test":
        print("Private transport-test configuration rendered. Employee public HTTPS is NOT configured; no server was changed.")
    else:
        print("Remote-access configuration validated" + (" and rendered. No server was changed." if args.command == "render" else "."))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
