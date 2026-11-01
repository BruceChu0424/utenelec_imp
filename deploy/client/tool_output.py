"""One text-output policy for the UTF-8 release toolchain, independent of OS locale.

Backslash escapes preserve any legacy non-UTF-8 diagnostic bytes instead of
crashing subprocess reader threads or silently discarding their messages.
"""
from pathlib import Path

UTF8_TOOL_OUTPUT = {"text": True, "encoding": "utf-8", "errors": "backslashreplace"}


def save_tool_output(directory: Path, name: str, result) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for stream in ("stdout", "stderr"):
        (directory / f"{name}.{stream}.log").write_text(
            getattr(result, stream, "") or "", encoding="utf-8")
