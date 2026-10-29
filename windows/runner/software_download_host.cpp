#include "software_download_host.h"

#include <windows.h>

namespace {
std::string SystemArchitecture() {
  using QueryMachines = BOOL(WINAPI*)(HANDLE, USHORT*, USHORT*);
  const auto kernel = GetModuleHandleW(L"kernel32.dll");
  const auto query = kernel == nullptr ? nullptr : reinterpret_cast<QueryMachines>(
      GetProcAddress(kernel, "IsWow64Process2"));
  USHORT process = 0, native = 0;
  if (query != nullptr && query(GetCurrentProcess(), &process, &native)) {
    if (native == IMAGE_FILE_MACHINE_ARM64) return "arm64";
    if (native == IMAGE_FILE_MACHINE_AMD64) return "x64";
    if (native == IMAGE_FILE_MACHINE_I386) return "x86";
    return "unknown";
  }
  SYSTEM_INFO system = {};
  GetNativeSystemInfo(&system);
  switch (system.wProcessorArchitecture) {
    case PROCESSOR_ARCHITECTURE_AMD64: return "x64";
    case PROCESSOR_ARCHITECTURE_INTEL: return "x86";
    case PROCESSOR_ARCHITECTURE_ARM64: return "arm64";
    default: return "unknown";
  }
}
}  // namespace

SoftwareDownloadHost ReadSoftwareDownloadHost() {
  SoftwareDownloadHost host;
  host.architecture = SystemArchitecture();
  using QueryVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
  const auto native = GetModuleHandleW(L"ntdll.dll");
  const auto query = native == nullptr ? nullptr : reinterpret_cast<QueryVersion>(
      GetProcAddress(native, "RtlGetVersion"));
  OSVERSIONINFOEXW version = {};
  version.dwOSVersionInfoSize = sizeof(version);
  if (query == nullptr || query(reinterpret_cast<OSVERSIONINFOW*>(&version)) != 0) return host;
  host.major = version.dwMajorVersion;
  host.minor = version.dwMinorVersion;
  host.build = version.dwBuildNumber;
  host.service_pack_major = version.wServicePackMajor;
  host.is_server = version.wProductType != VER_NT_WORKSTATION;
  if (host.is_server) host.os_label = "Windows Server";
  else if (host.major == 6 && host.minor == 1)
    host.os_label = host.service_pack_major >= 1 ? "Windows 7 SP1" : "Windows 7";
  else if (host.major == 6 && host.minor == 2) host.os_label = "Windows 8";
  else if (host.major == 6 && host.minor == 3) host.os_label = "Windows 8.1";
  else if (host.major == 10 && host.build >= 22000) host.os_label = "Windows 11";
  else if (host.major == 10) host.os_label = "Windows 10";
  return host;
}
