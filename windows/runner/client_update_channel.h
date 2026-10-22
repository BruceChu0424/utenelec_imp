#ifndef RUNNER_CLIENT_UPDATE_CHANNEL_H_
#define RUNNER_CLIENT_UPDATE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Only installs validated release files; never accepts a command from Dart/server.
class ClientUpdateChannel {
 public:
  ClientUpdateChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~ClientUpdateChannel();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_CLIENT_UPDATE_CHANNEL_H_
