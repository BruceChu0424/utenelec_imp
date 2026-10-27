abstract final class AppInfo {
  static const displayName = '优腾综合管理平台';
  static const externalName = 'UTEN';
  static const version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '2.5.33',
  );
  static const buildId = String.fromEnvironment(
    'APP_BUILD_ID',
    defaultValue: 'dev',
  );
  static const copyright = '© 2026 Uten';
}
