#include <flutter/dart_project.h>
#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <sstream>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {
constexpr UINT_PTR kHarnessTimer = 0x7a51;
HANDLE g_log = INVALID_HANDLE_VALUE;
HANDLE g_result = INVALID_HANDLE_VALUE;
volatile LONG g_step = -1;

std::string Escape(const std::string& text) {
  std::string result;
  for (const char character : text) {
    if (character == '\\' || character == '"') result += '\\';
    if (character == '\n') {
      result += "\\n";
    } else if (character == '\r') {
      result += "\\r";
    } else {
      result += character;
    }
  }
  return result;
}

void WriteBytes(HANDLE handle, const char* data, DWORD length) {
  if (handle == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(handle, data, length, &written, nullptr);
  FlushFileBuffers(handle);
}

void Log(const std::string& entry) {
  const std::string line = entry + "\n";
  WriteBytes(g_log, line.c_str(), static_cast<DWORD>(line.size()));
}

void Result(const std::string& entry) {
  LARGE_INTEGER zero{};
  SetFilePointerEx(g_result, zero, nullptr, FILE_BEGIN);
  SetEndOfFile(g_result);
  WriteBytes(g_result, entry.c_str(), static_cast<DWORD>(entry.size()));
}

LONG WINAPI CaptureException(EXCEPTION_POINTERS* pointers) {
  char receipt[512]{};
  const unsigned long code = pointers->ExceptionRecord->ExceptionCode;
  const auto address = reinterpret_cast<unsigned long long>(
      pointers->ExceptionRecord->ExceptionAddress);
  const int length = sprintf_s(
      receipt,
      "{\"status\":\"exception\",\"step\":%ld,\"exceptionCode\":\"0x%08lx\","
      "\"exceptionAddress\":\"0x%llx\"}\n",
      g_step, code, address);
  if (length > 0) {
    WriteBytes(g_log, receipt, static_cast<DWORD>(length));
    LARGE_INTEGER zero{};
    SetFilePointerEx(g_result, zero, nullptr, FILE_BEGIN);
    SetEndOfFile(g_result);
    WriteBytes(g_result, receipt, static_cast<DWORD>(length));
  }
  // Preserve normal Windows crash reporting and dumps.
  return EXCEPTION_CONTINUE_SEARCH;
}

struct Options {
  UINT start_delay_ms = 30000;
  UINT step_ms = 1000;
  std::string receipt_directory = "receipts";
  std::string accessibility_mode = "default";
  bool extended = false;
};

bool NumberOption(const std::string& text, const std::string& prefix, UINT& value) {
  if (text.rfind(prefix, 0) != 0) return false;
  char* end = nullptr;
  const unsigned long parsed = strtoul(text.c_str() + prefix.size(), &end, 10);
  if (end == nullptr || *end != '\0' || parsed < 100 || parsed > 300000) return false;
  value = static_cast<UINT>(parsed);
  return true;
}

enum class ActionKind { toggle, minimize, show, restore_native, resize };
struct Action {
  ActionKind kind;
  std::string name;
  bool maximized;
  bool minimized;
  bool check_maximized = true;
  int logical_width = 0;
  int logical_height = 0;
  UINT hold_after_ms = 0;
};

class RegressionWindow : public FlutterWindow {
 public:
  RegressionWindow(const flutter::DartProject& project, const Options& options)
      : FlutterWindow(project), options_(options) {
    for (int cycle = 1; cycle <= 10; ++cycle) {
      actions_.push_back({ActionKind::toggle, "maximize_" + std::to_string(cycle), true, false});
      actions_.push_back({ActionKind::toggle, "restore_" + std::to_string(cycle), false, false});
    }
    for (int cycle = 1; cycle <= 5; ++cycle) {
      actions_.push_back({ActionKind::minimize, "minimize_" + std::to_string(cycle), false, true});
      actions_.push_back({ActionKind::show, "show_" + std::to_string(cycle), false, false});
    }
    if (options.extended) {
      for (int cycle = 1; cycle <= 5; ++cycle) {
        const std::string suffix = std::to_string(cycle);
        actions_.push_back({ActionKind::toggle, "extended_maximize_" + suffix, true, false});
        // IsZoomed need not describe the pre-minimize placement while iconic.
        // Require an iconic state here, then strictly check maximization after
        // SW_RESTORE rather than inferring it from the previous state.
        actions_.push_back({ActionKind::minimize, "extended_minimize_" + suffix,
                            false, true, false});
        Action restore{ActionKind::restore_native, "restore_to_maximized_" + suffix,
                       true, false};
        restore.hold_after_ms = 2000;
        actions_.push_back(std::move(restore));
        actions_.push_back({ActionKind::toggle, "extended_restore_normal_" + suffix,
                            false, false});
      }
      actions_.push_back({ActionKind::resize, "resize_960x720", false, false, true, 960, 720});
      actions_.push_back({ActionKind::resize, "resize_1280x800", false, false, true, 1280, 800});
      actions_.push_back({ActionKind::resize, "resize_1080x740", false, false, true, 1080, 740});
    }
  }

  int exit_code() const { return exit_code_; }

 protected:
  bool OnCreate() override {
    if (!FlutterWindow::OnCreate()) return false;
    if (!SetTimer(GetHandle(), kHarnessTimer, options_.start_delay_ms, nullptr)) return false;
    SetUnhandledExceptionFilter(CaptureException);
    Log("{\"event\":\"flutter_created\",\"pid\":" + std::to_string(GetCurrentProcessId()) +
        ",\"hwnd\":" + std::to_string(reinterpret_cast<uintptr_t>(GetHandle())) +
        ",\"startDelayMs\":" + std::to_string(options_.start_delay_ms) +
        ",\"plannedActions\":" + std::to_string(actions_.size()) +
        ",\"extended\":" + std::string(options_.extended ? "true" : "false") +
        ",\"accessibilityMode\":\"" + Escape(options_.accessibility_mode) + "\"}");
    return true;
  }

  LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept override {
    if (message == WM_TIMER && wparam == kHarnessTimer) {
      Tick();
      return 0;
    }
    if (message == WM_DESTROY && !finished_) Finish(false, "window_destroyed_before_completion");
    return FlutterWindow::MessageHandler(window, message, wparam, lparam);
  }

 private:
  void State(const char* event, const std::string& action) {
    RECT rectangle{};
    GetWindowRect(GetHandle(), &rectangle);
    const auto style = static_cast<DWORD>(GetWindowLongPtr(GetHandle(), GWL_STYLE));
    const HWND focus = GetFocus();
    const HWND content_child = GetWindow(GetHandle(), GW_CHILD);
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    const bool placement_valid = GetWindowPlacement(GetHandle(), &placement) != FALSE;
    std::ostringstream entry;
    entry << "{\"event\":\"" << event << "\",\"step\":" << action_index_
          << ",\"action\":\"" << Escape(action) << "\",\"tickMs\":" << GetTickCount64()
          << ",\"maximized\":" << (IsZoomed(GetHandle()) ? "true" : "false")
          << ",\"minimized\":" << (IsIconic(GetHandle()) ? "true" : "false")
          << ",\"windowStyle\":" << style
          << ",\"hasCaption\":" << ((style & WS_CAPTION) == WS_CAPTION ? "true" : "false")
          << ",\"hasThickFrame\":" << ((style & WS_THICKFRAME) != 0 ? "true" : "false")
          << ",\"focusWindow\":" << reinterpret_cast<uintptr_t>(focus)
          << ",\"contentChildWindow\":" << reinterpret_cast<uintptr_t>(content_child)
          << ",\"focusIsContentChild\":" << (focus != nullptr && focus == content_child ? "true" : "false")
          << ",\"focusBelongsToWindow\":" << (focus != nullptr && GetAncestor(focus, GA_ROOT) == GetHandle() ? "true" : "false")
          << ",\"foreground\":" << (GetForegroundWindow() == GetHandle() ? "true" : "false")
          << ",\"placementValid\":" << (placement_valid ? "true" : "false")
          << ",\"placementFlags\":" << placement.flags
          << ",\"placementShowCommand\":" << placement.showCmd
          << ",\"rect\":[" << rectangle.left << ',' << rectangle.top << ','
          << rectangle.right << ',' << rectangle.bottom << "]}";
    Log(entry.str());
  }

  void Finish(bool success, const std::string& reason) {
    if (finished_) return;
    finished_ = true;
    exit_code_ = success ? 0 : 2;
    KillTimer(GetHandle(), kHarnessTimer);
    const std::string receipt = "{\"status\":\"" + std::string(success ? "passed" : "failed") +
        "\",\"reason\":\"" + Escape(reason) + "\",\"completedActions\":" +
        std::to_string(action_index_) + ",\"plannedActions\":" +
        std::to_string(actions_.size()) + ",\"realFlutterEngine\":true,\"accessibilityMode\":\"" +
        Escape(options_.accessibility_mode) + "\",\"extended\":" +
        std::string(options_.extended ? "true" : "false") + ",\"finalUiaReadWindowMs\":2000}";
    Result(receipt);
    Log(receipt);
    CloseWindow();
  }

  void Tick() {
    if (finished_) return;
    if (!started_) {
      started_ = true;
      if (!SetMainWindowMode(true)) {
        Finish(false, "set_main_mode_failed");
        return;
      }
      SetTimer(GetHandle(), kHarnessTimer, options_.step_ms, nullptr);
      State("main_mode_ready", "set_main_mode");
      return;
    }
    if (hold_until_ != 0) {
      if (GetTickCount64() < hold_until_) return;
      hold_until_ = 0;
    }
    if (pending_) {
      const Action& action = actions_[action_index_];
      bool matched = (!action.check_maximized ||
                      (IsZoomed(GetHandle()) != FALSE) == action.maximized) &&
                     (IsIconic(GetHandle()) != FALSE) == action.minimized;
      if (action.kind == ActionKind::resize) {
        RECT bounds{};
        matched = matched && GetWindowRect(GetHandle(), &bounds) != FALSE &&
                  bounds.right - bounds.left == pending_width_ &&
                  bounds.bottom - bounds.top == pending_height_;
      }
      State(matched ? "verified" : "waiting", action.name);
      if (!matched) {
        if (++attempts_ >= 5) Finish(false, "window_state_timeout_" + action.name);
        return;
      }
      ++action_index_;
      pending_ = false;
      if (action.hold_after_ms != 0) {
        hold_until_ = GetTickCount64() + action.hold_after_ms;
        State("uia_read_hold", action.name);
        return;
      }
    }
    if (action_index_ == actions_.size()) {
      if (!settling_) {
        settling_ = true;
        State("uia_final_read_window", "all_actions_verified");
        SetTimer(GetHandle(), kHarnessTimer, 2000, nullptr);
        return;
      }
      Finish(true, "all_native_window_actions_verified");
      return;
    }
    const Action& action = actions_[action_index_];
    InterlockedExchange(&g_step, static_cast<LONG>(action_index_));
    State("before", action.name);
    bool requested = true;
    switch (action.kind) {
      case ActionKind::toggle:
        requested = ToggleMaximizeWindow();
        break;
      case ActionKind::minimize:
        requested = MinimizeWindow();
        break;
      case ActionKind::show:
        Show();
        break;
      case ActionKind::restore_native:
        // Match taskbar/system restoration, preserving the pre-minimize state.
        ::ShowWindow(GetHandle(), SW_RESTORE);
        break;
      case ActionKind::resize: {
        MONITORINFO monitor{};
        monitor.cbSize = sizeof(monitor);
        requested = GetMonitorInfo(
            MonitorFromWindow(GetHandle(), MONITOR_DEFAULTTONEAREST), &monitor) != FALSE;
        if (!requested) break;
        UINT dpi = GetDpiForWindow(GetHandle());
        if (dpi == 0) dpi = 96;
        const LONG work_width = monitor.rcWork.right - monitor.rcWork.left;
        const LONG work_height = monitor.rcWork.bottom - monitor.rcWork.top;
        pending_width_ = std::min<LONG>(MulDiv(action.logical_width, dpi, 96), work_width);
        pending_height_ = std::min<LONG>(MulDiv(action.logical_height, dpi, 96), work_height);
        // One discrete placement per test action; no interpolated resize loop.
        requested = SetWindowPos(GetHandle(), nullptr,
            monitor.rcWork.left + (work_width - pending_width_) / 2,
            monitor.rcWork.top + (work_height - pending_height_) / 2,
            pending_width_, pending_height_, SWP_NOZORDER | SWP_NOACTIVATE) != FALSE;
        Log("{\"event\":\"resize_target\",\"step\":" + std::to_string(action_index_) +
            ",\"width\":" + std::to_string(pending_width_) +
            ",\"height\":" + std::to_string(pending_height_) + "}");
        break;
      }
    }
    if (!requested) {
      Finish(false, "native_action_rejected_" + action.name);
      return;
    }
    pending_ = true;
    attempts_ = 0;
    State("requested", action.name);
  }

  Options options_;
  std::vector<Action> actions_;
  size_t action_index_ = 0;
  unsigned attempts_ = 0;
  ULONGLONG hold_until_ = 0;
  LONG pending_width_ = 0;
  LONG pending_height_ = 0;
  bool started_ = false;
  bool pending_ = false;
  bool settling_ = false;
  bool finished_ = false;
  int exit_code_ = 2;
};
}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  Options options;
  for (const std::string& argument : GetCommandLineArguments()) {
    if (argument == "--extended") {
      options.extended = true;
      continue;
    }
    if (NumberOption(argument, "--start-delay-ms=", options.start_delay_ms) ||
        NumberOption(argument, "--step-ms=", options.step_ms)) continue;
    if (argument.rfind("--receipt-dir=", 0) == 0) options.receipt_directory = argument.substr(14);
    if (argument.rfind("--accessibility-mode=", 0) == 0) options.accessibility_mode = argument.substr(21);
  }
  std::error_code filesystem_error;
  const auto receipt_directory = std::filesystem::u8path(options.receipt_directory);
  std::filesystem::create_directories(receipt_directory, filesystem_error);
  if (filesystem_error) return 3;
  g_log = CreateFileW((receipt_directory / L"steps.jsonl").c_str(), GENERIC_WRITE,
                     FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  g_result = CreateFileW((receipt_directory / L"result.json").c_str(), GENERIC_WRITE,
                        FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (g_log == INVALID_HANDLE_VALUE || g_result == INVALID_HANDLE_VALUE) return 3;
  Result("{\"status\":\"running\",\"realFlutterEngine\":true}");
  SetUnhandledExceptionFilter(CaptureException);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  flutter::DartProject project(L"data");
  if (options.accessibility_mode == "legacy") {
    project.set_accessibility_mode(flutter::AccessibilityMode::IAccessible);
  } else if (options.accessibility_mode == "native") {
    project.set_accessibility_mode(flutter::AccessibilityMode::IAccessibleEx);
  } else if (options.accessibility_mode != "default") {
    Result("{\"status\":\"failed\",\"reason\":\"invalid_accessibility_mode\"}");
    return 3;
  }
  RegressionWindow window(project, options);
  if (!window.Create(L"UTEN Native Window Regression", Win32Window::Point(10, 10),
                     Win32Window::Size(800, 540))) {
    Result("{\"status\":\"failed\",\"reason\":\"flutter_window_create_failed\"}");
    return 3;
  }
  window.SetQuitOnClose(true);
  MSG message{};
  while (GetMessage(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessage(&message);
  }
  CoUninitialize();
  CloseHandle(g_log);
  CloseHandle(g_result);
  g_log = g_result = INVALID_HANDLE_VALUE;
  return window.exit_code();
}
