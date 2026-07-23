// 路由名称常量
// 文档：docs/05-架构/路由设计.md

/// 路由路径常量
abstract final class RouteName {
  static const String login = '/login';
  static const String home = '/';
  static const String dashboard = '/dashboard';
  static const String profile = '/profile';
  static const String settings = '/settings';
  static const String changePassword = '/change-password';
  static const String department = '/department';

  // 工资条
  static const String payrollSlipList = '/payroll/slip';
  static const String payrollSlipDetail = '/payroll/slip/:id';

  // 报销
  static const String expense = '/expense';
  static const String expenseNew = '/expense/new';
  static const String expenseDetail = '/expense/:id';

  // 通知
  static const String notice = '/notice';
  static const String noticeDetail = '/notice/:id';

  // 建议
  static const String suggestion = '/suggestion';
  static const String suggestionNew = '/suggestion/new';
  static const String suggestionDetail = '/suggestion/:id';

  // 员工档案（Phase 2）
  static const String employee = '/employee';
  static const String employeeDetail = '/employee/:id';

  // 入口选择（登录前：内部人员 / 访客）
  static const String entry = '/entry';

  // 访客端（独立流程，不进 ShellRoute）
  static const String visitorLogin = '/visitor/login';
  static const String visitorHome = '/visitor/home';
  static const String visitorSettings = '/visitor/settings';
  static const String visitorApply = '/visitor/apply';
  static const String visitorApplyDetail = '/visitor/apply/:id';

  // 访客审批 / 被访人 / 保安（员工登录后，进 ShellRoute）
  static const String visitorApproval = '/visitor-approval';
  static const String visitorApprovalDetail = '/visitor-approval/:id';
  static const String myVisitors = '/my-visitors';
  static const String securityScan = '/security/scan';
  static const String securityCheck = '/security/check/:id';
}

/// 路径拼接工具（带参数的路由）
abstract final class RoutePath {
  /// 登录页（可带 returnTo）
  static String login({String? returnTo}) {
    if (returnTo == null) return RouteName.login;
    return '${RouteName.login}?returnTo=$returnTo';
  }

  static String payrollSlipDetail(String id) => '/payroll/slip/$id';
  static String expenseDetail(String id) => '/expense/$id';
  static String noticeDetail(String id) => '/notice/$id';
  static String suggestionDetail(String id) => '/suggestion/$id';
  static String employeeDetail(String id) => '/employee/$id';
  static String employeeEdit(String id) => '/employee/$id/edit';
}
