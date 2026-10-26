"""Explicit local imports. Model training never runs in an ERP request."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from .data import InputError, ledger_payload, read_dataset, require_append_only
from .locking import os_file_lock, register_write_barrier, write_barrier


def atomic_json(path: Path, value: dict, *, public: bool = False) -> None:
    with write_barrier(path):
        _atomic_json(path, value, public=public)


def atomic_health_json(path: Path, value: dict) -> None:
    """Publish volatile liveness independently of durable snapshot copies.

    A backup may hold the state barrier longer than the supervisor's freshness
    window. Health is excluded from new exports and must remain live during
    that copy; all model, quote and cache writes still use atomic_json.
    """
    if path.name != "auto-feed-health.json":
        raise ValueError("Only the volatile heartbeat may bypass the state barrier")
    _atomic_json(path, value, public=True)


def _atomic_json(path: Path, value: dict, *, public: bool = False) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            if public and os.name == "posix":
                # Only the published market documents are shared with the
                # ERP reader group. Private ledgers/cache/locks remain owner-only.
                # An SGID output directory supplies the reader group without
                # giving this separate writer identity any ERP group membership.
                os.fchmod(handle.fileno(), 0o640)
            json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def series_lock(path: Path):
    try:
        with os_file_lock(path):
            yield
    except BlockingIOError as exc:
        raise InputError("COLLECTOR_BUSY") from exc


def run_once(manifest_path: Path, csv_path: Path, output_directory: Path,
             state_directory: Path | None = None, allow_synthetic: bool = False,
             now: datetime | None = None) -> tuple[Path, dict]:
    now = now or datetime.now(timezone.utc)
    dataset = read_dataset(manifest_path, csv_path, now, allow_synthetic)
    output_directory.mkdir(parents=True, exist_ok=True)
    register_write_barrier(output_directory)
    state_directory = state_directory or output_directory / ".state"
    state_directory.mkdir(parents=True, exist_ok=True)
    series_id = dataset.manifest["seriesId"]
    destination = output_directory / (series_id + ".json")
    ledger_path = state_directory / (series_id + ".state.json")
    with series_lock(state_directory / (series_id + ".lock")):
        previous = None
        if ledger_path.exists():
            if ledger_path.stat().st_size > 8 * 1024 * 1024:
                raise InputError("import ledger is invalid; restore its trusted backup")
            try:
                previous = json.loads(ledger_path.read_text(encoding="utf-8"))
            except (ValueError, UnicodeError) as exc:
                raise InputError("import ledger is invalid; restore its trusted backup") from exc
            if not isinstance(previous, dict):
                raise InputError("import ledger must be an object")
        require_append_only(dataset, previous)
        from .engine import build_snapshot
        snapshot = build_snapshot(dataset, now)
        # Ledger first: after a crash, rerunning the same full append-only file is safe.
        # Publish uses same-directory replace, so readers see either complete generation.
        atomic_json(ledger_path, ledger_payload(dataset))
        atomic_json(destination, snapshot, public=True)
    return destination, snapshot


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Offline material benchmark forecasts from authorized CSV revisions")
    result.add_argument("--auto", action="store_true", help="automatically collect the three built-in public SHFE benchmarks")
    result.add_argument("--once", action="store_true", help="one bounded automatic collection cycle, without claiming a live daemon")
    result.add_argument("--interval", type=int, default=900, help="automatic poll interval, 900..3600 seconds")
    result.add_argument("--history-days", type=int, default=1200, help="calendar-day history window, 3..3650")
    result.add_argument("--backfill-budget", type=int, default=30, help="maximum additional historical daily requests per cycle, 0..1000")
    result.add_argument("--configuration-revision", help="managed policy SHA-256, echoed without reinterpretation")
    result.add_argument("--run-id", help="managed process canonical UUID")
    result.add_argument("--manifest", type=Path)
    result.add_argument("--csv", type=Path)
    result.add_argument("--output-directory", required=True, type=Path)
    result.add_argument("--state-directory", type=Path, help="durable append-only ledger; default OUTPUT/.state")
    result.add_argument("--watch", type=int, metavar="SECONDS", help="check local files for updates (minimum 10 seconds)")
    result.add_argument("--allow-synthetic", action="store_true", help="isolated tests only; output remains marked synthetic")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if bool(args.configuration_revision) != bool(args.run_id):
        parser().error("configuration revision and run id must be supplied together")
    if args.configuration_revision:
        import re
        if not re.fullmatch(r"[0-9a-f]{64}", args.configuration_revision):
            parser().error("invalid configuration revision")
        try:
            if str(uuid.UUID(args.run_id)) != args.run_id:
                raise ValueError()
        except ValueError:
            parser().error("invalid managed run id")
    if args.auto:
        if args.manifest or args.csv or args.watch is not None or args.allow_synthetic or args.state_directory:
            parser().error("--auto cannot be combined with manual CSV/test options")
        if not (900 <= args.interval <= 3600 and 3 <= args.history_days <= 3650 and 0 <= args.backfill_budget <= 1000):
            parser().error("automatic interval/history/backfill budget exceeds supported bounds")
        from .autofeed import run_auto
        return run_auto(args)
    if args.once or not args.manifest or not args.csv:
        parser().error("use --auto [--once], or supply both --manifest and --csv")
    if args.configuration_revision:
        parser().error("managed policy acknowledgement requires --auto")
    if args.watch is not None and args.watch < 10:
        parser().error("--watch must be at least 10 seconds")
    last_signature = None
    while True:
        try:
            signature = tuple((path.stat().st_mtime_ns, path.stat().st_size)
                              for path in (args.manifest, args.csv))
            if signature != last_signature:
                path, snapshot = run_once(args.manifest, args.csv, args.output_directory,
                                          args.state_directory, args.allow_synthetic)
                print(json.dumps({"output": str(path.resolve()), "status": snapshot["status"],
                                  "reasonCodes": snapshot["reasonCodes"],
                                  "dataAsOf": snapshot["dataAsOf"], "datasetDigest": snapshot["datasetDigest"]}), flush=True)
                last_signature = signature
        except (InputError, OSError, ValueError, RuntimeError) as exc:
            print("material-forecast: " + str(exc), file=sys.stderr, flush=True)
            if args.watch is None:
                return 2
        if args.watch is None:
            return 0
        try:
            time.sleep(args.watch)
        except KeyboardInterrupt:
            return 0
