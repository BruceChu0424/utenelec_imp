import asyncio
import io
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from PIL import Image

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


if __name__ == "__main__":
    unittest.main()
