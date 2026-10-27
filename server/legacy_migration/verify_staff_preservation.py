#!/usr/bin/env python3
"""Read-only staff conservation gate for a same-version database rebuild/restore.

Normal application upgrades do not replace HR/account data and do not run this
scanner. A legacy-bootstrap PASSED receipt does not establish staff conservation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

from staff_preservation import (PreservationError, compare_staff, reviewed_specs,
                                schema_sql, snapshot_sql, validate_snapshot)
from verify_rehearsal_result import ReadOnlyDatabase, VerificationError


class NativeReadOnlyDatabase(ReadOnlyDatabase):
    """Reuse the pinned SELECT-only transaction/identity envelope with local psql.

    The operator runs under the intended OS/database role. Credentials are never
    accepted as command arguments or written by this verifier.
    """
    def _pin_transport(self):
        if self.transport is None:
            self.transport = []
        return self.transport


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sealed(path, expected_sha):
    if digest(path) != expected_sha:
        raise PreservationError("Staff evidence SHA-256 differs from the reviewed file")
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    validate_snapshot(value)
    if value.get("collector") != collector_identity():
        raise PreservationError("Staff evidence collector differs from the current reviewed policy; recapture both snapshots")
    return value


def collector_identity():
    return {"cli_sha256": digest(Path(__file__)),
            "policy_sha256": digest(Path(__file__).with_name("staff_preservation.py"))}


def write_new(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    modes = root.add_subparsers(dest="mode", required=True)
    capture = modes.add_parser("capture", help="Capture a private source/candidate snapshot without changing business rows")
    capture.add_argument("--database", required=True)
    capture.add_argument("--user", default="uten")
    transport = capture.add_mutually_exclusive_group()
    transport.add_argument("--container", default="uten-imp-postgres")
    transport.add_argument("--native", action="store_true", help="Use local psql under the explicitly selected operator role")
    capture.add_argument("--expected-system-identifier", required=True)
    capture.add_argument("--expected-database-oid", required=True, type=int)
    capture.add_argument("--baseline", type=Path, help="Source snapshot; candidate capture reuses its immutable audit high-water")
    capture.add_argument("--baseline-sha256")
    capture.add_argument("--output", required=True, type=Path)
    compare = modes.add_parser("compare", help="Fail if native staff, security state, permissions or evidence changed/lost")
    compare.add_argument("--source", required=True, type=Path)
    compare.add_argument("--source-sha256", required=True)
    compare.add_argument("--candidate", required=True, type=Path)
    compare.add_argument("--candidate-sha256", required=True)
    compare.add_argument("--allow-same-database-restore", action="store_true", help="Explicit restore verification; never silently accept source-as-candidate")
    compare.add_argument("--output", required=True, type=Path)
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.output.exists():
            raise PreservationError("Refusing to overwrite prior staff evidence")
        if args.mode == "capture":
            if bool(args.baseline) != bool(args.baseline_sha256):
                raise PreservationError("Candidate baseline and its reviewed SHA must be supplied together")
            baseline = sealed(args.baseline, args.baseline_sha256) if args.baseline else None
            database_type = NativeReadOnlyDatabase if args.native else ReadOnlyDatabase
            database = database_type(args.database, args.container, args.user,
                                     args.expected_system_identifier, args.expected_database_oid)
            metadata = database.query(schema_sql())
            specs = reviewed_specs(metadata)
            if baseline and specs != baseline["schema"]:
                raise PreservationError("Source/candidate HR and account schema contracts differ")
            evidence = database.query(snapshot_sql(metadata, baseline["audit"]["highwater"] if baseline else None))
            indices = validate_snapshot(evidence)
            evidence["collector"] = collector_identity()
            write_new(args.output, evidence)
            report = {"status": "CAPTURED_READ_ONLY", "employees": len(indices["employees"]),
                      "accounts": len(indices["users"]), "registered_tables": len(indices),
                      "snapshot_sha256": digest(args.output), "business_writes": 0,
                      "production_acceptance": False, "actual_password_login_tested": False}
        else:
            source = sealed(args.source, args.source_sha256)
            candidate = sealed(args.candidate, args.candidate_sha256)
            report = compare_staff(source, candidate, allow_same_database_restore=args.allow_same_database_restore)
            report.update(source_snapshot_sha256=args.source_sha256, candidate_snapshot_sha256=args.candidate_sha256)
            write_new(args.output, report)
        # Safe bounded report only; never print the captured rows or custody tokens.
        print(json.dumps(report, ensure_ascii=True))
        return 0 if report["status"] != "FAILED" else 1
    except (PreservationError, VerificationError, OSError, ValueError, TypeError, KeyError) as error:
        # Policy/transport errors contain reviewed, bounded instructions only;
        # never expose raw JSON values, SQL, database stderr or OS paths.
        reason = str(error) if isinstance(error, (PreservationError, VerificationError)) else "Staff evidence could not be read or decoded; raw values were withheld"
        print(json.dumps({"status": "FAILED", "reason": reason, "business_writes": 0}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
