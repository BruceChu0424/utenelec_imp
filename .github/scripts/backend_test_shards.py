#!/usr/bin/env python3
"""Discover, balance, run and audit the *complete* Maven verify suite.

Timing history is only a scheduling hint. JUnit Platform discovery supplies the
inventory; fresh Surefire and Failsafe XML supplies the execution evidence.
Only the Python standard library is needed. Run --help for local/CI entry points.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import locale
import math
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
VERSION = 1
OPTIONAL_GATES = {
    "UTEN_RUN_PRODUCTION_STRESS",
    "UTEN_RUN_SALES_MONEY_PRESSURE",
    "UTEN_RUN_REHEARSAL_DB_TESTS",
}
EXPORTER = "com.uten.imp.migration.FlywayChecksumManifestExporterTest#exportsCanonicalFlywayChecksumsOnlyWhenExplicitlyRequested"
WORKBOOK_PROPERTY = "uten.cost.companyWorkbook"
WORKBOOK_REVIEW = "com.uten.imp.features.master.goods.costing.CostCompanyWorkbookReviewTest#preservesFortyDetailBlocksIncludingProductsAbsentFromTheThirtySevenRowSummary"


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def source_identity(root=ROOT):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root)
    def snapshot():
        return (git("rev-parse", "HEAD").strip(), git("ls-files", "--stage", "-z"),
                git("diff-files", "--raw", "--no-renames", "-z"), git("ls-files", "--others", "--exclude-standard", "-z"))
    before = snapshot()
    files = {}
    for entry in filter(None, before[1].decode().split("\0")):
        metadata, relative = entry.split("\t", 1)
        mode, blob, stage = metadata.split()
        if stage != "0":
            raise ValueError("Unmerged source index; resolve conflicts before creating test evidence")
        files[relative] = {"mode": mode, "blob": blob}
    raw_changes = before[2].decode().split("\0")
    mode_changes = {raw_changes[i + 1]: raw_changes[i].split()[1] for i in range(0, len(raw_changes) - 1, 2)}
    changed = sorted(set(mode_changes) | set(filter(None, before[3].decode().split("\0"))))
    def stats():
        return {relative: ((root / relative).lstat().st_mtime_ns, (root / relative).lstat().st_size)
                if (root / relative).exists() else None for relative in changed}
    before_stats = stats()
    present = [relative for relative in changed if before_stats[relative] is not None]
    if present:
        # Git applies the repository's text/binary attributes and checkout normalization.
        # Reuse canonical index blobs for unchanged files; don't reopen 10,000 cold files.
        payload = "".join(json.dumps(relative, ensure_ascii=False) + "\n" for relative in present).encode()
        hashes = subprocess.check_output(["git", "hash-object", "--stdin-paths"], input=payload, cwd=root).decode().splitlines()
        if len(hashes) != len(present):
            raise ValueError("Incomplete source hash inventory")
        for relative, blob in zip(present, hashes):
            mode = mode_changes.get(relative, files.get(relative, {}).get("mode", "100755" if os.name != "nt" and (root / relative).stat().st_mode & 0o111 else "100644"))
            files[relative] = {"mode": mode, "blob": blob}
    for relative in changed:
        if before_stats[relative] is None:
            files.pop(relative, None)
    if before != snapshot() or before_stats != stats():
        raise ValueError("Sources/index changed while capturing identity; retry after edits finish")
    return {"sha": before[0].decode(), "fingerprint": digest(files)}


def checked_plan(path, check_source=True):
    plan = read_json(path)
    expected_hash = digest({key: value for key, value in plan.items() if key != "plan_hash"})
    if plan.get("schema_version") != VERSION or plan.get("plan_hash") != expected_hash:
        raise ValueError("Invalid plan version/hash; generate a fresh plan")
    if check_source and plan["source"] != source_identity():
        raise ValueError("Source SHA/content changed after discovery; generate a fresh plan")
    assigned = [name for shard in plan["shards"] for name in shard["classes"]]
    names = [row["name"] for row in plan["classes"]]
    if Counter(assigned) != Counter(names) or any(count != 1 for count in Counter(names).values()):
        raise ValueError("Plan does not assign every discovered class exactly once")
    if not names or sorted(shard["id"] for shard in plan["shards"]) != list(range(len(plan["shards"]))):
        raise ValueError("Empty inventory or invalid shard IDs")
    return plan


def command_log(command, cwd, logfile, env=None):
    """Keep complete raw logs while streaming bounded, useful Maven progress."""
    logfile = Path(logfile)
    logfile.parent.mkdir(parents=True, exist_ok=True)
    print(f"Running {Path(command[0]).name}; log: {logfile}", flush=True)
    encoding = locale.getpreferredencoding(False)
    progress = re.compile(r"\[(?:INFO|WARNING|ERROR)\] (?:--- |Running |Tests run:|BUILD |Total time:|Finished at:)")
    with logfile.open("wb") as output, subprocess.Popen(command, cwd=cwd, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
        for raw in process.stdout:
            output.write(raw)
            line = raw.decode(encoding, errors="replace").rstrip()
            line = re.sub(r"\x1b\[[0-9;]*m", "", line)
            if progress.match(line):
                output.flush()
                print(f"[{logfile.parent.name}] {line[:1000]}", flush=True)
        code = process.wait()
    if code:
        print("\n".join(logfile.read_text(encoding=encoding, errors="replace").splitlines()[-35:]), flush=True)
    return code


def maven_executable(value):
    found = value or shutil.which("mvn") or shutil.which("mvn.cmd")
    if not found:
        raise ValueError("Maven not found; pass --maven /path/to/mvn")
    return found


def discover(output, maven):
    target = ROOT / "server" / f"target-shard-discovery-{uuid.uuid4().hex[:8]}"
    classpath = output / "classpath.txt"
    effective_pom = output / "effective-pom.xml"
    (output / "tmp").mkdir(exist_ok=True)
    command = [maven, "-B", "-ntp", "clean", "test-compile", "dependency:build-classpath", "help:effective-pom",
               f"-Duten.build.directory={target}", "-DincludeScope=test", f"-Dmdep.outputFile={classpath}",
               f"-Doutput={effective_pom}", f"-Duten.test.tmpdir={output / 'tmp'}", "-DskipTests=false", "-Dmaven.test.skip=false"]
    if command_log(command, ROOT / "server", output / "discovery-maven.log"):
        raise ValueError("JUnit discovery compilation failed; see discovery-maven.log")
    validate_maven_discovery(effective_pom)
    cp = os.pathsep.join([str(target / "test-classes"), str(target / "classes"), classpath.read_text(encoding="utf-8").strip()])
    java = str(Path(os.environ["JAVA_HOME"]) / "bin" / ("java.exe" if os.name == "nt" else "java")) if os.environ.get("JAVA_HOME") else shutil.which("java")
    if not java:
        raise ValueError("Java not found")
    inventory = output / "inventory.json"
    # An argument file also handles classpaths longer than Windows' command-line limit.
    argfile = output / "java-discovery.args"
    argfile.write_text("\n".join('"' + entry.replace("\\", "/").replace('"', '\\"') + '"'
                                  for entry in ["-cp", cp, "com.uten.imp.support.BackendTestInventory", str(target / "test-classes"), str(inventory)]) + "\n", encoding="utf-8")
    if command_log([java, "@" + str(argfile)], ROOT / "server", output / "discovery-java.log"):
        raise ValueError("JUnit discovery failed; see discovery-java.log")
    return read_json(inventory)["classes"]


def validate_maven_discovery(path):
    """Fail closed when Maven selection stops matching the documented default inventory."""
    root = ET.parse(path).getroot()
    ns = {"m": "http://maven.apache.org/POM/4.0.0"}
    unsupported = {"includes", "excludes", "includesFile", "excludesFile", "groups", "excludedGroups",
                   "includeJUnit5Engines", "excludeJUnit5Engines", "testClassesDirectory", "testSourceDirectory"}
    for plugin in root.findall("./m:build/m:plugins/m:plugin", ns):
        name = plugin.findtext("m:artifactId", namespaces=ns)
        if name not in {"maven-surefire-plugin", "maven-failsafe-plugin"}:
            continue
        for configuration in plugin.findall(".//m:configuration", ns):
            for child in configuration.iter():
                if child.tag.rsplit("}", 1)[-1] in unsupported:
                    raise ValueError(f"{name} custom selection {child.tag} needs inventory support before sharding")


def balance(classes, shard_count, history):
    if shard_count < 1 or shard_count > len(classes):
        raise ValueError("Shard count must be between 1 and discovered class count")
    historical = history.get("classes", {})
    if any(not math.isfinite(float(row.get("seconds", 0))) or float(row.get("seconds", 0)) < 0 for row in historical.values()):
        raise ValueError("Historical durations must be finite and nonnegative")
    known = [float(row["seconds"]) for row in historical.values() if float(row.get("seconds", 0)) > 0]
    fallback = statistics.median(known) if known else 10.0
    shards = [{"id": i, "classes": [], "estimated_seconds": 0.0} for i in range(shard_count)]
    def estimate(row):
        return max(0.001, float(historical.get(row["name"], {}).get("seconds", fallback)))
    # Failsafe tests run on one worker after packaging; never omitted from verify.
    integrations = sorted((row for row in classes if row["phase"] == "failsafe"), key=lambda row: row["name"])
    for row in integrations:
        shards[0]["classes"].append(row["name"])
        shards[0]["estimated_seconds"] += estimate(row)
    for row in sorted((row for row in classes if row["phase"] == "surefire"), key=lambda row: (-estimate(row), row["name"])):
        shard = min(shards, key=lambda part: (part["estimated_seconds"], part["id"]))
        shard["classes"].append(row["name"])
        shard["estimated_seconds"] += estimate(row)
    for shard in shards:
        shard["classes"].sort()
        shard["estimated_seconds"] = round(shard["estimated_seconds"], 3)
    return shards


def make_plan(classes, shard_count, history, source):
    seen = set()
    for row in classes:
        if row["name"] in seen or row["phase"] not in ("surefire", "failsafe") or not row["methods"]:
            raise ValueError(f"Duplicate/invalid discovered class: {row['name']}")
        seen.add(row["name"])
        ids = [method["id"] for method in row["methods"]]
        if len(ids) != len(set(ids)):
            # Surefire XML cannot distinguish overloaded methods reliably across versions.
            raise ValueError(f"Ambiguous overloaded test method in {row['name']}; explicit inventory support required")
    return {"schema_version": VERSION, "source": source, "classes": classes,
            "shards": balance(classes, shard_count, history), "coverage": "full",
            "history_source": history.get("source_run", "no history; equal initial estimates"),
            "optional_gates": sorted(OPTIONAL_GATES)}


def plan_command(args):
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    before = source_identity()
    classes = discover(output, maven_executable(args.maven))
    if before != source_identity():
        raise ValueError("Sources changed during discovery; retry after edits finish")
    history_path = Path(args.history) if args.history else ROOT / ".github" / "test-timings" / "backend.json"
    history = read_json(history_path) if history_path.is_file() else {}
    plan = make_plan(classes, args.shards, history, before)
    plan["plan_hash"] = digest(plan)
    write_json(output / "plan.json", plan)
    print(f"Discovered {len(classes)} classes, {sum(len(row['methods']) for row in classes)} methods; plan: {output / 'plan.json'}")
    for shard in plan["shards"]:
        print(f"  shard {shard['id']}: {len(shard['classes'])} classes; scheduling estimate {shard['estimated_seconds']:.1f}s")
    return 0


def xml_cases(directory):
    records, errors = [], []
    for phase in ("surefire", "failsafe"):
        for path in sorted((Path(directory) / f"{phase}-reports").glob("TEST-*.xml")):
            try:
                root = ET.parse(path).getroot()
                elements = list(root.iter("testcase"))
                properties = {item.get("name"): item.get("value", "") for item in root.findall("./properties/property")}
                # Truncated/mismatched XML totals must not silently count as coverage.
                if root.tag == "testsuite" and int(root.attrib.get("tests", len(elements))) != len(elements):
                    errors.append(f"XML count mismatch: {path.name}")
                for attribute, element in (("failures", "failure"), ("errors", "error"), ("skipped", "skipped")):
                    actual = sum(case.find(element) is not None for case in elements)
                    if attribute in root.attrib and int(root.attrib[attribute]) != actual:
                        errors.append(f"XML {attribute} count mismatch: {path.name}")
                for case in elements:
                    skipped = case.find("skipped")
                    failure = case.find("failure")
                    error = case.find("error")
                    status = "failed" if failure is not None or error is not None else "skipped" if skipped is not None else "passed"
                    records.append({"phase": phase, "class": case.attrib.get("classname", ""),
                                    "name": case.attrib.get("name", ""), "status": status,
                                    "seconds": float(case.attrib.get("time", "0")),
                                    "suite": root.attrib.get("name", case.attrib.get("classname", "")),
                                    "suite_seconds": float(root.attrib.get("time", "0")),
                                    "os_name": properties.get("os.name", ""),
                                    # Record presence only; private local workbook paths never enter summaries.
                                    "workbook_property_present": WORKBOOK_PROPERTY in properties,
                                    "skip_reason": (skipped.attrib.get("message", "") + " " + (skipped.text or "")).strip() if skipped is not None else ""})
            except (ET.ParseError, OSError, ValueError) as exc:
                errors.append(f"Unreadable XML {path.name}: {exc}")
    return records, errors


def method_identity(case, methods):
    # Standard Surefire JUnit Platform names: method, method(args), method(args)[n].
    prefix = case["class"] + "#"
    name = re.split(r"[\[(]", case["name"], maxsplit=1)[0]
    candidate = prefix + name
    return candidate if candidate in methods else None


def os_family(os_name):
    if os_name == "Linux":
        return "LINUX"
    if re.fullmatch(r"Windows(?: [A-Za-z0-9 ._-]+)?", os_name):
        return "WINDOWS"
    if os_name == "Mac OS X":
        return "MAC"
    return None


def allowed_skip(case, method, runtime_platform=None):
    reason = case["skip_reason"]
    if method["id"] == EXPORTER:
        return "Set -Duten.exportFlywayChecksums=true only in the signed-release CI job" in reason
    if method["id"] == WORKBOOK_REVIEW:
        return (method.get("system_property_gates") == [{"named": WORKBOOK_PROPERTY, "matches": ".+"}]
                and not case.get("workbook_property_present", False)
                and reason == f"System property [{WORKBOOK_PROPERTY}] does not exist")
    os_name = case.get("os_name", "")
    current_os = os_family(os_name)
    actual_os = {"linux": "LINUX", "win32": "WINDOWS", "darwin": "MAC"}.get(runtime_platform)
    if current_os and current_os == actual_os and reason == f"Disabled on operating system: {os_name}":
        # Only a real @EnabledOnOs declaration may explain the platform skip.
        # Architecture/custom conditions stay fail-closed until explicitly supported.
        return any(gate.get("value") and not gate.get("architectures")
                   and set(gate["value"]) <= {"LINUX", "WINDOWS", "MAC"}
                   and current_os not in gate["value"] for gate in method.get("enabled_on_os", []))
    return any(gate in OPTIONAL_GATES and gate in reason and "Environment variable" in reason
               for gate in method.get("environment_gates", []))


def audit_cases(plan, shard_id, cases, maven_exit, runtime_platform=None):
    shard = next(part for part in plan["shards"] if part["id"] == shard_id)
    classes = {row["name"]: row for row in plan["classes"] if row["name"] in shard["classes"]}
    methods = {method["id"]: {**method, "phase": row["phase"], "owner": row["name"]}
               for row in classes.values() for method in row["methods"]}
    errors = []
    if maven_exit != 0:
        errors.append(f"Maven exited {maven_exit}; compile, test and packaging phases must all succeed")
    counts, testcase_ids, timings, failed_classes, skipped = Counter(), Counter(), defaultdict(dict), set(), []
    for case in cases:
        if case["status"] == "failed":
            # @BeforeAll errors are class-level XML cases and have no method identity.
            owner = next((name for name in classes if case["class"] == name or case["class"].startswith(name + "$")), None)
            if owner:
                failed_classes.add(owner)
        identifier = method_identity(case, methods)
        exact = (case["phase"], case["class"], case["name"])
        testcase_ids[exact] += 1
        if not identifier:
            errors.append(f"Unexpected test case: {case['class']}#{case['name']} ({case['phase']})")
            continue
        method = methods[identifier]
        counts[identifier] += 1
        # Suite wall time includes @BeforeAll/Flyway/Spring startup. Testcase sums lose it.
        timings[method["owner"]][case.get("suite", case["class"])] = case.get("suite_seconds", case["seconds"])
        if case["phase"] != method["phase"]:
            errors.append(f"Wrong Maven phase: {identifier}")
        if case["status"] == "failed":
            errors.append(f"Failed test: {identifier}")
            failed_classes.add(method["owner"])
        elif case["status"] == "skipped":
            permitted = allowed_skip(case, method, runtime_platform)
            skipped.append({"id": identifier, "reason": case["skip_reason"], "permitted": permitted,
                            "os_name": case.get("os_name", ""),
                            "workbook_property_present": case.get("workbook_property_present", False)})
            if not permitted:
                errors.append(f"Unexpected skip: {identifier}: {case['skip_reason']}")
    for exact, count in testcase_ids.items():
        if count != 1:
            errors.append(f"Duplicate test case ({count} copies): {'#'.join(exact)}")
    for identifier, method in methods.items():
        if counts[identifier] == 0:
            errors.append(f"Missing discovered method: {identifier}")
        elif method["kind"] == "test" and counts[identifier] != 1:
            errors.append(f"Static test executed {counts[identifier]} times: {identifier}")
    return {"errors": errors, "complete": not errors, "testcase_count": len(cases),
            "method_counts": dict(sorted(counts.items())), "skipped": skipped,
            "failed_classes": sorted(failed_classes),
            # The outer suite includes its nested suite's wall time; avoid counting it twice.
            "class_seconds": {name: round(suites.get(name, sum(suites.values())), 6) for name, suites in sorted(timings.items())}}


def write_includes(path, names):
    # No -Dtest comma list: includes files avoid Windows command-length limits.
    path.write_text("\n".join(name.replace(".", "/") + ".java" for name in names) + ("\n" if names else "__no_discovered_tests__.java\n"), encoding="utf-8")


def heap_size(value):
    """A positive Java heap size, never an arbitrary JVM argument or shell fragment."""
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+[kKmMgG]?", value):
        raise ValueError("heap size must be a positive integer with an optional K, M or G suffix")
    suffix = value[-1].lower()
    number = value[:-1] if suffix in "kmg" else value
    multiplier = {"k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}.get(suffix, 1)
    if not 0 < int(number) * multiplier <= (1 << 63) - 1:
        raise ValueError("heap size must be positive and fit in a signed 64-bit byte count")
    return value


def heap_options(parser):
    parser.add_argument("--jvm-max-heap", type=heap_size,
                        help="Optional test JVM maximum heap, e.g. 4g; preserves agent and temp arguments")
    parser.add_argument("--maven-max-heap", type=heap_size,
                        help="Optional Maven parent maximum heap, e.g. 1536m; appends to MAVEN_OPTS")


def run_one(plan, shard_id, output, maven, unfiltered=False, jvm_max_heap=None, maven_max_heap=None):
    # Validate again for callers that use this module directly rather than argparse.
    if jvm_max_heap is not None:
        jvm_max_heap = heap_size(jvm_max_heap)
    if maven_max_heap is not None:
        maven_max_heap = heap_size(maven_max_heap)
    directory = output / f"shard-{shard_id}"
    # Existing report directories are never reused as evidence (even after an interrupted run).
    directory.mkdir(parents=True, exist_ok=False)
    target = ROOT / "server" / f"target-shard-{shard_id}-{uuid.uuid4().hex[:8]}"
    temp = directory / "tmp"
    temp.mkdir()
    chosen = set(plan["shards"][shard_id]["classes"])
    include_args = []
    for phase in ("surefire", "failsafe"):
        includes = directory / f"{phase}-includes.txt"
        write_includes(includes, [row["name"] for row in plan["classes"] if row["name"] in chosen and row["phase"] == phase])
        include_args.append(f"-D{phase}.includesFile={includes}")
    env = os.environ.copy()
    env["UTEN_RUN_DB_TESTS"] = "true"
    env["UTEN_TEST_SHARD_ID"] = str(shard_id)
    if maven_max_heap is not None:
        existing = env.get("MAVEN_OPTS", "")
        env["MAVEN_OPTS"] = (existing + " " if existing else "") + f"-Xmx{maven_max_heap}"
    # Pressure tests and company-data rehearsals need separately provisioned/approved inputs.
    for name in OPTIONAL_GATES:
        if env.get(name, "").lower() == "true":
            raise ValueError(f"{name}=true belongs to its dedicated workflow, not this ordinary full-suite runner")
    command = [maven, "-B", "-ntp", "clean", "verify", f"-Duten.build.directory={target}",
               "-DskipTests=false", "-Dmaven.test.skip=false", "-DskipITs=false", "-Dmaven.test.failure.ignore=false",
               "-DforkCount=1", "-DreuseForks=true", "-Djunit.jupiter.execution.parallel.enabled=false",
               f"-Djava.io.tmpdir={temp}", f"-Duten.test.tmpdir={temp}",
               *([f"-Duten.test.jvm.heap.args=-Xmx{jvm_max_heap}"] if jvm_max_heap is not None else []),
               *([] if unfiltered else include_args)]
    started = time.monotonic()
    exit_code = -1
    infrastructure_error = None
    try:
        exit_code = command_log(command, ROOT / "server", directory / "maven.log", env)
    except (OSError, subprocess.SubprocessError) as exc:
        infrastructure_error = f"Maven could not run: {exc}"
    finally:
        for phase in ("surefire", "failsafe"):
            source = target / f"{phase}-reports"
            if source.is_dir():
                shutil.copytree(source, directory / source.name)
        records, xml_errors = xml_cases(directory)
        audit = audit_cases(plan, shard_id, records, exit_code, sys.platform)
        audit["errors"].extend(xml_errors)
        if infrastructure_error:
            audit["errors"].append(infrastructure_error)
        if plan["source"] != source_identity():
            audit["errors"].append("Sources changed while tests were running")
        audit["complete"] = not audit["errors"]
        report = {"schema_version": VERSION, "plan_hash": plan["plan_hash"], "source": plan["source"],
                  "shard": shard_id, "coverage": plan["coverage"], "maven_exit_code": exit_code,
                  "unfiltered": unfiltered,
                  "heap_limits": {"test_jvm_max_heap": jvm_max_heap, "maven_max_heap": maven_max_heap},
                  "platform": sys.platform,
                  "elapsed_seconds": round(time.monotonic() - started, 3),
                  "database_tests_enabled": True, "target": str(target), **audit}
        write_json(directory / "report.json", report)
    print(f"Shard {shard_id}: {'PASS' if report['complete'] else 'FAIL'}; {report['testcase_count']} cases; {directory / 'report.json'}", flush=True)
    return report["complete"]


def run_command(args):
    plan = checked_plan(args.plan)
    if args.workers < 1:
        raise ValueError("--workers must be positive")
    shard_ids = [part["id"] for part in plan["shards"]] if args.all else [args.shard]
    if any(index is None or index < 0 or index >= len(plan["shards"]) for index in shard_ids):
        raise ValueError("Unknown shard ID")
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    maven = maven_executable(args.maven)
    results = []
    with ThreadPoolExecutor(max_workers=min(args.workers, len(shard_ids))) as pool:
        futures = [pool.submit(run_one, plan, index, output, maven,
                               jvm_max_heap=args.jvm_max_heap, maven_max_heap=args.maven_max_heap)
                   for index in shard_ids]
        for future in as_completed(futures):
            results.append(future.result())
    return 0 if all(results) else 1


def verify_reports(plan, reports):
    errors, seen, audits = [], Counter(), []
    for path in sorted(Path(reports).rglob("report.json")):
        report = read_json(path)
        shard_id = report.get("shard")
        seen[shard_id] += 1
        if shard_id not in range(len(plan["shards"])):
            errors.append(f"Unknown shard in {path}")
            continue
        if report.get("plan_hash") != plan["plan_hash"] or report.get("source") != plan["source"]:
            errors.append(f"Stale/different plan or source: {path}")
        if report.get("coverage") != "full" or report.get("database_tests_enabled") is not True:
            errors.append(f"Incomplete/DB-disabled run: {path}")
        records, xml_errors = xml_cases(path.parent)
        audit = audit_cases(plan, shard_id, records, report.get("maven_exit_code", -1), report.get("platform"))
        if not report.get("complete") or report.get("errors"):
            errors.append(f"Shard {shard_id} did not complete successfully")
        # Recompute from actual XML instead of trusting the report's success flag.
        if report.get("method_counts") != audit["method_counts"] or report.get("skipped") != audit["skipped"]:
            errors.append(f"Execution evidence changed after reporting: shard {shard_id}")
        errors.extend(xml_errors + audit["errors"])
        audits.append({"shard": shard_id, "elapsed_seconds": report.get("elapsed_seconds"), **audit})
    for shard in plan["shards"]:
        if seen[shard["id"]] != 1:
            errors.append(f"Expected exactly one report for shard {shard['id']}; found {seen[shard['id']]}")
    if plan["coverage"] != "full":
        errors.append("A focused run is never full-suite evidence")
    return {"schema_version": VERSION, "plan_hash": plan["plan_hash"], "source": plan["source"],
            "complete": not errors, "errors": errors, "shards": audits}


def verify_command(args):
    plan = checked_plan(args.plan)
    result = verify_reports(plan, args.reports)
    write_json(Path(args.reports) / "verification.json", result)
    history = {"schema_version": VERSION, "source_sha": plan["source"]["sha"],
               "purpose": "Scheduling hints only; not passing-test or coverage evidence", "classes": {}}
    for shard in result["shards"]:
        for name, seconds in shard["class_seconds"].items():
            history["classes"][name] = {"seconds": seconds}
    write_json(Path(args.reports) / "timings.json", history)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a", encoding="utf-8") as stream:
            stream.write(f"## Backend full-suite verification: {'PASS' if result['complete'] else 'FAIL'}\n\n")
            stream.write(f"Discovered {len(plan['classes'])} classes / {sum(len(row['methods']) for row in plan['classes'])} methods.\n\n")
            stream.write("| Shard | Elapsed seconds | Actual cases | Skips | Complete |\n| --- | ---: | ---: | ---: | --- |\n")
            for shard in result["shards"]:
                stream.write(f"| {shard['shard']} | {shard['elapsed_seconds']} | {shard['testcase_count']} | {len(shard['skipped'])} | {shard['complete']} |\n")
            stream.write("\n")
            for error in result["errors"][:25]:
                stream.write(f"- {error[:300]}\n")
    print(f"Full-suite verification: {'PASS' if result['complete'] else 'FAIL'}")
    for error in result["errors"][:35]:
        print(f"  {error}")
    return 0 if result["complete"] else 1


def baseline_command(args):
    original = checked_plan(args.plan)
    baseline = make_plan(original["classes"], 1, {}, original["source"])
    baseline["parent_plan_hash"] = original["plan_hash"]
    baseline["plan_hash"] = digest(baseline)
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / "baseline-plan.json", baseline)
    print("Running the original, unfiltered Maven clean verify as the comparison baseline.", flush=True)
    return 0 if run_one(baseline, 0, output, maven_executable(args.maven), unfiltered=True,
                       jvm_max_heap=args.jvm_max_heap, maven_max_heap=args.maven_max_heap) else 1


def compare_evidence(plan, reports, reference):
    result = verify_reports(plan, reports)
    errors = list(result["errors"])
    baseline_plan = checked_plan(Path(reference) / "baseline-plan.json", check_source=False)
    baseline_result = verify_reports(baseline_plan, reference)
    errors.extend("Baseline: " + error for error in baseline_result["errors"])
    baseline_report = read_json(Path(reference) / "shard-0" / "report.json")
    if baseline_plan["source"] != plan["source"] or baseline_report.get("unfiltered") is not True:
        errors.append("Baseline must be an unfiltered verify on the same source")
    def signatures(directory):
        rows = []
        for report in sorted(Path(directory).rglob("report.json")):
            cases, xml_errors = xml_cases(report.parent)
            errors.extend(xml_errors)
            rows.extend((case["phase"], case["class"], case["name"], case["status"], case["skip_reason"]) for case in cases)
        return Counter(rows)
    actual, expected = signatures(reports), signatures(reference)
    missing, extra = expected - actual, actual - expected
    if missing:
        errors.append(f"Missing/changed baseline invocations: {sum(missing.values())}")
    if extra:
        errors.append(f"Extra/changed invocations versus baseline: {sum(extra.values())}")
    return {"schema_version": VERSION, "source": plan["source"], "plan_hash": plan["plan_hash"],
            "complete": not errors, "errors": errors,
            "baseline_invocations": sum(expected.values()), "sharded_invocations": sum(actual.values()),
            "missing": [{"case": list(case), "count": count} for case, count in sorted(missing.items())],
            "extra": [{"case": list(case), "count": count} for case, count in sorted(extra.items())]}


def compare_command(args):
    result = compare_evidence(checked_plan(args.plan), args.reports, args.reference)
    write_json(Path(args.reports) / "comparison.json", result)
    print(f"Unfiltered baseline comparison: {'PASS' if result['complete'] else 'FAIL'}; "
          f"{result['baseline_invocations']} baseline / {result['sharded_invocations']} sharded invocations")
    for error in result["errors"][:35]:
        print(f"  {error}")
    return 0 if result["complete"] else 1


def focus_command(args):
    plan = checked_plan(args.plan)
    names = set(filter(None, (args.classes or "").split(",")))
    if args.previous_report:
        for path in Path(args.previous_report).rglob("report.json"):
            names.update(read_json(path).get("failed_classes", []))
    available = {row["name"] for row in plan["classes"]}
    if not names or names - available:
        raise ValueError(f"Select known classes; unknown: {sorted(names - available)}")
    focused = make_plan([row for row in plan["classes"] if row["name"] in names], 1, {}, plan["source"])
    focused["coverage"] = "focused-incomplete"
    focused["parent_plan_hash"] = plan["plan_hash"]
    focused["plan_hash"] = digest(focused)
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / "focus-plan.json", focused)
    print("Focused feedback only: this result cannot satisfy the full-suite gate.", flush=True)
    return 0 if run_one(focused, 0, output, maven_executable(args.maven),
                       jvm_max_heap=args.jvm_max_heap, maven_max_heap=args.maven_max_heap) else 1


def main(argv=None):
    # Some Windows consoles use GBK; diagnostic decoding must not hide a real test failure.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    planning = commands.add_parser("plan", help="Compile and discover all tests; balance by historical duration")
    planning.add_argument("--output", required=True)
    planning.add_argument("--shards", type=int, default=4)
    planning.add_argument("--history")
    planning.add_argument("--maven")
    planning.set_defaults(handler=plan_command)
    run = commands.add_parser("run", help="Run complete Maven verify for assigned classes")
    run.add_argument("--plan", required=True)
    selector = run.add_mutually_exclusive_group(required=True)
    selector.add_argument("--shard", type=int)
    selector.add_argument("--all", action="store_true")
    run.add_argument("--workers", type=int, default=1)
    run.add_argument("--output", required=True)
    run.add_argument("--maven")
    heap_options(run)
    run.set_defaults(handler=run_command)
    verify = commands.add_parser("verify", help="Fail closed unless every shard and every discovered method is accounted for")
    verify.add_argument("--plan", required=True)
    verify.add_argument("--reports", required=True)
    verify.set_defaults(handler=verify_command)
    baseline = commands.add_parser("baseline", help="Original unfiltered Maven verify for rollout equivalence checking")
    baseline.add_argument("--plan", required=True)
    baseline.add_argument("--output", required=True)
    baseline.add_argument("--maven")
    heap_options(baseline)
    baseline.set_defaults(handler=baseline_command)
    compare = commands.add_parser("compare", help="Compare actual test instances/skip reasons with unfiltered baseline")
    compare.add_argument("--plan", required=True)
    compare.add_argument("--reports", required=True)
    compare.add_argument("--reference", required=True)
    compare.set_defaults(handler=compare_command)
    focus = commands.add_parser("focus", help="Run known failing/related classes for early feedback (never a full gate)")
    focus.add_argument("--plan", required=True)
    focus.add_argument("--classes", help="Comma-separated fully qualified names")
    focus.add_argument("--previous-report", help="Directory containing previous report.json files")
    focus.add_argument("--output", required=True)
    focus.add_argument("--maven")
    heap_options(focus)
    focus.set_defaults(handler=focus_command)
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
