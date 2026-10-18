#!/usr/bin/env python3
"""Opt-in, read-only endpoint probe. No writes, redirects, response bodies or tokens in reports."""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import math
import os
from pathlib import Path
import re
import ssl
import statistics
import sys
import time
from urllib.parse import urlsplit

# Keep the default allowlist non-business. Approved additions are an explicit local file.
DEFAULT_PATHS = ("/actuator/health/readiness",)
FORBIDDEN = re.compile(r"(?:/export(?:/|$)|/download(?:/|$)|/raw(?:/|$)|/reset(?:/|$)|/delete(?:/|$)|/send-code(?:/|$))", re.I)


def approved_paths(path: Path | None) -> tuple[str, ...]:
    if path is None:
        return DEFAULT_PATHS
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or not 1 <= len(data) <= 20:
        raise ValueError("allowlist must contain 1..20 paths")
    for item in data:
        if (not isinstance(item, str) or not item.startswith("/api/")
                or len(item) > 250 or not re.fullmatch(r"/[A-Za-z0-9_./-]+", item)
                or ".." in item or "//" in item or FORBIDDEN.search(item)):
            raise ValueError("only explicitly approved bounded GET API paths without queries/downloads are accepted")
    return tuple(dict.fromkeys(data))


def target(url: str) -> tuple[str, int]:
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment or parsed.path not in ("", "/")):
        raise ValueError("base URL must be an HTTPS origin without credentials or paths")
    return parsed.hostname, parsed.port or 443


def percentile(values: list[float], p: float) -> float:
    return sorted(values)[max(0, math.ceil(len(values) * p) - 1)] if values else 0


def probe(host: str, port: int, path: str, token: str, timeout: float, context: ssl.SSLContext) -> dict:
    started = time.perf_counter()
    connection = http.client.HTTPSConnection(host, port, timeout=timeout, context=context)
    try:
        headers = {"Accept": "application/json", "User-Agent": "Uten-Approved-ReadOnly-Probe/1", "Connection": "close"}
        if token:
            headers["Authorization"] = "Bearer " + token
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        # Bound work even if an accidentally selected endpoint returns huge data.
        size = 0
        while True:
            chunk = response.read(min(65536, 2 * 1024 * 1024 + 1 - size))
            if not chunk:
                break
            size += len(chunk)
            if size > 2 * 1024 * 1024:
                return {"status": response.status, "bytes": size, "error": "response_limit", "ms": (time.perf_counter() - started) * 1000}
        return {"status": response.status, "bytes": size, "error": "" if 200 <= response.status < 300 else "http_error", "ms": (time.perf_counter() - started) * 1000}
    except (OSError, ssl.SSLError, http.client.HTTPException):
        return {"status": 0, "bytes": 0, "error": "transport_error", "ms": (time.perf_counter() - started) * 1000}
    finally:
        connection.close()


def summarize(results: list[dict], concurrency: int) -> dict:
    timings = [item["ms"] for item in results]
    errors = {}
    statuses = {}
    for item in results:
        statuses[str(item["status"])] = statuses.get(str(item["status"]), 0) + 1
        if item["error"]:
            errors[item["error"]] = errors.get(item["error"], 0) + 1
    successful = [item["ms"] for item in results if not item["error"]]
    return {"concurrency": concurrency, "requests": len(results), "statuses": statuses,
            "errors": errors, "p50_ms": round(percentile(timings, .50), 2),
            "p95_ms": round(percentile(timings, .95), 2), "p99_ms": round(percentile(timings, .99), 2),
            "success_p95_ms": round(percentile(successful, .95), 2) if successful else None,
            "response_bytes_total": sum(item["bytes"] for item in results),
            "response_bytes_max": max((item["bytes"] for item in results), default=0)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--approved-get-paths", type=Path)
    parser.add_argument("--token-stdin", action="store_true", help="read a bearer token from secure stdin instead of UTEN_PROBE_TOKEN")
    parser.add_argument("--requests-per-stage", type=int, default=30)
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument("--ca-file", help="optional company CA; verification remains enabled")
    parser.add_argument("--acknowledge-live-read-load", action="store_true", required=True)
    args = parser.parse_args()
    try:
        host, port = target(args.base_url)
        paths = approved_paths(args.approved_get_paths)
        if not 10 <= args.requests_per_stage <= 200 or not 1 <= args.timeout <= 60:
            raise ValueError("load bounds")
        token = sys.stdin.readline(16385).strip() if args.token_stdin else os.environ.get("UTEN_PROBE_TOKEN", "")
        if len(token) > 16384 or any(ord(ch) < 33 or ord(ch) > 126 for ch in token):
            raise ValueError("invalid token")
        if args.approved_get_paths and not token:
            raise ValueError("business GET probe requires a least-privilege token")
        context = ssl.create_default_context(cafile=args.ca_file)
        reports = []
        for concurrency in (5, 10):
            with ThreadPoolExecutor(max_workers=concurrency) as pool:
                futures = [pool.submit(probe, host, port, paths[i % len(paths)], token, args.timeout, context)
                           for i in range(args.requests_per_stage)]
                results = [future.result() for future in futures]
            reports.append(summarize(results, concurrency))
            if concurrency == 5:
                time.sleep(2)
        print(json.dumps({"schema_version": 1, "method": "GET", "path_count": len(paths),
                          "new_tls_connection_per_request": True, "stages": reports}, ensure_ascii=False, indent=2))
        return 1 if any(report["errors"] for report in reports) else 0
    except (OSError, ValueError, ssl.SSLError):
        print("Read-only probe rejected or could not initialize; no token or response body was logged.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
