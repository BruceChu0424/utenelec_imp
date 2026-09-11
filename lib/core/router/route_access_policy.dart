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
  if (requiredAny != null) {
    if (requiredAny.isEmpty) return RouteName.notFound;
    if (!user.canAny(requiredAny)) return RouteName.accessDenied;
  }

  final requiredAll = requiredAllPermsFor(location);
  if (requiredAll.isNotEmpty && !requiredAll.every(user.can)) {
    return RouteName.accessDenied;
  }
  return null;
}

/// 页内入口显隐（详情页「返回列表」等）：给定权限快照能否进入 [location]。
///
/// 与 [employeePermissionRedirect] 同源：any/all 双契约都要满足；无守卫映射的
/// 路由（登录即可）放行；已知前缀但无授权码的单据段（`const []`）fail-closed。
/// 详情页可由任务中心/财务审批/车间任务等无列表权限的入口 push 进来，
/// 「返回列表」若不按此门控会把用户带到 /access-denied（2026-09-10 审计）。
bool locationAllowedFor(
  Set<String> permissions,
  bool superAdmin,
  String location,
) {
  if (superAdmin) return true;
  final requiredAny = requiredAnyPermFor(location);
  if (requiredAny != null) {
    if (requiredAny.isEmpty) return false;
    if (!requiredAny.any(permissions.contains)) return false;
  }
  final requiredAll = requiredAllPermsFor(location);
  return requiredAll.every(permissions.contains);
}
