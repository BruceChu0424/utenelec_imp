#!/usr/bin/env python3
"""Run every Flutter test file once and reconcile the real JSON reporter stream.

Flutter 3.44.2 commands/test.dart enumerates test/**/*_test.dart without following
directory links. test/runner.dart supports expanded stdout and an additional
native JSON file reporter in the same execution.
Its runtime root-group testCount, testStart/testDone and allSuites/done events
provide execution evidence; Dart source is never used to guess a test count.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import time
from urllib.parse import unquote, urlsplit

from backend_test_shards import digest, read_json, source_identity, write_json

ROOT = Path(__file__).resolve().parents[2]
VERSION = 3
FLUTTER_VERSION = "3.44.2"
PROTOCOL_VERSION = "0.1.1"
SHARDS = 8
COMMAND_OPTIONS = ("test", "--no-pub", "--reporter", "expanded", "--no-fail-fast")
REPORT_ROOT = "build/flutter-ci-reports"
WORKER_PATH = "test/.uten-ci-codec-worker.js"
WORKER_SOURCE = "web/uten_data_codec_worker.js"
BROWSER_OPTIONS = (*COMMAND_OPTIONS, "--platform", "chrome",
                   "--dart-define=UTEN_DATA_CODEC_WORKER_PATH=/.uten-ci-codec-worker.js")
BROWSER_FILES = (
    "test/shared/drafts/form_draft_storage_browser_test.dart",
    "test/shared/drafts/form_draft_history_browser_test.dart",
    "test/device_audit_receipt_storage_web_test.dart",
    "test/features/production/models/material_quantity_apportionment_test.dart",
    "test/attachments/attachment_media_preview_browser_test.dart",
    "test/core/web_update_bridge_browser_test.dart",
)
# The pinned SDK loader emits no LoadSuite at all for this library selector.
# This is platform metadata, not a parser/count of test declarations. Unknown
# selectors are never an excuse for a missing execution report.
BROWSER_LIBRARY = re.compile(r"\A@TestOn\((['\"])browser\1\)\s*library\s*;")
STARTUP_BANNER = re.compile(r"Flutter assets will be downloaded from https://[^\s]+\. Make sure you trust this source!\Z")


def ci_identity():
    return {key: os.environ.get(key) for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")}


def sha256(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def check_stderr(path):
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    if re.search(r"(?m)^(?:Unhandled exception:|ERROR:|Error:|[^\r\n]*\.dart:\d+:\d+: Error:)", text):
        raise ValueError("Flutter tool error on stderr")


def file_reporter_option(number):
    if not (type(number) is int and 0 <= number < SHARDS or number == "browser"):
        raise ValueError("invalid Flutter report owner")
    return f"--file-reporter=json:{REPORT_ROOT}/shard-{number}/machine.jsonl"


def report_directory(output, number, root):
    root = Path(root).resolve()
    supplied = Path(output)
    if ".." in supplied.parts:
        raise ValueError("Flutter output must use the fixed report root")
    supplied = supplied if supplied.is_absolute() else root / supplied
    expected = root / REPORT_ROOT
    if supplied.absolute() != expected:
        raise ValueError("Flutter output must use the fixed report root")
    for parent in (root / "build", expected):
        if (parent.is_symlink() or getattr(parent, "is_junction", lambda: False)()
                or parent.exists() and not parent.is_dir() or not parent.resolve().is_relative_to(root)):
            raise ValueError("linked/special Flutter report output")
    file_reporter_option(number)
    return expected / f"shard-{number}"


def test_path(value):
    if (not isinstance(value, str) or not value.startswith("test/")
            or not value.endswith("_test.dart") or any(c in value for c in "\\:?\x00#\r\n&|<>%")
            or any(part in {"", ".", ".."} for part in value.split("/"))
            or PurePosixPath(value).is_absolute()):
        raise ValueError("invalid or selectable Flutter test file path")
    return value


def inventory(root=ROOT):
    root = Path(root)
    if not (root / "test").is_dir() or (root / "test").is_symlink():
        raise ValueError("Flutter test/ must be a real directory")
    rows = []
    aliases = set()
    for directory, dirs, files in os.walk(root / "test", followlinks=False):
        dirs[:] = sorted(name for name in dirs if not (Path(directory) / name).is_symlink())
        for name in sorted(files):
            if not name.endswith("_test.dart"):
                continue
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                raise ValueError("test-file links/special nodes cannot supply test evidence")
            relative = test_path(path.relative_to(root).as_posix())
            if relative.casefold() in aliases:
                raise ValueError("case-aliased Flutter test files")
            aliases.add(relative.casefold())
            rows.append({"path": relative, "bytes": path.stat().st_size,
                         "sha256": sha256(path),
                         "vm_platform_skip": bool(BROWSER_LIBRARY.match(path.read_text(encoding="utf-8-sig")))})
    return sorted(rows, key=lambda row: row["path"])


def make_plan(files, count, history, source):
    if (type(count) is not int or not 1 <= count <= SHARDS or len(files) < count
            or sum(not row["vm_platform_skip"] for row in files) < count):
        raise ValueError("one to eight nonempty file partitions are required")
    timings = history.get("durations_seconds", {}) if isinstance(history, dict) else {}
    weighted = []
    for row in files:
        seconds = timings.get(row["path"])
        known = type(seconds) in {int, float} and math.isfinite(seconds) and seconds > 0
        weighted.append({**row, "weight": 0.0 if row["vm_platform_skip"] else float(seconds) if known else max(1.0, row["bytes"] / 2048),
                         "weight_source": "source-owned browser-only (no VM suite)" if row["vm_platform_skip"] else "historical_seconds" if known else "source_bytes/2048"})
    buckets = [{"id": number, "files": [], "weight": 0.0} for number in range(count)]
    for row in sorted(weighted, key=lambda row: (-row["weight"], row["path"])):
        bucket = min(buckets, key=lambda item: (item["weight"], item["id"]))
        bucket["files"].append(row["path"])
        bucket["weight"] += row["weight"]
    for bucket in buckets:
        bucket["files"].sort()
    plan = {"schema_version": VERSION, "source": source, "ci": ci_identity(), "flutter_version": FLUTTER_VERSION,
            "command_options": list(COMMAND_OPTIONS), "browser_options": list(BROWSER_OPTIONS),
            "browser_files": list(BROWSER_FILES), "files": weighted, "shards": buckets}
    return {**plan, "plan_hash": digest(plan)}


def validate_plan(plan, root=ROOT, check_source=True):
    if (type(plan.get("schema_version")) is not int or plan.get("schema_version") != VERSION or plan.get("flutter_version") != FLUTTER_VERSION
            or plan.get("command_options") != list(COMMAND_OPTIONS)
            or plan.get("browser_options") != list(BROWSER_OPTIONS) or plan.get("browser_files") != list(BROWSER_FILES)
            or plan.get("plan_hash") != digest({k: v for k, v in plan.items() if k != "plan_hash"})):
        raise ValueError("invalid Flutter plan version, command, or fingerprint")
    files, shards = plan["files"], plan["shards"]
    if any(type(row.get("vm_platform_skip")) is not bool or type(row.get("bytes")) is not int
           or row["bytes"] < 0 or not re.fullmatch(r"[a-f0-9]{64}", row.get("sha256", "")) for row in files):
        raise ValueError("invalid source file or platform metadata")
    paths = [test_path(row["path"]) for row in files]
    if (len(set(plan["browser_files"])) != len(plan["browser_files"])
            or not set(plan["browser_files"]) <= set(paths)
            or not {row["path"] for row in files if row["vm_platform_skip"]} <= set(plan["browser_files"])):
        raise ValueError("fixed Chrome cohort must cover every VM-inapplicable browser library")
    assigned = [path for shard in shards for path in shard["files"]]
    if (not paths or len(set(paths)) != len(paths) or Counter(paths) != Counter(assigned)
            or any(value != 1 for value in Counter(assigned).values())
            or not 1 <= len(shards) <= SHARDS
            or any(type(row["id"]) is not int for row in shards)
            or [row["id"] for row in shards] != list(range(len(shards)))
            or any(not row["files"] for row in shards)):
        raise ValueError("every test file must belong to exactly one nonempty shard")
    if check_source:
        if plan.get("ci") != ci_identity():
            raise ValueError("Flutter plan belongs to another workflow run/attempt")
        workflow_sha = os.environ.get("GITHUB_SHA")
        if workflow_sha is not None and plan["source"]["sha"] != workflow_sha:
            raise ValueError("Flutter checkout differs from the workflow target SHA")
        if plan["source"] != source_identity(root):
            raise ValueError("source SHA/content differs from the complete Flutter plan")
        actual = inventory(root)
        projected = [{key: row[key] for key in ("path", "bytes", "sha256", "vm_platform_skip")} for row in files]
        if actual != sorted(projected, key=lambda row: row["path"]):
            raise ValueError("complete file inventory or source-owned platform skip differs")
    return plan


def _integer(value, label):
    if type(value) is not int or value < 0:
        raise ValueError("invalid JSON reporter " + label)
    return value


def suite_path(value, root):
    if not isinstance(value, str):
        raise ValueError("missing suite file path")
    if value.startswith("file:"):
        parsed = urlsplit(value)
        if parsed.query or parsed.fragment or parsed.netloc not in {"", "localhost"}:
            raise ValueError("selectable or foreign suite URI")
        value = unquote(parsed.path)
        if os.name == "nt" and re.match(r"^/[A-Za-z]:/", value):
            value = value[1:]
    path = Path(value)
    if not path.is_absolute():
        path = Path(root) / path
    try:
        return test_path(path.resolve().relative_to(Path(root).resolve()).as_posix())
    except ValueError as error:
        raise ValueError("suite outside the assigned checkout") from error


def parse_events(path, expected_files, root=ROOT, platform_skips=(), platform="vm"):
    expected = set(expected_files)
    allowed_missing = set(platform_skips)
    if not allowed_missing <= expected:
        raise ValueError("platform skip outside the assigned file set")
    suites, groups, starts, ends, ids, runtime_skips = {}, {}, {}, {}, set(), {}
    roots = {}
    start_seen = False
    done_seen = False
    all_suites = None
    errors = []
    event_count = 0
    elapsed = 0
    with Path(path).open(encoding="utf-8-sig") as source:
        for number, raw in enumerate(source, 1):
            raw = raw.rstrip("\r\n")
            if not raw.strip():
                continue
            try:
                event = json.loads(raw)
            except ValueError as error:
                if not start_seen and STARTUP_BANNER.fullmatch(raw):
                    continue
                raise ValueError(f"non-JSON Flutter output at line {number}") from error
            # flutter_tools/test/event_printer.dart wraps its one process-start
            # notification in a JSON array between the test_core reporter events.
            if (isinstance(event, list) and not done_seen and start_seen and len(event) == 1
                    and isinstance(event[0], dict) and set(event[0]) == {"event", "params"}
                    and event[0]["event"] == "test.startedProcess"
                    and isinstance(event[0]["params"], dict) and set(event[0]["params"]) == {"vmServiceUri"}
                    and (event[0]["params"]["vmServiceUri"] is None or isinstance(event[0]["params"]["vmServiceUri"], str))):
                continue
            if not isinstance(event, dict) or not isinstance(event.get("type"), str) or done_seen:
                raise ValueError("invalid JSON event or output after terminal done")
            kind = event["type"]
            event_count += 1
            elapsed = max(elapsed, _integer(event.get("time"), "event time"))
            if kind == "start":
                if start_seen or event_count != 1 or event.get("protocolVersion") != PROTOCOL_VERSION:
                    raise ValueError("invalid/duplicate Flutter JSON protocol start")
                start_seen = True
                continue
            if not start_seen:
                raise ValueError("Flutter events preceded protocol start")
            if kind in {"suite", "group", "testStart"}:
                value = event[{"suite": "suite", "group": "group", "testStart": "test"}[kind]]
                identity = _integer(value["id"], "identity")
                if identity in ids:
                    raise ValueError("duplicate reporter identity")
                ids.add(identity)
                if kind == "suite":
                    owner = suite_path(value["path"], root)
                    if value.get("platform") != platform or owner not in expected or owner in suites.values():
                        raise ValueError("foreign platform, unexpected or duplicate test file suite")
                    suites[identity] = owner
                else:
                    owner = _integer(value["suiteID"], "suite identity")
                    if owner not in suites:
                        raise ValueError("group/test references an unknown suite")
                    metadata = value.get("metadata")
                    if not isinstance(metadata, dict) or type(metadata.get("skip")) is not bool:
                        raise ValueError("missing native reporter skip metadata")
                    if kind == "group":
                        parent = value.get("parentID")
                        if parent is not None and (parent not in groups or groups[parent]["suiteID"] != owner):
                            raise ValueError("unknown/foreign parent group")
                        _integer(value["testCount"], "runtime group test count")
                        if parent is None:
                            if owner in roots:
                                raise ValueError("duplicate root test group")
                            roots[owner] = value["testCount"]
                        groups[identity] = value
                    else:
                        if (not isinstance(value.get("name"), str) or not isinstance(value.get("groupIDs"), list)
                                or any(group not in groups or groups[group]["suiteID"] != owner for group in value["groupIDs"])):
                            raise ValueError("test has invalid name/group ownership")
                        starts[identity] = {**value, "started_ms": event["time"]}
            elif kind == "testDone":
                identity = _integer(event.get("testID"), "completed test identity")
                if identity not in starts or identity in ends:
                    raise ValueError("missing start or duplicate test completion")
                if type(event.get("skipped")) is not bool or type(event.get("hidden")) is not bool:
                    raise ValueError("invalid test completion flags")
                if event.get("result") != "success":
                    errors.append("failed/error/cancelled test: " + starts[identity]["name"])
                ends[identity] = event
            elif kind == "error":
                errors.append("Flutter error event")
            elif kind == "print":
                if event.get("testID") not in starts:
                    raise ValueError("print references unknown test")
                if event.get("messageType") == "skip" and str(event.get("message", "")).strip():
                    runtime_skips[event["testID"]] = event["message"]
            elif kind == "allSuites":
                if all_suites is not None:
                    raise ValueError("duplicate allSuites declaration")
                all_suites = _integer(event.get("count"), "allSuites count")
            elif kind == "done":
                done_seen = True
                if event.get("success") is not True:
                    errors.append("runner did not complete successfully")
            elif kind != "debug":
                raise ValueError("unsupported Flutter reporter event: " + kind)
    if not start_seen or not done_seen or all_suites != len(suites) or not suites or set(starts) != set(ends):
        raise ValueError("incomplete runner/suite/test lifecycle")
    observed = set(suites.values())
    if expected - observed != allowed_missing or observed & allowed_missing:
        raise ValueError("missing/unexpected files or incorrect source-owned platform skips")
    actual_counts = Counter(starts[key]["suiteID"] for key, end in ends.items() if not end["hidden"])
    for identity in suites:
        if actual_counts[identity] != roots.get(identity, 0):
            raise ValueError("actual tests differ from the runtime root-group inventory")
    skipped, tests, durations = [], [], {}
    for identity, test in starts.items():
        end = ends[identity]
        if end["time"] < test["started_ms"]:
            raise ValueError("test completion preceded its start")
        file = suites[test["suiteID"]]
        duration = max(0, end["time"] - test["started_ms"]) / 1000
        durations[file] = durations.get(file, 0) + duration
        if end["hidden"]:
            continue
        tests.append({"file": file, "name": test["name"], "id": identity, "skipped": end["skipped"]})
        if end["skipped"]:
            declarations = [test["metadata"]] + [groups[key]["metadata"] for key in test["groupIDs"]]
            declared = [row for row in declarations if row["skip"]]
            if not declared and identity not in runtime_skips:
                raise ValueError("skip without native declaration/group or runtime reason")
            skipped.append({"file": file, "name": test["name"], "reason": runtime_skips.get(identity)
                            or next((row.get("skipReason") for row in declared if row.get("skipReason")), None)
                            or "native boolean skip declaration"})
    if errors:
        raise ValueError("; ".join(errors[:10]))
    return {"complete": True, "events": event_count, "files": sorted(observed), "tests": tests,
            "testcase_count": len(tests), "skipped": skipped, "platform_skipped_files": sorted(allowed_missing),
            "elapsed_seconds": elapsed / 1000, "durations_seconds": durations}


def verify_worker(root):
    source, worker = Path(root) / WORKER_SOURCE, Path(root) / WORKER_PATH
    if (source.is_symlink() or worker.is_symlink() or not source.is_file() or not worker.is_file()
            or (Path(root) / "web").is_symlink() or (Path(root) / "test").is_symlink()
            or sha256(source) != sha256(worker)):
        raise ValueError("codec worker is missing, linked or differs from the reviewed source")
    return {"path": WORKER_PATH, "source": WORKER_SOURCE, "sha256": sha256(source)}


def require_browser_execution(actual, files):
    executed = {test["file"] for test in actual["tests"] if not test["skipped"]}
    if executed != set(files):
        raise ValueError("Chrome cohort contains files without real non-skipped test execution")


def run_shard(plan, number, output, flutter="flutter", root=ROOT):
    validate_plan(plan, root)
    if type(number) is not int or number not in range(len(plan["shards"])):
        raise ValueError("unknown shard")
    return _run_cohort(plan, number, plan["shards"][number]["files"], COMMAND_OPTIONS, "vm", output, flutter, root)


def run_browser(plan, output, flutter="flutter", root=ROOT):
    validate_plan(plan, root)
    if not plan["browser_files"]:
        raise ValueError("empty Chrome cohort")
    return _run_cohort(plan, "browser", plan["browser_files"], BROWSER_OPTIONS, "chrome", output, flutter, root)


def _run_cohort(plan, number, files, options, mode, output, flutter, root):
    directory = report_directory(output, number, root)
    directory.mkdir(parents=True, exist_ok=False)
    command = [shutil.which(flutter) or flutter, *options, file_reporter_option(number), *files]
    record = {"schema_version": VERSION, "source": plan["source"], "plan_hash": plan["plan_hash"],
              "ci": ci_identity(), "mode": mode, "shard": number, "files": files, "command": command, "exit_code": None, "complete": False}
    started = time.monotonic()
    try:
        if mode == "chrome":
            record["worker"] = verify_worker(root)
        version = subprocess.run([command[0], "--version", "--machine"], cwd=root,
                                 capture_output=True, text=True, encoding="utf-8", check=False)
        payload = version.stdout[version.stdout.find("{"):] if "{" in version.stdout else ""
        sdk = json.loads(payload)
        if version.returncode != 0 or sdk.get("frameworkVersion") != plan["flutter_version"]:
            raise ValueError("Flutter executable does not match the pinned SDK")
        record["sdk"] = {key: sdk.get(key) for key in ("frameworkVersion", "frameworkRevision", "dartSdkVersion")}
        with (directory / "stdout.log").open("xb") as stdout, (directory / "stderr.log").open("xb") as stderr:
            process = subprocess.run(command, cwd=root, stdout=stdout, stderr=stderr, check=False)
        record["exit_code"] = process.returncode
        record["stdout_sha256"] = sha256(directory / "stdout.log")
        record["stderr_sha256"] = sha256(directory / "stderr.log")
        if mode == "chrome":
            if verify_worker(root) != record["worker"]:
                raise ValueError("codec worker changed during Chrome execution")
            record["worker"]["verified_after"] = True
        record["source_after"] = source_identity(root)
        record["machine_sha256"] = sha256(directory / "machine.jsonl")
        check_stderr(directory / "stderr.log")
        skips = [row["path"] for row in plan["files"] if mode == "vm" and row["vm_platform_skip"] and row["path"] in files]
        record["results"] = parse_events(directory / "machine.jsonl", files, root, skips, "vm" if mode == "vm" else "chrome")
        if mode == "chrome":
            require_browser_execution(record["results"], files)
        record["complete"] = process.returncode == 0 and record["source_after"] == plan["source"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        record["error"] = str(error)
    finally:
        record["elapsed_seconds"] = time.monotonic() - started
        write_json(directory / "report.json", record)
    print(f"Flutter shard {number}: complete={record['complete']}; log={directory / 'stdout.log'}; native={directory / 'machine.jsonl'}", flush=True)
    return record


def _verify_cohort(plan, reports, shard, options, mode, root):
    directory = reports / f"shard-{shard['id']}"
    if directory.is_symlink() or {path.name for path in directory.iterdir()} != {"report.json", "machine.jsonl", "stdout.log", "stderr.log"}:
        raise ValueError("invalid Flutter report ownership/files")
    if any(path.is_symlink() or not path.is_file() for path in directory.iterdir()):
        raise ValueError("linked/special Flutter evidence file")
    report = read_json(directory / "report.json")
    if (type(report.get("schema_version")) is not int or report.get("schema_version") != VERSION or report.get("source") != plan["source"]
            or report.get("source_after") != plan["source"] or report.get("plan_hash") != plan["plan_hash"]
            or report.get("ci") != plan.get("ci")
            or type(report.get("shard")) is not type(shard["id"]) or report.get("shard") != shard["id"] or report.get("mode") != mode or report.get("files") != shard["files"]
            or type(report.get("exit_code")) is not int or report.get("exit_code") != 0 or report.get("complete") is not True
            or report.get("sdk", {}).get("frameworkVersion") != plan["flutter_version"]
            or not isinstance(report.get("command"), list)
            or report["command"][1:] != [*options, file_reporter_option(shard["id"]), *shard["files"]]
            or not isinstance(report["command"][0], str)
            or report.get("machine_sha256") != sha256(directory / "machine.jsonl")
            or report.get("stdout_sha256") != sha256(directory / "stdout.log")
            or report.get("stderr_sha256") != sha256(directory / "stderr.log")):
        raise ValueError("failed, filtered, wrong-SHA or tampered Flutter report")
    skips = [row["path"] for row in plan["files"] if mode == "vm" and row["vm_platform_skip"] and row["path"] in shard["files"]]
    check_stderr(directory / "stderr.log")
    actual = parse_events(directory / "machine.jsonl", shard["files"], root, skips, "vm" if mode == "vm" else "chrome")
    if report.get("results") != actual:
        raise ValueError("producer summary differs from fresh JSON reconciliation")
    if mode == "chrome":
        expected_worker = {"path": WORKER_PATH, "source": WORKER_SOURCE,
                           "sha256": sha256(Path(root) / WORKER_SOURCE), "verified_after": True}
        if report.get("worker") != expected_worker:
            raise ValueError("Chrome report lacks exact codec worker provenance")
        require_browser_execution(actual, shard["files"])
    elif report.get("worker") is not None:
        raise ValueError("unexpected worker in VM report")
    return actual


def verify_reports(plan, reports, root=ROOT):
    validate_plan(plan, root)
    reports = Path(reports)
    if reports.is_symlink():
        raise ValueError("Flutter reports must not be a link")
    expected_directories = {f"shard-{row['id']}" for row in plan["shards"]}
    if plan["browser_files"]:
        expected_directories.add("shard-browser")
    existing = {path.name for path in reports.iterdir()}
    if existing - {"verification.json", "timings.json"} != expected_directories:
        raise ValueError("missing, duplicate or unexpected Flutter report shard")
    for name in ("verification.json", "timings.json"):
        path = reports / name
        if path.is_symlink() or path.exists() and not path.is_file():
            raise ValueError("summary output is a link or special node")
    completed = []
    for shard in plan["shards"]:
        actual = _verify_cohort(plan, reports, shard, COMMAND_OPTIONS, "vm", root)
        completed.append({"id": shard["id"], **actual})
    browser = None
    if plan["browser_files"]:
        browser = _verify_cohort(plan, reports, {"id": "browser", "files": plan["browser_files"]},
                                 BROWSER_OPTIONS, "chrome", root)
        platform_files = {row["path"] for row in plan["files"] if row["vm_platform_skip"]}
        if not platform_files <= set(browser["files"]):
            raise ValueError("a VM-inapplicable file lacks actual Chrome coverage")
    vm_files = {file for shard in completed for file in shard["files"]}
    chrome_files = set(browser["files"]) if browser else set()
    if vm_files | chrome_files != {row["path"] for row in plan["files"]}:
        raise ValueError("the planned source inventory lacks complete platform execution")
    summary = {"complete": True, "source": plan["source"], "plan_hash": plan["plan_hash"],
               "file_count": len(plan["files"]), "executed_file_count": len(vm_files | chrome_files),
               "vm_file_count": len(vm_files), "browser_file_count": len(chrome_files),
               "dual_platform_files": sorted(vm_files & chrome_files),
               "testcase_count": sum(row["testcase_count"] for row in completed)
                    + (browser["testcase_count"] if browser else 0),
               "skipped_count": sum(len(row["skipped"]) for row in completed) + (len(browser["skipped"]) if browser else 0),
               "shards": completed, "browser": browser,
               "browser_only_files": [row["path"] for row in plan["files"] if row["vm_platform_skip"]]}
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    planning = actions.add_parser("plan")
    planning.add_argument("--output", default="build/flutter-ci-plan")
    planning.add_argument("--shards", type=int, default=SHARDS)
    planning.add_argument("--history")
    running = actions.add_parser("run")
    running.add_argument("--plan", required=True)
    running.add_argument("--shard", type=int, required=True)
    running.add_argument("--output", default="build/flutter-ci-reports")
    running.add_argument("--flutter", default="flutter")
    browser = actions.add_parser("browser")
    browser.add_argument("--plan", required=True)
    browser.add_argument("--output", default="build/flutter-ci-reports")
    browser.add_argument("--flutter", default="flutter")
    verifying = actions.add_parser("verify")
    verifying.add_argument("--plan", required=True)
    verifying.add_argument("--reports", required=True)
    args = parser.parse_args()
    try:
        if args.action == "plan":
            source = source_identity(ROOT)
            plan = make_plan(inventory(ROOT), args.shards, read_json(args.history) if args.history else {}, source)
            validate_plan(plan)
            output = Path(args.output)
            if output.exists():
                raise ValueError("plan output already exists")
            write_json(output / "plan.json", plan)
            print(f"Planned all {len(plan['files'])} Flutter test files in {len(plan['shards'])} complete partitions")
        elif args.action in {"run", "browser"}:
            record = (run_shard(read_json(args.plan), args.shard, args.output, args.flutter)
                      if args.action == "run" else run_browser(read_json(args.plan), args.output, args.flutter))
            if not record["complete"]:
                raise ValueError(record.get("error", "Flutter process/source failed"))
        else:
            summary = verify_reports(read_json(args.plan), args.reports)
            write_json(Path(args.reports) / "verification.json", summary)
            timings = {path: duration for shard in summary["shards"] for path, duration in shard["durations_seconds"].items()}
            write_json(Path(args.reports) / "timings.json", {"schema_version": VERSION, "source": summary["source"], "durations_seconds": timings})
            print(f"Verified {summary['file_count']} whole-file VM assignments, {summary['browser_file_count']} Chrome files "
                  f"and {summary['testcase_count']} completed real test instances; unique executed files={summary['executed_file_count']}")
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        parser.exit(1, f"Complete Flutter gate failed: {error}\n")


if __name__ == "__main__":
    main()
