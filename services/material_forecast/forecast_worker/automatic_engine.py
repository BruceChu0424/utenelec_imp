"""Explicit retrospective forecasts for the automatically collected SHFE chain.

The collector owns actual observed timestamps and immutable raw revisions. The
nominal historical publication instants below exist only inside labelled replay;
they are never written back as historical first-observed evidence.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import date, datetime, time, timezone
from decimal import Decimal, InvalidOperation, localcontext
from importlib.metadata import version
from zoneinfo import ZoneInfo

from . import __version__
from .data import Dataset, InputError, MANIFEST_FIELDS, Revision, utc_text
from .engine import build_snapshot

SHANGHAI = ZoneInfo("Asia/Shanghai")
MAX_CHAIN_POINTS = 5000
PRICE_LIMIT = Decimal("1000000000000000")
OUTPUT_QUANTUM = Decimal("0.000001")
SYMBOLS = {
    "cu": ("COPPER", "吨"),
    "al": ("ALUMINIUM", "吨"),
    "ag": ("SILVER", "千克"),
}


def _instant(value: datetime, label: str) -> datetime:
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise InputError(f"{label} must be timezone aware")
    return value.astimezone(timezone.utc)


def _positive(value: object, label: str) -> Decimal:
    if isinstance(value, bool):
        raise InputError(f"invalid {label}")
    try:
        parsed = Decimal(str(value))
    except (ValueError, InvalidOperation) as error:
        raise InputError(f"invalid {label}") from error
    if not parsed.is_finite() or not 0 < parsed <= PRICE_LIMIT:
        raise InputError(f"invalid {label}")
    return parsed


def _scale(value: str | None, factor: Decimal) -> str | None:
    if value is None:
        return None
    with localcontext() as context:
        context.prec = 80
        amount = (Decimal(value) * factor).quantize(OUTPUT_QUANTUM)
    if not amount.is_finite() or amount < 0 or amount > PRICE_LIMIT:
        raise InputError("forecast exceeds the supported price range")
    return format(amount, "f").rstrip("0").rstrip(".") if amount else "0"


def build_automatic_snapshot(
    benchmark: dict,
    chain_points: list[dict],
    now: datetime,
    digest: str,
    source_fetched_at: datetime,
) -> dict:
    """Fit the forward chain and report estimates in the current contract level.

    A passed final-history replay is RESEARCH_ONLY, never READY. In particular,
    importing a public historical file today does not fabricate point-in-time
    validation or an actionable procurement recommendation.
    """
    now = _instant(now, "now")
    source_fetched_at = _instant(source_fetched_at, "source_fetched_at")
    if source_fetched_at > now:
        raise InputError("source fetched timestamp is in the future")
    symbol = benchmark.get("symbol")
    if symbol not in SYMBOLS or benchmark.get("provider") != "SHFE_PUBLIC_DAILY":
        raise InputError("unsupported automatic benchmark")
    commodity, unit = SYMBOLS[symbol]
    if (benchmark.get("commodity") != commodity or benchmark.get("currency") != "CNY"
            or benchmark.get("unit") != unit or benchmark.get("market") != "FUTURES"
            or benchmark.get("seriesId") != f"shfe_{symbol}_main_daily"):
        raise InputError("automatic benchmark identity does not match its quote denomination")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise InputError("invalid automatic source digest")
    if not chain_points or len(chain_points) > MAX_CHAIN_POINTS:
        raise InputError("automatic history must contain 1..5000 chain observations")

    manifest = {key: benchmark.get(key) for key in MANIFEST_FIELDS}
    manifest["authorized"] = True  # Explicit operator-enabled public collector; not a resale license.
    for key, value in manifest.items():
        if key != "authorized" and (not isinstance(value, str) or not value.strip()):
            raise InputError(f"automatic benchmark is missing {key}")

    revisions: list[Revision] = []
    canonical_points = []
    previous_day = None
    latest_settlement = latest_index = None
    for point in chain_points:
        day = point.get("day")
        if not isinstance(day, date) or isinstance(day, datetime):
            raise InputError("chain day must be an explicit date")
        if previous_day is not None and day <= previous_day:
            raise InputError("chain observations must be strictly chronological")
        if day > source_fetched_at.astimezone(SHANGHAI).date():
            raise InputError("chain observation occurs after its source fetch")
        contract = point.get("contract")
        if not isinstance(contract, str) or not re.fullmatch(symbol + r"[0-9]{4}", contract):
            raise InputError("chain contract does not match the benchmark")
        index = _positive(point.get("index"), "chain index")
        settlement = _positive(point.get("settlement"), "settlement")
        # 18:00 is a conservative replay convention, not an asserted publication
        # vintage. A same-day completed report is already available when fetched.
        replay_available = min(datetime.combine(day, time(18), SHANGHAI), source_fetched_at)
        revisions.append(Revision(day, index, replay_available))
        canonical_points.append({
            "day": day.isoformat(), "contract": contract,
            "index": format(index, "f"), "settlement": format(settlement, "f"),
        })
        previous_day, latest_index, latest_settlement = day, index, settlement

    material = json.dumps({"manifest": manifest, "source": digest, "chain": canonical_points},
                          sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    replay_digest = hashlib.sha256(material.encode("utf-8")).hexdigest()
    try:
        result = build_snapshot(Dataset(manifest, tuple(revisions), replay_digest), now)
    except Exception:
        # A numerical/model failure must not prevent publication of a sound,
        # independently parsed market settlement. No fallback forecast is invented.
        result = {
            "schemaVersion": 1, **manifest,
            "dataAsOf": revisions[-1].day.isoformat(), "generatedAt": utc_text(now),
            "latestPrice": format(latest_index, "f"), "status": "INSUFFICIENT",
            "reasonCodes": ["MODEL_FAILED"],
            "modelVersion": "UNAVAILABLE/worker-" + __version__,
            "libraryVersion": version("statsforecast"), "datasetDigest": replay_digest,
            "validation": {"passed": False, "baselineMAE": None, "modelMAE": None,
                           "folds": 0, "coverage80": None,
                           "backtestStart": None, "backtestEnd": None},
            "forecasts": [], "procurementSignal": "INSUFFICIENT",
        }
    with localcontext() as context:
        context.prec = 80
        factor = latest_settlement / latest_index

    result.update({
        "schemaVersion": 2,
        "latestPrice": format(latest_settlement, "f"),
        "validationBasis": "LATEST_HISTORY_REPLAY",
        "modelPriceBasis": "CHAIN_LINKED_CURRENT_ANCHOR",
        "quoteContract": chain_points[-1]["contract"],
        "sourceFetchedAt": utc_text(source_fetched_at),
        "historyRecordCount": len(chain_points),
        "procurementSignal": "INSUFFICIENT",
    })
    if result["status"] == "READY":
        result["status"] = "RESEARCH_ONLY"
    result["reasonCodes"] = list(dict.fromkeys([
        *result["reasonCodes"], "LATEST_HISTORY_REPLAY", "ROLL_ADJUSTED_BASIS",
    ]))
    for field in ("baselineMAE", "modelMAE"):
        result["validation"][field] = _scale(result["validation"][field], factor)
    for prediction in result["forecasts"]:
        for field in ("price", "lower80", "upper80"):
            prediction[field] = _scale(prediction[field], factor)
        lower, upper = Decimal(prediction["lower80"]), Decimal(prediction["upper80"])
        if result["status"] != "RESEARCH_ONLY":
            prediction["direction"] = "UNCERTAIN"
        else:
            prediction["direction"] = ("UP" if lower > latest_settlement else
                                       "DOWN" if upper < latest_settlement else "UNCERTAIN")
    return result
