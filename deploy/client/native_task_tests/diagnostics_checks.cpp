#include "native_diagnostics.h"
#include "update_helper_process.h"
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace {
LRESULT CALLBACK DiagnosticWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kDiagnosticHeartbeat) { AcknowledgeDiagnosticHeartbeat(); return 0; }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
void Pump(DWORD duration) {
  const auto end = GetTickCount64() + duration;
  while (GetTickCount64() < end) {
    MSG message;
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message); DispatchMessageW(&message);
    }
    Sleep(2);
  }
}
std::string ReadLogs(const std::filesystem::path& root) {
  std::string content;
  for (const auto& entry : std::filesystem::directory_iterator(root)) {
    if (entry.path().extension() != L".log") continue;
    std::ifstream file(entry.path(), std::ios::binary);
    std::ostringstream bytes; bytes << file.rdbuf(); content += bytes.str();
  }
  return content;
}
}  // namespace

int RunNativeDiagnosticChild(int argc, wchar_t** argv) {
  if (argc != 3 || (std::wstring(argv[1]) != L"--diag-hang" && std::wstring(argv[1]) != L"--diag-crash")) return -1;
  SetErrorMode(SEM_NOGPFAULTERRORBOX | SEM_FAILCRITICALERRORS);
  SetStdHandle(STD_ERROR_HANDLE, nullptr);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  WNDCLASSW wc{}; wc.lpfnWndProc = DiagnosticWindowProc;
  wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"UtenDiagnosticFixture";
  RegisterClassW(&wc);
  HWND window = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
  StartNativeDiagnostics(window, argv[2], 80, 10);
  if (std::wstring(argv[1]) == L"--diag-crash") {
    RaiseException(EXCEPTION_ACCESS_VIOLATION, EXCEPTION_NONCONTINUABLE, 0, nullptr);
    return 99;
  }
  std::fprintf(stderr, "[ERROR:flutter/shell/platform/common/accessibility_bridge.cc(1)] private_user_text\n");
  std::fflush(stderr);
  // A deliberately blocked message thread must produce a durable hang record.
  Sleep(250);
  Pump(200);
  for (int i = 0; i < 5000; ++i) LogNativeDiagnostic("diagnostic.surge", "fixed_metadata");
  Pump(150);
  StopNativeDiagnostics(); Sleep(100);
  DestroyWindow(window); CoUninitialize();
  return 0;
}

int RunNativeDiagnosticChecks() {
  int failures = 0;
  const auto check = [&](bool ok, const char* description) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", description);
    if (!ok) ++failures;
  };
  wchar_t temporary[32768]{}, executable[32768]{};
  GetTempPathW(32768, temporary); GetModuleFileNameW(nullptr, executable, 32768);
  const auto root = std::filesystem::path(temporary) / (L"uten-native-logs-" + std::to_wstring(GetCurrentProcessId()));
  std::filesystem::create_directories(root);
  for (const auto& mode : {std::wstring(L"--diag-hang"), std::wstring(L"--diag-crash")}) {
    const auto folder = root / (mode == L"--diag-hang" ? L"hang" : L"crash");
    std::filesystem::create_directory(folder);
    auto child = UpdateHelperProcess::Start(executable, L"\"" + std::wstring(executable) + L"\" " + mode + L" \"" + folder.wstring() + L"\"", L"");
    check(child != nullptr, "diagnostic fixture process starts");
    if (!child) continue;
    const bool ended = WaitForSingleObject(child->process(), 10000) == WAIT_OBJECT_0;
    check(ended, "logging never traps shutdown or a fatal process");
    if (!ended) { child.reset(); continue; }
    const auto logs = ReadLogs(folder);
    check(!logs.empty(), "automatic .log exists without a collection tool");
    check(logs.find("schemaVersion") != std::string::npos && logs.find("version") != std::string::npos,
        "persistent logs identify their contract and installed version");
    if (mode == L"--diag-hang") {
      check(logs.find("window.unresponsive") != std::string::npos, "blocked UI is logged by a background watchdog");
      check(logs.find("window.recovered") != std::string::npos, "recovered UI is recorded without termination");
      check(logs.find("engine.accessibility_error") != std::string::npos && logs.find("private_user_text") == std::string::npos,
          "GUI engine errors are categorized without copying raw output");
      check(logs.size() < 3 * 1024 * 1024, "event surge remains bounded on disk");
    } else {
      check(logs.find("native.unhandled_exception") != std::string::npos && logs.find("0xc0000005") != std::string::npos,
          "native access violation survives in .log after process exit");
    }
  }
  return failures;
}
