"""Exercise migration resource synchronization through the real Maven lifecycle."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SERVER = Path(__file__).resolve().parents[1]
MAVEN = shutil.which("mvn")


@unittest.skipUnless(MAVEN, "Maven is required for resource lifecycle regression tests")
class MigrationResourcesTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="uten migration resources ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.server = self.root / "server"
        self.server.mkdir()
        shutil.copyfile(SERVER / "pom.xml", self.server / "pom.xml")
        shutil.copytree(SERVER / ".mvn", self.server / ".mvn")
        self.resources = self.server / "src/main/resources"
        self.migrations = self.resources / "db/migration"
        self.migrations.mkdir(parents=True)
        self.old_names = {
            "V908__goods_import_operation_binding.sql":
                "V910__goods_import_operation_binding.sql",
            "V909__unused_deleted_goods_code_reuse.sql":
                "V911__unused_deleted_goods_code_reuse.sql",
        }
        for number, old_name in enumerate(self.old_names):
            (self.migrations / old_name).write_bytes(
                f"-- renamed migration {number}\r\nSELECT {number};\r\n".encode()
            )
        (self.migrations / "V907__baseline.sql").write_bytes(b"SELECT 907;\n")
        self.other_resource = self.resources / "config/keep.bin"
        self.other_resource.parent.mkdir()
        self.other_resource.write_bytes(b"resource\x00\xff\r\n")

    def run_resources(self, arguments, from_root):
        command = [MAVEN, "--batch-mode", "--no-transfer-progress"]
        if from_root:
            command.extend(["-f", "server/pom.xml"])
        command.extend([*arguments, "process-resources"])
        result = subprocess.run(
            command,
            cwd=self.root if from_root else self.server,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=180,
        )
        self.assertEqual(
            result.returncode, 0,
            f"{subprocess.list2cmdline(command)}\n{result.stdout}\n{result.stderr}",
        )

    @staticmethod
    def file_bytes(directory):
        return {
            path.relative_to(directory).as_posix(): path.read_bytes()
            for path in directory.rglob("*") if path.is_file()
        }

    def exercise_rename(self, arguments, build_directory, from_root=False):
        output = self.server / build_directory
        classes = output / "classes"
        expected = self.file_bytes(self.migrations)
        self.run_resources(arguments, from_root)
        self.assertEqual(self.file_bytes(self.migrations), expected)
        self.assertEqual(self.file_bytes(classes / "db/migration"), expected)

        # Existing build outputs must survive migration-only cleanup.
        sentinels = {
            classes / "com/uten/AlreadyCompiled.class": b"\xca\xfe\xba\xbecompiled sentinel",
            classes / "config/generated.bin": b"generated resource\x00\xff",
            classes / "db/generated.bin": b"other database resource",
            output / "test-classes/Test.class": b"compiled test sentinel",
            output / "keep.txt": b"other build output",
        }
        for path, content in sentinels.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)

        for old_name, new_name in self.old_names.items():
            (self.migrations / old_name).rename(self.migrations / new_name)
        (self.migrations / "V908__legacy_initial_quantity_counter_provenance.sql").write_bytes(
            b"-- legitimate replacement version\nSELECT 908;\n"
        )
        (self.migrations / "V909__legacy_receipt_optional_order_reference_snapshot.sql").write_bytes(
            b"-- legitimate replacement version\nSELECT 909;\n"
        )

        expected = self.file_bytes(self.migrations)
        self.run_resources(arguments, from_root)
        self.assertEqual(self.file_bytes(self.migrations), expected)
        self.assertEqual(
            self.file_bytes(classes / "db/migration"),
            expected,
            "Packaged migrations must match current source names and bytes exactly",
        )
        self.assertEqual(
            (classes / "config/keep.bin").read_bytes(), self.other_resource.read_bytes()
        )
        for path, content in sentinels.items():
            with self.subTest(preserved=path.relative_to(output)):
                self.assertEqual(path.read_bytes(), content)

    def test_default_target_removes_renamed_migrations(self):
        self.exercise_rename([], "target")

    def test_dev_run_default_target_dev_removes_renamed_migrations(self):
        self.exercise_rename(["-Pdev-run"], "target-dev")

    def test_root_f_and_spaced_build_directory_override(self):
        self.exercise_rename(
            ["-Pdev-run", "-Duten.build.directory=target custom output"],
            "target custom output",
            from_root=True,
        )


if __name__ == "__main__":
    unittest.main()
