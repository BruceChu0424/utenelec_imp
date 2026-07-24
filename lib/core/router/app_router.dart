// 路由配置
// 文档：docs/05-架构/路由设计.md · 全局机制权限见 docs/05-架构/全局机制.md
// 使用 go_router，扁平路由（静态段声明在 :id 之前避免冲突）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/analytics/pages/alerts_page.dart';
import '../../features/analytics/pages/analytics_explore_page.dart';
import '../../features/analytics/pages/business_dashboard_page.dart';
import '../../features/admin/pages/admin_permissions_page.dart';
import '../../features/auth/pages/login_page.dart';
import '../../features/dashboard/pages/dashboard_page.dart';
import '../../features/department/pages/department_page.dart';
import '../../features/employee/pages/employee_detail_page.dart';
import '../../features/employee/pages/employee_edit_page.dart';
import '../../features/employee/pages/employee_list_page.dart';
import '../../features/employee/pages/employee_offboarding_page.dart';
import '../../features/employee/pages/employee_onboarding_page.dart';
import '../../features/expense/pages/expense_approval_detail_page.dart';
import '../../features/expense/pages/expense_approval_list_page.dart';
import '../../features/expense/pages/expense_detail_page.dart';
import '../../features/expense/pages/expense_list_page.dart';
import '../../features/expense/pages/expense_new_page.dart';
import '../../features/finance/pages/finance_report_page.dart';
import '../../features/hr_profile/pages/hr_profile_change_detail_page.dart';
import '../../features/hr_profile/pages/hr_profile_changes_list_page.dart';
import '../../features/hvac/pages/hvac_control_page.dart';
import '../../features/hvac/pages/hvac_overview_page.dart';
import '../../features/inventory/pages/inventory_list_page.dart';
import '../../features/inventory/pages/inventory_movement_page.dart';
import '../../features/lab/pages/lab_test_list_page.dart';
import '../../features/lab/pages/lab_test_report_page.dart';
import '../../features/lab/pages/lab_test_upload_page.dart';
import '../../features/notice/pages/notice_detail_page.dart';
import '../../features/notice/pages/notice_list_page.dart';
import '../../features/notice/pages/notice_publish_page.dart';
import '../../features/payroll/pages/payroll_generate_page.dart';
import '../../features/payroll/pages/payroll_review_page.dart';
import '../../features/payroll/pages/payroll_slip_detail_page.dart';
import '../../features/payroll/pages/payroll_slip_list_page.dart';
import '../../features/placeholder/pages/feature_placeholder_page.dart';
import '../../features/production/pages/production_line_board_page.dart';
import '../../features/production/pages/production_output_entry_page.dart';
import '../../features/production/pages/production_output_stats_page.dart';
import '../../features/profile/pages/my_profile_changes_page.dart';
import '../../features/profile/pages/profile_edit_page.dart';
import '../../features/profile/pages/profile_page.dart';
import '../../features/settings/pages/settings_page.dart';
import '../../features/shell/pages/main_shell_page.dart';
import '../../features/suggestion/pages/suggestion_detail_page.dart';
import '../../features/suggestion/pages/suggestion_list_page.dart';
import '../../features/suggestion/pages/suggestion_new_page.dart';
import '../../features/security/pages/security_scan_page.dart';
import '../../features/visitor_approval/pages/my_visitors_page.dart';
import '../../features/visitor_approval/pages/visitor_approval_detail_page.dart';
import '../../features/visitor_approval/pages/visitor_approval_list_page.dart';
import '../../features/entry/pages/entry_selection_page.dart';
import '../../features/visitor/pages/visitor_apply_page.dart';
import '../../features/visitor/pages/visitor_application_detail_page.dart';
import '../../features/visitor/pages/visitor_home_page.dart';
import '../../features/visitor/pages/visitor_settings_page.dart';
import '../../features/visitor/pages/visitor_login_page.dart';
import '../../features/visitor/providers/visitor_session_provider.dart';
import '../../shared/providers/session_provider.dart';
import '../../features/auth/pages/change_password_page.dart';
import 'permission_by_path.dart';
import 'route_names.dart';

/// App 路由 Provider
final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: RouteName.entry,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final vSession = ref.read(visitorSessionProvider);
      final loc = state.matchedLocation;
      final isEntry = loc == RouteName.entry;
      final isLogin = loc == RouteName.login;
      final isChangePw = loc == RouteName.changePassword;
      final isVisitorPath = loc.startsWith('/visitor');

      // 1) 员工首登强制改密（最高优先）
      if (session.status == AuthStatus.mustChangePassword) {
        return isChangePw ? null : '${RouteName.changePassword}?forced=true';
      }

      // 2) 访客自助流程（/visitor/*）：员工不进，由访客 session 守卫
      if (isVisitorPath) {
        if (session.status == AuthStatus.authenticated)
          return RouteName.dashboard;
        if (vSession.isLoggedIn) return null;
        return loc == RouteName.visitorLogin ? null : RouteName.visitorLogin;
      }

      // 3) 入口选择页：两端都未登录才显示
      if (isEntry) {
        if (session.status == AuthStatus.authenticated)
          return RouteName.dashboard;
        if (vSession.isLoggedIn) return RouteName.visitorHome;
        return null;
      }

      // 4) 员工区（login + ShellRoute 业务页）
      switch (session.status) {
        case AuthStatus.unauthenticated:
          if (vSession.isLoggedIn) return RouteName.visitorHome;
          return isLogin ? null : RouteName.entry;
        case AuthStatus.mustChangePassword:
          return isChangePw ? null : '${RouteName.changePassword}?forced=true';
        case AuthStatus.authenticated:
          // 注意：isChangePw 不在此重定向——"我的→修改密码"是已登录用户的合法入口。
          // 强制改密（mustChangePassword）由前两个分支独立处理。
          if (isLogin) return RouteName.dashboard;
          // "多级权限任一满足即可"的路径（如客户资料）返回列表，任一命中即放行
          final requiredAny = requiredAnyPermFor(loc);
          if (requiredAny != null &&
              !(session.user?.canAny(requiredAny) ?? false)) {
            return RouteName.dashboard;
          }
          return null;
      }
    },
    routes: [
      GoRoute(
        path: RouteName.login,
        name: 'login',
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: RouteName.changePassword,
        name: 'change-password',
        builder: (context, state) => ChangePasswordPage(
          forced: state.uri.queryParameters['forced'] == 'true',
        ),
      ),

      // —— 入口选择（登录前）——
      GoRoute(
        path: RouteName.entry,
        name: 'entry',
        builder: (_, _) => const EntrySelectionPage(),
      ),

      // —— 访客自助流程（不进 ShellRoute）——
      GoRoute(
        path: RouteName.visitorLogin,
        name: 'visitor-login',
        builder: (_, _) => const VisitorLoginPage(),
      ),
      GoRoute(
        path: RouteName.visitorHome,
        name: 'visitor-home',
        builder: (_, _) => const VisitorHomePage(),
      ),
      GoRoute(
        path: RouteName.visitorSettings,
        name: 'visitor-settings',
        builder: (_, _) => const VisitorSettingsPage(),
      ),
      GoRoute(
        path: RouteName.visitorApply,
        name: 'visitor-apply',
        builder: (_, _) => const VisitorApplyPage(),
      ),
      GoRoute(
        path: RouteName.visitorApplyDetail,
        name: 'visitor-apply-detail',
        builder: (_, s) => VisitorApplicationDetailPage(
          applicationId: s.pathParameters['id']!,
        ),
      ),
      ShellRoute(
        builder: (context, state, child) => MainShellPage(child: child),
        routes: [
          GoRoute(
            path: RouteName.home,
            redirect: (_, _) => RouteName.dashboard,
          ),

          // —— 地基 ——
          GoRoute(
            path: RouteName.dashboard,
            name: 'dashboard',
            builder: (_, _) => const DashboardPage(),
          ),
          GoRoute(
            path: RouteName.profile,
            name: 'profile',
            builder: (_, _) => const ProfilePage(),
          ),
          GoRoute(
            path: RouteName.settings,
            name: 'settings',
            builder: (_, _) => const SettingsPage(),
          ),

          // —— 工资 ——
          GoRoute(
            path: '/payroll/slip',
            name: 'payroll-slip-list',
            builder: (_, _) => const PayrollSlipListPage(),
          ),
          GoRoute(
            path: '/payroll/slip/:id',
            name: 'payroll-slip-detail',
            builder: (_, s) =>
                PayrollSlipDetailPage(slipId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/payroll/generate',
            name: 'payroll-generate',
            builder: (_, _) => const PayrollGeneratePage(),
          ),
          GoRoute(
            path: '/payroll/review',
            name: 'payroll-review',
            builder: (_, _) => const PayrollReviewPage(),
          ),
          GoRoute(
            path: '/finance/report',
            name: 'finance-report',
            builder: (_, _) => const FinanceReportPage(),
          ),

          // —— 财税部新模块（占位页：权限已可配置，功能规划接入中）——
          GoRoute(
            path: RouteName.financePurchase,
            name: 'finance-purchase',
            builder: (_, _) => const FeaturePlaceholderPage(
              title: '采购管理',
              icon: Icons.shopping_cart_outlined,
            ),
          ),
          GoRoute(
            path: RouteName.financeCustomers,
            name: 'finance-customers',
            builder: (_, _) => const FeaturePlaceholderPage(
              title: '客户资料',
              icon: Icons.people_alt_outlined,
            ),
          ),
          GoRoute(
            path: RouteName.financeSuppliers,
            name: 'finance-suppliers',
            builder: (_, _) => const FeaturePlaceholderPage(
              title: '供应商资料',
              icon: Icons.local_shipping_outlined,
            ),
          ),
          GoRoute(
            path: RouteName.financeAccounts,
            name: 'finance-accounts',
            builder: (_, _) => const FeaturePlaceholderPage(
              title: '账户资料',
              icon: Icons.account_balance_outlined,
            ),
          ),

          // —— 报销（approval 静态段在 :id 前）——
          GoRoute(
            path: '/expense',
            name: 'expense-list',
            builder: (_, _) => const ExpenseListPage(),
          ),
          GoRoute(
            path: '/expense/new',
            name: 'expense-new',
            builder: (_, _) => const ExpenseNewPage(),
          ),
          GoRoute(
            path: '/expense/approval',
            name: 'expense-approval-list',
            builder: (_, _) => const ExpenseApprovalListPage(),
          ),
          GoRoute(
            path: '/expense/approval/:id',
            name: 'expense-approval-detail',
            builder: (_, s) =>
                ExpenseApprovalDetailPage(claimId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/expense/:id',
            name: 'expense-detail',
            builder: (_, s) =>
                ExpenseDetailPage(claimId: s.pathParameters['id']!),
          ),

          // —— 通知 ——
          GoRoute(
            path: '/notice',
            name: 'notice-list',
            builder: (_, _) => const NoticeListPage(),
          ),
          GoRoute(
            path: '/notice/publish',
            name: 'notice-publish',
            builder: (_, _) => const NoticePublishPage(),
          ),
          GoRoute(
            path: '/notice/:id',
            name: 'notice-detail',
            builder: (_, s) =>
                NoticeDetailPage(noticeId: s.pathParameters['id']!),
          ),

          // —— 建议箱 ——
          GoRoute(
            path: '/suggestion',
            name: 'suggestion-list',
            builder: (_, _) => const SuggestionListPage(),
          ),
          GoRoute(
            path: '/suggestion/new',
            name: 'suggestion-new',
            builder: (_, _) => const SuggestionNewPage(),
          ),
          GoRoute(
            path: '/suggestion/:id',
            name: 'suggestion-detail',
            builder: (_, s) =>
                SuggestionDetailPage(suggestionId: s.pathParameters['id']!),
          ),

          // —— 员工档案（onboarding/edit/offboarding 静态段在 :id 前）——
          GoRoute(
            path: '/employee',
            name: 'employee-list',
            builder: (_, _) => const EmployeeListPage(),
          ),
          GoRoute(
            path: '/employee/onboarding',
            name: 'employee-onboarding',
            builder: (_, _) => const EmployeeOnboardingPage(),
          ),
          GoRoute(
            path: '/employee/:id/edit',
            name: 'employee-edit',
            builder: (_, s) =>
                EmployeeEditPage(employeeId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/employee/:id/offboarding',
            name: 'employee-offboarding',
            builder: (_, s) =>
                EmployeeOffboardingPage(employeeId: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/employee/:id',
            name: 'employee-detail',
            builder: (_, s) =>
                EmployeeDetailPage(employeeId: s.pathParameters['id']!),
          ),

          // —— 部门 ——
          GoRoute(
            path: '/department',
            name: 'department',
            builder: (_, _) => const DepartmentPage(),
          ),

          // —— 实验室（upload 在 :id 前）——
          GoRoute(
            path: '/lab/test',
            name: 'lab-list',
            builder: (_, _) => const LabTestListPage(),
          ),
          GoRoute(
            path: '/lab/test/upload',
            name: 'lab-upload',
            builder: (_, _) => const LabTestUploadPage(),
          ),
          GoRoute(
            path: '/lab/test/:id',
            name: 'lab-report',
            builder: (_, s) =>
                LabTestReportPage(testId: s.pathParameters['id']!),
          ),

          // —— 空调 ——
          GoRoute(
            path: '/hvac',
            name: 'hvac-overview',
            builder: (_, _) => const HvacOverviewPage(),
          ),
          GoRoute(
            path: '/hvac/:id',
            name: 'hvac-control',
            builder: (_, s) =>
                HvacControlPage(deviceId: s.pathParameters['id']!),
          ),

          // —— 生产 ——
          GoRoute(
            path: '/production/line',
            name: 'production-board',
            builder: (_, _) => const ProductionLineBoardPage(),
          ),
          GoRoute(
            path: '/production/output/entry',
            name: 'production-output-entry',
            builder: (_, _) => const ProductionOutputEntryPage(),
          ),
          GoRoute(
            path: '/production/output',
            name: 'production-output-stats',
            builder: (_, _) => const ProductionOutputStatsPage(),
          ),

          // —— 库存 ——
          GoRoute(
            path: '/inventory',
            name: 'inventory-list',
            builder: (_, _) => const InventoryListPage(),
          ),
          GoRoute(
            path: '/inventory/movement',
            name: 'inventory-movement',
            builder: (_, _) => const InventoryMovementPage(),
          ),

          // —— 管理层分析 ——
          GoRoute(
            path: '/analytics/dashboard',
            name: 'analytics-dashboard',
            builder: (_, _) => const BusinessDashboardPage(),
          ),
          GoRoute(
            path: '/analytics/explore',
            name: 'analytics-explore',
            builder: (_, _) => const AnalyticsExplorePage(),
          ),
          GoRoute(
            path: '/analytics/alerts',
            name: 'analytics-alerts',
            builder: (_, _) => const AlertsPage(),
          ),

          // —— 访客审批 / 被访人 / 保安扫码 ——
          GoRoute(
            path: RouteName.visitorApproval,
            name: 'visitor-approval-list',
            builder: (_, _) => const VisitorApprovalListPage(),
          ),
          GoRoute(
            path: RouteName.visitorApprovalDetail,
            name: 'visitor-approval-detail',
            builder: (_, s) => VisitorApprovalDetailPage(
              applicationId: s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: RouteName.myVisitors,
            name: 'my-visitors',
            builder: (_, _) => const MyVisitorsPage(),
          ),
          GoRoute(
            path: RouteName.securityScan,
            name: 'security-scan',
            builder: (_, _) => const SecurityScanPage(),
          ),

          // —— 个人信息自助修改（员工侧）——
          GoRoute(
            path: RouteName.profileEdit,
            name: 'profile-edit',
            builder: (_, _) => const ProfileEditPage(),
          ),
          GoRoute(
            path: RouteName.profileMyChanges,
            name: 'profile-my-changes',
            builder: (_, _) => const MyProfileChangesPage(),
          ),

          // —— HR 端：员工个人信息修改审批 ——
          GoRoute(
            path: RouteName.hrProfileChanges,
            name: 'hr-profile-changes',
            builder: (_, _) => const HrProfileChangesListPage(),
          ),
          GoRoute(
            path: RouteName.hrProfileChangeDetail,
            name: 'hr-profile-change-detail',
            builder: (_, s) =>
                HrProfileChangeDetailPage(batchId: s.pathParameters['id']!),
          ),

          // —— 系统管理（超管）——
          GoRoute(
            path: RouteName.adminPermissions,
            name: 'admin-permissions',
            builder: (_, _) => const AdminPermissionsPage(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => _ErrorPage(error: state.error),
  );

  ref.listen(sessionProvider, (_, _) {
    router.refresh();
  });
  ref.listen(visitorSessionProvider, (_, _) {
    router.refresh();
  });

  ref.onDispose(router.dispose);

  return router;
});

class _ErrorPage extends StatelessWidget {
  const _ErrorPage({required this.error});
  final Exception? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('页面不存在')),
      body: Center(child: Text(error.toString())),
    );
  }
}
