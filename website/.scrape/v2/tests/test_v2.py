from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from legacy_site.fixture_site import (
    FixtureSite,
    _product_detail,
    _product_list,
    fixture_options,
    run_fixture_smoke,
)
from legacy_site.parsers import parse_product_detail, parse_product_list
from legacy_site.policy import PolicyError, SourcePolicy, canonical_url
from legacy_site.runner import LegacyCrawler
from legacy_site.store import normalized_absolute_path, path_is_within
from legacy_site.validation import validate_output


LEGACY_CACHE = Path(__file__).resolve().parents[2] / "pages"


class SourcePolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = SourcePolicy("http://www.ch-uten.com/")

    def test_canonicalization_handles_legacy_case_and_query_order(self) -> None:
        left = "http://www.ch-uten.com/Product.asp?SortID=8&Page=2#here"
        right = "http://www.ch-uten.com/product.asp?page=2&sortid=8"
        self.assertEqual(canonical_url(left), canonical_url(right))

    def test_policy_is_get_only_same_origin_and_refuses_save(self) -> None:
        with self.assertRaises(PolicyError):
            self.policy.assert_get("http://www.ch-uten.com/Save.asp")
        with self.assertRaises(PolicyError):
            self.policy.assert_get("http://www.ch-uten.com/Product.asp", "POST")
        with self.assertRaises(PolicyError):
            self.policy.assert_get("http://example.com/Product.asp")
        with self.assertRaises(PolicyError):
            self.policy.assert_asset("http://www.ch-uten.com/Inc/VerifyCode.asp")
        self.policy.assert_get("http://www.ch-uten.com/en/product.asp")

    @unittest.skipUnless(os.name == "nt", "Windows extended path regression")
    def test_windows_extended_path_prefix_is_normalized(self) -> None:
        with tempfile.TemporaryDirectory(prefix="uten-v2-path-") as directory:
            root = normalized_absolute_path(directory)
            child = root / "raw" / "html" / "detail.html"
            extended_child = Path("\\\\?\\" + str(child))
            self.assertEqual(child, normalized_absolute_path(extended_child))
            self.assertTrue(path_is_within(extended_child, root))


class ParserTest(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = SourcePolicy("http://www.ch-uten.com/")

    def test_same_name_products_are_not_deduplicated(self) -> None:
        parsed = parse_product_list(
            _product_list("zh"),
            "http://www.ch-uten.com/Product.asp",
            "zh",
            self.policy,
        )
        self.assertEqual(2, len(parsed["products"]))
        self.assertEqual({"1", "124"}, {item["oldSiteId"] for item in parsed["products"]})
        self.assertEqual({"GK11"}, {item["name"] for item in parsed["products"]})
        self.assertTrue(all(item["legacyHiddenValue"] == "114456-211" for item in parsed["products"]))

    def test_detail_preserves_raw_description_and_structured_hints(self) -> None:
        parsed = parse_product_detail(
            _product_detail("zh", "1"),
            "http://www.ch-uten.com/productshow.asp?ID=1&SortID=8&SortPath=0,1,8,",
            "zh",
            self.policy,
        )
        self.assertEqual("GK11", parsed["authoritativeName"])
        self.assertEqual(["GK11"], parsed["modelMentions"])
        self.assertIn("包装数量", parsed["packingText"] or "")
        self.assertIn("<p>", parsed["descriptionHtml"])
        self.assertEqual(
            "UNTRUSTED_LEGACY_HTML_DO_NOT_RENDER",
            parsed["descriptionHtmlSafety"],
        )
        self.assertEqual(
            [
                {"sortId": "1", "name": "V1.0"},
                {"sortId": "8", "name": "大跷板开关系列"},
            ],
            parsed["categoryBreadcrumb"],
        )

    def test_semantic_200_without_detail_structure_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "not a product detail"):
            parse_product_detail(
                "<html><title>UTEN</title><body>generic home page</body></html>",
                "http://www.ch-uten.com/productshow.asp?ID=1",
                "zh",
                self.policy,
            )

    @unittest.skipUnless((LEGACY_CACHE / "product.asp.html").exists(), "legacy cache not present")
    def test_real_cached_legacy_html(self) -> None:
        listing = parse_product_list(
            (LEGACY_CACHE / "product.asp.html").read_text(encoding="utf-8"),
            "http://www.ch-uten.com/Product.asp",
            "zh",
            self.policy,
        )
        self.assertEqual(12, len(listing["products"]))
        self.assertEqual(12, len({item["oldSiteId"] for item in listing["products"]}))

        duplicate_name_files = [
            "productshow.asp__ID_1_SortID_8_Sequence_101_SortPath_0_1_8_.html",
            "productshow.asp__ID_124_SortID_23_Sequence_201_SortPath_0_2_23_.html",
            "productshow.asp__ID_783_SortID_71_Sequence_86_SortPath_0_70_71_.html",
        ]
        names = []
        for filename in duplicate_name_files:
            parsed = parse_product_detail(
                (LEGACY_CACHE / filename).read_text(encoding="utf-8"),
                "http://www.ch-uten.com/productshow.asp?ID=1",
                "zh",
                self.policy,
            )
            names.append(parsed["authoritativeName"])
        self.assertEqual(["GK11", "GK11", "GK11"], names)

        empty = parse_product_detail(
            (
                LEGACY_CACHE
                / "productshow.asp__ID_1038_SortID_80_Sequence_9_SortPath_0_80_.html"
            ).read_text(encoding="utf-8"),
            "http://www.ch-uten.com/productshow.asp?ID=1038",
            "zh",
            self.policy,
        )
        self.assertEqual("", empty["descriptionText"])


class SmokeTest(unittest.TestCase):
    def test_redirected_detail_id_is_rejected_and_persisted(self) -> None:
        with tempfile.TemporaryDirectory(prefix="uten-v2-redirect-") as directory:
            root = Path(directory)
            with FixtureSite(redirect_detail_ids={"124": "1"}) as site:
                catalog, _media, qa = LegacyCrawler(
                    fixture_options(root, site.base_url)
                ).run()
            redirected = next(
                item
                for item in catalog["products"]
                if item["locale"] == "zh" and item["oldSiteId"] == "124"
            )
            self.assertEqual("parse-error", redirected["detailStatus"])
            self.assertTrue(qa["parseErrors"])
            standalone = validate_output(root, expect_full=False)
            self.assertTrue(standalone["parseErrors"])
            self.assertEqual("warn", standalone["status"])

    def test_fixture_pipeline_and_resume(self) -> None:
        with tempfile.TemporaryDirectory(prefix="uten-v2-test-") as directory:
            first = run_fixture_smoke(Path(directory), keep_output=True)
            self.assertEqual("pass", first["status"], first)
            # The standalone smoke validates HTTP, parsers, output manifests, hashes,
            # duplicate-name identity, GET-only policy and content-hash dedupe.
            self.assertTrue(all(first["assertions"].values()), first)
            full = validate_output(Path(directory), expect_full=True)
            self.assertEqual("fail", full["status"])
            self.assertEqual(-1119, full["baselineDeltas"]["products"]["zh"])
            self.assertEqual(-1035, full["baselineDeltas"]["products"]["en"])
            self.assertEqual(-2135, full["baselineDeltas"]["zhProductAssetUrls"]["zh"])

            catalog_path = Path(directory) / "catalog.json"
            original_catalog = catalog_path.read_text(encoding="utf-8")
            catalog = json.loads(original_catalog)
            catalog["products"][0]["thumbnailSha256"] = None
            catalog_path.write_text(json.dumps(catalog, ensure_ascii=False), encoding="utf-8")
            image_report = validate_output(Path(directory), expect_full=False)
            image_check = next(
                check
                for check in image_report["checks"]
                if check["id"] == "per-product-image-completeness"
            )
            self.assertEqual("fail", image_check["status"])
            catalog_path.write_text(original_catalog, encoding="utf-8")

            checkpoint_path = Path(directory) / "checkpoint.json"
            checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
            checkpoint["diagnostics"]["parseErrors"] = [
                {"kind": "fixture", "sourceUrl": "fixture", "error": "preserved"}
            ]
            checkpoint_path.write_text(
                json.dumps(checkpoint, ensure_ascii=False), encoding="utf-8"
            )
            diagnostic_report = validate_output(Path(directory), expect_full=False)
            self.assertEqual(1, len(diagnostic_report["parseErrors"]))
            self.assertEqual("warn", diagnostic_report["status"])

            page_record = next(
                record
                for record in checkpoint["pages"].values()
                if record.get("status") == "ok" and record.get("kind") == "product-list"
            )
            (Path(directory) / page_record["rawHtmlPath"]).write_bytes(b"corrupt")
            integrity_report = validate_output(Path(directory), expect_full=False)
            self.assertEqual("fail", integrity_report["status"])
            self.assertTrue(integrity_report["integrityErrors"])

    def test_corrupt_cache_is_refetched_and_checkpoint_version_is_enforced(self) -> None:
        with tempfile.TemporaryDirectory(prefix="uten-v2-recovery-") as directory:
            root = Path(directory)
            with FixtureSite() as site:
                options = fixture_options(root, site.base_url)
                LegacyCrawler(options).run()
                first_request_count = len(site.requests)
                checkpoint_path = root / "checkpoint.json"
                checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
                page_record = next(
                    record
                    for record in checkpoint["pages"].values()
                    if record.get("kind") == "product-list" and record.get("status") == "ok"
                )
                damaged_path = root / page_record["rawHtmlPath"]
                damaged_path.write_bytes(b"damaged")
                LegacyCrawler(options).run()
                self.assertEqual(first_request_count + 1, len(site.requests))
                self.assertEqual("pass", validate_output(root, expect_full=False)["status"])

                checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
                checkpoint["checkpointVersion"] = 999
                checkpoint_path.write_text(
                    json.dumps(checkpoint, ensure_ascii=False), encoding="utf-8"
                )
                with self.assertRaisesRegex(RuntimeError, "checkpointVersion"):
                    LegacyCrawler(options)


if __name__ == "__main__":
    unittest.main()
