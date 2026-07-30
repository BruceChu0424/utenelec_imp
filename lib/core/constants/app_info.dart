abstract final class AppInfo {
  static const displayName = '优腾综合管理平台';
  static const version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '0.1.0',
  );
  static const copyright = '© 2026 Uten';
}
