#include "update_helper_process.h"
#include "native_diagnostics.h"

#include <vector>

std::shared_ptr<UpdateHelperProcess> UpdateHelperProcess::Start(
    const std::wstring& application, std::wstring command,
    const std::wstring& directory) {
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (!job) { LogNativeWin32Failure("update.job_failed", GetLastError()); return nullptr; }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
          &limits, sizeof(limits))) {
    LogNativeWin32Failure("update.job_limits_failed", GetLastError());
    CloseHandle(job);
    return nullptr;
  }
  SIZE_T attribute_bytes = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
  if (attribute_bytes == 0) {
    CloseHandle(job);
    return nullptr;
  }
  std::vector<BYTE> storage(attribute_bytes);
  auto attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  if (!InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes)) {
    LogNativeWin32Failure("update.attributes_failed", GetLastError());
    CloseHandle(job);
    return nullptr;
  }
  const BOOL configured = UpdateProcThreadAttribute(attributes, 0,
      PROC_THREAD_ATTRIBUTE_JOB_LIST, &job, sizeof(job), nullptr, nullptr);
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.lpAttributeList = attributes;
  PROCESS_INFORMATION process{};
  // Job membership is atomic with process creation, including parent death
  // during CreateProcess itself. No runnable or suspended orphan can escape.
  const BOOL started = configured && CreateProcessW(application.c_str(),
      command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, nullptr,
      directory.empty() ? nullptr : directory.c_str(),
      &startup.StartupInfo, &process);
  const DWORD start_error = started ? ERROR_SUCCESS : GetLastError();
  DeleteProcThreadAttributeList(attributes);
  if (!started) {
    LogNativeWin32Failure("update.process_failed", start_error);
    CloseHandle(job);
    return nullptr;
  }
  CloseHandle(process.hThread);
  return std::shared_ptr<UpdateHelperProcess>(
      new UpdateHelperProcess(process.hProcess, job));
}

UpdateHelperProcess::~UpdateHelperProcess() {
  CloseHandle(job_);  // Kills an unaccepted helper and any of its child processes.
  CloseHandle(process_);
}

bool UpdateHelperProcess::Accept() {
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  return SetInformationJobObject(job_, JobObjectExtendedLimitInformation,
      &limits, sizeof(limits)) != FALSE;
}
