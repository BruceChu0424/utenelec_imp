import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'client_runtime_profile.dart';

/// Check before opening preferences or credentials. A mixed native/AOT pair
/// must not silently inherit another installation's storage or network scope.
Future<void> verifyNativeRuntimeIdentity({
  ClientRuntimeProfile profile = ClientRuntimeProfile.current,
  MethodChannel channel = const MethodChannel('com.uten.imp/diagnostics'),
  bool? windows,
}) async {
  if (!(windows ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows))) {
    return;
  }
  Map<Object?, Object?>? native;
  try {
    native = await channel.invokeMapMethod<Object?, Object?>(
      'getRuntimeProfile',
    );
  } on MissingPluginException {
    // Preserve an older formal runner's supported startup path. A LocalTest
    // identity always needs an explicitly matching native runner.
    if (!profile.localTest) return;
  }
  if (native?['schemaVersion'] != 1 ||
      native?['buildProfile'] != profile.buildProfile ||
      native?['applicationId'] != profile.applicationId ||
      native?['nativeProductName'] != profile.nativeProductName) {
    throw StateError('Native and Dart runtime profiles do not match.');
  }
}
