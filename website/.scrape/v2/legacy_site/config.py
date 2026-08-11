from __future__ import annotations

from dataclasses import dataclass


SCHEMA_VERSION = "uten-legacy-catalog/v2"
CHECKPOINT_VERSION = 1
DEFAULT_BASE_URL = "http://www.ch-uten.com/"

PRODUCT_LIST_PAGE_COUNTS = {"zh": 94, "en": 87}
NEWS_LIST_PAGE_COUNTS = {"zh": 4, "en": 1}

BASELINE = {
    "capturedAt": "2026-08-09",
    "productListPages": {"zh": 94, "en": 87},
    "products": {"zh": 1121, "en": 1036},
    "productDetails": {"zh": 1121, "en": 1036},
    "productLeafSortIds": {"zh": 60, "en": 58},
    "nonEmptyDescriptions": {"zh": 814, "en": 801},
    "emptyDescriptions": {"zh": 307, "en": 235},
    "news": {"zh": 19, "en": 3},
    "staticPages": {"zh": 17, "en": 7},
    "newsAssetUrls": {"zh": 118, "en": 1},
    "zhProductAssetUrls": 2137,
    "enProductAssetUrls": 2025,
    "productIdIntersection": 1035,
    "zhOnlyProductIds": 86,
    "enOnlyProductIds": 1,
    # SHA-256 over numeric-ID-sorted lines: oldSiteId<TAB>sortId<TAB>sortPath<LF>
    "identitySortPathSha256": {
        "zh": "6bbb72644226577cd6a79b3b825c1a2e67cb9647e30b92d4bc42013ad4c8652b",
        "en": "977455e76c25712c0f2741a867b599defa0078b4c381caff3b7ae80fee60a752",
    },
    # SHA-256 over numeric-ID-sorted lines: oldSiteId<TAB>thumbnailUrl<TAB>mainImageUrl<LF>
    "productImagesSha256": {
        "zh": "868677193cb0d021e797f2832e51738dda53a1ddd8b4c57ec9c93118dfbd98f5",
        "en": "1605428754c660b16729117cf2eb576fbe0d8de4077389b689df0565207f0fb4",
    },
}

STATIC_PATHS = {
    "zh": [
        "index.asp",
        "about.asp?id=1",
        "about.asp?id=2",
        "about.asp?id=3",
        "about.asp?id=4",
        "honor.asp?Sortid=1",
        "honor.asp?Sortid=1&Page=2",
        "case.asp?id=6",
        "join.asp?id=7",
        "join.asp?id=8",
        "join.asp?id=9",
        "ln.asp?id=10",
        "job.asp",
        "jobshow.asp?ID=1",
        "contact.asp?id=11",
        "feedback.asp",
        "tian.asp",
    ],
    "en": [
        "en/index.asp",
        "en/about.asp?id=1",
        "en/about.asp?id=2",
        "en/service.asp?id=5",
        "en/faq.asp?Sortid=4",
        "en/feedback.asp",
        "en/contact.asp?id=11",
    ],
}

# These product-bearing leaves appear in detail SortPath values but are not
# exposed as separate links in the old site's sidebar.
HIDDEN_CATEGORY_NAMES = {
    "zh": {
        "63": "大跷板开关系列",
        "64": "LED微点开关系列",
        "65": "通用电子插座系列",
        "69": "出口插座",
    },
    "en": {
        "63": "Rocker switch series",
        "64": "LED micro-point switch series",
        "65": "Universal electronic socket series",
        "69": "Export socket series",
    },
}

DOWNLOAD_EXTENSIONS = {
    ".pdf",
    ".doc",
    ".docx",
    ".xls",
    ".xlsx",
    ".zip",
    ".rar",
}

FORBIDDEN_ENDPOINT_BASENAMES = {
    "save.asp",
    "messagesave.asp",
}

SAFE_PAGE_BASENAMES = {
    "index.asp",
    "product.asp",
    "productshow.asp",
    "news.asp",
    "newsshow.asp",
    "about.asp",
    "honor.asp",
    "case.asp",
    "join.asp",
    "ln.asp",
    "job.asp",
    "jobshow.asp",
    "contact.asp",
    "feedback.asp",
    "tian.asp",
    "service.asp",
    "faq.asp",
}

SAFE_ASSET_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".png",
    ".gif",
    ".bmp",
    ".webp",
    ".svg",
    ".ico",
    ".tif",
    ".tiff",
    *DOWNLOAD_EXTENSIONS,
}


@dataclass(frozen=True)
class RetrySettings:
    retries: int = 4
    timeout_seconds: float = 20.0
    throttle_seconds: float = 0.35
    max_html_bytes: int = 12 * 1024 * 1024
    max_asset_bytes: int = 64 * 1024 * 1024
