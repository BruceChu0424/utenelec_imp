#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def controller_routes(relative: str) -> set[tuple[str, str]]:
    source = read(relative)
    base = re.search(r'@RequestMapping\("([^"]+)"\)', source)
    if base is None:
        raise AssertionError(f"controller has no literal base mapping: {relative}")
    routes: set[tuple[str, str]] = set()
    for mapping in re.finditer(
        r'@(Get|Post|Put|Patch|Delete)Mapping(?:\(\s*"([^"]*)"\s*\))?',
        source,
    ):
        suffix = mapping.group(2) or ""
        routes.add((mapping.group(1).upper(), base.group(1) + suffix))
    return routes


def location_block(configuration: str, declaration: str) -> str:
    marker = f"location {declaration} {{"
    start = configuration.find(marker)
    if start < 0:
        raise AssertionError(f"missing Nginx location: {declaration}")
    cursor = configuration.find("{", start)
    depth = 0
    while cursor < len(configuration):
        if configuration[cursor] == "{":
            depth += 1
        elif configuration[cursor] == "}":
            depth -= 1
            if depth == 0:
                return configuration[start : cursor + 1]
        cursor += 1
    raise AssertionError(f"unterminated Nginx location: {declaration}")


class InternalTestRuntimeContractTest(unittest.TestCase):
    def test_application_profile_is_production_like_but_fixed_local(self) -> None:
        profile = read("server/src/main/resources/application-internal-test.yml")
        for expected in (
            "address: 127.0.0.1",
            "url: ${UTEN_DB_URL}",
            "password: ${UTEN_DB_PASSWORD}",
            "local-allowed-cidrs: ${UTEN_LOCAL_ALLOWED_CIDRS}",
            "cors-allowed-origins: ${UTEN_CORS_ORIGINS}",
            "require-https: true",
            "lazy-initialization: false",
            "swagger-enabled: false",
            "provider: local",
            "uploads-enabled: false",
            "local-dir: /data/uten-imp/attachments",
            "path: /data",
            "threshold: 10GB",
        ):
            self.assertIn(expected, profile)
        self.assertNotIn("UTEN_STORAGE_LOCAL_DIR", profile)
        self.assertNotIn("UTEN_OSS_", profile)

    def test_prod_and_cloud_oss_gates_are_unchanged(self) -> None:
        gate = read(
            "server/src/main/java/com/uten/imp/config/ProductionStorageSafetyGate.java"
        )
        production = read("server/src/main/resources/application-prod.yml")
        cloud = read("server/src/main/resources/application-cloud.yml")
        self.assertIn('Profiles.of("prod", "cloud")', gate)
        self.assertIn('!"oss".equalsIgnoreCase', gate)
        self.assertIn("provider: ${UTEN_STORAGE_PROVIDER:oss}", production)
        self.assertIn("provider: ${UTEN_STORAGE_PROVIDER:oss}", cloud)
        self.assertIn("require-versioning: ${UTEN_OSS_REQUIRE_VERSIONING:true}", production)
        self.assertIn("require-versioning: ${UTEN_OSS_REQUIRE_VERSIONING:true}", cloud)

    def test_environment_validator_treats_file_as_data(self) -> None:
        validator = read("deploy/setup/validate-internal-test-server-env.sh")
        template = read("deploy/setup/server.env.internal-test.example")
        for expected in (
            "expect_exact UTEN_PROFILE internal-test",
            "expect_exact SPRING_FLYWAY_ENABLED false",
            "expect_exact UTEN_REQUIRE_HTTPS true",
            "expect_boolean UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED",
            "expect_exact UTEN_STORAGE_PROVIDER local",
            "expect_exact UTEN_STORAGE_LOCAL_DIR /data/uten-imp/attachments",
            "expect_exact UTEN_ATTACHMENT_UPLOADS_ENABLED false",
            "expect_absent \"$key\"",
            "validate_exclusive_service_account uten-imp uten-imp",
            "validate_exclusive_service_account uten-imp-migrate uten-imp-migrate",
            "the application environment contains the dedicated migrator credential",
            "#!/bin/bash",
            "validate_supported_environment_keys",
            "unsupported environment key:",
            'ipaddress.ip_network(raw, strict=True)',
            "network.prefixlen > parent.prefixlen",
            "expect_exact UTEN_STORAGE_PRESIGN_EXPIRY 300",
        ):
            self.assertIn(expected, validator)
        self.assertNotRegex(validator, r"(?m)^\s*(?:source|eval)\s")
        self.assertIn("UTEN_PROFILE=internal-test", template)
        self.assertIn("UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED=true", template)
        self.assertIn("UTEN_STORAGE_LOCAL_DIR=/data/uten-imp/attachments", template)
        self.assertNotIn("UTEN_OSS_ACCESS_KEY", template)
        self.assertNotIn("UTEN_OSS_ENDPOINT", template)
        self.assertNotIn("SPRING_MAIN_LAZY_INITIALIZATION", template)

    def test_permission_delegation_gate_accepts_only_explicit_booleans(self) -> None:
        validator = read("deploy/setup/validate-internal-test-server-env.sh")
        match = re.search(
            r"expect_boolean\(\) \{(?P<body>.*?)\n\}",
            validator,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        self.assertIn("true|false", match.group("body"))
        self.assertIn(
            "expect_boolean UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED", validator
        )

    def test_production_permission_delegation_gate_is_explicit_boolean(self) -> None:
        validator = read("deploy/setup/validate-server-env.sh")
        template = read("deploy/setup/server.env.oss-migration.example")
        phase3 = read("deploy/setup/phase3-runtime.sh")
        match = re.search(
            r"expect_boolean\(\) \{(?P<body>.*?)\n\}",
            validator,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        self.assertIn("true|false", match.group("body"))
        self.assertIn(
            "expect_boolean UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED", validator
        )
        for source in (template, phase3):
            self.assertIn(
                "UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED=true", source
            )

    def test_environment_allowlist_matches_the_template_and_excludes_controls(self) -> None:
        validator = read("deploy/setup/validate-internal-test-server-env.sh")
        template = read("deploy/setup/server.env.internal-test.example")
        match = re.search(
            r'case "\$environment_key" in\n(?P<keys>.*?)\)\n\s*;;',
            validator,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        raw_keys = match.group("keys").replace("\\\n", "").strip()
        allowed = {key.strip() for key in raw_keys.split("|")}
        template_keys = {
            line.split("=", 1)[0]
            for line in template.splitlines()
            if line and not line.startswith("#")
        }
        self.assertEqual(template_keys, allowed)
        for forbidden in (
            "SPRING_MAIN_LAZY_INITIALIZATION",
            "SPRING_APPLICATION_JSON",
            "JAVA_TOOL_OPTIONS",
            "JDK_JAVA_OPTIONS",
            "_JAVA_OPTIONS",
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "SHELLOPTS",
            "BASHOPTS",
            "PS4",
            "BASH_XTRACEFD",
            "BASH_ENV",
            "ENV",
        ):
            self.assertNotIn(forbidden, allowed)

    def test_embedded_cidr_policy_rejects_masking_and_public_bypasses(self) -> None:
        validator = read("deploy/setup/validate-internal-test-server-env.sh")
        match = re.search(
            r'/usr/bin/python3 -I - "\$configured" <<\'PY\'\n(?P<script>.*?)\nPY',
            validator,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        policy = match.group("script")

        def evaluate(value: str) -> int:
            return subprocess.run(
                [sys.executable, "-I", "-", value],
                input=policy,
                text=True,
                capture_output=True,
                check=False,
            ).returncode

        for accepted in (
            "127.0.0.0/8,192.168.0.0/23",
            "127.0.0.1/32,10.20.0.0/16",
            "::1/128,172.20.0.0/16",
        ):
            self.assertEqual(0, evaluate(accepted), accepted)
        for rejected in (
            "1.2.3.4/0",
            "10.1.2.3/8",
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "192.168.1.1/24",
            "203.0.113.0/24",
            "2001:db8::/64",
            "10.0.0.0/08",
            "10.0.0.0/+9",
            "010.0.0.0/9",
            "127.0.0.0/8,127.0.0.0/8",
        ):
            self.assertNotEqual(0, evaluate(rejected), rejected)

    def test_storage_preflight_proves_nvme_namespace(self) -> None:
        validator = read("deploy/setup/validate-internal-test-storage.sh")
        for expected in (
            "/usr/bin/mountpoint --quiet \"$DATA_ROOT\"",
            '[[ "$source_device" == /dev/mapper/* ]]',
            '-o ROTA "$source_device"',
            '[[ "$filesystem" == ext4 ]]',
            "capacity_bytes >= 300 * 1024 * 1024 * 1024",
            "root:uten-imp:750",
            "uten-imp:uten-imp:750",
        ):
            self.assertIn(expected, validator)
        self.assertNotIn("mkdir", validator)
        self.assertNotIn("mkfs", validator)

    def test_systemd_unit_keeps_fixed_profile_and_write_boundary(self) -> None:
        unit = read("deploy/systemd/uten-imp-internal-test.service.example")
        for expected in (
            "ExecStartPre=+/bin/bash --noprofile --norc -p /usr/local/sbin/uten-imp-validate-internal-test-server-env",
            "ExecStartPre=+/usr/local/sbin/uten-imp-validate-internal-test-storage",
            "-Dspring.profiles.active=internal-test",
            "-Dspring.main.lazy-initialization=false",
            "UnsetEnvironment=LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG GCONV_PATH BASH_ENV ENV SHELLOPTS BASHOPTS PS4 BASH_XTRACEFD",
            "-Dserver.address=127.0.0.1",
            "-Dspring.flyway.enabled=false",
            "-Duten.storage.provider=local",
            "-Duten.storage.local-dir=/data/uten-imp/attachments",
            "-Duten.storage.uploads-enabled=false",
            "ReadWritePaths=/data/uten-imp/attachments -/run/uten-imp-release",
            "IPAddressDeny=any",
            "IPAddressAllow=localhost",
            "WantedBy=multi-user.target",
        ):
            self.assertIn(expected, unit)

    def test_nginx_requires_dns_tls_and_blocks_out_of_scope_routes(self) -> None:
        nginx = read("deploy/nginx/uten-imp-internal-test.conf.example")
        for expected in (
            "server 127.0.0.1:8080;",
            "listen 80 default_server;",
            "listen 443 ssl default_server;",
            "ssl_reject_handshake on;",
            "server_name __INTERNAL_DOMAIN__;",
            "allow __EXACT_OFFICE_CIDR__;",
            "return 308 https://__INTERNAL_DOMAIN__$request_uri;",
            "proxy_set_header X-Forwarded-Proto $scheme;",
            "location ~ ^/api/website-inquiries(?:;[^/]*)?/ingest(?:[;/]|$) {",
            "location ~ ^/api/attachments(?:;[^/]*)?/(?:presign|confirm)(?:[;/]|$) {",
            "location ~ ^/api/attachments(?:;[^/]*)?/raw(?:[;/]|$) {",
            "location ^~ /swagger-ui/ {",
            "limit_except GET HEAD {",
        ):
            self.assertIn(expected, nginx)
        self.assertNotIn("__OSS_PUBLIC_HOST__", nginx)
        self.assertIsNone(re.search(r"server_name\s+(?:\d{1,3}\.){3}\d{1,3}", nginx))
        self.assertEqual(nginx.count("{"), nginx.count("}"))

    def test_controller_route_inventory_is_exact_and_gateway_policy_is_complete(self) -> None:
        inquiry_routes = controller_routes(
            "server/src/main/java/com/uten/imp/features/webinquiry/WebsiteInquiryController.java"
        )
        self.assertEqual(
            inquiry_routes,
            {
                ("POST", "/api/website-inquiries/ingest"),
                ("GET", "/api/website-inquiries"),
                ("GET", "/api/website-inquiries/new-count"),
                ("GET", "/api/website-inquiries/{id}"),
                ("POST", "/api/website-inquiries/{id}/status"),
                ("POST", "/api/website-inquiries/{id}/convert"),
            },
        )
        attachment_routes = controller_routes(
            "server/src/main/java/com/uten/imp/features/attachment/AttachmentController.java"
        )
        self.assertEqual(
            attachment_routes,
            {
                ("POST", "/api/attachments/presign"),
                ("POST", "/api/attachments/confirm"),
                ("GET", "/api/attachments"),
                ("GET", "/api/attachments/{id}/download-grant"),
                ("DELETE", "/api/attachments/{id}"),
                ("GET", "/api/attachments/reconciliation/findings"),
                (
                    "POST",
                    "/api/attachments/reconciliation/findings/{id}/approve-delete",
                ),
                ("PUT", "/api/attachments/raw/{key}"),
                ("GET", "/api/attachments/raw/{key}"),
            },
        )
        inquiry_controller = read(
            "server/src/main/java/com/uten/imp/features/webinquiry/WebsiteInquiryController.java"
        )
        inquiry_service = read(
            "server/src/main/java/com/uten/imp/features/webinquiry/WebsiteInquiryService.java"
        )
        inquiry_status_request = read(
            "server/src/main/java/com/uten/imp/features/webinquiry/dto/StatusUpdateRequest.java"
        )
        attachment_controller = read(
            "server/src/main/java/com/uten/imp/features/attachment/AttachmentController.java"
        )
        security_config = read("server/src/main/java/com/uten/imp/config/SecurityConfig.java")
        self.assertIn('"/api/website-inquiries/ingest"', security_config)
        self.assertIn(".anyRequest().authenticated()", security_config)
        self.assertEqual(3, inquiry_controller.count("hasAuthority('webinquiry:view')"))
        dynamic_inquiry_guard = (
            "hasAuthority(#request.requiredPermission()) and "
            "(#request.assignToMe() != true or hasAuthority('webinquiry:claim'))"
        )
        for source in (inquiry_controller, inquiry_service):
            self.assertEqual(1, source.count(dynamic_inquiry_guard))
            self.assertEqual(1, source.count("hasAuthority('webinquiry:convert_client')"))
            self.assertNotIn("hasAuthority('webinquiry:manage')", source)
        self.assertIn(
            '"closed".equals(status) ? "webinquiry:close" : "webinquiry:claim"',
            inquiry_status_request,
        )
        for permission, expected_count in {
            "attachment:upload": 3,
            "attachment:view": 1,
            "attachment:download": 2,
            "attachment:delete": 1,
            "attachment:reconcile:view": 1,
            "attachment:reconcile:approve_delete": 1,
        }.items():
            self.assertEqual(expected_count, attachment_controller.count(
                f"hasAuthority('{permission}')"))
        self.assertNotIn("hasAuthority('attachment:manage')", attachment_controller)
        self.assertNotIn("hasAuthority('attachment:reconcile')", attachment_controller)

        nginx = read("deploy/nginx/uten-imp-internal-test.conf.example")
        location_declarations = re.findall(r"(?m)^\s*location\s+([^\{]+?)\s*\{", nginx)
        self.assertEqual(
            [item.strip() for item in location_declarations if "/api/website-inquiries" in item],
            [r"~ ^/api/website-inquiries(?:;[^/]*)?/ingest(?:[;/]|$)"],
        )
        self.assertEqual(
            [item.strip() for item in location_declarations if "/api/attachments" in item],
            [
                r"~ ^/api/attachments(?:;[^/]*)?/(?:presign|confirm)(?:[;/]|$)",
                r"~ ^/api/attachments(?:;[^/]*)?/raw(?:[;/]|$)",
            ],
        )
        inquiry_location = r"~ ^/api/website-inquiries(?:;[^/]*)?/ingest(?:[;/]|$)"
        intake_location = r"~ ^/api/attachments(?:;[^/]*)?/(?:presign|confirm)(?:[;/]|$)"
        raw_location = r"~ ^/api/attachments(?:;[^/]*)?/raw(?:[;/]|$)"
        inquiry_block = location_block(nginx, inquiry_location)
        intake_block = location_block(nginx, intake_location)
        raw_block = location_block(nginx, raw_location)
        self.assertIn("return 404;", inquiry_block)
        self.assertNotIn("proxy_pass", inquiry_block)
        self.assertIn("return 404;", intake_block)
        self.assertNotIn("proxy_pass", intake_block)
        self.assertRegex(
            raw_block,
            r"limit_except GET HEAD\s*\{\s*deny all;\s*\}",
        )
        self.assertIn("proxy_pass http://uten_imp_internal_test_backend;", raw_block)
        self.assertLess(
            nginx.index(f"location {inquiry_location}"),
            nginx.index("location /api/ {"),
        )
        for reserved_location in (
            f"location {intake_location}",
            f"location {raw_location}",
        ):
            self.assertLess(nginx.index(reserved_location), nginx.index("location /api/ {"))

        # Exercise every live Controller mapping plus slash, matrix and child
        # variants. Only external ingest and the three upload stages are
        # closed; authenticated employee operations remain on generic /api/.
        def gateway_decision(method: str, path: str) -> str:
            spring_path = "/".join(segment.split(";", 1)[0] for segment in path.split("/"))
            if spring_path == "/api/website-inquiries/ingest" or spring_path.startswith(
                "/api/website-inquiries/ingest/"
            ):
                return "closed"
            if spring_path in {"/api/attachments/presign", "/api/attachments/confirm"} or any(
                spring_path.startswith(prefix)
                for prefix in ("/api/attachments/presign/", "/api/attachments/confirm/")
            ):
                return "closed"
            if spring_path == "/api/attachments/raw" or spring_path.startswith(
                "/api/attachments/raw/"
            ):
                return "read" if method in {"GET", "HEAD"} else "closed"
            return "generic"

        for method, path in inquiry_routes:
            concrete = path.replace("{id}", "11111111-2222-3333-4444-555555555555")
            expected = "closed" if path == "/api/website-inquiries/ingest" else "generic"
            self.assertEqual(expected, gateway_decision(method, concrete), concrete)
        for path in (
            "/api/website-inquiries/ingest/",
            "/api/website-inquiries/ingest/future-child",
            "/api/website-inquiries/ingest;matrix=1",
            "/api/website-inquiries;matrix=1/ingest",
        ):
            self.assertEqual("closed", gateway_decision("POST", path), path)
        for path in (
            "/api/website-inquiries",
            "/api/website-inquiries/",
            "/api/website-inquiries/new-count",
            "/api/website-inquiries/11111111-2222-3333-4444-555555555555/status",
        ):
            self.assertEqual("generic", gateway_decision("GET", path), path)
        for method, path in attachment_routes:
            concrete = path.replace("{id}", "11111111-2222-3333-4444-555555555555").replace(
                "{key}", "approved-final-object.pdf"
            )
            if path in {"/api/attachments/presign", "/api/attachments/confirm"}:
                expected = "closed"
            elif path == "/api/attachments/raw/{key}":
                expected = "read" if method == "GET" else "closed"
            else:
                expected = "generic"
            self.assertEqual(expected, gateway_decision(method, concrete), concrete)
            if path == "/api/attachments/raw/{key}" and method == "GET":
                self.assertEqual("read", gateway_decision("HEAD", concrete), concrete)
        for path in (
            "/api/attachments/presign/",
            "/api/attachments/presign;matrix=1",
            "/api/attachments/confirm/retry",
            "/api/attachments;matrix=1/confirm",
        ):
            self.assertEqual("closed", gateway_decision("POST", path), path)
        self.assertEqual(
            "generic",
            gateway_decision("POST", "/api/attachments/reconciliation/findings/id/approve-delete"),
        )
        self.assertEqual("generic", gateway_decision("DELETE", "/api/attachments/id"))


if __name__ == "__main__":
    unittest.main()
