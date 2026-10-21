"""Automatic replay never masquerades as a historical observed prediction."""

from __future__ import annotations

import copy
import json
import random
import sys
import unittest
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from forecast_worker.automatic_engine import build_automatic_snapshot
from forecast_worker.data import InputError


CATALOG = (Path(__file__).resolve().parents[3] / "server/src/main/resources/pricing/material-benchmarks.json")


class AutomaticEngineTest(unittest.TestCase):
    def setUp(self):
        self.benchmark = json.loads(CATALOG.read_text(encoding="utf-8"))[0]
        self.now = datetime(2026, 10, 20, 12, tzinfo=timezone.utc)
        self.points = [{"day": date(2026, 10, 19), "index": Decimal("100"),
                        "settlement": Decimal("80000"), "contract": "cu2611"},
                       {"day": date(2026, 10, 20), "index": Decimal("101"),
                        "settlement": Decimal("80800"), "contract": "cu2611"}]

    def run_snapshot(self, **kwargs):
        return build_automatic_snapshot(
            kwargs.get("benchmark", self.benchmark), kwargs.get("points", self.points),
            kwargs.get("now", self.now), kwargs.get("digest", "a" * 64),
            kwargs.get("fetched", self.now),
        )

    def test_actual_library_short_history_produces_baseline_in_market_units(self):
        result = self.run_snapshot()
        self.assertEqual(result["schemaVersion"], 2)
        self.assertEqual(result["status"], "BASELINE_ONLY")
        self.assertEqual(result["latestPrice"], "80800")
        self.assertEqual(result["validationBasis"], "LATEST_HISTORY_REPLAY")
        self.assertEqual(result["quoteContract"], "cu2611")
        self.assertEqual(result["historyRecordCount"], 2)
        self.assertEqual({Decimal(row["price"]) for row in result["forecasts"]}, {Decimal("80800")})
        self.assertEqual(result["procurementSignal"], "INSUFFICIENT")

    def test_replay_pass_is_research_only_with_scaled_metrics_and_no_advice(self):
        template = {
            "status": "READY", "reasonCodes": [], "schemaVersion": 1,
            "validation": {"passed": True, "baselineMAE": "2", "modelMAE": "1"},
            "forecasts": [{"horizon": h, "price": "104", "lower80": "102",
                           "upper80": "106", "direction": "UP"} for h in (1, 5, 20)],
        }
        with patch("forecast_worker.automatic_engine.build_snapshot", return_value=copy.deepcopy(template)) as fit:
            result = self.run_snapshot()
        self.assertEqual(result["status"], "RESEARCH_ONLY")
        self.assertTrue(result["validation"]["passed"])
        self.assertEqual(Decimal(result["forecasts"][0]["price"]), Decimal("83200"))
        self.assertEqual(Decimal(result["validation"]["baselineMAE"]), Decimal("1600"))
        self.assertEqual(result["procurementSignal"], "INSUFFICIENT")
        self.assertEqual(result["forecasts"][0]["direction"], "UP")
        replay = fit.call_args.args[0]
        self.assertLess(replay.rows[0].available_at, self.now)
        self.assertEqual(result["sourceFetchedAt"], "2026-10-20T12:00:00Z")

    def test_midday_completed_daily_report_is_not_lost_to_nominal_replay_hour(self):
        midday = datetime(2026, 10, 20, 8, tzinfo=timezone.utc)
        result = self.run_snapshot(now=midday, fetched=midday)
        self.assertEqual(result["dataAsOf"], "2026-10-20")

    def test_model_failure_keeps_new_market_settlement_without_inventing_forecast(self):
        with patch("forecast_worker.automatic_engine.build_snapshot", side_effect=RuntimeError("fit failed")):
            result = self.run_snapshot()
        self.assertEqual(result["latestPrice"], "80800")
        self.assertEqual(result["dataAsOf"], "2026-10-20")
        self.assertEqual(result["status"], "INSUFFICIENT")
        self.assertEqual(result["forecasts"], [])
        self.assertFalse(result["validation"]["passed"])
        self.assertIn("MODEL_FAILED", result["reasonCodes"])
        self.assertEqual(result["procurementSignal"], "INSUFFICIENT")

    def test_future_fetch_or_observation_is_rejected(self):
        with self.assertRaises(InputError):
            self.run_snapshot(fetched=self.now + timedelta(seconds=1))
        future = copy.deepcopy(self.points)
        future[-1]["day"] = date(2026, 10, 21)
        with self.assertRaises(InputError):
            self.run_snapshot(points=future)

    def test_nonchronological_or_mismatched_contract_is_rejected(self):
        with self.assertRaises(InputError):
            self.run_snapshot(points=list(reversed(self.points)))
        wrong = copy.deepcopy(self.points)
        wrong[-1]["contract"] = "ag2611"
        with self.assertRaises(InputError):
            self.run_snapshot(points=wrong)

    def test_no_implicit_currency_or_unit_conversion(self):
        for key, value in (("currency", "USD"), ("unit", "千克"), ("commodity", "SILVER")):
            wrong = {**self.benchmark, key: value}
            with self.subTest(key=key), self.assertRaises(InputError):
                self.run_snapshot(benchmark=wrong)

    def test_source_digest_and_finite_price_bounds(self):
        with self.assertRaises(InputError):
            self.run_snapshot(digest="unknown")
        for value in (Decimal("NaN"), Decimal("0"), Decimal("Infinity")):
            invalid = copy.deepcopy(self.points)
            invalid[-1]["settlement"] = value
            with self.subTest(value=str(value)), self.assertRaises(InputError):
                self.run_snapshot(points=invalid)

    def test_actual_library_long_replay_never_promotes_archive_to_observed_validation(self):
        rng = random.Random(8128)
        start = self.now.date() - timedelta(days=899)
        points = []
        for i in range(900):
            value = Decimal(f"{50000 + 12 * i + rng.gauss(0, 1.2):.6f}")
            points.append({"day": start + timedelta(days=i), "index": value,
                           "settlement": value * 2, "contract": "cu2611"})
        result = self.run_snapshot(points=points)
        self.assertEqual(result["status"], "RESEARCH_ONLY")
        self.assertTrue(result["validation"]["passed"])
        self.assertEqual(result["procurementSignal"], "INSUFFICIENT")
        self.assertEqual(len(result["forecasts"]), 3)
        self.assertTrue(all(Decimal(row["price"]) > Decimal("100000") for row in result["forecasts"]))


if __name__ == "__main__":
    unittest.main()
