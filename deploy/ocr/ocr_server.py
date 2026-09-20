"""Local PaddleOCR sidecar. Document bytes are never sent to external AI APIs."""
import asyncio
import io
import logging
import os
import threading
import warnings
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, UploadFile
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

app = FastAPI(title="uten-paddle-ocr", version="2", docs_url=None, redoc_url=None)
logger = logging.getLogger("uten-ocr")
MAX_BYTES = 8 * 1024 * 1024
MAX_PIXELS = 40_000_000
Image.MAX_IMAGE_PIXELS = MAX_PIXELS
_engine = None
_engine_lock = threading.Lock()
_request_lock = asyncio.Lock()


def engine():
    global _engine
    if _engine is None:
        with _engine_lock:
            if _engine is None:
                from paddleocr import PaddleOCR
                cache = Path(os.environ.get("PADDLE_PDX_CACHE_HOME", "/opt/uten-ocr/models")) / "official_models"
                model_names = {
                    "text_detection": "PP-OCRv5_mobile_det",
                    "text_recognition": "PP-OCRv5_mobile_rec",
                    "textline_orientation": "PP-LCNet_x1_0_textline_ori",
                }
                options = {}
                for kind, name in model_names.items():
                    model_dir = cache / name
                    if not model_dir.is_dir():
                        raise RuntimeError("OCR model cache is incomplete; prepare models before activation")
                    options[f"{kind}_model_name"] = name
                    options[f"{kind}_model_dir"] = str(model_dir)
                _engine = PaddleOCR(
                    lang="ch", ocr_version="PP-OCRv5", device="cpu",
                    use_doc_orientation_classify=False, use_doc_unwarping=False,
                    use_textline_orientation=True, enable_mkldnn=False,
                    **options,
                )
    return _engine


class Line(BaseModel):
    text: str


class OcrResult(BaseModel):
    lines: list[Line]


@app.get("/health")
def health():
    # Liveness only; sample inference remains necessary for deployment acceptance.
    return {"status": "ok", "engine_loaded": _engine is not None}


def infer(raw: bytes, content_type: str) -> OcrResult:
    expected_format = {"image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WEBP"}
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(raw)) as source:
                if source.format != expected_format.get(content_type):
                    raise HTTPException(422, "image content does not match its type")
                width, height = source.size
                if width * height > MAX_PIXELS or max(width, height) > 30000:
                    raise HTTPException(422, "image dimensions exceed limit")
                if getattr(source, "n_frames", 1) != 1:
                    raise HTTPException(422, "animated images are not supported")
                source.verify()
        import numpy as np
        with Image.open(io.BytesIO(raw)) as source:
            bitmap = np.asarray(source.convert("RGB"))[:, :, ::-1].copy()
    except HTTPException:
        raise
    except (UnidentifiedImageError, OSError, ValueError,
            Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise HTTPException(422, "invalid or oversized image") from None
    try:
        texts = []
        # Materialize lazy prediction inside the guard; never stringify unknown objects.
        for page in engine().predict(bitmap):
            values = page.get("rec_texts", [])
            if not isinstance(values, (list, tuple)):
                raise ValueError("unsupported OCR response")
            for value in values:
                if isinstance(value, str) and value.strip():
                    texts.append(Line(text=value.strip()[:2000]))
                    if len(texts) > 2000:
                        raise ValueError("too many OCR lines")
        return OcrResult(lines=texts)
    except Exception as error:
        logger.warning("OCR inference failed: %s", type(error).__name__)
        raise HTTPException(502, "ocr engine failed") from None


@app.post("/ocr/invoice", response_model=OcrResult)
async def ocr_invoice(file: UploadFile = File(...)):
    try:
        if file.content_type not in {"image/jpeg", "image/png", "image/webp"}:
            raise HTTPException(422, "only JPEG, PNG and WebP are supported")
        if _request_lock.locked():
            raise HTTPException(429, "ocr engine is busy")
        async with _request_lock:
            raw = await file.read(MAX_BYTES + 1)
            if not raw:
                raise HTTPException(422, "empty file")
            if len(raw) > MAX_BYTES:
                raise HTTPException(413, "file too large")
            return await run_in_threadpool(infer, raw, file.content_type)
    finally:
        await file.close()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("UTEN_OCR_PORT", "8501")))
