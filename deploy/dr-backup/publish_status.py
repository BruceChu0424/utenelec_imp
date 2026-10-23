#!/usr/bin/python3
"""Publish only fixed-target ciphertext evidence to the loopback DR control plane."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
import urllib.request


def publish(base, config_path, token_path, state_path, endpoint):
    # No caller-supplied network destinations, paths from API requests, or shell execution.
    if endpoint != "http://127.0.0.1:9087/v1/agent/snapshot":
        raise ValueError("Publisher only accepts the fixed loopback controller")
    config = base.read_json(base.private_path(config_path))
    token = base.private_path(token_path).read_text(encoding="ascii").strip()
    if not 32 <= len(token) <= 256 or any(ch.isspace() for ch in token):
        raise ValueError("Invalid protected publisher token")
    state = base.read_json(state_path) if state_path.exists() else {}
    status = base.build_status(config)  # Recalculate age instead of replaying a stale healthy JSON.
    sequence = max(time.time_ns(), state.get("sequence", -1) + 1)
    fields = ("id", "storageTargetId", "recoverableUntil", "manifestSha256", "cipherSha256",
              "complete", "cipherVerified", "keysCovered", "verified")
    points = [{key: row[key] for key in fields} for row in sorted(status["recoveryPoints"],
        key=lambda row: row["recoverableUntil"], reverse=True)[:100]]
    for point in points:
        point["keysCovered"] = False
        point["verified"] = False
    body = {"agentId": "backup-publisher", "sequence": sequence,
            "observedAt": base.now().isoformat(), "health": status["health"], "recoveryPoints": points}
    request = urllib.request.Request(endpoint, data=json.dumps(body, separators=(",", ":")).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}, method="POST")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=15) as response:
        result = json.loads(response.read(8193))
    if result.get("accepted") is not True:
        raise ValueError("Controller did not acknowledge archive evidence")
    receipt = {"state": "PUBLISHED", "at": base.now().isoformat(), "sequence": sequence,
               "health": status["health"], "recoveryPoints": len(points)}
    base.atomic_json(state_path, receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("/etc/uten-imp-dr-backup/receiver.json"))
    parser.add_argument("--token", type=Path, default=Path("/etc/uten-dr-control/backup-publisher.token"))
    parser.add_argument("--state", type=Path, default=Path("/var/lib/uten-imp-dr-backup/publisher-state.json"))
    args = parser.parse_args()
    os.umask(0o077)
    path = Path(__file__).with_name("continuous_backup.py")
    spec = importlib.util.spec_from_file_location("uten_dr_publisher_base", path)
    module = importlib.util.module_from_spec(spec);sys.modules[spec.name] = module;spec.loader.exec_module(module)
    try:
        print(json.dumps(publish(module, args.config, args.token, args.state,
                                 "http://127.0.0.1:9087/v1/agent/snapshot")))
    except Exception as error:
        print(json.dumps({"state": "FAILED", "errorType": type(error).__name__}), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":raise SystemExit(main())
