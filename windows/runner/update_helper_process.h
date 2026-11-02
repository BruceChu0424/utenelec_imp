#ifndef RUNNER_UPDATE_HELPER_PROCESS_H_
#define RUNNER_UPDATE_HELPER_PROCESS_H_

#include <windows.h>
#include <memory>
#include <string>

// A helper cannot outlive an abandoned handoff, even if the parent process
// exits before its background worker observes cancellation.
class UpdateHelperProcess {
 public:
  static std::shared_ptr<UpdateHelperProcess> Start(
      const std::wstring& application, std::wstring command,
      const std::wstring& directory);
  ~UpdateHelperProcess();
  UpdateHelperProcess(const UpdateHelperProcess&) = delete;
  UpdateHelperProcess& operator=(const UpdateHelperProcess&) = delete;
  HANDLE process() const { return process_; }
  bool Accept();

 private:
  UpdateHelperProcess(HANDLE process, HANDLE job) : process_(process), job_(job) {}
  HANDLE process_;
  HANDLE job_;
};

#endif  // RUNNER_UPDATE_HELPER_PROCESS_H_
