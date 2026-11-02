#include "native_diagnostics.h"
#include <shlobj.h>
#include <shellapi.h>
#include <atomic>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <mutex>
#include <vector>
#include <io.h>
#include <fcntl.h>

#ifndef FLUTTER_VERSION
#define FLUTTER_VERSION "test"
#endif
#ifndef UTEN_BUILD_KIND
#define UTEN_BUILD_KIND "unknown"
#endif

namespace {
namespace fs = std::filesystem;
#if defined(_M_ARM64)
constexpr char kArchitecture[] = "arm64";
#elif defined(_M_IX86)
constexpr char kArchitecture[] = "x86";
#else
constexpr char kArchitecture[] = "x64";
#endif
struct State {
  std::mutex mutex;
  std::deque<std::string> queue;
  HANDLE file = INVALID_HANDLE_VALUE;
  HANDLE fatal_file = INVALID_HANDLE_VALUE;
  HANDLE wake = nullptr;
  HWND window = nullptr;
  std::atomic<bool> active{false};
  std::atomic<ULONGLONG> acknowledged{0};
  std::atomic<bool> outstanding{false};
  std::atomic<LONG> fatal{0};
  uintptr_t engine = 0;
  DWORD engine_size = 0;
  char engine_pdb[96]{};
  std::wstring directory;
  size_t bytes = 0;
  unsigned dropped = 0;
  DWORD warning_ms = 5000, poll_ms = 1000;
  LPTOP_LEVEL_EXCEPTION_FILTER previous = nullptr;
};
// Process-lifetime state/handle intentionally survives engine/window teardown.
// Windows closes the handle even if an unhandled exception aborts the process.
State* g = nullptr;

void Timestamp(char* out, size_t length) {
  SYSTEMTIME time{};
  GetSystemTime(&time);
  sprintf_s(out, length, "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
      time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
      time.wSecond, time.wMilliseconds);
}

void Append(const char* data, DWORD length, bool flush = false) {
  if (!g || g->file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  const HANDLE file = flush && g->fatal_file != INVALID_HANDLE_VALUE ? g->fatal_file : g->file;
  WriteFile(file, data, length, &written, nullptr);
  if (flush) FlushFileBuffers(file);
}

DWORD WINAPI EngineErrors(void* handle) {
  const HANDLE pipe = static_cast<HANDLE>(handle);
  char buffer[512]{};
  DWORD read = 0;
  std::string line;
  ULONGLONG last = 0;
  while (g && g->active && ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr) && read) {
    for (DWORD i = 0; i < read; ++i) {
      if (buffer[i] == '\n') {
        if (line.find("[ERROR:flutter/") != std::string::npos && GetTickCount64() - last >= 1000) {
          const bool accessibility = line.find("accessibility_bridge") != std::string::npos || line.find("AXTree") != std::string::npos;
          // Only a fixed category is persisted. Engine output can otherwise
          // contain framework widget text or plugin-supplied sensitive values.
          LogNativeDiagnostic(accessibility ? "engine.accessibility_error" : "engine.error", "engine_reported_error");
          last = GetTickCount64();
        }
        line.clear();
      } else if (line.size() < 512) line.push_back(buffer[i]);
    }
  }
  CloseHandle(pipe);
  return 0;
}

void CaptureEngineErrorsWithoutConsole() {
  const HANDLE previous = GetStdHandle(STD_ERROR_HANDLE);
  if (previous && previous != INVALID_HANDLE_VALUE && GetFileType(previous) != FILE_TYPE_UNKNOWN) return;
  HANDLE reader = nullptr, writer = nullptr;
  if (!CreatePipe(&reader, &writer, nullptr, 4096)) return;
  if (!QueueUserWorkItem(EngineErrors, reader, WT_EXECUTELONGFUNCTION)) { CloseHandle(reader); CloseHandle(writer); return; }
  if (_fileno(stderr) < 0) {
    FILE* initialized = nullptr;
    _wfreopen_s(&initialized, L"NUL", L"w", stderr);
  }
  const int fd = _open_osfhandle(reinterpret_cast<intptr_t>(writer), _O_WRONLY | _O_BINARY | _O_NOINHERIT);
  if (fd < 0) { CloseHandle(writer); return; }
  if (_dup2(fd, _fileno(stderr)) == 0) {
    const HANDLE redirected = reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(stderr)));
    SetHandleInformation(redirected, HANDLE_FLAG_INHERIT, 0);
    SetStdHandle(STD_ERROR_HANDLE, redirected);
  }
  _close(fd);
}

LONG WINAPI Fatal(EXCEPTION_POINTERS* pointers) {
  RecordNativeException(pointers);
  return g && g->previous ? g->previous(pointers) : EXCEPTION_CONTINUE_SEARCH;
}

DWORD WINAPI Writer(void*) {
  // Only owned, closed log leaves in this namespace may expire. No recursive
  // deletion and no traversal through directory links.
  std::vector<fs::directory_entry> old;
  std::error_code error;
  for (const auto& entry : fs::directory_iterator(g->directory, error)) {
    const auto name = entry.path().filename().wstring();
    if (!entry.is_symlink(error) && entry.is_regular_file(error) &&
        (name.rfind(L"native-", 0) == 0 || name.rfind(L"fatal-native-", 0) == 0) && entry.path().extension() == L".log") old.push_back(entry);
  }
  std::sort(old.begin(), old.end(), [](const auto& a, const auto& b) {
    std::error_code ignored;
    return a.last_write_time(ignored) > b.last_write_time(ignored);
  });
  for (size_t i = 16; i < old.size(); ++i) fs::remove(old[i].path(), error);
  bool reported = false;
  ULONGLONG stalled_at = 0;
  while (g && g->active) {
    WaitForSingleObject(g->wake, g->poll_ms);
    std::deque<std::string> batch;
    unsigned dropped = 0;
    {
      std::lock_guard<std::mutex> lock(g->mutex);
      batch.swap(g->queue);
      dropped = g->dropped;
      g->dropped = 0;
    }
    if (dropped) LogNativeDiagnostic("diagnostic.dropped", "queue_limit");
    for (const auto& line : batch) {
      if (g->bytes + line.size() > 2 * 1024 * 1024) {
        LARGE_INTEGER start{};
        SetFilePointerEx(g->file, start, nullptr, FILE_BEGIN);
        SetEndOfFile(g->file);
        g->bytes = 0;
        LogNativeDiagnostic("native.engine_pdb", g->engine_pdb);
      }
      Append(line.data(), static_cast<DWORD>(line.size()));
      g->bytes += line.size();
    }
    const auto now = GetTickCount64();
    if (g->outstanding.load() && now - g->acknowledged.load() > g->warning_ms && !reported) {
      reported = true;
      stalled_at = g->acknowledged.load();
      LogNativeDiagnostic("window.unresponsive", "heartbeat_timeout");
    } else if (reported && !g->outstanding.load()) {
      reported = false;
      char duration[64]{};
      sprintf_s(duration, "recovered_after_%llums", now - stalled_at);
      LogNativeDiagnostic("window.recovered", duration);
    }
    std::lock_guard<std::mutex> lock(g->mutex);
    if (g->active && g->window && !g->outstanding.exchange(true)) {
      if (!PostMessageW(g->window, kDiagnosticHeartbeat, 0, 0)) {
        g->outstanding = false;
      }
    }
  }
  // Drain the final bounded queue without making the window thread join I/O.
  std::deque<std::string> final;
  { std::lock_guard<std::mutex> lock(g->mutex); final.swap(g->queue); }
  for (const auto& line : final) {
    if (g->bytes + line.size() > 2 * 1024 * 1024) {
      LARGE_INTEGER start{}; SetFilePointerEx(g->file, start, nullptr, FILE_BEGIN);
      SetEndOfFile(g->file); g->bytes = 0;
    }
    Append(line.data(), static_cast<DWORD>(line.size())); g->bytes += line.size();
  }
  return 0;
}
}  // namespace

std::wstring NativeDiagnosticDirectory() {
  if (g) return g->directory;
  return L"";
}

void StartNativeDiagnostics(HWND window, const std::wstring& test_directory,
                            DWORD warning_ms, DWORD poll_ms) {
  if (g) return;
  g = new State();
  PWSTR raw = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &raw))) return;
#if defined(_M_ARM64)
  constexpr wchar_t architecture[] = L"arm64";
#elif defined(_M_IX86)
  constexpr wchar_t architecture[] = L"x86";
#else
  constexpr wchar_t architecture[] = L"x64";
#endif
  const auto root = test_directory.empty()
      ? fs::path(raw) / L"com.uten.uten_imp" / L"client-logs" / L"flutter" /
            architecture / UTEN_BUILD_KIND
      : fs::path(test_directory);
  CoTaskMemFree(raw);
  std::error_code error;
  fs::create_directories(root, error);
  if (error) return;
  g->directory = root.wstring();
  const auto leaf = std::string("native-") + FLUTTER_VERSION + "-" +
      std::to_string(GetTickCount64()) + "-" + std::to_string(GetCurrentProcessId()) + ".log";
  g->file = CreateFileW((root / leaf).c_str(), GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  if (g->file == INVALID_HANDLE_VALUE) return;
  const auto fatal_leaf = "fatal-" + leaf;
  g->fatal_file = CreateFileW((root / fatal_leaf).c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  g->wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!g->wake) return;
  g->window = window;
  ULONG reserved_stack = 64 * 1024;
  SetThreadStackGuarantee(&reserved_stack);
  g->warning_ms = warning_ms;
  g->poll_ms = poll_ms;
  g->acknowledged = GetTickCount64();
  g->active = true;
  g->engine = reinterpret_cast<uintptr_t>(GetModuleHandleW(L"flutter_windows.dll"));
  if (g->engine) {
    const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(g->engine);
    const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(g->engine + dos->e_lfanew);
    g->engine_size = nt->OptionalHeader.SizeOfImage;
    const auto debug = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DEBUG];
    if (debug.VirtualAddress && debug.VirtualAddress + debug.Size < g->engine_size) {
      const auto entries = reinterpret_cast<const IMAGE_DEBUG_DIRECTORY*>(g->engine + debug.VirtualAddress);
      for (size_t i = 0; i < debug.Size / sizeof(IMAGE_DEBUG_DIRECTORY) && i < 16; ++i) {
        const auto& entry = entries[i];
        if (entry.Type != IMAGE_DEBUG_TYPE_CODEVIEW || entry.SizeOfData < 24 || entry.AddressOfRawData + entry.SizeOfData >= g->engine_size) continue;
        const auto data = reinterpret_cast<const BYTE*>(g->engine + entry.AddressOfRawData);
        if (memcmp(data, "RSDS", 4) != 0) continue;
        GUID id{}; DWORD age = 0;
        memcpy(&id, data + 4, sizeof(id)); memcpy(&age, data + 20, sizeof(age));
        sprintf_s(g->engine_pdb, "%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x-age%lu", id.Data1,
          static_cast<unsigned>(id.Data2), static_cast<unsigned>(id.Data3), id.Data4[0], id.Data4[1], id.Data4[2],
          id.Data4[3], id.Data4[4], id.Data4[5], id.Data4[6], id.Data4[7], age);
      }
    }
  }
  g->previous = SetUnhandledExceptionFilter(Fatal);
  if (!QueueUserWorkItem(Writer, nullptr, WT_EXECUTELONGFUNCTION)) g->active = false;
  CaptureEngineErrorsWithoutConsole();
  LogNativeDiagnostic("native.start", "UTEN_LOG_V1");
  if (g->engine) {
    const auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(g->engine);
    const auto nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(g->engine + dos->e_lfanew);
    char identity[96]{};
    sprintf_s(identity, "timestamp_%08lx_image_%08lx", nt->FileHeader.TimeDateStamp, g->engine_size);
    LogNativeDiagnostic("native.engine", identity);
    LogNativeDiagnostic("native.engine_pdb", g->engine_pdb);
  }
}

void LogNativeDiagnostic(const char* event, const char* code) {
  if (!g || !g->active) return;
  const DWORD previous_error = GetLastError();
  // Callers supply fixed identifiers or numbers, never exception messages,
  // input, request bodies, credentials, URLs or downloaded filenames.
  char timestamp[40]{};
  Timestamp(timestamp, sizeof(timestamp));
  char line[1024]{};
  const int length = sprintf_s(line,
      "{\"schemaVersion\":1,\"atUtc\":\"%s\",\"event\":\"%s\","
      "\"version\":\"%s\",\"runtime\":\"flutter\",\"architecture\":\"%s\",\"configuration\":\"%s\",\"processId\":%lu,\"level\":\"%s\",\"code\":\"%s\"}\n",
      timestamp, event, FLUTTER_VERSION, kArchitecture, UTEN_BUILD_KIND, GetCurrentProcessId(),
      (strstr(event, "failed") || strstr(event, "unresponsive") || strstr(event, "_error")) ? "warning" : "info", code);
  if (length <= 0) { SetLastError(previous_error); return; }
  {
    std::lock_guard<std::mutex> lock(g->mutex);
    if (g->queue.size() == 256) { g->queue.pop_front(); ++g->dropped; }
    g->queue.emplace_back(line, length);
  }
  SetEvent(g->wake);
  SetLastError(previous_error);
}

void AcknowledgeDiagnosticHeartbeat() {
  if (g) { g->acknowledged = GetTickCount64(); g->outstanding = false; }
}

void LogNativeWin32Failure(const char* event, DWORD error) {
  char code[40]{}; sprintf_s(code, "win32_%lu", error);
  LogNativeDiagnostic(event, code);
}

void StopNativeDiagnostics() {
  if (!g || !g->active) return;
  LogNativeDiagnostic("native.stop");
  { std::lock_guard<std::mutex> lock(g->mutex); g->active = false; g->window = nullptr; }
  SetEvent(g->wake);
}

void RecordNativeException(EXCEPTION_POINTERS* pointers) {
  if (!g || !pointers || g->fatal.exchange(1)) return;
  const auto& exception = *pointers->ExceptionRecord;
  const auto address = reinterpret_cast<uintptr_t>(exception.ExceptionAddress);
  const bool in_engine = g->engine && address >= g->engine && address - g->engine < g->engine_size;
  char timestamp[40]{};
  Timestamp(timestamp, sizeof(timestamp));
  char line[2048]{};
  const int length = sprintf_s(line,
      "{\"schemaVersion\":1,\"atUtc\":\"%s\",\"event\":\"native.unhandled_exception\","
      "\"level\":\"error\",\"version\":\"%s\",\"runtime\":\"flutter\",\"architecture\":\"%s\",\"configuration\":\"%s\",\"processId\":%lu,\"code\":\"0x%08lx\",\"module\":\"%s\","
      "\"rva\":\"0x%llx\",\"accessAddress\":\"0x%llx\",\"enginePdb\":\"%s\",\"threadId\":%lu,\"frames\":[",
      timestamp, FLUTTER_VERSION, kArchitecture, UTEN_BUILD_KIND, GetCurrentProcessId(), exception.ExceptionCode,
      in_engine ? "flutter_windows.dll" : "other",
      static_cast<unsigned long long>(in_engine ? address - g->engine : address),
      static_cast<unsigned long long>(exception.NumberParameters > 1 ? exception.ExceptionInformation[1] : 0), g->engine_pdb, GetCurrentThreadId());
  if (length > 0) {
    void* frames[16]{};
    const USHORT count = CaptureStackBackTrace(0, 16, frames, nullptr);
    size_t used = static_cast<size_t>(length);
    for (USHORT i = 0; i < count && used < sizeof(line) - 80; ++i) {
      const auto pc = reinterpret_cast<uintptr_t>(frames[i]);
      const bool engine = g->engine && pc >= g->engine && pc - g->engine < g->engine_size;
      const int wrote = sprintf_s(line + used, sizeof(line) - used, "%s\"%s0x%llx\"", i ? "," : "",
          engine ? "engine+" : "address+", static_cast<unsigned long long>(engine ? pc - g->engine : pc));
      if (wrote > 0) used += static_cast<size_t>(wrote);
    }
    const int tail = sprintf_s(line + used, sizeof(line) - used, "]}\n");
    if (tail > 0) Append(line, static_cast<DWORD>(used + static_cast<size_t>(tail)), true);
  }
}
