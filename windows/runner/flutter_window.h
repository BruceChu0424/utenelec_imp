#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "win32_window.h"
#include "client_update_channel.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Presentation only: never changes CompanyName/ProductName storage identity.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_title_channel_;
  std::wstring last_window_title_;
  std::unique_ptr<ClientUpdateChannel> client_update_channel_;
  void ResetWindowTitleChannel();
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      desktop_window_channel_;
  void ResetDesktopWindowChannel();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
