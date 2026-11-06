#!/usr/bin/env python3
"""Embed the sole Flyway parser into existing trusted standalone tool snapshots."""

import argparse
import ast
import hashlib
import re
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("deploy/contracts/flyway_version_contract.py")
BEGIN = "# BEGIN GENERATED FLYWAY VERSION CONTRACT"
END = "# END GENERATED FLYWAY VERSION CONTRACT"
TARGETS = {
    "deploy/release/release_tools.py": "ReleaseMetadataError",
    "deploy/updater/release_guard.py": "ReleaseGuardError",
    "deploy/updater/runtime_boot_verifier.py": "BootVerificationError",
    "deploy/updater/release_updater.py": "UpdaterError",
    "deploy/updater/retention_manager.py": "RetentionError",
    "deploy/updater/recovery_commit_boot_verifier.py": "VerificationError",
    "deploy/updater/migration_authorization.py": "MigrationAuthorizationError",
    "deploy/postgres/backup/pgbackrest_health.py": "ContractError",
    "deploy/postgres/backup/backup_acceptance.py": "ContractError",
    "deploy/postgres/backup/paired_internal_backup.py": "ValueError",
    "server/legacy_migration/verify_candidate.py": "ValueError",
    "server/legacy_migration/migrate.sh": "ValueError",
    "deploy/setup/harden-existing-postgres-roles.sh": "ValueError",
}

# Dependency order is significant: pin every leaf before hashing its consumer.
PIN_GRAPH = (
    ("deploy/updater/release_guard.py", (
        ("deploy/updater/release_updater.py", "_GUARD_SHA256", "python"),
        ("deploy/updater/runtime_boot_verifier.py", "RELEASE_GUARD_SHA256", "python"),
        ("deploy/updater/migration_authorization.py", "RELEASE_GUARD_SHA256", "python"),
    )),
    ("deploy/updater/runtime_boot_verifier.py", (
        ("deploy/updater/release_updater.py", "RUNTIME_BOOT_VERIFIER_SHA256", "python"),
    )),
    ("deploy/updater/migration_authorization.py", (
        ("deploy/updater/release_updater.py", "MIGRATION_AUTHORIZATION_HELPER_SHA256", "python"),
        ("deploy/setup/phase3-runtime.sh", "MIGRATION_AUTHORIZATION_HELPER_SHA256", "shell"),
        ("deploy/setup/phase4-updater-nginx.sh", "MIGRATION_AUTHORIZATION_HELPER_SHA256", "shell"),
    )),
    ("deploy/updater/release_updater.py", (
        ("deploy/updater/retention_launcher.py", "APPROVED_RELEASE_UPDATER_SHA256", "python"),
    )),
    ("deploy/updater/retention_manager.py", (
        ("deploy/updater/retention_launcher.py", "APPROVED_RETENTION_MANAGER_SHA256", "python"),
    )),
)


def source_file(root: Path, relative: str | Path) -> Path:
    path = root / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Not an owned regular source file: {relative}")
    return path


def pinned_text(text: str, name: str, digest: str, kind: str) -> str:
    if kind == "shell":
        pattern = re.compile(rf"(?m)^readonly {re.escape(name)}='([0-9a-f]{{64}})'$")
        matches = list(pattern.finditer(text))
        if len(matches) != 1:
            raise ValueError(f"Reviewed shell pin is absent or ambiguous: {name}")
        match = matches[0]
        return text[:match.start(1)] + digest + text[match.end(1):]
    values = []
    for node in ast.parse(text).body:
        names = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        if any(isinstance(target, ast.Name) and target.id == name for target in names):
            values.append(node.value)
    if len(values) != 1 or not isinstance(values[0], ast.Constant) or not isinstance(values[0].value, str) or re.fullmatch(r"[0-9a-f]{64}", values[0].value) is None:
        raise ValueError(f"Reviewed Python pin is absent, unresolved or ambiguous: {name}")
    value = values[0]
    lines = text.splitlines(keepends=True)
    start = sum(len(line) for line in lines[:value.lineno - 1]) + value.col_offset
    finish = sum(len(line) for line in lines[:value.end_lineno - 1]) + value.end_col_offset
    return text[:start] + '"' + digest + '"' + text[finish:]


def sync_pins(root: Path, check: bool) -> list[str]:
    stale = []
    for dependency, owners in PIN_GRAPH:
        leaf = source_file(root, dependency)
        digest = hashlib.sha256(leaf.read_bytes()).hexdigest()
        for relative, name, kind in owners:
            path = source_file(root, relative)
            text = path.read_text(encoding="utf-8")
            expected = pinned_text(text, name, digest, kind)
            if expected != text:
                stale.append(relative + ":" + name)
                if not check:
                    path.write_text(expected, encoding="utf-8", newline="\n")
    return stale


def fragment(root: Path, error_type: str) -> str:
    raw = source_file(root, SOURCE).read_bytes()
    text = raw.decode("utf-8")
    tree = ast.parse(text)
    removed = set()
    for node in (tree, *ast.walk(tree)):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.body and isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant) and isinstance(node.body[0].value.value, str):
                removed.update(range(node.body[0].lineno, node.body[0].end_lineno + 1))
        if isinstance(node, ast.ImportFrom) and node.module == "__future__":
            removed.update(range(node.lineno, node.end_lineno + 1))
    body = "\n".join(line for number, line in enumerate(text.splitlines(), 1) if number not in removed).strip()
    if '"""' in body or "'''" in body:
        raise ValueError("Generated parser must not close a caller's quoted program literal")
    return (
        f"{BEGIN}\n# Source: {SOURCE.as_posix()}\n# SHA-256: {hashlib.sha256(raw).hexdigest()}\n"
        f"{body}\n\n_FLYWAY_CONTRACT_ERROR = {error_type}\n{END}\n"
    )


def render(root: Path, relative: str) -> str:
    path = source_file(root, relative)
    text = path.read_text(encoding="utf-8")
    block = fragment(root, TARGETS[relative])
    if BEGIN in text or END in text:
        if text.count(BEGIN) != 1 or text.count(END) != 1:
            raise ValueError(f"Exactly one generated parser boundary is required: {relative}")
        start = text.index(BEGIN)
        finish = text.index(END, start) + len(END)
        if start and text[start - 1] != "\n":
            raise ValueError(f"Parser block must start in column zero: {relative}")
        if finish < len(text) and text[finish] == "\n":
            finish += 1
        return text[:start] + block + text[finish:]
    if path.suffix != ".py":
        raise ValueError(f"Reviewed quoted adapter must provide parser boundaries: {relative}")
    tree = ast.parse(text)
    offset = len(text)
    for node in tree.body:
        if isinstance(node, ast.If) and isinstance(node.test, ast.Compare):
            test = node.test
            if isinstance(test.left, ast.Name) and test.left.id == "__name__" and any(isinstance(value, ast.Constant) and value.value == "__main__" for value in test.comparators):
                offset = sum(len(line) for line in text.splitlines(keepends=True)[:node.lineno - 1])
                break
    return text[:offset].rstrip() + "\n\n\n" + block + "\n" + text[offset:]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--targets", nargs="+", choices=sorted(TARGETS))
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    stale = []
    for relative in args.targets or TARGETS:
        path = source_file(root, relative)
        expected = render(root, relative)
        actual = path.read_text(encoding="utf-8")
        if actual != expected:
            stale.append(relative)
            if not args.check:
                path.write_text(expected, encoding="utf-8", newline="\n")
    pin_stale = sync_pins(root, args.check)
    if args.check and (stale or pin_stale):
        print("Flyway generated contracts are stale: " + ", ".join(stale), file=sys.stderr)
        print("Flyway exact source pins are stale: " + ", ".join(pin_stale), file=sys.stderr)
        return 1
    print(f"{'Checked' if args.check else 'Generated'} {len(args.targets or TARGETS)} Flyway contract blocks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
