"""Cross-file startup contract for the durable export capability (no host mutation)."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
VARIABLE = "UTEN_REPORT_EXPORT_DIRECTORY"
PRODUCTION = "/var/lib/uten-imp-report-exports"
INTERNAL = "/var/lib/uten-imp-internal-test-report-exports"


def values(path, name):
    return [line.partition("=")[2] for line in path.read_text(encoding="utf-8").splitlines()
            if line.startswith(name + "=")]


class ReportExportStorageContractTest(unittest.TestCase):
    def test_each_runtime_unit_initializes_its_private_persistent_namespace(self):
        for relative, expected in [
            ("deploy/simple/units/uten-imp.service", PRODUCTION),
            ("deploy/systemd/uten-imp.service.example", PRODUCTION),
            ("deploy/systemd/uten-imp-internal-test.service.example", INTERNAL),
        ]:
            unit = ROOT / relative
            self.assertEqual([Path(expected).name], values(unit, "StateDirectory"), relative)
            self.assertEqual(["0700"], values(unit, "StateDirectoryMode"), relative)
            self.assertIn(VARIABLE + "=" + expected, values(unit, "Environment"), relative)
            self.assertEqual(["uten-imp"], values(unit, "User"), relative)
            self.assertEqual(["uten-imp"], values(unit, "Group"), relative)
            self.assertNotIn(Path(expected).name, values(unit, "RuntimeDirectory"), relative)

    def test_application_property_bridges_the_explicit_environment_name(self):
        yaml = (ROOT / "server/src/main/resources/application.yml").read_text(encoding="utf-8")
        self.assertRegex(yaml, re.compile(r"^  report-export:\s*\n(?:\s*#.*\n)*    directory: \$\{UTEN_REPORT_EXPORT_DIRECTORY:\}$", re.MULTILINE))
        service = (ROOT / "server/src/main/java/com/uten/imp/features/reporting/export/ReportExportService.java").read_text(encoding="utf-8")
        self.assertIn('${uten.report-export.directory:}', service)
        self.assertIn('Files.isDirectory(root,LinkOption.NOFOLLOW_LINKS)', service)
        self.assertIn('!Files.isSymbolicLink(root)', service)

    def test_environment_templates_match_their_unit_without_sharing_candidate_files(self):
        production = ROOT / "deploy/setup/server.env.internal-storage.example"
        internal = ROOT / "deploy/setup/server.env.internal-test.example"
        self.assertEqual([PRODUCTION], values(production, VARIABLE))
        self.assertEqual([INTERNAL], values(internal, VARIABLE))
        self.assertNotEqual(PRODUCTION, INTERNAL)
        self.assertFalse(any(part in PRODUCTION.split("/") for part in ("current", "web", "attachments", "releases")))

    def test_storage_dropin_preserves_the_same_state_owner(self):
        dropin = ROOT / "deploy/systemd/uten-imp-internal-storage.conf.example"
        self.assertEqual([Path(PRODUCTION).name], values(dropin, "StateDirectory"))
        self.assertEqual(["0700"], values(dropin, "StateDirectoryMode"))
        self.assertIn(VARIABLE + "=" + PRODUCTION, values(dropin, "Environment"))

    def test_validators_reject_redirection_while_old_env_files_inherit_unit_defaults(self):
        for name, expected in (("validate-server-env.sh", PRODUCTION), ("validate-internal-test-server-env.sh", INTERNAL)):
            source = (ROOT / "deploy/setup" / name).read_text(encoding="utf-8")
            self.assertIn("expect_exact " + VARIABLE + " " + expected, source)
            self.assertIn('" != 0 ]]', source)
        internal = (ROOT / "deploy/setup/validate-internal-test-server-env.sh").read_text(encoding="utf-8")
        self.assertIn("|" + VARIABLE + "|", internal)

    def test_simple_sandbox_keeps_existing_paths_closed_and_does_not_clear_jobs(self):
        unit = ROOT / "deploy/simple/units/uten-imp.service"
        self.assertEqual(["strict"], values(unit, "ProtectSystem"))
        self.assertEqual(["0077"], values(unit, "UMask"))
        for line in values(unit, "ReadWritePaths"):
            self.assertNotIn("/var/lib ", line + " ")
        for line in values(unit, "ExecStartPre"):
            self.assertNotIn("rm ", line)


if __name__ == "__main__":
    unittest.main()
