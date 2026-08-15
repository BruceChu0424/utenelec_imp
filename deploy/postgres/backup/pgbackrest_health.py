#!/usr/bin/env python3
"""Evaluate pgBackRest repo1/repo2, daily full and continuous-WAL health.

The ``live`` command is designed for the reviewed systemd unit and writes one
machine-readable report from pgBackRest ``info`` and read-only SQL.  It never
performs a backup, check, expire, restore, stanza delete or configuration
change.  The daily repo2 unit runs the more invasive archive-path probe before
its backup instead of repeating it from the five-minute health timer.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

try:
    from pgbackrest_repo2 import ContractError, _load_json, parse_policy
except ModuleNotFoundError as exc:
    if exc.name != "pgbackrest_repo2":
        raise
    sibling = Path(__file__).resolve(strict=True).with_name("pgbackrest_repo2.py")
    specification = importlib.util.spec_from_file_location("pgbackrest_repo2", sibling)
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load fixed pgbackrest_repo2 sibling") from exc
    module = importlib.util.module_from_spec(specification)
    sys.modules["pgbackrest_repo2"] = module
    specification.loader.exec_module(module)
    ContractError = module.ContractError
    _load_json = module._load_json
    parse_policy = module.parse_policy


WAL_NAME = __import__("re").compile(r"^[0-9A-F]{24}$")
MAX_COMMAND_OUTPUT = 8 * 1024 * 1024
PSQL_QUERY = r"""
SELECT json_build_object(
  'nowEpoch', extract(epoch from clock_timestamp())::bigint,
  'archiveMode', current_setting('archive_mode'),
  'archiveCommand', current_setting('archive_command'),
  'inRecovery', pg_is_in_recovery(),
  'lastArchivedEpoch', CASE WHEN last_archived_time IS NULL THEN NULL
                            ELSE extract(epoch from last_archived_time)::bigint END,
  'lastArchivedWal', last_archived_wal,
  'archivedCount', archived_count,
  'failedCount', failed_count,
  'lastFailedEpoch', CASE WHEN last_failed_time IS NULL THEN NULL
                          ELSE extract(epoch from last_failed_time)::bigint END,
  'currentWal', pg_walfile_name(pg_current_wal_lsn()),
  'systemIdentifier', (SELECT system_identifier::text FROM pg_control_system()),
  'timeline', (SELECT timeline_id FROM pg_control_checkpoint())
)::text
FROM pg_stat_archiver;
""".strip()
FLYWAY_QUERY = r"""
SELECT COALESCE(
  json_agg(
    json_build_object(
      'installedRank', installed_rank,
      'version', version,
      'description', description,
      'type', type,
      'script', script,
      'checksum', checksum,
      'success', success
    ) ORDER BY installed_rank
  ),
  '[]'::json
)::text
FROM flyway_schema_history;
""".strip()


class LiveCheckError(RuntimeError):
    """A fixed live verification command failed without exposing its output."""


def _as_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ContractError(f"{label} must be numeric")
    result = int(value)
    if result != value or result < 0:
        raise ContractError(f"{label} must be a non-negative integer")
    return result


def _single_stanza(value: Any, stanza: str, label: str) -> dict[str, Any]:
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        raise ContractError(f"{label} must contain exactly one stanza")
    result = value[0]
    if result.get("name") != stanza:
        raise ContractError(f"{label} stanza identity differs from policy")
    status = result.get("status")
    if not isinstance(status, dict) or status.get("code") != 0:
        raise ContractError(f"{label} stanza status is not ok")
    return result


def _repo_health(
    info: Any,
    stanza: str,
    repo_number: int,
    system_identifier: str,
    minimum_points: int,
    maximum_full_age: int,
    now_epoch: int,
) -> dict[str, Any]:
    stanza_info = _single_stanza(info, stanza, f"repo{repo_number} info")
    repositories = stanza_info.get("repo")
    matching_repositories = (
        [
            item
            for item in repositories
            if isinstance(item, dict) and item.get("key") == repo_number
        ]
        if isinstance(repositories, list)
        else []
    )
    if len(matching_repositories) != 1:
        raise ContractError(f"repo{repo_number} selected repository identity is missing")
    repository_status = matching_repositories[0].get("status")
    if not isinstance(repository_status, dict) or repository_status.get("code") != 0:
        raise ContractError(f"repo{repo_number} selected repository status is not ok")
    databases = stanza_info.get("db")
    matching_databases = (
        [
            item
            for item in databases
            if isinstance(item, dict)
            and str(item.get("system-id")) == system_identifier
        ]
        if isinstance(databases, list)
        else []
    )
    if len(matching_databases) != 1:
        raise ContractError(
            f"repo{repo_number} does not identify exactly one current PostgreSQL system"
        )
    database_id = _as_int(
        matching_databases[0].get("id"), f"repo{repo_number} current database id"
    )
    if database_id < 1:
        raise ContractError(f"repo{repo_number} current database id must be positive")
    backups = stanza_info.get("backup")
    if not isinstance(backups, list):
        raise ContractError(f"repo{repo_number} backup inventory is missing")
    successful_full: list[dict[str, Any]] = []
    for backup in backups:
        if not isinstance(backup, dict) or backup.get("type") != "full":
            continue
        if backup.get("error") not in (None, False):
            continue
        database = backup.get("database")
        if not isinstance(database, dict) or (
            database.get("repo-key") != repo_number
            or database.get("id") != database_id
        ):
            continue
        timestamp = backup.get("timestamp")
        archive = backup.get("archive")
        if not isinstance(timestamp, dict) or not isinstance(archive, dict):
            raise ContractError(f"repo{repo_number} full backup lacks timestamp/archive identity")
        stop = _as_int(timestamp.get("stop"), f"repo{repo_number} backup stop")
        archive_start = archive.get("start")
        archive_stop = archive.get("stop")
        if not isinstance(archive_start, str) or not WAL_NAME.fullmatch(archive_start):
            raise ContractError(f"repo{repo_number} full backup archive start is invalid")
        if not isinstance(archive_stop, str) or not WAL_NAME.fullmatch(archive_stop):
            raise ContractError(f"repo{repo_number} full backup archive stop is invalid")
        if archive_start > archive_stop:
            raise ContractError(f"repo{repo_number} full backup WAL range is reversed")
        label = backup.get("label")
        if not isinstance(label, str) or not label or len(label) > 128:
            raise ContractError(f"repo{repo_number} full backup label is invalid")
        successful_full.append(
            {
                "label": label,
                "stop": stop,
                "archiveStart": archive_start,
                "archiveStop": archive_stop,
            }
        )
    successful_full.sort(key=lambda item: item["stop"])
    if len(successful_full) < minimum_points:
        raise ContractError(
            f"repo{repo_number} has {len(successful_full)} successful full restore points; "
            f"at least {minimum_points} are required"
        )
    accepted_points = successful_full[-minimum_points:]
    accepted_dates = {
        datetime.fromtimestamp(item["stop"], tz=timezone.utc).date()
        for item in accepted_points
    }
    if len(accepted_dates) != minimum_points:
        raise ContractError(
            f"repo{repo_number} restore points are not from {minimum_points} distinct UTC dates"
        )
    latest = successful_full[-1]
    age = now_epoch - latest["stop"]
    if age < 0 or age > maximum_full_age:
        raise ContractError(
            f"repo{repo_number} latest successful full age {age}s exceeds {maximum_full_age}s"
        )

    archive_inventory = stanza_info.get("archive")
    if not isinstance(archive_inventory, list) or not archive_inventory:
        raise ContractError(f"repo{repo_number} WAL archive inventory is empty")
    maxima: list[str] = []
    for archive_item in archive_inventory:
        if not isinstance(archive_item, dict):
            continue
        database = archive_item.get("database")
        if not isinstance(database, dict) or (
            database.get("repo-key") != repo_number
            or database.get("id") != database_id
        ):
            continue
        maximum = archive_item.get("max")
        if isinstance(maximum, str) and WAL_NAME.fullmatch(maximum):
            maxima.append(maximum)
    if not maxima:
        raise ContractError(f"repo{repo_number} has no valid latest archived WAL")
    return {
        "repo": repo_number,
        "databaseId": database_id,
        "successfulFullRestorePoints": len(successful_full),
        "latestSuccessfulFullLabel": latest["label"],
        "latestSuccessfulFullStopEpoch": latest["stop"],
        "latestSuccessfulFullAgeSeconds": age,
        "latestSuccessfulFullWalStart": latest["archiveStart"],
        "latestSuccessfulFullWalStop": latest["archiveStop"],
        "successfulFullRestorePointLabels": [
            item["label"] for item in accepted_points
        ],
        "restorePoints": [
            {
                "label": item["label"],
                "stopEpoch": item["stop"],
                "walStart": item["archiveStart"],
                "walStop": item["archiveStop"],
            }
            for item in accepted_points
        ],
        "latestArchivedWal": max(maxima),
    }


def _validate_archiver(value: Any, stanza: str, maximum_archive_age: int) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError("PostgreSQL archiver status must be one object")
    expected_keys = {
        "nowEpoch",
        "archiveMode",
        "archiveCommand",
        "inRecovery",
        "lastArchivedEpoch",
        "lastArchivedWal",
        "archivedCount",
        "failedCount",
        "lastFailedEpoch",
        "currentWal",
        "systemIdentifier",
        "timeline",
    }
    if set(value) != expected_keys:
        raise ContractError("PostgreSQL archiver status keys differ from the reviewed query")
    if value["archiveMode"] != "on" or value["inRecovery"] is not False:
        raise ContractError("continuous WAL health must run on the writable archive-enabled primary")
    command = value["archiveCommand"]
    if not isinstance(command, str):
        raise ContractError("archive_command is missing")
    try:
        argv = shlex.split(command, posix=True)
    except ValueError as exc:
        raise ContractError("archive_command cannot be parsed safely") from exc
    if argv and argv[0] == "/usr/bin/pgbackrest":
        argv[0] = "pgbackrest"
    expected = ["pgbackrest", f"--stanza={stanza}", "archive-push", "%p"]
    if argv != expected:
        raise ContractError("archive_command differs from the reviewed pgBackRest-only command")
    now_epoch = _as_int(value["nowEpoch"], "nowEpoch")
    last_archived = _as_int(value["lastArchivedEpoch"], "lastArchivedEpoch")
    age = now_epoch - last_archived
    if age < 0 or age > maximum_archive_age:
        raise ContractError(
            f"latest PostgreSQL archive success age {age}s exceeds {maximum_archive_age}s"
        )
    archived_count = _as_int(value["archivedCount"], "archivedCount")
    failed_count = _as_int(value["failedCount"], "failedCount")
    last_failed_raw = value["lastFailedEpoch"]
    if last_failed_raw is not None:
        last_failed = _as_int(last_failed_raw, "lastFailedEpoch")
        if last_failed > last_archived:
            raise ContractError("the latest PostgreSQL archive attempt failed after the last success")
    current_wal = value["currentWal"]
    if not isinstance(current_wal, str) or not WAL_NAME.fullmatch(current_wal):
        raise ContractError("current PostgreSQL WAL identity is invalid")
    if archived_count < 1:
        raise ContractError("PostgreSQL has not recorded a successful WAL archive")
    system_identifier = value["systemIdentifier"]
    if (
        not isinstance(system_identifier, str)
        or not system_identifier.isdigit()
        or not 16 <= len(system_identifier) <= 24
    ):
        raise ContractError("PostgreSQL system_identifier is invalid")
    timeline = _as_int(value["timeline"], "timeline")
    if timeline < 1 or timeline > 0xFFFFFFFF:
        raise ContractError("PostgreSQL timeline must be a positive uint32")
    timeline_prefix = f"{timeline:08X}"
    last_archived_wal = value["lastArchivedWal"]
    if (
        not isinstance(last_archived_wal, str)
        or not WAL_NAME.fullmatch(last_archived_wal)
        or not last_archived_wal.startswith(timeline_prefix)
    ):
        raise ContractError("PostgreSQL last archived WAL identity/timeline is invalid")
    if not current_wal.startswith(timeline_prefix) or current_wal < last_archived_wal:
        raise ContractError("PostgreSQL current WAL is behind the last archived WAL")
    return {
        "nowEpoch": now_epoch,
        "latestArchiveSuccessEpoch": last_archived,
        "latestArchiveSuccessAgeSeconds": age,
        "archivedCount": archived_count,
        "failedCount": failed_count,
        "currentWal": current_wal,
        "lastArchivedWal": last_archived_wal,
        "systemIdentifier": system_identifier,
        "timeline": timeline,
    }


def _flyway_identity(value: Any) -> dict[str, Any]:
    if not isinstance(value, list) or not value:
        raise ContractError("Flyway history must be a non-empty JSON array")
    expected = {
        "installedRank",
        "version",
        "description",
        "type",
        "script",
        "checksum",
        "success",
    }
    canonical_rows: list[dict[str, Any]] = []
    versions: set[str] = set()
    prior_rank = -1
    for row in value:
        if not isinstance(row, dict) or set(row) != expected:
            raise ContractError("Flyway history row schema differs from the canonical query")
        rank = _as_int(row["installedRank"], "Flyway installedRank")
        version = row["version"]
        checksum = row["checksum"]
        if rank <= prior_rank:
            raise ContractError("Flyway history installedRank is not strictly increasing")
        if not isinstance(version, str) or not version.isdigit() or version in versions:
            raise ContractError("Flyway history has a null/non-numeric/duplicate version")
        if row["type"] != "SQL" or row["success"] is not True:
            raise ContractError("Flyway history contains a non-SQL or unsuccessful row")
        if isinstance(checksum, bool) or not isinstance(checksum, int):
            raise ContractError("Flyway history checksum is not an integer")
        if not isinstance(row["script"], str) or not row["script"].endswith(".sql"):
            raise ContractError("Flyway history script is invalid")
        if not isinstance(row["description"], str):
            raise ContractError("Flyway history description is invalid")
        canonical_rows.append(row)
        versions.add(version)
        prior_rank = rank
    payload = json.dumps(
        canonical_rows, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    signed_projection = "".join(
        f"{row['version']}\t{row['script']}\t{row['checksum']}\n"
        for row in canonical_rows
    ).encode("utf-8")
    return {
        "successfulMigrationCount": len(canonical_rows),
        "headVersion": max(int(version) for version in versions),
        "canonicalHistorySha256": __import__("hashlib").sha256(payload).hexdigest(),
        "signedProjectionSha256": __import__("hashlib")
        .sha256(signed_projection)
        .hexdigest(),
    }


def evaluate(
    policy_value: dict[str, Any],
    repo1_info: Any,
    repo2_info: Any,
    archiver_status: Any,
    flyway_history: Any,
) -> dict[str, Any]:
    policy = parse_policy(policy_value)
    archiver = _validate_archiver(
        archiver_status, policy.stanza, policy.maximum_archive_age_seconds
    )
    repo1 = _repo_health(
        repo1_info,
        policy.stanza,
        1,
        archiver["systemIdentifier"],
        policy.minimum_restore_points,
        policy.maximum_full_age_seconds,
        archiver["nowEpoch"],
    )
    repo2 = _repo_health(
        repo2_info,
        policy.stanza,
        2,
        archiver["systemIdentifier"],
        policy.minimum_restore_points,
        policy.maximum_full_age_seconds,
        archiver["nowEpoch"],
    )
    if repo1["latestArchivedWal"] != repo2["latestArchivedWal"]:
        raise ContractError("repo1 and repo2 latest archived WAL identities differ")
    if repo1["latestArchivedWal"] < archiver["lastArchivedWal"]:
        raise ContractError(
            "both repositories are behind PostgreSQL last archived WAL"
        )
    flyway = _flyway_identity(flyway_history)
    return {
        "schemaVersion": 1,
        "status": "PASS",
        "checkedAtUtc": datetime.fromtimestamp(
            archiver["nowEpoch"], tz=timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stanza": policy.stanza,
        "continuousWal": archiver,
        "databaseIdentity": {
            "systemIdentifier": archiver["systemIdentifier"],
            "timeline": archiver["timeline"],
            "flyway": flyway,
        },
        "repositories": [repo1, repo2],
        "minimumSuccessfulFullRestorePoints": policy.minimum_restore_points,
        "repositoryCheckPerformedByThisRun": False,
        "walInventoryContinuityProvenByThisCheck": False,
        "remoteImmutabilityProvenByThisCheck": False,
        "pitrRestoreDrillProvenByThisCheck": False,
    }


def _safe_environment() -> dict[str, str]:
    return {
        "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "HOME": "/var/lib/postgresql",
    }


def _run_json(command: Sequence[str], label: str, timeout: int) -> Any:
    try:
        result = subprocess.run(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=_safe_environment(),
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LiveCheckError(f"{label} could not complete") from exc
    if result.returncode != 0:
        raise LiveCheckError(f"{label} exited non-zero")
    if len(result.stdout) > MAX_COMMAND_OUTPUT:
        raise LiveCheckError(f"{label} output exceeds the safety limit")
    try:
        return json.loads(result.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise LiveCheckError(f"{label} did not return UTF-8 JSON") from exc


def _load_any_json(path: Path, label: str) -> Any:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise ContractError(f"cannot read {label}: {exc}") from exc
    if len(raw) > MAX_COMMAND_OUTPUT:
        raise ContractError(f"{label} exceeds the safety limit")
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ContractError(f"{label} must not contain a UTF-8 BOM")
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"{label} is not UTF-8 JSON") from exc


def collect_live(policy_path: Path, config: Path, include_path: Path) -> dict[str, Any]:
    policy_value = _load_json(policy_path, "policy")
    policy = parse_policy(policy_value)
    common = [
        "/usr/bin/pgbackrest",
        f"--config={config}",
        f"--config-include-path={include_path}",
        f"--stanza={policy.stanza}",
        "--output=json",
    ]
    archiver = _run_json(
        [
            "/usr/bin/psql",
            "-X",
            "-A",
            "-t",
            "-v",
            "ON_ERROR_STOP=1",
            "-d",
            "uten_imp",
            "-c",
            PSQL_QUERY,
        ],
        "PostgreSQL archiver status",
        30,
    )
    # Capture the PostgreSQL archive target before repository inventories.  A
    # repository may advance while the read-only samples run, but neither may
    # remain behind this already-successful archive target.
    repo1 = _run_json(common + ["--repo=1", "info"], "repo1 info", 120)
    repo2 = _run_json(common + ["--repo=2", "info"], "repo2 info", 120)
    flyway = _run_json(
        [
            "/usr/bin/psql",
            "-X",
            "-A",
            "-t",
            "-v",
            "ON_ERROR_STOP=1",
            "-d",
            "uten_imp",
            "-c",
            FLYWAY_QUERY,
        ],
        "canonical Flyway history",
        30,
    )
    return evaluate(policy_value, repo1, repo2, archiver, flyway)


def _atomic_report(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    payload = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o640)
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            if written < 1:
                raise OSError("short backup-health report write")
            view = view[written:]
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, path)
        parent_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    evaluate_parser = sub.add_parser("evaluate")
    evaluate_parser.add_argument("--policy", required=True, type=Path)
    evaluate_parser.add_argument("--repo1-info", required=True, type=Path)
    evaluate_parser.add_argument("--repo2-info", required=True, type=Path)
    evaluate_parser.add_argument("--archiver-status", required=True, type=Path)
    evaluate_parser.add_argument("--flyway-history", required=True, type=Path)
    live = sub.add_parser("live")
    live.add_argument("--policy", required=True, type=Path)
    live.add_argument("--config", default=Path("/etc/pgbackrest.conf"), type=Path)
    live.add_argument(
        "--config-include-path", default=Path("/etc/pgbackrest/conf.d"), type=Path
    )
    live.add_argument(
        "--report", default=Path("/var/lib/uten-imp-backup-health/health.json"), type=Path
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.action == "evaluate":
            report = evaluate(
                _load_json(args.policy, "policy"),
                _load_any_json(args.repo1_info, "repo1 info"),
                _load_any_json(args.repo2_info, "repo2 info"),
                _load_json(args.archiver_status, "archiver status"),
                _load_any_json(args.flyway_history, "Flyway history"),
            )
            print(json.dumps(report, sort_keys=True))
            return 0
        try:
            report = collect_live(args.policy, args.config, args.config_include_path)
            status = 0
        except (ContractError, LiveCheckError, OSError) as exc:
            report = {
                "schemaVersion": 1,
                "status": "FAIL",
                "checkedAtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "failure": str(exc),
                "secretsIncluded": False,
            }
            status = 1
        _atomic_report(args.report, report)
        print(json.dumps(report, sort_keys=True))
        return status
    except (ContractError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
