import '../../shared/models/user.dart';
import 'permission_by_path.dart';
import 'route_names.dart';

/// Returns whether [location] belongs to the external visitor portal.
///
/// Match a complete path segment instead of a raw `/visitor` prefix so
/// employee routes such as `/visitor-approval` stay in the employee area.
bool isVisitorPortalLocation(String location) =>
    location == '/visitor' || location.startsWith('/visitor/');

/// Returns the permission redirect for an authenticated employee route.
///
/// The router uses this as its single permission gate so a hidden navigation
/// entry cannot be bypassed by typing or opening a deep link directly.
String? employeePermissionRedirect(AppUser? user, String location) {
  if (user == null) return RouteName.dashboard;

  final requiredAny = requiredAnyPermFor(location);
  if (requiredAny != null && !user.canAny(requiredAny)) {
    return RouteName.dashboard;
  }

  final requiredAll = requiredAllPermsFor(location);
  if (requiredAll.isNotEmpty && !requiredAll.every(user.can)) {
    return RouteName.dashboard;
  }
  return null;
}
