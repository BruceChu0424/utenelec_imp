from __future__ import annotations

import hashlib
import io
import json
import mimetypes
import os
import re
import threading
import time
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlsplit

from PIL import Image, UnidentifiedImageError

from .config import CHECKPOINT_VERSION
from .policy import canonical_url
from .transport import FetchResult, decode_html


def utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_has_sha256(path: Path, expected: str) -> bool:
    try:
        return path.is_file() and sha256_bytes(path.read_bytes()) == expected
    except OSError:
        return False


def normalized_absolute_path(path: str | os.PathLike[str]) -> Path:
    """Make Windows extended-length and ordinary absolute paths comparable."""

    raw = os.path.realpath(os.fspath(path))
    if raw.startswith("\\\\?\\UNC\\"):
        raw = "\\\\" + raw[8:]
    elif raw.startswith("\\\\?\\"):
        raw = raw[4:]
    return Path(os.path.normpath(raw))


def path_is_within(path: Path, root: Path) -> bool:
    try:
        normalized_path = os.path.normcase(os.fspath(normalized_absolute_path(path)))
        normalized_root = os.path.normcase(os.fspath(normalized_absolute_path(root)))
        return os.path.commonpath([normalized_path, normalized_root]) == normalized_root
    except ValueError:
        return False


def atomic_write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def atomic_write_json(path: Path, value: object) -> None:
    data = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    atomic_write_bytes(path, data)


def source_metadata(record: dict | None) -> dict | None:
    if not record or record.get("status") != "ok":
        return None
    return {
        "sourceUrl": record["sourceUrl"],
        "finalUrl": record.get("finalUrl", record["sourceUrl"]),
        "scrapedAt": record["scrapedAt"],
        "sourceHash": record["sourceHash"],
        "rawHtmlPath": record["rawHtmlPath"],
        "httpStatus": record.get("httpStatus", 200),
    }


class CheckpointStore:
    def __init__(self, output_dir: Path, base_url: str, *, resume: bool = True) -> None:
        self.root = normalized_absolute_path(output_dir)
        self.root.mkdir(parents=True, exist_ok=True)
        self.checkpoint_path = self.root / "checkpoint.json"
        self._lock = threading.RLock()
        self._dirty = 0
        self._last_save = 0.0
        if self.checkpoint_path.exists():
            if not resume:
                raise RuntimeError(
                    f"Checkpoint already exists at {self.checkpoint_path}; use --resume or a new output directory"
                )
            self.data = json.loads(self.checkpoint_path.read_text(encoding="utf-8"))
            if self.data.get("checkpointVersion") != CHECKPOINT_VERSION:
                raise RuntimeError(
                    f"Unsupported checkpointVersion {self.data.get('checkpointVersion')!r}; "
                    f"expected {CHECKPOINT_VERSION}"
                )
            if self.data.get("baseUrl") != base_url:
                raise RuntimeError(
                    f"Checkpoint base URL {self.data.get('baseUrl')!r} does not match {base_url!r}"
                )
            self.data.setdefault("diagnostics", {"fetchErrors": [], "parseErrors": [], "conflicts": []})
            self.data.setdefault("refusedUrls", [])
            self.data.setdefault("pages", {})
            self.data.setdefault("media", {})
            if not isinstance(self.data["pages"], dict):
                self.data["pages"] = {}
            if not isinstance(self.data["media"], dict):
                self.data["media"] = {}
        else:
            self.data = {
                "checkpointVersion": CHECKPOINT_VERSION,
                "baseUrl": base_url,
                "createdAt": utc_now(),
                "updatedAt": utc_now(),
                "pages": {},
                "media": {},
                "refusedUrls": [],
                "diagnostics": {"fetchErrors": [], "parseErrors": [], "conflicts": []},
            }

    def _relative(self, path: Path) -> str:
        resolved = normalized_absolute_path(path)
        if not path_is_within(resolved, self.root):
            raise RuntimeError(f"Path escaped output directory: {resolved}")
        return Path(os.path.relpath(resolved, self.root)).as_posix()

    def resolve_relative(self, relative: str) -> Path:
        resolved = normalized_absolute_path(self.root / relative)
        if not path_is_within(resolved, self.root):
            raise RuntimeError(f"Checkpoint path escaped output directory: {relative}")
        return resolved

    def _mark_dirty(self) -> None:
        self._dirty += 1
        self.data["updatedAt"] = utc_now()

    def save(self, *, force: bool = False) -> None:
        with self._lock:
            if not self._dirty and self.checkpoint_path.exists():
                return
            now = time.monotonic()
            if not force and self._dirty < 12 and now - self._last_save < 2.0:
                return
            atomic_write_json(self.checkpoint_path, self.data)
            self._dirty = 0
            self._last_save = now

    def flush(self) -> None:
        self.save(force=True)

    def cached_page(self, url: str) -> tuple[dict, bytes, str] | None:
        key = canonical_url(url)
        with self._lock:
            record = self.data["pages"].get(key)
            if not isinstance(record, dict) or record.get("status") != "ok":
                return None
            try:
                path = self.resolve_relative(record["rawHtmlPath"])
                if not path.exists():
                    return None
                body = path.read_bytes()
                if sha256_bytes(body) != record.get("sourceHash"):
                    return None
                text, _encoding = decode_html(body, record.get("contentType", ""))
            except (KeyError, OSError, RuntimeError, ValueError, TypeError):
                return None
            return dict(record), body, text

    def put_page(self, url: str, kind: str, locale: str, result: FetchResult) -> tuple[dict, str]:
        digest = sha256_bytes(result.body)
        path = self.root / "raw" / "html" / locale / kind / f"{digest}.html"
        text, encoding = decode_html(result.body, result.headers.get("content-type", ""))
        record = {
            "status": "ok",
            "sourceUrl": url,
            "finalUrl": result.final_url,
            "scrapedAt": result.fetched_at,
            "sourceHash": digest,
            "rawHtmlPath": self._relative(path),
            "httpStatus": result.status,
            "contentType": result.headers.get("content-type", ""),
            "encoding": encoding,
            "bytes": len(result.body),
            "attempts": result.attempts,
            "kind": kind,
            "locale": locale,
        }
        with self._lock:
            if not file_has_sha256(path, digest):
                atomic_write_bytes(path, result.body)
            self.data["pages"][canonical_url(url)] = record
            self._mark_dirty()
            self.save()
        return dict(record), text

    def put_page_error(
        self,
        url: str,
        kind: str,
        locale: str,
        error: Exception,
        *,
        status: int | None = None,
        attempts: int | None = None,
        retryable: bool | None = None,
    ) -> dict:
        record = {
            "status": "error",
            "sourceUrl": url,
            "failedAt": utc_now(),
            "error": f"{type(error).__name__}: {error}",
            "httpStatus": status,
            "attempts": attempts,
            "retryable": retryable,
            "kind": kind,
            "locale": locale,
        }
        with self._lock:
            self.data["pages"][canonical_url(url)] = record
            self._mark_dirty()
            self.save()
        return dict(record)

    def cached_media(self, url: str) -> dict | None:
        with self._lock:
            record = self.data["media"].get(canonical_url(url))
            if not isinstance(record, dict) or record.get("status") != "ok":
                return None
            try:
                path = self.resolve_relative(record["localPath"])
                if not path.exists() or sha256_bytes(path.read_bytes()) != record.get("sha256"):
                    return None
            except (KeyError, OSError, RuntimeError, ValueError, TypeError):
                return None
            return dict(record)

    def put_media(self, url: str, result: FetchResult) -> dict:
        metadata = inspect_asset(result.body, result.content_type, url)
        digest = sha256_bytes(result.body)
        extension = metadata["extension"]
        path = self.root / "media" / digest[:2] / f"{digest}{extension}"
        record = {
            "status": "ok",
            "sourceUrl": url,
            "finalUrl": result.final_url,
            "scrapedAt": result.fetched_at,
            "sha256": digest,
            "mimeType": metadata["mimeType"],
            "extension": extension,
            "bytes": len(result.body),
            "width": metadata.get("width"),
            "height": metadata.get("height"),
            "localPath": self._relative(path),
            "httpStatus": result.status,
            "attempts": result.attempts,
        }
        with self._lock:
            if not file_has_sha256(path, digest):
                atomic_write_bytes(path, result.body)
            self.data["media"][canonical_url(url)] = record
            self._mark_dirty()
            self.save()
        return dict(record)

    def put_media_error(
        self,
        url: str,
        error: Exception,
        *,
        status: int | None = None,
        attempts: int | None = None,
        retryable: bool | None = None,
    ) -> dict:
        record = {
            "status": "error",
            "sourceUrl": url,
            "failedAt": utc_now(),
            "error": f"{type(error).__name__}: {error}",
            "httpStatus": status,
            "attempts": attempts,
            "retryable": retryable,
        }
        with self._lock:
            self.data["media"][canonical_url(url)] = record
            self._mark_dirty()
            self.save()
        return dict(record)

    def add_refused_url(self, url: str, reason: str) -> None:
        with self._lock:
            item = {"url": url, "reason": reason, "refusedAt": utc_now()}
            if item not in self.data["refusedUrls"]:
                self.data["refusedUrls"].append(item)
                self._mark_dirty()
                self.save()

    def set_diagnostics(
        self,
        *,
        fetch_errors: list[dict],
        parse_errors: list[dict],
        conflicts: list[dict],
    ) -> None:
        with self._lock:
            self.data["diagnostics"] = {
                "fetchErrors": list(fetch_errors),
                "parseErrors": list(parse_errors),
                "conflicts": list(conflicts),
            }
            self._mark_dirty()
            self.save(force=True)


def inspect_asset(body: bytes, header_mime: str, source_url: str) -> dict:
    header_mime = (header_mime or "").split(";", 1)[0].strip().lower()
    lowered_prefix = body[:512].lstrip().lower()
    if lowered_prefix.startswith((b"<html", b"<!doctype html", b"<script")):
        raise ValueError(f"HTML response cannot be stored as an asset: {source_url}")

    try:
        with Image.open(io.BytesIO(body)) as image:
            image.verify()
        with Image.open(io.BytesIO(body)) as image:
            width, height = image.size
            image_format = (image.format or "").upper()
        mime = Image.MIME.get(image_format) or header_mime or "application/octet-stream"
        extension = {
            "JPEG": ".jpg",
            "PNG": ".png",
            "GIF": ".gif",
            "WEBP": ".webp",
            "BMP": ".bmp",
            "TIFF": ".tiff",
            "ICO": ".ico",
        }.get(image_format, mimetypes.guess_extension(mime) or ".bin")
        return {"mimeType": mime, "extension": extension, "width": width, "height": height}
    except (UnidentifiedImageError, OSError, SyntaxError):
        pass

    text_prefix = body[:8192].decode("utf-8", errors="ignore").lstrip()
    if text_prefix.startswith("<?xml") or text_prefix.lower().startswith("<svg"):
        svg_match = re.search(r"<svg\b([^>]*)>", text_prefix, re.IGNORECASE)
        if svg_match:
            attrs = svg_match.group(1)
            width_match = re.search(r"\bwidth=['\"]?([0-9.]+)", attrs, re.IGNORECASE)
            height_match = re.search(r"\bheight=['\"]?([0-9.]+)", attrs, re.IGNORECASE)
            width = int(float(width_match.group(1))) if width_match else None
            height = int(float(height_match.group(1))) if height_match else None
            if (not width or not height) and (
                viewbox_match := re.search(
                    r"\bviewBox=['\"]\s*[-0-9.]+\s+[-0-9.]+\s+([0-9.]+)\s+([0-9.]+)",
                    attrs,
                    re.IGNORECASE,
                )
            ):
                width = width or int(float(viewbox_match.group(1)))
                height = height or int(float(viewbox_match.group(2)))
            return {
                "mimeType": "image/svg+xml",
                "extension": ".svg",
                "width": width,
                "height": height,
            }

    suffix = Path(urlsplit(source_url).path).suffix.lower()
    magic_mime: str | None = None
    if body.startswith(b"%PDF-"):
        magic_mime = "application/pdf"
        suffix = ".pdf"
    elif body.startswith(b"PK\x03\x04"):
        magic_mime = header_mime or "application/zip"
        suffix = suffix if suffix in {".docx", ".xlsx", ".zip"} else ".zip"
    elif body.startswith(b"Rar!\x1a\x07"):
        magic_mime = "application/vnd.rar"
        suffix = ".rar"
    elif suffix in {".doc", ".xls"} and body.startswith(b"\xd0\xcf\x11\xe0"):
        magic_mime = header_mime or "application/x-ole-storage"
    if not magic_mime:
        raise ValueError(f"Unrecognized or corrupt asset content: {source_url}")
    return {
        "mimeType": magic_mime,
        "extension": suffix or mimetypes.guess_extension(magic_mime) or ".bin",
        "width": None,
        "height": None,
    }
