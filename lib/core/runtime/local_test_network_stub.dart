import 'client_runtime_profile.dart';

void installLocalTestNetworkBoundary({
  required String localApi,
  ClientRuntimeProfile profile = ClientRuntimeProfile.current,
}) {
  if (profile.localTest) {
    throw StateError('LocalTest runtime is supported only by native clients.');
  }
}
