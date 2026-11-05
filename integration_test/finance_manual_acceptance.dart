// Task-only manual entry. Production startup and ordinary UI login are unchanged.
import 'package:flutter/foundation.dart';
import 'package:uten_imp/core/network/api_base_url.dart';
import 'package:uten_imp/core/runtime/client_runtime_profile.dart';
import 'package:uten_imp/main.dart' as application;
import '../tool/finance_acceptance_platform.dart';

Future<void> main() async {
  if (kIsWeb ||
      !ClientRuntimeProfile.isLocalTest ||
      !const {
        'http://127.0.0.1:18090/api',
        'http://127.0.0.1:18092/api',
      }.contains(apiBaseUrl)) {
    throw StateError(
      'Manual finance acceptance requires this task loopback LocalTest profile.',
    );
  }
  await prepareAcceptanceRuntime();
  await application.bootstrapUtenApp();
}
