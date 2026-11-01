import 'network_policy.dart';

/// Explicit file APIs have one finite browser transfer budget. Fetch cannot
/// distinguish connection, wire upload and waiting for the first response.
/// Ordinary requests retain their independently configured shortest deadline.
const fileUploadOverallTimeoutKey = 'uten.fileUploadOverallTimeout';

Duration fileUploadOverallTimeout({
  Duration? sendTimeout,
  Duration? receiveTimeout,
}) {
  Duration finite(Duration? value, Duration fallback) =>
      value != null && value > Duration.zero ? value : fallback;
  return finite(sendTimeout, apiSendTimeout) +
      finite(receiveTimeout, apiReceiveTimeout);
}
