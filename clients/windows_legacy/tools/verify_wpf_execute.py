#!/usr/bin/env python3
"""True updater Execute in isolated process/known-folder fixtures; never a real client.

Child-only USERPROFILE/LOCALAPPDATA are probed before the unmodified helper is
started. All apps, jobs, profiles, backups and control files are under one new
random Temp root. No process is killed. Recovery evidence is copied only to the
task-private build directory before bounded fixtures are cleaned.
"""
from __future__ import annotations
import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid
import package_wpf as producer
from verify_wpf_update_pipeline import build_fixture_package, run

ROOT = producer.ROOT
FIXTURE_SOURCE = ROOT / "clients/windows_legacy/Uten.Legacy.Tests/Fixtures/UpdaterProcessFixture.cs"
SCENARIOS = ("success", "cancel", "no_authorization", "wrong_authorization", "wrong_start", "wrong_image",
             "parent_nonzero", "timeout", "mutex", "old_lease", "rollback")
CREATE_NO_WINDOW = 0x08000000

def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def atomic(path: Path, value: dict) -> None:
    temporary = path.parent / (".fixture-" + uuid.uuid4().hex)
    with temporary.open("xb") as stream:
        stream.write(json.dumps(value).encode("utf-8"))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)

def read_json(path: Path, seconds: float = 20, process: subprocess.Popen | None = None) -> dict:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.is_file():
            try:
                return json.loads(path.read_text(encoding="utf-8-sig"))
            except (ValueError, OSError):
                pass
        if process is not None and process.poll() is not None:
            raise ValueError(f"Fixture process exited {process.returncode} before {path.name}")
        time.sleep(0.02)
    raise ValueError("Timed out waiting for owned fixture: " + path.name)

def owned(root: Path) -> None:
    if root.parent.resolve() != Path(tempfile.gettempdir()).resolve() or not root.name.startswith("uten-wpf-execute-"):
        raise ValueError("Execute accepts only its direct random temporary root")
    for path in (root, *root.parents):
        if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
            raise ValueError("Fixture refuses linked directories")

def compile_parent(csc: Path, root: Path, architecture: str, *, incoming: bool) -> None:
    destination = root / ("payload" if incoming else "installed") / producer.EXECUTABLE
    version = "2.5.35" if incoming else "2.5.34"
    build = 2535 if incoming else 2534
    attributes = root / ("incoming-version.cs" if incoming else "parent-version.cs")
    attributes.write_text("using System.Reflection;\n"
        f'[assembly:AssemblyVersion("{version}.0")]\n[assembly:AssemblyFileVersion("{version}.{build}")]\n'
        f'[assembly:AssemblyInformationalVersion("{version}.{build}")]\n'
        + "[assembly:AssemblyDescription(" + json.dumps(producer.MARKER) + ")]\n", encoding="utf-8")
    reference = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Reference Assemblies/Microsoft/Framework/.NETFramework/v4.8/System.Web.Extensions.dll"
    arguments = [str(csc), "/nologo", "/langversion:7.3", "/target:winexe", "/platform:" + architecture,
        "/out:" + str(destination), "/r:" + str(reference), str(attributes), str(FIXTURE_SOURCE)]
    if incoming:
        arguments.append("/define:INCOMING")
    run(arguments)

def exclusive(path: Path):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    handle = kernel.CreateFileW(str(path), 0xC0000000, 0, None, 3, 0x00200000, None)
    if handle == wintypes.HANDLE(-1).value:
        raise OSError(ctypes.get_last_error(), "Cannot hold the explicit fixture file lease")
    return kernel, handle

def close_lease(lease) -> None:
    if lease:
        kernel, handle = lease
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle(handle)

def wait_restarted(pid: int, ticks: int, image: Path, seconds: int = 12) -> None:
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    handle = kernel.OpenProcess(0x100000 | 0x1000, False, pid)
    if not handle:  # Already exited after its bounded control wait.
        return
    try:
        created, exited, system, user = (wintypes.FILETIME() for _ in range(4))
        kernel.GetProcessTimes.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.FILETIME), ctypes.POINTER(wintypes.FILETIME), ctypes.POINTER(wintypes.FILETIME), ctypes.POINTER(wintypes.FILETIME)]
        if not kernel.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(system), ctypes.byref(user)):
            raise ValueError("Cannot verify restarted fixture start time")
        actual_ticks = ((created.dwHighDateTime << 32) | created.dwLowDateTime) + 504911232000000000
        name = ctypes.create_unicode_buffer(32768)
        length = wintypes.DWORD(len(name))
        kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
        if actual_ticks != ticks or not kernel.QueryFullProcessImageNameW(handle, 0, name, ctypes.byref(length)) or Path(name.value).resolve() != image.resolve():
            raise ValueError("Restarted fixture PID identity changed")
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        if kernel.WaitForSingleObject(handle, seconds * 1000) != 0:
            raise ValueError("Restarted inert fixture did not exit normally")
    finally:
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle(handle)

def verify_one(harness: Path, helper: Path, csc: Path, architecture: str, scenario: str, output: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="uten-wpf-execute-") as temporary:
        root = Path(temporary).resolve()
        owned(root)
        emitted = json.loads(run([str(harness), "emit-execute", str(root)]))
        if emitted.get("architecture") != architecture:
            raise ValueError("Fixture harness architecture differs")
        compile_parent(csc, root, architecture, incoming=False)
        compile_parent(csc, root, architecture, incoming=True)
        application = root / "installed"
        bootstrap = application / "client_updater"
        bootstrap.mkdir()
        shutil.copyfile(helper, bootstrap / helper.name)
        shutil.copyfile(helper.with_suffix(".exe.config"), bootstrap / (helper.name + ".config"))
        helper_hash = digest(bootstrap / helper.name)
        local = root / "profile/AppData/Local"
        local.mkdir(parents=True)
        (root / "profile/AppData/Roaming").mkdir()
        environment = dict(os.environ, USERPROFILE=str(root / "profile"), LOCALAPPDATA=str(local),
            APPDATA=str(root / "profile/AppData/Roaming"), UTEN_WPF_EXECUTE_ROOT=str(root), UTEN_WPF_FIXTURE_MODE="probe")
        main = application / producer.EXECUTABLE
        probe = subprocess.run([str(main)], env=environment, creationflags=CREATE_NO_WINDOW, timeout=10)
        if probe.returncode != 0:
            raise ValueError("Child known-folder isolation failed; helper was not started")
        folders = read_json(root / "knownfolders.json", 1)
        if Path(folders["localApplicationData"]).resolve() != local.resolve():
            raise ValueError("Known folders point outside the random fixture; helper was not started")
        package = build_fixture_package(root, architecture)
        profile = local / "Uten/UIMP-Win7-WPF"
        job = profile / "client-updates" / str(uuid.uuid4())
        job.mkdir(parents=True)
        (profile / "profile-sentinel.txt").write_text("owned fixture profile, never company credentials", encoding="utf-8")
        sibling = root / "other-runtime"
        sibling.mkdir()
        (sibling / "uten_imp.exe").write_bytes(b"owned Flutter isolation sentinel")
        sentinel_hash = digest(sibling / "uten_imp.exe")
        shutil.copyfile(root / "producer.zip", job / "package.zip")
        original = {name: digest(application / name) for name in producer.REQUIRED}
        expected = {name: digest(root / "payload" / name) for name in producer.REQUIRED}
        environment["UTEN_WPF_FIXTURE_MODE"] = "parent"
        image = main
        if scenario == "wrong_image":
            image = root / "other-parent.exe"
            shutil.copyfile(main, image)
        parent = subprocess.Popen([str(image)], env=environment, creationflags=CREATE_NO_WINDOW)
        child = None
        lease = None
        restart = None
        competitor_code = None
        competitor = None
        competitor_job = None
        try:
            parent_proof = read_json(root / "parent-ready.json", process=parent)
            instruction = {"schemaVersion": 1, "packagePath": str(job / "package.zip"), "sha256": package["sha256"],
                "sizeBytes": package["sizeBytes"], "version": "2.5.35", "buildNumber": 2535, "architecture": architecture,
                "runtimeFamily": "wpf_legacy", "parentPid": parent.pid,
                "parentStartTimeUtcTicks": parent_proof["startTimeUtcTicks"] + (1 if scenario == "wrong_start" else 0)}
            atomic(job / "instruction.json", instruction)
            child = subprocess.Popen([str(bootstrap / helper.name), str(job / "instruction.json")],
                env=environment, creationflags=CREATE_NO_WINDOW)
            if scenario in ("wrong_start", "wrong_image"):
                code = child.wait(timeout=20)
                if code == 0 or (job / "ready.json").exists():
                    raise ValueError("Helper accepted a different parent start time/image")
            else:
                ready = read_json(job / "ready.json", 20, child)
                if ready != {"schemaVersion": 1, "state": "ready", "parentPid": parent.pid,
                        "parentStartTimeUtcTicks": parent_proof["startTimeUtcTicks"], "updaterPid": child.pid}:
                    raise ValueError("Real ready handshake identity differs")
                if scenario == "mutex":
                    # Different jobs prove the app-root writer lock, rather than
                    # merely observing the same-job execution.lock.
                    competitor_job = profile / "client-updates" / str(uuid.uuid4())
                    competitor_job.mkdir()
                    shutil.copyfile(job / "package.zip", competitor_job / "package.zip")
                    competitor_instruction = dict(instruction, packagePath=str(competitor_job / "package.zip"))
                    atomic(competitor_job / "instruction.json", competitor_instruction)
                    competitor = subprocess.Popen([str(bootstrap / helper.name), str(competitor_job / "instruction.json")], env=environment, creationflags=CREATE_NO_WINDOW)
                    competitor_code = competitor.wait(timeout=10)
                    if competitor_code == 0 or child.poll() is not None or (competitor_job / "ready.json").exists():
                        raise ValueError("Single-writer lock did not isolate two real helper processes")
                if scenario == "old_lease":
                    lease = exclusive(application / "uten.client.json")
                elif scenario == "rollback":
                    # Deterministic IO failure at the last source file after previous
                    # approved files changed. No production fault switch or code hook.
                    lease = exclusive(job / "stage" / producer.EXECUTABLE)
                if scenario != "no_authorization":
                    consent = {"schemaVersion": 1, "state": "apply_authorized", "runtimeFamily": "wpf_legacy",
                        "architecture": architecture, "packageSha256": package["sha256"], "packageSizeBytes": package["sizeBytes"],
                        "version": "2.5.35", "buildNumber": 2535, "parentPid": parent.pid,
                        "parentStartTimeUtcTicks": parent_proof["startTimeUtcTicks"], "updaterPid": child.pid}
                    if scenario == "wrong_authorization":
                        consent["packageSha256"] = "0" * 64
                    atomic(job / "apply-authorized.json", consent)
                if scenario in ("cancel", "mutex"):
                    atomic(job / "cancel.flag", {"schemaVersion": 1, "state": "cancelled"})
                if scenario != "timeout":
                    atomic(root / "parent-exit.json", {"exitCode": 17 if scenario == "parent_nonzero" else 0})
                    parent.wait(timeout=10)
                code = child.wait(timeout=40)
            result = read_json(job / "result.json", 2)
            close_lease(lease)
            lease = None
            if scenario == "success":
                if code != 0 or not result["succeeded"]:
                    raise ValueError("Real helper failed to apply/restart the isolated fixture: " + str(result))
                restart = read_json(root / "restart-proof.json", 10)
                if (Path(restart["image"]).resolve() != main.resolve() or restart["fileVersion"] != "2.5.35.2535"
                        or restart["pid"] != result["restartedPid"] or restart["startTimeUtcTicks"] != result["restartedStartTimeUtcTicks"]):
                    raise ValueError("Restarted process/version identity differs")
                if {name: digest(application / name) for name in producer.REQUIRED} != expected:
                    raise ValueError("Successful Execute did not install all exact producer bytes")
            else:
                if code == 0 or result["succeeded"] or (root / "restart-proof.json").exists():
                    raise ValueError("Rejected/cancelled/failed Execute unexpectedly restarted")
                if {name: digest(application / name) for name in producer.REQUIRED} != original:
                    raise ValueError("Rejected or rolled-back Execute changed the old installation")
                if scenario == "rollback" and (result["state"] != "failed_rolled_back" or not result["rollbackComplete"]):
                    raise ValueError("Deterministic source lease did not exercise a complete real rollback")
            if scenario in ("success", "rollback"):
                recovery = read_json(job / "recovery-manifest.json", 2)
                if Path(recovery["appRoot"]).resolve() != application.resolve() or recovery["packageSha256"] != package["sha256"]:
                    raise ValueError("Persistent recovery manifest is not bound to this installation/package")
                for item in recovery["files"]:
                    if item["originalSha256"] != original[item["path"]] or digest(job / "backup" / item["path"]) != item["originalSha256"]:
                        raise ValueError("Retained old recovery material differs")
            if digest(bootstrap / helper.name) != helper_hash or digest(sibling / "uten_imp.exe") != sentinel_hash:
                raise ValueError("Updater changed its bootstrap or another runtime")
            if not (profile / "profile-sentinel.txt").exists():
                raise ValueError("Updater touched isolated profile data")
            evidence = output / (scenario + "-" + uuid.uuid4().hex)
            evidence.mkdir()
            for leaf in ("ready.json", "result.json", "update.log", "recovery-manifest.json", "instruction.json", "apply-authorized.json", "cancel.flag"):
                if (job / leaf).is_file():
                    shutil.copyfile(job / leaf, evidence / leaf)
            for leaf in ("knownfolders.json", "parent-ready.json", "restart-proof.json", "receipt.json"):
                if (root / leaf).is_file():
                    shutil.copyfile(root / leaf, evidence / leaf)
            if (job / "backup").is_dir():
                shutil.copytree(job / "backup", evidence / "backup")
            record = {"fixtureOnly": True, "scenario": scenario, "architecture": architecture, "helperExitCode": code,
                "state": result["state"], "rollbackComplete": result["rollbackComplete"], "ready": (job / "ready.json").exists(),
                "restartVerified": restart is not None, "knownFolderIsolated": True, "companyProfileTouched": False,
                "competitorExitCode": competitor_code, "helperSha256": helper_hash,
                "distinctJobMutex": competitor_job is not None,
                "evidence": str(evidence), "packageSha256": package["sha256"]}
            atomic(evidence / "summary.json", record)
            return record
        except BaseException as error:
            evidence = output / (scenario + "-failed-" + uuid.uuid4().hex)
            evidence.mkdir()
            for leaf in ("ready.json", "result.json", "update.log", "recovery-manifest.json", "instruction.json", "apply-authorized.json", "cancel.flag"):
                if (job / leaf).is_file():
                    shutil.copyfile(job / leaf, evidence / leaf)
            for leaf in ("knownfolders.json", "parent-ready.json", "restart-proof.json", "receipt.json"):
                if (root / leaf).is_file():
                    shutil.copyfile(root / leaf, evidence / leaf)
            if (job / "backup").is_dir():
                shutil.copytree(job / "backup", evidence / "backup")
            atomic(evidence / "failure.json", {"schemaVersion": 1, "fixtureOnly": True, "scenario": scenario,
                "architecture": architecture, "error": type(error).__name__ + ": " + str(error)})
            raise
        finally:
            close_lease(lease)
            if parent.poll() is None:
                atomic(root / "parent-exit.json", {"exitCode": 0})
                parent.wait(timeout=15)
            if child is not None and child.poll() is None:
                atomic(job / "cancel.flag", {"schemaVersion": 1, "state": "cancelled"})
                child.wait(timeout=35)
            if competitor is not None and competitor.poll() is None:
                atomic(competitor_job / "cancel.flag", {"schemaVersion": 1, "state": "cancelled"})
                competitor.wait(timeout=35)
            if restart is None and (root / "restart-proof.json").is_file():
                restart = json.loads((root / "restart-proof.json").read_text(encoding="utf-8-sig"))
            if restart is not None:
                (root / "restart-exit.flag").write_bytes(b"")
                wait_restarted(restart["pid"], restart["startTimeUtcTicks"], main)
            owned(root)  # Recheck exact Temp anchor before TemporaryDirectory cleanup.

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-harness", required=True, type=Path)
    parser.add_argument("--updater", required=True, type=Path)
    parser.add_argument("--csc", required=True, type=Path)
    parser.add_argument("--architecture", required=True, choices=("x86", "x64"))
    parser.add_argument("--scenario", choices=SCENARIOS + ("all",), default="all")
    parser.add_argument("--output-root", required=True, type=Path)
    args = parser.parse_args()
    try:
        output = producer._plain(args.output_root)
        allowed = (ROOT / "build/windows-wpf/installer-execute").resolve()
        if allowed not in output.parents or output == allowed:
            raise ValueError("Evidence must be in a task-owned child of build/windows-wpf/installer-execute")
        output.mkdir(parents=True, exist_ok=True)
        harness, helper, csc = (producer._plain(path) for path in (args.fixture_harness, args.updater, args.csc))
        if harness.name != "Uten.Wpf.PackageContract.Checks.exe" or helper.name != "Uten.Legacy.Updater.exe" or csc.name.lower() != "csc.exe":
            raise ValueError("Explicit fixture/compiler/helper paths are required")
        if producer.inspect_managed(helper, executable=True)["architecture"] != args.architecture:
            raise ValueError("Helper architecture differs")
        for scenario in SCENARIOS if args.scenario == "all" else (args.scenario,):
            print(json.dumps(verify_one(harness, helper, csc, args.architecture, scenario, output), ensure_ascii=False), flush=True)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        parser.error(str(error))

if __name__ == "__main__":
    main()
