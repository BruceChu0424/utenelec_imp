from __future__ import annotations

import re
from collections.abc import Iterable
from pathlib import PurePosixPath
from urllib.parse import parse_qsl, urlsplit

from bs4 import BeautifulSoup, Tag

from .config import DOWNLOAD_EXTENSIONS
from .policy import PolicyError, SourcePolicy


SPACE_RE = re.compile(r"[\t\f\v ]+")
NEWLINE_RE = re.compile(r"\n{3,}")
CSS_URL_RE = re.compile(r"url\(\s*(['\"]?)(.*?)\1\s*\)", re.IGNORECASE)


def soup_for(html: str) -> BeautifulSoup:
    return BeautifulSoup(html, "html.parser")


def clean_text(value: str) -> str:
    value = value.replace("\xa0", " ").replace("\r", "\n")
    lines = [SPACE_RE.sub(" ", line).strip() for line in value.split("\n")]
    return NEWLINE_RE.sub("\n\n", "\n".join(line for line in lines if line)).strip()


def tag_text(tag: Tag | None, separator: str = "\n") -> str:
    return clean_text(tag.get_text(separator, strip=True)) if tag else ""


def page_title(soup: BeautifulSoup) -> str:
    return tag_text(soup.title, " ")


def query_ci(url: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, value in parse_qsl(urlsplit(url).query, keep_blank_values=True):
        result.setdefault(key.lower(), value)
    return result


def path_ids(sort_path: str) -> list[str]:
    return [part for part in sort_path.split(",") if part and part != "0"]


def _absolute_or_none(policy: SourcePolicy, href: str | None, context_url: str) -> str | None:
    if not href:
        return None
    try:
        return policy.absolute(href, context_url)
    except (PolicyError, ValueError):
        return None


def _is_detail_href(href: str) -> bool:
    return PurePosixPath(urlsplit(href).path).name.lower() == "productshow.asp"


def _is_product_list_href(href: str) -> bool:
    return PurePosixPath(urlsplit(href).path).name.lower() == "product.asp"


def _is_news_detail_href(href: str) -> bool:
    return PurePosixPath(urlsplit(href).path).name.lower() == "newsshow.asp"


def _visible_dd_text(block: Tag) -> tuple[str, str | None]:
    visible = ""
    hidden: str | None = None
    for dd in block.find_all("dd"):
        text = tag_text(dd, " ")
        style = str(dd.get("style") or "").replace(" ", "").lower()
        if "display:none" in style:
            hidden = hidden or text
        elif not visible:
            visible = text
    return visible, hidden


def extract_asset_urls(
    scope: BeautifulSoup | Tag,
    context_url: str,
    policy: SourcePolicy,
    *,
    include_downloads: bool = True,
) -> list[str]:
    urls: list[str] = []

    def add(value: str | None) -> None:
        absolute = _absolute_or_none(policy, value, context_url)
        if absolute and absolute not in urls:
            urls.append(absolute)

    for tag in scope.find_all(["img", "source"]):
        for attribute in ("src", "data-src", "data-original", "data-lazy-src"):
            add(tag.get(attribute))
        srcset = tag.get("srcset")
        if srcset:
            for item in str(srcset).split(","):
                add(item.strip().split(" ", 1)[0])
    for tag in scope.find_all(style=True):
        for match in CSS_URL_RE.finditer(str(tag.get("style"))):
            add(match.group(2))
    for tag in scope.find_all("style"):
        for match in CSS_URL_RE.finditer(tag.get_text(" ", strip=False)):
            add(match.group(2))
    if include_downloads:
        for anchor in scope.find_all("a", href=True):
            href = str(anchor.get("href"))
            suffix = PurePosixPath(urlsplit(href).path).suffix.lower()
            if suffix in DOWNLOAD_EXTENSIONS:
                add(href)
    return urls


def parse_product_list(
    html: str,
    source_url: str,
    locale: str,
    policy: SourcePolicy,
) -> dict:
    soup = soup_for(html)
    products: list[dict] = []
    for block in soup.find_all("dl"):
        classes = {str(value).lower() for value in (block.get("class") or [])}
        if "dl_1" not in classes:
            continue
        detail_anchor: Tag | None = None
        detail_url: str | None = None
        for anchor in block.find_all("a", href=True):
            candidate = _absolute_or_none(policy, str(anchor.get("href")), source_url)
            if candidate and _is_detail_href(candidate):
                detail_anchor = anchor
                detail_url = candidate
                break
        if not detail_anchor or not detail_url:
            continue
        query = query_ci(detail_url)
        old_id = query.get("id")
        if not old_id or not old_id.isdigit():
            continue
        label, hidden_value = _visible_dd_text(block)
        name = re.sub(r"^(?:型号|model)\s*[：:]\s*", "", label, flags=re.IGNORECASE).strip()
        image = block.find("img")
        image_url = _absolute_or_none(policy, str(image.get("src")) if image else None, source_url)
        products.append(
            {
                "identityKey": f"{locale}:{old_id}",
                "locale": locale,
                "oldSiteId": old_id,
                "name": name or label,
                "listingLabel": label,
                # Kept only as raw legacy evidence; it is explicitly not a SKU.
                "legacyHiddenValue": hidden_value,
                "sortId": query.get("sortid"),
                "sortPath": query.get("sortpath", ""),
                "sequence": query.get("sequence"),
                "detailUrl": detail_url,
                "thumbnailSourceUrl": image_url,
            }
        )

    categories: list[dict] = []
    seen_categories: set[str] = set()
    for anchor in soup.find_all("a", href=True):
        absolute = _absolute_or_none(policy, str(anchor.get("href")), source_url)
        if not absolute or not _is_product_list_href(absolute):
            continue
        query = query_ci(absolute)
        sort_id = query.get("sortid")
        if not sort_id or not sort_id.isdigit() or sort_id in seen_categories:
            continue
        seen_categories.add(sort_id)
        sort_path = query.get("sortpath", "")
        ids = path_ids(sort_path)
        categories.append(
            {
                "identityKey": f"{locale}:{sort_id}",
                "locale": locale,
                "sortId": sort_id,
                "name": tag_text(anchor, " "),
                "sortPath": sort_path,
                "parentSortId": ids[-2] if len(ids) > 1 else None,
                "inferred": False,
            }
        )

    return {
        "title": page_title(soup),
        "products": products,
        "categories": categories,
        "assetUrls": extract_asset_urls(soup, source_url, policy),
    }


def _model_mentions(lines: Iterable[str], locale: str) -> list[str]:
    mentions: list[str] = []
    marker = re.compile(r"^(?:型号|model(?:\s+no\.?)?)\s*[：:]\s*(.+)$", re.IGNORECASE)
    for line in lines:
        match = marker.match(line.strip())
        if match:
            value = match.group(1).strip()
            if value and value not in mentions:
                mentions.append(value)
    return mentions


def _packing_text(lines: list[str]) -> str | None:
    marker = re.compile(r"(?:包装数量|包装数|packing\s+quantity|packing)", re.IGNORECASE)
    for index, line in enumerate(lines):
        if not marker.search(line):
            continue
        combined = line
        if index + 1 < len(lines) and len(combined) < 80:
            combined = f"{combined} {lines[index + 1]}".strip()
        return combined
    return None


def _detail_category_breadcrumb(soup: BeautifulSoup, source_url: str) -> list[dict[str, str]]:
    """Align authoritative detail breadcrumb labels with stable SortPath IDs.

    The legacy listing navigation truncates several labels with malformed entities.
    Product detail pages carry the complete hierarchy in ``div.rtop``.  Aligning the
    final N breadcrumb segments to the N SortPath IDs works for both Chinese
    (``首页 | 产品中心 | ...``) and English (``Home / Products | ...``) layouts.
    """
    ids = path_ids(query_ci(source_url).get("sortpath", ""))
    breadcrumb = soup.select_one("div.rtop")
    if not ids or breadcrumb is None:
        return []
    segments = [clean_text(part) for part in tag_text(breadcrumb, " ").split("|")]
    segments = [part for part in segments if part]
    if len(segments) < len(ids):
        return []
    category_names = segments[-len(ids) :]
    return [
        {"sortId": sort_id, "name": name}
        for sort_id, name in zip(ids, category_names, strict=True)
    ]


def parse_product_detail(
    html: str,
    source_url: str,
    locale: str,
    policy: SourcePolicy,
) -> dict:
    soup = soup_for(html)
    container = soup.select_one("div.products_detail")
    if container is None:
        raise ValueError("HTTP 200 page is not a product detail: missing div.products_detail")
    description = container.select_one("div.con_box") if container else None
    main_image = container.find("img") if container else None
    title = page_title(soup)
    authoritative_name = title.split("_", 1)[0].strip() if title else ""
    if not authoritative_name or authoritative_name in {
        "中山市优腾电器有限公司",
        "Zhongshan UTEN Eletiric Co.,Ltd",
    }:
        raise ValueError("HTTP 200 product detail has no authoritative product title")
    if main_image is None:
        raise ValueError("HTTP 200 product detail has no main product image")
    description_text = tag_text(description)
    lines = [line.strip() for line in description_text.split("\n") if line.strip()]
    asset_scope = container or soup
    asset_urls = extract_asset_urls(asset_scope, source_url, policy)
    main_image_url = _absolute_or_none(
        policy,
        str(main_image.get("src")) if main_image else None,
        source_url,
    )
    if main_image_url and main_image_url not in asset_urls:
        asset_urls.insert(0, main_image_url)
    downloads = [
        url
        for url in asset_urls
        if PurePosixPath(urlsplit(url).path).suffix.lower() in DOWNLOAD_EXTENSIONS
    ]
    mentions = _model_mentions(lines, locale)
    return {
        "pageTitle": title,
        "authoritativeName": authoritative_name,
        "descriptionHtml": description.decode_contents().strip() if description else "",
        "descriptionText": description_text,
        "descriptionHtmlSafety": "UNTRUSTED_LEGACY_HTML_DO_NOT_RENDER",
        "modelMentions": mentions,
        "modelMentionCount": len(mentions),
        "packingText": _packing_text(lines),
        "categoryBreadcrumb": _detail_category_breadcrumb(soup, source_url),
        "mainImageSourceUrl": main_image_url,
        "assetUrls": asset_urls,
        "downloads": downloads,
    }


def parse_news_list(
    html: str,
    source_url: str,
    locale: str,
    policy: SourcePolicy,
) -> dict:
    soup = soup_for(html)
    articles: list[dict] = []
    seen: set[str] = set()
    for anchor in soup.find_all("a", href=True):
        absolute = _absolute_or_none(policy, str(anchor.get("href")), source_url)
        if not absolute or not _is_news_detail_href(absolute):
            continue
        query = query_ci(absolute)
        old_id = query.get("id")
        if not old_id or not old_id.isdigit() or old_id in seen:
            continue
        seen.add(old_id)
        articles.append(
            {
                "identityKey": f"{locale}:{old_id}",
                "locale": locale,
                "oldSiteId": old_id,
                "sortId": query.get("sortid"),
                "title": str(anchor.get("title") or tag_text(anchor, " ")).strip(),
                "detailUrl": absolute,
            }
        )
    return {
        "title": page_title(soup),
        "articles": articles,
        "assetUrls": extract_asset_urls(soup, source_url, policy),
    }


def parse_news_detail(
    html: str,
    source_url: str,
    locale: str,
    policy: SourcePolicy,
) -> dict:
    soup = soup_for(html)
    view = soup.select_one("div.news_view")
    if view is None:
        raise ValueError("HTTP 200 page is not a news detail: missing div.news_view")
    title_tag = view.select_one("div.title") if view else None
    info_tag = view.select_one("div.info") if view else None
    body = view.select_one("div.con") if view else None
    if title_tag is None or body is None:
        raise ValueError("HTTP 200 news detail is missing title or body container")
    scope = body or view or soup
    return {
        "pageTitle": page_title(soup),
        "title": tag_text(title_tag, " "),
        "publishedText": tag_text(info_tag, " "),
        "bodyHtml": body.decode_contents().strip() if body else "",
        "bodyHtmlSafety": "UNTRUSTED_LEGACY_HTML_DO_NOT_RENDER",
        "bodyText": tag_text(body),
        "assetUrls": extract_asset_urls(scope, source_url, policy),
    }


def parse_static_page(
    html: str,
    source_url: str,
    locale: str,
    policy: SourcePolicy,
) -> dict:
    soup = soup_for(html)
    for unwanted in soup(["script", "style", "noscript"]):
        unwanted.decompose()
    body = soup.body or soup
    return {
        "title": page_title(soup),
        "text": tag_text(body),
        "assetUrls": extract_asset_urls(body, source_url, policy),
    }
