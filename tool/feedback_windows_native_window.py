"""Test-only file handshake for one owned real Windows Flutter application.

No foreign window is changed: its process executable must equal this worktree's
Debug output. Window geometry comes from user32, never a fake Flutter view.
"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import threading


class NativeWindowEvidenceDriver:
    def __init__(self, output: Path, executable: Path, source_head: str, scenario: str):
        if os.name != "nt":
            raise RuntimeError("Actual window evidence requires Windows")
        self.output = output.resolve()
        self.executable = os.path.normcase(str(executable.resolve()))
        self.source_head = source_head
        if scenario not in {"original-714", "supported-min800", "below-min714"}:
            raise ValueError("Unknown native geometry scenario")
        self.scenario = scenario
        self.pinned_window: tuple[int, int] | None = None
        self.stop = threading.Event()
        self.ready = threading.Event()
        self.startup_error: Exception | None = None
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.seen: set[str] = set()

    def start(self):
        self.thread.start()
        if not self.ready.wait(timeout=5):
            raise RuntimeError("Owned native window driver did not initialize")
        if self.startup_error is not None:
            raise RuntimeError("Owned native window driver initialization failed") from self.startup_error

    def close(self):
        self.stop.set()
        self.thread.join(timeout=3)

    def _serve(self):
        try:
            self._serve_windows()
        except Exception as error:
            self.startup_error = error
            self.ready.set()

    def _serve_windows(self):
        user = ctypes.WinDLL("user32", use_last_error=True)
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        user.SetThreadDpiAwarenessContext.argtypes = [ctypes.c_void_p]
        user.SetThreadDpiAwarenessContext.restype = ctypes.c_void_p
        user.SetThreadDpiAwarenessContext(ctypes.c_void_p(-4))
        user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        user.GetWindow.argtypes = [wintypes.HWND, wintypes.UINT]
        user.GetWindow.restype = wintypes.HWND
        user.IsWindowVisible.argtypes = [wintypes.HWND]
        user.IsWindow.argtypes = [wintypes.HWND]
        user.IsWindow.restype = wintypes.BOOL
        user.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
        user.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
        user.GetDpiForWindow.argtypes = [wintypes.HWND]
        user.GetDpiForWindow.restype = wintypes.UINT
        user.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
        user.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
        user.EnumWindows.restype = wintypes.BOOL
        self.ready.set()

        def geometry(hwnd):
            client, window = wintypes.RECT(), wintypes.RECT()
            if not user.GetClientRect(hwnd, ctypes.byref(client)) or not user.GetWindowRect(hwnd, ctypes.byref(window)):
                raise ctypes.WinError(ctypes.get_last_error())
            dpi = user.GetDpiForWindow(hwnd)
            if not dpi:
                raise RuntimeError("The owned native window has no DPI")
            return {"clientPhysicalWidth": client.right - client.left,
                    "clientPhysicalHeight": client.bottom - client.top,
                    "outerPhysicalWidth": window.right - window.left,
                    "outerPhysicalHeight": window.bottom - window.top,
                    "dpi": dpi,
                    "clientLogicalWidth": (client.right - client.left) * 96 / dpi,
                    "clientLogicalHeight": (client.bottom - client.top) * 96 / dpi}

        def find_owned():
            matches = []

            @callback_type
            def visit(hwnd, _):
                if not user.IsWindowVisible(hwnd) or user.GetWindow(hwnd, 4):
                    return True
                pid = wintypes.DWORD()
                user.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                handle = kernel.OpenProcess(0x1000, False, pid.value)
                if not handle:
                    return True
                try:
                    length = wintypes.DWORD(32768)
                    buffer = ctypes.create_unicode_buffer(length.value)
                    if kernel.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(length)) and os.path.normcase(buffer.value) == self.executable:
                        matches.append((hwnd, pid.value))
                finally:
                    kernel.CloseHandle(handle)
                return True

            user.EnumWindows(visit, 0)
            if len(matches) != 1:
                raise RuntimeError(f"Expected one visible owned application window; found {len(matches)}")
            return matches[0]

        while not self.stop.wait(0.025):
            for request in sorted(self.output.glob("native-window-request-*.json")):
                if request.name in self.seen:
                    continue
                self.seen.add(request.name)
                result = {"request": request.name, "ok": False, "sourceHead": self.source_head}
                data = None
                validated = False
                try:
                    data = json.loads(request.read_text(encoding="utf-8"))
                    if set(data) != {"sourceHead", "sequence", "width", "height", "phase", "scenario"} or data["sourceHead"] != self.source_head or data["scenario"] != self.scenario:
                        raise RuntimeError("Native window request left the committed test identity")
                    width, height = data["width"], data["height"]
                    if not isinstance(width, (int, float)) or not isinstance(height, (int, float)) or not 600 <= width <= 4000 or not 600 <= height <= 2160:
                        raise RuntimeError("Native window request exceeds the reviewed test geometry")
                    narrow = 800 if self.scenario == "supported-min800" else 714
                    if (width, height) not in {(1280, 900), (narrow, 764)}:
                        raise RuntimeError("Native window request is not a reviewed wide/narrow geometry")
                    validated = True
                    hwnd, pid = find_owned()
                    identity = (int(hwnd), pid)
                    if self.pinned_window is None:
                        self.pinned_window = identity
                    elif self.pinned_window != identity:
                        raise RuntimeError("The run's owned process/HWND changed; no replacement window is resized")
                    # Same no-activation normalization as the production runner.
                    user.ShowWindow(hwnd, 4)  # SW_SHOWNOACTIVATE
                    before = geometry(hwnd)
                    scale = before["dpi"] / 96
                    outer_width = round(width * scale) + before["outerPhysicalWidth"] - before["clientPhysicalWidth"]
                    outer_height = round(height * scale) + before["outerPhysicalHeight"] - before["clientPhysicalHeight"]
                    flags = 0x0002 | 0x0004 | 0x0010
                    below_min_stress = self.scenario == "below-min714" and width == 714
                    if below_min_stress:
                        # Explicit test-only programmatic geometry stress. No
                        # product min-track handler, style or OS setting changes.
                        flags |= 0x0400  # SWP_NOSENDCHANGING
                    if not user.SetWindowPos(hwnd, None, 0, 0, outer_width, outer_height, flags):
                        raise ctypes.WinError(ctypes.get_last_error())
                    after = geometry(hwnd)
                    result.update(ok=True, sequence=data["sequence"], phase=data["phase"], requestedLogicalWidth=width,
                                  requestedLogicalHeight=height, processId=pid, executable=self.executable,
                                  hwnd=int(hwnd), before=before, after=after, nativeApi="user32.SetWindowPos")
                    result.update(scenario=self.scenario, setWindowPosFlags=flags,
                                  setWindowPosFlagNames=["SWP_NOMOVE", "SWP_NOZORDER", "SWP_NOACTIVATE"] + (["SWP_NOSENDCHANGING"] if below_min_stress else []),
                                  belowInteractiveMinimumStress=below_min_stress,
                                  productionMinimumPolicyChanged=False)
                except Exception as error:
                    # Only terminal cleanup may accept a destroyed *pinned*
                    # HWND. A missing window in any scenario step stays fatal.
                    closed_window_error = (isinstance(error, OSError) and getattr(error, "winerror", None) == 1400
                                           or isinstance(error, RuntimeError) and str(error) == "Expected one visible owned application window; found 0")
                    if (closed_window_error and validated and data is not None and data.get("phase") == "cleanup-native-wide"
                            and self.pinned_window is not None
                            and not user.IsWindow(self.pinned_window[0])):
                        result.update(ok=True, phase=data["phase"],
                                      expectedWindowAlreadyClosed=True,
                                      processId=self.pinned_window[1], hwnd=self.pinned_window[0],
                                      replacementWindowsTouched=False,
                                      observedCleanupErrorType=type(error).__name__)
                    else:
                        result.update(errorType=type(error).__name__, message=str(error))
                destination = self.output / request.name.replace("request", "result")
                temporary = destination.with_suffix(".tmp")
                temporary.write_text(json.dumps(result, indent=2), encoding="utf-8")
                temporary.replace(destination)
