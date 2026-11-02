#include "window_background_task.h"

#include <mutex>
#include <utility>

namespace {
constexpr wchar_t kClassName[] = L"UtenBackgroundTaskCompletion";
constexpr UINT kCompleted = WM_APP + 0x359;
}  // namespace

struct WindowBackgroundTask::State {
  State() : cancelled(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
  ~State() { if (cancelled) CloseHandle(cancelled); }
  std::mutex mutex;
  HANDLE cancelled;
  HWND window = nullptr;
  bool busy = false;
  Completion completion;
};

struct WindowBackgroundTask::Pending {
  std::shared_ptr<State> state;
  Work work;
};

WindowBackgroundTask::WindowBackgroundTask() : state_(std::make_shared<State>()) {
  static std::once_flag registered;
  std::call_once(registered, [] {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = kClassName;
    RegisterClassW(&window_class);
  });
  if (state_->cancelled) {
    state_->window = CreateWindowExW(0, kClassName, L"", 0, 0, 0, 0, 0,
        HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), state_.get());
  }
}

WindowBackgroundTask::~WindowBackgroundTask() {
  HWND window;
  Completion abandoned;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->cancelled) SetEvent(state_->cancelled);
    window = state_->window;
    state_->window = nullptr;
    abandoned = std::move(state_->completion);
  }
  // Destroy callbacks/owned resources outside the lock, on the platform thread.
  abandoned = nullptr;
  if (window) DestroyWindow(window);
}

bool WindowBackgroundTask::Start(Work work) {
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (!state_->window || state_->busy) return false;
  state_->busy = true;
  auto pending = std::make_unique<Pending>(Pending{state_, std::move(work)});
  if (!QueueUserWorkItem(Run, pending.get(), WT_EXECUTELONGFUNCTION)) {
    state_->busy = false;
    return false;
  }
  pending.release();
  return true;
}

DWORD WINAPI WindowBackgroundTask::Run(void* argument) {
  std::unique_ptr<Pending> pending(static_cast<Pending*>(argument));
  const auto state = pending->state;
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (WaitForSingleObject(state->cancelled, 0) != WAIT_OBJECT_0) {
    auto completion = pending->work(state->cancelled);
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (state->window &&
          WaitForSingleObject(state->cancelled, 0) != WAIT_OBJECT_0) {
        state->completion = std::move(completion);
        if (!PostMessageW(state->window, kCompleted, 0, 0)) {
          completion = std::move(state->completion);
          state->busy = false;
        }
      }
    }
    // A discarded completion can own a helper process; release it outside locks.
  }
  if (SUCCEEDED(com)) CoUninitialize();
  return 0;
}

LRESULT CALLBACK WindowBackgroundTask::WindowProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto state = reinterpret_cast<State*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == kCompleted && state) {
    Completion completion;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      completion = std::move(state->completion);
      state->busy = false;
    }
    // No state/owner access after this: completion may destroy its own owner.
    if (completion) completion();
    return 0;
  }
  if (message == WM_NCDESTROY) SetWindowLongPtrW(window, GWLP_USERDATA, 0);
  return DefWindowProcW(window, message, wparam, lparam);
}
