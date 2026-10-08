#!/usr/bin/env python3
"""Offline, isolated Linux before/after runner for the quality/report fixtures.

prepare copies frozen class files and existing Maven caches into new run-owned
volumes. run is deliberately separate: use it only after all correctness jobs
finish. No production DB address or credentials are accepted by this runner.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import runpy
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IMAGE = "uten-local-backend-linux-env:20260930-shard-runner"
CACHE = "uten-linux-full-maven-cache-20260930-shard-runner"
DIND = "sha256:6acc6aaf783ac1c1100822e542534c3dab3f1d38782760b0bdcb688280574d9e"
FIXTURE_IMAGES = ("postgres:16-alpine", "testcontainers/ryuk:0.12.0", "python:3.12-slim")
TESTS = (
    "QualityAndDailyReportPerformancePostgresTest#fourReceiptsQualityApprovalIncludesAutomaticPhysicalStockInAndReplays,"
    "DailyReportComplexPerformancePostgresTest,"
    "ProductionFqcPreStockBatchEndToEndTest#fourPreStockedReportsKeepPhysicalFactsAndShareFinalAnalysisRefresh"
)


def docker(*arguments: str, capture: bool = True) -> str:
    result = subprocess.run(["docker", *arguments], text=True, capture_output=capture)
    if result.returncode:
        if capture:
            sys.stderr.write(result.stderr)
        raise RuntimeError(f"Docker operation failed ({result.returncode})")
    return result.stdout.strip() if capture else ""


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def tree_identity(directory: Path) -> dict:
    files = {file.relative_to(directory).as_posix(): digest(file)
             for file in sorted(directory.rglob("*")) if file.is_file()}
    if not files:
        raise ValueError(f"Empty compiled directory: {directory}")
    canonical = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return {"sha256": hashlib.sha256(canonical).hexdigest(), "files": files}


def scoped(path: Path) -> Path:
    path = path.resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError("All compiled artifacts must belong to this isolated checkout")
    return path


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def owned(resource: dict, run_id: str) -> None:
    labels = resource.get("Labels", resource.get("Config", {}).get("Labels", {})) or {}
    if labels.get("uten.run") != run_id or labels.get("uten.task") != "quality-report-performance":
        raise ValueError("Resource does not belong to this benchmark run")


def validate_topology(manifest: dict) -> None:
    network = json.loads(docker("network", "inspect", manifest["network"]))[0]
    daemon = json.loads(docker("inspect", manifest["daemonContainer"]))[0]
    owned(network, manifest["runId"])
    owned(daemon, manifest["runId"])
    if not network["Internal"] or daemon["Image"] != manifest["daemonImageIdentity"]:
        raise ValueError("Isolated daemon network/image drifted")
    if daemon["HostConfig"].get("PortBindings") or not daemon["State"]["Running"]:
        raise ValueError("Daemon must be running with no host-published ports")
    mounts = daemon["Mounts"]
    if len(mounts) != 1 or mounts[0].get("Name") != manifest["daemonVolume"] or mounts[0]["Destination"] != "/var/lib/docker":
        raise ValueError("Daemon must mount only its run-owned data volume")
    if set(daemon["NetworkSettings"]["Networks"]) != {manifest["network"]}:
        raise ValueError("Daemon has an unexpected network")
    for name, identity in manifest["fixtureImages"].items():
        actual = json.loads(docker("exec", manifest["daemonContainer"], "docker", "image", "inspect", name))[0]["Id"]
        if actual != identity:
            raise ValueError("Offline fixture image changed: " + name)


def prepare_topology(manifest: dict) -> None:
    labels = ["--label", "uten.task=quality-report-performance", "--label", "uten.run=" + manifest["runId"]]
    docker("network", "create", "--internal", *labels, manifest["network"])
    docker("run", "-d", "--pull=never", "--privileged", "--name", manifest["daemonContainer"], *labels,
           "--network", manifest["network"], "--network-alias", "daemon", "-e", "DOCKER_TLS_CERTDIR=",
           "--mount", "type=volume,source=" + manifest["daemonVolume"] + ",target=/var/lib/docker",
           manifest["daemonImageIdentity"], "--host=unix:///var/run/docker.sock", "--host=tcp://0.0.0.0:2375", "--tls=false")
    deadline = time.monotonic() + 45
    while True:
        ready = subprocess.run(["docker", "exec", manifest["daemonContainer"], "docker", "info"], capture_output=True)
        if ready.returncode == 0:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError("Dedicated Docker daemon did not become ready")
        time.sleep(1)
    save = subprocess.Popen(["docker", "image", "save", *FIXTURE_IMAGES], stdout=subprocess.PIPE)
    try:
        loaded = subprocess.run(["docker", "exec", "-i", manifest["daemonContainer"], "docker", "load"], stdin=save.stdout)
    finally:
        save.stdout.close()
    if save.wait() or loaded.returncode:
        raise RuntimeError("Offline fixture image transfer failed")
    validate_topology(manifest)
    probe = "quality-network-probe"
    program = "import socket;s=socket.socket();s.bind(('0.0.0.0',32123));s.listen();c,a=s.accept();c.sendall(b'ok');c.close()"
    docker("exec", manifest["daemonContainer"], "docker", "run", "-d", "--pull=never", "--name", probe, *labels,
           "-p", "32123", "python:3.12-slim", "python", "-u", "-c", program)
    try:
        bound = docker("exec", manifest["daemonContainer"], "docker", "port", probe, "32123/tcp")
        port = re.search(r"0\.0\.0\.0:(\d+)", bound).group(1)
        client = "import socket;s=socket.create_connection(('daemon'," + port + "),5);assert s.recv(16)==b'ok';s.close();print('DIRECT_LINUX_TCP_OK')"
        result = docker("run", "--rm", "--pull=never", "--user=0:0", "--network", manifest["network"],
                        "--entrypoint", "/usr/bin/python3", manifest["image"], "-c", client)
        if result != "DIRECT_LINUX_TCP_OK":
            raise ValueError("Direct Linux published-port probe failed")
    finally:
        inspected = json.loads(docker("exec", manifest["daemonContainer"], "docker", "inspect", probe))[0]
        owned(inspected, manifest["runId"])
        docker("exec", manifest["daemonContainer"], "docker", "rm", "-f", probe)
    manifest["networkProbe"] = "DIRECT_LINUX_TCP_OK; runner -> dedicated daemon published port, no host proxy"


def observe_load(path: Path, stop: threading.Event, daemon: str) -> None:
    with path.open("w", encoding="utf-8") as output:
        while True:
            row = {"atUtc": datetime.now(timezone.utc).isoformat()}
            try:
                row["containers"] = [json.loads(line) for line in docker("stats", "--no-stream", "--format", "{{json .}}").splitlines() if line]
                row["host"] = json.loads(docker("info", "--format", '{{json .}}'))
                row["host"] = {key: row["host"][key] for key in ("NCPU", "MemTotal", "ContainersRunning")}
                memory = docker("exec", daemon, "cat", "/proc/meminfo")
                row["linuxMemoryKb"] = {key: int(value) for key, value in re.findall(r"^(MemTotal|MemAvailable|SwapTotal|SwapFree):\s+(\d+)", memory, re.M)}
                row["windowsHost"] = windows_resources()
            except Exception as failure:
                row["observationError"] = str(failure)
            output.write(json.dumps(row) + "\n")
            output.flush()
            if stop.wait(15):
                break


def windows_resources() -> dict:
    if sys.platform != "win32":
        return {"available": False, "reason": "host is not Windows"}
    script = r'''
$ErrorActionPreference='Stop'
$os=Get-CimInstance Win32_OperatingSystem
$cpu=Get-CimInstance Win32_Processor
$processes=@(Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne 0 } | ForEach-Object {
    [pscustomobject]@{pid=$_.ProcessId;name=$_.Name;createdUtc=$_.CreationDate.ToUniversalTime().ToString('o');
        cpu100ns=([long]$_.KernelModeTime+[long]$_.UserModeTime);workingSetBytes=[long]$_.WorkingSetSize;
        readBytes=[long]$_.ReadTransferCount;writeBytes=[long]$_.WriteTransferCount}
})
[pscustomobject]@{available=$true;sampledAtUtc=[DateTimeOffset]::UtcNow.ToString('o');
    totalPhysicalKb=[long]$os.TotalVisibleMemorySize;freePhysicalKb=[long]$os.FreePhysicalMemory;
    cpu=@($cpu | Select-Object NumberOfLogicalProcessors,LoadPercentage);processes=$processes} | ConvertTo-Json -Depth 5 -Compress
'''
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                            capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError("Read-only Windows resource observation failed")
    return json.loads(result.stdout)


def verify_snapshot(arguments: list[str]) -> None:
    previous = sys.argv
    try:
        sys.argv = [str(Path(__file__).with_name("verify_quality_report_snapshot.py")), *arguments]
        runpy.run_path(sys.argv[0], run_name="__main__")
    finally:
        sys.argv = previous


def workspace_source_identity() -> str:
    files = []
    for directory in (ROOT / "server/src/main", ROOT / "server/src/test"):
        files.extend(path for path in directory.rglob("*") if path.is_file())
    files.append(ROOT / "server/pom.xml")
    rows = {path.relative_to(ROOT).as_posix(): digest(path) for path in sorted(files)}
    return "source-sha256:" + hashlib.sha256(json.dumps(rows, sort_keys=True).encode()).hexdigest()


def prepare(args: argparse.Namespace, output: Path) -> None:
    if output.exists():
        raise ValueError("Run output already exists; retain it and choose a fresh run id")
    before = scoped(args.baseline)
    after = scoped(args.candidate)
    main_before = tree_identity(before / "classes")
    main_after = tree_identity(after / "classes")
    tests = tree_identity(after / "test-classes")
    policy = after / "test-classes/com/uten/imp/common/files/malware/MalwareScannerPolicyTest$ScannerContext.class"
    if policy.exists() and b"org/springframework/boot/test/context/TestConfiguration" not in policy.read_bytes():
        raise ValueError("Candidate tests still contain the obsolete globally scanned scanner configuration")
    source_identity = workspace_source_identity()
    docker("image", "inspect", args.image)
    fixture_images = {name: json.loads(docker("image", "inspect", name))[0]["Id"] for name in FIXTURE_IMAGES}
    daemon_image = json.loads(docker("image", "inspect", args.dind_image))[0]["Id"]
    docker("volume", "inspect", args.cache)
    work = "uten-performance-" + args.run_id + "-work"
    cache = "uten-performance-" + args.run_id + "-cache"
    daemon = "uten-performance-" + args.run_id + "-daemon"
    network = "uten-performance-" + args.run_id + "-net"
    for kind, name in (("network", network), ("container", daemon)):
        if subprocess.run(["docker", kind, "inspect", name], capture_output=True).returncode == 0:
            raise ValueError("Refusing to replace an existing resource: " + name)
    for name in (work, cache, daemon):
        if subprocess.run(["docker", "volume", "inspect", name], capture_output=True).returncode == 0:
            raise ValueError("Refusing to replace an existing volume: " + name)
    output.mkdir(parents=True)
    for name in (work, cache, daemon):
        docker("volume", "create", "--label", "uten.task=quality-report-performance", "--label", "uten.run=" + args.run_id, name)
    manifest = {
        "state": "PREPARING", "runId": args.run_id, "preparedAtUtc": datetime.now(timezone.utc).isoformat(),
        "image": args.image, "imageIdentity": json.loads(docker("image", "inspect", args.image))[0]["Id"],
        "postgresImageIdentity": fixture_images["postgres:16-alpine"], "fixtureImages": fixture_images,
        "daemonImageIdentity": daemon_image, "daemonContainer": daemon, "daemonVolume": daemon, "network": network,
        "runnerSha256": digest(Path(__file__)),
        "verifierSha256": digest(Path(__file__).with_name("verify_quality_report_snapshot.py")),
        "sourceIdentity": source_identity, "baselineIdentity": args.baseline_identity,
        "baselinePath": str(before), "candidatePath": str(after), "projectPomSha256": digest(ROOT / "server/pom.xml"),
        "baselineClasses": main_before, "candidateClasses": main_after, "sharedTestClasses": tests,
        "workVolume": work, "cacheVolume": cache,
        "limits": {"runnerCpu": 4, "runnerMemory": "6g", "testHeap": "4g",
                   "postgresCgroup": "fixture default, no independent cgroup limit; same on both sides",
                   "postgresDurability": "fsync=on,synchronous_commit=on,full_page_writes=on"},
        "suite": TESTS, "repetitions": 3,
        "configuration": {"verifyNestedFootprint": False, "statementTrace": False, "iqcLinesPerReceipt": 1,
                          "fqcPreStockReports": 4, "reportExecutionSegments": 10, "directReceivers": 11},
        "scope": "synthetic service plus real commit; excludes preparation, HTTP and async notifications; local comparison, not production SLO proof",
    }
    write_json(output / "manifest.json", manifest)
    prepare_topology(manifest)
    local_repository = Path.home() / ".m2/repository"
    if not (local_repository / "com/fasterxml/jackson").is_dir():
        raise ValueError("Existing local Jackson artifacts are required; this runner never downloads dependencies")
    mounts = [
        "type=bind,source=" + before.as_posix() + ",target=/before,readonly",
        "type=bind,source=" + after.as_posix() + ",target=/after,readonly",
        "type=bind,source=" + (ROOT / "server/pom.xml").as_posix() + ",target=/project-pom.xml,readonly",
        "type=volume,source=" + args.cache + ",target=/old-cache,readonly",
        "type=bind,source=" + (local_repository / "com/fasterxml/jackson").as_posix() + ",target=/jackson,readonly",
        "type=volume,source=" + work + ",target=/runs",
        "type=volume,source=" + cache + ",target=/cache",
    ]
    command = ["run", "--rm", "--pull=never", "--user=0:0", "--network", "none"]
    for mount in mounts:
        command.extend(["--mount", mount])
    command.extend(["--entrypoint", "/bin/bash", args.image, "-lc", """
set -euo pipefail
mkdir -p /runs/baseline/classes /runs/baseline/test-classes /runs/candidate/classes /runs/candidate/test-classes /runs/project/server /cache/repository
cp /project-pom.xml /runs/project/server/pom.xml
cp -a /before/classes/. /runs/baseline/classes/
cp -a /after/classes/. /runs/candidate/classes/
cp -a /after/test-classes/. /runs/baseline/test-classes/
cp -a /after/test-classes/. /runs/candidate/test-classes/
cp -a /old-cache/repository/. /cache/repository/
mkdir -p /cache/repository/com/fasterxml/jackson
cp -a /jackson/. /cache/repository/com/fasterxml/jackson/
cat > /cache/settings.xml <<'XML'
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0">
  <profiles><profile><id>existing-cache-origins</id><repositories><repository>
    <id>aliyun-public</id><url>https://maven.aliyun.com/repository/public</url>
    <releases><enabled>true</enabled></releases><snapshots><enabled>false</enabled></snapshots>
  </repository></repositories></profile></profiles>
  <activeProfiles><activeProfile>existing-cache-origins</activeProfile></activeProfiles>
</settings>
XML
"""])
    docker(*command)
    if source_identity != workspace_source_identity() or tree_identity(before / "classes") != main_before or tree_identity(after / "classes") != main_after or tree_identity(after / "test-classes") != tests:
        raise ValueError("Sources or candidate artifacts changed during preparation; keep this evidence and prepare a fresh run")
    manifest["state"] = "PREPARED"
    write_json(output / "manifest.json", manifest)
    print(f"Prepared {args.run_id}; no JVM or PostgreSQL measurement was started. Manifest: {output / 'manifest.json'}")


def run(args: argparse.Namespace, output: Path) -> None:
    manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    if manifest["state"] != "PREPARED" or not args.quiet_window:
        raise ValueError("A completed preparation and an explicitly selected quiet window are required")
    if manifest["runnerSha256"] != digest(Path(__file__)):
        raise ValueError("Runner changed after preparation; prepare a new run")
    if manifest["verifierSha256"] != digest(Path(__file__).with_name("verify_quality_report_snapshot.py")):
        raise ValueError("Snapshot verifier changed after preparation")
    validate_topology(manifest)
    if manifest["imageIdentity"] != json.loads(docker("image", "inspect", manifest["image"]))[0]["Id"]:
        raise ValueError("Runner image changed after preparation")
    if manifest["postgresImageIdentity"] != json.loads(docker("image", "inspect", "postgres:16-alpine"))[0]["Id"]:
        raise ValueError("PostgreSQL image changed after preparation")
    for suffix, field in (("-work", "workVolume"), ("-cache", "cacheVolume"), ("-daemon", "daemonVolume")):
        expected = "uten-performance-" + args.run_id + suffix
        if manifest[field] != expected:
            raise ValueError("Unexpected run volume identity")
        owned(json.loads(docker("volume", "inspect", expected))[0], args.run_id)
    side = args.side
    if side == "candidate":
        baseline = json.loads((output / "baseline/receipt.json").read_text(encoding="utf-8"))
        if baseline["state"] != "PASSED":
            raise ValueError("A failed baseline cannot be used as paired acceptance evidence")
    if docker("ps", "-q", "--filter", "label=uten.performance.run=" + args.run_id):
        raise ValueError("Another side of this pair is still running")
    side_output = output / side
    if side_output.exists():
        raise ValueError("This side already has evidence; never overwrite a failed or completed sample")
    side_output.mkdir()
    verify_command = ["--run-id", args.run_id, "--side", side,
                      "--baseline", manifest["baselinePath"], "--candidate", manifest["candidatePath"]]
    print("Verifying complete frozen snapshots before starting the JVM", flush=True)
    verify_snapshot([*verify_command, "--stage", "before"])
    source = manifest["baselineIdentity"] if side == "baseline" else manifest["sourceIdentity"]
    target = "/runs/" + side
    container = "uten-performance-" + args.run_id + "-" + side
    command = ["docker", "run", "--rm", "--pull=never", "--user=0:0", "--name", container,
               "--label", "uten.performance.run=" + args.run_id, "--cpus=4", "--memory=6g", "--memory-swap=6g",
               "--network", manifest["network"],
               "--mount", "type=volume,source=" + manifest["workVolume"] + ",target=/runs",
               "--mount", "type=volume,source=" + manifest["cacheVolume"] + ",target=/cache",
               "-w", "/runs/project/server", "-e", "DOCKER_HOST=tcp://daemon:2375",
               "-e", "DOCKER_TLS_VERIFY=", "-e", "DOCKER_CERT_PATH=",
               "-e", "TESTCONTAINERS_HOST_OVERRIDE=daemon", "-e", "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock",
               "-e", "TESTCONTAINERS_RYUK_DISABLED=false", "-e", "TESTCONTAINERS_REUSE_ENABLE=false",
               "-e", "TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX=",
               "-e", "UTEN_RUN_DB_TESTS=true", "-e", "UTEN_RUN_PRODUCTION_STRESS=true",
               "-e", "UTEN_AI_OUTBOUND_ENABLED=false", "-e", "JAVA_TOOL_OPTIONS=", "-e", "JDK_JAVA_OPTIONS=",
               "-e", "MAVEN_OPTS=-Xmx768m -XX:ActiveProcessorCount=4", "--entrypoint", "/usr/bin/mvn", manifest["image"],
               "-o", "-B", "-ntp", "-s", "/cache/settings.xml", "-Dmaven.repo.local=/cache/repository", "-Duten.build.directory=" + target,
               "-Duten.test.jvm.heap.args=-Xms512m -Xmx4g -XX:ActiveProcessorCount=4",
               "-Dtest=" + manifest["suite"], "-Duten.perf.iqc-lines=1", "-Duten.perf.repetitions=3",
               "-Duten.fqc.handoffs.repetitions=3", "-Duten.fqc.batch.verifyNestedFootprint=false",
               "-Duten.fqc.batch.run=" + ("before" if side == "baseline" else "after"),
               "-Duten.concurrency.verify-nested-footprint=false", "-Duten.perf.source-identity=" + source,
               "-Duten.perf.report-directory=" + target + "/perf", "surefire:test"]
    receipt = {"side": side, "state": "RUNNING", "sourceIdentity": source,
               "latencyComparable": None, "loadReview": "Pending review of timestamped host-load.jsonl; unknown containers are observed only",
               "startedAtUtc": datetime.now(timezone.utc).isoformat(), "manifest": "../manifest.json"}
    write_json(side_output / "receipt.json", receipt)
    print(f"Running {side}; full output: {side_output / 'maven.log'}", flush=True)
    stop = threading.Event()
    observer = threading.Thread(target=observe_load, args=(side_output / "host-load.jsonl", stop, manifest["daemonContainer"]), daemon=True)
    observer.start()
    try:
        with (side_output / "maven.log").open("wb") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    finally:
        stop.set()
        observer.join(timeout=30)
    receipt.update(state="PROCESS_PASSED" if result.returncode == 0 else "FAILED", exitCode=result.returncode,
                   finishedAtUtc=datetime.now(timezone.utc).isoformat())
    write_json(side_output / "receipt.json", receipt)
    # Copy reports even after failure; failed runs are never deleted or relabelled.
    docker("run", "--rm", "--pull=never", "--user=0:0", "--network", "none", "--mount",
           "type=volume,source=" + manifest["workVolume"] + ",target=/runs,readonly", "--mount",
           "type=bind,source=" + side_output.as_posix() + ",target=/out", "--entrypoint", "/bin/bash", manifest["image"],
           "-lc", f"for name in surefire-reports perf logs; do if [ -d {target}/$name ]; then cp -R {target}/$name /out/; fi; done")
    profiles = [json.loads(line.split("FQC-BATCH-PROFILE ", 1)[1])
                for line in (side_output / "maven.log").read_text(encoding="utf-8", errors="replace").splitlines()
                if "FQC-BATCH-PROFILE " in line]
    write_json(side_output / "fqc-profiles.json", profiles)
    verify_snapshot([*verify_command, "--stage", "after"])
    if result.returncode == 0:
        try:
            xml = [ET.parse(path).getroot() for path in (side_output / "surefire-reports").glob("TEST-*.xml")]
            if sum(int(row.get("tests", "0")) for row in xml) != 4 or any(
                    int(row.get(key, "0")) for row in xml for key in ("failures", "errors", "skipped")):
                raise ValueError("Expected four complete, passing fixture methods with no skips")
            samples = [json.loads(path.read_text(encoding="utf-8")) for path in (side_output / "perf").glob("*.json")]
            if len(samples) != 24 or len(profiles) != 6:
                raise ValueError("Incomplete three-repetition measurement inventory")
            if any(row.get("verifyNestedFootprint") is not False for row in profiles + samples):
                raise ValueError("Diagnostic configuration drifted")
            if any(row.get("databaseSettings", {}).get(setting) != "on"
                   for row in profiles + samples for setting in ("fsync", "synchronous_commit", "full_page_writes")):
                raise ValueError("A measured PostgreSQL durability setting is not explicitly on")
            if any(row.get("diagnostic") is not False or row.get("sourceIdentity") != source for row in samples):
                raise ValueError("SQL tracing or source identity differs from the declared pair")
            classes = manifest["baselineClasses"] if side == "baseline" else manifest["candidateClasses"]
            stock = classes["files"]["com/uten/imp/features/stock/StockDocService.class"]
            quality = classes["files"]["com/uten/imp/features/production/quality/ProductionFqcInspectionService.class"]
            if any(row.get("stockBytecodeSha256") != stock or row.get("qualityBytecodeSha256") != quality for row in profiles):
                raise ValueError("Executed bytecode does not match the frozen artifact manifest")
            receipt["state"] = "PASSED"
        except (ValueError, KeyError) as invalid:
            receipt.update(state="INVALID_EVIDENCE", evidenceError=str(invalid))
            write_json(side_output / "receipt.json", receipt)
            raise
    write_json(side_output / "receipt.json", receipt)
    print(f"{side}: {receipt['state']} (exit {result.returncode}); evidence retained at {side_output}")
    if result.returncode:
        raise SystemExit(result.returncode)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "run"))
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--baseline", type=Path, default=ROOT / "server/target-perf-baseline")
    parser.add_argument("--candidate", type=Path, default=ROOT / "server/target-quality-safety-final")
    parser.add_argument("--baseline-identity", default="4c9f8dc89fd51856e9c6a855ae533d78481e6dbb")
    parser.add_argument("--image", default=IMAGE)
    parser.add_argument("--cache", default=CACHE)
    parser.add_argument("--dind-image", default=DIND)
    parser.add_argument("--side", choices=("baseline", "candidate"), default="baseline")
    parser.add_argument("--quiet-window", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,39}", args.run_id):
        parser.error("run-id must be 2..40 lowercase letters/digits/hyphens, starting with a letter")
    output = ROOT / "server/target-performance-linux" / args.run_id
    if args.mode == "prepare":
        prepare(args, output)
    else:
        run(args, output)


if __name__ == "__main__":
    main()
