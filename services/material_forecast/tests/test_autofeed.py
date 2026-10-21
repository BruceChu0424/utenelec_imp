"""Source fixtures test automatic collection; live HTTP is a separate explicit smoke."""

import gzip
import io
import json
import random
import sys
import tempfile
import unittest
import urllib.error
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from forecast_worker.autofeed import AutoFeed
from forecast_worker.shfe import (MAX_RESPONSE, ReportCache, ShfeClient, SourceError, _SafeRedirect,
                                  allowed_url, chain_points, parse_daily, select_contract)

NOW = datetime(2026, 10, 20, 6, tzinfo=timezone.utc)


def source(day, sequence, rows=None):
    if rows is None:
        rows = [{"PRODUCTGROUPID": symbol + "   ", "PRODUCTID": symbol + "_f   ",
                 "DELIVERYMONTH": "2611", "SETTLEMENTPRICE": "50000", "OPENINTEREST": "100"}
                for symbol in ("cu", "al", "ag")]
    return {"report_date": day.strftime("%Y%m%d"), "o_trade_day": str(sequence), "o_curinstrument": rows}


def bar(contract, settlement, interest):
    return {"contract": contract, "settlement": str(settlement), "open_interest": str(interest)}


class RollTests(unittest.TestCase):
    def test_previous_oi_and_same_contract_returns_remove_roll_jump(self):
        indices = [
            {"date": "2026-10-16", "tradeSequence": 1, "rows": [bar("cu2611", 100, 100), bar("cu2612", 200, 50)]},
            {"date": "2026-10-19", "tradeSequence": 2, "rows": [bar("cu2611", 110, 5), bar("cu2612", 220, 200)]},
            {"date": "2026-10-20", "tradeSequence": 3, "rows": [bar("cu2611", 121, 1000), bar("cu2612", 242, 50)]},
        ]
        points = chain_points(indices, "cu")
        self.assertEqual([point["contract"] for point in points], ["cu2611", "cu2612"])
        self.assertEqual(points[-1]["index"], Decimal("110"))
        self.assertEqual(points[-1]["settlement"], Decimal("242"))

    def test_tie_uses_nearest_month_and_missing_winner_has_no_runner_up(self):
        previous = [bar("cu2612", 200, 100), bar("cu2611", 100, 100)]
        current = [bar("cu2612", 220, 300)]
        self.assertIsNone(select_contract(previous, current, "cu", date(2026, 10, 20)))

    def test_missing_report_sequence_cannot_join_two_trading_days(self):
        indices = [
            {"date": "2026-10-16", "tradeSequence": 10, "rows": [bar("cu2611", 100, 100)]},
            {"date": "2026-10-20", "tradeSequence": 12, "rows": [bar("cu2611", 120, 100)]},
        ]
        self.assertEqual(chain_points(indices, "cu"), [])


class CacheAndHttpTests(unittest.TestCase):
    def test_source_revisions_retain_actual_first_observation(self):
        with tempfile.TemporaryDirectory() as temporary:
            cache = ReportCache(Path(temporary))
            day = date(2026, 10, 19)
            payload = source(day, 1)
            cache.save(day, payload, NOW)
            cache.save(day, payload, NOW + timedelta(hours=1))
            self.assertEqual(len(list((cache.root / "raw" / day.isoformat()).glob("*.json"))), 1)
            raw = json.loads(next((cache.root / "raw" / day.isoformat()).glob("*.json")).read_text(encoding="utf-8"))
            self.assertEqual(raw["fetchedAt"], "2026-10-20T06:00:00Z")
            payload["o_curinstrument"][0]["SETTLEMENTPRICE"] = "50001"
            cache.save(day, payload, NOW + timedelta(hours=2))
            self.assertEqual(len(list((cache.root / "raw" / day.isoformat()).glob("*.json"))), 2)
            self.assertEqual(cache.daily(day)["firstObservedAt"], "2026-10-20T06:00:00Z")

    def test_unknown_cache_gap_stops_contiguous_history(self):
        with tempfile.TemporaryDirectory() as temporary:
            worker = AutoFeed(Path(temporary), now=lambda: NOW, client=FakeClient({}), backfill_budget=0)
            worker.cache.save(date(2026, 10, 15), source(date(2026, 10, 15), 1), NOW)
            worker.cache.save(date(2026, 10, 20), source(date(2026, 10, 20), 4), NOW)
            indices = worker.contiguous_indices(date(2026, 10, 20))
            self.assertEqual([item["date"] for item in indices], ["2026-10-20"])
            self.assertEqual(chain_points(indices, "cu"), [])

    def test_source_path_redirect_and_decompression_are_bounded(self):
        for url in ("http://www.shfe.com.cn/data/config/currentTradingday.dat",
                    "https://evil.example/data/config/currentTradingday.dat",
                    "https://www.shfe.com.cn/data/config/currentTradingday.dat?url=https://evil.example"):
            self.assertFalse(allowed_url(url))
        with self.assertRaises(SourceError):
            _SafeRedirect().redirect_request(None, None, 302, "", {}, "https://evil.example/")
        client = ShfeClient(minimum_interval=0)
        class Response(io.BytesIO):
            status = 200
            url = "https://www.shfe.com.cn/data/config/currentTradingday.dat"
            headers = {"Content-Encoding": "gzip"}
        class Opener:
            def open(self, *_args, **_kwargs):
                return Response(gzip.compress(b"x" * (MAX_RESPONSE + 1)))
        client._opener = Opener()
        with self.assertRaisesRegex(SourceError, "INVALID_SOURCE"):
            client.get("/data/config/currentTradingday.dat")

    def test_rate_limit_is_not_retried_or_bypassed(self):
        client = ShfeClient(minimum_interval=0)
        class Opener:
            count = 0
            def open(self, *_args, **_kwargs):
                self.count += 1
                raise urllib.error.HTTPError("https://www.shfe.com.cn/", 429, "limited", {"Retry-After": "3600"}, None)
        client._opener = Opener()
        with self.assertRaises(SourceError) as failure:
            client.get("/data/config/currentTradingday.dat")
        self.assertEqual(failure.exception.code, "RATE_LIMITED")
        self.assertEqual(failure.exception.retry_after, 3600)
        self.assertEqual(client._opener.count, 1)

    def test_report_day_wrong_contract_and_duplicate_are_rejected(self):
        day = date(2026, 10, 19)
        payload = source(day, 1)
        with self.assertRaises(SourceError):
            parse_daily(payload, date(2026, 10, 18), NOW)
        payload["o_curinstrument"].append(payload["o_curinstrument"][0].copy())
        with self.assertRaises(SourceError):
            parse_daily(payload, day, NOW)


class FakeClient:
    def __init__(self, payloads):
        self.payloads, self.calls, self.failure = payloads, [], None

    def get(self, path):
        self.calls.append(path)
        if self.failure:
            raise SourceError(self.failure)
        return self.payloads.get(path)


def fixture(count=900):
    latest = date(2026, 10, 19)
    days, day = [], latest
    while len(days) < count:
        if day.weekday() < 5:
            days.append(day)
        day -= timedelta(days=1)
    days.reverse()
    payloads = {
        "/data/config/currentTradingday.dat": {"currentTradingday": "20261020", "lastTradingday": "20261019"},
        "/reports/tradedata/datadownload/download.json": {"data": {"latestData": [], "historicalData": []}},
    }
    rng = random.Random(121)
    for index, day in enumerate(days):
        rows = []
        underlying = Decimal(str(50000 + index * 12 + rng.gauss(0, 1)))
        for symbol, scale in (("cu", 1), ("al", .4), ("ag", .2)):
            for month, basis in (("2611", 0), ("2612", 2000)):
                amount = (underlying + basis) * Decimal(str(scale))
                oi = 200 if (month == "2611") == (index < count // 2) else 100
                rows.append({"PRODUCTGROUPID": symbol, "DELIVERYMONTH": month,
                             "SETTLEMENTPRICE": format(amount.quantize(Decimal(".000001")), "f"), "OPENINTEREST": oi})
        payloads["/data/tradedata/future/dailydata/kx" + day.strftime("%Y%m%d") + ".dat"] = source(day, index + 1, rows)
    for symbol in ("cu", "al", "ag"):
        payloads[f"/data/tradedata/future/delaymarket/delaymarket_{symbol}.dat"] = {"delaymarket": [
            {"contractname": symbol + "2612", "instrumentid": symbol, "lastprice": "50000", "updatetime": "2026-10-20 13:00:00"}]}
    return payloads


class AutomaticCycleTests(unittest.TestCase):
    def test_optional_archive_discovery_does_not_block_daily_quotes(self):
        with tempfile.TemporaryDirectory() as temporary:
            payloads = fixture(10)
            payloads.pop("/reports/tradedata/datadownload/download.json")
            worker = AutoFeed(Path(temporary), client=FakeClient(payloads), now=lambda: NOW,
                              history_days=10, backfill_budget=0)
            self.assertTrue(worker.run_cycle())
            self.assertTrue((Path(temporary) / "shfe_cu_main_daily.quote.json").exists())
            self.assertEqual(len(list((Path(temporary) / ".auto-feed/issued/shfe_cu_main_daily").glob("*.json"))), 1)
            health = json.loads((Path(temporary) / "auto-feed-health.json").read_text(encoding="utf-8"))
            self.assertTrue(all(row["status"] == "IDLE" for row in health["series"]))

    def test_full_backfill_real_model_next_day_update_and_failure_preservation(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = FakeClient(fixture())
            clock = [NOW]
            worker = AutoFeed(Path(temporary), client=client, now=lambda: clock[0], history_days=1400, backfill_budget=1000)
            self.assertTrue(worker.run_cycle())
            snapshot_path = Path(temporary) / "shfe_cu_main_daily.json"
            snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
            self.assertEqual(snapshot["schemaVersion"], 2)
            self.assertGreaterEqual(snapshot["historyRecordCount"], 800)
            self.assertEqual(snapshot["status"], "RESEARCH_ONLY", snapshot["reasonCodes"])
            self.assertEqual(snapshot["procurementSignal"], "INSUFFICIENT")
            self.assertEqual(len(snapshot["forecasts"]), 3)
            self.assertEqual(snapshot["quoteContract"], "cu2612")
            health = json.loads((Path(temporary) / "auto-feed-health.json").read_text(encoding="utf-8"))
            self.assertFalse(health["autoUpdateEnabled"])
            self.assertTrue(all(row["status"] == "IDLE" for row in health["series"]))
            # Appending a new official day triggers a new model generation automatically.
            latest = date(2026, 10, 20)
            old = client.payloads["/data/tradedata/future/dailydata/kx20261019.dat"]
            rows = [dict(row, SETTLEMENTPRICE=str(Decimal(str(row["SETTLEMENTPRICE"])) + 12)) for row in old["o_curinstrument"]]
            client.payloads["/data/tradedata/future/dailydata/kx20261020.dat"] = source(latest, 901, rows)
            client.payloads["/data/config/currentTradingday.dat"] = {"currentTradingday": "20261021", "lastTradingday": "20261020"}
            clock[0] += timedelta(days=1)
            self.assertTrue(worker.run_cycle())
            changed = json.loads(snapshot_path.read_text(encoding="utf-8"))
            self.assertEqual(changed["dataAsOf"], "2026-10-20")
            self.assertNotEqual(changed["generatedAt"], snapshot["generatedAt"])
            before = snapshot_path.read_bytes()
            client.failure = "RATE_LIMITED"
            self.assertFalse(worker.run_cycle())
            self.assertEqual(snapshot_path.read_bytes(), before)
            health = json.loads((Path(temporary) / "auto-feed-health.json").read_text(encoding="utf-8"))
            self.assertTrue(all(row["errorCode"] == "RATE_LIMITED" for row in health["series"]))
            call_count = len(client.calls)
            restarted = AutoFeed(Path(temporary), client=client, now=lambda: clock[0], history_days=1400, backfill_budget=1000)
            self.assertFalse(restarted.run_cycle())
            self.assertEqual(len(client.calls), call_count, "restart must honor the persisted rate-limit backoff")

    def test_small_budget_persists_progress_and_current_day_404_is_retried(self):
        with tempfile.TemporaryDirectory() as temporary:
            client = FakeClient(fixture(30))
            worker = AutoFeed(Path(temporary), client=client, now=lambda: NOW, history_days=60, backfill_budget=2)
            self.assertTrue(worker.run_cycle())
            first = worker.state["backfillCursor"]
            self.assertTrue(worker.run_cycle())
            self.assertLess(worker.state["backfillCursor"], first)
            today = date(2026, 10, 20)
            worker.daily(today, refresh=True)
            worker.daily(today, refresh=True)
            self.assertFalse(worker.cache.missing(today))
            self.assertGreaterEqual(client.calls.count("/data/tradedata/future/dailydata/kx20261020.dat"), 2)


if __name__ == "__main__":
    unittest.main()
