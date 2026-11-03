"""Generate the bounded publish-response exception for every supported proxy.

Forwarding/TLS/rate policy is inherited from each existing package route. Only
the exact publish POST receives a longer response wait; upload limits and all
ordinary API timeouts remain owned by their current locations.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
TARGETS = (
    "deploy/nginx/uten-imp-http-lan.conf",
    "deploy/nginx/uten-imp.conf.example",
    "deploy/nginx/uten-imp-internal-test.conf.example",
    "deploy/cloud/nginx-cloud.conf.example",
    "deploy/remote-access/templates/company-nginx.conf.tmpl",
)
BEGIN = "# BEGIN generated client publish response budget"
END = "# END generated client publish response budget"


def synchronize(text: str) -> str:
    generated = re.compile(r"(?m)^[ \t]*" + re.escape(BEGIN) + r"\n.*?^[ \t]*" + re.escape(END) + r"\n", re.S)
    text = generated.sub("", text)
    start = re.search(r"(?m)^([ \t]*)location ~ \^/api/admin/client-releases/\[0-9A-Fa-f-\]\+/package\$ \{\n", text)
    if start is None:
        raise ValueError("The reviewed package route is missing")
    depth = 0
    finish = start.start()
    for line in text[start.start():].splitlines(keepends=True):
        depth += line.count("{") - line.count("}")
        finish += len(line)
        if depth == 0:
            break
    if depth:
        raise ValueError("The reviewed package route is incomplete")
    source = text[start.start():finish]
    body = source.replace("/package$", "/publish$", 1).replace("^(PUT|OPTIONS)$", "^(POST|OPTIONS)$", 1)
    removed = ("client_max_body_size ", "client_body_timeout ", "proxy_request_buffering ",
               "proxy_buffering ", "proxy_send_timeout ")
    lines = [line for line in body.splitlines(keepends=True) if not line.lstrip().startswith(removed)]
    body = "".join(lines).replace("proxy_read_timeout 1800s;", "proxy_read_timeout 300s;")
    if "proxy_read_timeout 300s;" not in body:
        raise ValueError("The reviewed package response budget has changed")
    indent = start.group(1)
    block = (indent + BEGIN + "\n" + indent + "# Pair verification is bounded; account and step-up policy stays in Spring.\n"
             + body + indent + END + "\n")
    return text[:finish] + block + text[finish:]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    for name in TARGETS:
        path = ROOT / name
        current = path.read_text(encoding="utf-8")
        expected = synchronize(current)
        if arguments.check:
            if expected != current:
                raise SystemExit("Client publish proxy contract drift: " + name)
        else:
            path.write_text(expected, encoding="utf-8", newline="\n")
    print("Client publish proxy response budget: 5 templates checked")


if __name__ == "__main__":
    main()
