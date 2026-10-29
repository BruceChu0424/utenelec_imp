#ifndef RUNNER_SOFTWARE_DOWNLOAD_HOST_H_
#define RUNNER_SOFTWARE_DOWNLOAD_HOST_H_

#include <cstdint>
#include <string>

struct SoftwareDownloadHost {
  std::string architecture = "unknown";
  std::string os_label = "Windows";
  uint32_t major = 0;
  uint32_t minor = 0;
  uint32_t build = 0;
  uint32_t service_pack_major = 0;
  bool is_server = false;
};

// OS identity only. Does not inspect/create a client profile or update staging.
SoftwareDownloadHost ReadSoftwareDownloadHost();

#endif  // RUNNER_SOFTWARE_DOWNLOAD_HOST_H_
