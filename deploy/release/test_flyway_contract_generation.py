"""The standalone copies and their existing trust pins come from one reviewed source."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("flyway_contract_generator", ROOT / "tool/sync_flyway_version_contract.py")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class FlywayContractGenerationTest(unittest.TestCase):
    def fixture(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        names = {GENERATOR.SOURCE, *map(Path, GENERATOR.TARGETS)}
        for dependency, owners in GENERATOR.PIN_GRAPH:
            names.add(Path(dependency))
            names.update(Path(relative) for relative, _, _ in owners)
        for relative in names:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        return root

    def command(self, root, *arguments):
        return subprocess.run(
            [sys.executable, str(ROOT / "tool/sync_flyway_version_contract.py"), "--root", str(root), *arguments],
            text=True, capture_output=True, check=False,
        )

    def test_all_fourteen_copies_and_every_existing_pin_match_the_single_source(self):
        self.assertEqual(14, len(GENERATOR.TARGETS))
        for relative, error_type in GENERATOR.TARGETS.items():
            with self.subTest(caller=relative):
                self.assertEqual((ROOT / relative).read_text(encoding="utf-8"), GENERATOR.render(ROOT, relative))
                class CallerError(Exception):
                    pass
                scope = {error_type: CallerError}
                exec(GENERATOR.fragment(ROOT, error_type), scope)
                self.assertEqual((999, 11), scope["_flyway_version_key"]("999.11"))
                self.assertEqual((1,), scope["_flyway_history_version_key"]("01", "V01__enable_pgcrypto.sql"))
                with self.assertRaises(CallerError):
                    scope["_flyway_version_key"]("999_11")
                late_backfill = [("999", "V999__a.sql"), ("1000", "V1000__b.sql"), ("999.1", "V999_1__c.sql")]
                self.assertEqual(1000, scope["_flyway_history_head"](late_backfill))
                with self.assertRaises(CallerError):
                    scope["_flyway_history_head"]([("1000", "V1000__b.sql"), ("999", "V999__a.sql")])
        self.assertEqual([], GENERATOR.sync_pins(ROOT, True))

    def test_check_rejects_source_drift_without_rewriting_any_copy_or_pin(self):
        root = self.fixture()
        relative = next(iter(GENERATOR.TARGETS))
        previous = (root / relative).read_bytes()
        source = root / GENERATOR.SOURCE
        source.write_bytes(source.read_bytes() + b"\n# Synthetic source drift\n")
        checked = self.command(root, "--check")
        self.assertEqual(1, checked.returncode, checked.stderr)
        self.assertIn(relative, checked.stderr)
        self.assertEqual(previous, (root / relative).read_bytes())
        generated = self.command(root)
        self.assertEqual(0, generated.returncode, generated.stderr)
        verified = self.command(root, "--check")
        self.assertEqual(0, verified.returncode, verified.stderr)
        self.assertNotEqual(previous, (root / relative).read_bytes())

    def test_tampered_leaf_and_owner_pins_are_rejected_then_generated_in_dependency_order(self):
        root = self.fixture()
        dependency, owners = GENERATOR.PIN_GRAPH[0]
        leaf = root / dependency
        leaf.write_bytes(leaf.read_bytes() + b"\n# Synthetic reviewed dependency change\n")
        stale = GENERATOR.sync_pins(root, True)
        self.assertEqual({relative + ":" + name for relative, name, _ in owners}, set(stale))
        self.assertNotEqual([], GENERATOR.sync_pins(root, False))
        self.assertEqual([], GENERATOR.sync_pins(root, True))

    def test_missing_duplicate_and_unresolved_pins_never_become_approved(self):
        for text in ('OTHER = "' + "a" * 64 + '"\n', 'PIN = None\n',
                     'PIN = "' + "a" * 64 + '"\nPIN = "' + "b" * 64 + '"\n'):
            with self.subTest(source=text), self.assertRaises(ValueError):
                GENERATOR.pinned_text(text, "PIN", "f" * 64, "python")
        for text in ("readonly OTHER='" + "a" * 64 + "'\n", "readonly PIN='not-a-sha256'\n",
                     ("readonly PIN='" + "a" * 64 + "'\n") * 2):
            with self.subTest(source=text), self.assertRaises(ValueError):
                GENERATOR.pinned_text(text, "PIN", "f" * 64, "shell")

    def test_duplicate_or_missing_boundaries_fail_instead_of_inserting_a_second_parser(self):
        root = self.fixture()
        relative = "server/legacy_migration/migrate.sh"
        path = root / relative
        original = path.read_text(encoding="utf-8")
        for changed in (original + "\n" + GENERATOR.BEGIN + "\n", original.replace(GENERATOR.END, ""),
                        original.replace(GENERATOR.BEGIN, "# Removed boundary")):
            with self.subTest(source=changed[-80:]):
                path.write_text(changed, encoding="utf-8")
                with self.assertRaises(ValueError):
                    GENERATOR.render(root, relative)

    def test_source_and_pin_path_escape_or_symlink_are_rejected(self):
        root = self.fixture()
        outside = root.parent / (root.name + "-outside.py")
        outside.write_text("# outside the owned source\n", encoding="utf-8")
        self.addCleanup(outside.unlink)
        with self.assertRaises(ValueError):
            GENERATOR.source_file(root, outside)
        relative = next(iter(GENERATOR.TARGETS))
        path = root / relative
        path.unlink()
        try:
            path.symlink_to(outside)
        except OSError as error:
            self.skipTest(f"Creating a symlink is unavailable: {error}")
        with self.assertRaises(ValueError):
            GENERATOR.render(root, relative)
        path.unlink()
        source = root / GENERATOR.SOURCE
        source.unlink()
        source.symlink_to(outside)
        with self.assertRaises(ValueError):
            GENERATOR.fragment(root, "ValueError")


if __name__ == "__main__":
    unittest.main()
