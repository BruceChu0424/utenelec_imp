"""Build/check the self-hosted CSP-safe PDF worker; no network or new tools."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "tool/pdf_worker.dart",
    "lib/core/print/print_pdf_document.dart",
    "lib/core/performance/ui_work_budget.dart",
    "pubspec.lock",
)
OUTPUT = ROOT / "assets/workers/uten_pdf_worker.js"
RECEIPT = ROOT / "assets/workers/uten_pdf_worker.build.json"
FLAGS = ["-O2", "--csp", "--no-source-maps"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    # Git may check out pubspec.lock with CRLF on Windows. Text identity must
    # remain stable across Windows/Linux; generated worker bytes stay exact.
    sources = {name: hashlib.sha256((ROOT / name).read_bytes().replace(b"\r\n", b"\n")).hexdigest() for name in SOURCES}
    if args.check:
        receipt = json.loads(RECEIPT.read_text(encoding="utf-8"))
        if receipt.get("sourceTextNormalization") != "LF" or receipt["sources"] != sources or receipt["workerSha256"] != digest(OUTPUT) or receipt["flags"] != FLAGS:
            raise SystemExit("PDF worker differs from its reviewed sources; run python tool/build_pdf_worker.py")
        print(f"PDF_WORKER_MATCH bytes={OUTPUT.stat().st_size} sha256={receipt['workerSha256']}")
        return
    dart = shutil.which("dart")
    if dart is None:
        raise SystemExit("Dart SDK from the configured Flutter toolchain is required")
    version = subprocess.run([dart, "--version"], capture_output=True, text=True, check=True)
    with tempfile.TemporaryDirectory(prefix="uten-pdf-worker-") as temporary:
        built = Path(temporary) / "uten_pdf_worker.js"
        subprocess.run([dart, "compile", "js", *FLAGS, "tool/pdf_worker.dart", "-o", str(built)], cwd=ROOT, check=True)
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_bytes(built.read_bytes())
    receipt = {
        "format": "uten-pdf-worker-v1", "compiler": (version.stdout + version.stderr).strip(),
        "flags": FLAGS, "sources": sources, "workerSha256": digest(OUTPUT), "workerBytes": OUTPUT.stat().st_size,
        "protocolVersion": 1, "sourceTextNormalization": "LF",
    }
    RECEIPT.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"PDF_WORKER_BUILT bytes={OUTPUT.stat().st_size} sha256={receipt['workerSha256']}")


if __name__ == "__main__":
    main()
