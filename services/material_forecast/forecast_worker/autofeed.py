"""Independent SHFE collector. Global benchmarks only; no ERP credentials or facts."""

from __future__ import annotations

import hashlib
import json
import signal
import sys
import threading
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

from . import __version__
from .cli import atomic_json, series_lock
from .data import BUSINESS_ZONE, instant, utc_text
from .locking import register_write_barrier
from .shfe import ReportCache, ShfeClient, SourceCancelled, SourceError, chain_points, load_benchmarks, price


class AutoFeed:
    def __init__(self, output_directory: Path, *, client=None, now=None,
                 history_days: int = 1200, backfill_budget: int = 30,
                 interval: int = 900, continuous: bool = False,
                 config_revision: str | None = None, run_id: str | None = None):
        self.output = output_directory
        output_directory.mkdir(parents=True, exist_ok=True)
        register_write_barrier(output_directory)
        self.cache = ReportCache(output_directory / ".auto-feed")
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.stop = threading.Event()
        self.client = client or ShfeClient(stop=self.stop)
        self.history_days, self.budget, self.interval = history_days, backfill_budget, interval
        self.continuous = continuous
        self.config_revision, self.run_id = config_revision, run_id
        self.benchmarks = load_benchmarks()
        self.state_path = self.cache.root / "state.json"
        self.state = json.loads(self.state_path.read_text(encoding="utf-8")) if self.state_path.exists() else {}
        self.health_lock = threading.Lock()
        self.health = {item["seriesId"]: {
            "seriesId": item["seriesId"], "status": "IDLE", "lastAttemptAt": None,
            "lastSuccessAt": self.state.get("lastSuccessAt", {}).get(item["seriesId"]),
            "nextSyncAt": None, "errorCode": None,
        } for item in self.benchmarks}

    def heartbeat(self, **changes) -> None:
        with self.health_lock:
            for item in self.health.values():
                item.update(changes)
            atomic_json(self.output / "auto-feed-health.json", {
                "schemaVersion": 1, "workerVersion": __version__, "generatedAt": utc_text(self.now()),
                "autoUpdateEnabled": self.continuous and not self.stop.is_set(),
                "series": list(self.health.values()),
                **({"configRevision": self.config_revision, "runId": self.run_id} if self.config_revision else {}),
            }, public=True)

    def _heartbeat_loop(self) -> None:
        while not self.stop.wait(30):
            self.heartbeat()

    def _managed_stop_loop(self) -> None:
        expected = ("STOP " + self.run_id).encode("ascii")
        while not self.stop.is_set():
            line = sys.stdin.buffer.readline(80)
            if not line:
                # This loop exists only for an owned managed run. EOF means its
                # supervisor disappeared; release the collector lease rather
                # than leave an orphan blocking the next application process.
                self.stop.set()
                return
            if line.rstrip(b"\r\n") == expected:
                self.stop.set()
                return

    def _check_cancelled(self) -> None:
        if self.stop.is_set():
            raise SourceCancelled()

    def daily(self, day: date, *, refresh: bool = False) -> dict | None:
        self._check_cancelled()
        old = self.cache.daily(day)
        if old and not refresh:
            return old
        if not refresh and self.cache.missing(day):
            return None
        value = self.client.get("/data/tradedata/future/dailydata/kx" + day.strftime("%Y%m%d") + ".dat")
        if value is None:
            # A not-yet-published current report must be retried next cycle.
            if day < self.now().astimezone(BUSINESS_ZONE).date() - timedelta(days=2):
                self.cache.record_missing(day, self.now())
            return old
        saved = self.cache.save(day, value, self.now())
        return saved if saved["rows"] else None

    def latest_pair(self) -> date:
        config = self.client.get("/data/config/currentTradingday.dat")
        if config is None:
            raise SourceError("INVALID_SOURCE")
        try:
            latest = datetime.strptime(config["lastTradingday"], "%Y%m%d").date()
            current = datetime.strptime(config["currentTradingday"], "%Y%m%d").date()
        except (ValueError, KeyError, TypeError) as exc:
            raise SourceError("INVALID_SOURCE") from exc
        local = self.now().astimezone(BUSINESS_ZONE)
        if latest > local.date() or current < latest or current > local.date() + timedelta(days=15):
            raise SourceError("INVALID_SOURCE")
        if current <= local.date() and local.time().replace(tzinfo=None) >= time(15, 15):
            if self.daily(current, refresh=True):
                latest = current
            elif not self.daily(latest, refresh=True):
                raise SourceError("INVALID_SOURCE")
        elif not self.daily(latest, refresh=True):
            raise SourceError("INVALID_SOURCE")
        # Only prior-day OI may choose a contract. Find that completed trading day.
        for offset in range(1, 20):
            self._check_cancelled()
            day = latest - timedelta(days=offset)
            if day.weekday() >= 5:
                continue
            if self.daily(day):
                return latest
        raise SourceError("INVALID_SOURCE")

    def contiguous_indices(self, latest: date) -> list[dict]:
        indices = []
        day, start = latest, latest - timedelta(days=self.history_days)
        while day >= start:
            self._check_cancelled()
            cached = self.cache.daily(day)
            if cached:
                indices.append(cached)
            elif day.weekday() < 5 and not self.cache.missing(day):
                break
            day -= timedelta(days=1)
        return list(reversed(indices))

    def backfill(self, latest: date) -> bool:
        self.heartbeat(status="BACKFILLING")
        start, day, requested = latest - timedelta(days=self.history_days), latest, 0
        while day >= start and not self.stop.is_set():
            if day.weekday() < 5 and not self.cache.daily(day) and not self.cache.missing(day):
                if requested >= self.budget:
                    break
                self.daily(day)
                requested += 1
            day -= timedelta(days=1)
        self._check_cancelled()
        self.state["backfillCursor"] = day.isoformat()
        self.state["historyStart"] = start.isoformat()
        return requested > 0

    def archive_manifest(self) -> None:
        """Discover official archives without downloading/extracting the large all-product ZIPs."""
        self._check_cancelled()
        path = self.cache.root / "metadata" / "download-manifest.json"
        if path.exists():
            cached = json.loads(path.read_text(encoding="utf-8"))
            if self.now() - instant(cached["fetchedAt"]) < timedelta(days=7):
                return
        value = self.client.get("/reports/tradedata/datadownload/download.json")
        self._check_cancelled()
        if value is None or not isinstance(value.get("data"), dict):
            raise SourceError("INVALID_SOURCE")
        self.cache.record_document("download-manifest", value, self.now())
        atomic_json(path, {"firstObservedAt": utc_text(self.now()), "fetchedAt": utc_text(self.now()), "payload": value})

    def publish_models(self, indices: list[dict]) -> dict[str, str]:
        from .automatic_engine import build_automatic_snapshot

        self.heartbeat(status="MODEL")
        digest = hashlib.sha256(json.dumps([(item["date"], item["sha256"]) for item in indices]).encode()).hexdigest()
        selected = {}
        for benchmark in self.benchmarks:
            self._check_cancelled()
            points = chain_points(indices, benchmark["symbol"])
            if not points:
                continue
            series = benchmark["seriesId"]
            selected[series] = points[-1]["contract"]
            previous = self.state.get("models", {}).get(series, {})
            path = self.output / (series + ".json")
            due = (not path.exists() or previous.get("digest") != digest or
                   not previous.get("generatedAt") or self.now() - instant(previous["generatedAt"]) >= timedelta(hours=12))
            if due:
                try:
                    snapshot = build_automatic_snapshot(benchmark, points, self.now(), digest, instant(indices[-1]["fetchedAt"]))
                    self._check_cancelled()
                    if snapshot.get("schemaVersion") != 2 or snapshot.get("status") == "READY" or snapshot.get("procurementSignal") != "INSUFFICIENT":
                        raise ValueError("automatic model contract violated")
                    issued_digest = hashlib.sha256(json.dumps(snapshot, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
                    issued_directory = self.cache.root / "issued" / series
                    issued_directory.mkdir(parents=True, exist_ok=True)
                    issued_path = issued_directory / (issued_digest + ".json")
                    if not issued_path.exists():
                        # Preserve what was actually issued for later prospective analysis.
                        # This archive does not by itself constitute a passed forward validation.
                        atomic_json(issued_path, snapshot)
                    atomic_json(path, snapshot, public=True)
                except (ValueError, ArithmeticError, RuntimeError) as exc:
                    raise SourceError("MODEL_FAILED") from exc
                self.state.setdefault("models", {})[series] = {"digest": digest, "generatedAt": snapshot["generatedAt"]}
            with self.health_lock:
                self.health[series]["lastSuccessAt"] = utc_text(self.now())
        return selected

    def publish_quotes(self, selected: dict[str, str]) -> None:
        self.heartbeat(status="FETCHING")
        for benchmark in self.benchmarks:
            self._check_cancelled()
            series = benchmark["seriesId"]
            contract = selected.get(series)
            if not contract:
                continue
            payload = self.client.get("/data/tradedata/future/delaymarket/delaymarket_" + benchmark["symbol"] + ".dat")
            self._check_cancelled()
            if payload is None or not isinstance(payload.get("delaymarket"), list) or len(payload["delaymarket"]) > 1000:
                raise SourceError("INVALID_SOURCE")
            rows = [item for item in payload["delaymarket"] if isinstance(item, dict) and str(item.get("contractname", "")).strip() == contract]
            if len(rows) != 1:
                continue
            row, now = rows[0], self.now()
            try:
                market_time = datetime.strptime(row["updatetime"], "%Y-%m-%d %H:%M:%S").replace(tzinfo=BUSINESS_ZONE)
            except (KeyError, TypeError, ValueError) as exc:
                raise SourceError("INVALID_SOURCE") from exc
            if market_time > now or str(row.get("instrumentid", "")).strip() != benchmark["symbol"]:
                raise SourceError("INVALID_SOURCE")
            amount = price(row.get("lastprice"))
            self.cache.record_document("quote_" + benchmark["symbol"], payload, now)
            quote = {"schemaVersion": 1, "seriesId": series, "contract": contract,
                     "price": format(amount, "f"), "currency": benchmark["currency"], "unit": benchmark["unit"],
                     "marketTime": utc_text(market_time), "fetchedAt": utc_text(now),
                     "delayMinutes": 30, "provider": "SHFE_PUBLIC_DAILY"}
            atomic_json(self.output / (series + ".quote.json"), quote, public=True)
            with self.health_lock:
                self.health[series]["lastSuccessAt"] = utc_text(now)

    def run_cycle(self) -> bool:
        if self.stop.is_set():
            return False
        now = self.now()
        retry_at = self.state.get("retryNotBefore")
        if retry_at and now < instant(retry_at):
            self.heartbeat(status="ERROR", errorCode=self.state.get("lastErrorCode", "NETWORK_ERROR"),
                           nextSyncAt=retry_at if self.continuous else None)
            return False
        self.heartbeat(status="FETCHING", lastAttemptAt=utc_text(now), nextSyncAt=None, errorCode=None)
        try:
            self._check_cancelled()
            latest = self.latest_pair()
            indices = self.contiguous_indices(latest)
            selected = self.publish_models(indices)  # Publish completed prices before historical work.
            self.publish_quotes(selected)
            try:
                self.archive_manifest()
            except (SourceError, OSError, ValueError) as warning:
                # Annual ZIP discovery is optional; daily prices do not depend on it.
                # A source throttle still stops every request to that host immediately.
                if isinstance(warning, SourceError) and warning.code == "RATE_LIMITED":
                    raise
                self._check_cancelled()
                print(json.dumps({"event": "archive_discovery_unavailable", "errorCode":
                                  warning.code if isinstance(warning, SourceError) else "INVALID_SOURCE"}), flush=True)
            backfilled = self.backfill(latest)
            self._check_cancelled()
            if backfilled:
                self.publish_models(self.contiguous_indices(latest))
            # Revisiting one cached prior date per cycle detects later source corrections.
            cursor = self.state.get("revisionDay", 1)
            review = latest - timedelta(days=cursor)
            if review.weekday() < 5 and (self.cache.daily(review) or self.cache.missing(review)):
                self.daily(review, refresh=True)
            history_reports = len(self.contiguous_indices(latest))
            # Commit success only after all work completed without cancellation.
            # Reports already saved by a partial backfill remain reusable.
            self._check_cancelled()
            self.state["revisionDay"] = 1 if cursor >= 7 else cursor + 1
            self.state["failures"] = 0
            self.state.pop("retryNotBefore", None)
            self.state.pop("lastErrorCode", None)
            self.state["lastSuccessAt"] = {series: item["lastSuccessAt"] for series, item in self.health.items()}
            self.state["nextDelay"] = self.interval
            atomic_json(self.state_path, self.state)
            self.heartbeat(status="IDLE", errorCode=None,
                           nextSyncAt=utc_text(self.now() + timedelta(seconds=self.interval)) if self.continuous else None)
            print(json.dumps({"event": "source_sync_complete", "dataAsOf": latest.isoformat(),
                              "historyReports": history_reports,
                              "backfillCursor": self.state["backfillCursor"]}), flush=True)
            return True
        except SourceCancelled:
            self.stop.set()
            return False
        except (SourceError, OSError, ValueError, KeyError) as exc:
            if self.stop.is_set() and not (isinstance(exc, SourceError) and exc.code == "RATE_LIMITED"):
                return False
            code = exc.code if isinstance(exc, SourceError) else "INVALID_SOURCE"
            self.state["failures"] = min(6, self.state.get("failures", 0) + 1)
            delay = min(21600, self.interval * 2 ** self.state["failures"])
            if isinstance(exc, SourceError):
                delay = max(delay, exc.retry_after)
            self.state["nextDelay"] = delay
            self.state["retryNotBefore"] = utc_text(self.now() + timedelta(seconds=delay))
            self.state["lastErrorCode"] = code
            atomic_json(self.state_path, self.state)
            self.heartbeat(status="ERROR", errorCode=code,
                           nextSyncAt=utc_text(self.now() + timedelta(seconds=delay)) if self.continuous else None)
            print(json.dumps({"event": "source_sync_failed", "errorCode": code, "nextDelaySeconds": delay}), flush=True)
            return False

    def run(self) -> int:
        with series_lock(self.cache.root / "collector.lock"):
            heartbeat = threading.Thread(target=self._heartbeat_loop, name="market-feed-heartbeat", daemon=True)
            heartbeat.start()
            if self.run_id:
                threading.Thread(target=self._managed_stop_loop, name="market-feed-stop", daemon=True).start()
            try:
                while not self.stop.is_set():
                    success = self.run_cycle()
                    if self.stop.is_set():
                        break
                    if not self.continuous:
                        return 0 if success else 2
                    if self.stop.wait(self.state.get("nextDelay", self.interval)):
                        break
                return 0
            finally:
                self.stop.set()
                heartbeat.join(timeout=2)
                self.heartbeat(nextSyncAt=None)


def run_auto(args) -> int:
    worker = AutoFeed(args.output_directory, history_days=args.history_days,
                      backfill_budget=args.backfill_budget, interval=args.interval, continuous=not args.once,
                      config_revision=args.configuration_revision, run_id=args.run_id)
    for name in ("SIGINT", "SIGTERM"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), lambda *_: worker.stop.set())
    return worker.run()
