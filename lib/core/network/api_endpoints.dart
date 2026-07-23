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
  static String userResetPassword(String id) => '/admin/users/$id/reset-password';
  static const adminRoles = '/admin/roles';

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
  static String visitorApprovalById(String id) => '/visitor-approval/$id';
  static String visitorApprovalAction(String id) => '/visitor-approval/$id/action';
  static String visitorHostConfirm(String id) => '/visitor-approval/$id/host-confirm';
  static const securityVerify = '/security/verify';
  static String securityCheckIn(String id) => '/security/check-in/$id';
}
