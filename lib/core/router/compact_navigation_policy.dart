import 'route_names.dart';

/// Compact navigation belongs to the workbench/main tabs and first-level
/// management entries. Lists, details and editors below an entry use the full
/// screen. The shell supplies the actual top route, including imperative pushes.
abstract final class UtenCompactNavigationPolicy {
  static const _firstLevelEntries = {
    RouteName.payrollSlipList,
    RouteName.hrTaskCenter,
    RouteName.adminPermissions,
    RouteName.adminAuditLogs,
    RouteName.adminSystemSettings,
    RouteName.adminServerStatus,
  };

  static bool showsNavigation(String location) {
    final uri = Uri.tryParse(location);
    if (uri == null) return false;
    return uri.pathSegments.where((segment) => segment.isNotEmpty).length <=
            1 ||
        _firstLevelEntries.contains(uri.path);
  }
}
