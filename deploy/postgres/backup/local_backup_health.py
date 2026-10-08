#!/usr/bin/python3
"""Read-only health for the current local repo1/repo2 layout; publishes the existing ERP contract."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import sys

try:
    import pgbackrest_health as health
except ModuleNotFoundError as failure:
    if failure.name != "pgbackrest_health":
        raise
    specification = importlib.util.spec_from_file_location(
        "pgbackrest_health", Path(__file__).resolve(strict=True).with_name("pgbackrest_health.py"))
    if specification is None or specification.loader is None:
        raise RuntimeError("Fixed backup-health parser is unavailable") from failure
    health = importlib.util.module_from_spec(specification)
    sys.modules["pgbackrest_health"] = health
    specification.loader.exec_module(health)


STANZA = "uten-imp"
MINIMUM_RESTORE_POINTS = health.MINIMUM_RESTORE_POINTS
MAXIMUM_FULL_AGE_SECONDS = 30 * 60 * 60
MAXIMUM_ARCHIVE_AGE_SECONDS = 15 * 60
READ_ONLY_PREFIX = "BEGIN READ ONLY; SET LOCAL statement_timeout='15s'; SET LOCAL lock_timeout='1s'; "


def evaluate(repo1_info, repo2_info, archiver_status, flyway_history) -> dict:
    archiver = health._validate_archiver(archiver_status, STANZA, MAXIMUM_ARCHIVE_AGE_SECONDS)
    repositories = [health._repo_health(info, STANZA, repo, archiver["systemIdentifier"],
                    MINIMUM_RESTORE_POINTS, MAXIMUM_FULL_AGE_SECONDS, archiver["nowEpoch"])
                    for repo, info in ((1, repo1_info), (2, repo2_info))]
    timeline = f"{archiver['timeline']:08X}"
    for repository in repositories:
        wal = repository["latestArchivedWal"]
        if not wal.startswith(timeline) or wal < archiver["lastArchivedWal"]:
            raise health.ContractError("A local repository is behind the sampled successful WAL or on another timeline")
    # Repository samples may advance between the two info calls; both must cover
    # the PostgreSQL success sampled before them, rather than falsely requiring equal maxima.
    return {
        "schemaVersion": 1, "status": "PASS",
        "checkedAtUtc": datetime.fromtimestamp(archiver["nowEpoch"], timezone.utc).isoformat(),
        "stanza": STANZA, "continuousWal": archiver,
        "databaseIdentity": {"systemIdentifier": archiver["systemIdentifier"],
                             "timeline": archiver["timeline"], "flyway": health._flyway_identity(flyway_history)},
        "repositories": repositories, "minimumSuccessfulFullRestorePoints": MINIMUM_RESTORE_POINTS,
        "repositoryCheckPerformedByThisRun": False, "walInventoryContinuityProvenByThisCheck": False,
        "remoteImmutabilityProvenByThisCheck": False, "pitrRestoreDrillProvenByThisCheck": False,
    }


def collect_live() -> dict:
    psql = ["/usr/bin/psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1",
            "-h", "/run/postgresql", "-p", "5432", "-d", "uten_imp", "-c"]
    archiver = health._run_json(psql + [READ_ONLY_PREFIX + health.PSQL_QUERY], "local PostgreSQL archiver", 30)
    command = ["/usr/bin/pgbackrest", "--config=/etc/pgbackrest.conf",
               "--config-include-path=/etc/pgbackrest/conf.d", f"--stanza={STANZA}",
               "--output=json", "--log-level-file=off"]
    first = health._run_json(command + ["--repo=1", "info"], "local repo1 info", 60)
    second = health._run_json(command + ["--repo=2", "info"], "local repo2 info", 60)
    flyway = health._run_json(psql + [READ_ONLY_PREFIX + health.FLYWAY_QUERY], "local Flyway history", 30)
    return evaluate(first, second, archiver, flyway)


def main(arguments=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=Path("/var/lib/uten-imp-backup-health/health.json"))
    args = parser.parse_args(arguments)
    try:
        report, status = collect_live(), 0
    except (health.ContractError, health.LiveCheckError, OSError, ValueError, TypeError, KeyError, OverflowError):
        report, status = {"schemaVersion": 1, "status": "FAIL",
                          "checkedAtUtc": datetime.now(timezone.utc).isoformat(),
                          "reasonCode": "LOCAL_BACKUP_HEALTH_CHECK_FAILED"}, 1
    health._atomic_report(args.report, report)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
