from __future__ import annotations

import io
import shutil
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from PIL import Image

from .config import RetrySettings
from .runner import CrawlOptions, LegacyCrawler
from .validation import validate_output


def _png_bytes() -> bytes:
    output = io.BytesIO()
    Image.new("RGBA", (3, 2), (25, 140, 120, 255)).save(output, format="PNG")
    return output.getvalue()


PNG_BYTES = _png_bytes()


def _product_list(locale: str) -> str:
    if locale == "en":
        products = [
            ("1", "GK11", "8", "101", "0,1,8,"),
        ]
        category = "Rocker switch series"
        model_prefix = "Model:"
    else:
        # Same name, different old IDs: the smoke test guards against name-based dedupe.
        products = [
            ("1", "GK11", "8", "101", "0,1,8,"),
            ("124", "GK11", "23", "201", "0,2,23,"),
        ]
        category = "大跷板开关系列"
        model_prefix = "型号："
    blocks = []
    for old_id, name, sort_id, sequence, sort_path in products:
        href = (
            f"productshow.asp?ID={old_id}&SortID={sort_id}"
            f"&Sequence={sequence}&SortPath={sort_path}#here"
        )
        blocks.append(
            f"""
            <dl class="dl_1">
              <dt><a href="{href}"><img src="/Upload/PicFiles/shared.png"></a></dt>
              <dd><a href="{href}">{model_prefix}{name}</a></dd>
              <dd style="display:none"><a href="{href}">114456-211</a></dd>
            </dl>
            """
        )
    extra_categories = ""
    if locale == "zh":
        extra_categories = (
            '<a href="Product.asp?sortID=2&SortPath=0,2,">V1.1</a>'
            '<a href="Product.asp?sortID=23&SortPath=0,2,23,">大跷板开关系列</a>'
        )
    return f"""
    <!doctype html><html><head><meta charset="utf-8"><title>Products</title></head><body>
      <nav><a href="Product.asp?sortID=1&SortPath=0,1,">V1.0</a>
      <a href="Product.asp?sortID=8&SortPath=0,1,8,">{category}</a>{extra_categories}</nav>
      {''.join(blocks)}
    </body></html>
    """


def _product_detail(locale: str, old_id: str) -> str:
    if locale == "en":
        body = "<p>Model: GK11</p><p>Single-gang one-way switch</p><p>Packing quantity:</p><p>10 pcs/box</p>"
        breadcrumb = "Home / Products | V1.0 | Rocker Switches"
    elif old_id == "124":
        body = "<p>GK11</p><p>型号：GK11</p><p>单联单控开关</p><p>包装数量：</p><p>10只/盒</p>"
        breadcrumb = "首页 | 产品中心 | V1.1 | 大跷板开关系列"
    else:
        body = "<p>型号：GK11</p><p>单联单控开关</p><p>包装数量：</p><p>10只/盒 100只/箱</p>"
        breadcrumb = "首页 | 产品中心 | V1.0 | 大跷板开关系列"
    return f"""
    <!doctype html><html><head><meta charset="utf-8"><title>GK11_UTEN</title></head><body>
      <div class="rtop">{breadcrumb}</div>
      <div class="products_detail">
        <div><img src="/Upload/PicFiles/detail.png" width="297"></div>
        <div class="products_detail_con"><div class="h2">Description</div>
          <div class="con_box">{body}</div>
        </div>
      </div>
    </body></html>
    """


def _news_list(locale: str) -> str:
    old_id = "14" if locale == "en" else "10"
    title = "Fixture news" if locale == "en" else "测试新闻"
    return f"""
    <html><head><meta charset="utf-8"><title>News</title></head><body>
      <a href="newsshow.asp?ID={old_id}&SortID=1" title="{title}">{title}</a>
    </body></html>
    """


def _news_detail(locale: str) -> str:
    title = "Fixture news" if locale == "en" else "测试新闻"
    body = "Fixture body" if locale == "en" else "测试正文"
    return f"""
    <html><head><meta charset="utf-8"><title>{title}_UTEN</title></head><body>
      <div class="news_view"><div class="title">{title}</div>
        <div class="info">2017-01-01</div>
        <div class="con"><p>{body}</p><img src="/Upload/PicFiles/news.png"></div>
      </div>
    </body></html>
    """


class FixtureSite:
    def __init__(self, *, redirect_detail_ids: dict[str, str] | None = None) -> None:
        self.requests: list[tuple[str, str]] = []
        self.redirect_detail_ids = redirect_detail_ids or {}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
                owner.requests.append(("GET", self.path))
                owner._serve(self)

            def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
                owner.requests.append(("POST", self.path))
                self.send_response(500)
                self.end_headers()

            def log_message(self, _format: str, *_args: object) -> None:
                return

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def base_url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}/"

    def __enter__(self) -> "FixtureSite":
        self.thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def _serve(self, handler: BaseHTTPRequestHandler) -> None:
        parsed = urlsplit(handler.path)
        path = parsed.path.lower()
        locale = "en" if path.startswith("/en/") else "zh"
        if path.endswith("/save.asp") or path.endswith("/messagesave.asp"):
            self._send(handler, 500, b"must never be requested", "text/plain")
            return
        if path in {"/product.asp", "/en/product.asp"}:
            self._send_html(handler, _product_list(locale))
            return
        if path in {"/productshow.asp", "/en/productshow.asp"}:
            old_id = parse_qs(parsed.query).get("ID", parse_qs(parsed.query).get("id", ["1"]))[0]
            if old_id in self.redirect_detail_ids:
                target_id = self.redirect_detail_ids[old_id]
                prefix = "/en/productshow.asp" if locale == "en" else "/productshow.asp"
                handler.send_response(302)
                handler.send_header("Location", f"{prefix}?ID={target_id}&SortID=8")
                handler.send_header("Content-Length", "0")
                handler.end_headers()
                return
            self._send_html(handler, _product_detail(locale, old_id))
            return
        if path in {"/news.asp", "/en/news.asp"}:
            self._send_html(handler, _news_list(locale))
            return
        if path in {"/newsshow.asp", "/en/newsshow.asp"}:
            self._send_html(handler, _news_detail(locale))
            return
        if path in {"/index.asp", "/en/index.asp"}:
            title = "Home" if locale == "en" else "首页"
            self._send_html(
                handler,
                f"<html><head><meta charset='utf-8'><title>{title}</title></head>"
                f"<body><main>{title}<img src='/Upload/PicFiles/static.png'></main></body></html>",
            )
            return
        if path.startswith("/upload/picfiles/"):
            self._send(handler, 200, PNG_BYTES, "image/png")
            return
        self._send_html(handler, "<html><title>404 Not Found</title><body>page not found</body></html>", 404)

    @staticmethod
    def _send_html(handler: BaseHTTPRequestHandler, html: str, status: int = 200) -> None:
        FixtureSite._send(handler, status, html.encode("utf-8"), "text/html; charset=utf-8")

    @staticmethod
    def _send(
        handler: BaseHTTPRequestHandler,
        status: int,
        body: bytes,
        content_type: str,
    ) -> None:
        handler.send_response(status)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)


def fixture_options(root: Path, base_url: str) -> CrawlOptions:
    return CrawlOptions(
        output_dir=root,
        base_url=base_url,
        locales=("zh", "en"),
        concurrency=2,
        retry_settings=RetrySettings(
            retries=2,
            timeout_seconds=3,
            throttle_seconds=0,
            max_html_bytes=1024 * 1024,
            max_asset_bytes=1024 * 1024,
        ),
        allow_test_origin=True,
        product_page_counts={"zh": 1, "en": 1},
        news_page_counts={"zh": 1, "en": 1},
        static_paths={"zh": ["index.asp"], "en": ["en/index.asp"]},
    )


def run_fixture_smoke(output_dir: Path | None = None, *, keep_output: bool = False) -> dict:
    temporary = output_dir is None
    root = output_dir or Path(tempfile.mkdtemp(prefix="uten-legacy-v2-smoke-"))
    if root.exists() and any(root.iterdir()):
        raise RuntimeError(f"Smoke output directory must be empty: {root}")
    with FixtureSite() as site:
        options = fixture_options(root, site.base_url)
        catalog, media, qa = LegacyCrawler(options).run()
        validation = validate_output(root, expect_full=False)
        requests_after_first_run = len(site.requests)
        resumed_catalog, resumed_media, resumed_qa = LegacyCrawler(options).run()
        resumed_validation = validate_output(root, expect_full=False)
        zh_products = [item for item in catalog["products"] if item["locale"] == "zh"]
        assertions = {
            "productCount": len(catalog["products"]) == 3,
            "sameNameDifferentIdsPreserved": len(zh_products) == 2
            and len({item["oldSiteId"] for item in zh_products}) == 2
            and len({item["name"] for item in zh_products}) == 1,
            "newsCount": len(catalog["news"]) == 2,
            "staticPageCount": len(catalog["pages"]) == 2,
            "contentHashDedup": len(media["assets"]) == 1,
            "qaPass": qa["status"] == "pass",
            "validationPass": validation["status"] == "pass",
            "resumeUsesCheckpointOnly": len(site.requests) == requests_after_first_run
            and len(resumed_catalog["products"]) == len(catalog["products"])
            and len(resumed_media["assets"]) == len(media["assets"])
            and resumed_qa["status"] == "pass"
            and resumed_validation["status"] == "pass",
            "getOnly": all(method == "GET" for method, _path in site.requests),
            "saveEndpointsUntouched": all(
                "save.asp" not in path.lower() for _method, path in site.requests
            ),
        }
        result = {
            "status": "pass" if all(assertions.values()) else "fail",
            "assertions": assertions,
            "outputDir": str(root.resolve()),
            "requestCount": len(site.requests),
            "requests": site.requests,
            "qaSummary": qa["summary"],
        }
    if temporary and not keep_output:
        shutil.rmtree(root)
        result["outputDir"] = None
    return result
