// 路由 → 所需权限点映射（路由守卫用）。未列出的路径 = 登录即可访问。
// 文档：docs/05-架构/全局机制.md §1.4
//
// 单一权限点的路径直接用 requiredPermFor()；
// "多级权限任一满足即可"的路径（如客户资料 self/department/all）
// 用 requiredAnyPermFor() 返回列表，任一命中即放行。
import '../../shared/auth/permissions.dart';

/// 返回某路径所需的权限点列表（任一满足即可）；不需要权限返回 null。
///
/// 这是路由守卫与工作台显隐共用的唯一数据源。
List<String>? requiredAnyPermFor(String location) {
  // 系统管理（超管：员工角色/权限分配）
  if (location == '/admin/permissions' || location.startsWith('/admin/')) {
    return const [Perm.userManage];
  }
  // 员工档案
  if (location == '/employee' || location.startsWith('/employee/')) {
    if (location == '/employee/onboarding') return const [Perm.employeeCreate];
    if (location.endsWith('/edit') || location.endsWith('/offboarding')) {
      return const [Perm.employeeEdit];
    }
    return const [Perm.employeeView];
  }
  // 部门
  if (location == '/department' || location.startsWith('/department/')) {
    return const [Perm.departmentView];
  }
  // 财务
  if (location == '/expense/approval' ||
      location.startsWith('/expense/approval/')) {
    return const [Perm.expenseApprove];
  }
  if (location == '/payroll/review') return const [Perm.payrollReview];
  if (location == '/payroll/generate') return const [Perm.payrollGenerate];
  if (location == '/finance/report') return const [Perm.payrollViewAll];
  // 财税部新模块（占位页阶段；权限点已种子化）
  if (location.startsWith('/finance/purchase')) {
    return const [Perm.purchaseView];
  }
  // 客户资料：self/department/all 三级数据范围，任一即达最低门槛
  if (location.startsWith('/finance/customers')) {
    return const [
      Perm.customerViewSelf,
      Perm.customerViewDepartment,
      Perm.customerViewAll,
    ];
  }
  if (location.startsWith('/finance/suppliers')) {
    return const [Perm.supplierView];
  }
  if (location.startsWith('/finance/accounts')) {
    return const [Perm.accountView];
  }
  // 通知发布
  if (location == '/notice/publish') return const ['notice:publish'];
  // 实验室
  if (location.startsWith('/lab/')) return const ['lab:test:view'];
  // 生产 / 库存
  if (location.startsWith('/production/') ||
      location.startsWith('/inventory') ||
      location.startsWith('/hvac')) {
    return const ['production:view'];
  }
  // 访客审批 / 被访人 / 保安
  if (location == '/visitor-approval' ||
      location.startsWith('/visitor-approval/')) {
    return const [Perm.visitorApprove];
  }
  if (location == '/my-visitors') return const [Perm.visitorHostConfirm];
  if (location == '/security/scan' || location.startsWith('/security/')) {
    return const [Perm.visitorCheckIn];
  }
  // 管理层：决策支持（V25 起独立权限点 analytics:view，默认仅 manager/admin）
  if (location.startsWith('/analytics/')) return const [Perm.analyticsView];
  // 个人信息自助修改（员工侧）：全员入口——任何登录员工都能查看/修改自己的信息。
  // 能改什么由编辑页 + 后端 ProfileFieldPolicy 的字段策略（直改即时生效 / 需审核走 HR /
  // HR 专属只读）控制，不在这里挂权限点守卫。后端用当前用户 employeeId 落库，无越权风险。
  // HR 端：员工修改审批
  if (location == '/hr/profile-changes' ||
      location.startsWith('/hr/profile-changes/')) {
    return const [Perm.profileReview];
  }
  // 基础资料（/profile）不在此映射 = 登录即可访问
  return null;
}

/// 返回某路径所需权限点；不需要权限返回 null。
///
/// 兼容旧签名：对"任一满足"的多权限路径只返回第一个（最低门槛）。
/// 新代码请直接用 [requiredAnyPermFor]。
String? requiredPermFor(String location) =>
    requiredAnyPermFor(location)?.first;
