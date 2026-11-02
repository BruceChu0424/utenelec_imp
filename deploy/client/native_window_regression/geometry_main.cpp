#include <windows.h>

#include <cstdio>

#include "win32_window.h"

class GeometryWindow : public Win32Window {
 public:
  LRESULT Calculate(WPARAM shape, LPARAM rectangle) {
    return MessageHandler(GetHandle(), WM_NCCALCSIZE, shape, rectangle);
  }
};

bool Same(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right &&
         a.bottom == b.bottom;
}

int main() {
  // A hidden development window only: never focus or cover the user's ERP.
  SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  GeometryWindow window;
  if (!window.Create(L"UTEN hidden client geometry regression", {20, 20},
                     {1000, 700}) || !window.SetMainWindowMode(true)) return 2;
  const HWND hwnd = window.GetHandle();
  const LONG_PTR restored = GetWindowLongPtr(hwnd, GWL_STYLE);
  SetWindowLongPtr(hwnd, GWL_STYLE, restored | WS_MAXIMIZE);
  if (!IsZoomed(hwnd) || IsWindowVisible(hwnd)) return 3;
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                      &monitor)) return 4;
  const RECT expected = monitor.rcWork;
  const UINT dpi = GetDpiForWindow(hwnd);
  const int x = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  const int y = GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
                GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  const RECT overhang{expected.left - x, expected.top - y,
                      expected.right + x, expected.bottom + y};
  NCCALCSIZE_PARAMS params{};
  params.rgrc[0] = overhang;
  window.Calculate(TRUE, reinterpret_cast<LPARAM>(&params));
  RECT simple = overhang;
  window.Calculate(FALSE, reinterpret_cast<LPARAM>(&simple));
  const bool maximized = Same(params.rgrc[0], expected) && Same(simple, expected);
  params.rgrc[0] = expected;
  window.Calculate(TRUE, reinterpret_cast<LPARAM>(&params));
  const bool exact = Same(params.rgrc[0], expected);
  const HWND child = CreateWindowEx(0, L"STATIC", L"", WS_CHILD,
                                    0, 0, 1, 1, hwnd, nullptr,
                                    GetModuleHandle(nullptr), nullptr);
  if (child == nullptr) return 5;
  window.SetChildContent(child);
  if (!SetWindowPos(hwnd, nullptr, overhang.left, overhang.top,
                    overhang.right - overhang.left,
                    overhang.bottom - overhang.top,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) return 6;
  RECT client{};
  RECT child_bounds{};
  POINT origin{};
  GetClientRect(hwnd, &client);
  ClientToScreen(hwnd, &origin);
  OffsetRect(&client, origin.x, origin.y);
  GetWindowRect(child, &child_bounds);
  const bool physical = Same(client, expected) && Same(child_bounds, expected);
  SetWindowLongPtr(hwnd, GWL_STYLE, restored);
  RECT normal{expected.left + 30, expected.top + 30,
              expected.left + 830, expected.top + 630};
  const RECT original = normal;
  window.Calculate(FALSE, reinterpret_cast<LPARAM>(&normal));
  const bool restored_ok = Same(normal, original);
  std::printf("{\"maximizedBothForms\":%s,\"alreadyExact\":%s,"
              "\"physicalClientAndChild\":%s,\"restoredUnchanged\":%s,\"visible\":%s,\"dpi\":%u,"
              "\"work\":[%ld,%ld,%ld,%ld],\"client\":[%ld,%ld,%ld,%ld]}\n",
              maximized ? "true" : "false", exact ? "true" : "false",
              physical ? "true" : "false",
              restored_ok ? "true" : "false",
              IsWindowVisible(hwnd) ? "true" : "false", dpi,
              expected.left, expected.top, expected.right, expected.bottom,
              simple.left, simple.top, simple.right, simple.bottom);
  return maximized && exact && physical && restored_ok ? 0 : 1;
}
