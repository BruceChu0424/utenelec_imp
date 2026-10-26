import asyncio
import io
import threading
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from PIL import Image
from starlette.datastructures import Headers, UploadFile

import ocr_server as server


def png():
    output = io.BytesIO()
    Image.new("RGB", (40, 20), "white").save(output, format="PNG")
    return output.getvalue()


class FakeEngine:
    def predict(self, bitmap):
        yield {"rec_texts": [" 发票号码12345678 ", "价税合计￥12.34", None]}


class OcrServerTest(unittest.TestCase):
    def setUp(self):
        server._request_lock = asyncio.Lock()
        self.client = TestClient(server.app)

    def test_valid_image_returns_only_ocr_lines(self):
        with patch.object(server, "engine", return_value=FakeEngine()):
            response = self.client.post("/ocr/invoice", files={"file": ("票.png", png(), "image/png")})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["lines"][0]["text"], "发票号码12345678")
        self.assertEqual(len(response.json()["lines"]), 2)

    def test_rejects_mime_spoof_without_loading_engine(self):
        with patch.object(server, "engine") as engine:
            for data, mime in [(b"not image", "image/png"), (png(), "image/jpeg"), (png(), "image/svg+xml")]:
                response = self.client.post("/ocr/invoice", files={"file": ("invoice.png", data, mime)})
                self.assertEqual(response.status_code, 422)
            engine.assert_not_called()

    def test_supported_image_decoders_survive_the_security_upgrade(self):
        with patch.object(server, "engine", return_value=FakeEngine()) as engine:
            for image_format, mime in [("JPEG", "image/jpeg"), ("PNG", "image/png"), ("WEBP", "image/webp")]:
                with self.subTest(format=image_format):
                    output = io.BytesIO()
                    Image.new("RGB", (40, 20), "white").save(output, format=image_format)
                    response = self.client.post("/ocr/invoice", files={"file": ("invoice", output.getvalue(), mime)})
                    self.assertEqual(response.status_code, 200)
                    self.assertEqual(len(response.json()["lines"]), 2)
            self.assertEqual(engine.call_count, 3)

    def test_other_image_plugins_are_rejected_before_inference(self):
        with patch.object(server, "engine") as engine:
            for image_format in ("GIF", "TIFF"):
                with self.subTest(format=image_format):
                    output = io.BytesIO()
                    Image.new("RGB", (40, 20), "white").save(output, format=image_format)
                    response = self.client.post("/ocr/invoice", files={"file": ("invoice.png", output.getvalue(), "image/png")})
                    self.assertEqual(response.status_code, 422)
            engine.assert_not_called()

    def test_bounded_upload_size(self):
        with patch.object(server, "MAX_BYTES", 10), patch.object(server, "engine") as engine:
            response = self.client.post("/ocr/invoice", files={"file": ("invoice.png", png(), "image/png")})
            self.assertEqual(response.status_code, 413)
            engine.assert_not_called()

    def test_pixel_limit_is_checked_before_inference(self):
        with patch.object(server, "MAX_PIXELS", 10), patch.object(server, "engine") as engine:
            response = self.client.post("/ocr/invoice", files={"file": ("invoice.png", png(), "image/png")})
            self.assertEqual(response.status_code, 422)
            engine.assert_not_called()

    def test_lazy_prediction_failure_is_sanitized(self):
        class FailingEngine:
            def predict(self, bitmap):
                yield {"rec_texts": ["private invoice text"]}
                raise RuntimeError("private invoice text")
        with patch.object(server, "engine", return_value=FailingEngine()):
            response = self.client.post("/ocr/invoice", files={"file": ("invoice.png", png(), "image/png")})
            self.assertEqual(response.status_code, 502)
            self.assertNotIn("private", response.text)

    def test_health_does_not_pretend_the_engine_is_ready(self):
        with patch.object(server, "_engine", None):
            self.assertFalse(self.client.get("/health").json()["engine_loaded"])


class OcrCancellationTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        await asyncio.to_thread(lambda: __import__("numpy"))

    async def test_cancelled_request_keeps_inference_serial_until_worker_finishes(self):
        started, release, finished = threading.Event(), threading.Event(), threading.Event()
        calls = []

        class BlockingEngine:
            def predict(self, bitmap):
                calls.append(threading.get_ident())
                started.set()
                if len(calls) == 1 and not release.wait(15):
                    raise TimeoutError("test inference barrier")
                yield {"rec_texts": ["invoice"]}

        original_infer = server.infer

        def tracked_infer(*args):
            try:
                return original_infer(*args)
            finally:
                finished.set()

        def upload():
            return UploadFile(io.BytesIO(png()), filename="invoice.png",
                              headers=Headers({"content-type": "image/png"}))

        server._request_lock = asyncio.Lock()
        first = upload()
        with patch.object(server, "engine", return_value=BlockingEngine()), \
                patch.object(server, "infer", side_effect=tracked_infer):
            task = asyncio.create_task(server.ocr_invoice(first))
            try:
                self.assertTrue(await asyncio.to_thread(started.wait, 15))
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
                self.assertFalse(finished.is_set())
                second = upload()
                with self.assertRaises(server.HTTPException) as busy:
                    await server.ocr_invoice(second)
                self.assertEqual(busy.exception.status_code, 429)
                self.assertTrue(second.file.closed)
                self.assertEqual(len(calls), 1)
            finally:
                release.set()
                self.assertTrue(await asyncio.to_thread(finished.wait, 15))
                if not task.done():
                    await task
            result = await server.ocr_invoice(upload())
            self.assertEqual(result.lines[0].text, "invoice")
            self.assertEqual(len(calls), 2)
        self.assertTrue(first.file.closed)


if __name__ == "__main__":
    unittest.main()
