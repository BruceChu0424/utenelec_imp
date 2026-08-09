from __future__ import annotations

import random
import threading
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Mapping

import requests
from bs4 import UnicodeDammit

from .config import RetrySettings
from .policy import SourcePolicy


RETRYABLE_STATUS = {408, 425, 429, 500, 502, 503, 504}
SEMANTIC_NOT_FOUND_MARKERS = (
    "您访问的页面不存在",
    "页面不存在",
    "page not found",
    "404 not found",
)


class FetchError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        url: str,
        attempts: int,
        status: int | None = None,
        retryable: bool = False,
    ) -> None:
        super().__init__(message)
        self.url = url
        self.attempts = attempts
        self.status = status
        self.retryable = retryable


@dataclass(frozen=True)
class FetchResult:
    requested_url: str
    final_url: str
    status: int
    headers: Mapping[str, str]
    body: bytes
    fetched_at: str
    attempts: int

    @property
    def content_type(self) -> str:
        return self.headers.get("content-type", "").split(";", 1)[0].strip().lower()


class GlobalThrottle:
    def __init__(self, minimum_interval_seconds: float) -> None:
        self.minimum_interval_seconds = max(0.0, minimum_interval_seconds)
        self._lock = threading.Lock()
        self._next_allowed = 0.0

    def wait(self) -> None:
        with self._lock:
            now = time.monotonic()
            delay = max(0.0, self._next_allowed - now)
            if delay:
                time.sleep(delay)
            self._next_allowed = time.monotonic() + self.minimum_interval_seconds


def _utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def decode_html(body: bytes, content_type: str = "") -> tuple[str, str]:
    declared: str | None = None
    lowered = content_type.lower()
    if "charset=" in lowered:
        declared = lowered.split("charset=", 1)[1].split(";", 1)[0].strip(" \"'")
    candidates = [item for item in (declared, "utf-8", "gb18030") if item]
    decoded = UnicodeDammit(body, candidates, is_html=True)
    text = decoded.unicode_markup or body.decode("utf-8", errors="replace")
    encoding = decoded.original_encoding or declared or "utf-8"
    return text, encoding


def looks_like_semantic_404(text: str, status: int) -> bool:
    if status == 404:
        return True
    lowered = text[:8000].lower()
    return any(marker.lower() in lowered for marker in SEMANTIC_NOT_FOUND_MARKERS)


class HttpClient:
    """A GET-only, same-origin client with bounded retries and global pacing."""

    def __init__(
        self,
        policy: SourcePolicy,
        settings: RetrySettings,
        *,
        user_agent: str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) UTEN-migration-crawler-v2/1.0",
    ) -> None:
        self.policy = policy
        self.settings = settings
        self.user_agent = user_agent
        self.throttle = GlobalThrottle(settings.throttle_seconds)

    def get_html(self, url: str, locale: str) -> FetchResult:
        result = self._get(url, self.settings.max_html_bytes, locale)
        text, _ = decode_html(result.body, result.headers.get("content-type", ""))
        if looks_like_semantic_404(text, result.status):
            raise FetchError(
                f"Semantic 404 returned for {url}",
                url=url,
                attempts=result.attempts,
                status=result.status,
                retryable=False,
            )
        return result

    def get_asset(self, url: str, locale: str = "zh") -> FetchResult:
        self.policy.assert_asset(url)
        return self._get(url, self.settings.max_asset_bytes, locale)

    def _get(self, url: str, max_bytes: int, locale: str) -> FetchResult:
        self.policy.assert_get(url, "GET")
        last_error: Exception | None = None
        last_status: int | None = None
        total_attempts = max(1, self.settings.retries)
        for attempt in range(1, total_attempts + 1):
            self.throttle.wait()
            try:
                return self._single_get(url, max_bytes, locale, attempt)
            except FetchError as exc:
                last_error = exc
                last_status = exc.status
                if not exc.retryable or attempt >= total_attempts:
                    raise FetchError(
                        str(exc),
                        url=url,
                        attempts=attempt,
                        status=exc.status,
                        retryable=exc.retryable,
                    ) from exc
            except requests.RequestException as exc:
                last_error = exc
                if attempt >= total_attempts:
                    break
            delay = min(8.0, (2 ** (attempt - 1)) * 0.75) + random.uniform(0.0, 0.25)
            time.sleep(delay)
        raise FetchError(
            f"GET failed after {total_attempts} attempts: {last_error}",
            url=url,
            attempts=total_attempts,
            status=last_status,
            retryable=True,
        ) from last_error

    def _single_get(self, url: str, max_bytes: int, locale: str, attempt: int) -> FetchResult:
        current = url
        for _redirect in range(6):
            self.policy.assert_get(current, "GET")
            response = requests.get(
                current,
                headers={
                    "User-Agent": self.user_agent,
                    "Accept": "text/html,application/xhtml+xml,image/avif,image/webp,image/*,*/*;q=0.8",
                    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.7" if locale == "zh" else "en-US,en;q=0.9,zh;q=0.4",
                    "Connection": "close",
                },
                timeout=self.settings.timeout_seconds,
                allow_redirects=False,
                stream=True,
            )
            try:
                if response.status_code in {301, 302, 303, 307, 308}:
                    location = response.headers.get("Location")
                    if not location:
                        raise FetchError(
                            f"Redirect without Location from {current}",
                            url=url,
                            attempts=attempt,
                            status=response.status_code,
                            retryable=False,
                        )
                    current = self.policy.absolute(location, current)
                    continue
                if response.status_code >= 400:
                    retryable = response.status_code in RETRYABLE_STATUS
                    raise FetchError(
                        f"HTTP {response.status_code} for {current}",
                        url=url,
                        attempts=attempt,
                        status=response.status_code,
                        retryable=retryable,
                    )
                declared_length = response.headers.get("Content-Length")
                if declared_length and int(declared_length) > max_bytes:
                    raise FetchError(
                        f"Response exceeds {max_bytes} bytes: {current}",
                        url=url,
                        attempts=attempt,
                        status=response.status_code,
                        retryable=False,
                    )
                chunks: list[bytes] = []
                size = 0
                for chunk in response.iter_content(chunk_size=64 * 1024):
                    if not chunk:
                        continue
                    size += len(chunk)
                    if size > max_bytes:
                        raise FetchError(
                            f"Response exceeds {max_bytes} bytes: {current}",
                            url=url,
                            attempts=attempt,
                            status=response.status_code,
                            retryable=False,
                        )
                    chunks.append(chunk)
                return FetchResult(
                    requested_url=url,
                    final_url=current,
                    status=response.status_code,
                    headers={key.lower(): value for key, value in response.headers.items()},
                    body=b"".join(chunks),
                    fetched_at=_utc_now(),
                    attempts=attempt,
                )
            finally:
                response.close()
        raise FetchError(
            f"Too many redirects for {url}",
            url=url,
            attempts=attempt,
            retryable=False,
        )
