"""Exercise the actual Bash storage policy against non-secret synthetic env files."""
from pathlib import Path
import json
import re
import shutil
import subprocess
import os
import socket
import sys
import threading
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CurrentStorageConfigurationTest(unittest.TestCase):
    def test_current_first_install_uses_a_complete_internal_storage_template(self):
        template = (ROOT / "deploy/setup/server.env.internal-storage.example").read_text(encoding="utf-8")
        values = dict(line.split("=", 1) for line in template.splitlines() if line and not line.startswith("#"))
        required = {"UTEN_PROFILE", "UTEN_DB_URL", "UTEN_DB_USER", "UTEN_DB_PASSWORD", "UTEN_JWT_SECRET",
                    "UTEN_JWT_ISSUER", "UTEN_PGP_MASTER_KEY", "UTEN_PGP_KEY_VERSION", "UTEN_HMAC_KEY",
                    "UTEN_SECRET_CIPHER_KEY", "UTEN_BOOTSTRAP_ADMIN_RETIRED", "BOOTSTRAP_ADMIN_LOGIN",
                    "BOOTSTRAP_ADMIN_PASSWORD", "UTEN_CORS_ORIGINS", "SPRING_FLYWAY_ENABLED"}
        self.assertTrue(required.issubset(values))
        self.assertEqual("prod", values["UTEN_PROFILE"])
        self.assertEqual("false", values["UTEN_BUSINESS_DATA_RESET_ENABLED"])
        self.assertEqual("internal", values["UTEN_STORAGE_PROVIDER"])
        self.assertEqual("clamav", values["UTEN_ATTACHMENT_SCANNER_PROVIDER"])
        self.assertEqual("/run/clamav/clamd.ctl", values["UTEN_CLAMAV_UNIX_SOCKET"])
        runbook = (ROOT / "deploy/simple/RUNBOOK.zh-CN.md").read_text(encoding="utf-8")
        self.assertIn("参考完整 deploy/setup/server.env.internal-storage.example", runbook)
        self.assertNotIn("← 参考 deploy/setup/server.env.internal-test.example", runbook)

    def validate_template_syntax(self, template):
        # Execute only the production validator's actual non-executing parser.
        # Its host ownership, account and secret-file preflights must never run
        # against the developer machine, and the fixture contains no real secrets.
        source = (ROOT / "deploy/setup/validate-server-env.sh").read_text(encoding="utf-8")
        start = source.index("if ! LC_ALL=C awk '")
        end = source.index("\nfi", start) + len("\nfi")
        parser = source[start:end]
        with tempfile.TemporaryDirectory() as directory:
            env = Path(directory) / "production-template.env"
            env.write_text(template, encoding="utf-8")
            helpers = '''set -euo pipefail
ENV_FILE="$1"
die() { printf '%s\\n' 'Invalid synthetic environment syntax' >&2; exit 7; }
'''
            return subprocess.run(["bash", "-c", helpers + parser, "template-parser", str(env)],
                                  capture_output=True, text=True)

    def test_complete_current_template_passes_the_actual_production_parser(self):
        template = (ROOT / "deploy/setup/server.env.internal-storage.example").read_text(encoding="utf-8")
        result = self.validate_template_syntax(template)
        self.assertEqual(0, result.returncode, result.stderr)
        for invalid in (
            template.replace("UTEN_TRUSTED_PROXY_REGEX=127[.].*|::1",
                             "UTEN_TRUSTED_PROXY_REGEX='127[.].*|::1'"),
            template + "\nUTEN_PROFILE=prod\n",
        ):
            with self.subTest(invalid="quoted value" if "REGEX='" in invalid else "duplicate key"):
                self.assertNotEqual(0, self.validate_template_syntax(invalid).returncode)

    @staticmethod
    def nginx_locations(source):
        locations = {}
        for match in re.finditer(r"^\s*location\s+([^\n{]+)\s*\{", source, re.MULTILINE):
            start = match.end()
            depth = 1
            cursor = start
            while cursor < len(source) and depth:
                depth += (source[cursor] == "{") - (source[cursor] == "}")
                cursor += 1
            locations[match.group(1).strip()] = source[start:cursor - 1].strip()
        return locations

    def test_public_and_cloud_nginx_block_the_whole_test_surface(self):
        for path in ("deploy/nginx/uten-imp.conf.example", "deploy/cloud/nginx-cloud.conf.example"):
            nginx = (ROOT / path).read_text(encoding="utf-8")
            test_locations = {header: body for header, body in self.nginx_locations(nginx).items()
                              if "/api/system-test" in header}
            with self.subTest(path=path):
                self.assertEqual({"= /api/system-test", "^~ /api/system-test/"}, set(test_locations))
                self.assertTrue(all(body == "return 404;" for body in test_locations.values()))

    def test_lan_only_forwards_three_exact_reset_actions_with_existing_api_guards(self):
        runbook = (ROOT / "deploy/simple/RUNBOOK.zh-CN.md").read_text(encoding="utf-8")
        self.assertIn("cp deploy/nginx/uten-imp-http-lan.conf /etc/nginx/sites-available/uten-imp", runbook)
        nginx = (ROOT / "deploy/nginx/uten-imp-http-lan.conf").read_text(encoding="utf-8")
        locations = self.nginx_locations(nginx)
        actions = {"preview": "GET|HEAD|OPTIONS", "last-result": "GET|HEAD|OPTIONS", "reset": "POST|OPTIONS"}
        expected = {"= /api/system-test", "^~ /api/system-test/"} | {
            "= /api/system-test/business-data/" + action for action in actions}
        self.assertEqual(expected, {header for header in locations if "/api/system-test" in header})
        self.assertEqual("return 404;", locations["= /api/system-test"])
        self.assertEqual("return 404;", locations["^~ /api/system-test/"])
        api_proxy = set(re.findall(r"^\s*(proxy_(?:pass|http_version|set_header)\s+[^;]+;)",
                                   locations["/api/"], re.MULTILINE))
        self.assertTrue(api_proxy)
        for action, method in actions.items():
            body = locations["= /api/system-test/business-data/" + action]
            with self.subTest(action=action):
                self.assertIn(f"if ($request_method !~ ^({method})$) {{ return 405; }}", body)
                self.assertEqual(api_proxy, set(re.findall(
                    r"^\s*(proxy_(?:pass|http_version|set_header)\s+[^;]+;)", body, re.MULTILINE)))
                self.assertIn("limit_req zone=uten_api_ip burst=500 nodelay;", body)
                # Inherit the same LAN ACL, security headers and 2 MiB body cap.
                self.assertNotIn("add_header", body)
                self.assertNotIn("allow ", body)
                self.assertNotIn("client_max_body_size", body)
                # Forward Origin/preflight to the existing Spring CORS allowlist;
                # the edge must not create a wildcard or suppress credentials.
                self.assertNotIn("Access-Control-Allow", body)
                if action == "reset":
                    self.assertIn("proxy_read_timeout 600s;", body)
                    self.assertIn("proxy_send_timeout 600s;", body)
                else:
                    self.assertNotIn("proxy_read_timeout", body)
                    self.assertNotIn("proxy_send_timeout", body)

    def validate_reset_policy(self, values):
        source = (ROOT / "deploy/setup/validate-server-env.sh").read_text(encoding="utf-8")
        # Run the actual parser helpers and runtime policy, never privileged host preflights.
        helpers = source[source.index("\ndie() {"):source.index("\nvalidate_pgp_configuration() {")]
        start = source.index("expect_exact UTEN_PROFILE prod")
        policy = source[start:source.index("expect_exact SERVER_ADDRESS", start)]
        with tempfile.TemporaryDirectory() as directory:
            env = Path(directory) / "reset-policy.env"
            env.write_text("".join(f"{key}={value}\n" for key, value in values), encoding="utf-8")
            return subprocess.run(["bash", "-c", 'set -euo pipefail\nENV_FILE="$1"\n' + helpers + policy,
                                   "reset-policy", str(env)], capture_output=True, text=True)

    def test_reset_requires_explicit_boolean_on_prod_local_only(self):
        for enabled in ("false", "true"):
            with self.subTest(enabled=enabled):
                result = self.validate_reset_policy([
                    ("UTEN_PROFILE", "prod"), ("UTEN_DEPLOYMENT_SITE", "local"),
                    ("UTEN_BUSINESS_DATA_RESET_ENABLED", enabled)])
                self.assertEqual(0, result.returncode, result.stderr)
        for site, enabled in (("cloud", "true"), ("cloud", "false"), ("", "true"),
                              ("local", "yes"), ("local", "TRUE"), ("local", "")):
            with self.subTest(site=site, enabled=enabled):
                result = self.validate_reset_policy([
                    ("UTEN_PROFILE", "prod"), ("UTEN_DEPLOYMENT_SITE", site),
                    ("UTEN_BUSINESS_DATA_RESET_ENABLED", enabled)])
                self.assertNotEqual(0, result.returncode)
                self.assertNotIn("UTEN_DB_PASSWORD", result.stdout + result.stderr)
        for profile in ("dev", "internal-test", "cloud", ""):
            with self.subTest(profile=profile):
                self.assertNotEqual(0, self.validate_reset_policy([
                    ("UTEN_PROFILE", profile), ("UTEN_DEPLOYMENT_SITE", "local"),
                    ("UTEN_BUSINESS_DATA_RESET_ENABLED", "true")]).returncode)
        for fields in ([('UTEN_PROFILE', 'prod'), ('UTEN_DEPLOYMENT_SITE', 'local')],
                       [('UTEN_PROFILE', 'prod'), ('UTEN_DEPLOYMENT_SITE', 'local'),
                        ('UTEN_BUSINESS_DATA_RESET_ENABLED', 'false'), ('UTEN_BUSINESS_DATA_RESET_ENABLED', 'true')]):
            with self.subTest(missing_or_duplicate=fields):
                self.assertNotEqual(0, self.validate_reset_policy(fields).returncode)

    def validate(self, **changes):
        values = {
            "UTEN_STORAGE_PROVIDER": "internal",
            "UTEN_ATTACHMENT_UPLOADS_ENABLED": "false",
            "UTEN_ATTACHMENT_SCANNER_PROVIDER": "clamav",
            "UTEN_ATTACHMENT_RECONCILIATION_ENABLED": "false",
            "UTEN_STORAGE_LEGACY_LOCAL_READ_ENABLED": "false",
            "UTEN_STORAGE_LEGACY_OSS_READ_ENABLED": "false",
            "UTEN_INTERNAL_STORAGE_ROOT": "/var/lib/uten-imp-media/attachments",
            "UTEN_CLAMAV_UNIX_SOCKET": "/run/clamav/clamd.ctl",
        }
        values.update(changes)
        source = (ROOT / "deploy/setup/validate-server-env.sh").read_text(encoding="utf-8")
        start = source.index("expect_exact UTEN_STORAGE_PROVIDER internal")
        end = source.index("printf '%s\\n'", start)
        policy = source[start:end]
        with tempfile.TemporaryDirectory() as directory:
            env = Path(directory) / "synthetic.env"
            env.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
            helpers = r'''
set -euo pipefail
ENV_FILE="$1"
die() { printf '%s\n' "$*" >&2; exit 7; }
env_value() {
  local key="$1" count
  count="$(awk -F= -v key="$key" '$1 == key { n++ } END { print n+0 }' "$ENV_FILE")"
  [[ "$count" == 1 ]] || die 'missing or duplicate key'
  awk -v key="$key" 'index($0,key "=")==1 { print substr($0,length(key)+2); exit }' "$ENV_FILE"
}
expect_exact() { [[ "$(env_value "$1")" == "$2" ]] || die "invalid $1"; }
expect_boolean() { case "$(env_value "$1")" in true|false) ;; *) die "invalid $1";; esac; }
require_value() { [[ -n "$(env_value "$1")" ]] || die "empty $1"; }
'''
            return subprocess.run(["bash", "-c", helpers + policy, "storage-policy", str(env)], capture_output=True, text=True)

    def test_current_internal_contract_and_retained_local_are_accepted(self):
        self.assertEqual(0, self.validate().returncode)
        self.assertEqual(0, self.validate(UTEN_ATTACHMENT_SCANNER_PROVIDER="disabled", UTEN_CLAMAV_UNIX_SOCKET="").returncode)
        self.assertEqual(0, self.validate(UTEN_STORAGE_LEGACY_LOCAL_READ_ENABLED="true", UTEN_STORAGE_LOCAL_DIR="/data/uten-imp/attachments").returncode)

    def test_retired_or_unsafe_configurations_fail_closed(self):
        for change in (
            {"UTEN_STORAGE_PROVIDER": "oss"},
            {"UTEN_ATTACHMENT_SCANNER_PROVIDER": "test-only"},
            {"UTEN_ATTACHMENT_SCANNER_PROVIDER": "disabled", "UTEN_ATTACHMENT_UPLOADS_ENABLED": "true"},
            {"UTEN_CLAMAV_UNIX_SOCKET": "relative.sock"},
            {"UTEN_INTERNAL_STORAGE_ROOT": "/var/../etc"},
            {"UTEN_STORAGE_LEGACY_LOCAL_READ_ENABLED": "yes"},
            {"UTEN_STORAGE_LEGACY_LOCAL_READ_ENABLED": "true", "UTEN_STORAGE_LOCAL_DIR": "/var/lib/uten-imp-media/attachments"},
        ):
            with self.subTest(change=change):
                self.assertNotEqual(0, self.validate(**change).returncode)

    def test_reference_retirement_report_is_read_only_and_never_exposes_keys(self):
        sql = (ROOT / "deploy/setup/legacy-storage-reference-report.sql").read_text(encoding="utf-8")
        self.assertIn("BEGIN TRANSACTION READ ONLY", sql)
        self.assertIn("v_private_document_storage_references", sql)
        self.assertIn("attachment_object_outbox", sql)
        for command in ("DELETE FROM", "UPDATE ", "TRUNCATE ", "DROP "):
            self.assertNotIn(command, sql)

    def test_application_socket_preflight_is_conditional_and_uses_its_primary_group(self):
        for path in ("deploy/simple/units/uten-imp.service", "deploy/systemd/uten-imp.service.example"):
            unit = (ROOT / path).read_text(encoding="utf-8")
            self.assertIn("Group=uten-imp", unit)
            self.assertNotIn("SupplementaryGroups=clamav", unit)
            self.assertIn("Wants=network-online.target clamav-daemon.service", unit)
            command = next(line.split("ExecStartPre=/bin/sh -c '", 1)[1][:-1]
                           for line in unit.splitlines() if line.startswith("ExecStartPre=/bin/sh -c '"))
            command = command.replace("$$", "$")
            for provider, expected in (("disabled", 0), ("clamav", 1)):
                result = subprocess.run(["sh", "-c", command], env={"UTEN_ATTACHMENT_SCANNER_PROVIDER": provider,
                                        "UTEN_CLAMAV_UNIX_SOCKET": "/nonexistent-fixture/socket"}, capture_output=True)
                self.assertEqual(expected, result.returncode)
        socket = (ROOT / "deploy/systemd/clamav-uten-imp-unix.socket.conf.example").read_text(encoding="utf-8")
        self.assertIn("SocketGroup=uten-imp", socket)
        self.assertIn("SocketMode=0660", socket)

    @unittest.skipUnless(sys.platform == "linux" and hasattr(os, "geteuid") and os.geteuid() == 0,
                         "requires a disposable root Linux container to verify separate service identities")
    def test_socket_cold_start_access_uses_only_the_application_primary_group(self):
        unit = (ROOT / "deploy/simple/units/uten-imp.service").read_text(encoding="utf-8")
        command = next(line.split("ExecStartPre=/bin/sh -c '", 1)[1][:-1]
                       for line in unit.splitlines() if line.startswith("ExecStartPre=/bin/sh -c '")).replace("$$", "$")

        def service_identity():
            os.setgroups([])
            os.setgid(65534)
            os.setuid(65534)

        with tempfile.TemporaryDirectory(prefix="uten-socket-fixture-") as directory:
            root = Path(directory); root.chmod(0o755)
            endpoint = root / "clamd.ctl"
            env = {"UTEN_ATTACHMENT_SCANNER_PROVIDER": "clamav", "UTEN_CLAMAV_UNIX_SOCKET": str(endpoint)}
            self.assertNotEqual(0, subprocess.run(["sh", "-c", command], env=env, preexec_fn=service_identity).returncode)
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(endpoint)); server.listen(1)
                os.chown(endpoint, 65533, 65534)  # scanner owns it; app's primary group alone has access
                endpoint.chmod(0o660)
                self.assertEqual(0, subprocess.run(["sh", "-c", command], env=env, preexec_fn=service_identity).returncode)

                def reply():
                    connection, _ = server.accept()
                    with connection:
                        self.assertEqual(b"zPING\x00", connection.recv(6))
                        connection.sendall(b"PONG\x00")

                worker = threading.Thread(target=reply, daemon=True); worker.start()
                client = "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect(sys.argv[1]); s.sendall(b'zPING\\0'); assert s.recv(5)==b'PONG\\0'; s.close()"
                result = subprocess.run([sys.executable, "-c", client, str(endpoint)], preexec_fn=service_identity, capture_output=True)
                self.assertEqual(0, result.returncode, result.stderr.decode())
                worker.join(3); self.assertFalse(worker.is_alive())
                endpoint.chmod(0o600)
                self.assertNotEqual(0, subprocess.run(["sh", "-c", command], env=env, preexec_fn=service_identity).returncode)


class NginxResetTemplateVerifierTest(unittest.TestCase):
    """Execute the actual PowerShell boundary against isolated public fixtures."""

    @classmethod
    def setUpClass(cls):
        cls.pwsh = shutil.which("pwsh")
        if cls.pwsh is None:
            raise RuntimeError("PowerShell is required, as in the deployment CI template-validation step")
        cls.templates = {
            "lan": (ROOT / "deploy/nginx/uten-imp-http-lan.conf").read_text(encoding="utf-8"),
            "public": (ROOT / "deploy/nginx/uten-imp.conf.example").read_text(encoding="utf-8"),
            "cloud": (ROOT / "deploy/cloud/nginx-cloud.conf.example").read_text(encoding="utf-8"),
        }
        cls.locations = CurrentStorageConfigurationTest.nginx_locations(cls.templates["lan"])

    def check_cases(self, cases):
        # Parse and invoke the repository function itself. No template file, host
        # configuration, or shared working-tree file is changed for mutations.
        harness = r'''
param([string] $Verifier, [string] $Cases)
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Verifier, [ref] $tokens, [ref] $errors)
if ($errors.Count -ne 0) { throw 'Verifier syntax error' }
$definition = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Assert-NginxSystemTestBoundary'
}, $false)
if ($null -eq $definition) { throw 'Missing real Nginx boundary function' }
. ([scriptblock]::Create($definition.Extent.Text))
$results = foreach ($case in (Get-Content -LiteralPath $Cases -Raw | ConvertFrom-Json)) {
    try {
        Assert-NginxSystemTestBoundary $case.text $case.id $case.allowReset
        [pscustomobject]@{ id = $case.id; accepted = $true; error = '' }
    } catch {
        [pscustomobject]@{ id = $case.id; accepted = $false; error = $_.Exception.Message }
    }
}
ConvertTo-Json -InputObject @($results) -Depth 4 -Compress
'''
        with tempfile.TemporaryDirectory(prefix="uten-reset-template-contract-") as directory:
            work = Path(directory)
            (work / "verify.ps1").write_text(harness, encoding="utf-8")
            (work / "cases.json").write_text(json.dumps(cases), encoding="utf-8")
            result = subprocess.run([
                self.pwsh, "-NoLogo", "-NoProfile", "-File", str(work / "verify.ps1"),
                str(ROOT / "deploy/verify-templates.ps1"), str(work / "cases.json"),
            ], capture_output=True, text=True, timeout=60)
        self.assertEqual(0, result.returncode, result.stderr)
        actual = json.loads(result.stdout)
        self.assertEqual(len(cases), len(actual))
        for fixture, outcome in zip(cases, actual):
            with self.subTest(case=fixture["id"]):
                self.assertEqual(fixture["id"], outcome["id"])
                self.assertEqual(fixture["accepted"], outcome["accepted"], outcome["error"])
                if not fixture["accepted"]:
                    self.assertIn("Forbidden deployment contract:", outcome["error"])

    def case(self, name, text, *, template="lan", accepted=False):
        return {"id": name, "text": text, "allowReset": template == "lan", "accepted": accepted}

    def change_body(self, action, old, new):
        body = self.locations["= /api/system-test/business-data/" + action]
        self.assertIn(old, body)
        return self.templates["lan"].replace(body, body.replace(old, new, 1), 1)

    def add_location(self, template, location):
        before, after = self.templates[template].rsplit("}", 1)
        return before + "\n" + location + "\n}" + after

    def test_reviewed_lan_public_and_cloud_templates_pass(self):
        self.check_cases([self.case(name, text, template=name, accepted=True)
                          for name, text in self.templates.items()])

    def test_each_required_location_is_required_with_its_original_denial(self):
        cases = []
        for action in ("preview", "last-result", "reset"):
            header = "location = /api/system-test/business-data/" + action
            cases.append(self.case("missing-" + action, self.templates["lan"].replace(header, "location = /removed")))
        for header in ("location = /api/system-test", "location ^~ /api/system-test/"):
            cases.append(self.case("missing-" + header, self.templates["lan"].replace(header, "location = /removed")))
        cases.append(self.case("root-not-404", self.templates["lan"].replace(
            "location = /api/system-test { return 404; }", "location = /api/system-test { return 200; }")))
        self.check_cases(cases)

    def test_unknown_duplicate_and_broad_locations_fail_even_on_the_same_line(self):
        cases = [self.case("additional", self.add_location(
                           "lan", "location = /api/system-test/unknown { proxy_pass http://uten_imp_backend; }")),
                 self.case("inline-additional", self.templates["lan"].replace(
                     "location = /api/system-test { return 404; }",
                     "location = /api/system-test { return 404; } location = /api/system-test/unknown { return 200; }")),
                 self.case("duplicate", self.add_location("lan", "location = /api/system-test { return 404; }"))]
        for modifier in ("", "^~ ", "~ "):
            cases.append(self.case("broad-" + modifier, self.templates["lan"].replace(
                "location = /api/system-test/business-data/reset", "location " + modifier + "/api/system-test/business-data/reset")))
        self.check_cases(cases)

    def test_multiline_headers_keep_exact_allowlist_and_reject_unknown_locations(self):
        cases = []
        for action in ("preview", "last-result", "reset"):
            header = "location = /api/system-test/business-data/" + action + " {"
            multiline = "location\n =\n /api/system-test/business-data/" + action + "\n {"
            cases.append(self.case("reviewed-multiline-" + action,
                                   self.templates["lan"].replace(header, multiline), accepted=True))
        for index, header in enumerate((
                "location =\n /api/system-test/unreviewed {",
                "location\n = /api/system-test/unreviewed {",
                "location = /api/system-test/unreviewed\n {",
                "location ^~\n /api/system-test/unreviewed {",
                "location ~\n ^/api/system-test/unreviewed {",
                'location =\n "/api/system-test/unreviewed" {')):
            cases.append(self.case("unreviewed-multiline-" + str(index), self.add_location(
                "lan", header + " proxy_pass http://uten_imp_backend; }")))
        self.check_cases(cases)

    def test_read_and_reset_methods_remain_exact_and_cors_preflight_is_forwarded(self):
        cases = []
        for action in ("preview", "last-result", "reset"):
            allowed = "POST|OPTIONS" if action == "reset" else "GET|HEAD|OPTIONS"
            for replacement in ("GET|POST|HEAD|OPTIONS", allowed.replace("|OPTIONS", "")):
                cases.append(self.case(action + "-" + replacement,
                                       self.change_body(action, allowed, replacement)))
            cases.append(self.case(action + "-no-method-guard", self.change_body(
                action, f"if ($request_method !~ ^({allowed})$) {{ return 405; }}", "")))
        self.check_cases(cases)

    def test_proxy_rate_and_every_forwarded_header_are_mandatory(self):
        directives = ["limit_req zone=uten_api_ip burst=500 nodelay;",
                      "proxy_pass http://uten_imp_backend;", "proxy_http_version 1.1;",
                      'proxy_set_header Connection "";', "proxy_set_header Host $host;",
                      "proxy_set_header X-Forwarded-For $remote_addr;",
                      "proxy_set_header X-Forwarded-Proto $scheme;",
                      "proxy_set_header X-Request-Id $request_id;"]
        self.check_cases([self.case("missing-" + directive, self.change_body(action, directive, ""))
                          for action in ("preview", "last-result", "reset") for directive in directives])

    def test_no_route_may_override_inherited_acl_headers_body_limit_or_cors(self):
        additions = ["allow all;", "deny all;", "client_max_body_size 0;",
                     'add_header Strict-Transport-Security "changed";',
                     "add_header Access-Control-Allow-Origin *;", "auth_request off;"]
        self.check_cases([self.case("extra-" + directive, self.change_body(
            action, "proxy_http_version 1.1;", "proxy_http_version 1.1; " + directive))
            for action in ("preview", "last-result", "reset") for directive in additions])

    def test_only_reset_gets_both_exact_long_timeouts(self):
        cases = []
        for kind in ("read", "send"):
            directive = f"proxy_{kind}_timeout 600s;"
            cases.append(self.case("missing-" + kind, self.change_body("reset", directive, "")))
            cases.append(self.case("unbounded-" + kind, self.change_body("reset", directive, f"proxy_{kind}_timeout 0;")))
            for action in ("preview", "last-result"):
                cases.append(self.case(action + "-unexpected-" + kind, self.change_body(
                    action, "proxy_http_version 1.1;", "proxy_http_version 1.1; " + directive)))
        self.check_cases(cases)

    def test_public_and_cloud_never_allow_a_reset_exception(self):
        cases = []
        body = self.locations["= /api/system-test/business-data/reset"]
        for template in ("public", "cloud"):
            cases.append(self.case(template + "-reset", self.add_location(template,
                                   "location = /api/system-test/business-data/reset { " + body + " }"), template=template))
            cases.append(self.case(template + "-deny-bypass", self.templates[template].replace(
                "location ^~ /api/system-test/ { return 404; }",
                "location ^~ /api/system-test/ { proxy_pass http://uten_imp_backend; }"), template=template))
        self.check_cases(cases)


if __name__ == "__main__":
    unittest.main()
