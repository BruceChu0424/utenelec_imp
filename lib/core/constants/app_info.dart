import '../runtime/client_runtime_profile.dart';

abstract final class AppInfo {
  static const displayName = ClientRuntimeProfile.isLocalTest
      ? ClientRuntimeProfile.localDisplayName
      : ClientRuntimeProfile.formalProductName;
  static const externalName = ClientRuntimeProfile.isLocalTest
      ? ClientRuntimeProfile.localDisplayName
      : ClientRuntimeProfile.formalDisplayName;
  static const version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '2.5.52',
  );
  static const buildId = String.fromEnvironment(
    'APP_BUILD_ID',
    defaultValue: 'dev',
  );
  static const copyright = '© 2026 Uten';
}
