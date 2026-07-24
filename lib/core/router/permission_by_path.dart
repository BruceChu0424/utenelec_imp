// 路由 → 所需权限点映射（路由守卫用）。未列出的路径 = 登录即可访问。
// 文档：docs/05-架构/全局机制.md §1.4
import '../../shared/auth/permissions.dart';

/// 返回某路径所需权限点；不需要权限返回 null。
String? requiredPermFor(String location) {
  // 系统管理（超管：员工角色/权限分配）
  if (location == '/admin/permissions' || location.startsWith('/admin/')) {
    return Perm.userManage;
  }
  // 员工档案
  if (location == '/employee' || location.startsWith('/employee/')) {
    if (location == '/employee/onboarding') return Perm.employeeCreate;
    if (location.endsWith('/edit') || location.endsWith('/offboarding')) {
      return Perm.employeeEdit;
    }
    return Perm.employeeView;
  }
  // 部门
  if (location == '/department' || location.startsWith('/department/')) {
    return Perm.departmentView;
  }
  // 财务
  if (location == '/expense/approval' ||
      location.startsWith('/expense/approval/')) {
    return Perm.expenseApprove;
  }
  if (location == '/payroll/review') return Perm.payrollReview;
  if (location == '/payroll/generate') return Perm.payrollGenerate;
  if (location == '/finance/report') return Perm.payrollViewAll;
  // 通知发布
  if (location == '/notice/publish') return 'notice:publish';
  // 实验室
  if (location.startsWith('/lab/')) return 'lab:test:view';
  // 生产 / 库存
  if (location.startsWith('/production/') ||
      location.startsWith('/inventory') ||
      location.startsWith('/hvac')) {
    return 'production:view';
  }
  // 访客审批 / 被访人 / 保安
  if (location == '/visitor-approval' ||
      location.startsWith('/visitor-approval/')) {
    return Perm.visitorApprove;
  }
  if (location == '/my-visitors') return Perm.visitorHostConfirm;
  if (location == '/security/scan' || location.startsWith('/security/')) {
    return Perm.visitorCheckIn;
  }
  // 管理层：决策支持（V25 起独立权限点 analytics:view，默认仅 manager/admin）
  if (location.startsWith('/analytics/')) return Perm.analyticsView;
  // 个人信息自助修改（员工侧）
  if (location == '/profile/edit' || location == '/profile/me/changes') {
    return Perm.profileEditSelf;
  }
  // HR 端：员工修改审批
  if (location == '/hr/profile-changes' ||
      location.startsWith('/hr/profile-changes/')) {
    return Perm.profileReview;
  }
  return null;
}
