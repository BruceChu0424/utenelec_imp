#!/usr/bin/env python3
"""Generate bounded output-only gateway routes from the real JSON-budgeted controllers.

Existing per-environment proxy directives remain the source of upstream, rate and
timeout behavior. This never modifies the global 2 MiB limit or deployment hosts.
"""
from pathlib import Path
import argparse
import re

ROOT = Path(__file__).resolve().parents[2]
CONFIGS = ("uten-imp-http-lan.conf", "uten-imp.conf.example", "uten-imp-internal-test.conf.example")
BEGIN = "    # BEGIN generated output selection request budget"
END = "    # END generated output selection request budget"


def output_paths(root=ROOT):
    routes = set()
    for file in sorted((root / "server/src/main/java").rglob("*Controller.java")):
        text = file.read_text(encoding="utf-8")
        if "JsonBodyLimit" not in text:
            continue
        declaration = re.search(r"\bpublic\s+(?:final\s+)?class\b", text)
        if declaration is None:
            continue
        bases = re.findall(r'@RequestMapping\(\s*"([^"]*)"\s*\)', text[:declaration.start()])
        base = bases[-1] if bases else ""
        for mapping in re.finditer(r"@PostMapping(?:\(([^)]*)\))?", text):
            line_start = text.rfind("\n", 0, mapping.start()) + 1
            before = text[:line_start].splitlines()
            prior = []
            for line in reversed(before):
                if not line.strip() or line.rstrip().endswith("}"):
                    break
                prior.append(line)
            public = text.find("public ", mapping.end())
            if public < 0:
                continue
            head = "\n".join(reversed(prior)) + text[line_start:public]
            if "JsonBodyLimit" not in head:
                continue
            paths = re.findall(r'"([^"]*)"', mapping.group(1) or "") or [""]
            for path in paths:
                if path and not path.startswith("/"):
                    continue
                route = base.rstrip("/") + path
                if route.startswith("/api/") and (route.endswith("/export") or route == "/api/report-export-jobs"):
                    routes.add(route)
    if "/api/report-export-jobs" not in routes or "/api/master/moulds/export" not in routes:
        raise ValueError("Required output controller routes were not discovered")
    return sorted(routes)


def proxy_body(text, location):
    start = text.index(location) + len(location)
    end = text.index("\n    }", start)
    body = text[start:end]
    if "{" in body or "}" in body or "client_max_body_size" in body:
        raise ValueError("Original proxy block changed; review its directives before regeneration")
    return body


def route_pattern(route):
    marker = "UTENPATHPARAMETER"
    route = re.sub(r"\{[^{}]+\}", marker, route)
    return re.escape(route).replace(r"\-", "-").replace(marker, "[^/]+")


def generated(text, routes):
    ordinary = proxy_body(text, "    location /api/ {")
    exports = proxy_body(text, "    location ~ ^/api/.*/export$ {")
    paths = [route for route in routes if route != "/api/report-export-jobs"]
    pattern = "^(?:" + "|".join(route_pattern(route) for route in paths) + ")$"
    return (BEGIN + "\n"
            "    # Route allowlist comes from JsonBodyLimit POST output controllers.\n"
            "    # Spring retains tighter DTO, identity, row, authority and field limits.\n"
            "    location = /api/report-export-jobs {\n"
            "        client_max_body_size 16m;" + ordinary + "\n    }\n"
            '    location ~ "' + pattern + '" {\n'
            "        client_max_body_size 16m;" + exports + "\n    }\n" + END)


def render(text, routes):
    block = generated(text, routes)
    if BEGIN in text:
        start = text.index(BEGIN)
        end = text.index(END, start) + len(END)
        return text[:start] + block + text[end:]
    position = text.index("    location ~ ^/api/.*/export$ {")
    return text[:position] + block + "\n\n" + text[position:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    routes = output_paths()
    changed = []
    for name in CONFIGS:
        path = ROOT / "deploy/nginx" / name
        old = path.read_text(encoding="utf-8")
        updated = render(old, routes)
        if path.read_bytes() != updated.encode("utf-8"):
            changed.append(name)
            if not args.check:
                path.write_text(updated, encoding="utf-8", newline="\n")
    if args.check and changed:
        raise SystemExit("Output selection gateway drift: " + ", ".join(changed))
    print(f"Output selection gateway: {len(routes)} bounded routes, {len(CONFIGS)} configurations; "
          + ("checked" if args.check else "generated"))


if __name__ == "__main__":
    main()
