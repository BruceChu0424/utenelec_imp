"""Render a reviewed alias-only transaction. This tool never connects to a database."""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import re
import uuid


def validate_plan(plan: dict) -> None:
    def require(condition: bool, message: str) -> None:
        if not condition:
            raise ValueError(message)

    def exact(value: dict, keys: set[str], label: str) -> None:
        require(isinstance(value, dict) and set(value) == keys, f"Unexpected {label} fields")

    def identity(value: str) -> None:
        require(isinstance(value, str) and str(uuid.UUID(value)) == value, "Use canonical UUIDs")

    def integer(value: int) -> None:
        require(type(value) is int and value >= 0, "Expected a nonnegative integer")

    def text(value: str, maximum: int = 1000) -> None:
        require(isinstance(value, str) and 1 <= len(value.strip()) <= maximum
                and all(ord(c) >= 32 for c in value), "Missing or unsafe evidence text")

    exact(plan, {"protocol", "captured_at", "database_identity", "canonical", "retained_user",
                 "aliases", "backup", "evidence_reference", "maintenance_actor"}, "plan")
    require(plan["protocol"] == "verified-employee-alias-only-v1", "Unknown alias protocol")
    captured = dt.datetime.fromisoformat(plan["captured_at"])
    require(captured.tzinfo is not None, "captured_at needs an explicit timezone")
    age = dt.datetime.now(dt.timezone.utc) - captured
    require(-dt.timedelta(minutes=5) <= age <= dt.timedelta(hours=24), "Plan is expired or future-dated")
    database = plan["database_identity"]
    exact(database, {"database", "system_identifier", "database_oid", "dataset_id", "generation",
                     "migration_max", "migration_sha256"}, "database identity")
    text(database["database"], 63)
    require(bool(re.fullmatch(r"[0-9]{1,20}", database["system_identifier"])), "Invalid cluster identity")
    identity(database["dataset_id"])
    for key in ("database_oid", "generation", "migration_max"):
        integer(database[key])
    require(database["migration_max"] >= 947, "Current identity-alias/account-row-lock schema has not been deployed")
    require(bool(re.fullmatch(r"[0-9a-f]{64}", database["migration_sha256"])), "Missing migration fingerprint")
    canonical = plan["canonical"]
    exact(canonical, {"employee_id", "code", "version"}, "canonical identity")
    identity(canonical["employee_id"]); text(canonical["code"], 128); integer(canonical["version"])
    user = plan["retained_user"]
    exact(user, {"user_id", "version", "auth_version"}, "retained account")
    identity(user["user_id"]); integer(user["version"]); integer(user["auth_version"])
    require(isinstance(plan["aliases"], list) and 1 <= len(plan["aliases"]) <= 20, "Provide explicit aliases")
    members = {canonical["employee_id"]}
    for alias in plan["aliases"]:
        exact(alias, {"employee_id", "code", "version", "reason"}, "alias")
        identity(alias["employee_id"]); text(alias["code"], 128)
        integer(alias["version"]); text(alias["reason"])
        require(alias["employee_id"] not in members, "Duplicate or canonical alias identity")
        members.add(alias["employee_id"])
    backup = plan["backup"]
    exact(backup, {"reference", "manifest_sha256", "verified"}, "backup evidence")
    text(backup["reference"])
    require(backup["verified"] is True and bool(re.fullmatch(r"[0-9a-f]{64}", backup["manifest_sha256"])),
            "Require an independently verified paired-backup receipt")
    text(plan["evidence_reference"]); text(plan["maintenance_actor"], 128)


def render(plan: dict, *, commit: bool = False) -> str:
    validate_plan(plan)
    body = Path(__file__).with_name("verified_employee_alias_only.sql").read_text(encoding="utf-8")
    # JSON only contains reviewed identifiers and evidence references. SQL quoting
    # handles apostrophes; JSON is never interpolated into a shell command.
    literal = json.dumps(plan, ensure_ascii=False, separators=(",", ":")).replace("'", "''")
    return ("\\set ON_ERROR_STOP on\nBEGIN ISOLATION LEVEL REPEATABLE READ;\n"
            "SET LOCAL standard_conforming_strings=on;\n" + body
            + "\nSELECT pg_temp.apply_verified_employee_alias_only('" + literal + "'::jsonb);\n"
            + ("COMMIT;\n" if commit else "ROLLBACK;\n"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--commit", action="store_true", help="Render COMMIT; default renders ROLLBACK")
    args = parser.parse_args()
    output = render(json.loads(args.plan.read_text(encoding="utf-8-sig")), commit=args.commit)
    with args.out.open("x", encoding="utf-8", newline="\n") as handle:
        handle.write(output)
    print(json.dumps({"state": "RENDERED_ONLY", "transaction": "COMMIT" if args.commit else "ROLLBACK",
                      "output": str(args.out), "database_connections": 0}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
