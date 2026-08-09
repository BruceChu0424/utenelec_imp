from __future__ import annotations

import hashlib
import json
from collections import Counter
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

from .config import BASELINE, CHECKPOINT_VERSION, SCHEMA_VERSION
from .policy import PolicyError, SourcePolicy
from .store import normalized_absolute_path, path_is_within, sha256_bytes, utc_now


def _locale_counts(items: list[dict]) -> dict[str, int]:
    counter = Counter(item.get("locale") for item in items)
    return {locale: counter.get(locale, 0) for locale in ("zh", "en")}


def _duplicate_keys(items: list[dict], fields: tuple[str, ...]) -> list[str]:
    keys = [":".join(str(item.get(field, "")) for field in fields) for item in items]
    counts = Counter(keys)
    return sorted(key for key, count in counts.items() if count > 1)


def _replacement_count(value: object) -> int:
    if isinstance(value, str):
        return value.count("\ufffd")
    if isinstance(value, list):
        return sum(_replacement_count(item) for item in value)
    if isinstance(value, dict):
        return sum(_replacement_count(item) for item in value.values())
    return 0


def _sorted_products(products: list[dict], locale: str) -> list[dict]:
    return sorted(
        (item for item in products if item.get("locale") == locale),
        key=lambda item: (
            int(item["oldSiteId"]) if str(item.get("oldSiteId", "")).isdigit() else 2**31 - 1,
            str(item.get("oldSiteId", "")),
        ),
    )


def _identity_sort_path_fingerprint(products: list[dict], locale: str) -> str:
    lines = [
        f"{item.get('oldSiteId', '')}\t{item.get('sortId', '')}\t{item.get('sortPath', '')}"
        for item in _sorted_products(products, locale)
    ]
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _product_image_fingerprint(products: list[dict], locale: str) -> str:
    lines = [
        f"{item.get('oldSiteId', '')}\t{item.get('thumbnailSourceUrl') or ''}\t"
        f"{item.get('mainImageSourceUrl') or ''}"
        for item in _sorted_products(products, locale)
    ]
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _sample(values: list[str], limit: int = 50) -> dict:
    return {"count": len(values), "sample": values[:limit]}


def _url_id(url: str | None) -> str | None:
    if not url:
        return None
    values = {key.lower(): value for key, value in parse_qsl(urlsplit(url).query)}
    return values.get("id")


def _source_missing(items: list[dict]) -> list[str]:
    required = ("sourceUrl", "scrapedAt", "sourceHash", "rawHtmlPath")
    missing = []
    for item in items:
        if any(not item.get(field) for field in required):
            missing.append(item.get("identityKey") or item.get("key") or "unknown")
    return missing


def _check(
    checks: list[dict],
    check_id: str,
    ok: bool,
    message: str,
    *,
    severity: str = "error",
    expected: object | None = None,
    actual: object | None = None,
) -> None:
    checks.append(
        {
            "id": check_id,
            "status": "pass" if ok else "fail",
            "severity": severity,
            "message": message,
            "expected": expected,
            "actual": actual,
        }
    )


def build_qa_report(
    catalog: dict,
    media: dict,
    *,
    checkpoint: dict,
    expect_full: bool,
    fetch_errors: list[dict] | None = None,
    parse_errors: list[dict] | None = None,
    conflicts: list[dict] | None = None,
) -> dict:
    products = catalog.get("products", [])
    categories = catalog.get("categories", [])
    articles = catalog.get("news", [])
    pages = catalog.get("pages", [])
    checks: list[dict] = []
    product_counts = _locale_counts(products)
    detail_counts = {
        locale: sum(
            1
            for product in products
            if product.get("locale") == locale and product.get("detailStatus") == "ok"
        )
        for locale in ("zh", "en")
    }
    non_empty = {
        locale: sum(
            1
            for product in products
            if product.get("locale") == locale and product.get("descriptionText", "").strip()
        )
        for locale in ("zh", "en")
    }
    empty = {
        locale: detail_counts[locale] - non_empty[locale]
        for locale in ("zh", "en")
    }
    leaf_counts = {
        locale: len(
            {
                product.get("sortId")
                for product in products
                if product.get("locale") == locale and product.get("sortId")
            }
        )
        for locale in ("zh", "en")
    }
    news_counts = _locale_counts(articles)
    static_counts = _locale_counts(pages)
    news_asset_counts = {
        locale: len(
            {
                url
                for article in articles
                if article.get("locale") == locale
                for url in article.get("assetUrls", [])
                if url
            }
        )
        for locale in ("zh", "en")
    }

    duplicate_products = _duplicate_keys(products, ("locale", "oldSiteId"))
    duplicate_categories = _duplicate_keys(categories, ("locale", "sortId"))
    duplicate_news = _duplicate_keys(articles, ("locale", "oldSiteId"))
    _check(
        checks,
        "unique-product-identity",
        not duplicate_products,
        "Products are unique by (locale, oldSiteId); names are never identity keys.",
        actual=duplicate_products,
    )
    _check(
        checks,
        "unique-category-identity",
        not duplicate_categories,
        "Categories are unique by (locale, sortId).",
        actual=duplicate_categories,
    )
    _check(
        checks,
        "unique-news-identity",
        not duplicate_news,
        "News is unique by (locale, oldSiteId).",
        actual=duplicate_news,
    )

    missing_sources = {
        "products": _source_missing(products),
        "categories": _source_missing(categories),
        "news": _source_missing(articles),
        "pages": _source_missing(pages),
    }
    total_missing_sources = sum(len(items) for items in missing_sources.values())
    _check(
        checks,
        "source-provenance",
        total_missing_sources == 0,
        "Every catalog record preserves sourceUrl, scrapedAt, sourceHash and rawHtmlPath.",
        actual=missing_sources,
    )

    identity_fingerprints = {
        locale: _identity_sort_path_fingerprint(products, locale)
        for locale in ("zh", "en")
    }
    image_fingerprints = {
        locale: _product_image_fingerprint(products, locale)
        for locale in ("zh", "en")
    }
    zh_ids = {
        str(product.get("oldSiteId"))
        for product in products
        if product.get("locale") == "zh"
    }
    en_ids = {
        str(product.get("oldSiteId"))
        for product in products
        if product.get("locale") == "en"
    }
    id_relationships = {
        "intersection": len(zh_ids & en_ids),
        "zhOnly": len(zh_ids - en_ids),
        "enOnly": len(en_ids - zh_ids),
    }
    expected_relationships = {
        "intersection": BASELINE["productIdIntersection"],
        "zhOnly": BASELINE["zhOnlyProductIds"],
        "enOnly": BASELINE["enOnlyProductIds"],
    }
    _check(
        checks,
        "exact-product-id-relationship",
        id_relationships == expected_relationships if expect_full else True,
        "Chinese/English product ID intersection and language-only sets match the frozen crawl.",
        expected=expected_relationships,
        actual=id_relationships,
        severity="error" if expect_full else "info",
    )
    for locale in ("zh", "en"):
        _check(
            checks,
            f"exact-product-identity-sortpath-{locale}",
            identity_fingerprints[locale] == BASELINE["identitySortPathSha256"][locale]
            if expect_full
            else True,
            "Exact oldSiteId, SortID and SortPath set matches the frozen crawl signature.",
            expected=BASELINE["identitySortPathSha256"][locale],
            actual=identity_fingerprints[locale],
            severity="error" if expect_full else "info",
        )
        _check(
            checks,
            f"exact-product-images-{locale}",
            image_fingerprints[locale] == BASELINE["productImagesSha256"][locale]
            if expect_full
            else True,
            "Each product ID retains its exact thumbnail and main-image source URLs.",
            expected=BASELINE["productImagesSha256"][locale],
            actual=image_fingerprints[locale],
            severity="error" if expect_full else "info",
        )

    bad_detail_identity = []
    detail_hashes: Counter[tuple[str, str]] = Counter()
    for product in products:
        expected_id = str(product.get("oldSiteId"))
        requested_id = _url_id(product.get("sourceUrl"))
        final_id = _url_id(product.get("finalUrl"))
        if product.get("detailStatus") == "ok" and (
            requested_id != expected_id or final_id != expected_id
        ):
            bad_detail_identity.append(product.get("identityKey", "unknown"))
        if product.get("detailStatus") == "ok" and product.get("sourceHash"):
            detail_hashes[(product.get("locale", ""), product["sourceHash"])] += 1
    duplicate_detail_hashes = [
        f"{locale}:{digest}:{count}"
        for (locale, digest), count in detail_hashes.items()
        if count > 1
    ]
    _check(
        checks,
        "detail-url-identity",
        not bad_detail_identity,
        "Requested/final detail URL IDs agree with each product oldSiteId.",
        actual=_sample(bad_detail_identity),
    )
    _check(
        checks,
        "unique-detail-source-pages",
        not duplicate_detail_hashes,
        "Different product IDs did not receive an identical detail HTML response.",
        actual=_sample(duplicate_detail_hashes),
        severity="error" if expect_full else "warning",
    )

    unsafe_html = [
        product.get("identityKey", "unknown")
        for product in products
        if product.get("descriptionHtml") is not None
        and product.get("descriptionHtmlSafety") != "UNTRUSTED_LEGACY_HTML_DO_NOT_RENDER"
    ] + [
        article.get("identityKey", "unknown")
        for article in articles
        if article.get("bodyHtml") is not None
        and article.get("bodyHtmlSafety") != "UNTRUSTED_LEGACY_HTML_DO_NOT_RENDER"
    ]
    _check(
        checks,
        "legacy-html-safety-label",
        not unsafe_html,
        "Raw legacy HTML is explicitly marked untrusted and must not be rendered directly.",
        actual=_sample(unsafe_html),
    )

    media_by_hash = {asset.get("sha256"): asset for asset in media.get("assets", [])}
    missing_thumbnail_urls: list[str] = []
    missing_main_urls: list[str] = []
    missing_thumbnail_hashes: list[str] = []
    missing_main_hashes: list[str] = []
    invalid_image_dimensions: list[str] = []
    for product in products:
        identity = product.get("identityKey", "unknown")
        if not product.get("thumbnailSourceUrl"):
            missing_thumbnail_urls.append(identity)
        if product.get("detailStatus") == "ok" and not product.get("mainImageSourceUrl"):
            missing_main_urls.append(identity)
        fields = [("thumbnailSha256", missing_thumbnail_hashes)]
        if product.get("detailStatus") == "ok":
            fields.append(("mainImageSha256", missing_main_hashes))
        for field, missing in fields:
            digest = product.get(field)
            if not digest:
                missing.append(identity)
                continue
            asset = media_by_hash.get(digest)
            if not asset:
                missing.append(identity)
                continue
            if not asset.get("width") or not asset.get("height"):
                invalid_image_dimensions.append(f"{identity}:{field}")
    image_issues = {
        "missingThumbnailUrls": _sample(missing_thumbnail_urls),
        "missingMainUrls": _sample(missing_main_urls),
        "missingThumbnailHashes": _sample(missing_thumbnail_hashes),
        "missingMainHashes": _sample(missing_main_hashes),
        "invalidDimensions": _sample(invalid_image_dimensions),
    }
    has_image_issues = any(value["count"] for value in image_issues.values())
    _check(
        checks,
        "per-product-image-completeness",
        not has_image_issues,
        "Every product has thumbnail/main URLs, successful media hashes and decoded dimensions.",
        actual=image_issues,
        severity="error" if expect_full else "warning",
    )

    invalid_prices = [
        product["identityKey"]
        for product in products
        if product.get("price", {}).get("status") != "UNSET"
        or product.get("price", {}).get("amount") is not None
        or product.get("price", {}).get("publicationApproved") is not False
    ]
    _check(
        checks,
        "prices-remain-unset",
        not invalid_prices,
        "The crawler never invents or publishes prices.",
        actual=invalid_prices,
    )

    replacement_count = _replacement_count(catalog)
    _check(
        checks,
        "no-replacement-characters",
        replacement_count == 0,
        "Decoded catalog text contains no U+FFFD replacement characters.",
        expected=0,
        actual=replacement_count,
        severity="warning" if not expect_full else "error",
    )

    unnamed_inferred = [
        category["identityKey"]
        for category in categories
        if category.get("inferred") and not category.get("name")
    ]
    _check(
        checks,
        "inferred-category-names",
        not unnamed_inferred,
        "Every inferred category has an editorial name.",
        actual=unnamed_inferred,
        severity="warning",
    )

    page_errors = [
        record
        for record in checkpoint.get("pages", {}).values()
        if record.get("status") == "error"
    ]
    media_errors = media.get("failures", [])
    all_fetch_errors = fetch_errors or []
    all_parse_errors = parse_errors or []
    all_conflicts = conflicts or []
    error_severity = "error" if expect_full else "warning"
    _check(
        checks,
        "no-page-fetch-errors",
        not page_errors and not all_fetch_errors,
        "No page request exhausted retries or returned a permanent error.",
        actual=len(page_errors) + len(all_fetch_errors),
        severity=error_severity,
    )
    _check(
        checks,
        "no-parse-errors",
        not all_parse_errors,
        "All fetched pages parsed successfully.",
        actual=len(all_parse_errors),
        severity=error_severity,
    )
    _check(
        checks,
        "no-media-errors",
        not media_errors,
        "Every referenced asset was downloaded and content-validated.",
        actual=len(media_errors),
        severity=error_severity,
    )
    _check(
        checks,
        "no-source-conflicts",
        not all_conflicts,
        "Repeated listing appearances agree on stable source fields.",
        actual=len(all_conflicts),
        severity="warning",
    )
    refused = checkpoint.get("refusedUrls", [])
    _check(
        checks,
        "no-forbidden-request-attempts",
        not refused,
        "No form-save or cross-origin URL entered the request queue.",
        actual=refused,
    )

    product_asset_urls = {
        locale: {
            url
            for product in products
            if product.get("locale") == locale
            for url in (
                [product.get("thumbnailSourceUrl"), product.get("mainImageSourceUrl")]
                + list(product.get("assetUrls", []))
            )
            if url
        }
        for locale in ("zh", "en")
    }
    progress = catalog.get("scope", {}).get("progress", {})
    deltas: dict[str, dict[str, int]] = {}
    for metric, actuals, expected in (
        ("products", product_counts, BASELINE["products"]),
        ("productDetails", detail_counts, BASELINE["productDetails"]),
        ("productLeafSortIds", leaf_counts, BASELINE["productLeafSortIds"]),
        ("nonEmptyDescriptions", non_empty, BASELINE["nonEmptyDescriptions"]),
        ("emptyDescriptions", empty, BASELINE["emptyDescriptions"]),
        ("news", news_counts, BASELINE["news"]),
        ("staticPages", static_counts, BASELINE["staticPages"]),
        ("newsAssetUrls", news_asset_counts, BASELINE["newsAssetUrls"]),
    ):
        deltas[metric] = {
            locale: actuals[locale] - expected[locale] for locale in ("zh", "en")
        }
        for locale in ("zh", "en"):
            _check(
                checks,
                f"baseline-{metric}-{locale}",
                actuals[locale] == expected[locale] if expect_full else True,
                f"{metric} count for {locale} compared with the frozen 2026-08-09 baseline.",
                expected=expected[locale],
                actual=actuals[locale],
                severity="error" if expect_full else "info",
            )

    for locale in ("zh", "en"):
        completed = progress.get(locale, {}).get("productCompleted", 0)
        expected_pages = BASELINE["productListPages"][locale]
        _check(
            checks,
            f"baseline-product-list-pages-{locale}",
            completed == expected_pages if expect_full else True,
            f"Product listing pages completed for {locale}.",
            expected=expected_pages,
            actual=completed,
            severity="error" if expect_full else "info",
        )
    for locale, expected_assets in (
        ("zh", BASELINE["zhProductAssetUrls"]),
        ("en", BASELINE["enProductAssetUrls"]),
    ):
        actual_assets = len(product_asset_urls[locale])
        deltas[f"{locale}ProductAssetUrls"] = {locale: actual_assets - expected_assets}
        _check(
            checks,
            f"baseline-product-assets-{locale}",
            actual_assets == expected_assets if expect_full else True,
            f"Unique product asset source URLs for {locale}.",
            expected=expected_assets,
            actual=actual_assets,
            severity="error" if expect_full else "info",
        )

    failed_errors = [
        check for check in checks if check["status"] == "fail" and check["severity"] == "error"
    ]
    failed_warnings = [
        check for check in checks if check["status"] == "fail" and check["severity"] == "warning"
    ]
    status = "fail" if failed_errors else ("warn" if failed_warnings else "pass")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": utc_now(),
        "status": status,
        "expectFull": expect_full,
        "summary": {
            "products": product_counts,
            "productDetails": detail_counts,
            "categories": _locale_counts(categories),
            "productLeafSortIds": leaf_counts,
            "nonEmptyDescriptions": non_empty,
            "emptyDescriptions": empty,
            "news": news_counts,
            "staticPages": static_counts,
            "newsAssetUrls": news_asset_counts,
            "identitySortPathSha256": identity_fingerprints,
            "productImagesSha256": image_fingerprints,
            "productIdRelationships": id_relationships,
            "mediaAssetsByHash": len(media.get("assets", [])),
            "mediaFailures": len(media_errors),
            "uniqueProductAssetUrls": {
                locale: len(urls) for locale, urls in product_asset_urls.items()
            },
        },
        "baselineDeltas": deltas,
        "checks": checks,
        "fetchErrors": all_fetch_errors,
        "parseErrors": all_parse_errors,
        "conflicts": all_conflicts,
    }


def validate_output(output_dir: Path, *, expect_full: bool | None = None) -> dict:
    root = normalized_absolute_path(output_dir)
    catalog_path = root / "catalog.json"
    media_path = root / "media.json"
    checkpoint_path = root / "checkpoint.json"
    for path in (catalog_path, media_path, checkpoint_path):
        if not path.exists():
            raise FileNotFoundError(f"Missing required output: {path}")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    media = json.loads(media_path.read_text(encoding="utf-8"))
    checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
    if catalog.get("schemaVersion") != SCHEMA_VERSION or media.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError("Unsupported output schema version")
    if checkpoint.get("checkpointVersion") != CHECKPOINT_VERSION:
        raise ValueError(
            f"Unsupported checkpointVersion {checkpoint.get('checkpointVersion')!r}; "
            f"expected {CHECKPOINT_VERSION}"
        )
    if expect_full is None:
        expect_full = bool(catalog.get("scope", {}).get("fullRequested"))

    integrity_errors: list[dict] = []
    verified_paths: dict[Path, str] = {}

    def verify_relative(relative: str, expected_hash: str, kind: str, identity: str) -> None:
        path = normalized_absolute_path(root / relative)
        if not path_is_within(path, root):
            integrity_errors.append(
                {"kind": kind, "identity": identity, "error": f"path escaped output root: {relative}"}
            )
            return
        try:
            if not path.exists():
                integrity_errors.append(
                    {"kind": kind, "identity": identity, "error": f"missing file: {relative}"}
                )
                return
            actual_hash = verified_paths.get(path)
            if actual_hash is None:
                actual_hash = sha256_bytes(path.read_bytes())
                verified_paths[path] = actual_hash
        except (OSError, ValueError, TypeError) as exc:
            integrity_errors.append(
                {"kind": kind, "identity": identity, "error": f"cannot read {relative}: {exc}"}
            )
            return
        if actual_hash != expected_hash:
            integrity_errors.append(
                {
                    "kind": kind,
                    "identity": identity,
                    "error": "sha256 mismatch",
                    "expected": expected_hash,
                    "actual": actual_hash,
                }
            )

    for canonical, record in checkpoint.get("pages", {}).items():
        if record.get("status") == "ok":
            verify_relative(
                record.get("rawHtmlPath", ""),
                record.get("sourceHash", ""),
                "checkpoint-raw-html",
                canonical,
            )
    for canonical, record in checkpoint.get("media", {}).items():
        if record.get("status") == "ok":
            verify_relative(
                record.get("localPath", ""),
                record.get("sha256", ""),
                "checkpoint-media",
                canonical,
            )
    for collection_name in ("products", "categories", "news", "pages"):
        for item in catalog.get(collection_name, []):
            identity = item.get("identityKey") or item.get("key") or "unknown"
            if item.get("rawHtmlPath") and item.get("sourceHash"):
                verify_relative(item["rawHtmlPath"], item["sourceHash"], "catalog-raw-html", identity)
    for asset in media.get("assets", []):
        verify_relative(asset["localPath"], asset["sha256"], "manifest-media", asset["sha256"])

    base_parts = urlsplit(catalog["sourceBaseUrl"])
    test_origin = base_parts.hostname in {"127.0.0.1", "localhost", "::1"}
    policy = SourcePolicy(catalog["sourceBaseUrl"], allow_test_origin=test_origin)
    unsafe_urls: list[str] = []
    for record in checkpoint.get("pages", {}).values():
        url = record.get("sourceUrl")
        if url:
            try:
                policy.assert_get(url)
            except PolicyError:
                unsafe_urls.append(url)
    for record in checkpoint.get("media", {}).values():
        url = record.get("sourceUrl")
        if url:
            try:
                policy.assert_asset(url)
            except PolicyError:
                unsafe_urls.append(url)

    diagnostics = checkpoint.get("diagnostics", {})
    report = build_qa_report(
        catalog,
        media,
        checkpoint=checkpoint,
        expect_full=expect_full,
        fetch_errors=diagnostics.get("fetchErrors", []),
        parse_errors=diagnostics.get("parseErrors", []),
        conflicts=diagnostics.get("conflicts", []),
    )
    report["integrityErrors"] = integrity_errors
    report["unsafeUrls"] = sorted(set(unsafe_urls))
    if integrity_errors or unsafe_urls:
        report["status"] = "fail"
        report["checks"].append(
            {
                "id": "on-disk-integrity",
                "status": "fail",
                "severity": "error",
                "message": "Raw HTML/media hashes and URL policy were revalidated from disk.",
                "expected": {"integrityErrors": 0, "unsafeUrls": 0},
                "actual": {
                    "integrityErrors": len(integrity_errors),
                    "unsafeUrls": len(unsafe_urls),
                },
            }
        )
    else:
        report["checks"].append(
            {
                "id": "on-disk-integrity",
                "status": "pass",
                "severity": "error",
                "message": "Raw HTML/media hashes and URL policy were revalidated from disk.",
                "expected": {"integrityErrors": 0, "unsafeUrls": 0},
                "actual": {"integrityErrors": 0, "unsafeUrls": 0},
            }
        )
    return report
