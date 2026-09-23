import '../../shared/models/user.dart';
import 'hub_catalog.dart';
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

  // hub：任一子卡能进就能进(hub 守卫 = 子卡守卫并集，ADR-109)。
  if (isHubLocation(location)) {
    final children = hubCardLocations[hubCardPath(location)]!;
    return children.any(
          (child) => employeePermissionRedirect(user, child) == null,
        )
        ? null
        : RouteName.accessDenied;
  }

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
  if (isHubLocation(location)) {
    return hubCardLocations[hubCardPath(location)]!.any(
      (child) => locationAllowedFor(permissions, superAdmin, child),
    );
  }
  final requiredAny = requiredAnyPermFor(location);
  if (requiredAny != null) {
    if (requiredAny.isEmpty) return false;
    if (!requiredAny.any(permissions.contains)) return false;
  }
  final requiredAll = requiredAllPermsFor(location);
  return requiredAll.every(permissions.contains);
}

/// hub 页 / 工作台用：该卡片是否可见(与路由守卫同一份 any/all 契约)。
///
/// [hub] 非空时调试态断言卡片落点已登记在 hub_catalog——页面多出一张目录外的卡，
/// hub 守卫的并集就会漏掉它的权限，持码人又会点不进。
bool hubCardAllowed(
  String hub,
  String location,
  Set<String> permissions,
  bool superAdmin,
) {
  assert(
    hubCardLocations[hub]?.contains(hubCardPath(location)) ?? false,
    'hub 卡片落点 $location 未登记在 hub_catalog[$hub]',
  );
  return locationAllowedFor(permissions, superAdmin, location);
}
