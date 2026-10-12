#include "flutter_window.h"

#include <optional>
#include <string>
#include <variant>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() { ResetWindowTitleChannel(); }

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  window_title_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.uten.imp/window_title",
          &flutter::StandardMethodCodec::GetInstance());
  window_title_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setTitle") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = call.arguments();
        const auto* utf8 = arguments == nullptr
                               ? nullptr
                               : std::get_if<std::string>(arguments);
        if (utf8 == nullptr || utf8->empty() || utf8->size() > 320) {
          result->Error("INVALID_TITLE", "Title must be a non-empty string.");
          return;
        }
        const int length = ::MultiByteToWideChar(
            CP_UTF8, MB_ERR_INVALID_CHARS, utf8->data(),
            static_cast<int>(utf8->size()), nullptr, 0);
        if (length <= 0 || length > 80) {
          result->Error("INVALID_TITLE", "Title must be valid bounded UTF-8.");
          return;
        }
        std::wstring title(static_cast<size_t>(length), L'\0');
        if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8->data(),
                                  static_cast<int>(utf8->size()), title.data(),
                                  length) != length) {
          result->Error("INVALID_TITLE", "Title encoding is invalid.");
          return;
        }
        bool has_visible_character = false;
        for (const wchar_t character : title) {
          if (character < 0x20 || (character >= 0x7f && character <= 0x9f)) {
            result->Error("INVALID_TITLE", "Title must be a single line.");
            return;
          }
          has_visible_character = has_visible_character || character != L' ';
        }
        if (!has_visible_character) {
          result->Error("INVALID_TITLE", "Title must not be blank.");
          return;
        }
        HWND window = GetHandle();
        if (window == nullptr || !::IsWindow(window)) {
          result->Error("WINDOW_UNAVAILABLE", "The window is closing.");
          return;
        }
        if (last_window_title_ != title) {
          // Update visible HWND text only. Installer/EXE identity metadata is
          // deliberately untouched so upgrades retain the existing prefs path.
          if (!::SetWindowTextW(window, title.c_str())) {
            result->Error("WINDOW_UNAVAILABLE", "Could not update the caption.");
            return;
          }
          last_window_title_ = std::move(title);
        }
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  ResetWindowTitleChannel();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ResetWindowTitleChannel() {
  if (window_title_channel_) {
    // MethodChannel destruction alone does not unregister its messenger handler.
    // Unregister while the engine still exists, then release the channel first.
    window_title_channel_->SetMethodCallHandler(nullptr);
    window_title_channel_.reset();
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
