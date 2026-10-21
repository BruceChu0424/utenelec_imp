"""Strict imports and point-in-time reconstruction. No network code lives here."""

from __future__ import annotations

import csv
import hashlib
import io
import json
import re
from dataclasses import dataclass
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

MAX_CSV_BYTES = 8 * 1024 * 1024
MAX_ROWS = 50_000
SERIES_ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
COMMODITIES = {"COPPER", "ALUMINIUM", "SILVER", "POLYCARBONATE"}
BUSINESS_ZONE = ZoneInfo("Asia/Shanghai")
MANIFEST_FIELDS = (
    "seriesId", "name", "commodity", "market", "grade", "region", "currency",
    "unit", "priceBasis", "sourceName", "sourceUrl", "authorized", "rollPolicy",
)


class InputError(ValueError):
    """An actionable import error. The CLI never publishes a partial snapshot."""


def instant(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, TypeError) as exc:
        raise InputError("available_at must be an ISO 8601 timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise InputError("available_at must include a timezone")
    return parsed


def utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class Revision:
    day: date
    price: Decimal
    available_at: datetime

    def canonical(self) -> str:
        return f"{self.day.isoformat()},{format(self.price, 'f')},{utc_text(self.available_at)}"


@dataclass(frozen=True)
class Dataset:
    manifest: dict
    rows: tuple[Revision, ...]
    digest: str

    @property
    def first_publications(self) -> dict[date, Revision]:
        first: dict[date, Revision] = {}
        for row in self.rows:
            if row.day not in first or row.available_at < first[row.day].available_at:
                first[row.day] = row
        return first

    def as_of(self, cutoff: datetime, through: date | None = None) -> list[Revision]:
        """Choose the last revision actually available at the requested instant."""
        selected: dict[date, Revision] = {}
        for row in self.rows:
            if row.available_at <= cutoff and (through is None or row.day <= through):
                if row.day not in selected or row.available_at > selected[row.day].available_at:
                    selected[row.day] = row
        return [selected[day] for day in sorted(selected)]

    def row_hashes(self) -> list[str]:
        return [hashlib.sha256(row.canonical().encode()).hexdigest() for row in self.rows]


def read_manifest(path: Path, allow_synthetic: bool = False) -> dict:
    if path.stat().st_size > 64 * 1024:
        raise InputError("manifest exceeds 64 KiB")
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (ValueError, UnicodeError) as exc:
        raise InputError("manifest must be UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise InputError("manifest must be an object")
    unknown = set(value) - set(MANIFEST_FIELDS) - {"synthetic"}
    if unknown:
        raise InputError("unknown manifest fields: " + ", ".join(sorted(unknown)))
    for field in MANIFEST_FIELDS:
        if field in {"authorized", "rollPolicy"}:
            continue
        if not isinstance(value.get(field), str) or (field != "sourceUrl" and not value[field].strip()):
            raise InputError(f"manifest {field} is required")
        if len(value[field]) > (2048 if field == "sourceUrl" else 256):
            raise InputError(f"manifest {field} is too long")
        if any(ord(character) < 32 or 127 <= ord(character) <= 159 for character in value[field]):
            raise InputError(f"manifest {field} contains control characters")
        value[field] = value[field].strip()
    if not SERIES_ID.fullmatch(value["seriesId"]):
        raise InputError("seriesId must be 1..64 lowercase ASCII letters, digits, underscores or hyphens")
    if value["commodity"] not in COMMODITIES or value["market"] not in {"SPOT", "FUTURES"}:
        raise InputError("unsupported commodity or market")
    if value.get("authorized") is not True:
        raise InputError("authorized must explicitly be true for this data source")
    if not isinstance(value.get("synthetic", False), bool):
        raise InputError("synthetic must be a boolean")
    if value.get("synthetic", False) and not allow_synthetic:
        raise InputError("SYNTHETIC data is rejected; use --allow-synthetic only in an isolated test directory")
    policy = value.get("rollPolicy")
    if value["market"] == "FUTURES" and (not isinstance(policy, str) or not policy.strip()):
        raise InputError("futures require an explicit rollPolicy")
    if policy is not None and (not isinstance(policy, str) or len(policy) > 512
                               or any(ord(character) < 32 or 127 <= ord(character) <= 159 for character in policy)):
        raise InputError("rollPolicy must be a bounded string or null")
    value["rollPolicy"] = policy.strip() if isinstance(policy, str) else None
    if value["commodity"] == "POLYCARBONATE" and value["market"] != "SPOT":
        raise InputError("PC/POLYCARBONATE must be a SPOT series, never a PP/PVC futures proxy")
    url = urlparse(value["sourceUrl"])
    if value["sourceUrl"] and (url.scheme not in {"https", "http"} or not url.hostname or url.username or url.password or any(character.isspace() for character in value["sourceUrl"])):
        raise InputError("sourceUrl must be an HTTP(S) provenance URL without credentials")
    return value


def strict_csv_rows(raw: str):
    """A partially replaced quoted file must not become a valid new generation."""
    try:
        reader = csv.DictReader(io.StringIO(raw), strict=True)
        if reader.fieldnames != ["date", "price", "available_at"]:
            raise InputError("CSV header must be date,price,available_at in that order")
        yield from reader
    except csv.Error as exc:
        raise InputError("CSV is malformed or truncated; restore the complete source file") from exc


def dataset_digest(manifest: dict, rows) -> str:
    canonical = json.dumps(manifest, sort_keys=True, ensure_ascii=False) + "\n"
    canonical += "\n".join(row.canonical() for row in rows)
    return hashlib.sha256(canonical.encode()).hexdigest()


def read_dataset(manifest_path: Path, csv_path: Path, now: datetime,
                 allow_synthetic: bool = False) -> Dataset:
    manifest = read_manifest(manifest_path, allow_synthetic)
    if csv_path.stat().st_size > MAX_CSV_BYTES:
        raise InputError("CSV exceeds 8 MiB")
    try:
        raw = csv_path.read_text(encoding="utf-8-sig")
    except UnicodeError as exc:
        raise InputError("CSV must be UTF-8") from exc
    rows: list[Revision] = []
    seen: set[tuple[date, datetime]] = set()
    for line, entry in enumerate(strict_csv_rows(raw), 2):
        if len(rows) >= MAX_ROWS:
            raise InputError("CSV exceeds 50000 revisions")
        if None in entry or any(value is None for value in entry.values()):
            raise InputError(f"CSV row {line} has an invalid column count")
        if len(entry["price"]) > 48:
            raise InputError(f"CSV row {line} price precision is excessive")
        try:
            day = date.fromisoformat(entry["date"])
            price = Decimal(entry["price"])
        except (ValueError, InvalidOperation) as exc:
            raise InputError(f"CSV row {line} has invalid date or price") from exc
        published = instant(entry["available_at"])
        if not price.is_finite() or not Decimal("0.00000001") <= price <= Decimal("1000000000000"):
            raise InputError(f"CSV row {line} price is not positive, finite and plausible")
        if len(price.as_tuple().digits) > 36 or price.as_tuple().exponent < -18:
            raise InputError(f"CSV row {line} price precision is excessive")
        if published > now:
            raise InputError(f"CSV row {line} publication is in the future")
        if day > now.astimezone(BUSINESS_ZONE).date():
            raise InputError(f"CSV row {line} observation date is in the future")
        if published.astimezone(BUSINESS_ZONE).date() < day:
            raise InputError(f"CSV row {line} publication precedes its observation date")
        key = (day, published)
        if key in seen:
            raise InputError(f"CSV row {line} duplicates date+available_at")
        seen.add(key)
        rows.append(Revision(day, price, published))
    if not rows:
        raise InputError("CSV has no observations; no snapshot produced")
    # Detect obvious scale/unit changes, including an implausible appended revision.
    by_day: dict[date, list[Revision]] = {}
    for row in rows:
        by_day.setdefault(row.day, []).append(row)
    first_prices = []
    for day in sorted(by_day):
        revisions = sorted(by_day[day], key=lambda row: row.available_at)
        first_prices.append(revisions[0].price)
        if max(row.price for row in revisions) / min(row.price for row in revisions) > 5:
            raise InputError("implausible revision price change; check units/source")
    for left, right in zip(first_prices, first_prices[1:]):
        if max(left, right) / min(left, right) > 5:
            raise InputError("implausible adjacent price change; check units/source")
    return Dataset(manifest, tuple(rows), dataset_digest(manifest, rows))


def ledger_payload(dataset: Dataset) -> dict:
    return {"manifest": dataset.manifest, "rows": dataset.row_hashes(), "digest": dataset.digest}


def require_append_only(dataset: Dataset, previous: dict | None) -> None:
    if previous is None:
        return
    old_rows = previous.get("rows")
    if (set(previous) != {"manifest", "rows", "digest"}
            or not isinstance(old_rows, list) or not old_rows
            or any(not isinstance(value, str) or re.fullmatch(r"[a-f0-9]{64}", value) is None
                   for value in old_rows)):
        raise InputError("import ledger is invalid; restore its trusted backup")
    if previous.get("manifest") != dataset.manifest:
        raise InputError("manifest identity changed; create a new seriesId for a new source/basis")
    hashes = dataset.row_hashes()
    if hashes[:len(old_rows)] != old_rows:
        raise InputError("append-only import violated: retain every old CSV row in its original order")
    # Validate the ledger against its complete canonical prefix. Merely matching
    # a prefix of row hashes lets a truncated/empty ledger erase import history.
    if previous.get("digest") != dataset_digest(dataset.manifest, dataset.rows[:len(old_rows)]):
        raise InputError("import ledger digest is invalid; restore its trusted backup")
