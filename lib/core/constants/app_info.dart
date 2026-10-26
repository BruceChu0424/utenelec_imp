abstract final class AppInfo {
  static const displayName = 'UTEN';
  static const version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '2.5.32',
  );
  static const buildId = String.fromEnvironment(
    'APP_BUILD_ID',
    defaultValue: 'dev',
  );
  static const copyright = '© 2026 Uten';
}
