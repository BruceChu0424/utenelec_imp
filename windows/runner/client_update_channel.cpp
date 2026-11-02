#include "client_update_channel.h"
#include "software_download_host.h"
#include "update_helper_process.h"

#include <bcrypt.h>
#include <shlobj.h>
#include <flutter/standard_method_codec.h>

#include <array>
#include <filesystem>
#include <fstream>
#include <string>
#include <variant>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
namespace fs = std::filesystem;

std::string Utf8(const std::wstring& value) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring Wide(const std::string& value) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), size);
  return result;
}

fs::path Executable() {
  std::wstring path(32768, L'\0');
  const DWORD size = GetModuleFileNameW(nullptr, path.data(),
      static_cast<DWORD>(path.size()));
  if (size == 0 || size >= path.size()) return {};
  path.resize(size);
  return fs::path(path);
}

fs::path StagingDirectory() {
  PWSTR raw = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                 nullptr, &raw))) return {};
  const fs::path result = fs::path(raw) / L"com.uten.uten_imp" / L"client-updates";
  CoTaskMemFree(raw);
  std::error_code error;
  fs::create_directories(result, error);
  return error ? fs::path() : result;
}

bool NoReparsePoint(const fs::path& path) {
  for (fs::path current = path; !current.empty();) {
    const DWORD attributes = GetFileAttributesW(current.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) return false;
    const auto parent = current.parent_path();
    if (parent == current) break;
    current = parent;
  }
  return true;
}

bool IsInside(const fs::path& child, const fs::path& parent) {
  auto part = child.begin();
  for (auto expected = parent.begin(); expected != parent.end(); ++expected, ++part) {
    if (part == child.end() || _wcsicmp(part->c_str(), expected->c_str()) != 0) {
      return false;
    }
  }
  return part != child.end();
}

bool ValidHash(const std::string& hash) {
  if (hash.size() != 64) return false;
  for (const char value : hash) {
    if (!((value >= '0' && value <= '9') || (value >= 'a' && value <= 'f'))) {
      return false;
    }
  }
  return true;
}

std::string Sha256(const fs::path& path, HANDLE cancelled) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0;
  DWORD returned_size = 0;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) {
    return {};
  }
  std::string result;
  if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
          reinterpret_cast<PUCHAR>(&object_size), sizeof(object_size),
          &returned_size, 0) >= 0) {
    std::vector<UCHAR> object(object_size);
    if (BCryptCreateHash(algorithm, &hash, object.data(), object_size,
                         nullptr, 0, 0) >= 0) {
      std::ifstream input(path, std::ios::binary);
      std::array<char, 65536> buffer{};
      bool valid = input.good();
      while (valid && input && WaitForSingleObject(cancelled, 0) != WAIT_OBJECT_0) {
        input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
        const auto size = input.gcount();
        if (size > 0 && BCryptHashData(hash,
                reinterpret_cast<PUCHAR>(buffer.data()),
                static_cast<ULONG>(size), 0) < 0) valid = false;
      }
      std::array<UCHAR, 32> digest{};
      if (valid && input.eof() && BCryptFinishHash(hash, digest.data(),
              static_cast<ULONG>(digest.size()), 0) >= 0) {
        constexpr char digits[] = "0123456789abcdef";
        for (const auto byte : digest) {
          result += digits[byte >> 4];
          result += digits[byte & 15];
        }
      }
      BCryptDestroyHash(hash);
    }
  }
  BCryptCloseAlgorithmProvider(algorithm, 0);
  return result;
}

std::wstring Quote(const std::wstring& value) {
  // Win32 command-line escaping, including paths ending in a backslash.
  // CreateProcess receives a fixed application path; no shell is involved.
  std::wstring quoted = L"\"";
  size_t slashes = 0;
  for (const wchar_t character : value) {
    if (character == L'\\') {
      ++slashes;
    } else {
      quoted.append(character == L'"' ? slashes * 2 + 1 : slashes, L'\\');
      quoted += character;
      slashes = 0;
    }
  }
  quoted.append(slashes * 2, L'\\');
  return quoted + L"\"";
}

std::string StringArg(const Map* args, const char* key) {
  if (args == nullptr) return {};
  const auto found = args->find(Value(key));
  if (found == args->end()) return {};
  const auto value = std::get_if<std::string>(&found->second);
  return value == nullptr ? std::string() : *value;
}

int64_t BuildArg(const Map* args) {
  if (args == nullptr) return 0;
  const auto found = args->find(Value("buildNumber"));
  if (found == args->end()) return 0;
  if (const auto value = std::get_if<int64_t>(&found->second)) return *value;
  if (const auto value = std::get_if<int32_t>(&found->second)) return *value;
  return 0;
}

std::string Architecture() {
#if defined(_M_ARM64)
  return "arm64";
#elif defined(_M_X64)
  return "x64";
#else
  return "x86";
#endif
}

std::string LastUpdateResult(const fs::path& staging) {
  const auto path = staging / L"last-update-result.json";
  std::error_code error;
  const auto size = fs::file_size(path, error);
  if (error || size == 0 || size > 16384 || !NoReparsePoint(path)) return {};
  std::ifstream input(path, std::ios::binary);
  std::string json(static_cast<size_t>(size), '\0');
  input.read(json.data(), static_cast<std::streamsize>(size));
  if (!input) return {};
  if (json.compare(0, 3, "\xef\xbb\xbf") == 0) json.erase(0, 3);
  return json;
}
struct UpdatePreparation {
  std::string error;
  std::string message;
  std::shared_ptr<UpdateHelperProcess> helper;
};

UpdatePreparation PrepareUpdate(const std::string& path_arg,
    const std::string& expected_hash, int64_t build, HANDLE cancelled) {
  const auto staging = StagingDirectory();
  const auto executable = Executable();
  const auto script = executable.parent_path() / L"client_updater" / L"client_updater.ps1";
  std::error_code error;
  const fs::path package(Wide(path_arg));
  const auto canonical_package = fs::canonical(package, error);
  if (error || staging.empty() || !IsInside(canonical_package, staging) ||
      !NoReparsePoint(canonical_package) || !NoReparsePoint(script) ||
      !NoReparsePoint(executable.parent_path()) ||
      canonical_package.extension() != L".zip" ||
      !fs::is_regular_file(canonical_package, error) || error) {
    return {"UNSAFE_UPDATE_PATH", "Update must be a ZIP in private staging.", nullptr};
  }
  const auto package_size = fs::file_size(canonical_package, error);
  if (error || package_size == 0 || package_size > 536870912) {
    return {"INVALID_UPDATE_SIZE", "Update ZIP must be between 1 byte and 512 MiB.", nullptr};
  }
  if (Sha256(canonical_package, cancelled) != expected_hash) {
    return {"UPDATE_HASH_MISMATCH", "Update integrity check failed.", nullptr};
  }
  // Do not request elevation or redirect AppData. Portable/per-user installs
  // retain their original path and their existing personal settings.
  const auto probe = executable.parent_path() /
      (L".uten-update-probe-" + std::to_wstring(GetCurrentProcessId()));
  HANDLE probe_file = CreateFileW(probe.c_str(), GENERIC_WRITE, 0, nullptr,
      CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
  if (probe_file == INVALID_HANDLE_VALUE) {
    return {"INSTALL_DIRECTORY_READ_ONLY", "The install directory is not writable.", nullptr};
  }
  CloseHandle(probe_file);
  GUID id{};
  if (FAILED(CoCreateGuid(&id))) {
    return {"UPDATE_START_FAILED", "Could not allocate an update job.", nullptr};
  }
  wchar_t id_text[40]{};
  StringFromGUID2(id, id_text, 40);
  const std::wstring job_id(id_text);
  const auto job = staging / job_id;
  fs::create_directory(job, error);
  if (error) {
    return {"UPDATE_START_FAILED", "Could not create private update workspace.", nullptr};
  }
  const auto helper = job / L"client_updater.ps1";
  fs::copy_file(script, helper, fs::copy_options::none, error);
  if (error) {
    return {"UPDATE_START_FAILED", "Could not prepare the installed updater.", nullptr};
  }
  FILETIME created{}, exited{}, kernel{}, user{};
  if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) {
    return {"UPDATE_START_FAILED", "Could not identify the running process.", nullptr};
  }
  ULARGE_INTEGER start{};
  start.LowPart = created.dwLowDateTime;
  start.HighPart = created.dwHighDateTime;
  const auto event_name = L"Local\\UtenClientUpdate-" + job_id;
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, event_name.c_str());
  wchar_t system_directory[MAX_PATH]{};
  const UINT system_length = GetSystemDirectoryW(system_directory, MAX_PATH);
  if (ready == nullptr || system_length == 0 || system_length >= MAX_PATH) {
    if (ready != nullptr) CloseHandle(ready);
    return {"UPDATE_START_FAILED", "Could not create update handshake.", nullptr};
  }
  const fs::path powershell = fs::path(system_directory) /
      L"WindowsPowerShell" / L"v1.0" / L"powershell.exe";
  std::wstring command = Quote(powershell.wstring()) +
      L" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
      Quote(helper.wstring()) + L" -PackagePath " + Quote(canonical_package.wstring()) +
      L" -ExpectedSha256 " + Wide(expected_hash) + L" -BuildNumber " +
      std::to_wstring(build) + L" -Architecture " + Wide(Architecture()) +
      L" -InstallDirectory " + Quote(executable.parent_path().wstring()) +
      L" -ParentProcessId " + std::to_wstring(GetCurrentProcessId()) +
      L" -ParentStartFileTime " + std::to_wstring(start.QuadPart) +
      L" -ReadyEventName " + Quote(event_name) +
      L" -Workspace " + Quote(job.wstring());
  auto helper_process = UpdateHelperProcess::Start(
      powershell.wstring(), std::move(command), job.wstring());
  if (!helper_process) {
    CloseHandle(ready);
    return {"UPDATE_START_FAILED", "Could not start the installed updater safely.", nullptr};
  }
  const HANDLE waits[] = {cancelled, ready, helper_process->process()};
  const DWORD state = WaitForMultipleObjects(3, waits, FALSE, 15000);
  if (state != WAIT_OBJECT_0 + 1) {
    // A late helper must never apply an update after the user has already
    // received a failed handoff. It cannot have changed install files while
    // this process is alive, so stopping this private helper is safe.
    TerminateProcess(helper_process->process(), 1);
    WaitForSingleObject(helper_process->process(), 5000);
  }
  CloseHandle(ready);
  if (state != WAIT_OBJECT_0 + 1) {
    // The helper never mutates the install until this process exits. A failed
    // handshake therefore leaves the running version intact.
    return {"UPDATE_START_FAILED", "Updater did not become ready. See the update log.", nullptr};
  }
  return {"", "", std::move(helper_process)};
}

}  // namespace

ClientUpdateChannel::ClientUpdateChannel(flutter::BinaryMessenger* messenger,
                                         HWND window) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "com.uten.imp/client_update",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this, window](const flutter::MethodCall<Value>& call,
               std::unique_ptr<flutter::MethodResult<Value>> result) {
    if (call.method_name() == "getSoftwareDownloadHost") {
      const auto host = ReadSoftwareDownloadHost();
      result->Success(Value(Map{
          {Value("platform"), Value("windows")},
          {Value("architecture"), Value(host.architecture)},
          {Value("osLabel"), Value(host.os_label)},
          {Value("osMajor"), Value(static_cast<int64_t>(host.major))},
          {Value("osMinor"), Value(static_cast<int64_t>(host.minor))},
          {Value("osBuild"), Value(static_cast<int64_t>(host.build))},
          {Value("servicePackMajor"), Value(static_cast<int64_t>(host.service_pack_major))},
          {Value("isServer"), Value(host.is_server)},
      }));
      return;
    }
    if (call.method_name() == "getInstallContext") {
      const auto staging = StagingDirectory();
      const auto script = Executable().parent_path() / L"client_updater" / L"client_updater.ps1";
      std::error_code error;
      result->Success(Value(Map{
          {Value("platform"), Value("windows")},
          {Value("architecture"), Value(Architecture())},
          {Value("currentVersion"), Value(FLUTTER_VERSION)},
          {Value("currentBuild"), Value(static_cast<int64_t>(FLUTTER_VERSION_BUILD))},
          {Value("stagingDirectory"), Value(Utf8(staging.wstring()))},
          {Value("supportsInPlaceUpdate"), Value(!staging.empty() && fs::is_regular_file(script, error))},
          {Value("requiresSystemConfirmation"), Value(false)},
          {Value("lastUpdateLog"), Value(Utf8((staging / L"last-update.log").wstring()))},
          {Value("lastUpdateResultJson"), Value(LastUpdateResult(staging))},
      }));
      return;
    }
    if (call.method_name() != "installUpdate") {
      result->NotImplemented();
      return;
    }
    const auto args = call.arguments() == nullptr ? nullptr :
        std::get_if<Map>(call.arguments());
    const auto path_arg = StringArg(args, "packagePath");
    const auto expected_hash = StringArg(args, "sha256");
    const auto build = BuildArg(args);
    if (path_arg.empty() || path_arg.find('\0') != std::string::npos ||
        path_arg.find('"') != std::string::npos || !ValidHash(expected_hash) ||
        build <= static_cast<int64_t>(FLUTTER_VERSION_BUILD) || build > 65535) {
      result->Error("INVALID_UPDATE", "Update path, hash or build is invalid.");
      return;
    }
    auto reply = std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
    const bool started = installation_.Start(
        [window, reply, path_arg, expected_hash, build](HANDLE cancelled) {
      auto prepared = PrepareUpdate(path_arg, expected_hash, build, cancelled);
      return [window, reply, prepared = std::move(prepared)]() {
        if (!prepared.error.empty()) {
          reply->Error(prepared.error, prepared.message);
          return;
        }
        if (!IsWindow(window)) {
          reply->Error("WINDOW_UNAVAILABLE", "The window is closing.");
          return;
        }
        // This closure runs on the platform thread with its channel still alive.
        if (!prepared.helper->Accept()) {
          reply->Error("UPDATE_START_FAILED", "Could not authorize the ready updater.");
          return;
        }
        reply->Success(Value(Map{{Value("status"), Value("restarting")}}));
        PostMessageW(window, WM_CLOSE, 0, 0);
      };
    });
    if (!started) {
      reply->Error("UPDATE_IN_PROGRESS", "An update handoff is already running or unavailable.");
    }
  });
}

ClientUpdateChannel::~ClientUpdateChannel() {
  channel_->SetMethodCallHandler(nullptr);
}
