from __future__ import annotations

import copy
import threading
from collections import defaultdict
from concurrent.futures import Future, ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

from .config import (
    BASELINE,
    DEFAULT_BASE_URL,
    HIDDEN_CATEGORY_NAMES,
    NEWS_LIST_PAGE_COUNTS,
    PRODUCT_LIST_PAGE_COUNTS,
    SCHEMA_VERSION,
    STATIC_PATHS,
    RetrySettings,
)
from .parsers import (
    parse_news_detail,
    parse_news_list,
    parse_product_detail,
    parse_product_list,
    parse_static_page,
    path_ids,
    query_ci,
)
from .policy import PolicyError, SourcePolicy, canonical_url, without_fragment
from .store import CheckpointStore, atomic_write_json, source_metadata, utc_now
from .transport import FetchError, HttpClient


@dataclass(frozen=True)
class CrawlOptions:
    output_dir: Path
    base_url: str = DEFAULT_BASE_URL
    locales: tuple[str, ...] = ("zh", "en")
    concurrency: int = 3
    retry_settings: RetrySettings = field(default_factory=RetrySettings)
    resume: bool = True
    download_media: bool = True
    max_product_list_pages: int | None = None
    max_details_per_locale: int | None = None
    max_news_list_pages: int | None = None
    max_static_pages_per_locale: int | None = None
    allow_test_origin: bool = False
    product_page_counts: dict[str, int] = field(
        default_factory=lambda: dict(PRODUCT_LIST_PAGE_COUNTS)
    )
    news_page_counts: dict[str, int] = field(default_factory=lambda: dict(NEWS_LIST_PAGE_COUNTS))
    static_paths: dict[str, list[str]] = field(
        default_factory=lambda: copy.deepcopy(STATIC_PATHS)
    )

    def __post_init__(self) -> None:
        if self.concurrency < 2 or self.concurrency > 4:
            raise ValueError("concurrency must be between 2 and 4")
        if not self.locales or any(locale not in {"zh", "en"} for locale in self.locales):
            raise ValueError("locales must contain zh and/or en")
        for name in (
            "max_product_list_pages",
            "max_details_per_locale",
            "max_news_list_pages",
            "max_static_pages_per_locale",
        ):
            value = getattr(self, name)
            if value is not None and value < 1:
                raise ValueError(f"{name} must be positive")

    @property
    def full_requested(self) -> bool:
        return (
            self.base_url == DEFAULT_BASE_URL
            and set(self.locales) == {"zh", "en"}
            and self.max_product_list_pages is None
            and self.max_details_per_locale is None
            and self.max_news_list_pages is None
            and self.max_static_pages_per_locale is None
            and self.download_media
            and self.product_page_counts == PRODUCT_LIST_PAGE_COUNTS
            and self.news_page_counts == NEWS_LIST_PAGE_COUNTS
        )


@dataclass(frozen=True)
class PageTask:
    url: str
    kind: str
    locale: str
    ordinal: int = 0


@dataclass(frozen=True)
class LoadedPage:
    task: PageTask
    record: dict
    text: str


def _numeric(value: str | None) -> tuple[int, str]:
    if value and value.isdigit():
        return int(value), value
    return 2**31 - 1, value or ""


def _apply_source(target: dict, metadata: dict | None) -> None:
    if not metadata:
        return
    target.update(
        {
            "sourceUrl": metadata["sourceUrl"],
            "finalUrl": metadata.get("finalUrl", metadata["sourceUrl"]),
            "scrapedAt": metadata["scrapedAt"],
            "sourceHash": metadata["sourceHash"],
            "rawHtmlPath": metadata["rawHtmlPath"],
            "httpStatus": metadata.get("httpStatus", 200),
        }
    )


class LegacyCrawler:
    def __init__(self, options: CrawlOptions) -> None:
        self.options = options
        self.policy = SourcePolicy(options.base_url, options.allow_test_origin)
        self.store = CheckpointStore(options.output_dir, options.base_url, resume=options.resume)
        self.client = HttpClient(self.policy, options.retry_settings)
        self._error_lock = threading.Lock()
        self._progress_lock = threading.Lock()
        self._progress_counts = {"page": 0, "media": 0}
        self.fetch_errors: list[dict] = []
        self.parse_errors: list[dict] = []
        self.conflicts: list[dict] = []
        self.asset_urls: dict[str, str] = {}
        self.asset_refs: dict[str, set[str]] = defaultdict(set)
        self.page_progress: dict[str, dict[str, int]] = {
            locale: {
                "productRequested": 0,
                "productCompleted": 0,
                "newsRequested": 0,
                "newsCompleted": 0,
                "staticRequested": 0,
                "staticCompleted": 0,
                "detailRequested": 0,
                "detailCompleted": 0,
            }
            for locale in options.locales
        }

    def run(self) -> tuple[dict, dict, dict]:
        generated_at = utc_now()
        products: dict[str, dict] = {}
        categories: dict[str, dict] = {}
        news: dict[str, dict] = {}
        pages: list[dict] = []
        try:
            print("[v2] Enumerating product listing pages...", flush=True)
            self._crawl_product_lists(products, categories)
            self._synthesize_product_categories(products, categories)
            print(f"[v2] Fetching {len(products)} product detail pages...", flush=True)
            self._crawl_product_details(products, categories)
            print("[v2] Fetching news lists and details...", flush=True)
            self._crawl_news(news)
            print("[v2] Fetching configured static pages...", flush=True)
            self._crawl_static_pages(pages)
            if self.options.download_media:
                print(f"[v2] Fetching {len(self.asset_urls)} unique asset URLs...", flush=True)
                self._download_media()
            self._resolve_media(products, news, pages)

            product_list = sorted(
                products.values(),
                key=lambda item: (item["locale"], _numeric(item.get("oldSiteId"))),
            )
            category_list = sorted(
                categories.values(),
                key=lambda item: (item["locale"], _numeric(item.get("sortId"))),
            )
            news_list = sorted(
                news.values(),
                key=lambda item: (item["locale"], _numeric(item.get("oldSiteId"))),
            )
            pages.sort(key=lambda item: (item["locale"], item["key"]))
            for collection in (product_list, category_list, news_list, pages):
                for item in collection:
                    for key in list(item):
                        if key.startswith("_"):
                            item.pop(key, None)

            catalog = {
                "schemaVersion": SCHEMA_VERSION,
                "generatedAt": generated_at,
                "sourceBaseUrl": self.options.base_url,
                "baseline": BASELINE,
                "scope": {
                    "locales": list(self.options.locales),
                    "fullRequested": self.options.full_requested,
                    "downloadMedia": self.options.download_media,
                    "concurrency": self.options.concurrency,
                    "progress": self.page_progress,
                },
                "categories": category_list,
                "products": product_list,
                "news": news_list,
                "pages": pages,
            }
            media = self._build_media_manifest(generated_at)

            self.store.set_diagnostics(
                fetch_errors=self.fetch_errors,
                parse_errors=self.parse_errors,
                conflicts=self.conflicts,
            )

            from .validation import build_qa_report

            qa = build_qa_report(
                catalog,
                media,
                checkpoint=self.store.data,
                expect_full=self.options.full_requested,
                fetch_errors=self.fetch_errors,
                parse_errors=self.parse_errors,
                conflicts=self.conflicts,
            )
            atomic_write_json(self.store.root / "catalog.json", catalog)
            atomic_write_json(self.store.root / "media.json", media)
            atomic_write_json(self.store.root / "qa-report.json", qa)
            print(f"[v2] Output complete with QA status={qa['status']}", flush=True)
            return catalog, media, qa
        finally:
            self.store.flush()

    def _product_list_url(self, locale: str, page: int) -> str:
        prefix = "en/product.asp" if locale == "en" else "Product.asp"
        path = prefix if page == 1 else f"{prefix}?Page={page}#here"
        return without_fragment(urljoin(self.options.base_url, path))

    def _news_list_url(self, locale: str, page: int) -> str:
        prefix = "en/news.asp" if locale == "en" else "news.asp"
        path = prefix if page == 1 else f"{prefix}?Page={page}#here"
        return without_fragment(urljoin(self.options.base_url, path))

    def _crawl_product_lists(self, products: dict[str, dict], categories: dict[str, dict]) -> None:
        tasks: list[PageTask] = []
        for locale in self.options.locales:
            count = self.options.product_page_counts[locale]
            if self.options.max_product_list_pages is not None:
                count = min(count, self.options.max_product_list_pages)
            self.page_progress[locale]["productRequested"] = count
            tasks.extend(
                PageTask(self._product_list_url(locale, page), "product-list", locale, page)
                for page in range(1, count + 1)
            )
        for loaded in self._load_many(tasks):
            self.page_progress[loaded.task.locale]["productCompleted"] += 1
            try:
                parsed = parse_product_list(
                    loaded.text,
                    loaded.task.url,
                    loaded.task.locale,
                    self.policy,
                )
            except Exception as exc:  # parser errors must not destroy the checkpoint
                self._record_parse_error(loaded.task, exc)
                continue
            metadata = source_metadata(loaded.record)
            for asset_url in parsed.get("assetUrls", []):
                self._add_asset(
                    asset_url,
                    f"product-list:{loaded.task.locale}:{loaded.task.ordinal}",
                )
            for entry in parsed["products"]:
                entry["_listingOrder"] = (loaded.task.ordinal, int(entry.get("sequence") or 0))
                entry["listingName"] = entry.get("name")
                entry["listingSource"] = metadata
                entry["listingSources"] = [metadata] if metadata else []
                entry["detailStatus"] = "pending"
                entry["price"] = {
                    "status": "UNSET",
                    "amount": None,
                    "currency": None,
                    "publicationApproved": False,
                }
                key = entry["identityKey"]
                existing = products.get(key)
                if existing:
                    self._merge_product_listing(existing, entry)
                else:
                    products[key] = entry
                if entry.get("thumbnailSourceUrl"):
                    self._add_asset(entry["thumbnailSourceUrl"], f"product:{key}:thumbnail")
            for category in parsed["categories"]:
                category["listingSource"] = metadata
                _apply_source(category, metadata)
                existing = categories.get(category["identityKey"])
                if not existing:
                    categories[category["identityKey"]] = category
                elif not existing.get("name") and category.get("name"):
                    existing["name"] = category["name"]

    def _merge_product_listing(self, existing: dict, incoming: dict) -> None:
        comparable = ("sortId", "sortPath", "sequence", "detailUrl", "thumbnailSourceUrl")
        conflicts = {
            key: [existing.get(key), incoming.get(key)]
            for key in comparable
            if existing.get(key) and incoming.get(key) and existing.get(key) != incoming.get(key)
        }
        if conflicts:
            self.conflicts.append(
                {
                    "kind": "product-listing-conflict",
                    "identityKey": existing["identityKey"],
                    "fields": conflicts,
                }
            )
        source = incoming.get("listingSource")
        if source and source not in existing["listingSources"]:
            existing["listingSources"].append(source)

    def _synthesize_product_categories(
        self, products: dict[str, dict], categories: dict[str, dict]
    ) -> None:
        for product in products.values():
            ids = path_ids(product.get("sortPath") or "")
            for index, sort_id in enumerate(ids):
                key = f"{product['locale']}:{sort_id}"
                if key in categories:
                    continue
                name = HIDDEN_CATEGORY_NAMES.get(product["locale"], {}).get(sort_id)
                category = {
                    "identityKey": key,
                    "locale": product["locale"],
                    "sortId": sort_id,
                    "name": name,
                    "sortPath": "0," + ",".join(ids[: index + 1]) + ",",
                    "parentSortId": ids[index - 1] if index else None,
                    "inferred": True,
                    "listingSource": product.get("listingSource"),
                }
                _apply_source(category, product.get("listingSource"))
                categories[key] = category

    def _crawl_product_details(
        self, products: dict[str, dict], categories: dict[str, dict]
    ) -> None:
        tasks: list[PageTask] = []
        task_to_key: dict[str, str] = {}
        for locale in self.options.locales:
            locale_products = sorted(
                (item for item in products.values() if item["locale"] == locale),
                key=lambda item: item.get("_listingOrder", (2**31 - 1, 2**31 - 1)),
            )
            if self.options.max_details_per_locale is not None:
                locale_products = locale_products[: self.options.max_details_per_locale]
            self.page_progress[locale]["detailRequested"] = len(locale_products)
            for index, product in enumerate(locale_products, start=1):
                task = PageTask(product["detailUrl"], "product-detail", locale, index)
                tasks.append(task)
                task_to_key[canonical_url(task.url)] = product["identityKey"]
        for loaded in self._load_many(tasks):
            key = task_to_key[canonical_url(loaded.task.url)]
            product = products[key]
            try:
                requested_id = query_ci(loaded.task.url).get("id")
                final_id = query_ci(loaded.record.get("finalUrl", loaded.task.url)).get("id")
                if requested_id != product["oldSiteId"]:
                    raise ValueError(
                        f"Requested detail ID {requested_id!r} does not match product {product['oldSiteId']!r}"
                    )
                if final_id != product["oldSiteId"]:
                    raise ValueError(
                        f"Final detail URL ID {final_id!r} does not match product {product['oldSiteId']!r}"
                    )
                parsed = parse_product_detail(
                    loaded.text,
                    loaded.task.url,
                    loaded.task.locale,
                    self.policy,
                )
            except Exception as exc:
                self._record_parse_error(loaded.task, exc)
                product["detailStatus"] = "parse-error"
                product["failedDetailSource"] = source_metadata(loaded.record)
                _apply_source(product, product.get("listingSource"))
                continue
            metadata = source_metadata(loaded.record)
            product.update(parsed)
            product["detailStatus"] = "ok"
            product["detailSource"] = metadata
            _apply_source(product, metadata)
            if parsed.get("authoritativeName"):
                product["name"] = parsed["authoritativeName"]
            for breadcrumb in parsed.get("categoryBreadcrumb", []):
                category_key = f"{product['locale']}:{breadcrumb['sortId']}"
                category = categories.get(category_key)
                if category is None:
                    self.conflicts.append(
                        {
                            "kind": "detail-breadcrumb-missing-category",
                            "identityKey": category_key,
                            "productIdentityKey": product["identityKey"],
                        }
                    )
                    continue
                authoritative_name = breadcrumb["name"]
                existing_detail_name = category.get("detailBreadcrumbName")
                if existing_detail_name and existing_detail_name != authoritative_name:
                    self.conflicts.append(
                        {
                            "kind": "detail-breadcrumb-category-conflict",
                            "identityKey": category_key,
                            "productIdentityKey": product["identityKey"],
                            "names": [existing_detail_name, authoritative_name],
                        }
                    )
                    continue
                if "listingName" not in category:
                    category["listingName"] = category.get("name")
                category["name"] = authoritative_name
                category["detailBreadcrumbName"] = authoritative_name
                category["detailBreadcrumbSource"] = metadata
            self.page_progress[loaded.task.locale]["detailCompleted"] += 1
            for asset_url in parsed.get("assetUrls", []):
                self._add_asset(asset_url, f"product:{key}:detail")

        requested_keys = set(task_to_key.values())
        for product in products.values():
            if product["identityKey"] not in requested_keys:
                product["detailStatus"] = "not-requested-by-limit"
                _apply_source(product, product.get("listingSource"))
            elif product.get("detailStatus") == "pending":
                product["detailStatus"] = "fetch-error"
                _apply_source(product, product.get("listingSource"))

    def _crawl_news(self, news: dict[str, dict]) -> None:
        list_tasks: list[PageTask] = []
        for locale in self.options.locales:
            count = self.options.news_page_counts[locale]
            if self.options.max_news_list_pages is not None:
                count = min(count, self.options.max_news_list_pages)
            self.page_progress[locale]["newsRequested"] = count
            list_tasks.extend(
                PageTask(self._news_list_url(locale, page), "news-list", locale, page)
                for page in range(1, count + 1)
            )
        for loaded in self._load_many(list_tasks):
            self.page_progress[loaded.task.locale]["newsCompleted"] += 1
            try:
                parsed = parse_news_list(
                    loaded.text,
                    loaded.task.url,
                    loaded.task.locale,
                    self.policy,
                )
            except Exception as exc:
                self._record_parse_error(loaded.task, exc)
                continue
            metadata = source_metadata(loaded.record)
            for asset_url in parsed.get("assetUrls", []):
                self._add_asset(
                    asset_url,
                    f"news-list:{loaded.task.locale}:{loaded.task.ordinal}",
                )
            for entry in parsed["articles"]:
                entry["listingSource"] = metadata
                news.setdefault(entry["identityKey"], entry)

        tasks: list[PageTask] = []
        task_to_key: dict[str, str] = {}
        for index, article in enumerate(news.values(), start=1):
            task = PageTask(article["detailUrl"], "news-detail", article["locale"], index)
            tasks.append(task)
            task_to_key[canonical_url(task.url)] = article["identityKey"]
        for loaded in self._load_many(tasks):
            key = task_to_key[canonical_url(loaded.task.url)]
            article = news[key]
            try:
                parsed = parse_news_detail(
                    loaded.text,
                    loaded.task.url,
                    loaded.task.locale,
                    self.policy,
                )
            except Exception as exc:
                self._record_parse_error(loaded.task, exc)
                article["detailStatus"] = "parse-error"
                continue
            article.update(parsed)
            article["detailStatus"] = "ok"
            metadata = source_metadata(loaded.record)
            article["detailSource"] = metadata
            _apply_source(article, metadata)
            for asset_url in parsed.get("assetUrls", []):
                self._add_asset(asset_url, f"news:{key}")

    def _crawl_static_pages(self, pages: list[dict]) -> None:
        tasks: list[PageTask] = []
        for locale in self.options.locales:
            paths = list(self.options.static_paths.get(locale, []))
            if self.options.max_static_pages_per_locale is not None:
                paths = paths[: self.options.max_static_pages_per_locale]
            self.page_progress[locale]["staticRequested"] = len(paths)
            tasks.extend(
                PageTask(without_fragment(urljoin(self.options.base_url, path)), "static", locale, index)
                for index, path in enumerate(paths, start=1)
            )
        for loaded in self._load_many(tasks):
            try:
                parsed = parse_static_page(
                    loaded.text,
                    loaded.task.url,
                    loaded.task.locale,
                    self.policy,
                )
            except Exception as exc:
                self._record_parse_error(loaded.task, exc)
                continue
            metadata = source_metadata(loaded.record)
            page = {
                "key": f"{loaded.task.locale}:{canonical_url(loaded.task.url)}",
                "locale": loaded.task.locale,
                "title": parsed["title"],
                "text": parsed["text"],
                "assetSourceUrls": parsed["assetUrls"],
            }
            _apply_source(page, metadata)
            pages.append(page)
            self.page_progress[loaded.task.locale]["staticCompleted"] += 1
            for asset_url in parsed["assetUrls"]:
                self._add_asset(asset_url, f"page:{page['key']}")

    def _load_many(self, tasks: list[PageTask]) -> list[LoadedPage]:
        if not tasks:
            return []
        loaded: list[LoadedPage] = []
        with ThreadPoolExecutor(max_workers=self.options.concurrency) as executor:
            futures: dict[Future[LoadedPage | None], PageTask] = {
                executor.submit(self._load_page, task): task for task in tasks
            }
            for future in as_completed(futures):
                result = future.result()
                if result is not None:
                    loaded.append(result)
        loaded.sort(key=lambda item: (item.task.locale, item.task.ordinal, item.task.url))
        return loaded

    def _load_page(self, task: PageTask) -> LoadedPage | None:
        cached = self.store.cached_page(task.url)
        if cached:
            record, _body, text = cached
            self._report_progress("page", f"cache {task.kind}")
            return LoadedPage(task, record, text)
        try:
            result = self.client.get_html(task.url, task.locale)
            record, text = self.store.put_page(task.url, task.kind, task.locale, result)
            self._report_progress("page", f"GET {task.kind}")
            return LoadedPage(task, record, text)
        except Exception as exc:
            status = getattr(exc, "status", None)
            attempts = getattr(exc, "attempts", None)
            retryable = getattr(exc, "retryable", None)
            self.store.put_page_error(
                task.url,
                task.kind,
                task.locale,
                exc,
                status=status,
                attempts=attempts,
                retryable=retryable,
            )
            with self._error_lock:
                self.fetch_errors.append(
                    {
                        "kind": task.kind,
                        "locale": task.locale,
                        "sourceUrl": task.url,
                        "error": f"{type(exc).__name__}: {exc}",
                        "httpStatus": status,
                        "attempts": attempts,
                        "retryable": retryable,
                    }
                )
            print(f"[v2] ERROR {task.kind} {task.url}: {exc}", flush=True)
            return None

    def _record_parse_error(self, task: PageTask, exc: Exception) -> None:
        self.parse_errors.append(
            {
                "kind": task.kind,
                "locale": task.locale,
                "sourceUrl": task.url,
                "error": f"{type(exc).__name__}: {exc}",
            }
        )

    def _add_asset(self, url: str, reference: str) -> None:
        try:
            safe_url = self.policy.absolute(url)
            self.policy.assert_asset(safe_url)
        except PolicyError as exc:
            self.store.add_refused_url(url, str(exc))
            return
        key = canonical_url(safe_url)
        self.asset_urls.setdefault(key, safe_url)
        self.asset_refs[key].add(reference)

    def _download_media(self) -> None:
        tasks = list(self.asset_urls.items())
        with ThreadPoolExecutor(max_workers=self.options.concurrency) as executor:
            futures = {
                executor.submit(self._download_one, canonical, url): (canonical, url)
                for canonical, url in tasks
            }
            for future in as_completed(futures):
                future.result()

    def _download_one(self, canonical: str, url: str) -> dict | None:
        cached = self.store.cached_media(url)
        if cached:
            self._report_progress("media", "cache asset")
            return cached
        locale = "en" if "/en/" in url.lower() else "zh"
        try:
            result = self.client.get_asset(url, locale)
            record = self.store.put_media(url, result)
            self._report_progress("media", "GET asset")
            return record
        except Exception as exc:
            status = getattr(exc, "status", None)
            attempts = getattr(exc, "attempts", None)
            retryable = getattr(exc, "retryable", None)
            self.store.put_media_error(
                url,
                exc,
                status=status,
                attempts=attempts,
                retryable=retryable,
            )
            with self._error_lock:
                self.fetch_errors.append(
                    {
                        "kind": "media",
                        "sourceUrl": url,
                        "error": f"{type(exc).__name__}: {exc}",
                        "httpStatus": status,
                        "attempts": attempts,
                        "retryable": retryable,
                    }
                )
            print(f"[v2] ERROR media {url}: {exc}", flush=True)
            return None

    def _report_progress(self, group: str, label: str) -> None:
        with self._progress_lock:
            self._progress_counts[group] += 1
            count = self._progress_counts[group]
            if count == 1 or count % 25 == 0:
                print(f"[v2] {group} progress: {count} ({label})", flush=True)

    def _media_record(self, url: str | None) -> dict | None:
        if not url:
            return None
        return self.store.data["media"].get(canonical_url(url))

    def _resolve_media(self, products: dict[str, dict], news: dict[str, dict], pages: list[dict]) -> None:
        for product in products.values():
            thumbnail = self._media_record(product.get("thumbnailSourceUrl"))
            main = self._media_record(product.get("mainImageSourceUrl"))
            product["thumbnailSha256"] = thumbnail.get("sha256") if thumbnail and thumbnail.get("status") == "ok" else None
            product["mainImageSha256"] = main.get("sha256") if main and main.get("status") == "ok" else None
            hashes: list[str] = []
            for url in product.get("assetUrls", []):
                record = self._media_record(url)
                if record and record.get("status") == "ok" and record["sha256"] not in hashes:
                    hashes.append(record["sha256"])
            product["mediaSha256"] = hashes
        for article in news.values():
            hashes = []
            for url in article.get("assetUrls", []):
                record = self._media_record(url)
                if record and record.get("status") == "ok" and record["sha256"] not in hashes:
                    hashes.append(record["sha256"])
            article["mediaSha256"] = hashes
        for page in pages:
            hashes = []
            for url in page.get("assetSourceUrls", []):
                record = self._media_record(url)
                if record and record.get("status") == "ok" and record["sha256"] not in hashes:
                    hashes.append(record["sha256"])
            page["mediaSha256"] = hashes

    def _build_media_manifest(self, generated_at: str) -> dict:
        by_hash: dict[str, dict] = {}
        failures: list[dict] = []
        for canonical, source_url in sorted(self.asset_urls.items()):
            record = self.store.data["media"].get(canonical)
            refs = sorted(self.asset_refs.get(canonical, set()))
            if not record or record.get("status") != "ok":
                failures.append(
                    {
                        "sourceUrl": source_url,
                        "sourceRefs": refs,
                        "error": (record or {}).get("error", "not downloaded"),
                        "httpStatus": (record or {}).get("httpStatus"),
                    }
                )
                continue
            digest = record["sha256"]
            asset = by_hash.setdefault(
                digest,
                {
                    "sha256": digest,
                    "mimeType": record["mimeType"],
                    "extension": record["extension"],
                    "bytes": record["bytes"],
                    "width": record.get("width"),
                    "height": record.get("height"),
                    "localPath": record["localPath"],
                    "scrapedAt": record["scrapedAt"],
                    "sourceUrl": source_url,
                    "sourceUrls": [],
                    "sourceRefs": [],
                },
            )
            if source_url not in asset["sourceUrls"]:
                asset["sourceUrls"].append(source_url)
            for ref in refs:
                if ref not in asset["sourceRefs"]:
                    asset["sourceRefs"].append(ref)
        assets = sorted(by_hash.values(), key=lambda item: item["sha256"])
        for asset in assets:
            asset["sourceUrls"].sort()
            asset["sourceRefs"].sort()
        return {
            "schemaVersion": SCHEMA_VERSION,
            "generatedAt": generated_at,
            "sourceBaseUrl": self.options.base_url,
            "assets": assets,
            "failures": failures,
        }
