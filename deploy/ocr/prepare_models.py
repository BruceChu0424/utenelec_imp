"""Explicit operator step: download/warm fixed models before enabling the service."""
import os
os.environ.setdefault("PADDLE_PDX_CACHE_HOME", "/opt/uten-ocr/models")

from paddleocr import PaddleOCR

PaddleOCR(
    lang="ch", ocr_version="PP-OCRv5", device="cpu",
    text_detection_model_name="PP-OCRv5_mobile_det",
    text_recognition_model_name="PP-OCRv5_mobile_rec",
    textline_orientation_model_name="PP-LCNet_x1_0_textline_ori",
    use_doc_orientation_classify=False, use_doc_unwarping=False,
    use_textline_orientation=True, enable_mkldnn=False,
)
print("Model preparation finished. A sample invoice inference is still required.")
