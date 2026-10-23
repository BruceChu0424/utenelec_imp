import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


remote = module("remote_access")
firewall = module("apply_firewall")
watchdog = module("tunnel_watchdog")
probe = module("performance_probe")


def profile():
    # Public test input is used offline only, never contacted by the tests.
    return {
        "schema_version": 1, "public_domain": "erp.example.test",
        "transport_server_name": "transport.uten.internal", "cloud_public_ipv4": "8.8.8.8",
        "cloud_wireguard_ipv4": "10.77.0.1", "company_wireguard_ipv4": "10.77.0.2",
        "cloud_wireguard_public_key": base64.b64encode(bytes(range(32))).decode(),
        "company_wireguard_public_key": base64.b64encode(bytes(range(1, 33))).decode(),
        "admin_ipv4_cidr": "1.1.1.1/32",
        "acme_account_uri": "https://acme-v02.api.letsencrypt.org/acme/acct/123456",
        "remote_backend_port": 8082,
    }


class ProfileTests(unittest.TestCase):
    def test_reject_injection_broad_routes_secrets_and_unsafe_endpoints(self):
        bad = {
            "public_domain": ["erp.example.test; include /etc/passwd", "erp.example.test\n}", "https://erp.example.test", "*.example.test"],
            "cloud_public_ipv4": ["127.0.0.1", "10.0.0.1", "169.254.169.254", "0.0.0.0", "203.0.113.1"],
            "company_wireguard_ipv4": ["10.77.0.0/24", "127.0.0.1", "0.0.0.0/0", "::1"],
            "admin_ipv4_cidr": ["0.0.0.0/0", "1.1.1.0/24", "127.0.0.1/32"],
            "remote_backend_port": [8080, 5432, True, "8082"],
            "acme_account_uri": ["https://evil.test/account/1", "https://acme-staging-v02.api.letsencrypt.org/acme/acct/1"],
            "cloud_wireguard_public_key": ["A" * 44, base64.b64encode(bytes(32)).decode(), "secret\nkey"],
        }
        for field, variants in bad.items():
            for value in variants:
                with self.subTest(field=field, value=value):
                    candidate = profile()
                    candidate[field] = value
                    with self.assertRaises(remote.InvalidProfile):
                        remote.validate(candidate)
        candidate = profile()
        candidate["private_key"] = "sensitive-must-not-echo"
        with self.assertRaises(remote.InvalidProfile) as error:
            remote.validate(candidate)
        self.assertNotIn("sensitive", str(error.exception))

    def test_no_duplicate_hosts_keys_or_json_properties(self):
        for a, b in (("company_wireguard_ipv4", "cloud_wireguard_ipv4"),
                     ("company_wireguard_public_key", "cloud_wireguard_public_key"),
                     ("transport_server_name", "public_domain")):
            candidate = profile()
            candidate[a] = candidate[b]
            with self.assertRaises(remote.InvalidProfile):
                remote.validate(candidate)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile.json"
            path.write_text('{"secret":"first","secret":"second"}', encoding="utf-8")
            with self.assertRaises(remote.InvalidProfile):
                remote.load_profile(path)

    def test_render_never_overwrites_or_accepts_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rendered"
            remote.render(profile(), path)
            original = (path / "company/nginx.conf").read_bytes()
            with self.assertRaises(remote.InvalidProfile):
                remote.render(profile(), path)
            self.assertEqual(original, (path / "company/nginx.conf").read_bytes())
            self.assertNotIn("@@", original.decode())

    def test_distribution_stream_module_is_explicit_bounded_and_role_specific(self):
        candidate = profile()
        candidate["cloud_nginx_stream_module"] = "/usr/lib64/nginx/modules/ngx_stream_module.so"
        files = remote.files(candidate)
        self.assertIn("load_module /usr/lib64/nginx/modules/ngx_stream_module.so;", files["cloud/nginx.conf"])
        self.assertIn("load_module /usr/lib/nginx/modules/ngx_stream_module.so;", files["company/nginx.conf"])
        candidate["cloud_nginx_stream_module"] = "builtin"
        self.assertNotIn("load_module", remote.files(candidate)["cloud/nginx.conf"])
        for value in ("/tmp/untrusted.so", "/usr/lib64/nginx/modules/ngx_stream_module.so; include /etc/passwd", "builtin\nhttp {}", None):
            candidate["cloud_nginx_stream_module"] = value
            with self.assertRaises(remote.InvalidProfile):
                remote.validate(candidate)

    def test_private_commissioning_needs_no_fake_domain_or_acme_account(self):
        candidate = {key: value for key, value in profile().items() if key in remote.COMMISSIONING_FIELDS}
        files = remote.files(candidate, commissioning_only=True)
        self.assertNotIn("dns-records.txt", files)
        self.assertIn("NOT configured", files["COMMISSIONING-ONLY.txt"])
        self.assertIn("server_name remote-commissioning.invalid;", files["company/nginx.conf"])
        with self.assertRaises(remote.InvalidProfile):
            remote.files(candidate)
        candidate["public_domain"] = "erp.example.test"
        with self.assertRaises(remote.InvalidProfile):
            remote.files(candidate, commissioning_only=True)


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.files = remote.files(profile())

    def test_cloud_has_only_stream_not_employee_tls_termination(self):
        config = self.files["cloud/nginx.conf"]
        self.assertNotIn("http {", config)
        self.assertNotIn("employee.key", config)
        self.assertIn("proxy_ssl on;", config)
        self.assertIn("proxy_ssl_verify on;", config)
        self.assertIn("proxy_ssl_name transport.uten.internal;", config)
        self.assertNotIn("listen 0.0.0.0:443 ssl", config)
        self.assertNotIn("proxy_protocol on", config)
        self.assertIn("ssl_preread on;", config)
        self.assertIn("erp.example.test 127.0.0.1:15443;", config)
        self.assertIn('default "";', config)

    def test_dr_is_separate_sni_control_plane_without_employee_key_or_trusted_client_headers(self):
        candidate = profile()
        candidate["dr_public_domain"] = "admin.example.test"
        files = remote.files(candidate)
        cloud = files["cloud/nginx.conf"]
        self.assertIn("admin.example.test 127.0.0.1:19443;", cloud)
        self.assertIn("listen 127.0.0.1:19443 ssl http2;", cloud)
        self.assertIn("proxy_pass http://127.0.0.1:9087;", cloud)
        self.assertIn("/etc/uten-remote/tls/dr.key", cloud)
        self.assertNotIn("employee.key", cloud)
        self.assertIn('proxy_set_header X-Forwarded-For "";', cloud)
        self.assertIn('location ^~ /v1/broker/ { return 404; }', cloud)
        self.assertIn('location ^~ /v1/agent/ { return 404; }', cloud)
        self.assertIn("client_max_body_size 128k;", cloud)
        self.assertIn("limit_conn dr_global_connections 4;", cloud)
        self.assertIn("limit_req zone=dr_login burst=2 nodelay;", cloud)
        self.assertIn("15443, 19443, 9087", files["cloud/firewall.nft"])

    def test_company_has_two_layers_and_dedicated_remote_app_port(self):
        config = self.files["company/nginx.conf"]
        for required in ("listen 10.77.0.2:8443 ssl;", "ssl_verify_client on;", "proxy_pass 127.0.0.1:9443;",
                         "listen 127.0.0.1:9443 ssl http2;", "server 127.0.0.1:8082;", "proxy_next_upstream off;",
                         "proxy_cache off;", "private, no-store", 'proxy_set_header Forwarded "";',
                         "location = /api/website-inquiries/ingest { return 404; }",
                         "proxy_set_header X-Forwarded-For $remote_addr;", "proxy_set_header X-Request-Id $request_id;"):
            self.assertIn(required, config)
        for forbidden in ("127.0.0.1:8080", "5432", "set_real_ip_from", "real_ip_header", "$proxy_add_x_forwarded_for"):
            self.assertNotIn(forbidden, config)

    def test_firewall_disallows_forwarding_and_db_connections(self):
        for role in ("company", "cloud"):
            config = self.files[f"{role}/firewall.nft"]
            self.assertIn('iifname "wg-uten" drop', config)
            self.assertIn('oifname "wg-uten" drop', config)
            self.assertIn('meta skuid "uten-remote" drop', config)
            self.assertNotIn("dport 5432", config)
            self.assertNotIn("dport 22", config)
            self.assertNotIn("flush ruleset\n", config)
            wireguard = self.files[f"{role}/wg-uten.conf"]
            self.assertNotIn("PrivateKey =", wireguard)
            self.assertNotIn("0.0.0.0/0", wireguard)
            self.assertEqual(wireguard.count("AllowedIPs ="), 1)
            self.assertRegex(wireguard, r"AllowedIPs = 10\.77\.0\.[12]/32")
        self.assertIn("PersistentKeepalive = 25", self.files["company/wg-uten.conf"])
        self.assertNotIn("Endpoint =", self.files["cloud/wg-uten.conf"])

    def test_dns_issuance_is_bound_to_company_account_and_dns_challenge(self):
        dns = self.files["dns-records.txt"]
        self.assertIn("validationmethods=dns-01;accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/123456", dns)
        self.assertIn('CAA 0 issuewild ";"', dns)

    def test_unit_cannot_read_database_secrets_or_wireguard_private_key(self):
        for role in ("cloud", "company"):
            unit = self.files[f"{role}/uten-remote-nginx.service"]
            for required in ("User=uten-remote", "NoNewPrivileges=true", "ProtectSystem=strict",
                             "/etc/uten-imp-postgres", "/var/lib/postgresql", "InaccessiblePaths=/etc/uten-remote/wireguard"):
                self.assertIn(required, unit)
        self.assertNotIn("CAP_NET_ADMIN", self.files["company/uten-remote-nginx.service"])
        self.assertIn("SupplementaryGroups=uten-web", self.files["company/uten-remote-nginx.service"])
        self.assertNotIn("SupplementaryGroups=uten-web", self.files["cloud/uten-remote-nginx.service"])

    def test_runtime_logs_cannot_implicitly_capture_sensitive_request_queries(self):
        for role in ("cloud", "company"):
            config = self.files[role + "/nginx.conf"]
            self.assertIn("error_log /dev/null crit;", config)
            self.assertNotIn("$request_uri", config)
            self.assertNotIn("$request ", config)
            self.assertNotIn("$args", config)

    def test_atomic_firewall_replace_keeps_other_tables(self):
        text = self.files["company/firewall.nft"]
        combined = firewall.transaction(text, True)
        self.assertTrue(combined.startswith("delete table inet uten_remote\n"))
        self.assertNotIn("delete table inet filter", combined)
        with self.assertRaises(ValueError):
            firewall.transaction("flush ruleset\n" + text, True)


class ProbeTests(unittest.TestCase):
    def test_probe_does_not_follow_or_accept_credential_urls(self):
        for url in ("http://example.test", "https://user:secret@example.test", "https://example.test/api", "https://example.test?token=secret"):
            with self.assertRaises(ValueError):
                probe.target(url)
        self.assertEqual(probe.target("https://erp.example.test"), ("erp.example.test", 443))

    def test_probe_rejects_unbounded_sensitive_routes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "approved.json"
            for item in ("/api/a/export", "/api/a/download", "/api/attachments/raw/id", "/api/../secret", "/api/a?secret=x", "https://evil.test"):
                path.write_text(json.dumps([item]), encoding="utf-8")
                with self.assertRaises(ValueError):
                    probe.approved_paths(path)

    def test_report_keeps_errors_separate_from_success_latency(self):
        result = probe.summarize([{"status": 200, "bytes": 3, "error": "", "ms": 80},
                                  {"status": 429, "bytes": 9, "error": "http_error", "ms": 1}], 10)
        self.assertEqual(result["success_p95_ms"], 80)
        self.assertEqual(result["errors"], {"http_error": 1})
        self.assertEqual(result["statuses"], {"200": 1, "429": 1})

    def test_watchdog_bounds_staleness_without_echoing_keys(self):
        self.assertTrue(watchdog.healthy("publickey\t900\n", 1000))
        for raw in ("", "publickey\t0", "publickey\t700", "publickey\t2000", "publickey\tnan", "key\t900\nkey2\t901"):
            self.assertFalse(watchdog.healthy(raw, 1000))


if __name__ == "__main__":
    unittest.main()
