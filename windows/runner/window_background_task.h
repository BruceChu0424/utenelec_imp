#ifndef RUNNER_WINDOW_BACKGROUND_TASK_H_
#define RUNNER_WINDOW_BACKGROUND_TASK_H_

#include <windows.h>

#include <functional>
#include <memory>

// Slow native work runs outside the window/message thread. Completion runs on
// that thread while its owner is alive, so Flutter messenger replies stay safe.
// Destruction cancels without joining a worker or pumping reentrant UI messages.
class WindowBackgroundTask {
 public:
  using Completion = std::function<void()>;
  using Work = std::function<Completion(HANDLE cancelled)>;

  WindowBackgroundTask();
  ~WindowBackgroundTask();
  WindowBackgroundTask(const WindowBackgroundTask&) = delete;
  WindowBackgroundTask& operator=(const WindowBackgroundTask&) = delete;

  // Call only on the constructing thread. A second in-flight task is rejected.
  bool Start(Work work);

 private:
  struct State;
  struct Pending;
  static LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM);
  static DWORD WINAPI Run(void*);
  std::shared_ptr<State> state_;
};

#endif  // RUNNER_WINDOW_BACKGROUND_TASK_H_
