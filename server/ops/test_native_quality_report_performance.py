"""Evidence/command safety tests; never invoke Java, Maven, Docker or a database."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

SCRIPT = Path(__file__).with_name("run_native_quality_report_performance.py")
SPEC = importlib.util.spec_from_file_location("native_quality_performance", SCRIPT)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class NativePerformanceEvidenceTest(unittest.TestCase):
    def fixture(self, root):
        folder = root / "baseline"
        (folder / "surefire-reports").mkdir(parents=True)
        (folder / "perf").mkdir()
        (folder / "classes").mkdir()
        (folder / "test-classes").mkdir()
        dependency = root / "dependency.jar"
        with zipfile.ZipFile(dependency, "w") as archive:
            archive.writestr("org/example/Dependency.class", b"synthetic dependency")
        classpath = os.pathsep.join(map(str, (folder / "test-classes", folder / "classes", dependency)))
        classes = {"files": {name: "frozen-" + field for field, name in runner.CLASS_FILES.items()}}
        suite = ET.Element("testsuite", tests="4", failures="0", errors="0", skipped="0")
        properties = ET.SubElement(suite, "properties")
        for name, value in (("java.class.path", classpath), ("surefire.test.class.path", classpath),
                            ("uten.perf.source-identity", "source-fixture")):
            ET.SubElement(properties, "property", name=name, value=value)
        for name, method in sorted(runner.METHODS):
            ET.SubElement(suite, "testcase", classname="com.uten.imp.businesschain." + name, name=method)
        ET.ElementTree(suite).write(folder / "surefire-reports/TEST-fixture.xml", encoding="utf-8")
        common = {"sourceIdentity": "source-fixture", "verifyNestedFootprint": False,
                  "databaseSettings": {setting: "on" for setting in runner.DURABILITY}}
        for phase in runner.PHASES:
            for repetition in range(3):
                runner.save(folder / "perf" / f"{phase}-{repetition}.json",
                            {**common, "phase": phase, "repetition": repetition, "diagnostic": False, "elapsedMillis": 1.0})
        profiles = [{**common, "action": f"four-handoffs-{action}-{repetition}", "candidate": "before",
                     "reportCount": 4, "size": 4, "mode": "prestock", "wallMillis": 2.0,
                     **{field: "frozen-" + field for field in runner.CLASS_FILES}}
                    for action in ("pass", "replay") for repetition in range(3)]
        (folder / "maven.log").write_text("".join("FQC-BATCH-PROFILE " + json.dumps(row) + "\n" for row in profiles), encoding="utf-8")
        return folder, classes, {str(dependency): runner.digest(dependency)}

    def validate(self, fixture):
        folder, classes, dependencies = fixture
        return runner.validate_evidence(folder, "source-fixture", classes, "baseline", dependencies)

    def test_complete_exact_inventory_and_frozen_runtime_are_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self.validate(self.fixture(Path(temporary)))
            self.assertEqual((4, 24, 6), (evidence["methods"], evidence["samples"], evidence["fqcProfiles"]))

    def test_missing_or_duplicate_phase_cannot_be_hidden_by_the_total_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = self.fixture(Path(temporary)); folder = fixture[0]
            path = next((folder / "perf").glob("*.json"))
            data = json.loads(path.read_text()); data["repetition"] = 2 if data["repetition"] != 2 else 1
            runner.save(path, data)
            with self.assertRaisesRegex(ValueError, "24 JSON"):
                self.validate(fixture)

    def test_skip_wrong_method_or_classpath_is_rejected(self):
        for mutation in ("skip", "method", "classpath"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                fixture = self.fixture(Path(temporary)); path = fixture[0] / "surefire-reports/TEST-fixture.xml"
                xml = ET.parse(path); suite = xml.getroot()
                if mutation == "skip":
                    suite.set("skipped", "1")
                elif mutation == "method":
                    suite.find("testcase").set("name", "unrelatedPassingMethod")
                else:
                    suite.find("properties/property").set("value", "wrong-classpath")
                xml.write(path, encoding="utf-8")
                with self.assertRaises(ValueError):
                    self.validate(fixture)

    def test_source_diagnostics_durability_and_actual_bytecode_fail_closed(self):
        for field, value in (("sourceIdentity", "wrong-source"), ("verifyNestedFootprint", True),
                             ("databaseSettings", {"fsync": "off"}), ("stockBytecodeSha256", "wrong-class")):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                fixture = self.fixture(Path(temporary)); path = fixture[0] / "maven.log"
                lines = path.read_text().splitlines()
                data = json.loads(lines[0].split("FQC-BATCH-PROFILE ", 1)[1]); data[field] = value
                lines[0] = "FQC-BATCH-PROFILE " + json.dumps(data)
                path.write_text("\n".join(lines), encoding="utf-8")
                with self.assertRaises(ValueError):
                    self.validate(fixture)

    def test_application_jar_overlay_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            jar = Path(temporary) / "old-server.jar"
            with zipfile.ZipFile(jar, "w") as archive:
                archive.writestr("com/uten/imp/features/stock/StockDocService.class", b"old bytecode")
            with self.assertRaisesRegex(ValueError, "application classes"):
                runner.dependency_snapshot(str(jar))

    def test_rejects_busy_runner_without_stopping_anything(self):
        for snapshot in ({"javaProcesses": 1, "runningContainers": 0}, {"javaProcesses": 0, "runningContainers": 1}):
            with self.assertRaisesRegex(ValueError, "no waiting or process termination"):
                runner.require_idle(snapshot)

    def test_actual_postgres_containers_must_use_the_frozen_image_and_limits(self):
        images = {runner.POSTGRES_IMAGE: {"id": "pg-frozen"}, runner.RYUK_IMAGE: {"id": "ryuk-frozen"}}
        observed = {str(index): {"imageId": "pg-frozen", "nanoCpus": 0, "memoryBytes": 0} for index in range(3)}
        self.assertEqual(3, runner.validate_containers(observed, [], images)["postgresContainers"])
        observed["reaper"] = {"imageId": "ryuk-frozen", "nanoCpus": 0, "memoryBytes": 0}
        self.assertEqual(3, runner.validate_containers(observed, [], images)["postgresContainers"])
        observed["reaper"]["imageId"] = "unexpected-reaper"
        with self.assertRaisesRegex(ValueError, "unexpected image"):
            runner.validate_containers(observed, [], images)
        observed["reaper"]["imageId"] = "ryuk-frozen"
        observed["0"]["imageId"] = "other-postgres"
        with self.assertRaisesRegex(ValueError, "unexpected image"):
            runner.validate_containers(observed, [], images)

    def test_existing_evidence_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner.sys, "platform", "linux"), patch.object(runner, "capture") as capture:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "Output already exists"):
                runner.run(SimpleNamespace(baseline=root / "base", candidate=root / "head", output=root, isolated_runner=True))
            capture.assert_not_called()

    def test_selector_is_read_without_importing_the_existing_runner(self):
        self.assertIn("DailyReportComplexPerformancePostgresTest", runner.selected_suite(SCRIPT.resolve().parents[2]))

    def test_environment_drops_database_and_jvm_override_inputs(self):
        with patch.dict(os.environ, {"UTEN_DB_URL": "forbidden", "SPRING_DATASOURCE_URL": "forbidden",
                                     "JAVA_TOOL_OPTIONS": "forbidden", "DOCKER_HOST": "tcp://forbidden",
                                     "MAVEN_ARGS": "--settings private.xml", "MAVEN_OPTS": "-Dprivate.override=true"}):
            environment = runner.clean_environment(2)
            self.assertNotIn("UTEN_DB_URL", environment)
            self.assertNotIn("SPRING_DATASOURCE_URL", environment)
            self.assertNotIn("JAVA_TOOL_OPTIONS", environment)
            self.assertNotIn("MAVEN_ARGS", environment)
            self.assertEqual("-Xmx2g -XX:ActiveProcessorCount=2", environment["MAVEN_OPTS"])
            self.assertEqual("unix:///var/run/docker.sock", environment["DOCKER_HOST"])


class MavenRepositoryPolicyTest(unittest.TestCase):
    policy = SCRIPT.resolve().parents[2] / runner.REPOSITORY_SETTINGS

    def fixture(self, root):
        candidate = root / "head"
        source = candidate / runner.REPOSITORY_SETTINGS
        source.parent.mkdir(parents=True)
        shutil.copyfile(self.policy, source)
        output = root / "evidence"
        output.mkdir()
        command, manifest = runner.prepare_maven(output, candidate)
        return candidate, output, command, manifest

    def test_project_launcher_policy_is_portable_and_does_not_select_user_settings(self):
        arguments = self.policy.with_name("maven.config").read_text(encoding="utf-8").splitlines()
        self.assertEqual(["--ignore-transitive-repositories", "--global-settings",
                          "${maven.multiModuleProjectDirectory}/.mvn/central-repository-settings.xml"], arguments)

    def test_only_four_obsolete_ids_redirect_and_default_external_http_block_remains(self):
        ns = {"m": "http://maven.apache.org/SETTINGS/1.2.0"}
        settings = ET.parse(self.policy).getroot()
        mirrors = {mirror.findtext("m:id", namespaces=ns): mirror
                   for mirror in settings.findall("m:mirrors/m:mirror", ns)}
        self.assertEqual({"uten-central-obsolete-transitive-repositories", "maven-default-http-blocker"}, set(mirrors))
        redirect = mirrors["uten-central-obsolete-transitive-repositories"]
        self.assertEqual("flyway-community-db-support,MavenFeed,jvnet-nexus-releases,jvnet-nexus-snapshots",
                         redirect.findtext("m:mirrorOf", namespaces=ns))
        self.assertEqual("https://repo.maven.apache.org/maven2", redirect.findtext("m:url", namespaces=ns))
        self.assertNotEqual("true", redirect.findtext("m:blocked", namespaces=ns))
        blocker = mirrors["maven-default-http-blocker"]
        self.assertEqual("external:http:*", blocker.findtext("m:mirrorOf", namespaces=ns))
        self.assertEqual("http://0.0.0.0/", blocker.findtext("m:url", namespaces=ns))
        self.assertEqual("true", blocker.findtext("m:blocked", namespaces=ns))
        for element in ("servers", "proxies", "profiles", "activeProfiles", "localRepository"):
            self.assertIsNone(settings.find("m:" + element, ns))

    def test_native_pair_uses_one_head_policy_copy_and_owned_empty_user_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            candidate, output, command, manifest = self.fixture(Path(temporary))
            self.assertEqual(["mvn", "-B", "-ntp", "--ignore-transitive-repositories",
                              "-s", str(output / "settings.xml"), "-gs", str(output / "repository-settings.xml")], command)
            self.assertEqual(self.policy.read_bytes(), (output / "repository-settings.xml").read_bytes())
            self.assertEqual(runner.digest(self.policy), manifest["repositorySettingsSha256"])
            self.assertEqual(runner.digest(output / "settings.xml"), manifest["settingsSha256"])
            self.assertEqual([], list(ET.parse(output / "settings.xml").getroot()))
            # No baseline policy is needed: the same argv is used for both revisions.
            runner.verify_repository_policy(output, candidate, manifest["repositorySettingsSha256"])

    def test_modifying_either_the_head_policy_or_execution_copy_is_rejected(self):
        for location in ("source", "copy"):
            with self.subTest(location=location), tempfile.TemporaryDirectory() as temporary:
                candidate, output, _, manifest = self.fixture(Path(temporary))
                target = candidate / runner.REPOSITORY_SETTINGS if location == "source" else output / "repository-settings.xml"
                target.write_text('<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"/>\n', encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "repository source policy changed"):
                    runner.verify_repository_policy(output, candidate, manifest["repositorySettingsSha256"])


if __name__ == "__main__":
    unittest.main()
