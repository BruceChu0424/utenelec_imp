#!/usr/bin/env python3
"""Sequential base/head comparison on a dedicated Linux host with native Docker.

Builds are outside the measured windows. Both sides use the exact head test
classes, Maven model and dependency jars; each retains its own production
classes/resources. No existing database address or credentials are accepted.
Importing this module has no side effects. A fresh output directory is required.
"""
from __future__ import annotations

import argparse
import ast
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
import zipfile

POSTGRES_IMAGE = "postgres:16-alpine"
RYUK_IMAGE = "testcontainers/ryuk:0.12.0"
REPETITIONS = 3
METHODS = {
    ("QualityAndDailyReportPerformancePostgresTest", "fourReceiptsQualityApprovalIncludesAutomaticPhysicalStockInAndReplays"),
    ("DailyReportComplexPerformancePostgresTest", "tenDistinctSourcesMeasureCreateApproveAndReplayWithActualMaterialSettlement"),
    ("DailyReportComplexPerformancePostgresTest", "elevenDirectReceiversIncludeRealStockCostAndExactHandoverSources"),
    ("ProductionFqcPreStockBatchEndToEndTest", "fourPreStockedReportsKeepPhysicalFactsAndShareFinalAnalysisRefresh"),
}
PHASES = {
    "iqc-four-receipts", "iqc-four-receipts-replay",
    "report-ten-segments-create", "report-ten-segments-approve",
    "report-ten-segments-create-replay", "report-ten-segments-approve-replay",
    "report-eleven-receivers-approve", "report-eleven-receivers-approve-replay",
}
DURABILITY = ("fsync", "synchronous_commit", "full_page_writes")
CLASS_FILES = {
    "stockBytecodeSha256": "com/uten/imp/features/stock/StockDocService.class",
    "qualityBytecodeSha256": "com/uten/imp/features/production/quality/ProductionFqcInspectionService.class",
}


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def identity(files: dict[str, str]) -> dict:
    if not files:
        raise ValueError("Empty source or compiled tree")
    encoded = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "files": files}


def tree(directory: Path) -> dict:
    paths = sorted(directory.rglob("*"))
    if any(path.is_symlink() for path in paths):
        raise ValueError("Snapshot must not contain symlinks: " + str(directory))
    return identity({path.relative_to(directory).as_posix(): digest(path) for path in paths if path.is_file()})


def source_snapshot(root: Path) -> dict:
    paths = [root / "server/pom.xml"]
    for folder in ("main", "test"):
        paths.extend(path for path in (root / "server/src" / folder).rglob("*") if path.is_file())
    if any(path.is_symlink() for path in paths):
        raise ValueError("Source snapshot must not contain symlinks")
    return identity({path.relative_to(root).as_posix(): digest(path) for path in sorted(paths)})


def save(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def capture(command: list[str], *, cwd: Path | None = None, env: dict | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=True, timeout=30)
    return result.stdout.strip()


def execute(command: list[str], cwd: Path, env: dict, log: Path, *, check: bool = True) -> int:
    print(f"Executing {log.name}; complete output retained in {log}", flush=True)
    with log.open("wb") as output:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}")
    return result.returncode


def selected_suite(root: Path) -> str:
    # Share the established selector without executing/importing a CLI module.
    module = ast.parse((root / "server/ops/run_quality_report_performance.py").read_text(encoding="utf-8"))
    definitions = [node.value for node in module.body if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == "TESTS" for target in node.targets)]
    if len(definitions) != 1 or not isinstance(value := ast.literal_eval(definitions[0]), str):
        raise ValueError("Existing benchmark must define exactly one literal TESTS selector")
    expected = ("QualityAndDailyReportPerformancePostgresTest#fourReceiptsQualityApprovalIncludesAutomaticPhysicalStockInAndReplays,"
                "DailyReportComplexPerformancePostgresTest,"
                "ProductionFqcPreStockBatchEndToEndTest#fourPreStockedReportsKeepPhysicalFactsAndShareFinalAnalysisRefresh")
    if value != expected:
        raise ValueError("Benchmark selector changed; review the native evidence inventory together")
    return value


def clean_environment(cpus: int) -> dict:
    blocked = ("UTEN_", "SPRING_", "TESTCONTAINERS_", "DOCKER_")
    env = {key: value for key, value in os.environ.items() if not key.startswith(blocked)
           and key not in {"JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS", "CLASSPATH", "MAVEN_ARGS", "MAVEN_OPTS"}}
    env.update(UTEN_RUN_DB_TESTS="true", UTEN_RUN_PRODUCTION_STRESS="true", UTEN_AI_OUTBOUND_ENABLED="false",
               DOCKER_HOST="unix:///var/run/docker.sock", TESTCONTAINERS_RYUK_DISABLED="false",
               TESTCONTAINERS_REUSE_ENABLE="false", TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX="",
               TESTCONTAINERS_CHECKS_DISABLE="true",
               MAVEN_OPTS=f"-Xmx2g -XX:ActiveProcessorCount={cpus}")
    return env


def java_process_count() -> int:
    count = 0
    for path in Path("/proc").glob("[0-9]*/comm"):
        try:
            count += path.read_text().strip() == "java"
        except (FileNotFoundError, PermissionError):
            pass
    return count


def load_snapshot(env: dict) -> dict:
    memory = Path("/proc/meminfo").read_text()
    return {"atUtc": now(), "loadAverage": os.getloadavg(), "logicalCpus": os.cpu_count(),
            "allowedCpus": sorted(os.sched_getaffinity(0)), "javaProcesses": java_process_count(),
            "cpuCounters": Path("/proc/stat").read_text().splitlines()[0],
            "memoryKb": {key: int(value) for key, value in re.findall(
                r"^(MemTotal|MemAvailable|SwapTotal|SwapFree):\s+(\d+)", memory, re.MULTILINE)},
            "runningContainers": len(capture(["docker", "ps", "-q"], env=env).splitlines())}


def require_idle(snapshot: dict) -> None:
    if snapshot["javaProcesses"] or snapshot["runningContainers"]:
        raise ValueError("Dedicated runner contains another JVM or container; no waiting or process termination is attempted")


def image_snapshot(env: dict) -> dict:
    result = {}
    for name in (POSTGRES_IMAGE, RYUK_IMAGE):
        image = json.loads(capture(["docker", "image", "inspect", name], env=env))[0]
        if not image.get("RepoDigests"):
            raise ValueError("Fixture image lacks a registry digest")
        result[name] = {"id": image["Id"], "repoDigests": sorted(image["RepoDigests"])}
    return result


def observe_containers(process: subprocess.Popen, env: dict, observed: dict, errors: list) -> None:
    """Inspect each started container once; no polling or resource-limit changes."""
    for line in process.stdout:
        try:
            event = json.loads(line)
            if event.get("Type") != "container":
                continue
            container_id = event.get("Actor", {}).get("ID") or event.get("id")
            container = json.loads(capture(["docker", "inspect", container_id], env=env))[0]
            observed[container_id] = {"imageId": container["Image"], "imageName": container["Config"]["Image"],
                                      "nanoCpus": container["HostConfig"].get("NanoCpus", 0),
                                      "memoryBytes": container["HostConfig"].get("Memory", 0)}
        except Exception as failure:
            errors.append(type(failure).__name__)


def validate_containers(observed: dict, errors: list, images: dict) -> dict:
    postgres = images[POSTGRES_IMAGE]["id"]
    allowed = {postgres, images[RYUK_IMAGE]["id"]}
    if errors or any(row["imageId"] not in allowed for row in observed.values()):
        raise ValueError("Actual container identity observation failed or an unexpected image ran")
    databases = [row for row in observed.values() if row["imageId"] == postgres]
    if len(databases) != 3 or any(row["nanoCpus"] or row["memoryBytes"] for row in databases):
        raise ValueError("Expected exactly three PostgreSQL fixture containers with identical native-host limits")
    return {"postgresContainers": len(databases), "postgresImageId": postgres, "postgresLimits": "host defaults"}


def dependency_snapshot(classpath: str) -> dict:
    jars = [Path(item) for item in classpath.split(os.pathsep) if item]
    if not jars or any(path.suffix != ".jar" or not path.is_file() for path in jars):
        raise ValueError("Unexpected extra classpath directory or missing dependency")
    result = {}
    for path in jars:
        with zipfile.ZipFile(path) as archive:
            if any(name.startswith("com/uten/imp/") and name.endswith(".class") for name in archive.namelist()):
                raise ValueError("A dependency jar contains application classes: " + str(path))
        result[str(path)] = digest(path)
    return result


def validate_evidence(folder: Path, source: str, classes: dict, side: str, dependencies: dict) -> dict:
    xml = [ET.parse(path).getroot() for path in sorted((folder / "surefire-reports").glob("TEST-*.xml"))]
    cases = [(case.get("classname", ""), case.get("name"))
             for suite in xml for case in suite.findall("testcase")]
    methods = {("com.uten.imp.businesschain." + name, method) for name, method in METHODS}
    if Counter(cases) != Counter(methods) or sum(int(row.get("tests", "0")) for row in xml) != 4 or any(
            int(row.get(key, "0")) for row in xml for key in ("failures", "errors", "skipped")):
        raise ValueError("Expected exactly the four passing fixture methods, with no skips or duplicate cases")
    if any(node.tag in {"skipped", "failure", "error", "flakyFailure", "flakyError", "rerunFailure", "rerunError"}
           for suite in xml for node in suite.iter()):
        raise ValueError("Skipped, failed or rerun test evidence cannot be accepted")
    for suite in xml:
        properties = {row.get("name"): row.get("value") for row in suite.findall("properties/property")}
        classpath = properties.get("java.class.path", "")
        if classpath != properties.get("surefire.test.class.path"):
            raise ValueError("JVM and Surefire runtime classpaths disagree")
        entries = classpath.split(os.pathsep)
        if entries[:2] != [str(folder / "test-classes"), str(folder / "classes")]:
            raise ValueError("Executed classpath does not start with the frozen head tests and selected production classes")
        actual = {str(Path(item)): digest(Path(item)) for item in entries[2:] if item}
        if actual != dependencies:
            raise ValueError("Executed dependency jars differ from the prepared runtime classpath")
        if properties.get("uten.perf.source-identity") != source:
            raise ValueError("Surefire source identity differs from the selected snapshot")
    samples = [json.loads(path.read_text(encoding="utf-8")) for path in sorted((folder / "perf").glob("*.json"))]
    expected = {(phase, repetition) for phase in PHASES for repetition in range(REPETITIONS)}
    if Counter((row.get("phase"), row.get("repetition")) for row in samples) != Counter(expected):
        raise ValueError("Expected each of eight phases exactly three times (24 JSON samples)")
    profiles = [json.loads(line.split("FQC-BATCH-PROFILE ", 1)[1])
                for line in (folder / "maven.log").read_text(encoding="utf-8", errors="replace").splitlines()
                if "FQC-BATCH-PROFILE " in line]
    save(folder / "fqc-profiles.json", profiles)
    actions = {f"four-handoffs-{action}-{repetition}" for action in ("pass", "replay") for repetition in range(REPETITIONS)}
    if Counter(row.get("action") for row in profiles) != Counter(actions):
        raise ValueError("Expected all six unique FQC pass/replay profiles")
    for row in samples + profiles:
        if row.get("sourceIdentity") != source or row.get("verifyNestedFootprint") is not False:
            raise ValueError("Measured source identity or nested-diagnostic configuration drifted")
        if any(row.get("databaseSettings", {}).get(setting) != "on" for setting in DURABILITY):
            raise ValueError("Measured PostgreSQL durability is not explicitly on")
    if any(row.get("diagnostic") is not False for row in samples):
        raise ValueError("SQL tracing was enabled during measurement")
    for rows, field in ((samples, "elapsedMillis"), (profiles, "wallMillis")):
        if any(not isinstance(row.get(field), (int, float)) or isinstance(row[field], bool)
               or not math.isfinite(row[field]) or row[field] < 0 for row in rows):
            raise ValueError("Measured elapsed time is missing or invalid")
    for row in profiles:
        if (row.get("candidate") != ("before" if side == "baseline" else "after")
                or row.get("reportCount") != 4 or row.get("size") != 4 or row.get("mode") != "prestock"):
            raise ValueError("FQC side or four-handoff fixture identity drifted")
        if any(row.get(field) != classes["files"][filename] for field, filename in CLASS_FILES.items()):
            raise ValueError("Executed FQC/stock bytecode differs from the frozen production tree")
    return {"methods": 4, "samples": len(samples), "fqcProfiles": len(profiles), "dependencyJars": dependencies}


def write_summary(output: Path, manifest: dict) -> None:
    timings = {}
    for side in ("baseline", "candidate"):
        rows = [json.loads(path.read_text()) for path in (output / side / "perf").glob("*.json")]
        grouped = {phase: [row["elapsedMillis"] for row in sorted(rows, key=lambda row: row["repetition"])
                           if row["phase"] == phase] for phase in sorted(PHASES)}
        profiles = json.loads((output / side / "fqc-profiles.json").read_text())
        for action in ("pass", "replay"):
            grouped["fqc-four-handoffs-" + action] = [row["wallMillis"] for row in sorted(profiles, key=lambda row: row["action"])
                                                       if row["action"].startswith("four-handoffs-" + action + "-")]
        timings[side] = grouped
    lines = ["## Quality/report paired measurements", "",
             f"Base `{manifest['commits']['baseline']}` → head `{manifest['commits']['candidate']}`.", "",
             "One dedicated Ubuntu runner, sequential sides, Java 21, identical head tests/dependencies and PostgreSQL image.",
             "Each side: 4 passing methods, 24 JSON samples, 6 FQC profiles, no skips; durability on and nested diagnostics off.",
             "Three fresh scenarios per phase; medians below are synthetic service/commit timings, not production SLO or p95 evidence.", "",
             "| Phase | Base samples (ms) | Head samples (ms) | Base median | Head median | Change |",
             "|---|---|---|---:|---:|---:|"]
    for phase in sorted(timings["baseline"]):
        before, after = timings["baseline"][phase], timings["candidate"][phase]
        left, right = statistics.median(before), statistics.median(after)
        change = f"{(right / left - 1) * 100:+.1f}%" if left else "n/a"
        lines.append(f"| {phase} | {', '.join(f'{value:.1f}' for value in before)} | "
                     f"{', '.join(f'{value:.1f}' for value in after)} | {left:.1f} | {right:.1f} | {change} |")
    lines.extend(["", "Image identity: `" + manifest["fixtureImages"][POSTGRES_IMAGE]["id"] + "`.",
                  "Full source/class/jar identities, actual-container receipts, host aggregates, logs and raw XML are in the artifact."])
    report = "\n".join(lines) + "\n"
    (output / "summary.md").write_text(report, encoding="utf-8")
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(path).open("a", encoding="utf-8") as stream:
            stream.write(report)


def run(args: argparse.Namespace) -> None:
    if sys.platform != "linux" or not args.isolated_runner:
        raise ValueError("Use a dedicated Linux runner and explicitly pass --isolated-runner")
    baseline, candidate, output = args.baseline.resolve(), args.candidate.resolve(), args.output.resolve()
    if baseline == candidate or baseline.is_relative_to(candidate) or candidate.is_relative_to(baseline):
        raise ValueError("Baseline and candidate must be separate checkouts")
    if output.exists():
        raise ValueError("Output already exists; preserve prior evidence and choose a fresh directory")
    for checkout in (baseline, candidate):
        if output.is_relative_to(checkout / "server/src"):
            raise ValueError("Output must not overlap source files")
        if capture(["git", "status", "--porcelain", "--", "server/src", "server/pom.xml"], cwd=checkout):
            raise ValueError("Build source has uncommitted changes")
    output.mkdir(parents=True)
    home = output / "test-home"; home.mkdir()
    cpus = min(4, len(os.sched_getaffinity(0)))
    env = clean_environment(cpus)
    sources = {side: source_snapshot(checkout) for side, checkout in (("baseline", baseline), ("candidate", candidate))}
    commits = {side: capture(["git", "rev-parse", "HEAD"], cwd=checkout)
               for side, checkout in (("baseline", baseline), ("candidate", candidate))}
    suite = selected_suite(candidate)
    manifest = {"state": "PREPARING", "startedAtUtc": now(), "commits": commits, "sources": sources,
                "suite": suite, "repetitions": REPETITIONS, "runnerSha256": digest(Path(__file__)),
                "resources": {"testHeap": "4g", "activeProcessors": cpus, "postgres": "native Docker defaults on the same dedicated host"},
                "testcontainersStartupChecks": "disabled to avoid unrelated tiny-image probe containers; actual PostgreSQL startup/readiness and durability remain mandatory",
                "scope": "base/head production bytes and resources under one head Maven dependency model and head tests; synthetic services plus real commits; excludes preparation, HTTP and async notices; no production SLO claim"}
    save(output / "manifest.json", manifest)
    try:
        save(output / "host-before-build.json", initial := load_snapshot(env)); require_idle(initial)
        java = capture(["java", "-version"], env=env)
        if not re.search(r'version "21[.\"]', java):
            raise ValueError("Java 21 is required")
        manifest["java"] = java
        manifest["maven"] = capture(["mvn", "--version"], env=env)
        settings = output / "settings.xml"
        settings.write_text('<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"/>\n', encoding="utf-8")
        maven = ["mvn", "-B", "-ntp", "-s", str(settings)]
        for side, checkout, goal in (("baseline", baseline, "compile"), ("candidate", candidate, "test-compile")):
            command = [*maven, "-DskipTests", "-Duten.build.directory=" + str(output / ("build-" + side)), goal]
            execute(command, checkout / "server", env, output / (side + "-compile.log"))
        effective = output / "effective-pom.xml"
        execute([*maven, "-DskipTests", "dependency:go-offline", "help:effective-pom", "-Doutput=" + str(effective)],
                candidate / "server", env, output / "dependency-prepare.log")
        ns = {"m": "http://maven.apache.org/POM/4.0.0"}
        plugin = ET.parse(effective).find("m:build/m:plugins/m:plugin[m:artifactId='maven-surefire-plugin']/m:version", ns)
        if plugin is None or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", plugin.text or ""):
            raise ValueError("Cannot resolve the pinned Surefire provider version")
        execute([*maven, "dependency:get", "-Dartifact=org.apache.maven.surefire:surefire-junit-platform:" + plugin.text],
                candidate / "server", env, output / "provider-prepare.log")
        dependency_file = output / "dependency-classpath.txt"
        execute([*maven, "dependency:build-classpath", "-DincludeScope=test", "-Dmdep.outputFile=" + str(dependency_file)],
                candidate / "server", env, output / "classpath-prepare.log")
        manifest["dependencyJars"] = dependency_snapshot(dependency_file.read_text(encoding="utf-8").strip())
        manifest["settingsSha256"] = digest(settings)
        for image in (POSTGRES_IMAGE, RYUK_IMAGE):
            execute(["docker", "pull", image], candidate, env, output / (image.split(":")[0].replace("/", "-") + "-pull.log"))
        manifest["fixtureImages"] = image_snapshot(env)
        project = output / "project/server"; project.mkdir(parents=True)
        shutil.copyfile(candidate / "server/pom.xml", project / "pom.xml")
        manifest["executionPomSha256"] = digest(project / "pom.xml")
        manifest["sharedTestClasses"] = tree(output / "build-candidate/test-classes")
        for side in ("baseline", "candidate"):
            folder = output / side; folder.mkdir()
            shutil.copytree(output / ("build-" + side) / "classes", folder / "classes")
            shutil.copytree(output / "build-candidate/test-classes", folder / "test-classes")
            manifest[side + "Classes"] = tree(folder / "classes")
            overlaps = set(manifest[side + "Classes"]["files"]) & set(manifest["sharedTestClasses"]["files"])
            if any(name.endswith(".class") for name in overlaps):
                raise ValueError("Shared test classes shadow production classes")
        policy = output / "candidate/test-classes/com/uten/imp/common/files/malware/MalwareScannerPolicyTest$ScannerContext.class"
        if policy.exists() and b"org/springframework/boot/test/context/TestConfiguration" not in policy.read_bytes():
            raise ValueError("Head tests contain the obsolete globally scanned scanner configuration")
        manifest["state"] = "PREPARED"; save(output / "manifest.json", manifest)
        previous_dependencies = None
        for side in ("baseline", "candidate"):
            folder = output / side
            source = commits[side] + ":source-sha256:" + sources[side]["sha256"]
            receipt = {"side": side, "state": "RUNNING", "startedAtUtc": now(), "sourceIdentity": source}
            save(folder / "receipt.json", receipt)
            verify_frozen(output, manifest, baseline, candidate, env)
            save(folder / "host-before.json", before := load_snapshot(env)); require_idle(before)
            command = [*maven, "-o", "-Duten.build.directory=" + str(folder), "-Dtest=" + suite,
                       "-DforkCount=1", "-DreuseForks=true", "-Dsurefire.runOrder=alphabetical",
                       "-Dsurefire.rerunFailingTestsCount=0", "-DskipTests=false", "-Dmaven.test.skip=false",
                       "-Djunit.jupiter.execution.parallel.enabled=false",
                       "-Duten.test.jvm.heap.args=-Xms512m -Xmx4g -XX:ActiveProcessorCount=" + str(cpus),
                       "-Duten.test.jvm.args=-Duser.home=" + str(home), "-Duten.perf.iqc-lines=1",
                       "-Duten.perf.repetitions=3", "-Duten.fqc.handoffs.repetitions=3",
                       "-Duten.fqc.batch.verifyNestedFootprint=false", "-Duten.concurrency.verify-nested-footprint=false",
                       "-Duten.fqc.batch.run=" + ("before" if side == "baseline" else "after"),
                       "-Duten.perf.source-identity=" + source, "-Duten.perf.report-directory=" + str(folder / "perf"), "surefire:test"]
            measured_env = {**env, "MAVEN_OPTS": f"-Xmx768m -XX:ActiveProcessorCount={cpus}"}
            observed, observation_errors = {}, []
            watcher = subprocess.Popen(["docker", "events", "--since", now(), "--filter", "event=start", "--format", "{{json .}}"],
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            observer = threading.Thread(target=observe_containers, args=(watcher, env, observed, observation_errors), daemon=True)
            observer.start()
            try:
                code = execute(command, project, measured_env, folder / "maven.log", check=False)
            finally:
                watcher.terminate(); watcher.wait(timeout=10); observer.join(timeout=35)
                if observer.is_alive():
                    observation_errors.append("ObserverDidNotFinish")
                save(folder / "actual-containers.json", {"containers": observed, "errors": observation_errors})
            save(folder / "host-after.json", after := load_snapshot(env))
            receipt.update(exitCode=code, finishedAtUtc=now(), state="FAILED" if code else "PROCESS_PASSED")
            save(folder / "receipt.json", receipt)
            verify_frozen(output, manifest, baseline, candidate, env)
            # Ryuk may finish milliseconds after the test fork exits. Wait only
            # for that bounded teardown, never for an occupied performance host.
            deadline = time.monotonic() + 15
            while after["runningContainers"] and not after["javaProcesses"] and time.monotonic() < deadline:
                time.sleep(1)
                after = load_snapshot(env)
            save(folder / "host-after-cleanup.json", after); require_idle(after)
            if code:
                raise RuntimeError(f"{side} tests failed; preserve the raw log/XML")
            receipt["containers"] = validate_containers(observed, observation_errors, manifest["fixtureImages"])
            evidence = validate_evidence(folder, source, manifest[side + "Classes"], side, manifest["dependencyJars"])
            if previous_dependencies is not None and evidence["dependencyJars"] != previous_dependencies:
                raise ValueError("Paired runtime dependency jars differ")
            previous_dependencies = evidence["dependencyJars"]
            receipt.update(state="PASSED", evidence=evidence); save(folder / "receipt.json", receipt)
        write_summary(output, manifest)
        manifest.update(state="PASSED", finishedAtUtc=now())
    except Exception as failure:
        manifest.update(state="FAILED", finishedAtUtc=now(), error=str(failure))
        raise
    finally:
        save(output / "manifest.json", manifest)
    print("Paired evidence verified:", output)


def verify_frozen(output: Path, manifest: dict, baseline: Path, candidate: Path, env: dict) -> None:
    for side, checkout in (("baseline", baseline), ("candidate", candidate)):
        if source_snapshot(checkout) != manifest["sources"][side]:
            raise ValueError("Source bytes changed: " + side)
        if tree(output / side / "classes") != manifest[side + "Classes"]:
            raise ValueError("Production class bytes changed: " + side)
        if tree(output / side / "test-classes") != manifest["sharedTestClasses"]:
            raise ValueError("Shared head test bytes changed: " + side)
    if digest(output / "project/server/pom.xml") != manifest["executionPomSha256"]:
        raise ValueError("Execution Maven model changed")
    if digest(output / "settings.xml") != manifest["settingsSha256"] or digest(Path(__file__)) != manifest["runnerSha256"]:
        raise ValueError("Runner or Maven settings changed")
    if any(digest(Path(path)) != expected for path, expected in manifest["dependencyJars"].items()):
        raise ValueError("Runtime dependency bytes changed")
    if image_snapshot(env) != manifest["fixtureImages"]:
        raise ValueError("Pinned fixture image identities changed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--isolated-runner", action="store_true")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
