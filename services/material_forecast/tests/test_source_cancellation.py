"""Cancellation is an owned lifecycle event, never a persisted source failure."""

import io
import json
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from contextlib import redirect_stdout
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from forecast_worker.autofeed import AutoFeed
from forecast_worker.cli import atomic_json
from forecast_worker.shfe import ShfeClient, SourceError

NOW = datetime(2026, 10, 21, 22, tzinfo=timezone.utc)
LATEST = date(2026, 10, 20)
RUN_ID = "12345678-1234-1234-1234-123456789abc"
CONFIG_PATH = "/data/config/currentTradingday.dat"


class Response(io.BytesIO):
    status = 200
    url = "https://www.shfe.com.cn" + CONFIG_PATH
    headers = {}


class SourceCancellationTests(unittest.TestCase):
    def assert_cancelled(self, operation):
        with self.assertRaises(Exception) as failure:
            operation()
        self.assertNotIsInstance(failure.exception, SourceError,
                                 "normal cancellation must not be a source error")
        self.assertEqual(type(failure.exception).__name__, "SourceCancelled")

    def test_rate_wait_cancellation_does_not_open_source(self):
        client = ShfeClient()
        client._next_request = time.monotonic() + 60
        client._opener = Mock()
        # Deterministically deliver cancellation inside the throttling wait.
        def cancelled_wait(timeout):
            self.assertGreater(timeout, 0)
            client.stop.set()
            return True
        with patch.object(client.stop, "wait", side_effect=cancelled_wait):
            self.assert_cancelled(lambda: client.get(CONFIG_PATH))
        client._opener.open.assert_not_called()

    def test_headers_and_body_cancellation_are_separate_from_network_errors(self):
        for phase in ("headers", "body", "headers-timeout", "body-timeout"):
            with self.subTest(phase=phase):
                client = ShfeClient(minimum_interval=0)
                response = Response(b'{"ok": true}')
                read = response.read
                def read_and_cancel(size):
                    client.stop.set()
                    if phase == "body-timeout":
                        raise TimeoutError("interrupted body")
                    return read(size)
                def open_and_cancel(*_args, **_kwargs):
                    if phase.startswith("headers"):
                        client.stop.set()
                    if phase == "headers-timeout":
                        raise TimeoutError("interrupted headers")
                    return response
                if phase.startswith("body"):
                    response.read = read_and_cancel
                client._opener = Mock(open=Mock(side_effect=open_and_cancel))
                self.assert_cancelled(lambda: client.get(CONFIG_PATH))

    def test_real_timeout_deadline_throttle_and_invalid_payload_keep_error_policy(self):
        cases = (
            (TimeoutError("real headers timeout"), "NETWORK_ERROR", 0),
            (urllib.error.HTTPError(Response.url, 429, "limited", {"Retry-After": "3600"}, None), "RATE_LIMITED", 3600),
            (urllib.error.HTTPError(Response.url, 403, "denied", {}, None), "RATE_LIMITED", 0),
        )
        for failure, code, delay in cases:
            with self.subTest(code=code, failure=str(failure)):
                client = ShfeClient(minimum_interval=0)
                client._opener = Mock(open=Mock(side_effect=failure))
                with self.assertRaises(SourceError) as caught:
                    client.get(CONFIG_PATH)
                self.assertEqual((caught.exception.code, caught.exception.retry_after), (code, delay))
                self.assertIs(caught.exception.__cause__, failure)
        client = ShfeClient(minimum_interval=0)
        client._opener = Mock(open=Mock(return_value=Response(b"not-json")))
        with self.assertRaisesRegex(SourceError, "INVALID_SOURCE"):
            client.get(CONFIG_PATH)
        client = ShfeClient(minimum_interval=0)
        response = Response(b"{}")
        response.read = Mock(side_effect=TimeoutError("real body timeout"))
        client._opener = Mock(open=Mock(return_value=response))
        with self.assertRaisesRegex(SourceError, "NETWORK_ERROR"):
            client.get(CONFIG_PATH)
        client = ShfeClient(minimum_interval=0)
        client._opener = Mock(open=Mock(return_value=Response(b"{}")))
        with patch("forecast_worker.shfe.time.monotonic", side_effect=[0, 0, 0, 31]):
            with self.assertRaisesRegex(SourceError, "NETWORK_ERROR"):
                client.get(CONFIG_PATH)

    def test_observed_403_and_429_are_retained_when_the_owner_stops_at_headers(self):
        for status in (403, 429):
            with self.subTest(status=status):
                client = ShfeClient(minimum_interval=0)
                failure = urllib.error.HTTPError(Response.url, status, "limited", {"Retry-After": "20000"}, None)
                def limited_headers(*_args, **_kwargs):
                    client.stop.set()
                    raise failure
                client._opener = Mock(open=Mock(side_effect=limited_headers))
                with self.assertRaises(SourceError) as caught:
                    client.get(CONFIG_PATH)
                self.assertEqual((caught.exception.code, caught.exception.retry_after), ("RATE_LIMITED", 20000))
                self.assertIs(caught.exception.__cause__, failure)
                client._opener.open.assert_called_once()


class CollectorCancellationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.output = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def worker(self, *, managed=False, continuous=False):
        return AutoFeed(self.output, now=lambda: NOW, interval=3600, continuous=continuous,
                        config_revision="a" * 64 if managed else None,
                        run_id=RUN_ID if managed else None)

    def seed_state(self, worker, *, future=False):
        worker.state = {"failures": 2, "lastErrorCode": "NETWORK_ERROR", "nextDelay": 14400,
                        "retryNotBefore": (NOW + timedelta(hours=4) if future else NOW - timedelta(seconds=1)).isoformat(),
                        "revisionDay": 7, "backfillCursor": "2025-01-30"}
        atomic_json(worker.state_path, worker.state)
        return worker.state_path.read_bytes()

    def stages(self, worker):
        """Reach the actual collector finalization without unrelated model work."""
        worker.latest_pair = Mock(return_value=LATEST)
        worker.contiguous_indices = Mock(return_value=[])
        worker.publish_models = Mock(return_value={})
        worker.publish_quotes = Mock()
        worker.archive_manifest = Mock()

    def assert_no_sync_result(self, stdout):
        events = [json.loads(line)["event"] for line in stdout.getvalue().splitlines()]
        self.assertNotIn("source_sync_complete", events)
        self.assertNotIn("source_sync_failed", events)

    def test_managed_stop_and_eof_during_request_leave_state_unchanged_and_once_exits_zero(self):
        for signal in (b"STOP " + RUN_ID.encode("ascii") + b"\n", b""):
            with self.subTest(signal=signal):
                worker = self.worker(managed=True)
                before = self.seed_state(worker)
                request_started = threading.Event()
                class ManagedInput:
                    def readline(_self, _limit):
                        if not request_started.wait(5):
                            raise AssertionError("request did not reach headers")
                        return signal
                def open_response(*_args, **_kwargs):
                    # Exercise the real run-owned stdin thread and parser while
                    # the request is waiting for headers, with no live network.
                    request_started.set()
                    self.assertTrue(worker.stop.wait(5), "managed stop was not received")
                    return Response(b"{}")
                worker.client._opener = Mock(open=Mock(side_effect=open_response))
                stdout = io.StringIO()
                with patch("sys.stdin", SimpleNamespace(buffer=ManagedInput())), redirect_stdout(stdout):
                    self.assertEqual(worker.run(), 0, "a cancelled --once run is a normal exit")
                self.assertEqual(worker.state_path.read_bytes(), before)
                self.assertEqual(worker.state["failures"], 2)
                self.assert_no_sync_result(stdout)
                health = json.loads((self.output / "auto-feed-health.json").read_text())
                self.assertFalse(health["autoUpdateEnabled"])
                self.assertTrue(all(item["errorCode"] is None for item in health["series"]))

    def test_restart_after_cancellation_makes_a_source_request_without_artificial_backoff(self):
        worker = self.worker()
        def cancelled_headers(*_args, **_kwargs):
            worker.stop.set()
            return Response(b"{}")
        worker.client._opener = Mock(open=Mock(side_effect=cancelled_headers))
        with redirect_stdout(io.StringIO()) as stdout:
            self.assertFalse(worker.run_cycle())
        self.assertFalse(worker.state_path.exists(), "cancellation must not persist a retry deadline")
        self.assert_no_sync_result(stdout)
        restarted = self.worker()
        restarted.client._opener = Mock(open=Mock(side_effect=TimeoutError("real new request")))
        with redirect_stdout(io.StringIO()):
            self.assertFalse(restarted.run_cycle())
        restarted.client._opener.open.assert_called_once()
        self.assertEqual(restarted.state["failures"], 1)

    def test_existing_real_future_backoff_survives_cancel_and_restart(self):
        worker = self.worker(continuous=True)
        before = self.seed_state(worker, future=True)
        worker.stop.set()
        worker.client._opener = Mock()
        with redirect_stdout(io.StringIO()) as stdout:
            self.assertFalse(worker.run_cycle())
        worker.client._opener.open.assert_not_called()
        self.assertEqual(worker.state_path.read_bytes(), before)
        self.assert_no_sync_result(stdout)
        restarted = self.worker(continuous=True)
        restarted.client._opener = Mock()
        with redirect_stdout(io.StringIO()):
            self.assertFalse(restarted.run_cycle())
        restarted.client._opener.open.assert_not_called()
        self.assertEqual(restarted.state_path.read_bytes(), before)
        self.assertTrue(all(row["errorCode"] == "NETWORK_ERROR" for row in restarted.health.values()))

    def test_cancelled_backfill_retains_completed_cache_without_success_or_state_reset(self):
        worker = self.worker()
        before = self.seed_state(worker)
        self.stages(worker)
        payload = {"report_date": "20261020", "o_trade_day": "1", "o_curinstrument": [
            {"PRODUCTGROUPID": "cu", "DELIVERYMONTH": "2611", "SETTLEMENTPRICE": "50000", "OPENINTEREST": "100"}]}
        def completed_report_then_stop(*_args, **_kwargs):
            # A completed response can enter cache just before STOP; retain it.
            worker.stop.set()
            return payload
        worker.client.get = Mock(side_effect=completed_report_then_stop)
        with redirect_stdout(io.StringIO()) as stdout:
            self.assertFalse(worker.run_cycle())
        self.assertIsNotNone(worker.cache.daily(LATEST))
        self.assertEqual(worker.state_path.read_bytes(), before)
        self.assertEqual(worker.state["failures"], 2)
        worker.publish_models.assert_called_once()
        self.assert_no_sync_result(stdout)

    def test_cancelled_no_work_backfill_cannot_fall_through_to_success(self):
        worker = self.worker()
        before = self.seed_state(worker)
        self.stages(worker)
        def cancelled_no_work(_latest):
            worker.stop.set()
            return False
        worker.backfill = Mock(side_effect=cancelled_no_work)
        with redirect_stdout(io.StringIO()) as stdout:
            self.assertFalse(worker.run_cycle())
        self.assertEqual(worker.state_path.read_bytes(), before)
        self.assert_no_sync_result(stdout)

    def test_cancellation_at_revision_read_cannot_clear_prior_failure(self):
        worker = self.worker()
        before = self.seed_state(worker)
        self.stages(worker)
        worker.backfill = Mock(return_value=False)
        worker.cache.daily = Mock(return_value={"completed": True})
        def cancel_revision(*_args, **_kwargs):
            worker.stop.set()
            return None
        worker.daily = Mock(side_effect=cancel_revision)
        with redirect_stdout(io.StringIO()) as stdout:
            self.assertFalse(worker.run_cycle())
        self.assertEqual(worker.state_path.read_bytes(), before)
        self.assert_no_sync_result(stdout)

    def test_real_errors_still_persist_failure_and_retry(self):
        for code, retry_after in (("NETWORK_ERROR", 0), ("RATE_LIMITED", 20000), ("INVALID_SOURCE", 0)):
            with self.subTest(code=code):
                worker = self.worker(continuous=True)
                worker.latest_pair = Mock(side_effect=SourceError(code, retry_after))
                with redirect_stdout(io.StringIO()) as stdout:
                    self.assertFalse(worker.run_cycle())
                persisted = json.loads(worker.state_path.read_text())
                self.assertEqual(persisted["lastErrorCode"], code)
                self.assertEqual(persisted["nextDelay"], max(7200, retry_after))
                self.assertEqual(persisted["failures"], 1)
                self.assertEqual([json.loads(line)["event"] for line in stdout.getvalue().splitlines()], ["source_sync_failed"])
                self.assertTrue(all(row["errorCode"] == code for row in worker.health.values()))
                worker.state_path.unlink()

    def test_observed_throttle_during_stop_keeps_backoff_and_stops_later_requests(self):
        for stage in ("latest_pair", "archive_manifest"):
            with self.subTest(stage=stage):
                worker = self.worker()
                self.stages(worker)
                def limited_then_stopped(*_args, **_kwargs):
                    worker.stop.set()
                    raise SourceError("RATE_LIMITED", 20000)
                setattr(worker, stage, Mock(side_effect=limited_then_stopped))
                worker.backfill = Mock(side_effect=AssertionError("no request after observed source throttle"))
                with redirect_stdout(io.StringIO()) as stdout:
                    self.assertEqual(worker.run(), 0, "normal stop still exits zero after recording real throttle")
                persisted = json.loads(worker.state_path.read_text())
                self.assertEqual(persisted["failures"], 1)
                self.assertEqual(persisted["lastErrorCode"], "RATE_LIMITED")
                self.assertEqual(persisted["nextDelay"], 20000)
                self.assertEqual(persisted["retryNotBefore"], "2026-10-22T03:33:20Z")
                worker.backfill.assert_not_called()
                self.assertEqual([json.loads(line)["event"] for line in stdout.getvalue().splitlines()], ["source_sync_failed"])
                restarted = self.worker()
                restarted.client._opener = Mock()
                self.assertFalse(restarted.run_cycle())
                restarted.client._opener.open.assert_not_called()
                worker.state_path.unlink()


if __name__ == "__main__":
    unittest.main()
