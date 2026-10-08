"""Exercise the actual Bash storage policy against non-secret synthetic env files."""
from pathlib import Path
import re
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

    def test_current_production_nginx_blocks_the_whole_test_surface(self):
        runbook = (ROOT / "deploy/simple/RUNBOOK.zh-CN.md").read_text(encoding="utf-8")
        self.assertIn("cp deploy/nginx/uten-imp-http-lan.conf /etc/nginx/sites-available/uten-imp", runbook)
        for path in ("deploy/nginx/uten-imp-http-lan.conf", "deploy/nginx/uten-imp.conf.example"):
            nginx = (ROOT / path).read_text(encoding="utf-8")
            locations = re.findall(r"^\s*location\s+([^\n{]+)\s*\{([^{}]*)\}", nginx, re.MULTILINE)
            test_locations = [(header.strip(), body.strip()) for header, body in locations
                              if "/api/system-test" in header]
            with self.subTest(path=path):
                self.assertEqual({"= /api/system-test", "^~ /api/system-test/"},
                                 {header for header, _ in test_locations})
                self.assertEqual(2, len(test_locations))
                self.assertTrue(all(body == "return 404;" for _, body in test_locations))

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


if __name__ == "__main__":
    unittest.main()
