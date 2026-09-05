// 路由配置
// 文档：docs/05-架构/路由设计.md · 全局机制权限见 docs/05-架构/全局机制.md
// 使用 go_router，扁平路由（静态段声明在 :id 之前避免冲突）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/gen/app_localizations.dart';
import '../../features/admin/pages/admin_audit_log_page.dart';
import '../../features/admin/pages/admin_audit_session_detail_page.dart';
import '../../features/admin/models/audit_session.dart';
import '../../features/admin/pages/admin_system_settings_page.dart';
import '../../features/admin/pages/admin_permissions_page.dart';
import '../../features/admin/pages/page_permission_settings_page.dart';
import '../../features/auth/pages/login_page.dart';
import '../../features/basic_data/pages/basic_data_hub_page.dart';
import '../../features/basic_data/pages/client_category_page.dart';
import '../../features/basic_data/pages/color_page.dart';
import '../../features/basic_data/pages/account_page.dart';
import '../../features/basic_data/pages/account_detail_page.dart';
import '../../features/basic_data/pages/currency_page.dart';
import '../../features/basic_data/pages/goods_detail_page.dart';
import '../../features/basic_data/pages/mould_category_page.dart';
import '../../features/basic_data/pages/payment_style_page.dart';
import '../../features/basic_data/pages/settlement_method_page.dart';
import '../../features/basic_data/pages/product_category_page.dart';
import '../../features/basic_data/pages/supplier_category_page.dart';
import '../../features/basic_data/pages/unit_page.dart';
import '../../features/basic_data/pages/warehouse_page.dart';
import '../../features/dashboard/pages/dashboard_page.dart';
import '../../features/department/pages/department_page.dart';
import '../../features/employee/pages/employee_detail_page.dart';
import '../../features/employee/pages/employee_edit_page.dart';
import '../../features/employee/pages/employee_list_page.dart';
import '../../features/employee/pages/employee_offboarding_workflow_page.dart';
import '../../features/employee/pages/employee_onboarding_page.dart';
import '../../features/expense/pages/expense_approval_detail_page.dart';
import '../../features/expense/pages/expense_approval_list_page.dart';
import '../../features/expense/pages/expense_detail_page.dart';
import '../../features/expense/pages/expense_list_page.dart';
import '../../features/expense/pages/expense_new_page.dart';
import '../../features/finance/models/finance_doc.dart';
import '../../features/finance/pages/finance_ar_ap_page.dart';
import '../../features/finance/pages/finance_assets_page.dart';
import '../../features/finance/pages/finance_doc_detail_page.dart';
import '../../features/finance/pages/finance_doc_edit_page.dart';
import '../../features/finance/pages/finance_doc_list_page.dart';
import '../../features/finance/pages/finance_hub_page.dart';
import '../../features/finance/payables/pages/finance_payables_page.dart';
import '../../features/finance/pages/finance_procurement_approval_review_page.dart';
import '../../features/finance/pages/finance_procurement_approval_tasks_page.dart';
import '../../features/finance/pages/finance_sales_order_confirmation_page.dart';
import '../../features/finance/pages/finance_sales_order_review_page.dart';
import '../../features/finance/pages/finance_sales_shipment_audit_page.dart';
import '../../features/finance/pages/finance_reconciliation_page.dart';
import '../../features/finance/pages/finance_report_table_page.dart';
import '../../features/finance/pages/finance_ar_ap_overview_page.dart';
import '../../features/finance/pages/finance_statement_page.dart';
import '../../features/finance/pages/finance_account_flow_page.dart';
import '../../features/hr_profile/pages/hr_profile_change_detail_page.dart';
import '../../features/hr_profile/pages/hr_profile_changes_list_page.dart';
import '../../features/hr_task/pages/hr_task_list_page.dart';
import '../../features/hr_task/pages/hr_workbench_page.dart';
import '../../features/hr_task/widgets/hr_task_widgets.dart';
import '../../features/notice/pages/notice_detail_page.dart';
import '../../features/operations_workbench/models/operations_workbench.dart';
import '../../features/operations_workbench/pages/operations_workbench_page.dart';
import '../../features/rd_task/pages/rd_task_page.dart';
import '../../features/purchase/pages/purchase_doc_detail_page.dart';
import '../../features/purchase/pages/purchase_doc_edit_page.dart';
import '../../features/purchase/pages/purchase_doc_list_page.dart';
import '../../features/purchase/pages/purchase_hub_page.dart';
import '../../features/purchase/pages/purchase_order_edit_page.dart';
import '../../features/purchase/pages/purchase_report_page.dart';
import '../../features/purchase/pages/purchase_report_table_page.dart';
import '../../features/purchase/config/purchase_report_config.dart';
import '../../features/purchase/models/purchase_doc.dart';
import '../../features/stock/pages/instant_inventory_page.dart';
import '../../features/stock/pages/stock_item_detail_page.dart';
import '../../features/warehouse/models/stock_doc.dart';
import '../../features/warehouse/config/warehouse_document_history_config.dart';
import '../../features/warehouse/pages/finance_arrival_exception_pages.dart';
import '../../features/warehouse/pages/procurement_return_task_pages.dart';
import '../../features/warehouse/pages/warehouse_arrival_exceptions_page.dart';
import '../../features/warehouse/pages/warehouse_arrival_expectation_detail_page.dart';
import '../../features/warehouse/pages/warehouse_arrival_receipt_page.dart';
import '../../features/warehouse/pages/warehouse_inbound_expectations_page.dart';
import '../../features/warehouse/pages/warehouse_quality_results_page.dart';
import '../../features/warehouse/pages/warehouse_quality_result_detail_page.dart';
import '../../features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import '../../features/warehouse/pages/warehouse_document_history_detail_page.dart';
import '../../features/warehouse/pages/warehouse_document_history_list_page.dart';
import '../../features/warehouse/pages/production_finished_arrival_batch_registration_page.dart';
import '../../features/warehouse/pages/production_finished_arrival_registration_page.dart';
import '../../features/warehouse/pages/production_finished_inbound_tasks_page.dart';
import '../../features/quality/pages/quality_task_center_page.dart';
import '../../features/quality/pages/quality_pending_disposal_page.dart';
import '../../features/quality/pages/quality_inspection_records_page.dart';
import '../../features/quality/pages/production_fqc_inspections_page.dart';
import '../../features/quality/models/quality_inspection_record.dart';
import '../../shared/models/procurement_inbound.dart';
import '../../features/warehouse/pages/stock_doc_detail_page.dart';
import '../../features/warehouse/pages/stock_doc_edit_page.dart';
import '../../features/warehouse/pages/stock_doc_list_page.dart';
import '../../features/warehouse/config/warehouse_report_config.dart';
import '../../features/warehouse/pages/warehouse_hub_page.dart';
import '../../features/warehouse/pages/warehouse_report_table_page.dart';
import '../../features/warehouse/pages/shelf_label_page.dart';
import '../../features/warehouse/pages/warehouse_subcontract_outbound_edit_page.dart';
import '../../features/warehouse/pages/warehouse_subcontract_outbound_page.dart';
import '../../features/warehouse/pages/warehouse_sales_outbound_page.dart';
import '../../features/warehouse/pages/warehouse_outbound_task_center_page.dart';
import '../../features/warehouse/pages/warehouse_inbound_task_center_page.dart';
import '../../features/warehouse/pages/warehouse_draw_task_center_page.dart';
import '../../features/notice/pages/notice_list_page.dart';
import '../../features/notice/pages/notice_publish_page.dart';
import '../../features/reviews/pages/review_inbox_page.dart';
import '../../features/notice/models/notice.dart';
import '../../features/payroll/pages/payroll_generate_page.dart';
import '../../features/payroll/pages/payroll_review_page.dart';
import '../../features/payroll/pages/payroll_slip_detail_page.dart';
import '../../features/payroll/pages/payroll_slip_list_page.dart';
import '../../features/production/production_routes.dart';
import '../../features/procurement_iqc_rejection/pages/procurement_iqc_rejection_detail_page.dart';
import '../../features/procurement_iqc_rejection/pages/procurement_iqc_rejection_list_page.dart';
import '../../features/profile/pages/my_profile_changes_page.dart';
import '../../features/department/pages/my_department_page.dart';
import '../../features/profile/pages/profile_edit_page.dart';
import '../../features/profile/pages/profile_page.dart';
import '../../features/settings/pages/settings_page.dart';
import '../../features/settings/pages/device_audit_receipts_page.dart';
import '../../features/shell/pages/main_shell_page.dart';
import '../../features/suggestion/pages/suggestion_detail_page.dart';
import '../../features/suggestion/pages/suggestion_list_page.dart';
import '../../features/suggestion/pages/suggestion_new_page.dart';
import '../../features/webinquiry/pages/website_inquiry_detail_page.dart';
import '../../features/webinquiry/pages/website_inquiry_list_page.dart';
import '../../features/sales/models/sales_doc.dart';
import '../../features/sales/pages/sales_doc_detail_page.dart';
import '../../features/sales/pages/sales_doc_edit_page.dart';
import '../../features/sales/pages/sales_doc_list_page.dart';
import '../../features/sales/pages/sales_hub_page.dart';
import '../../features/sales/config/sales_report_config.dart';
import '../../features/sales/pages/sales_report_page.dart';
import '../../features/sales/pages/sales_scarcity_page.dart';
import '../../features/sales/pages/sales_order_progress_detail_page.dart';
import '../../features/sales/pages/sales_order_progress_page.dart';
import '../../features/subcontract/models/subcontract_doc.dart';
import '../../features/subcontract/pages/subcontract_decomposition_page.dart';
import '../../features/subcontract/pages/subcontract_hub_page.dart';
import '../../features/subcontract/pages/subcontract_page_factory.dart';
import '../../features/subcontract/pages/subcontract_preparation_page.dart';
import '../../features/subcontract/config/subcontract_report_config.dart';
import '../../features/subcontract/pages/subcontract_report_table_page.dart';
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
import 'page_resume_provider.dart';
import 'route_access_policy.dart';
import 'route_names.dart';

String? _rejectUnknownPurchaseDoc(BuildContext _, GoRouterState state) =>
    PurchaseDocType.tryByPath(state.pathParameters['doc']!) == null
    ? RouteName.notFound
    : null;

String? _rejectUnknownStockDoc(BuildContext _, GoRouterState state) =>
    StockDocType.tryByCode(state.pathParameters['code']!) == null
    ? RouteName.notFound
    : null;

String? _rejectUnknownWarehouseHistoryType(
  BuildContext _,
  GoRouterState state,
) => WarehouseDocumentHistoryType.tryParse(state.pathParameters['type']) == null
    ? RouteName.notFound
    : null;

String? _rejectUnknownSalesDoc(BuildContext _, GoRouterState state) =>
    SalesDocType.tryByPath(state.pathParameters['seg']!) == null
    ? RouteName.notFound
    : null;

String? _rejectUnknownSubcontractDoc(BuildContext _, GoRouterState state) =>
    SubcontractDocType.tryByPath(state.pathParameters['seg']!) == null
    ? RouteName.notFound
    : null;

String? _rejectUnknownFinanceDoc(BuildContext _, GoRouterState state) =>
    FinanceDocType.tryByPath(state.pathParameters['seg']!) == null
    ? RouteName.notFound
    : null;

/// 根 Navigator 的全局 key。
///
/// 「模拟身份横幅」等构建在 `MaterialApp.builder` 里、位于路由 Navigator 之外的组件，
/// 拿不到路由作用域内的 context（`showDialog` / `GoRouter.of` 会取不到而静默失败）。
/// 用 `appNavigatorKey.currentContext` 即可得到一个路由 Navigator 内的 context。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'uten-app-root',
);

/// App 路由 Provider
final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    navigatorKey: appNavigatorKey,
    initialLocation: RouteName.entry,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final vSession = ref.read(visitorSessionProvider);
      final loc = state.matchedLocation;
      final requestedLocation = state.uri.toString();
      final isEntry = loc == RouteName.entry;
      final isLogin = loc == RouteName.login;
      final isChangePw = loc == RouteName.changePassword;
      final isVisitorPath = isVisitorPortalLocation(loc);
      final employeeReturnTo = returnToFromUri(
        state.uri,
        scope: ReturnToScope.employee,
      );
      final visitorReturnTo = returnToFromUri(
        state.uri,
        scope: ReturnToScope.visitor,
      );
      final employeeIntent = intendedReturnTo(
        state.uri,
        scope: ReturnToScope.employee,
      );

      // Forced password changes retain the original employee route.
      if (session.status == AuthStatus.mustChangePassword) {
        return isChangePw
            ? null
            : RoutePath.changePassword(forced: true, returnTo: employeeIntent);
      }

      // Visitor pages use the visitor session and never accept employee paths.
      if (isVisitorPath) {
        if (session.status == AuthStatus.authenticated) {
          return RouteName.dashboard;
        }
        if (vSession.isLoggedIn) {
          return loc == RouteName.visitorLogin
              ? visitorReturnTo ?? RouteName.visitorHome
              : null;
        }
        if (loc == RouteName.visitorLogin) return null;
        return RoutePath.entry(returnTo: requestedLocation);
      }

      // The entry page preserves the deep link until a portal is selected.
      if (isEntry) {
        if (session.status == AuthStatus.authenticated) {
          return employeeReturnTo ?? RouteName.dashboard;
        }
        if (vSession.isLoggedIn) {
          return visitorReturnTo ?? RouteName.visitorHome;
        }
        return null;
      }

      switch (session.status) {
        case AuthStatus.unauthenticated:
          if (vSession.isLoggedIn) return RouteName.visitorHome;
          if (isLogin) return null;
          return RoutePath.entry(returnTo: requestedLocation);
        case AuthStatus.mustChangePassword:
          return isChangePw
              ? null
              : RoutePath.changePassword(
                  forced: true,
                  returnTo: employeeIntent,
                );
        case AuthStatus.authenticated:
          if (isLogin) return employeeReturnTo ?? RouteName.dashboard;
          return employeePermissionRedirect(session.user, loc);
      }
    },
    routes: [
      GoRoute(
        path: RouteName.login,
        name: 'login',
        builder: (context, state) => LoginPage(
          returnTo: returnToFromUri(state.uri, scope: ReturnToScope.employee),
        ),
      ),
      GoRoute(
        path: RouteName.changePassword,
        name: 'change-password',
        builder: (context, state) => ChangePasswordPage(
          forced: state.uri.queryParameters['forced'] == 'true',
          returnTo: returnToFromUri(state.uri, scope: ReturnToScope.employee),
        ),
      ),
      GoRoute(
        path: RouteName.accessDenied,
        name: 'access-denied',
        builder: (_, _) => const _AccessDeniedPage(),
      ),
      GoRoute(
        path: RouteName.notFound,
        name: 'not-found',
        builder: (_, _) => const _ErrorPage(),
      ),

      // —— 入口选择（登录前）——
      GoRoute(
        path: RouteName.entry,
        name: 'entry',
        builder: (_, state) => EntrySelectionPage(
          returnTo: returnToFromUri(state.uri, scope: ReturnToScope.any),
        ),
      ),

      // —— 访客自助流程（不进 ShellRoute）——
      GoRoute(
        path: RouteName.visitorLogin,
        name: 'visitor-login',
        builder: (_, state) => VisitorLoginPage(
          returnTo: returnToFromUri(state.uri, scope: ReturnToScope.visitor),
        ),
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
        // ⚠️ SelectionArea 已下线：Flutter 框架 bug（web 端 SelectableRegion 在
        // 动态内容重建时 _flushInactiveSelections 抛 ConcurrentModificationError），
        // 全局包裹会让轮询/表格刷新在拖选文字时崩掉整个调度帧，表现为"点了没反应"。
        // 后续如需复制功能，改为在静态内容页局部包 SelectionArea，勿全局包裹。
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
          GoRoute(
            path: RouteName.deviceAuditReceipts,
            name: 'device-audit-receipts',
            builder: (_, state) => DeviceAuditReceiptsPage(
              backRoute: RouteName.settings,
              initialOperationId: state.uri.queryParameters['operationId'],
            ),
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
          // /finance/report 在下方「钱流管理」段统一注册（与 /finance hub 同段）。

          // —— 财税部主数据别名入口（复用基础资料真实页面）——
          GoRoute(
            path: RouteName.financeCustomers,
            name: 'finance-customers',
            builder: (_, _) => const ClientCategoryPage(),
          ),
          GoRoute(
            path: RouteName.financeSuppliers,
            name: 'finance-suppliers',
            builder: (_, _) => const SupplierCategoryPage(),
          ),
          GoRoute(
            path: RouteName.financeAccounts,
            name: 'finance-accounts',
            builder: (_, _) => const AccountPage(),
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
          // V459 我的待审收件台：跨业务域待审聚合（弹卡的稳定入口）。
          GoRoute(
            path: RouteName.reviewsInbox,
            name: 'reviews-inbox',
            builder: (_, _) => const ReviewInboxPage(),
          ),
          GoRoute(
            path: RouteName.noticePublish,
            name: 'notice-publish',
            builder: (_, s) {
              final typeName = s.uri.queryParameters['type'];
              NoticeType? preset;
              if (typeName != null) {
                for (final t in NoticeType.values) {
                  if (t.name == typeName) {
                    preset = t;
                    break;
                  }
                }
              }
              return NoticePublishPage(
                presetType: preset,
                presetSubjectId: s.uri.queryParameters['subject'],
              );
            },
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

          // —— 官网询盘（综合营销统一收件箱）——
          GoRoute(
            path: '/webinquiry',
            name: 'webinquiry-list',
            builder: (_, _) => const WebsiteInquiryListPage(),
          ),
          GoRoute(
            path: '/webinquiry/:id',
            name: 'webinquiry-detail',
            builder: (_, s) =>
                WebsiteInquiryDetailPage(inquiryId: s.pathParameters['id']!),
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
            builder: (_, s) => EmployeeOnboardingPage(
              initialDepartmentId: s.uri.queryParameters['departmentId'],
            ),
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
            builder: (_, s) => EmployeeOffboardingWorkflowPage(
              employeeId: s.pathParameters['id']!,
            ),
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

          // —— 基础资料（hub：货品/模具资料同级入口；登录即可访问）——
          GoRoute(
            path: RouteName.basicinfo,
            name: 'basicinfo',
            builder: (_, _) => const BasicDataHubPage(),
          ),
          GoRoute(
            path: RouteName.basicinfoGoods,
            name: 'basicinfo-goods',
            builder: (_, _) => const ProductCategoryPage(),
          ),
          // 静态段 new 必须在 :id 前（路由文件头注释的扁平路由约定）。
          GoRoute(
            path: RouteName.basicinfoGoodsNew,
            name: 'basicinfo-goods-new',
            builder: (_, s) => GoodsDetailPage(
              categoryId: s.uri.queryParameters['categoryId'],
            ),
          ),
          GoRoute(
            path: RouteName.basicinfoGoodsDetail,
            name: 'basicinfo-goods-detail',
            builder: (_, s) => GoodsDetailPage(
              goodsId: s.pathParameters['id']!,
              initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0,
            ),
          ),
          GoRoute(
            path: RouteName.basicinfoMould,
            name: 'basicinfo-mould',
            builder: (_, _) => const MouldCategoryPage(),
          ),
          GoRoute(
            path: RouteName.basicinfoClient,
            name: 'basicinfo-client',
            builder: (_, _) => const ClientCategoryPage(),
          ),
          GoRoute(
            path: RouteName.basicinfoSupplier,
            name: 'basicinfo-supplier',
            builder: (_, _) => const SupplierCategoryPage(),
          ),
          GoRoute(
            path: RouteName.basicinfoColor,
            name: 'basicinfo-color',
            builder: (_, _) => const ColorPage(),
          ),
          GoRoute(
            path: RouteName.basicinfoUnit,
            name: 'basicinfo-unit',
            builder: (_, _) => const UnitPage(),
          ),
          GoRoute(
            path: RouteName.basicinfoCurrency,
            name: 'basicinfo-currency',
            builder: (_, _) => const CurrencyPage(),
          ),
          GoRoute(
            path: RouteName.basicinfoWarehouse,
            name: 'basicinfo-warehouse',
            builder: (_, _) => const WarehousePage(),
          ),
          GoRoute(
            path: RouteName.basicinfoAccount,
            name: 'basicinfo-account',
            builder: (_, _) => const AccountPage(),
          ),
          GoRoute(
            path: RouteName.basicinfoAccountDetail,
            name: 'basicinfo-account-detail',
            builder: (_, state) => AccountDetailPage(
              accountId: state.pathParameters['id']!,
              startEditing: state.uri.queryParameters['edit'] == 'true',
            ),
          ),
          GoRoute(
            path: RouteName.basicinfoPaymentStyle,
            name: 'basicinfo-payment-style',
            builder: (_, _) => const PaymentStylePage(),
          ),
          GoRoute(
            path: RouteName.basicinfoSettlementMethod,
            name: 'basicinfo-settlement-method',
            builder: (_, _) => const SettlementMethodPage(),
          ),

          // —— 统一履约任务工作台（只从后端真实任务与动作单据读取）——
          GoRoute(
            path: RouteName.operationsWarehouseWorkbench,
            name: 'operations-workbench-warehouse',
            builder: (_, _) => const OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.warehouse,
            ),
          ),
          GoRoute(
            path: RouteName.operationsPurchaseWorkbench,
            name: 'operations-workbench-purchase',
            builder: (_, _) => const OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
            ),
          ),
          GoRoute(
            path: RouteName.operationsSubcontractWorkbench,
            name: 'operations-workbench-subcontract',
            builder: (_, _) => const SubcontractDecompositionPage(),
          ),
          // —— 工程研发部任务中心 ——
          GoRoute(
            path: RouteName.rdTaskCenter,
            name: 'rd-task-center',
            builder: (_, _) => const RdTaskPage(),
          ),
          GoRoute(
            path: RouteName.procurementArrivalExceptions,
            name: 'procurement-return-tasks',
            builder: (_, state) => ProcurementReturnTasksPage(
              orderType: procurementInboundOrderTypeFrom(
                state.uri.queryParameters['orderType'],
              ),
            ),
          ),
          GoRoute(
            path: '${RouteName.procurementArrivalExceptions}/:id',
            name: 'procurement-return-task-detail',
            builder: (_, state) => ProcurementReturnTaskDetailPage(
              id: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: RouteName.procurementIqcRejections,
            name: 'procurement-iqc-rejections',
            builder: (_, state) => ProcurementIqcRejectionListPage(
              source: state.uri.queryParameters['from'],
            ),
          ),
          GoRoute(
            path: '${RouteName.procurementIqcRejections}/:id',
            name: 'procurement-iqc-rejection-detail',
            builder: (_, state) => ProcurementIqcRejectionDetailPage(
              id: state.pathParameters['id']!,
              source: state.uri.queryParameters['from'],
            ),
          ),

          // —— 采购管理（hub + 4 单据 list + new/detail/edit）——
          GoRoute(
            path: RouteName.purchase,
            name: 'purchase-hub',
            builder: (_, _) => const PurchaseHubPage(),
          ),
          GoRoute(
            path: RouteName.purchaseRequestList,
            name: 'purchase-request-list',
            builder: (_, _) =>
                const PurchaseDocListPage(docType: PurchaseDocType.request),
          ),
          GoRoute(
            path: RouteName.purchaseOrderList,
            name: 'purchase-order-list',
            builder: (_, _) =>
                const PurchaseDocListPage(docType: PurchaseDocType.order),
          ),
          GoRoute(
            path: RouteName.purchaseReceiptList,
            name: 'purchase-receipt-list',
            builder: (_, _) =>
                const PurchaseDocListPage(docType: PurchaseDocType.receipt),
          ),
          GoRoute(
            path: RouteName.purchaseReturnList,
            name: 'purchase-return-list',
            builder: (_, _) =>
                const PurchaseDocListPage(docType: PurchaseDocType.returnDoc),
          ),
          // 采购报表（9 张，参数化）：必须在 /purchase/:doc/:id 之前，literal "report" 段优先。
          GoRoute(
            path: '/purchase/report/:kind',
            name: 'purchase-report-table',
            builder: (_, s) => PurchaseReportTablePage(
              kind: PurchaseReportKind.byName(s.pathParameters['kind']!),
            ),
          ),
          // 采购订货单专属编辑页（2026-09 行级商业条款）：字面量路由优先于 :doc 通配。
          GoRoute(
            path: '/purchase/orders/new',
            name: 'purchase-order-new',
            builder: (_, s) => PurchaseOrderEditPage(
              sourceRequestId: s.uri.queryParameters['requestId'],
              sourceRequestItemIds:
                  s.uri.queryParameters['requestItemIds']
                      ?.split(',')
                      .where((id) => id.trim().isNotEmpty)
                      .toList() ??
                  const [],
            ),
          ),
          GoRoute(
            path: '/purchase/orders/:id/edit',
            name: 'purchase-order-edit',
            builder: (_, s) =>
                PurchaseOrderEditPage(id: s.pathParameters['id']),
          ),
          GoRoute(
            path: '/purchase/:doc/new',
            name: 'purchase-doc-new',
            redirect: _rejectUnknownPurchaseDoc,
            builder: (_, s) => PurchaseDocEditPage(
              docType: PurchaseDocType.byPath(s.pathParameters['doc']!),
            ),
          ),
          GoRoute(
            path: '/purchase/:doc/:id/edit',
            name: 'purchase-doc-edit',
            redirect: _rejectUnknownPurchaseDoc,
            builder: (_, s) => PurchaseDocEditPage(
              docType: PurchaseDocType.byPath(s.pathParameters['doc']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/purchase/:doc/:id',
            name: 'purchase-doc-detail',
            redirect: _rejectUnknownPurchaseDoc,
            builder: (_, s) => PurchaseDocDetailPage(
              docType: PurchaseDocType.byPath(s.pathParameters['doc']!),
              id: s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/purchase/report',
            name: 'purchase-report',
            builder: (_, _) => const PurchaseReportPage(),
          ),

          // —— 库存查询（即时库存为唯一入口；余额/流水并入库存详情页）——
          // 旧「库存余额」页已并入：/stock/balance 重定向到即时库存（余额在库存详情页按货品查看）。
          GoRoute(
            path: RouteName.stockBalance,
            name: 'stock-balance',
            redirect: (_, _) => RouteName.stockInstantInventory,
          ),
          // 旧「出入库流水」页已并入库存详情页：带 goodsId 的旧深链（即时库存/货品详情/
          // 物料反查）落到 /stock/item/:goodsId，无 goodsId 时回即时库存。
          GoRoute(
            path: RouteName.stockMovement,
            name: 'stock-movement',
            redirect: (_, state) {
              final goodsId =
                  state.uri.queryParameters['goodsId']?.trim() ?? '';
              return goodsId.isEmpty
                  ? RouteName.stockInstantInventory
                  : RouteName.stockItemDetail(goodsId);
            },
          ),
          GoRoute(
            path: RouteName.stockInstantInventory,
            name: 'stock-instant-inventory',
            builder: (_, _) => const InstantInventoryPage(),
          ),
          // 库存详情：即时库存双击货品行进入（各仓余额 + 出入库流水 + 受控余额调整）。
          GoRoute(
            path: '${RouteName.stockItemBase}/:goodsId',
            name: 'stock-item-detail',
            builder: (_, state) =>
                StockItemDetailPage(goodsId: state.pathParameters['goodsId']!),
          ),

          // —— 仓库管理（8 单据 hub + 列表 + new/detail/edit + 报表）——
          GoRoute(
            path: RouteName.warehouse,
            name: 'warehouse-hub',
            builder: (_, _) => const WarehouseHubPage(),
          ),
          GoRoute(
            path: RouteName.warehouseInspections,
            name: 'warehouse-inspections',
            builder: (_, _) => const QualityPendingDisposalPage(),
          ),
          // 单张收货单的待检明细处置页（extra 携带任务卡快照；深链直达时页面自行反查）。
          GoRoute(
            path: '${RouteName.warehouseInspections}/:receiptType/:receiptId',
            name: 'warehouse-inspection-detail',
            builder: (_, s) => ProcurementInspectionDetailPage(
              receiptType: s.pathParameters['receiptType']!,
              receiptId: s.pathParameters['receiptId']!,
              extra: s.extra,
            ),
          ),
          // 旧「IQC 合格待入库」详情深链：合并页详情同参，直接重定向保旧链。
          GoRoute(
            path: '${RouteName.warehouseIqcStockIns}/:receiptType/:receiptId',
            name: 'warehouse-iqc-stock-in-detail',
            redirect: (_, state) => RouteName.warehouseQualityResultDetail(
              state.pathParameters['receiptType'] ?? '',
              state.pathParameters['receiptId'] ?? '',
            ),
          ),
          // 旧「IQC 合格待入库」列表入口：合并进「品质部检查结果」，老链接/收藏重定向。
          GoRoute(
            path: RouteName.warehouseIqcStockIns,
            name: 'warehouse-iqc-stock-ins',
            redirect: (_, _) => RouteName.warehouseQualityResults,
          ),
          GoRoute(
            path: RouteName.warehouseQualityResults,
            name: 'warehouse-quality-results',
            builder: (_, _) => const WarehouseQualityResultsPage(),
          ),
          GoRoute(
            path:
                '${RouteName.warehouseQualityResults}/:receiptType/:receiptId',
            name: 'warehouse-quality-result-detail',
            builder: (_, state) => WarehouseQualityResultDetailPage(
              receiptType: state.pathParameters['receiptType']!,
              receiptId: state.pathParameters['receiptId']!,
            ),
          ),
          GoRoute(
            path: RouteName.qualityTaskCenter,
            name: 'quality-task-center',
            builder: (_, _) => const QualityTaskCenterPage(),
          ),
          GoRoute(
            path: RouteName.qualityInspectionRecords,
            name: 'quality-inspection-records',
            builder: (_, state) => QualityInspectionRecordsPage(
              initialDomain: switch (state.uri.queryParameters['domain']
                  ?.toUpperCase()) {
                'IQC' => QualityInspectionRecordDomain.iqc,
                'FQC' => QualityInspectionRecordDomain.fqc,
                _ => null,
              },
            ),
          ),
          GoRoute(
            path: RouteName.productionFqcInspections,
            name: 'production-fqc-inspections',
            builder: (_, _) => const ProductionFqcInspectionsPage(),
          ),
          GoRoute(
            path: RouteName.warehouseInboundExpectations,
            name: 'warehouse-inbound-expectations',
            builder: (_, _) => const WarehouseInboundExpectationsPage(),
          ),
          GoRoute(
            // 预计到货任务详情页（2026-09-04 双击行直达，替代居中详情弹窗）；
            // extra 带当前 InboundExpectation，深链冷启动按 id 在列表里找回。
            path: '${RouteName.warehouseInboundExpectations}/:expectationId',
            name: 'warehouse-arrival-expectation-detail',
            builder: (_, state) => WarehouseArrivalExpectationDetailPage(
              expectationId: state.pathParameters['expectationId'] ?? '',
              initial: state.extra is InboundExpectation
                  ? state.extra as InboundExpectation
                  : null,
            ),
          ),
          GoRoute(
            path: RouteName.warehouseArrivalExceptions,
            name: 'warehouse-arrival-exceptions',
            builder: (_, _) => const WarehouseArrivalExceptionsPage(),
          ),
          GoRoute(
            path: RouteName.warehouseProductionFinishedInboundTasks,
            name: 'warehouse-production-finished-inbound-tasks',
            builder: (_, _) => const ProductionFinishedInboundTasksPage(),
          ),
          GoRoute(
            // 多单汇总登记页须先于 :reportId 声明（GoRouter 按声明顺序匹配同前缀）。
            path: RouteName.warehouseProductionFinishedArrivalBatchRegistration,
            name: 'warehouse-production-finished-arrival-batch-registration',
            builder: (_, state) =>
                ProductionFinishedArrivalBatchRegistrationPage(
                  reportIds: (state.uri.queryParameters['reportIds'] ?? '')
                      .split(',')
                      .map((id) => id.trim())
                      .where((id) => id.isNotEmpty)
                      .toList(growable: false),
                  returnTo: state.uri.queryParameters['returnTo'],
                ),
          ),
          GoRoute(
            path: RouteName.warehouseProductionFinishedArrivalRegistration,
            name: 'warehouse-production-finished-arrival-registration',
            builder: (_, state) => ProductionFinishedArrivalRegistrationPage(
              reportId: state.pathParameters['reportId'] ?? '',
            ),
          ),
          // 仓库登记实际到货独立页（须在 /warehouse/:code 系列之前；extra 带预填）。
          GoRoute(
            path: RouteName.warehouseArrivalReceiptNew,
            name: 'warehouse-arrival-receipt-new',
            builder: (_, s) => WarehouseArrivalReceiptPage(
              prefill: s.extra is ProcurementReceiptPrefill
                  ? s.extra! as ProcurementReceiptPrefill
                  : null,
            ),
          ),
          // 报表（静态段，需在 /warehouse/:code 之前声明以免被当作 :code 匹配）
          GoRoute(
            path: RouteName.warehouseReport,
            name: 'warehouse-report',
            // 同上：仅精确匹配父路径时才跳明细，summary 子路由不拦。
            redirect: (_, s) => s.uri.path == RouteName.warehouseReport
                ? RouteName.warehouseReportDetail
                : null,
            routes: [
              GoRoute(
                path: 'detail',
                name: 'warehouse-report-detail',
                builder: (_, _) => const WarehouseReportTablePage(
                  kind: WarehouseReportKind.detail,
                ),
              ),
              GoRoute(
                path: 'summary',
                name: 'warehouse-report-summary',
                builder: (_, _) => const WarehouseReportTablePage(
                  kind: WarehouseReportKind.summary,
                ),
              ),
            ],
          ),
          // 货架目视化清单（静态段，须在 /warehouse/:code 系列之前声明）。
          GoRoute(
            path: RouteName.warehouseShelfLabels,
            name: 'warehouse-shelf-labels',
            builder: (_, _) => const ShelfLabelPage(),
          ),
          // 委外出仓任务中心 + 拣货出仓页（V304 仓库专属；静态段，须在 /warehouse/:code 前）。
          GoRoute(
            path: RouteName.warehouseSubcontractOutbound,
            name: 'warehouse-subcontract-outbound',
            builder: (_, _) => const WarehouseSubcontractOutboundPage(),
          ),
          GoRoute(
            path: '/warehouse/sales-outbound/:id',
            name: 'warehouse-sales-outbound-detail',
            builder: (_, state) => WarehouseSalesOutboundDetailPage(
              id: state.pathParameters['id']!,
            ),
          ),
          // 旧「IQC 不合格实物退回」详情深链（按拒收案件 id，无法映射到收货单）：
          // 重定向到合并列表；退回案件的登记入口在合并详情页内。
          GoRoute(
            path: '/warehouse/iqc-returns/:id',
            name: 'warehouse-iqc-return-detail',
            redirect: (_, _) => RouteName.warehouseQualityResults,
          ),
          // 旧「IQC 不合格实物退回」列表入口：合并进「品质部检查结果」，重定向保旧链。
          GoRoute(
            path: RouteName.warehouseIqcReturns,
            name: 'warehouse-iqc-returns',
            redirect: (_, _) => RouteName.warehouseQualityResults,
          ),
          GoRoute(
            path: RouteName.warehouseSalesOutbound,
            name: 'warehouse-sales-outbound',
            builder: (_, _) => const WarehouseSalesOutboundPage(),
          ),
          GoRoute(
            path: '/warehouse/subcontract-outbound/:planId',
            name: 'warehouse-subcontract-outbound-edit',
            builder: (_, s) => WarehouseSubcontractOutboundEditPage(
              planId: s.pathParameters['planId']!,
            ),
          ),
          // 仓库实物历史专页：静态 history 段必须先于 /warehouse/:code。
          GoRoute(
            path: '/warehouse/history/:type/:id',
            name: 'warehouse-document-history-detail',
            redirect: _rejectUnknownWarehouseHistoryType,
            builder: (_, state) => WarehouseDocumentHistoryDetailPage(
              type: WarehouseDocumentHistoryType.tryParse(
                state.pathParameters['type'],
              )!,
              id: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/warehouse/history/:type',
            name: 'warehouse-document-history-list',
            redirect: _rejectUnknownWarehouseHistoryType,
            builder: (_, state) => WarehouseDocumentHistoryListPage(
              type: WarehouseDocumentHistoryType.tryParse(
                state.pathParameters['type'],
              )!,
            ),
          ),
          // 仓库任务中心三页（2026-09-01 重组；静态段 tasks 必须先于 /warehouse/:code，
          // 否则会被 :code/:id 单据路由吞掉）。
          GoRoute(
            path: RouteName.warehouseOutboundTasks,
            name: 'warehouse-outbound-tasks',
            builder: (_, _) => const WarehouseOutboundTaskCenterPage(),
          ),
          GoRoute(
            path: RouteName.warehouseInboundTasks,
            name: 'warehouse-inbound-tasks',
            builder: (_, _) => const WarehouseInboundTaskCenterPage(),
          ),
          GoRoute(
            path: RouteName.warehouseDrawTasks,
            name: 'warehouse-draw-tasks',
            builder: (_, _) => const WarehouseDrawTaskCenterPage(),
          ),
          GoRoute(
            path: '/warehouse/:code/new',
            name: 'stock-doc-new',
            redirect: _rejectUnknownStockDoc,
            builder: (_, s) => StockDocEditPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
              sourceDrawId: s.uri.queryParameters['drawId'],
            ),
          ),
          GoRoute(
            path: '/warehouse/:code/:id/edit',
            name: 'stock-doc-edit',
            redirect: _rejectUnknownStockDoc,
            builder: (_, s) => StockDocEditPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/warehouse/:code/:id',
            name: 'stock-doc-detail',
            redirect: _rejectUnknownStockDoc,
            builder: (_, s) => StockDocDetailPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
              id: s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/warehouse/:code',
            name: 'stock-doc-list',
            redirect: _rejectUnknownStockDoc,
            builder: (_, s) => StockDocListPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
            ),
          ),

          // —— 销售管理（综合营销部；静态段 /sales/report 在 :seg 参数路由前）——
          GoRoute(
            path: RouteName.sales,
            name: 'sales-hub',
            builder: (_, _) => const SalesHubPage(),
          ),
          GoRoute(
            path: RouteName.salesReport,
            name: 'sales-report',
            // 仅精确匹配 /sales/report 时跳明细；子路由（detail/summary）不拦——
            // go_router 父路由 redirect 对子路由同样生效，无条件跳会把 summary 也拐到 detail。
            redirect: (_, s) => s.uri.path == RouteName.salesReport
                ? RouteName.salesReportDetail
                : null,
            routes: [
              GoRoute(
                path: 'detail',
                name: 'sales-report-detail',
                builder: (_, _) =>
                    const SalesReportPage(kind: SalesReportKind.detail),
              ),
              GoRoute(
                path: 'summary',
                name: 'sales-report-summary',
                builder: (_, _) =>
                    const SalesReportPage(kind: SalesReportKind.summary),
              ),
            ],
          ),
          GoRoute(
            path: RouteName.salesScarcity,
            name: 'sales-scarcity',
            builder: (_, s) => SalesScarcityPage(
              initialGoodsId: s.uri.queryParameters['goodsId'],
              initialColorId: s.uri.queryParameters['colorId'],
            ),
          ),
          GoRoute(
            path: RouteName.salesOrderProgress,
            name: 'sales-order-progress',
            builder: (_, _) => const SalesOrderProgressPage(),
          ),
          GoRoute(
            path: '${RouteName.salesOrderProgress}/:orderId',
            name: 'sales-order-progress-detail',
            builder: (_, s) => SalesOrderProgressDetailPage(
              orderId: s.pathParameters['orderId']!,
            ),
          ),
          GoRoute(
            path: '/sales/:seg/new',
            name: 'sales-doc-new',
            redirect: _rejectUnknownSalesDoc,
            builder: (_, s) => SalesDocEditPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
            ),
          ),
          GoRoute(
            path: '/sales/:seg/:id/edit',
            name: 'sales-doc-edit',
            redirect: _rejectUnknownSalesDoc,
            builder: (_, s) => SalesDocEditPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/sales/:seg/:id',
            name: 'sales-doc-detail',
            redirect: _rejectUnknownSalesDoc,
            builder: (_, s) => SalesDocDetailPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/sales/:seg',
            name: 'sales-doc-list',
            redirect: _rejectUnknownSalesDoc,
            builder: (_, s) => SalesDocListPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
            ),
          ),

          // —— 委外管理（综合营销部；静态段 /subcontract/report 在 :seg 参数路由前）——
          GoRoute(
            path: RouteName.subcontract,
            name: 'subcontract-hub',
            builder: (_, _) => const SubcontractHubPage(),
          ),
          GoRoute(
            path: RouteName.subcontractReport,
            name: 'subcontract-report',
            builder: (_, _) => const SubcontractHubPage(),
          ),
          GoRoute(
            path: RouteName.subcontractPreparations,
            name: 'subcontract-preparations',
            builder: (_, state) => SubcontractPreparationPage(
              planItemId: state.uri.queryParameters['planItemId'],
              sourceAnalysisId: state.uri.queryParameters['sourceAnalysisId'],
              sourceMaterialLineId:
                  state.uri.queryParameters['sourceMaterialLineId'],
            ),
          ),
          // 委外报表（3 卡：明细/汇总/出入状况，静态段 report 优先于 :seg 参数路由）
          GoRoute(
            path: '/subcontract/report/:kind',
            name: 'subcontract-report-table',
            builder: (_, s) => SubcontractReportTablePage(
              kind: SubcontractReportKind.byRouteSegment(
                s.pathParameters['kind']!,
              ),
            ),
          ),
          GoRoute(
            path: '/subcontract/:seg/new',
            name: 'subcontract-doc-new',
            redirect: _rejectUnknownSubcontractDoc,
            builder: (_, s) => SubcontractPageFactory.editor(
              type: SubcontractDocType.byPath(s.pathParameters['seg']!),
              applicationItemIds:
                  s.uri.queryParameters['applicationItemIds']
                      ?.split(',')
                      .where((id) => id.trim().isNotEmpty)
                      .toList() ??
                  const [],
            ),
          ),
          GoRoute(
            path: '/subcontract/:seg/:id/edit',
            name: 'subcontract-doc-edit',
            redirect: _rejectUnknownSubcontractDoc,
            builder: (_, s) => SubcontractPageFactory.editor(
              type: SubcontractDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/subcontract/:seg/:id',
            name: 'subcontract-doc-detail',
            redirect: _rejectUnknownSubcontractDoc,
            builder: (_, s) => SubcontractPageFactory.detail(
              SubcontractDocType.byPath(s.pathParameters['seg']!),
              s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/subcontract/:seg',
            name: 'subcontract-doc-list',
            redirect: _rejectUnknownSubcontractDoc,
            builder: (_, s) => SubcontractPageFactory.list(
              SubcontractDocType.byPath(s.pathParameters['seg']!),
            ),
          ),

          // —— 生产管理（模块公开路由清单；静态段在 :id 参数路由前）——
          ...productionRoutes,

          // —— 钱流管理（财税部；静态段 /finance/{report|ar-ap|reconciliations|checks|
          //    customers|suppliers|accounts} 必须在 :seg 参数路由前声明）——
          GoRoute(
            path: RouteName.finance,
            name: 'finance-hub',
            builder: (_, _) => const FinanceHubPage(),
          ),
          GoRoute(
            path: RouteName.financePayables,
            name: 'finance-payables',
            builder: (_, _) => const FinancePayablesPage(),
          ),
          GoRoute(
            path: '/finance/procurement-approvals',
            name: 'finance-procurement-approvals',
            builder: (_, _) => const FinanceProcurementApprovalTasksPage(),
          ),
          GoRoute(
            path: '/finance/procurement-approvals/:caseId',
            name: 'finance-procurement-approval-review',
            builder: (_, state) => FinanceProcurementApprovalReviewPage(
              caseId: state.pathParameters['caseId']!,
            ),
          ),
          GoRoute(
            path: '/finance/sales-order-confirmations',
            name: 'finance-sales-order-confirmations',
            builder: (_, _) => const FinanceSalesOrderConfirmationPage(),
          ),
          GoRoute(
            path: '/finance/sales-order-confirmations/:id',
            name: 'finance-sales-order-review',
            builder: (_, state) =>
                FinanceSalesOrderReviewPage(id: state.pathParameters['id']!),
          ),
          GoRoute(
            path: RouteName.financeSalesShipmentAudit,
            name: 'finance-sales-shipment-audit',
            builder: (_, _) => const FinanceSalesShipmentAuditPage(),
          ),
          GoRoute(
            path: RouteName.financeArrivalExceptions,
            name: 'finance-arrival-exceptions',
            builder: (_, _) => const FinanceArrivalExceptionTasksPage(),
          ),
          GoRoute(
            path: '${RouteName.financeArrivalExceptions}/:id',
            name: 'finance-arrival-exception-detail',
            builder: (_, state) => FinanceArrivalExceptionDetailPage(
              id: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: RouteName.financeReport,
            name: 'finance-report',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'detail'),
          ),
          GoRoute(
            path: RouteName.financeReportDetail,
            name: 'finance-report-detail',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'detail'),
          ),
          GoRoute(
            path: RouteName.financeReportSummary,
            name: 'finance-report-summary',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'summary'),
          ),
          GoRoute(
            path: RouteName.financeReportOverview,
            name: 'finance-report-overview',
            builder: (_, _) => const FinanceArApOverviewPage(),
          ),
          GoRoute(
            path: RouteName.financeReportStatement,
            name: 'finance-report-statement',
            builder: (_, _) => const FinanceStatementPage(),
          ),
          GoRoute(
            path: RouteName.financeReportAccountFlow,
            name: 'finance-report-account-flow',
            builder: (_, _) => const FinanceAccountFlowPage(),
          ),
          GoRoute(
            path: RouteName.financeReportCustomerPrepayment,
            name: 'finance-report-customer-prepayment',
            builder: (_, _) =>
                const FinanceReportTablePage(cardId: 'customer-prepayment'),
          ),
          GoRoute(
            path: RouteName.financeReportRecon,
            name: 'finance-report-recon',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'recon'),
          ),
          GoRoute(
            path: RouteName.financeReportCost,
            name: 'finance-report-cost',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'cost'),
          ),
          GoRoute(
            path: RouteName.financeReportGl,
            name: 'finance-report-gl',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'gl'),
          ),
          GoRoute(
            path: RouteName.financeArAp,
            name: 'finance-ar-ap',
            builder: (_, _) => const FinanceArApPage(),
          ),
          GoRoute(
            path: RouteName.financeReconciliations,
            name: 'finance-reconciliations',
            builder: (_, _) => const FinanceReconciliationPage(),
          ),
          GoRoute(
            path: RouteName.financeChecks,
            name: 'finance-checks',
            builder: (_, _) =>
                const AccountPage(initialAccountTypeFilter: 'CHECK'),
          ),
          GoRoute(
            path: RouteName.financeAssets,
            name: 'finance-assets',
            builder: (_, _) => const FinanceAssetsPage(),
          ),
          GoRoute(
            path: '/finance/:seg/new',
            name: 'finance-doc-new',
            redirect: _rejectUnknownFinanceDoc,
            builder: (_, s) => FinanceDocEditPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
            ),
          ),
          GoRoute(
            path: '/finance/:seg/:id/edit',
            name: 'finance-doc-edit',
            redirect: _rejectUnknownFinanceDoc,
            builder: (_, s) => FinanceDocEditPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/finance/:seg/:id',
            name: 'finance-doc-detail',
            redirect: _rejectUnknownFinanceDoc,
            builder: (_, s) => FinanceDocDetailPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/finance/:seg',
            name: 'finance-doc-list',
            redirect: _rejectUnknownFinanceDoc,
            builder: (_, s) => FinanceDocListPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
            ),
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
            // ?field=xxx：从「我的」页字段铅笔进入，编辑页定位聚焦该字段。
            builder: (_, s) =>
                ProfileEditPage(initialField: s.uri.queryParameters['field']),
          ),
          GoRoute(
            path: RouteName.profileMyChanges,
            name: 'profile-my-changes',
            builder: (_, _) => const MyProfileChangesPage(),
          ),
          GoRoute(
            path: RouteName.profileMyDepartment,
            name: 'profile-my-department',
            builder: (_, _) => const MyDepartmentPage(),
          ),
          // 我的车辆与号码(/profile/me/vehicles)、我的文件(/profile/me/documents)
          // 独立页已吸收为「我的」页 Tab（我的页 v7），路由下线。

          // —— HR 端：工作台（今日概览 + 转正/生日/周年/新入职子页，ADR-021） ——
          GoRoute(
            path: RouteName.hrTaskCenter,
            name: 'hr-task-center',
            builder: (_, _) => const HrWorkbenchPage(),
            routes: [
              GoRoute(
                path: ':type',
                name: 'hr-task-list',
                builder: (_, s) {
                  final type =
                      HrTaskType.fromTaskType(s.pathParameters['type']) ??
                      HrTaskType.confirm;
                  return HrTaskListPage(type: type);
                },
              ),
            ],
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

          // —— 业务页面内权限设置（超管 / 部门负责人）——
          GoRoute(
            path: RouteName.pagePermissions,
            name: 'page-permissions',
            builder: (_, state) => PagePermissionSettingsPage(
              surfaceKey: state.pathParameters['surfaceKey'] ?? '',
            ),
          ),

          // —— 系统管理（超管）——
          GoRoute(
            path: RouteName.adminPermissions,
            name: 'admin-permissions',
            builder: (_, state) => AdminPermissionsPage(
              initialEmployeeId: state.uri.queryParameters['employeeId'],
              initialDepartmentId: state.uri.queryParameters['departmentId'],
            ),
          ),
          GoRoute(
            path: RouteName.adminAuditLogs,
            name: 'admin-audit-logs',
            builder: (_, state) => AdminAuditLogPage(
              initialRequestId: state.uri.queryParameters['requestId'],
            ),
          ),
          GoRoute(
            path: RouteName.adminAuditSession,
            name: 'admin-audit-session',
            builder: (_, state) => AdminAuditSessionDetailPage(
              sessionId: state.pathParameters['sessionId'] ?? '',
              routeSnapshotAuditId: int.tryParse(
                state.uri.queryParameters['snapshotAuditId'] ?? '',
              ),
              initialSummary: state.extra is AuditSessionSummary
                  ? state.extra! as AuditSessionSummary
                  : null,
            ),
          ),
          GoRoute(
            path: RouteName.adminSystemSettings,
            name: 'admin-system-settings',
            builder: (_, _) => const AdminSystemSettingsPage(),
          ),
        ],
      ),
    ],
    errorBuilder: (_, _) => const _ErrorPage(),
  );

  // 「返回即刷新」信号源：任何导航落定（go / push / pop / 系统返回手势 / 深链）后，
  // 把最新路径写入 pageResumeProvider；页面据此在自己重新可见时刷新数据。
  // 路由监听可能在 build 阶段触发，故推迟到微任务里再改 provider，
  // 避免 "Tried to modify a provider while the widget tree was building"。
  var routerDisposed = false;
  router.routerDelegate.addListener(() {
    if (routerDisposed) return;
    Future.microtask(() {
      if (routerDisposed) return;
      bumpPageResume(ref, router.routerDelegate.currentConfiguration.uri.path);
    });
  });

  ref.listen(sessionProvider, (_, _) {
    router.refresh();
  });
  ref.listen(visitorSessionProvider, (_, _) {
    router.refresh();
  });

  ref.onDispose(() {
    routerDisposed = true;
    router.dispose();
  });

  return router;
});

class _ErrorPage extends StatelessWidget {
  const _ErrorPage();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('页面不存在')),
      body: Center(child: Text(l10n.commonError)),
    );
  }
}

class _AccessDeniedPage extends StatelessWidget {
  const _AccessDeniedPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('无权访问')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 56,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text('当前账号没有访问此页面的权限', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  '如需处理这项业务，请联系权限管理员授权。系统未打开目标页面，也未执行任何操作。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => context.go(RouteName.dashboard),
                  icon: const Icon(Icons.dashboard_outlined),
                  label: const Text('返回工作台'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
