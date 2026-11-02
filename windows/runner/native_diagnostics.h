#ifndef RUNNER_NATIVE_DIAGNOSTICS_H_
#define RUNNER_NATIVE_DIAGNOSTICS_H_
#include <windows.h>
#include <string>

constexpr UINT kDiagnosticHeartbeat = WM_APP + 0x35b;
// Normal events are queued; fatal exception records use an already-open handle.
// One bounded log session per process, including all build configurations.
void StartNativeDiagnostics(HWND window, const std::wstring& test_directory = L"",
                            DWORD warning_ms = 5000, DWORD poll_ms = 1000);
void StopNativeDiagnostics();
void AcknowledgeDiagnosticHeartbeat();
void LogNativeDiagnostic(const char* event, const char* code = "");
void LogNativeWin32Failure(const char* event, DWORD error);
std::wstring NativeDiagnosticDirectory();
void RecordNativeException(EXCEPTION_POINTERS* pointers);
#endif
