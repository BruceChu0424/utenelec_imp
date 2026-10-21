"""Small, rate-limited client for public SHFE reports, never a generic URL fetcher."""

from __future__ import annotations

import hashlib
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

from .cli import atomic_json
from .data import BUSINESS_ZONE, InputError, instant, utc_text

HOST = "www.shfe.com.cn"
SYMBOLS = ("cu", "al", "ag")
MAX_RESPONSE = 5 * 1024 * 1024
PATHS = (
    r"/data/config/currentTradingday\.dat",
    r"/data/tradedata/future/dailydata/kx[0-9]{8}\.dat",
    r"/data/tradedata/future/delaymarket/delaymarket_(?:cu|al|ag)\.dat",
    r"/reports/tradedata/datadownload/download\.json",
)


class SourceError(RuntimeError):
    def __init__(self, code: str, retry_after: int = 0):
        super().__init__(code)
        self.code, self.retry_after = code, retry_after


def allowed_url(url: str) -> bool:
    parsed = urllib.parse.urlsplit(url)
    return (parsed.scheme == "https" and parsed.netloc == HOST and not parsed.query
            and not parsed.fragment and any(re.fullmatch(pattern, parsed.path) for pattern in PATHS))


class _SafeRedirect(urllib.request.HTTPRedirectHandler):
    max_redirections = 3

    def redirect_request(self, request, fp, code, message, headers, new_url):
        if not allowed_url(new_url):
            raise SourceError("INVALID_SOURCE")
        return super().redirect_request(request, fp, code, message, headers, new_url)


class ShfeClient:
    def __init__(self, minimum_interval: float = 1.0, stop: threading.Event | None = None):
        self.minimum_interval = minimum_interval
        self.stop = stop or threading.Event()
        self._next_request = 0.0
        self._opener = urllib.request.build_opener(_SafeRedirect())

    def get(self, path: str) -> dict | None:
        url = "https://" + HOST + path
        if not allowed_url(url):
            raise SourceError("INVALID_SOURCE")
        wait = max(0.0, self._next_request - time.monotonic())
        if self.stop.wait(wait):
            raise SourceError("NETWORK_ERROR")
        self._next_request = time.monotonic() + self.minimum_interval
        request = urllib.request.Request(url, headers={
            "User-Agent": "UtenIMP-MaterialForecast/2.0 public-report-client",
            "Accept": "application/json", "Accept-Encoding": "gzip",
        })
        try:
            with self._opener.open(request, timeout=10) as response:
                if response.status != 200 or not allowed_url(response.url):
                    raise SourceError("INVALID_SOURCE")
                length = response.headers.get("Content-Length")
                if length and int(length) > MAX_RESPONSE:
                    raise SourceError("INVALID_SOURCE")
                encoding = response.headers.get("Content-Encoding", "identity").lower()
                if encoding not in {"identity", "gzip"}:
                    raise SourceError("INVALID_SOURCE")
                decoder = zlib.decompressobj(16 + zlib.MAX_WBITS) if encoding == "gzip" else None
                chunks, compressed, expanded = [], 0, 0
                deadline = time.monotonic() + 30
                while True:
                    if self.stop.is_set() or time.monotonic() > deadline:
                        raise SourceError("NETWORK_ERROR")
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    compressed += len(chunk)
                    if compressed > MAX_RESPONSE:
                        raise SourceError("INVALID_SOURCE")
                    decoded = decoder.decompress(chunk, MAX_RESPONSE + 1 - expanded) if decoder else chunk
                    expanded += len(decoded)
                    if expanded > MAX_RESPONSE or decoder and decoder.unconsumed_tail:
                        raise SourceError("INVALID_SOURCE")
                    chunks.append(decoded)
                if decoder and (not decoder.eof or decoder.unused_data):
                    raise SourceError("INVALID_SOURCE")
                value = json.loads(b"".join(chunks).decode("utf-8-sig"))
                if not isinstance(value, dict):
                    raise SourceError("INVALID_SOURCE")
                return value
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            if exc.code in (403, 429):
                retry = exc.headers.get("Retry-After", "0")
                raise SourceError("RATE_LIMITED", min(21600, int(retry)) if retry.isdigit() else 0) from exc
            raise SourceError("NETWORK_ERROR") from exc
        except SourceError:
            raise
        except (OSError, ValueError, zlib.error) as exc:
            raise SourceError("INVALID_SOURCE" if isinstance(exc, (ValueError, zlib.error)) else "NETWORK_ERROR") from exc


def price(value, allow_zero: bool = False) -> Decimal:
    try:
        result = Decimal(str(value).strip())
    except (ValueError, InvalidOperation) as exc:
        raise SourceError("INVALID_SOURCE") from exc
    if not result.is_finite() or result < 0 or (not allow_zero and result == 0) or result > Decimal("1000000000000"):
        raise SourceError("INVALID_SOURCE")
    if len(result.as_tuple().digits) > 36 or result.as_tuple().exponent < -18:
        raise SourceError("INVALID_SOURCE")
    return result


def parse_daily(payload: dict, expected: date, now: datetime) -> list[dict]:
    try:
        reported = payload.get("report_date") or "".join(str(payload[key]).strip().zfill(2) for key in ("o_year", "o_month", "o_day"))
        if str(reported) != expected.strftime("%Y%m%d") or expected > now.astimezone(BUSINESS_ZONE).date():
            raise SourceError("INVALID_SOURCE")
        rows = payload["o_curinstrument"]
        if not isinstance(rows, list) or len(rows) > 20000:
            raise SourceError("INVALID_SOURCE")
        parsed, seen = [], set()
        for row in rows:
            if not isinstance(row, dict):
                raise SourceError("INVALID_SOURCE")
            symbol = str(row.get("PRODUCTGROUPID") or row.get("PRODUCTID", "")).strip().split("_")[0].lower()
            month = str(row.get("DELIVERYMONTH", "")).strip()
            if symbol not in SYMBOLS or not re.fullmatch(r"[0-9]{4}", month):
                continue
            if not 1 <= int(month[2:]) <= 12:
                raise SourceError("INVALID_SOURCE")
            contract = symbol + month
            if contract in seen:
                raise SourceError("INVALID_SOURCE")
            seen.add(contract)
            settlement = price(row.get("SETTLEMENTPRICE"), allow_zero=True)
            interest = price(row.get("OPENINTEREST"), allow_zero=True)
            if settlement == 0:
                continue
            parsed.append({"date": expected.isoformat(), "contract": contract,
                           "settlement": format(settlement, "f"), "open_interest": format(interest, "f")})
        if rows and not parsed:
            raise SourceError("INVALID_SOURCE")
        return parsed
    except (KeyError, TypeError, ValueError) as exc:
        raise SourceError("INVALID_SOURCE") from exc


def delivery_order(contract: str, report_day: date) -> tuple[int, int]:
    month = contract[-4:]
    year = report_day.year // 100 * 100 + int(month[:2])
    if year < report_day.year - 1:
        year += 100
    return year, int(month[2:])


def select_contract(previous: list[dict], current: list[dict], symbol: str, report_day: date) -> tuple[dict, dict] | None:
    candidates = [row for row in previous if row["contract"].startswith(symbol)
                  and price(row["open_interest"], True) > 0]
    if not candidates:
        return None
    ranked = sorted(candidates, key=lambda row: (-price(row["open_interest"], True), delivery_order(row["contract"], report_day)))
    selected = ranked[0]
    # Select before inspecting current prices. A missing winner is not replaced by a runner-up.
    present = next((row for row in current if row["contract"] == selected["contract"]), None)
    return (selected, present) if present is not None else None


def chain_points(indices: list[dict], symbol: str) -> list[dict]:
    result, index = [], Decimal("100")
    for previous, current in zip(indices, indices[1:]):
        if (not isinstance(previous.get("tradeSequence"), int) or
                current.get("tradeSequence") != previous["tradeSequence"] + 1):
            # A historical 404 is not proof that an actual trading session did not exist.
            result, index = [], Decimal("100")
            continue
        day = date.fromisoformat(current["date"])
        selected = select_contract(previous["rows"], current["rows"], symbol, day)
        if selected is None:
            result, index = [], Decimal("100")
            continue
        prior, actual = selected
        ratio = price(actual["settlement"]) / price(prior["settlement"])
        if ratio > 5 or ratio < Decimal("0.2"):
            raise SourceError("INVALID_SOURCE")
        index = index * ratio if result else Decimal("100")
        result.append({"day": day, "index": index, "settlement": price(actual["settlement"]),
                       "contract": actual["contract"]})
    return result


class ReportCache:
    """Immutable source versions plus a small current pointer; no imported date backdating."""

    def __init__(self, root: Path):
        self.root = root
        for directory in ("daily", "missing", "raw", "metadata"):
            (root / directory).mkdir(parents=True, exist_ok=True)

    def daily(self, day: date) -> dict | None:
        path = self.root / "daily" / (day.isoformat() + ".json")
        if not path.exists():
            return None
        value = json.loads(path.read_text(encoding="utf-8"))
        if value.get("date") != day.isoformat() or not isinstance(value.get("rows"), list):
            raise SourceError("INVALID_SOURCE")
        return value

    def missing(self, day: date) -> bool:
        return (self.root / "missing" / (day.isoformat() + ".json")).exists()

    def record_missing(self, day: date, now: datetime) -> None:
        atomic_json(self.root / "missing" / (day.isoformat() + ".json"), {"date": day.isoformat(), "checkedAt": utc_text(now)})

    def save(self, day: date, payload: dict, now: datetime) -> dict:
        rows = parse_daily(payload, day, now)
        if not rows:
            self.record_missing(day, now)
            return {"date": day.isoformat(), "rows": []}
        try:
            sequence = int(payload["o_trade_day"])
            if not 1 <= sequence <= 10000000:
                raise ValueError("invalid trading sequence")
        except (KeyError, TypeError, ValueError) as exc:
            raise SourceError("INVALID_SOURCE") from exc
        raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256(raw.encode()).hexdigest()
        folder = self.root / "raw" / day.isoformat()
        folder.mkdir(exist_ok=True)
        revision = folder / (digest + ".json")
        if not revision.exists():
            atomic_json(revision, {"firstObservedAt": utc_text(now), "fetchedAt": utc_text(now),
                                   "sha256": digest, "payload": payload})
        old = self.daily(day)
        pointer = {"date": day.isoformat(), "rows": rows, "sha256": digest, "tradeSequence": sequence,
                   "firstObservedAt": old["firstObservedAt"] if old else utc_text(now), "fetchedAt": utc_text(now)}
        atomic_json(self.root / "daily" / (day.isoformat() + ".json"), pointer)
        (self.root / "missing" / (day.isoformat() + ".json")).unlink(missing_ok=True)
        return pointer

    def record_document(self, key: str, payload: dict, now: datetime) -> None:
        if key not in {"download-manifest", "quote_cu", "quote_al", "quote_ag"}:
            raise SourceError("INVALID_SOURCE")
        material = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256(material.encode()).hexdigest()
        folder = self.root / "raw" / key
        folder.mkdir(exist_ok=True)
        path = folder / (digest + ".json")
        if not path.exists():
            atomic_json(path, {"firstObservedAt": utc_text(now), "fetchedAt": utc_text(now),
                               "sha256": digest, "payload": payload})


def load_benchmarks() -> list[dict]:
    path = Path(__file__).resolve().parents[3] / "server/src/main/resources/pricing/material-benchmarks.json"
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if (not isinstance(value, list) or len(value) != 3 or {x.get("symbol") for x in value} != set(SYMBOLS)
            or any(x.get("provider") != "SHFE_PUBLIC_DAILY" or x.get("seriesId") != f"shfe_{x.get('symbol')}_main_daily" for x in value)):
        raise InputError("built-in benchmark definitions are invalid")
    return value
