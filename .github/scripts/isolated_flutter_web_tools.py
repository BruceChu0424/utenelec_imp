"""Pinned Flutter test-tool fixes in a task-owned copy; never modify the SDK.

The original3.44.2 host handler claims every URL containing host.dart.js,
including uten_page_scrollbar_host.dart.js. Chrome never registers that suite.
URI handling also needs URL semantics on Windows. Real widget-font fixtures
need the already-built unit_test_assets bundle on its actual HTTP namespace.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import urljoin

VERSION = 1
SDK_REVISION = "c9a6c484230f8b5e408ec57be1ef71dee1e77020"
SDK_SOURCE = "lib/src/test/flutter_web_platform.dart"
# Canonical Git blob at SDK_REVISION. Windows' clean checkout uses CRLF;
# its raw7f986a... bytes are recorded separately and never rewritten.
SDK_SOURCE_SHA256 = "2b7ab129052f2ffceba5cadd2c738d9bb69a1dcd7acde1bdc0fb4ef77b6b7403"
ASSET_FRAGMENT = Path(__file__).with_name("flutter_web_test_assets.dart.fragment")
HEX = re.compile(r"[0-9a-f]{64}\Z")


def sha256(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def _replace(text, before, after, count=1):
    if text.count(before) != count:
        raise ValueError("Pinned Flutter web-tool source boundary changed")
    return text.replace(before, after)


def patched_source(original):
    original = original.replace("\r\n", "\n")
    if hashlib.sha256(original.encode()).hexdigest() != SDK_SOURCE_SHA256:
        raise ValueError("Unreviewed Flutter web test-tool source")
    result = _replace(original,
                      "request.requestedUri.path.contains('host.dart.js')",
                      "request.requestedUri.path == '/static/host.dart.js'")
    result = _replace(result, "_fileSystem.path.fromUri(request.url)", "request.url.path", 2)
    result = _replace(result, 'window.testSelector = "$test";',
                      'window.testSelector = ${jsonEncode(test)};')
    result = _replace(result, ".add(_handleTestRequest)",
                      ".add(_handleTestRequest)\n        .add(_bundledTestAssetsHandler)")
    anchor = "  FutureOr<shelf.Response> _packageFilesHandler"
    return _replace(result, anchor, ASSET_FRAGMENT.read_text(encoding="utf-8") + "\n" + anchor)


def package_config(original_path, copied_tools):
    original_path = Path(original_path).resolve()
    value = json.loads(original_path.read_text(encoding="utf-8"))
    if value.get("configVersion") != 2 or not isinstance(value.get("packages"), list):
        raise ValueError("Invalid SDK tool package configuration")
    matches = 0
    for package in value["packages"]:
        if not isinstance(package.get("rootUri"), str):
            raise ValueError("Invalid SDK tool dependency URI")
        package["rootUri"] = urljoin(original_path.as_uri(), package["rootUri"])
        if package.get("name") == "flutter_tools":
            package["rootUri"] = Path(copied_tools).resolve().as_uri() + "/"
            matches += 1
    if matches != 1:
        raise ValueError("SDK must have exactly one Flutter tool owner")
    return value


def sdk_root(flutter):
    executable = Path(shutil.which(str(flutter)) or flutter).resolve()
    root = executable.parent.parent
    if not (root / "packages/flutter_tools" / SDK_SOURCE).is_file():
        raise ValueError("Flutter executable does not own the pinned SDK layout")
    return root


def _sdk_inputs(root):
    paths = [root / "packages/flutter_tools" / SDK_SOURCE,
             root / "packages/flutter_tools/.dart_tool/package_config.json"]
    official_snapshot = root / "bin/cache/flutter_tools.snapshot"
    if official_snapshot.is_file():
        paths.append(official_snapshot)
    return {path.relative_to(root).as_posix(): sha256(path) for path in paths}


def _json_output(completed):
    output = completed.stdout.decode("utf-8", errors="strict")
    start = output.find("{")
    if completed.returncode != 0 or start < 0:
        raise ValueError("Isolated Flutter tool cannot report its SDK identity")
    return json.loads(output[start:])


def prepare(flutter, sdk, output, stdout, stderr):
    if sdk.get("frameworkVersion") != "3.44.2" or sdk.get("frameworkRevision") != SDK_REVISION:
        raise ValueError("Isolated tool requires the exact reviewed Flutter3.44.2 revision")
    root = sdk_root(flutter)
    supplied = Path(output).absolute()
    if supplied.is_symlink() or getattr(supplied, "is_junction", lambda: False)():
        raise ValueError("Private Flutter tool output cannot be a link")
    output = supplied.resolve()
    if output == root or output.is_relative_to(root):
        raise ValueError("Private Flutter tools cannot be written inside the SDK")
    before = _sdk_inputs(root)
    source = root / "packages/flutter_tools" / SDK_SOURCE
    patched = patched_source(source.read_text(encoding="utf-8"))
    inputs = {"version": VERSION, "sdk_revision": SDK_REVISION, "sdk_root": str(root),
              "sdk_source_normalized_sha256": SDK_SOURCE_SHA256,
              "sdk_inputs": before, "bootstrap_sha256": sha256(__file__),
              "asset_fragment_sha256": sha256(ASSET_FRAGMENT),
              "patched_source_sha256": hashlib.sha256(patched.encode()).hexdigest()}
    key = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()[:16]
    private = output / key
    metadata = private / "receipt.json"
    environment = dict(os.environ, FLUTTER_ROOT=str(root), FLUTTER_SUPPRESS_ANALYTICS="true")
    if metadata.is_file():
        receipt = json.loads(metadata.read_text(encoding="utf-8"))
        if receipt.get("inputs") != inputs:
            raise ValueError("Private Flutter tool input ownership changed")
        for name in ("package_config.json", "flutter_tools_private.snapshot", "framework/" + SDK_SOURCE):
            if receipt.get("files", {}).get(name) != sha256(private / name):
                raise ValueError("Private Flutter tool bytes changed")
    else:
        if private.exists():
            raise ValueError("Incomplete private Flutter tool copy retained; use a fresh task output")
        private.mkdir(parents=True)
        tools = private / "framework"
        original_tools = root / "packages/flutter_tools"
        tools.mkdir()
        for name in ("bin", "lib", "templates"):
            shutil.copytree(original_tools / name, tools / name)
        for name in ("pubspec.yaml", "pubspec.lock"):
            path = original_tools / name
            if path.is_file():
                shutil.copy2(path, tools / name)
        (tools / SDK_SOURCE).write_text(patched, encoding="utf-8", newline="\n")
        configuration = package_config(original_tools / ".dart_tool/package_config.json", tools)
        (private / "package_config.json").write_text(json.dumps(configuration, indent=2) + "\n", encoding="utf-8")
        dart = root / ("bin/cache/dart-sdk/bin/dart.exe" if os.name == "nt" else "bin/cache/dart-sdk/bin/dart")
        prefix = [str(dart), "--packages=" + str(private / "package_config.json"),
                  str(private / "flutter_tools_private.snapshot")]
        build = [str(dart), prefix[1], "--snapshot=" + prefix[2], str(tools / "bin/flutter_tools.dart")]
        completed = subprocess.run(build, cwd=output.parent.parent, env=environment,
                                   stdout=stdout, stderr=stderr, check=False)
        if completed.returncode != 0:
            raise ValueError("Private Flutter test-tool compilation failed; original SDK was not patched")
        version = subprocess.run([*prefix, "--version", "--machine"], cwd=output.parent.parent,
                                 env=environment, capture_output=True, check=False)
        identity = _json_output(version)
        if any(identity.get(field) != sdk.get(field)
               for field in ("frameworkVersion", "frameworkRevision", "dartSdkVersion")):
            raise ValueError("Private Flutter tool changed the SDK/runtime identity")
        after = _sdk_inputs(root)
        if before != after:
            raise ValueError("SDK input bytes changed during isolated tool preparation")
        receipt = {"inputs": inputs, "files": {name: sha256(private / name)
                    for name in ("package_config.json", "flutter_tools_private.snapshot", "framework/" + SDK_SOURCE)},
                   "command_prefix": prefix}
        metadata.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    if _sdk_inputs(root) != before:
        raise ValueError("SDK input bytes changed")
    evidence = {"kind": "isolated-pinned-web-test-tools", **receipt,
                "sdk_inputs_after": before, "sdk_unchanged": True}
    validate_evidence(evidence, receipt["command_prefix"])
    return receipt["command_prefix"], evidence, environment


def confirm_sdk_unchanged(evidence):
    before = evidence["inputs"]["sdk_inputs"]
    after = _sdk_inputs(Path(evidence["inputs"]["sdk_root"]))
    if before != after:
        raise ValueError("SDK bytes changed during Chrome execution")
    evidence["sdk_inputs_after"] = after
    evidence["sdk_unchanged"] = True


def validate_evidence(evidence, prefix):
    if not isinstance(evidence, dict) or evidence.get("kind") != "isolated-pinned-web-test-tools":
        raise ValueError("Chrome report lacks an owned isolated Flutter tool")
    inputs = evidence.get("inputs", {})
    files = evidence.get("files", {})
    if not isinstance(inputs, dict) or not isinstance(files, dict) or not isinstance(inputs.get("sdk_inputs"), dict):
        raise ValueError("Invalid isolated Flutter test-tool evidence shape")
    required_sdk = {"packages/flutter_tools/" + SDK_SOURCE,
                    "packages/flutter_tools/.dart_tool/package_config.json"}
    if (inputs.get("version") != VERSION or inputs.get("sdk_revision") != SDK_REVISION
            or inputs.get("sdk_source_normalized_sha256") != SDK_SOURCE_SHA256
            or not required_sdk <= inputs["sdk_inputs"].keys()
            or any(not isinstance(value, str) or not HEX.fullmatch(value)
                   for value in inputs["sdk_inputs"].values())
            or inputs.get("bootstrap_sha256") != sha256(__file__)
            or inputs.get("asset_fragment_sha256") != sha256(ASSET_FRAGMENT)
            or evidence.get("sdk_unchanged") is not True
            or inputs.get("sdk_inputs") != evidence.get("sdk_inputs_after")
            or not isinstance(prefix, list) or len(prefix) != 3
            or evidence.get("command_prefix") != prefix
            or not all(isinstance(item, str) and item for item in prefix)
            or not prefix[1].startswith("--packages=")
            or not prefix[1].endswith("/package_config.json") and not prefix[1].endswith("\\package_config.json")
            or not prefix[2].endswith("flutter_tools_private.snapshot")
            or Path(prefix[0]).name not in {"dart", "dart.exe"}
            or not isinstance(inputs.get("patched_source_sha256"), str)
            or not HEX.fullmatch(inputs["patched_source_sha256"])
            or files.get("framework/" + SDK_SOURCE) != inputs["patched_source_sha256"]
            or any(not isinstance(files.get(name), str) or not HEX.fullmatch(files[name])
                   for name in ("package_config.json", "flutter_tools_private.snapshot"))):
        raise ValueError("Changed, unpinned or unowned isolated Flutter test-tool evidence")
