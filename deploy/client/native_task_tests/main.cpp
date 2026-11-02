#include "window_background_task.h"
#include "update_helper_process.h"

#include <atomic>
#include <cstdio>
#include <functional>
#include <memory>

namespace {
int failures = 0;
void Check(bool value, const char* name) {
  std::printf("%s %s\n", value ? "PASS" : "FAIL", name);
  if (!value) ++failures;
}

bool PumpUntil(const std::function<bool()>& condition, DWORD timeout = 3000) {
  const auto deadline = GetTickCount64() + timeout;
  while (!condition() && GetTickCount64() < deadline) {
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    MsgWaitForMultipleObjects(0, nullptr, FALSE, 5, QS_ALLINPUT);
  }
  return condition();
}
}  // namespace

int main(int argc, char**) {
  if (argc > 1) { Sleep(30000); return 0; }
  const DWORD platform_thread = GetCurrentThreadId();
  {
    WindowBackgroundTask task;
    HANDLE release = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::atomic<bool> working{false};
    DWORD worker_thread = platform_thread, reply_thread = 0;
    bool replied = false;
    const auto started = GetTickCount64();
    Check(task.Start([&](HANDLE cancelled) {
      worker_thread = GetCurrentThreadId();
      working = true;
      const HANDLE events[] = {cancelled, release};
      WaitForMultipleObjects(2, events, FALSE, 2000);
      return [&] { reply_thread = GetCurrentThreadId(); replied = true; };
    }), "slow native operation starts");
    Check(GetTickCount64() - started < 100, "start returns without waiting for I/O");
    Check(PumpUntil([&] { return working.load(); }), "worker starts while UI pumps messages");
    Check(worker_thread != platform_thread, "blocking work leaves platform thread");
    Check(!task.Start([](HANDLE) { return [] {}; }), "rapid duplicate handoff rejected");
    const auto pumping = GetTickCount64();
    int ticks = 0;
    PumpUntil([&] { ++ticks; return GetTickCount64() - pumping >= 150; });
    Check(ticks > 5 && !replied, "UI remains responsive throughout a blocked handoff");
    SetEvent(release);
    Check(PumpUntil([&] { return replied; }), "ready handoff completes");
    Check(reply_thread == platform_thread, "completion replies on original platform thread");
    replied = false;
    Check(task.Start([&](HANDLE) { return [&] { replied = true; }; }), "completed slot accepts a new task");
    Check(PumpUntil([&] { return replied; }), "second completion delivered once");
    CloseHandle(release);
  }
  {
    auto task = std::make_unique<WindowBackgroundTask>();
    std::atomic<bool> working{false}, cancelled{false}, replied{false};
    HANDLE ended = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    task->Start([&](HANDLE stop) {
      working = true;
      cancelled = WaitForSingleObject(stop, 2000) == WAIT_OBJECT_0;
      SetEvent(ended);
      return [&] { replied = true; };
    });
    Check(PumpUntil([&] { return working.load(); }), "shutdown fixture enters blocked wait");
    const auto started = GetTickCount64();
    task.reset();
    Check(GetTickCount64() - started < 100, "owner destruction never joins a slow worker");
    Check(WaitForSingleObject(ended, 2000) == WAIT_OBJECT_0 && cancelled,
        "closing owner cancels its pending handoff");
    PumpUntil([&] { return replied.load(); }, 50);
    Check(!replied, "destroyed engine receives no late completion");
    CloseHandle(ended);
  }
  {
    auto task = std::make_unique<WindowBackgroundTask>();
    bool destroyed = false;
    task->Start([&](HANDLE) { return [&] { task.reset(); destroyed = true; }; });
    Check(PumpUntil([&] { return destroyed; }), "completion can close its own channel safely");
  }
  {
    wchar_t executable[32768]{};
    GetModuleFileNameW(nullptr, executable, 32768);
    const auto command = L"\"" + std::wstring(executable) + L"\" --child";
    auto child = UpdateHelperProcess::Start(executable, command, L"");
    Check(child != nullptr, "private helper starts under a kill-on-close job");
    if (child) {
      HANDLE observed = nullptr;
      DuplicateHandle(GetCurrentProcess(), child->process(), GetCurrentProcess(),
          &observed, SYNCHRONIZE, FALSE, 0);
      child.reset();
      Check(WaitForSingleObject(observed, 2000) == WAIT_OBJECT_0,
          "abandoned ready helper cannot apply an update after parent exit");
      CloseHandle(observed);
    }
    child = UpdateHelperProcess::Start(executable, command, L"");
    Check(child && child->Accept(), "UI acceptance releases only the approved helper");
    if (child) {
      HANDLE observed = nullptr;
      DuplicateHandle(GetCurrentProcess(), child->process(), GetCurrentProcess(),
          &observed, SYNCHRONIZE | PROCESS_TERMINATE, FALSE, 0);
      child.reset();
      Check(WaitForSingleObject(observed, 50) == WAIT_TIMEOUT,
          "accepted helper survives parent handoff handle disposal");
      TerminateProcess(observed, 0);
      WaitForSingleObject(observed, 2000);
      CloseHandle(observed);
    }
  }
  std::printf("failures=%d\n", failures);
  return failures ? 1 : 0;
}
