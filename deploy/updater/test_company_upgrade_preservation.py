"""Company upgrade invariants; read source only, never touch an installed host.

Database preservation through Flyway is covered by backend integration tests.
These contracts protect deployment boundaries and the installed client identity
that owns preferences, credentials, drafts, and device audit receipts.
"""
from pathlib import Path
import importlib.util
import re
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def source(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def shell_function(text, name):
    found = re.search(r"(?ms)^" + re.escape(name) + r"\(\) \{.*?^\}", text)
    if found is None:
        raise AssertionError(f"Missing reviewed updater function: {name}")
    return found.group(0)


def load_release_tools():
    name = "company_upgrade_release_tools"
    spec = importlib.util.spec_from_file_location(name, ROOT / "deploy/release/release_tools.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class CompanyUpgradePreservationTest(unittest.TestCase):
    def test_activation_and_rollback_read_existing_env_and_only_switch_code(self):
        activate = shell_function(source("deploy/simple/uten-imp-updater.sh"), "do_activate")
        self.assertIn('. "$UTEN_MIGRATOR_ENV"', activate)
        self.assertIn('ln -sfn "releases/$version" "$UTEN_BASE/current.new"', activate)
        self.assertIn('ln -sfn "releases/$prev_ver" "$UTEN_BASE/current.new"', activate)
        # A code rollback must never silently restore an old company database,
        # reinitialize business data, or reinstall an environment template.
        self.assertNotRegex(activate, r"\b(?:pg_restore|createdb|dropdb|psql|rsync|cp)\b")
        self.assertNotRegex(activate, r"(?im)^\s*(?:rm\s+-[^\n]*r|truncate)\b")
        self.assertNotIn("business_data_reset", activate)
        self.assertNotIn("install-server-env", activate)
        self.assertNotIn("phase2-postgres", activate)
        self.assertNotRegex(activate, r">\s*\"?\$(?:CONFIG|UTEN_MIGRATOR_ENV)\b")
        self.assertNotRegex(
            activate,
            r"(?im)^\s*(?:mv|install|rm|tee)\b[^\n]*(?:server\.env|migrator\.env|\$(?:CONFIG|UTEN_MIGRATOR_ENV))",
        )

    def test_runtime_config_and_original_files_stay_outside_release_directory(self):
        unit = source("deploy/simple/units/uten-imp.service")
        self.assertIn("WorkingDirectory=/opt/uten-imp/current", unit)
        self.assertIn("EnvironmentFile=/etc/uten-imp/server.env", unit)
        self.assertIn("ReadWritePaths=/var/lib/uten-imp-media/attachments /var/log/uten-imp", unit)
        self.assertIn("RequiresMountsFor=/var/lib/uten-imp-media/attachments /data/postgresql/16/main", unit)
        gate = source("server/src/main/java/com/uten/imp/config/ProductionStorageSafetyGate.java")
        self.assertIn('Profiles.of("prod", "cloud")', gate)
        self.assertIn('"internal".equalsIgnoreCase(storageProperties.getProvider())', gate)
        internal = source("server/src/main/java/com/uten/imp/common/storage/InternalStorageService.java")
        self.assertIn("!path.isAbsolute()", internal)
        updater = source("deploy/simple/uten-imp-updater.sh")
        self.assertIn('"${UTEN_MIGRATOR_ENV:=/etc/uten-imp/migrator.env}"', updater)
        prune = shell_function(updater, "prune_old")
        self.assertIn('if [ "$old" = "$active" ]; then', prune)
        self.assertIn('rm -rf "$RELEASES_DIR/$old"', prune)

    def test_release_payload_cannot_target_live_config_or_company_data_roots(self):
        tools = load_release_tools()
        with tempfile.TemporaryDirectory(prefix="uten-upgrade-contract-") as temp:
            root = Path(temp)
            for relative in (
                "etc/server.env", "data/postgresql/database", "attachments/final/original",
                "uploads/logo.png", "backups/company.dump", "deploy/setup/server.env",
            ):
                with self.subTest(path=relative), self.assertRaises(tools.ReleaseMetadataError):
                    tools.safe_relative_path(root / relative, root)
            self.assertEqual(
                tools.safe_relative_path(root / "server/uten-imp-server.jar", root),
                "server/uten-imp-server.jar",
            )

    def test_existing_environment_replacement_requires_separate_reviewed_action(self):
        installer = source("deploy/setup/install-server-env.sh")
        self.assertIn("replace_existing=false", installer)
        self.assertIn("--expected-current-sha256", installer)
        self.assertIn("--approval-reference", installer)
        self.assertIn("--confirm-replace", installer)
        self.assertIn("REPLACE LEGACY UTEN SERVER ENV", installer)
        activate = shell_function(source("deploy/simple/uten-imp-updater.sh"), "do_activate")
        self.assertNotIn("server.env.pending", activate)
        self.assertNotIn("replace-existing", activate)

    def test_windows_storage_identity_is_stable_across_company_branding(self):
        resource = source("windows/runner/Runner.rc")
        # The installed path_provider and secure_storage plugins both derive
        # their directory from these VERSIONINFO values. They are technical
        # storage identity, not the company's runtime display name. ProductName
        # now comes from the build-owned generated profile, not an RC literal.
        self.assertEqual(re.findall(r'VALUE\s+"CompanyName"\s*,\s*"([^"]+)"', resource), ["Uten"])
        self.assertEqual(re.findall(r'VALUE\s+"ProductName"\s*,\s*([^\r\n]+)', resource),
                         ['UTEN_NATIVE_PRODUCT_NAME "\\0"'])
        default = source("windows/runner/client_runtime_profile.default.g.h")
        macros = dict(re.findall(r'^#define\s+(UTEN_\w+)\s+"([^"\r\n]+)"$', default, re.MULTILINE))
        self.assertEqual(macros["UTEN_NATIVE_PRODUCT_NAME"], "优腾综合管理平台")
        self.assertEqual(macros["UTEN_BUILD_PROFILE"], "formal")
        self.assertIn("#define UTEN_LOCAL_TEST_BUILD 0", default)
        # LocalTest's English table must not change the historical formal
        # language/codepage and therefore the existing directory fallback.
        self.assertRegex(resource, r'#if UTEN_LOCAL_TEST_BUILD\s*(?://[^\n]*\n\s*)*'
                                  r'BLOCK "040904b0"\s*#else\s*BLOCK "080404b0"\s*#endif')
        self.assertRegex(resource, r'#if UTEN_LOCAL_TEST_BUILD\s*VALUE "Translation", 0x409, 1200\s*'
                                  r'#else\s*VALUE "Translation", 0x804, 1200\s*#endif')
        native_identity = source("windows/runner/client_runtime_identity.h")
        self.assertIn('#include "client_runtime_profile.g.h"', native_identity)
        self.assertIn('#include "client_runtime_profile.default.g.h"', native_identity)
        runner = source("windows/runner/CMakeLists.txt")
        self.assertIn('"${CMAKE_SOURCE_DIR}/../tool/generate_native_runtime_profile.dart"', runner)
        self.assertIn('"UTEN_GENERATED_RUNTIME_PROFILE=1"', runner)
        self.assertIn('set(BINARY_NAME "uten_imp")', source("windows/CMakeLists.txt"))
        for relative in ("windows/runner/Runner.rc", "windows/CMakeLists.txt",
                         "lib/core/runtime/client_runtime_profile.dart", "tool/generate_native_runtime_profile.dart"):
            self.assertNotIn("platform_branding", source(relative))
            self.assertNotIn("companyAliases", source(relative))

    def test_mobile_and_other_desktop_installation_ids_remain_fixed(self):
        android = source("android/app/build.gradle.kts")
        self.assertEqual(re.findall(r'applicationId\s*=\s*"([^"]+)"', android), ["com.uten.uten_imp"])
        # An explicit local Debug test variant owns separate storage. Production
        # identity must stay fixed and must never inherit that suffix.
        self.assertEqual(android.count("applicationIdSuffix"), 1)
        self.assertRegex(android, r'val localTestBuild = providers\.gradleProperty\("utenLocalTest"\)\.orNull == "true"')
        self.assertRegex(android, r'if \(localTestBuild && isReleaseBuild\)\s*\{\s*throw GradleException\(')
        self.assertRegex(android, r'buildTypes\s*\{\s*debug\s*\{\s*if \(localTestBuild\)\s*\{\s*applicationIdSuffix = "\.local_test"')
        release = re.search(r'(?s)\n        release \{(.*?)\n        \}', android)
        self.assertIsNotNone(release)
        self.assertNotIn("applicationIdSuffix", release.group(1))
        ios = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);", source("ios/Runner.xcodeproj/project.pbxproj"))
        self.assertTrue(ios)
        self.assertEqual(set(ios), {"com.uten.utenImp", "com.uten.utenImp.RunnerTests"})
        self.assertIn("$(PRODUCT_BUNDLE_IDENTIFIER)", source("ios/Runner/Info.plist"))
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.uten.utenImp", source("macos/Runner/Configs/AppInfo.xcconfig"))
        self.assertIn('set(APPLICATION_ID "com.uten.uten_imp")', source("linux/CMakeLists.txt"))

    def test_android_release_keeps_reviewed_signing_path_and_refuses_debug_key(self):
        android = source("android/app/build.gradle.kts")
        self.assertEqual(re.findall(r'applicationId\s*=\s*"([^"]+)"', android), ["com.uten.uten_imp"])
        self.assertIn('rootProject.file("key.properties")', android)
        signing_keys = re.search(r"val releaseSigningKeys\s*=\s*listOf\(([^)]+)\)", android)
        self.assertIsNotNone(signing_keys)
        self.assertEqual(
            set(re.findall(r'"([^"]+)"', signing_keys.group(1))),
            {"storeFile", "storePassword", "keyAlias", "keyPassword"},
        )
        self.assertIn("releaseSigningProperties.getProperty(it).isNullOrBlank()", android)
        self.assertIn('it.contains("Release", ignoreCase = true)', android)
        self.assertRegex(
            android,
            r"if \(isReleaseBuild && missingReleaseSigningKeys\.isNotEmpty\(\)\)\s*\{\s*throw GradleException\(",
        )
        self.assertIn('storeFile = rootProject.file(releaseSigningProperties.getProperty("storeFile"))', android)
        self.assertIn('signingConfig = signingConfigs.findByName("release")', android)
        self.assertNotRegex(android, r'signingConfigs\.(?:findByName|getByName)\("debug"\)')
        self.assertNotIn("platform_branding", android)
        # Read configuration code only: never open key.properties or a keystore.

    def test_web_update_keeps_origin_and_does_not_clear_company_preferences(self):
        workflow = source(".github/workflows/simple-release.yml")
        self.assertIn("--dart-define=API_BASE_URL=/api", workflow)
        api = source("lib/core/network/api_base_url.dart")
        self.assertIn("if (releaseMode && web)", api)
        self.assertIn("Web release API_BASE_URL must use same-origin /api.", api)
        update = source("web/update_check.js")
        self.assertIn("window.location.replace(url.toString())", update)
        self.assertIn('credentials: "same-origin"', update)
        self.assertIn("utenWebUpdateSafetyProbe", update)
        # Server-follow reload replaced the manual idle countdown. It still
        # awaits durable drafts and rejects ambiguous/busy or stale snapshots.
        live = update[update.index("async function check()"):
                      update.index("// A fresh entry")]
        for contract in (
            'health?.status !== "UP"',
            'const prepared = await prepare()',
            'const safety = window.utenWebUpdateSafetyProbe?.()',
            'prepared !== true',
            'safety?.schemaVersion !== 1',
            'safety.ready !== true',
            'safety.serverReloadSafe !== true',
            'safety.busy !== false',
            'Date.now() - safety.updatedAt > 25_000',
            'safety.updatedAt > Date.now() + 1_000',
        ):
            self.assertIn(contract, live)
        self.assertLess(live.index('const prepared = await prepare()'),
                        live.index('const safety = window.utenWebUpdateSafetyProbe?.()'))
        self.assertLess(live.index('safety.updatedAt > Date.now() + 1_000'),
                        live.index('navigate(latest,'))
        self.assertGreaterEqual(live.count('observed !== generation || !canResume()'), 3)
        registry = source("lib/core/web_update/web_update_safety.dart")
        self.assertIn('await checkpoint();', registry)
        self.assertIn('return snapshot.serverReloadSafe;', registry)
        self.assertIn('serverReloadSafe &= state.serverReloadSafe && !state.busy;', registry)
        self.assertIn("url.searchParams.set(RELEASE_PARAM", update)
        self.assertIn("new URL(window.location.href)", update)
        # Flutter's versioned asset cache may be refreshed. User storage must
        # not be cleared as part of the static-asset update path.
        for path in (ROOT / "web").glob("*"):
            if path.suffix not in {".js", ".html"}:
                continue
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"(?:localStorage|sessionStorage)\s*\.\s*clear\s*\(")
            self.assertNotRegex(text, r"indexedDB\s*\.\s*deleteDatabase\s*\(")
        for directory in (ROOT / "deploy/nginx", ROOT / "deploy/cloud"):
            for path in directory.glob("*.conf*"):
                self.assertNotRegex(path.read_text(encoding="utf-8"), r"(?im)^\s*add_header\s+['\"]?Clear-Site-Data\b")
        self.assertNotIn("ClearSiteDataHeaderWriter", source("server/src/main/java/com/uten/imp/config/SecurityConfig.java"))

    def test_release_workflows_do_not_uninstall_clients_or_clear_app_data(self):
        forbidden = r"(?im)^\s*(?:adb\s+(?:uninstall|shell\s+pm\s+clear)\b|xcrun\s+simctl\s+uninstall\b|Remove-AppxPackage\b)"
        for path in (ROOT / ".github/workflows").glob("*release*.yml"):
            self.assertNotRegex(path.read_text(encoding="utf-8"), forbidden, msg=path.name)


if __name__ == "__main__":
    unittest.main()
