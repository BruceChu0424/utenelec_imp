"""Explicit private Testcontainers destination for rollback-only SQL tests.

No local development container name or database is a default. The coordinator
must supply its immutable ID and matching per-fixture label before any SQL.
"""
import json
import os
import re
import subprocess
import uuid


def fixture_psql(sql: str):
    container = os.environ.get("UTEN_LEGACY_TEST_PG_CONTAINER", "")
    database = os.environ.get("UTEN_LEGACY_TEST_PG_DATABASE", "")
    user = os.environ.get("UTEN_LEGACY_TEST_PG_USER", "")
    nonce = os.environ.get("UTEN_LEGACY_TEST_PG_NONCE", "")
    if (not re.fullmatch(r"[0-9a-f]{64}", container)
            or not re.fullmatch(r"legacy_bootstrap_[a-z0-9_]+", database)
            or user != "fixture_admin"):
        raise RuntimeError("An explicit private legacy Testcontainers destination is required")
    try:
        valid_nonce = str(uuid.UUID(nonce)) == nonce and uuid.UUID(nonce).version == 4
    except ValueError:
        valid_nonce = False
    if not valid_nonce:
        raise RuntimeError("A private coordinator fixture nonce is required")
    if not sql.strip().startswith("BEGIN;") or not sql.strip().endswith("ROLLBACK;"):
        raise RuntimeError("Legacy SQL test fixtures must own a rollback-only transaction")
    inspected = subprocess.run(
        ["docker", "inspect", "--type=container", "--format", "{{json .Config.Labels}}", container],
        capture_output=True, text=True, timeout=20,
    )
    if inspected.returncode:
        raise RuntimeError("The explicit private Testcontainers destination is unavailable")
    labels = json.loads(inspected.stdout)
    if (not isinstance(labels, dict) or labels.get("org.testcontainers") != "true"
            or labels.get("uten.imp.legacy.fixture") != nonce):
        raise RuntimeError("The destination is not this coordinator's private Testcontainers fixture")
    return subprocess.run(
        ["docker", "exec", "-i", container, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1",
         "--host=/var/run/postgresql", "--port=5432", "-U", user, "-d", database],
        input=sql.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
    )
