#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <algorithm>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr DWORD kLoginWindowStyle =
    WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
constexpr DWORD kMainWindowStyle = WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN;
constexpr UINT kBeginWindowDrag = WM_APP + 0x351;

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindowEx(
      WS_EX_APPWINDOW, window_class, title.c_str(), kLoginWindowStyle,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  CenterClientSize(static_cast<int>(size.width), static_cast<int>(size.height));

  return OnCreate();
}

bool Win32Window::Show() {
  shown_ = true;
  const int command = main_mode_ && has_main_placement_ &&
                              main_placement_.showCmd == SW_SHOWMAXIMIZED
                          ? SW_SHOWMAXIMIZED
                          : SW_SHOWNORMAL;
  return ShowWindow(window_handle_, command);
}

void Win32Window::CenterClientSize(int width, int height) {
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  const HMONITOR monitor =
      MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
  if (!GetMonitorInfo(monitor, &monitor_info)) return;
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  RECT bounds = {0, 0, Scale(width, scale), Scale(height, scale)};
  const auto style = static_cast<DWORD>(GetWindowLongPtr(window_handle_, GWL_STYLE));
  const auto extended_style =
      static_cast<DWORD>(GetWindowLongPtr(window_handle_, GWL_EXSTYLE));
  AdjustWindowRectExForDpi(&bounds, style, FALSE, extended_style,
                          FlutterDesktopGetDpiForMonitor(monitor));
  const RECT& work = monitor_info.rcWork;
  const LONG outer_width = std::min(bounds.right - bounds.left,
                                    work.right - work.left);
  const LONG outer_height = std::min(bounds.bottom - bounds.top,
                                     work.bottom - work.top);
  SetWindowPos(window_handle_, nullptr,
               work.left + (work.right - work.left - outer_width) / 2,
               work.top + (work.bottom - work.top - outer_height) / 2,
               outer_width, outer_height,
               SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

void Win32Window::ConstrainToWorkArea() {
  if (IsIconic(window_handle_) || IsZoomed(window_handle_)) return;
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!GetMonitorInfo(MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST),
                       &monitor_info)) return;
  RECT bounds = {};
  if (!GetWindowRect(window_handle_, &bounds)) return;
  const RECT& work = monitor_info.rcWork;
  const LONG width = std::min(bounds.right - bounds.left, work.right - work.left);
  const LONG height = std::min(bounds.bottom - bounds.top, work.bottom - work.top);
  const LONG left = std::clamp(bounds.left, work.left, work.right - width);
  const LONG top = std::clamp(bounds.top, work.top, work.bottom - height);
  if (left != bounds.left || top != bounds.top ||
      width != bounds.right - bounds.left || height != bounds.bottom - bounds.top) {
    SetWindowPos(window_handle_, nullptr, left, top, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE);
  }
}

bool Win32Window::SetMainWindowMode(bool main_mode) {
  if (!IsWindow(window_handle_)) return false;
  if (main_mode == main_mode_) return true;
  const bool visible = shown_;
  if (main_mode_) {
    main_placement_.length = sizeof(main_placement_);
    has_main_placement_ = GetWindowPlacement(window_handle_, &main_placement_) != 0;
    if (main_placement_.showCmd == SW_SHOWMINIMIZED) {
      main_placement_.showCmd = (main_placement_.flags & WPF_RESTORETOMAXIMIZED)
                                    ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
    }
  }
  // Normalize the maximized/minimized state before replacing frame styles.
  // Keep hidden startup windows hidden until the first rendered frame.
  if (IsIconic(window_handle_) || IsZoomed(window_handle_)) {
    ShowWindow(window_handle_, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
  }
  main_mode_ = main_mode;
  const LONG_PTR transient_style = GetWindowLongPtr(window_handle_, GWL_STYLE) &
                                  (WS_VISIBLE | WS_DISABLED);
  SetWindowLongPtr(window_handle_, GWL_STYLE,
                   (main_mode_ ? kMainWindowStyle : kLoginWindowStyle) |
                       transient_style);
  SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  if (main_mode_ && has_main_placement_) {
    WINDOWPLACEMENT placement = main_placement_;
    placement.flags = 0;
    placement.showCmd = visible ? main_placement_.showCmd : SW_HIDE;
    SetWindowPlacement(window_handle_, &placement);
    ConstrainToWorkArea();
  } else {
    CenterClientSize(main_mode_ ? 1280 : 460, main_mode_ ? 800 : 720);
  }
  return true;
}

bool Win32Window::BeginWindowDrag() {
  if (main_mode_ || !IsWindow(window_handle_)) return false;
  // Post the modal Win32 move loop so the MethodChannel reply is not held until
  // the user releases the pointer. The Flutter drag strip owns hit testing.
  return PostMessage(window_handle_, kBeginWindowDrag, 0, 0) != 0;
}

bool Win32Window::MinimizeWindow() {
  return IsWindow(window_handle_) &&
         PostMessage(window_handle_, WM_SYSCOMMAND, SC_MINIMIZE, 0) != 0;
}

bool Win32Window::CloseWindow() {
  // Do not destroy the engine/messenger while its method handler is executing.
  return IsWindow(window_handle_) &&
         PostMessage(window_handle_, WM_CLOSE, 0, 0) != 0;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case kBeginWindowDrag:
      if (!main_mode_ && (GetAsyncKeyState(VK_LBUTTON) & 0x8000)) {
        ReleaseCapture();
        SendMessage(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
      }
      return 0;

    case WM_SYSCOMMAND:
      if (!main_mode_ && ((wparam & 0xfff0) == SC_MAXIMIZE ||
                         (wparam & 0xfff0) == SC_SIZE)) return 0;
      break;

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);
      ConstrainToWorkArea();

      return 0;
    }
    case WM_DISPLAYCHANGE:
      ConstrainToWorkArea();
      return 0;

    case WM_GETMINMAXINFO:
      if (main_mode_) {
        auto limits = reinterpret_cast<MINMAXINFO*>(lparam);
        MONITORINFO monitor_info = {};
        monitor_info.cbSize = sizeof(monitor_info);
        if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                            &monitor_info)) {
          const double scale = GetDpiForWindow(hwnd) / 96.0;
          limits->ptMinTrackSize.x = std::min<LONG>(
              Scale(800, scale), monitor_info.rcWork.right - monitor_info.rcWork.left);
          limits->ptMinTrackSize.y = std::min<LONG>(
              Scale(600, scale), monitor_info.rcWork.bottom - monitor_info.rcWork.top);
        }
        return 0;
      }
      break;
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
