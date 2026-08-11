from __future__ import annotations

from dataclasses import dataclass
from pathlib import PurePosixPath
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit, urlunsplit

from .config import (
    FORBIDDEN_ENDPOINT_BASENAMES,
    SAFE_ASSET_EXTENSIONS,
    SAFE_PAGE_BASENAMES,
)


class PolicyError(ValueError):
    """Raised before any disallowed network request can be sent."""


def without_fragment(url: str) -> str:
    parts = urlsplit(url.strip())
    return urlunsplit((parts.scheme, parts.netloc, parts.path, parts.query, ""))


def canonical_url(url: str) -> str:
    """Return a cache identity safe on case-insensitive Windows filesystems."""

    parts = urlsplit(without_fragment(url))
    query = parse_qsl(parts.query, keep_blank_values=True)
    query = sorted(((key.lower(), value) for key, value in query), key=lambda item: item)
    port = parts.port
    hostname = (parts.hostname or "").lower()
    default_port = (parts.scheme.lower() == "http" and port == 80) or (
        parts.scheme.lower() == "https" and port == 443
    )
    netloc = hostname if not port or default_port else f"{hostname}:{port}"
    # The old site runs on Windows/IIS and treats ASP paths case-insensitively.
    path = parts.path.lower() or "/"
    return urlunsplit((parts.scheme.lower(), netloc, path, urlencode(query), ""))


@dataclass(frozen=True)
class SourcePolicy:
    base_url: str
    allow_test_origin: bool = False

    def __post_init__(self) -> None:
        base = urlsplit(self.base_url)
        if base.scheme not in {"http", "https"} or not base.hostname:
            raise PolicyError(f"Invalid source base URL: {self.base_url!r}")
        if self.allow_test_origin:
            if base.hostname not in {"127.0.0.1", "localhost", "::1"}:
                raise PolicyError("Test origins are restricted to loopback hosts")
        elif base.scheme != "http" or base.hostname.lower() != "www.ch-uten.com":
            raise PolicyError("Production crawl is restricted to http://www.ch-uten.com/")

    @property
    def origin(self) -> tuple[str, str, int | None]:
        parts = urlsplit(self.base_url)
        port = parts.port
        if (parts.scheme.lower(), port) in {("http", 80), ("https", 443)}:
            port = None
        return parts.scheme.lower(), (parts.hostname or "").lower(), port

    def absolute(self, href: str, context_url: str | None = None) -> str:
        href = href.strip()
        if not href:
            raise PolicyError("Empty URL")
        lowered = href.lower()
        if lowered.startswith(("javascript:", "mailto:", "tel:", "data:")):
            raise PolicyError(f"Disallowed URL scheme: {href[:40]}")
        absolute = without_fragment(urljoin(context_url or self.base_url, href))
        self.assert_get(absolute)
        return absolute

    def assert_get(self, url: str, method: str = "GET") -> None:
        if method.upper() != "GET":
            raise PolicyError(f"Only GET is permitted; refused {method.upper()} {url}")
        parts = urlsplit(url)
        port = parts.port
        if (parts.scheme.lower(), port) in {("http", 80), ("https", 443)}:
            port = None
        source_origin = (parts.scheme.lower(), (parts.hostname or "").lower(), port)
        if source_origin != self.origin:
            raise PolicyError(f"Cross-origin request refused: {url}")
        basename = PurePosixPath(parts.path).name.lower()
        if basename in FORBIDDEN_ENDPOINT_BASENAMES:
            raise PolicyError(f"Form-save endpoint refused: {url}")
        if parts.username or parts.password:
            raise PolicyError("Credential-bearing URLs are refused")
        suffix = PurePosixPath(parts.path).suffix.lower()
        if basename not in SAFE_PAGE_BASENAMES and suffix not in SAFE_ASSET_EXTENSIONS:
            raise PolicyError(f"URL is outside the public page/media allowlist: {url}")

    def assert_asset(self, url: str) -> None:
        self.assert_get(url, "GET")
        suffix = PurePosixPath(urlsplit(url).path).suffix.lower()
        if suffix not in SAFE_ASSET_EXTENSIONS:
            raise PolicyError(f"Non-media URL refused from asset queue: {url}")

    def is_forbidden(self, url: str) -> bool:
        try:
            self.assert_get(url)
        except (PolicyError, ValueError):
            return True
        return False
