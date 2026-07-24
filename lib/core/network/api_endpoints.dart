// 接口路径常量（基址 /api）。后端见 server .../features/*/Controller。
abstract final class ApiEndpoints {
  // 鉴权
  static const authLogin = '/auth/login';
  static const authRefresh = '/auth/refresh';
  static const authLogout = '/auth/logout';
  static const authChangePassword = '/auth/change-password';
  static const authMe = '/auth/me';

  // 部门
  static const departmentsTree = '/org/departments/tree';
  static String departmentSubtree(String id) => '/org/departments/$id/subtree';
  static String department(String id) => '/org/departments/$id';
  static const departments = '/org/departments';

  // 岗位（部门下）
  static String departmentPositions(String deptId) =>
      '/org/departments/$deptId/positions';
  static String position(String id) => '/org/positions/$id';

  // 员工
  static const employees = '/org/employees';
  static String employee(String id) => '/org/employees/$id';
  static String employeeHistory(String id) => '/org/employees/$id/history';
  static String employeeTransfer(String id) => '/org/employees/$id/transfer';
  static String employeeOffboard(String id) => '/org/employees/$id/offboard';
  static String employeeConfirm(String id) => '/org/employees/$id/confirm';

  // 账号管理（HR）
  static const adminUsers = '/admin/users';
  static String userLock(String id) => '/admin/users/$id/lock';
  static String userUnlock(String id) => '/admin/users/$id/unlock';
  static String userDisable(String id) => '/admin/users/$id/disable';
  static String userEnable(String id) => '/admin/users/$id/enable';
  static String userResetPassword(String id) =>
      '/admin/users/$id/reset-password';
  static const adminRoles = '/admin/roles';

  // 权限管理（超级管理员）
  /// 列全部权限点（GET /admin/permissions；与前端路由 /admin/permissions 同名，注意区分）
  static const adminPermissionList = '/admin/permissions';
  static String userRoles(String id) => '/admin/users/$id/roles';
  static String userPermOverrides(String id) =>
      '/admin/users/$id/permission-overrides';
  static const adminDepartmentRoles = '/admin/department-roles';
  static String departmentRoles(String id) => '/admin/departments/$id/roles';

  // 访客（visitor）
  static const visitorSendCode = '/visitor/auth/send-code';
  static const visitorLogin = '/visitor/auth/login';
  static const visitorRefresh = '/visitor/auth/refresh';
  static const visitorLogout = '/visitor/auth/logout';
  static const visitorDirectoryDepartments = '/visitor/directory/departments';
  static const visitorDirectoryEmployees = '/visitor/directory/employees';
  static const visitorApplicationsMine = '/visitor/applications/mine';
  static const visitorApplications = '/visitor/applications';
  static String visitorApplication(String id) => '/visitor/applications/$id';
  static const visitorApproval = '/visitor-approval';
  static const visitorApprovalAsHost = '/visitor-approval/as-host';
  static const visitorApprovalPendingCount =
      '/visitor-approval/pending-count';
  static const visitorApprovalHostPendingCount =
      '/visitor-approval/host-pending-count';
  static String visitorApprovalById(String id) => '/visitor-approval/$id';
  static String visitorApprovalAction(String id) =>
      '/visitor-approval/$id/action';
  static String visitorHostConfirm(String id) =>
      '/visitor-approval/$id/host-confirm';
  static const securityVerify = '/security/verify';
  static String securityCheckIn(String id) => '/security/check-in/$id';

  // 个人信息修改（Phase 6）
  static const authVerifyPassword = '/auth/verify-password';
  static const profileMyChanges = '/profile/me/changes';
  static const hrProfileChanges = '/hr/profile-changes';
  static const hrProfileChangesPendingCount =
      '/hr/profile-changes/pending-count';
  static String hrProfileChangesPendingCountFor(String employeeId) =>
      '/hr/profile-changes/pending-count/$employeeId';
  static String hrProfileChangeDetail(String id) => '/hr/profile-changes/$id';
  static String hrProfileChangeReview(String id) =>
      '/hr/profile-changes/$id/review';
}
