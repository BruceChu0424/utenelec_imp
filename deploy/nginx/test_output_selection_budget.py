"""Generated output routes retain the complete original API proxy contract."""
import importlib.util
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("output_budget", HERE / "sync_output_selection_budget.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OutputSelectionGatewayTest(unittest.TestCase):
    def test_generated_sections_match_all_live_budgeted_output_routes(self):
        routes = module.output_paths()
        self.assertIn("/api/report-export-jobs", routes)
        self.assertIn("/api/master/moulds/export", routes)
        self.assertIn("/api/master/goods/export", routes)
        for name in module.CONFIGS:
            text = (HERE / name).read_text(encoding="utf-8")
            self.assertEqual(text, module.render(text, routes), name)

    def test_every_proxy_directive_and_original_timeout_is_retained(self):
        for name in module.CONFIGS:
            text = (HERE / name).read_text(encoding="utf-8")
            block = text[text.index(module.BEGIN):text.index(module.END)]
            opening = block.index("    location = /api/report-export-jobs {") + len("    location = /api/report-export-jobs {")
            jobs = block[opening:block.index("\n    }", opening)]
            original = module.proxy_body(text, "    location /api/ {")
            self.assertEqual(original, jobs.replace("\n        client_max_body_size 16m;", ""), name)
            export_start = block.index('    location ~ "')
            opening = block.index(" {", export_start) + 2
            selected = block[opening:block.index("\n    }", opening)]
            self.assertEqual(module.proxy_body(text, "    location ~ ^/api/.*/export$ {"),
                             selected.replace("\n        client_max_body_size 16m;", ""), name)
            for directive in ("proxy_set_header Host $host;", "proxy_set_header X-Forwarded-For $remote_addr;",
                              "proxy_set_header X-Forwarded-Proto $scheme;", "proxy_set_header X-Request-Id $request_id;"):
                self.assertIn(directive, jobs, name)

    def test_scope_is_an_anchored_exact_output_allowlist_and_ordinary_limit_stays_two_mib(self):
        routes = module.output_paths()
        for name in module.CONFIGS:
            text = (HERE / name).read_text(encoding="utf-8")
            block = text[text.index(module.BEGIN):text.index(module.END)]
            pattern = re.search(r'location ~ "([^"]+)"', block).group(1)
            for route in routes:
                if route == "/api/report-export-jobs":
                    continue
                actual = re.sub(r"\{[^{}]+\}", "12345678-1234-1234-1234-123456789abc", route)
                self.assertIsNotNone(re.fullmatch(pattern, actual), (name, route))
            for rejected in ("/api/auth/login", "/api/master/goods", "/api/master/goods/create",
                             "/api/arbitrary/export", "/api/master/goods/export/extra"):
                self.assertIsNone(re.fullmatch(pattern, rejected), (name, rejected))
            self.assertIn("    client_max_body_size 2m;", text, name)
            self.assertNotIn("access_log", block, name)
            self.assertNotIn("add_header", block, name)


if __name__ == "__main__":
    unittest.main()
