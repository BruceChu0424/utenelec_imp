"""Task-local Microsoft Word adapter for the canonical DOCX -> PNG renderer.

Uses workspace-loader managed Python, PowerShell and Poppler. Does not use or
search for any installed desktop LibreOffice, and does not modify managed code.
Only the canonical convert_to_pdf hook is replaced; OOXML repair, DPI, PDF to
PNG, and page naming are executed by canonical render_docx.py.
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys

SKILL = Path("C:/Users/bruce/.codex/plugins/cache/openai-primary-runtime/documents/26.1026.10807/skills/documents")
DEPENDENCIES = Path("C:/Users/bruce/.cache/codex-runtimes/codex-primary-runtime/dependencies")
POWERSHELL = DEPENDENCIES / "native/powershell/pwsh.exe"
POPPLER = DEPENDENCIES / "native/poppler/Library/bin"


def main() -> None:
    for required in (SKILL / "render_docx.py", POWERSHELL, POPPLER / "pdftoppm.exe", POPPLER / "pdfinfo.exe"):
        if not required.is_file():
            raise SystemExit(f"Workspace dependency unavailable: {required}")
    os.environ["PATH"] = str(POPPLER) + os.pathsep + os.environ.get("PATH", "")
    spec = importlib.util.spec_from_file_location("finance_canonical_render_docx", SKILL / "render_docx.py")
    if spec is None or spec.loader is None:
        raise SystemExit("Cannot load the canonical renderer")
    canonical = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(canonical)

    def word_convert(doc_path, user_profile, convert_tmp_dir, stem, verbose):
        del user_profile
        pdf_path = Path(convert_tmp_dir) / f"{stem}.pdf"
        command = [
            str(POWERSHELL), "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
            str(Path(__file__).with_name("render_finance_usage_guide_word.ps1")),
            "-InputPath", str(Path(doc_path).resolve()), "-OutputPath", str(pdf_path),
        ]
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
        log = f"WORD_COM_EXIT={result.returncode}\n{result.stdout.strip()}\n{result.stderr.strip()}"
        if verbose:
            print(log)
        if result.returncode or not pdf_path.is_file() or not pdf_path.stat().st_size:
            return "", log
        return str(pdf_path), log

    def forbidden_soffice():
        raise RuntimeError("Task policy prohibits desktop LibreOffice; Word COM hook was bypassed")

    canonical.convert_to_pdf = word_convert
    canonical._resolve_soffice = forbidden_soffice
    canonical.main()


if __name__ == "__main__":
    main()
