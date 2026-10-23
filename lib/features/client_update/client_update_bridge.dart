import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/constants/app_info.dart';
import 'client_release.dart';

class ClientUpdateBridge {
  static const channel = MethodChannel('com.uten.imp/client_update');

  Future<ClientInstallContext> context() async {
    try {
      final result = await channel.invokeMapMethod<dynamic, dynamic>(
        'getInstallContext',
      );
      if (result != null) return ClientInstallContext.fromJson(result);
    } on MissingPluginException {
      // Older installed clients cannot replace their own runner. The initial
      // installer must include this bridge before in-place updates are offered.
    }
    return ClientInstallContext(
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      architecture: 'universal',
      currentVersion: AppInfo.version,
      currentBuild: const int.fromEnvironment(
        'APP_BUILD_NUMBER',
        defaultValue: 2527,
      ),
    );
  }

  Future<String> install(String path, ClientRelease release) async {
    final result = await channel
        .invokeMapMethod<String, dynamic>('installUpdate', {
          'packagePath': path,
          'sha256': release.sha256,
          'buildNumber': release.buildNumber,
        });
    return result?['status'] as String? ?? 'installerOpened';
  }
}
