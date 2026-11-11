import 'dart:io';

import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

/// Retains the real JSON/cache implementations. Their concrete Windows path
/// providers are independent of PathProviderPlatform.instance and need the same
/// explicit routing before the first preference read. Never call getAll here.
void isolateRealWindowsPreferences(Directory root) {
  if (!Platform.isWindows) return;
  final legacy = SharedPreferencesStorePlatform.instance;
  final asynchronous = SharedPreferencesAsyncPlatform.instance;
  if (legacy is! SharedPreferencesWindows ||
      asynchronous is! SharedPreferencesAsyncWindows) {
    throw StateError(
      'Real Windows preferences must be registered before bootstrap',
    );
  }
  final paths = AcceptanceWindowsPreferencePaths(root);
  legacy.pathProvider = paths;
  asynchronous.pathProvider = paths;
}

class AcceptanceWindowsPreferencePaths extends PathProviderWindows {
  AcceptanceWindowsPreferencePaths(this.root);
  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async {
    final support = Directory('${root.path}/UTEN Local Test');
    await support.create(recursive: true);
    return support.absolute.path;
  }
}
