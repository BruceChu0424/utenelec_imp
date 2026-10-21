"""Real StatsForecast integration plus import/replay regressions; no market downloads."""

from __future__ import annotations

import csv
import json
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.generate_synthetic import generate
from forecast_worker.cli import run_once
from forecast_worker.data import Dataset, InputError, Revision, ledger_payload, read_dataset, require_append_only
from forecast_worker.engine import HORIZONS, MIN_VALIDATION_FOLDS, build_snapshot, chronological_folds, validation_reasons

NOW = datetime(2026, 10, 20, 17, tzinfo=timezone.utc)


def manifest() -> dict:
    return {
        "seriesId": "test_copper", "name": "Unit test source", "commodity": "COPPER",
        "market": "SPOT", "grade": "Cu99.99", "region": "Shanghai", "currency": "CNY",
        "unit": "元/吨", "priceBasis": "tax included, freight excluded",
        "sourceName": "Authorized test fixture", "sourceUrl": "https://example.invalid/source",
        "authorized": True, "rollPolicy": None,
    }


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.manifest_path = self.directory / "manifest.json"
        self.csv_path = self.directory / "prices.csv"
        self.write_manifest(manifest())

    def tearDown(self):
        self.temporary.cleanup()

    def write_manifest(self, value):
        self.manifest_path.write_text(json.dumps(value), encoding="utf-8")

    def write_rows(self, rows):
        with self.csv_path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(["date", "price", "available_at"])
            writer.writerows(rows)

    def read(self):
        return read_dataset(self.manifest_path, self.csv_path, NOW)

    def test_timezone_aware_append_revision_is_replayed_only_after_publication(self):
        self.write_rows([
            ("2026-10-18", "50000", "2026-10-18T16:00:00+08:00"),
            ("2026-10-19", "50020", "2026-10-19T16:00:00+08:00"),
            ("2026-10-18", "50100", "2026-10-20T16:00:00+08:00"),
        ])
        data = self.read()
        old = data.as_of(datetime(2026, 10, 19, 20, tzinfo=timezone.utc))
        new = data.as_of(NOW)
        self.assertEqual(old[0].price, Decimal("50000"))
        self.assertEqual(new[0].price, Decimal("50100"))

    def test_duplicate_instant_different_timezone_is_rejected(self):
        self.write_rows([("2026-10-19", "50000", "2026-10-19T16:00:00+08:00"),
                         ("2026-10-19", "50001", "2026-10-19T08:00:00Z")])
        with self.assertRaisesRegex(InputError, "duplicates"):
            self.read()

    def test_invalid_and_implausible_prices_are_rejected(self):
        for price in ("NaN", "Infinity", "-1", "0", "0.0000000000000000001", "1000000000001"):
            with self.subTest(price=price):
                self.write_rows([("2026-10-19", price, "2026-10-19T16:00:00+08:00")])
                with self.assertRaises(InputError):
                    self.read()
        self.write_rows([("2026-10-18", "1000", "2026-10-18T16:00:00+08:00"),
                         ("2026-10-19", "10000", "2026-10-19T16:00:00+08:00")])
        with self.assertRaisesRegex(InputError, "implausible"):
            self.read()

    def test_future_or_naive_publication_is_rejected(self):
        for published in ("2026-10-21T20:00:00Z", "2026-10-19T16:00:00"):
            self.write_rows([("2026-10-19", "50000", published)])
            with self.assertRaises(InputError):
                self.read()

    def test_beijing_midnight_observation_accepts_previous_utc_date(self):
        self.write_rows([("2026-10-21", "50000", "2026-10-20T16:30:00Z")])
        self.assertEqual(self.read().rows[0].day.isoformat(), "2026-10-21")

    def test_authorization_and_pc_futures_proxy_are_rejected(self):
        self.write_rows([("2026-10-19", "50000", "2026-10-19T16:00:00+08:00")])
        invalid = manifest()
        invalid["authorized"] = False
        self.write_manifest(invalid)
        with self.assertRaisesRegex(InputError, "authorized"):
            self.read()
        invalid.update(authorized=True, commodity="POLYCARBONATE", market="FUTURES", rollPolicy="PP proxy")
        self.write_manifest(invalid)
        with self.assertRaisesRegex(InputError, "PC/POLYCARBONATE"):
            self.read()

    def test_manifest_unsafe_identity_url_and_unknown_fields_are_rejected(self):
        self.write_rows([("2026-10-19", "50000", "2026-10-19T16:00:00+08:00")])
        for change in ({"seriesId": "../escape"}, {"seriesId": "UPPERCASE"},
                       {"sourceUrl": "https://name:secret@example.com/"},
                       {"sourceUrl": "https://example.com/\nunsafe"}, {"unexpected": "value"}):
            self.write_manifest({**manifest(), **change})
            with self.assertRaises(InputError):
                self.read()

    def test_empty_template_never_produces_a_snapshot(self):
        self.write_rows([])
        with self.assertRaisesRegex(InputError, "no observations"):
            self.read()

    def test_owned_supplier_data_does_not_require_a_fake_public_url(self):
        self.write_manifest({**manifest(), "sourceUrl": ""})
        self.write_rows([("2026-10-19", "50000", "2026-10-19T16:00:00+08:00")])
        self.assertEqual(self.read().manifest["sourceUrl"], "")

    def test_import_ledger_rejects_rewrite_and_accepts_append(self):
        rows = [("2026-10-18", "50000", "2026-10-18T16:00:00+08:00")]
        self.write_rows(rows)
        original = self.read()
        self.write_rows(rows + [("2026-10-19", "50020", "2026-10-19T16:00:00+08:00")])
        require_append_only(self.read(), ledger_payload(original))
        self.write_rows([("2026-10-18", "50001", "2026-10-18T16:00:00+08:00")])
        with self.assertRaisesRegex(InputError, "append-only"):
            require_append_only(self.read(), ledger_payload(original))

    def test_failed_import_preserves_last_complete_snapshot_and_fixed_decimal(self):
        self.write_rows([("2026-10-19", "5E+4", "2026-10-19T16:00:00+08:00")])
        output, snapshot = run_once(self.manifest_path, self.csv_path, self.directory / "out", now=NOW)
        self.assertEqual(snapshot["status"], "INSUFFICIENT")
        self.assertEqual(snapshot["latestPrice"], "50000")
        before = output.read_bytes()
        self.write_rows([("2026-10-19", "50001", "2026-10-19T16:00:00+08:00")])
        with self.assertRaises(InputError):
            run_once(self.manifest_path, self.csv_path, self.directory / "out", now=NOW)
        self.assertEqual(output.read_bytes(), before)


class RealLibraryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temporary.name)
        cls.manifest_path, cls.csv_path = generate(cls.directory / "input", 900)
        cls.now = datetime.now(timezone.utc)
        cls.data = read_dataset(cls.manifest_path, cls.csv_path, cls.now, allow_synthetic=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_synthetic_data_requires_explicit_opt_in(self):
        with self.assertRaisesRegex(InputError, "SYNTHETIC"):
            read_dataset(self.manifest_path, self.csv_path, self.now)

    def test_real_statsforecast_smoke_and_all_horizon_validation(self):
        output, snapshot = run_once(self.manifest_path, self.csv_path, self.directory / "output",
                                     allow_synthetic=True, now=self.now)
        self.assertEqual(snapshot["libraryVersion"], "2.1.1")
        self.assertTrue(snapshot["synthetic"])
        self.assertEqual(json.loads(output.read_text(encoding="utf-8")), snapshot)
        self.assertEqual(snapshot["status"], "READY", snapshot["reasonCodes"])
        validation = snapshot["validation"]
        self.assertTrue(validation["passed"])
        self.assertGreaterEqual(validation["folds"], MIN_VALIDATION_FOLDS)
        self.assertLess(Decimal(validation["modelMAE"]), Decimal(validation["baselineMAE"]))
        self.assertGreaterEqual(Decimal(validation["coverage80"]), Decimal("0.70"))
        self.assertEqual([f["horizon"] for f in snapshot["forecasts"]], list(HORIZONS))
        self.assertEqual(snapshot["procurementSignal"], "RISING")

    def test_historical_late_revision_cannot_improve_backtest(self):
        original = build_snapshot(self.data, self.now)
        old = self.data.rows[20]
        correction = Revision(old.day, old.price + Decimal("1000"), self.now - timedelta(seconds=1))
        revised = Dataset(self.data.manifest, (*self.data.rows, correction), "1" * 64)
        replay = build_snapshot(revised, self.now)
        self.assertEqual(original["validation"], replay["validation"])
        for fold in chronological_folds(revised):
            self.assertTrue(all(row.available_at <= fold.origin.available_at for row in fold.history))
            self.assertTrue(all(row.available_at > fold.origin.available_at for row in fold.targets))

    def test_unknown_historical_availability_cannot_invent_backtest(self):
        rows = tuple(Revision(row.day, row.price, self.now - timedelta(seconds=1)) for row in self.data.rows)
        imported_today = Dataset(self.data.manifest, rows, "2" * 64)
        snapshot = build_snapshot(imported_today, self.now)
        self.assertEqual(snapshot["status"], "BASELINE_ONLY")
        self.assertEqual(snapshot["validation"]["folds"], 0)
        self.assertEqual(snapshot["procurementSignal"], "INSUFFICIENT")
        self.assertTrue(all(f["direction"] == "UNCERTAIN" for f in snapshot["forecasts"]))

    def test_constant_series_cannot_beat_perfect_naive(self):
        rows = tuple(Revision(row.day, Decimal("50000"), row.available_at) for row in self.data.rows[:620])
        data = Dataset(self.data.manifest, rows, "3" * 64)
        snapshot = build_snapshot(data, self.now)
        self.assertEqual(snapshot["status"], "BASELINE_ONLY")
        self.assertFalse(snapshot["validation"]["passed"])
        self.assertEqual(snapshot["validation"]["baselineMAE"], "0")
        self.assertIn("VALIDATION_NOT_BETTER_THAN_NAIVE", snapshot["reasonCodes"])

    def test_folds_are_bounded_separate_and_keep_unfilled_observations(self):
        folds = chronological_folds(self.data)
        self.assertLessEqual(len(folds), 38)
        self.assertEqual(len(folds), 38)
        row_positions = {row.day: index for index, row in enumerate(self.data.rows)}
        for left, right in zip(folds, folds[1:]):
            self.assertGreaterEqual(row_positions[right.origin.day] - row_positions[left.origin.day], 20)
        self.assertTrue(all(len(fold.history) <= 1000 for fold in folds))


class ValidationGateTests(unittest.TestCase):
    def test_pooled_improvement_cannot_hide_one_bad_horizon(self):
        baseline = {h: {"mae": 10, "coverage": 0.8} for h in HORIZONS}
        model = {1: {"mae": 1, "coverage": 0.8}, 5: {"mae": 1, "coverage": 0.8},
                 20: {"mae": 11, "coverage": 0.8}}
        self.assertIn("VALIDATION_NOT_BETTER_THAN_NAIVE", validation_reasons(model, baseline))

    def test_pooled_coverage_cannot_hide_uncalibrated_purchase_horizon(self):
        baseline = {h: {"mae": 10, "coverage": 0.8} for h in HORIZONS}
        model = {1: {"mae": 1, "coverage": 1}, 5: {"mae": 1, "coverage": 1},
                 20: {"mae": 1, "coverage": 0.5}}
        self.assertIn("INTERVAL_COVERAGE_BELOW_THRESHOLD", validation_reasons(model, baseline))


class WatchCliTests(unittest.TestCase):
    def test_real_watch_process_publishes_appended_local_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest_path, csv_path = directory / "manifest.json", directory / "prices.csv"
            manifest_path.write_text(json.dumps(manifest()), encoding="utf-8")
            now = datetime.now(timezone.utc)
            first_day = now.date() - timedelta(days=3)
            row = f"{first_day.isoformat()},50000,{first_day.isoformat()}T12:00:00Z\n"
            csv_path.write_text("date,price,available_at\n" + row, encoding="utf-8")
            output = directory / "out" / "test_copper.json"
            worker = Path(__file__).resolve().parents[1] / "worker.py"
            process = subprocess.Popen([
                sys.executable, str(worker), "--manifest", str(manifest_path), "--csv", str(csv_path),
                "--output-directory", str(output.parent), "--watch", "10",
            ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            try:
                # Cold scientific imports contend with the complete Java build
                # on developer Windows hosts. Bound startup separately from the
                # ten-second watch interval; an exited child still fails early.
                deadline = time.monotonic() + 90
                while not output.exists() and time.monotonic() < deadline and process.poll() is None:
                    time.sleep(0.1)
                self.assertTrue(output.exists(), f"watch did not publish initial import (exit={process.poll()})")
                second_day = first_day + timedelta(days=1)
                with csv_path.open("a", encoding="utf-8") as handle:
                    handle.write(f"{second_day.isoformat()},50010,{second_day.isoformat()}T12:00:00Z\n")
                deadline = time.monotonic() + 20
                current = json.loads(output.read_text(encoding="utf-8"))
                while current["dataAsOf"] != second_day.isoformat() and time.monotonic() < deadline and process.poll() is None:
                    time.sleep(0.1)
                    current = json.loads(output.read_text(encoding="utf-8"))
                self.assertEqual(current["dataAsOf"], second_day.isoformat())
                self.assertEqual(current["status"], "BASELINE_ONLY")
            finally:
                process.terminate()
                process.communicate(timeout=10)


if __name__ == "__main__":
    unittest.main()
