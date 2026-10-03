// 路由配置
// 文档：docs/05-架构/路由设计.md · 全局机制权限见 docs/05-架构/全局机制.md
// 使用 go_router，扁平路由（静态段声明在 :id 之前避免冲突）

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/stock/models/instant_inventory_scope.dart';
import '../../shared/ai/guided/ai_guided_file_plan.dart';

import '../l10n/gen/app_localizations.dart';
import '../../features/admin/pages/admin_audit_log_page.dart';
import '../../features/admin/pages/admin_audit_session_detail_page.dart';
import '../../features/admin/models/audit_session.dart';
import '../../features/admin/pages/admin_ai_settings_page.dart';
import '../../features/admin/pages/admin_system_settings_page.dart';
import '../../features/admin/pages/server_status_page.dart';
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
import '../../features/basic_data/pages/party_detail_page.dart';
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
import '../../features/expense/pages/expense_claim_edit_page.dart';
import '../../features/expense/pages/expense_settings_page.dart';
import '../../features/finance/models/finance_doc.dart';
import '../../features/finance/pages/finance_ar_ap_page.dart';
import '../../features/finance/pages/finance_assets_page.dart';
import '../../features/finance/widgets/finance_asset_form.dart';
import '../../features/finance/models/finance_asset_models.dart';
import '../../features/finance/pages/finance_doc_detail_page.dart';
import '../../features/finance/pages/finance_doc_edit_page.dart';
import '../../features/finance/pages/finance_doc_list_page.dart';
import '../../features/finance/pages/finance_audit_center_page.dart';
import '../../features/finance/pages/finance_hub_page.dart';
import '../../features/finance/payables/pages/finance_payables_page.dart';
import '../../features/finance/pages/finance_procurement_approval_review_page.dart';
import '../../features/finance/pages/finance_procurement_approval_tasks_page.dart';
import '../../features/finance/pages/finance_sales_order_confirmation_page.dart';
import '../../features/finance/pages/finance_sales_order_review_page.dart';
import '../../features/finance/pages/finance_sales_shipment_audit_page.dart';
import '../../features/finance/pages/finance_sales_shipment_audit_review_page.dart';
import '../../features/finance/pages/finance_quote_review_list_page.dart';
import '../../features/finance/pages/finance_quote_review_page.dart';
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
import '../../features/purchase/widgets/purchase_draft_task_category.dart';
import '../../features/purchase/config/purchase_report_config.dart';
import '../../features/purchase/models/purchase_doc.dart';
import '../../features/stock/pages/instant_inventory_page.dart';
import '../../features/stock/pages/instant_inventory_overview_page.dart';
import '../../features/stock/pages/stock_item_detail_page.dart';
import '../../features/warehouse/models/stock_check_prefill.dart';
import '../../features/warehouse/models/stock_doc.dart';
import '../../features/warehouse/config/warehouse_document_history_config.dart';
import '../../features/warehouse/pages/finance_arrival_exception_pages.dart';
import '../../features/warehouse/pages/procurement_return_task_pages.dart';
import '../../features/warehouse/pages/warehouse_arrival_exceptions_page.dart';
import '../../features/warehouse/pages/warehouse_arrival_batch_receipt_page.dart';
import '../../features/warehouse/pages/warehouse_arrival_receipt_page.dart';
import '../../features/warehouse/pages/warehouse_inbound_expectations_page.dart';
import '../../features/warehouse/models/production_finished_inbound_task.dart';
import '../../features/warehouse/models/warehouse_quality_result.dart';
import '../../features/warehouse/pages/warehouse_quality_batch_stock_in_page.dart';
import '../../features/warehouse/pages/warehouse_quality_pre_stock_in_page.dart';
import '../../features/warehouse/pages/warehouse_quality_result_detail_page.dart';
import '../../features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import '../../features/warehouse/pages/warehouse_document_history_detail_page.dart';
import '../../features/warehouse/pages/warehouse_document_history_list_page.dart';
import '../../features/warehouse/pages/production_finished_arrival_batch_registration_page.dart';
import '../../features/warehouse/pages/production_finished_arrival_registration_page.dart';
import '../../features/warehouse/pages/production_finished_batch_stock_in_page.dart';
import '../../features/warehouse/pages/production_finished_inbound_tasks_page.dart';
import '../../features/quality/pages/quality_task_center_page.dart';
import '../../features/quality/pages/quality_pending_disposal_page.dart';
import '../../features/quality/pages/quality_batch_approval_page.dart';
import '../../features/quality/pages/quality_inspection_records_page.dart';
import '../../features/quality/pages/production_fqc_handling_page.dart';
import '../../features/quality/pages/production_fqc_inspections_page.dart';
import '../../features/quality/models/quality_inspection_record.dart';
import '../../shared/models/procurement_inbound.dart';
import '../../features/warehouse/pages/stock_doc_detail_page.dart';
import '../../features/warehouse/pages/production_draw_batch_issue_page.dart';
import '../../features/warehouse/pages/production_material_discovery_page.dart';
import '../../features/warehouse/pages/stock_doc_edit_page.dart';
import '../../features/warehouse/pages/stock_doc_list_page.dart';
import '../../features/warehouse/config/warehouse_report_config.dart';
import '../../features/warehouse/pages/warehouse_hub_page.dart';
import '../../features/warehouse/pages/warehouse_insight_page.dart';
import '../../features/warehouse/pages/warehouse_report_table_page.dart';
import '../../features/warehouse/pages/warehouse_weigh_count_page.dart';
import '../../features/warehouse/pages/shelf_label_page.dart';
import '../../features/warehouse/pages/warehouse_subcontract_outbound_edit_page.dart';
import '../../features/warehouse/pages/warehouse_subcontract_outbound_page.dart';
import '../../features/warehouse/pages/warehouse_sales_outbound_page.dart';
import '../../features/warehouse/pages/warehouse_task_center_page.dart';
import '../../features/warehouse/materialbin/pages/workshop_material_bin_page.dart';
import '../../features/warehouse/materialbin/pages/workshop_material_count_page.dart';
import '../../features/warehouse/materialbin/pages/workshop_material_issue_page.dart';
import '../../features/warehouse/materialbin/pages/workshop_material_setup_page.dart';
import '../../features/notice/pages/notice_list_page.dart';
import '../../features/notice/pages/notice_publish_page.dart';
import '../../features/notice/models/notice.dart';
import '../../features/notice/providers/notice_providers.dart'
    show NoticeFilter;
import '../../features/payroll/pages/payroll_generate_page.dart';
import '../../features/payroll/pages/payroll_review_page.dart';
import '../../features/payroll/pages/payroll_slip_detail_page.dart';
import '../../features/payroll/pages/payroll_slip_list_page.dart';
import '../../features/production/production_routes.dart';
import '../../features/production/pages/workshop_material_reports_page.dart';
import '../../features/stock/counts/pages/stock_count_review_page.dart';
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
import '../../features/sales/pages/sales_task_center_page.dart';
import '../../features/subcontract/models/subcontract_doc.dart';
import '../../features/subcontract/pages/subcontract_decomposition_page.dart';
import '../../features/subcontract/pages/subcontract_hub_page.dart';
import '../../features/subcontract/pages/subcontract_page_factory.dart';
import '../../features/subcontract/pages/subcontract_short_delivery_page.dart';
import '../../features/subcontract/config/subcontract_report_config.dart';
import '../../features/subcontract/pages/subcontract_report_table_page.dart';
import '../../features/security/pages/security_blacklist_page.dart';
import '../../features/security/pages/security_scan_page.dart';
import '../../features/visitor_approval/pages/my_visitors_page.dart';
import '../../features/visitor_approval/pages/visitor_approval_detail_page.dart';
import '../../features/visitor_approval/pages/visitor_approval_list_page.dart';
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
import '../../shared/drafts/form_draft_navigation.dart';
import '../../shared/drafts/form_drafts_page.dart';

String? _rejectUnknownPurchaseDoc(BuildContext _, GoRouterState state) =>
    PurchaseDocType.tryByPath(state.pathParameters['doc']!) == null
    ? RouteName.notFound
    : null;

String? _rejectUnknownStockDoc(BuildContext _, GoRouterState state) =>
    StockDocType.tryByCode(state.pathParameters['code']!) == null
    ? RouteName.notFound
    : null;

String? _rejectStockDocManualEdit(BuildContext context, GoRouterState state) {
  final unknown = _rejectUnknownStockDoc(context, state);
  if (unknown != null) return unknown;
  final code = state.pathParameters['code']!;
  if (StockDocType.byCode(code).supportsManualDraft) return null;
  final id = state.pathParameters['id'];
  return id == null
      ? RoutePath.stockDocList(code)
      : RoutePath.stockDocDetail(code, id);
}

String? _rejectUnknownWarehouseHistoryType(
  BuildContext _,
  GoRouterState state,
) => WarehouseDocumentHistoryType.tryParse(state.pathParameters['type']) == null
    ? RouteName.notFound
    : null;

String? _rejectUnknownSalesDoc(BuildContext _, GoRouterState state) {
  final type = SalesDocType.tryByPath(state.pathParameters['seg']!);
  if (type == null) return RouteName.notFound;
  if (type == SalesDocType.otherShipment && state.uri.path.endsWith('/new')) {
    return '/sales/customer-shipments/new';
  }
  if (type == SalesDocType.otherShipment && state.uri.path.endsWith('/edit')) {
    return '/sales/other-shipments/${state.pathParameters['id']}';
  }
  return null;
}

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
    // 2026-09-25 入口选择页退役：平台定位公司内部，应用直接落在员工登录页；
    // 访客门户前端同步下线（后端能力保留，将来另做独立入口）。
    initialLocation: RouteName.login,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      final isEntry = loc == RouteName.entry;
      final isLogin = loc == RouteName.login;
      final isChangePw = loc == RouteName.changePassword;
      final employeeReturnTo = returnToFromUri(
        state.uri,
        scope: ReturnToScope.employee,
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

      // 访客门户前端已下线(2026-09-25)：访客路径不再进入访客流程，
      // 员工已登录回工作台，其余一律落到员工登录页（访客页面代码保留但不可达）。
      if (isVisitorPortalLocation(loc)) {
        return session.status == AuthStatus.authenticated
            ? RouteName.dashboard
            : RouteName.login;
      }

      // 旧 /entry 深链兼容重定向到登录页（保留员工侧 returnTo）。
      if (isEntry) {
        if (session.status == AuthStatus.authenticated) {
          return employeeReturnTo ?? RouteName.dashboard;
        }
        return RoutePath.login(returnTo: employeeReturnTo);
      }

      switch (session.status) {
        case AuthStatus.unauthenticated:
          if (isLogin) return null;
          return RoutePath.login(returnTo: employeeIntent);
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
      DraftAwareGoRoute(
        path: RouteName.login,
        name: 'login',
        builder: (context, state) => LoginPage(
          returnTo: returnToFromUri(state.uri, scope: ReturnToScope.employee),
        ),
      ),
      DraftAwareGoRoute(
        path: RouteName.changePassword,
        name: 'change-password',
        builder: (context, state) => ChangePasswordPage(
          forced: state.uri.queryParameters['forced'] == 'true',
          returnTo: returnToFromUri(state.uri, scope: ReturnToScope.employee),
        ),
      ),
      DraftAwareGoRoute(
        path: RouteName.accessDenied,
        name: 'access-denied',
        builder: (_, _) => const _AccessDeniedPage(),
      ),
      DraftAwareGoRoute(
        path: RouteName.notFound,
        name: 'not-found',
        builder: (_, _) => const _ErrorPage(),
      ),

      // —— 入口选择页已退役(2026-09-25)：/entry 由 redirect 兼容重定向到 /login ——

      // —— 访客自助流程（不进 ShellRoute）——
      // 2026-09-25 前端下线：redirect 把全部 /visitor* 路径拦到员工登录页，
      // 以下路由与页面代码保留（后端访客能力不动），将来另做独立入口时恢复。
      DraftAwareGoRoute(
        path: RouteName.visitorLogin,
        name: 'visitor-login',
        builder: (_, state) => VisitorLoginPage(
          returnTo: returnToFromUri(state.uri, scope: ReturnToScope.visitor),
        ),
      ),
      DraftAwareGoRoute(
        path: RouteName.visitorHome,
        name: 'visitor-home',
        builder: (_, _) => const VisitorHomePage(),
      ),
      DraftAwareGoRoute(
        path: RouteName.visitorSettings,
        name: 'visitor-settings',
        builder: (_, _) => const VisitorSettingsPage(),
      ),
      DraftAwareGoRoute(
        path: RouteName.visitorApply,
        name: 'visitor-apply',
        builder: (_, _) => const VisitorApplyPage(),
      ),
      DraftAwareGoRoute(
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
          DraftAwareGoRoute(
            path: RouteName.home,
            redirect: (_, _) => RouteName.dashboard,
          ),

          // —— 地基 ——
          DraftAwareGoRoute(
            path: RouteName.dashboard,
            name: 'dashboard',
            builder: (_, _) => const DashboardPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.profile,
            name: 'profile',
            builder: (_, _) => const ProfilePage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.settings,
            name: 'settings',
            builder: (_, _) => const SettingsPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.deviceAuditReceipts,
            name: 'device-audit-receipts',
            builder: (_, state) => DeviceAuditReceiptsPage(
              backRoute: RouteName.settings,
              initialOperationId: state.uri.queryParameters['operationId'],
            ),
          ),

          // —— 工资 ——
          DraftAwareGoRoute(
            path: '/payroll/slip',
            name: 'payroll-slip-list',
            builder: (_, _) => const PayrollSlipListPage(),
          ),
          DraftAwareGoRoute(
            path: '/payroll/slip/:id',
            name: 'payroll-slip-detail',
            builder: (_, s) =>
                PayrollSlipDetailPage(slipId: s.pathParameters['id']!),
          ),
          DraftAwareGoRoute(
            path: '/payroll/generate',
            name: 'payroll-generate',
            builder: (_, _) => const PayrollGeneratePage(),
          ),
          DraftAwareGoRoute(
            path: '/payroll/review',
            name: 'payroll-review',
            builder: (_, _) => const PayrollReviewPage(),
          ),
          // /finance/report 在下方「钱流管理」段统一注册（与 /finance hub 同段）。

          // —— 财税部主数据别名入口（复用基础资料真实页面）——
          DraftAwareGoRoute(
            path: RouteName.financeCustomers,
            name: 'finance-customers',
            builder: (_, _) => const ClientCategoryPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeSuppliers,
            name: 'finance-suppliers',
            builder: (_, _) => const SupplierCategoryPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeAccounts,
            name: 'finance-accounts',
            builder: (_, _) => const AccountPage(),
          ),

          // —— 报销（approval 静态段在 :id 前）——
          DraftAwareGoRoute(
            path: '/expense',
            name: 'expense-list',
            builder: (_, _) => const ExpenseListPage(),
          ),
          DraftAwareGoRoute(
            path: '/expense/new',
            name: 'expense-new',
            builder: (_, s) => ExpenseClaimEditPage(
              initialGuidedPlan: s.extra is AiGuidedFilePlan
                  ? s.extra as AiGuidedFilePlan
                  : null,
            ),
          ),
          DraftAwareGoRoute(
            path: '/expense/settings',
            name: 'expense-settings',
            builder: (_, _) => const ExpenseSettingsPage(),
          ),
          DraftAwareGoRoute(
            path: '/expense/:id/edit',
            name: 'expense-edit',
            builder: (_, s) =>
                ExpenseClaimEditPage(claimId: s.pathParameters['id']!),
          ),
          DraftAwareGoRoute(
            path: '/expense/approval',
            name: 'expense-approval-list',
            builder: (_, _) => const ExpenseApprovalListPage(),
          ),
          DraftAwareGoRoute(
            path: '/expense/approval/:id',
            name: 'expense-approval-detail',
            builder: (_, s) =>
                ExpenseApprovalDetailPage(claimId: s.pathParameters['id']!),
          ),
          DraftAwareGoRoute(
            path: '/expense/:id',
            name: 'expense-detail',
            builder: (_, s) =>
                ExpenseDetailPage(claimId: s.pathParameters['id']!),
          ),

          // —— 通知 ——
          DraftAwareGoRoute(
            path: '/notice',
            name: 'notice-list',
            // ?filter=unread|important 直达筛选段（工作台「重要通知」指标深链）。
            builder: (_, s) => NoticeListPage(
              initialFilter: switch (s.uri.queryParameters['filter']) {
                'unread' => NoticeFilter.unread,
                'important' => NoticeFilter.important,
                _ => null,
              },
            ),
          ),
          DraftAwareGoRoute(
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
          DraftAwareGoRoute(
            path: '/notice/:id',
            name: 'notice-detail',
            builder: (_, s) =>
                NoticeDetailPage(noticeId: s.pathParameters['id']!),
          ),

          // —— 建议箱 ——
          DraftAwareGoRoute(
            path: '/suggestion',
            name: 'suggestion-list',
            builder: (_, _) => const SuggestionListPage(),
          ),
          DraftAwareGoRoute(
            path: '/suggestion/new',
            name: 'suggestion-new',
            builder: (_, _) => const SuggestionNewPage(),
          ),
          DraftAwareGoRoute(
            path: '/suggestion/:id',
            name: 'suggestion-detail',
            builder: (_, s) =>
                SuggestionDetailPage(suggestionId: s.pathParameters['id']!),
          ),

          // —— 官网询盘（综合营销统一收件箱）——
          DraftAwareGoRoute(
            path: '/webinquiry',
            name: 'webinquiry-list',
            builder: (_, _) => const WebsiteInquiryListPage(),
          ),
          DraftAwareGoRoute(
            path: '/webinquiry/:id',
            name: 'webinquiry-detail',
            builder: (_, s) =>
                WebsiteInquiryDetailPage(inquiryId: s.pathParameters['id']!),
          ),

          // —— 员工档案（onboarding/edit/offboarding 静态段在 :id 前）——
          DraftAwareGoRoute(
            path: '/employee',
            name: 'employee-list',
            builder: (_, _) => const EmployeeListPage(),
          ),
          DraftAwareGoRoute(
            path: '/employee/onboarding',
            name: 'employee-onboarding',
            builder: (_, s) => EmployeeOnboardingPage(
              initialDepartmentId: s.uri.queryParameters['departmentId'],
            ),
          ),
          DraftAwareGoRoute(
            path: '/employee/:id/edit',
            name: 'employee-edit',
            builder: (_, s) =>
                EmployeeEditPage(employeeId: s.pathParameters['id']!),
          ),
          DraftAwareGoRoute(
            path: '/employee/:id/offboarding',
            name: 'employee-offboarding',
            builder: (_, s) => EmployeeOffboardingWorkflowPage(
              employeeId: s.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: '/employee/:id',
            name: 'employee-detail',
            builder: (_, s) =>
                EmployeeDetailPage(employeeId: s.pathParameters['id']!),
          ),

          // —— 部门 ——
          DraftAwareGoRoute(
            path: '/department',
            name: 'department',
            builder: (_, _) => const DepartmentPage(),
          ),

          // —— 基础资料（hub：货品/模具资料同级入口；登录即可访问）——
          DraftAwareGoRoute(
            path: RouteName.basicinfo,
            name: 'basicinfo',
            builder: (_, _) => const BasicDataHubPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoGoods,
            name: 'basicinfo-goods',
            builder: (_, _) => const ProductCategoryPage(),
          ),
          // 静态段 new 必须在 :id 前（路由文件头注释的扁平路由约定）。
          DraftAwareGoRoute(
            path: RouteName.basicinfoGoodsNew,
            name: 'basicinfo-goods-new',
            builder: (_, s) => GoodsDetailPage(
              categoryId: s.uri.queryParameters['categoryId'],
            ),
          ),
          // ?tab= 原样交给页面：命名键 basic|bom|cost|files|stock，兼容旧数字 0/1 (ADR-135)。
          DraftAwareGoRoute(
            path: RouteName.basicinfoGoodsDetail,
            name: 'basicinfo-goods-detail',
            builder: (_, s) => GoodsDetailPage(
              goodsId: s.pathParameters['id']!,
              initialTab: s.uri.queryParameters['tab'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoMould,
            name: 'basicinfo-mould',
            builder: (_, _) => const MouldCategoryPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoClient,
            name: 'basicinfo-client',
            builder: (_, _) => const ClientCategoryPage(),
          ),
          // 2026-09-14：客户详情整页（双击列表行进入，替代 560 宽弹窗）。
          DraftAwareGoRoute(
            path: RouteName.basicinfoClientDetail,
            name: 'basicinfo-client-detail',
            builder: (_, s) => PartyDetailPage(
              partyType: 'client',
              id: s.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoSupplier,
            name: 'basicinfo-supplier',
            builder: (_, _) => const SupplierCategoryPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoSupplierDetail,
            name: 'basicinfo-supplier-detail',
            builder: (_, s) => PartyDetailPage(
              partyType: 'supplier',
              id: s.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoColor,
            name: 'basicinfo-color',
            builder: (_, _) => const ColorPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoUnit,
            name: 'basicinfo-unit',
            builder: (_, _) => const UnitPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoCurrency,
            name: 'basicinfo-currency',
            builder: (_, _) => const CurrencyPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoWarehouse,
            name: 'basicinfo-warehouse',
            builder: (_, _) => const WarehousePage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoAccount,
            name: 'basicinfo-account',
            builder: (_, _) => const AccountPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoAccountDetail,
            name: 'basicinfo-account-detail',
            builder: (_, state) => AccountDetailPage(
              accountId: state.pathParameters['id']!,
              startEditing: state.uri.queryParameters['edit'] == 'true',
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoPaymentStyle,
            name: 'basicinfo-payment-style',
            builder: (_, _) => const PaymentStylePage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.basicinfoSettlementMethod,
            name: 'basicinfo-settlement-method',
            builder: (_, _) => const SettlementMethodPage(),
          ),

          // —— 统一履约任务工作台（只从后端真实任务与动作单据读取）——
          DraftAwareGoRoute(
            path: RouteName.operationsWarehouseWorkbench,
            name: 'operations-workbench-warehouse',
            builder: (_, _) => const OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.warehouse,
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.operationsPurchaseWorkbench,
            name: 'operations-workbench-purchase',
            builder: (_, _) => OperationsWorkbenchPage(
              department: OperationsWorkbenchDepartment.purchase,
              draftCategoryBuilder:
                  (_, {required search, required externalHeader}) =>
                      PurchaseDraftTaskCategory(
                        search: search,
                        externalHeader: externalHeader,
                      ),
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.operationsSubcontractWorkbench,
            name: 'operations-workbench-subcontract',
            builder: (_, _) => const SubcontractDecompositionPage(),
          ),
          // —— 工程研发部任务中心 ——
          DraftAwareGoRoute(
            path: RouteName.rdTaskCenter,
            name: 'rd-task-center',
            builder: (_, _) => const RdTaskPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.procurementArrivalExceptions,
            name: 'procurement-return-tasks',
            builder: (_, state) => ProcurementReturnTasksPage(
              orderType: procurementInboundOrderTypeFrom(
                state.uri.queryParameters['orderType'],
              ),
            ),
          ),
          DraftAwareGoRoute(
            path: '${RouteName.procurementArrivalExceptions}/:id',
            name: 'procurement-return-task-detail',
            builder: (_, state) => ProcurementReturnTaskDetailPage(
              id: state.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.procurementIqcRejections,
            name: 'procurement-iqc-rejections',
            builder: (_, state) => ProcurementIqcRejectionListPage(
              source: state.uri.queryParameters['from'],
            ),
          ),
          DraftAwareGoRoute(
            path: '${RouteName.procurementIqcRejections}/:id',
            name: 'procurement-iqc-rejection-detail',
            builder: (_, state) => ProcurementIqcRejectionDetailPage(
              id: state.pathParameters['id']!,
              source: state.uri.queryParameters['from'],
            ),
          ),

          // —— 采购管理（hub + 4 单据 list + new/detail/edit）——
          DraftAwareGoRoute(
            path: RouteName.purchase,
            name: 'purchase-hub',
            builder: (_, _) => const PurchaseHubPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.purchaseRequestList,
            name: 'purchase-request-list',
            builder: (_, _) =>
                const PurchaseDocListPage(docType: PurchaseDocType.request),
          ),
          DraftAwareGoRoute(
            path: RouteName.purchaseOrderList,
            name: 'purchase-order-list',
            // ?status=draft：新建页「草稿(N)」按钮深链，直接落在草稿段。
            builder: (_, s) => PurchaseDocListPage(
              docType: PurchaseDocType.order,
              initialStatus: s.uri.queryParameters['status'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.purchaseReceiptList,
            name: 'purchase-receipt-list',
            builder: (_, s) => PurchaseDocListPage(
              docType: PurchaseDocType.receipt,
              initialStatus: s.uri.queryParameters['status'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.purchaseReturnList,
            name: 'purchase-return-list',
            builder: (_, s) => PurchaseDocListPage(
              docType: PurchaseDocType.returnDoc,
              initialStatus: s.uri.queryParameters['status'],
            ),
          ),
          // 采购报表（9 张，参数化）：必须在 /purchase/:doc/:id 之前，literal "report" 段优先。
          DraftAwareGoRoute(
            path: '/purchase/report/:kind',
            name: 'purchase-report-table',
            builder: (_, s) => PurchaseReportTablePage(
              kind: PurchaseReportKind.byName(s.pathParameters['kind']!),
            ),
          ),
          // 采购订货单专属编辑页（2026-09 行级商业条款）：字面量路由优先于 :doc 通配。
          DraftAwareGoRoute(
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
          DraftAwareGoRoute(
            path: '/purchase/orders/:id/edit',
            name: 'purchase-order-edit',
            builder: (_, s) =>
                PurchaseOrderEditPage(id: s.pathParameters['id']),
          ),
          DraftAwareGoRoute(
            path: '/purchase/:doc/new',
            name: 'purchase-doc-new',
            redirect: _rejectUnknownPurchaseDoc,
            builder: (_, s) => PurchaseDocEditPage(
              docType: PurchaseDocType.byPath(s.pathParameters['doc']!),
            ),
          ),
          DraftAwareGoRoute(
            path: '/purchase/:doc/:id/edit',
            name: 'purchase-doc-edit',
            redirect: _rejectUnknownPurchaseDoc,
            builder: (_, s) => PurchaseDocEditPage(
              docType: PurchaseDocType.byPath(s.pathParameters['doc']!),
              id: s.pathParameters['id'],
            ),
          ),
          DraftAwareGoRoute(
            path: '/purchase/:doc/:id',
            name: 'purchase-doc-detail',
            redirect: _rejectUnknownPurchaseDoc,
            builder: (_, s) => PurchaseDocDetailPage(
              docType: PurchaseDocType.byPath(s.pathParameters['doc']!),
              id: s.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: '/purchase/report',
            name: 'purchase-report',
            builder: (_, _) => const PurchaseReportPage(),
          ),

          // —— 库存查询（即时库存为唯一入口；余额/流水并入库存详情页）——
          // 旧「库存余额」页已并入：/stock/balance 重定向到即时库存（余额在库存详情页按货品查看）。
          DraftAwareGoRoute(
            path: RouteName.stockBalance,
            name: 'stock-balance',
            redirect: (_, _) => RouteName.stockInstantInventory,
          ),
          // 旧「出入库流水」页已并入库存详情页：带 goodsId 的旧深链 (即时库存/货品详情/
          // 物料反查) 落到 /stock/item/:goodsId?tab=ledger (出入库流水段)，无 goodsId 时回即时库存。
          DraftAwareGoRoute(
            path: RouteName.stockMovement,
            name: 'stock-movement',
            redirect: (_, state) {
              final goodsId =
                  state.uri.queryParameters['goodsId']?.trim() ?? '';
              return goodsId.isEmpty
                  ? RouteName.stockInstantInventory
                  : RouteName.stockItemDetail(goodsId, tab: 'ledger');
            },
          ),
          DraftAwareGoRoute(
            path: RouteName.stockInstantInventoryOverview,
            name: 'stock-instant-inventory-overview',
            builder: (_, state) => InstantInventoryOverviewPage(
              scope: InstantInventoryScope.fromQuery(state.uri.queryParameters),
              scopeLabel: state.uri.queryParameters['scopeLabel'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.stockInstantInventory,
            name: 'stock-instant-inventory',
            builder: (_, state) => InstantInventoryPage(
              initialScope: state.uri.queryParameters.isEmpty
                  ? null
                  : InstantInventoryScope.fromQuery(state.uri.queryParameters),
            ),
          ),
          // 库存详情：即时库存双击货品行进入 (库存余额 / 出入库流水 / 单重学习三段)；
          // ?tab=balance|ledger|weight 原样交给页面解析 (ADR-135)。
          DraftAwareGoRoute(
            path: '${RouteName.stockItemBase}/:goodsId',
            name: 'stock-item-detail',
            builder: (_, state) => StockItemDetailPage(
              goodsId: state.pathParameters['goodsId']!,
              initialTab: state.uri.queryParameters['tab'],
              initialScope: InstantInventoryScope.fromQuery(
                state.uri.queryParameters,
                inventoryDefault: false,
              ),
              returnTo: state.uri.queryParameters['returnTo'],
            ),
          ),

          // —— 仓库管理（8 单据 hub + 列表 + new/detail/edit + 报表）——
          DraftAwareGoRoute(
            path: RouteName.warehouse,
            name: 'warehouse-hub',
            builder: (_, _) => const WarehouseHubPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseInspections,
            name: 'warehouse-inspections',
            builder: (_, _) => const QualityPendingDisposalPage(),
          ),
          // 多选「批量审批」汇总页（须先于 :receiptType/:receiptId 声明）。
          DraftAwareGoRoute(
            path: '/warehouse/material-discovery/:requestId',
            builder: (_, state) => ProductionMaterialDiscoveryPage(
              requestId: state.pathParameters['requestId']!,
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseInspectionBatchApproval,
            name: 'warehouse-inspection-batch-approval',
            builder: (_, s) => QualityBatchApprovalPage(
              draftId: s.uri.queryParameters['draftId'],
              selection: s.extra is QualityBatchApprovalSelection
                  ? s.extra! as QualityBatchApprovalSelection
                  : const QualityBatchApprovalSelection(),
            ),
          ),
          // FQC 检查单办理页（2026-09-12 弹窗改页，对齐采购 IQC 处置页范式；
          // extra 带列表行检查单快照，深链直达时页面自行拉取）。
          DraftAwareGoRoute(
            path: '${RouteName.productionFqcSheetHandlingBase}/:sheetId',
            name: 'production-fqc-sheet-handling',
            builder: ProductionFqcSheetHandlingPage.route,
          ),
          // FQC 单任务办理页（详情 + 决定 + 检验证据；extra 带任务快照）。
          DraftAwareGoRoute(
            path:
                '${RouteName.productionFqcInspectionHandlingBase}/:inspectionId',
            name: 'production-fqc-inspection-handling',
            builder: ProductionFqcInspectionPage.route,
          ),
          // 单张收货单的待检明细处置页（extra 携带任务卡快照；深链直达时页面自行反查）。
          DraftAwareGoRoute(
            path: '${RouteName.warehouseInspections}/:receiptType/:receiptId',
            name: 'warehouse-inspection-detail',
            builder: (_, s) => ProcurementInspectionDetailPage(
              receiptType: s.pathParameters['receiptType']!,
              receiptId: s.pathParameters['receiptId']!,
              extra: s.extra,
            ),
          ),
          // 旧「IQC 合格待入库」详情深链：合并页详情同参，直接重定向保旧链。
          DraftAwareGoRoute(
            path: '${RouteName.warehouseIqcStockIns}/:receiptType/:receiptId',
            name: 'warehouse-iqc-stock-in-detail',
            redirect: (_, state) => RouteName.warehouseQualityResultDetail(
              state.pathParameters['receiptType'] ?? '',
              state.pathParameters['receiptId'] ?? '',
            ),
          ),
          // 旧「IQC 合格待入库」列表入口：合并进「品质部检查结果」，老链接/收藏重定向。
          DraftAwareGoRoute(
            path: RouteName.warehouseIqcStockIns,
            name: 'warehouse-iqc-stock-ins',
            redirect: (_, _) => RouteName.warehouseQualityResults,
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseQualityResults,
            name: 'warehouse-quality-results',
            // 2026-09-24 并入仓库任务中心合并页（品质检查结果大类）；
            // 详情/批量入库/先入库后检子路由不变。
            builder: (_, _) =>
                const WarehouseTaskCenterPage(initialGroup: 'quality'),
          ),
          // 待入库多选「批量入库」页（2026-09-12 弹窗改页；须先于
          // :receiptType/:receiptId 声明）。
          DraftAwareGoRoute(
            path: RouteName.warehouseQualityBatchStockIn,
            name: 'warehouse-quality-batch-stock-in',
            builder: (_, s) => WarehouseQualityBatchStockInPage(
              targets: s.extra is List<WarehouseQualityResultTask>
                  ? s.extra! as List<WarehouseQualityResultTask>
                  : const [],
            ),
          ),
          // 先入库后质检(V596)：逐行上架页(静态前缀段，须先于 :receiptType/:receiptId)。
          DraftAwareGoRoute(
            path:
                '${RouteName.warehouseQualityPreStockInBase}/:receiptType/:receiptId',
            name: 'warehouse-quality-pre-stock-in',
            builder: (_, state) => WarehouseQualityPreStockInPage(
              receiptType: state.pathParameters['receiptType']!,
              receiptId: state.pathParameters['receiptId']!,
            ),
          ),
          DraftAwareGoRoute(
            path:
                '${RouteName.warehouseQualityResults}/:receiptType/:receiptId',
            name: 'warehouse-quality-result-detail',
            builder: (_, state) => WarehouseQualityResultDetailPage(
              receiptType: state.pathParameters['receiptType']!,
              receiptId: state.pathParameters['receiptId']!,
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.qualityTaskCenter,
            name: 'quality-task-center',
            builder: (_, _) => const QualityTaskCenterPage(),
          ),
          DraftAwareGoRoute(
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
          DraftAwareGoRoute(
            path: RouteName.productionFqcInspections,
            name: 'production-fqc-inspections',
            builder: (_, _) => const ProductionFqcInspectionsPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseInboundExpectations,
            name: 'warehouse-inbound-expectations',
            builder: (_, _) => const WarehouseInboundExpectationsPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseArrivalExceptions,
            name: 'warehouse-arrival-exceptions',
            builder: (_, _) => const WarehouseArrivalExceptionsPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseProductionFinishedInboundTasks,
            name: 'warehouse-production-finished-inbound-tasks',
            builder: (_, _) => const ProductionFinishedInboundTasksPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseProductionDrawBatchIssue,
            name: 'warehouse-production-draw-batch-issue',
            builder: ProductionDrawBatchIssuePage.route,
          ),
          // 待点收多选「批量全量点收入库」页（2026-09-12 弹窗改页）。
          DraftAwareGoRoute(
            path: RouteName.warehouseProductionFinishedBatchStockIn,
            name: 'warehouse-production-finished-batch-stock-in',
            builder: (_, s) => ProductionFinishedBatchStockInPage(
              targets: s.extra is List<ProductionFinishedInboundTask>
                  ? s.extra! as List<ProductionFinishedInboundTask>
                  : const [],
            ),
          ),
          DraftAwareGoRoute(
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
                  // ?preStock=1 = 任务中心「先入库后质检(N)」直达，不带 = 「先质检后入库(N)」
                  // 直达(与采购/委外批量登记页同一口径，页面只显示所选路线的提交按钮)。
                  stockInBeforeInspection:
                      state.uri.queryParameters['preStock'] == '1',
                ),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseProductionFinishedArrivalRegistration,
            name: 'warehouse-production-finished-arrival-registration',
            builder: (_, state) => ProductionFinishedArrivalRegistrationPage(
              reportId: state.pathParameters['reportId'] ?? '',
            ),
          ),
          // 仓库登记实际到货独立页（须在 /warehouse/:code 系列之前；extra 带预填）。
          DraftAwareGoRoute(
            path: RouteName.warehouseArrivalReceiptNew,
            name: 'warehouse-arrival-receipt-new',
            builder: (_, s) => WarehouseArrivalReceiptPage(
              prefill: s.extra is ProcurementReceiptPrefill
                  ? s.extra! as ProcurementReceiptPrefill
                  : null,
            ),
          ),
          // 批量登记实际到货页(入库任务中心多选「先质检后入库」/「先入库后质检」落点；
          // extra 带 List<ProcurementReceiptPrefill>，每张=一张订货单；
          // ?preStock=1 = 列表「先入库后质检(N)」直达，不带 = 「先质检后入库(N)」直达；
          // 2026-09-20 起页面只显示所选路线的提交按钮)。
          DraftAwareGoRoute(
            path: RouteName.warehouseArrivalReceiptBatch,
            name: 'warehouse-arrival-receipt-batch',
            builder: (_, s) => WarehouseArrivalBatchReceiptPage(
              prefills: s.extra is List<ProcurementReceiptPrefill>
                  ? s.extra! as List<ProcurementReceiptPrefill>
                  : null,
              stockInBeforeInspection: s.uri.queryParameters['preStock'] == '1',
            ),
          ),
          // 报表（静态段，需在 /warehouse/:code 之前声明以免被当作 :code 匹配）
          DraftAwareGoRoute(
            path: RouteName.warehouseReport,
            name: 'warehouse-report',
            // 同上：仅精确匹配父路径时才跳明细，summary 子路由不拦。
            redirect: (_, s) => s.uri.path == RouteName.warehouseReport
                ? RouteName.warehouseReportDetail
                : null,
            routes: [
              DraftAwareGoRoute(
                path: 'detail',
                name: 'warehouse-report-detail',
                builder: (_, _) => const WarehouseReportTablePage(
                  kind: WarehouseReportKind.detail,
                ),
              ),
              DraftAwareGoRoute(
                path: 'summary',
                name: 'warehouse-report-summary',
                builder: (_, _) => const WarehouseReportTablePage(
                  kind: WarehouseReportKind.summary,
                ),
              ),
            ],
          ),
          // 货架目视化清单（静态段，须在 /warehouse/:code 系列之前声明）。
          DraftAwareGoRoute(
            path: RouteName.warehouseShelfLabels,
            name: 'warehouse-shelf-labels',
            builder: (_, _) => const ShelfLabelPage(),
          ),
          // 库存分析 + 独立称重计数 (ADR-135；静态段，须在 /warehouse/:code 系列之前)。
          // ?segment=health|cycle-count|weight-alerts|learning 直达分段。
          DraftAwareGoRoute(
            path: RouteName.warehouseInsights,
            name: 'warehouse-insights',
            builder: (_, s) => WarehouseInsightPage(
              initialSegment: s.uri.queryParameters['segment'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseWeighCount,
            name: 'warehouse-weigh-count',
            builder: (_, _) => const WarehouseWeighCountPage(),
          ),
          // 委外出仓任务中心 + 拣货出仓页（V304 仓库专属；静态段，须在 /warehouse/:code 前）。
          DraftAwareGoRoute(
            path: RouteName.warehouseSubcontractOutbound,
            name: 'warehouse-subcontract-outbound',
            builder: (_, _) => const WarehouseSubcontractOutboundPage(),
          ),
          DraftAwareGoRoute(
            path: '/warehouse/sales-outbound/:id',
            name: 'warehouse-sales-outbound-detail',
            builder: (_, state) => WarehouseSalesOutboundDetailPage(
              id: state.pathParameters['id']!,
            ),
          ),
          // 旧「IQC 不合格实物退回」详情深链（按拒收案件 id，无法映射到收货单）：
          // 重定向到合并列表；退回案件的登记入口在合并详情页内。
          DraftAwareGoRoute(
            path: '/warehouse/iqc-returns/:id',
            name: 'warehouse-iqc-return-detail',
            redirect: (_, _) => RouteName.warehouseQualityResults,
          ),
          // 旧「IQC 不合格实物退回」列表入口：合并进「品质部检查结果」，重定向保旧链。
          DraftAwareGoRoute(
            path: RouteName.warehouseIqcReturns,
            name: 'warehouse-iqc-returns',
            redirect: (_, _) => RouteName.warehouseQualityResults,
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseSalesOutbound,
            name: 'warehouse-sales-outbound',
            builder: (_, _) => const WarehouseSalesOutboundPage(),
          ),
          DraftAwareGoRoute(
            path: '/warehouse/subcontract-outbound/:planId',
            name: 'warehouse-subcontract-outbound-edit',
            builder: (_, s) => WarehouseSubcontractOutboundEditPage(
              planId: s.pathParameters['planId']!,
            ),
          ),
          // 仓库实物历史专页：静态 history 段必须先于 /warehouse/:code。
          DraftAwareGoRoute(
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
          DraftAwareGoRoute(
            path: '/warehouse/history/:type',
            name: 'warehouse-document-history-list',
            redirect: _rejectUnknownWarehouseHistoryType,
            builder: (_, state) => WarehouseDocumentHistoryListPage(
              type: WarehouseDocumentHistoryType.tryParse(
                state.pathParameters['type'],
              )!,
            ),
          ),
          // 仓库任务中心（2026-09-24 四卡合并页；静态段 tasks 须先于 /warehouse/:code，
          // 否则会被 :code/:id 单据路由吞掉）。旧三路由与本页等价（预设大类构建），
          // 通知深链/收藏/草稿按钮原样可达；?group= 可直达任一大类。
          DraftAwareGoRoute(
            path: RouteName.warehouseTasks,
            name: 'warehouse-tasks',
            builder: (_, state) => WarehouseTaskCenterPage(
              initialGroup: state.uri.queryParameters['group'],
              initialSection: state.uri.queryParameters['section'],
              initialView: state.uri.queryParameters['view'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseOutboundTasks,
            name: 'warehouse-outbound-tasks',
            builder: (_, state) => WarehouseTaskCenterPage(
              initialGroup: 'outbound',
              initialSection: state.uri.queryParameters['section'],
              initialView: state.uri.queryParameters['view'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseInboundTasks,
            name: 'warehouse-inbound-tasks',
            builder: (_, _) =>
                const WarehouseTaskCenterPage(initialGroup: 'inbound'),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseDrawTasks,
            name: 'warehouse-draw-tasks',
            builder: (_, _) =>
                const WarehouseTaskCenterPage(initialGroup: 'draw'),
          ),
          // 车间内料仓设置 (ADR-131; 静态段须先于 /warehouse/:code/:id, 否则被单据详情吞掉)。
          // ?tab=enable|machines|prep 直达页签。
          DraftAwareGoRoute(
            path: RouteName.workshopMaterialSetup,
            name: 'workshop-material-setup',
            builder: (_, s) => WorkshopMaterialSetupPage(
              initialTab: s.uri.queryParameters['tab'],
              initialWorkshopId: s.uri.queryParameters['workshopId'],
            ),
          ),

          // 新建盘点单可带 extra = StockCheckPrefill (库存分析「生成盘点单」按仓预填货品，
          // 只是未保存的明细行，ADR-135)；其它单据类型不认 extra。
          DraftAwareGoRoute(
            path: '/warehouse/:code/new',
            name: 'stock-doc-new',
            redirect: _rejectStockDocManualEdit,
            builder: (_, s) => StockDocEditPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
              checkPrefill: s.extra is StockCheckPrefill
                  ? s.extra! as StockCheckPrefill
                  : null,
            ),
          ),
          DraftAwareGoRoute(
            path: '/warehouse/:code/:id/edit',
            name: 'stock-doc-edit',
            redirect: _rejectStockDocManualEdit,
            builder: (_, s) => StockDocEditPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
              id: s.pathParameters['id'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.warehouseStockCountReview,
            name: 'warehouse-stock-count-review',
            builder: (_, s) => StockCountReviewPage(
              reviewRoute: 'WAREHOUSE',
              requestId: s.uri.queryParameters['requestId'],
            ),
          ),
          DraftAwareGoRoute(
            path: '/warehouse/:code/:id',
            name: 'stock-doc-detail',
            redirect: _rejectUnknownStockDoc,
            builder: (_, s) => StockDocDetailPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
              id: s.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: '/warehouse/:code',
            name: 'stock-doc-list',
            redirect: _rejectUnknownStockDoc,
            // ?status=draft：新建页「草稿(N)」按钮深链，直接落在草稿段。
            builder: (_, s) => StockDocListPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
              initialStatus: s.uri.queryParameters['status'],
            ),
          ),

          DraftAwareGoRoute(
            path: RouteName.stockCountRequests,
            name: 'stock-count-requests',
            builder: (_, s) => StockCountReviewPage(
              requestId: s.uri.queryParameters['requestId'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeStockCountReview,
            name: 'finance-stock-count-review',
            builder: (_, s) => StockCountReviewPage(
              reviewRoute: 'FINANCE',
              requestId: s.uri.queryParameters['requestId'],
            ),
          ),
          // —— 车间内料仓 (ADR-131) ——
          DraftAwareGoRoute(
            path: RouteName.workshopMaterialBin,
            name: 'workshop-material-bin',
            builder: (_, s) => WorkshopMaterialBinPage(
              workshopId: s.uri.queryParameters['workshopId'],
            ),
          ),
          // 带 ?requisitionId= 为按申请发料 / 收退回; 不带 (或 ?mode=direct) 为直接发料。
          DraftAwareGoRoute(
            path: RouteName.workshopMaterialIssue,
            name: 'workshop-material-issue',
            builder: (_, s) => WorkshopMaterialIssuePage(
              requisitionId: s.uri.queryParameters['requisitionId'],
              mode: s.uri.queryParameters['mode'],
            ),
          ),
          // 盘点页只认 ?periodId=; 缺参数时回到车间内料仓页选期间。
          DraftAwareGoRoute(
            path: RouteName.workshopMaterialCount,
            name: 'workshop-material-count',
            redirect: (_, s) =>
                (s.uri.queryParameters['periodId']?.trim().isNotEmpty ?? false)
                ? null
                : RouteName.workshopMaterialBin,
            builder: (_, s) => WorkshopMaterialCountPage(
              periodId: s.uri.queryParameters['periodId']!.trim(),
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.workshopMaterialReports,
            name: 'workshop-material-reports',
            builder: (_, s) => WorkshopMaterialReportsPage(
              initialBinId: s.uri.queryParameters['binId'],
              initialPeriodId: s.uri.queryParameters['periodId'],
            ),
          ),

          // —— 销售管理（综合营销部；静态段 /sales/report 在 :seg 参数路由前）——
          DraftAwareGoRoute(
            path: RouteName.sales,
            name: 'sales-hub',
            builder: (_, _) => const SalesHubPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.salesReport,
            name: 'sales-report',
            // 仅精确匹配 /sales/report 时跳明细；子路由（detail/summary）不拦——
            // go_router 父路由 redirect 对子路由同样生效，无条件跳会把 summary 也拐到 detail。
            redirect: (_, s) => s.uri.path == RouteName.salesReport
                ? RouteName.salesReportDetail
                : null,
            routes: [
              DraftAwareGoRoute(
                path: 'detail',
                name: 'sales-report-detail',
                builder: (_, _) =>
                    const SalesReportPage(kind: SalesReportKind.detail),
              ),
              DraftAwareGoRoute(
                path: 'summary',
                name: 'sales-report-summary',
                builder: (_, _) =>
                    const SalesReportPage(kind: SalesReportKind.summary),
              ),
            ],
          ),
          DraftAwareGoRoute(
            path: RouteName.salesScarcity,
            name: 'sales-scarcity',
            builder: (_, s) => SalesScarcityPage(
              initialGoodsId: s.uri.queryParameters['goodsId'],
              initialColorId: s.uri.queryParameters['colorId'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.salesOrderProgress,
            name: 'sales-order-progress',
            builder: (_, _) => const SalesOrderProgressPage(),
          ),
          DraftAwareGoRoute(
            path: '${RouteName.salesOrderProgress}/:orderId',
            name: 'sales-order-progress-detail',
            builder: (_, s) => SalesOrderProgressDetailPage(
              orderId: s.pathParameters['orderId']!,
            ),
          ),
          // 销售任务中心（2026-09-24 三段式：一站式查看；静态段 tasks 须先于
          // /sales/:seg 参数路由声明，否则会被 :seg 列表路由吞掉）。
          DraftAwareGoRoute(
            path: RouteName.salesTasks,
            name: 'sales-tasks',
            builder: (_, s) => SalesTaskCenterPage(
              initialGroup: s.uri.queryParameters['group'],
            ),
          ),
          DraftAwareGoRoute(
            path: '/sales/:seg/new',
            name: 'sales-doc-new',
            redirect: _rejectUnknownSalesDoc,
            builder: (_, s) => SalesDocEditPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
              initialOrderId: s.uri.queryParameters['sourceOrderId'],
              initialOrderItems: s.uri.queryParameters['orderItems'],
              // 订货单识别结果「改为新建报价单」: 同一次识别直接在报价页恢复(ADR-134),
              // 原文件经 extra 带过来(只在同一次跳转里有)。
              initialAiJobId: s.uri.queryParameters['aiJobId'],
              initialGuidedPlan: s.extra is AiGuidedFilePlan
                  ? s.extra as AiGuidedFilePlan
                  : null,
              initialAiFile: s.extra is PlatformFile
                  ? s.extra as PlatformFile
                  : null,
            ),
          ),
          DraftAwareGoRoute(
            path: '/sales/:seg/:id/edit',
            name: 'sales-doc-edit',
            redirect: _rejectUnknownSalesDoc,
            builder: (_, s) => SalesDocEditPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id'],
            ),
          ),
          DraftAwareGoRoute(
            path: '/sales/:seg/:id',
            name: 'sales-doc-detail',
            redirect: _rejectUnknownSalesDoc,
            builder: (_, s) => SalesDocDetailPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id']!,
              historyRead:
                  s.pathParameters['seg'] == 'quotes' &&
                  s.uri.queryParameters['history'] == '1',
            ),
          ),
          DraftAwareGoRoute(
            path: '/sales/:seg',
            name: 'sales-doc-list',
            redirect: _rejectUnknownSalesDoc,
            // ?status=draft：新建页「草稿(N)」按钮深链，直接落在草稿段。
            builder: (_, s) => SalesDocListPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
              initialStatus: s.uri.queryParameters['status'],
            ),
          ),

          // —— 委外管理（综合营销部；静态段 /subcontract/report 在 :seg 参数路由前）——
          DraftAwareGoRoute(
            path: RouteName.subcontract,
            name: 'subcontract-hub',
            builder: (_, _) => const SubcontractHubPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.subcontractReport,
            name: 'subcontract-report',
            builder: (_, _) => const SubcontractHubPage(),
          ),
          // ADR-098 委外回厂短交判定（静态段，须在 /subcontract/:seg 参数路由之前）。
          DraftAwareGoRoute(
            path: RouteName.subcontractShortDeliveries,
            name: 'subcontract-short-deliveries',
            builder: (_, s) => SubcontractShortDeliveryPage(
              initialCaseId: s.uri.queryParameters['caseId'],
              initialOrderId: s.uri.queryParameters['orderId'],
              initialSupplierId: s.uri.queryParameters['supplierId'],
            ),
          ),
          // 委外准备中心已退役（2026-09-05 后端 API 下线）：旧深链一律重定向到
          // 委外管理 hub，避免收藏/通知里的 /subcontract/preparations 404。
          DraftAwareGoRoute(
            path: RouteName.subcontractPreparations,
            name: 'subcontract-preparations',
            redirect: (_, _) => RouteName.subcontract,
          ),
          // 2026-09-06 收口：计划委外申请列表并入「委外任务中心」（含待生产
          // 合成行与进度弹窗）；只读申请详情深链保留（/:id 路由在下）。
          DraftAwareGoRoute(
            path: '/subcontract/applications',
            name: 'subcontract-applications-list',
            redirect: (_, _) => RouteName.operationsSubcontractWorkbench,
          ),
          // 2026-09-06 委外回厂跟踪页退役：回厂/IQC 进度在任务中心双击弹窗与
          // 订货单详情全链路查看；既有回厂单详情/草稿编辑深链保留。
          DraftAwareGoRoute(
            path: '/subcontract/receipts',
            name: 'subcontract-receipts-list',
            redirect: (_, _) => '/subcontract/orders',
          ),
          // 委外报表（3 卡：明细/汇总/出入状况，静态段 report 优先于 :seg 参数路由）
          DraftAwareGoRoute(
            path: '/subcontract/report/:kind',
            name: 'subcontract-report-table',
            builder: (_, s) => SubcontractReportTablePage(
              kind: SubcontractReportKind.byRouteSegment(
                s.pathParameters['kind']!,
              ),
            ),
          ),
          DraftAwareGoRoute(
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
          DraftAwareGoRoute(
            path: '/subcontract/:seg/:id/edit',
            name: 'subcontract-doc-edit',
            redirect: _rejectUnknownSubcontractDoc,
            builder: (_, s) => SubcontractPageFactory.editor(
              type: SubcontractDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id'],
            ),
          ),
          DraftAwareGoRoute(
            path: '/subcontract/:seg/:id',
            name: 'subcontract-doc-detail',
            redirect: _rejectUnknownSubcontractDoc,
            builder: (_, s) => SubcontractPageFactory.detail(
              SubcontractDocType.byPath(s.pathParameters['seg']!),
              s.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: '/subcontract/:seg',
            name: 'subcontract-doc-list',
            redirect: _rejectUnknownSubcontractDoc,
            // ?status=draft：新建页「草稿(N)」按钮深链，直接落在草稿段。
            builder: (_, s) => SubcontractPageFactory.list(
              SubcontractDocType.byPath(s.pathParameters['seg']!),
              initialStatus: s.uri.queryParameters['status'],
            ),
          ),

          // —— 生产管理（模块公开路由清单；静态段在 :id 参数路由前）——
          ...productionRoutes,

          // —— 钱流管理（财税部；静态段 /finance/{report|ar-ap|reconciliations|checks|
          //    customers|suppliers|accounts} 必须在 :seg 参数路由前声明）——
          DraftAwareGoRoute(
            path: RouteName.finance,
            name: 'finance-hub',
            builder: (_, _) => const FinanceHubPage(),
          ),
          // 业务审核中心：六个审核队列的分段工作台（?segment= 深链直落某队列；
          // 静态段，须先于 /finance/:seg 单据参数路由声明）。
          DraftAwareGoRoute(
            path: RouteName.financeAudits,
            name: 'finance-audit-center',
            builder: (_, state) => FinanceAuditCenterPage(
              initialSegment: state.uri.queryParameters['segment'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.financePayables,
            name: 'finance-payables',
            builder: (_, _) => const FinancePayablesPage(),
          ),
          DraftAwareGoRoute(
            path: '/finance/procurement-approvals',
            name: 'finance-procurement-approvals',
            builder: (_, _) => const FinanceProcurementApprovalTasksPage(),
          ),
          DraftAwareGoRoute(
            path: '/finance/procurement-approvals/:caseId',
            name: 'finance-procurement-approval-review',
            builder: (_, state) => FinanceProcurementApprovalReviewPage(
              caseId: state.pathParameters['caseId']!,
            ),
          ),
          DraftAwareGoRoute(
            path: '/finance/sales-order-confirmations',
            name: 'finance-sales-order-confirmations',
            builder: (_, _) => const FinanceSalesOrderConfirmationPage(),
          ),
          DraftAwareGoRoute(
            path: '/finance/sales-order-changes',
            name: 'finance-sales-order-changes',
            builder: (_, _) =>
                const FinanceSalesOrderConfirmationPage(changesOnly: true),
          ),
          DraftAwareGoRoute(
            path: '/finance/sales-order-confirmations/:id',
            name: 'finance-sales-order-review',
            builder: (_, state) => FinanceSalesOrderReviewPage(
              id: state.pathParameters['id']!,
              returnTo: state.uri.queryParameters['returnTo'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeSalesShipmentAudit,
            name: 'finance-sales-shipment-audit',
            builder: (_, _) => const FinanceSalesShipmentAuditPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeSalesShipmentAuditReview,
            name: 'finance-sales-shipment-audit-review',
            builder: (_, state) => FinanceSalesShipmentAuditReviewPage(
              id: state.pathParameters['id']!,
            ),
          ),
          // 销售报价财务核价(ADR-134)：队列(?state= 深链分段) + 核价详情。
          DraftAwareGoRoute(
            path: RouteName.financeQuoteReview,
            name: 'finance-quote-review',
            builder: (_, state) => FinanceQuoteReviewListPage(
              initialState: state.uri.queryParameters['state'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeQuoteReviewDetail,
            name: 'finance-quote-review-detail',
            builder: (_, state) =>
                FinanceQuoteReviewPage(id: state.pathParameters['id']!),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeArrivalExceptions,
            name: 'finance-arrival-exceptions',
            builder: (_, _) => const FinanceArrivalExceptionTasksPage(),
          ),
          DraftAwareGoRoute(
            path: '${RouteName.financeArrivalExceptions}/:id',
            name: 'finance-arrival-exception-detail',
            builder: (_, state) => FinanceArrivalExceptionDetailPage(
              id: state.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReport,
            name: 'finance-report',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'detail'),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReportDetail,
            name: 'finance-report-detail',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'detail'),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReportSummary,
            name: 'finance-report-summary',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'summary'),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReportOverview,
            name: 'finance-report-overview',
            builder: (_, _) => const FinanceArApOverviewPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReportStatement,
            name: 'finance-report-statement',
            builder: (_, _) => const FinanceStatementPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReportAccountFlow,
            name: 'finance-report-account-flow',
            builder: (_, _) => const FinanceAccountFlowPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReportCustomerPrepayment,
            name: 'finance-report-customer-prepayment',
            builder: (_, _) =>
                const FinanceReportTablePage(cardId: 'customer-prepayment'),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReportRecon,
            name: 'finance-report-recon',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'recon'),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReportCost,
            name: 'finance-report-cost',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'cost'),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReportGl,
            name: 'finance-report-gl',
            builder: (_, _) => const FinanceReportTablePage(cardId: 'gl'),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeArAp,
            name: 'finance-ar-ap',
            builder: (_, _) => const FinanceArApPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeReconciliations,
            name: 'finance-reconciliations',
            builder: (_, _) => const FinanceReconciliationPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeChecks,
            name: 'finance-checks',
            builder: (_, _) =>
                const AccountPage(initialAccountTypeFilter: 'CHECK'),
          ),
          DraftAwareGoRoute(
            path: RouteName.financeAssets,
            name: 'finance-assets',
            builder: (_, _) => const FinanceAssetsPage(),
          ),
          DraftAwareGoRoute(
            path: '/finance/assets/new',
            redirect: (_, state) {
              final ledger = state.uri.queryParameters['ledger'];
              return ledger == null ||
                      FinanceAssetLedger.values.any(
                        (item) => item.name == ledger,
                      )
                  ? null
                  : RouteName.notFound;
            },
            builder: (_, state) => FinanceAssetFormSurface(
              ledger: FinanceAssetLedger.values.byName(
                state.uri.queryParameters['ledger'] ?? 'fixedAsset',
              ),
              inPanel: false,
            ),
          ),
          DraftAwareGoRoute(
            path: '/finance/:seg/new',
            // Concrete asset editor routes are registered before this family.
            name: 'finance-doc-new',
            redirect: _rejectUnknownFinanceDoc,
            builder: (_, s) => FinanceDocEditPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
            ),
          ),
          DraftAwareGoRoute(
            path: '/finance/:seg/:id/edit',
            name: 'finance-doc-edit',
            redirect: _rejectUnknownFinanceDoc,
            builder: (_, s) => FinanceDocEditPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id'],
            ),
          ),
          DraftAwareGoRoute(
            path: '/finance/:seg/:id',
            name: 'finance-doc-detail',
            redirect: _rejectUnknownFinanceDoc,
            builder: (_, s) => FinanceDocDetailPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: '/finance/:seg',
            name: 'finance-doc-list',
            redirect: _rejectUnknownFinanceDoc,
            // ?status=draft：新建页「草稿(N)」按钮深链，直接落在草稿段。
            builder: (_, s) => FinanceDocListPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
              initialStatus: s.uri.queryParameters['status'],
            ),
          ),

          // —— 访客审批 / 被访人 / 保安扫码 ——
          DraftAwareGoRoute(
            path: RouteName.visitorApproval,
            name: 'visitor-approval-list',
            builder: (_, _) => const VisitorApprovalListPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.visitorApprovalDetail,
            name: 'visitor-approval-detail',
            builder: (_, s) => VisitorApprovalDetailPage(
              applicationId: s.pathParameters['id']!,
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.myVisitors,
            name: 'my-visitors',
            builder: (_, _) => const MyVisitorsPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.securityScan,
            name: 'security-scan',
            builder: (_, _) => const SecurityScanPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.securityBlacklist,
            name: 'security-blacklist',
            builder: (_, _) => const SecurityBlacklistPage(),
          ),

          // —— 个人信息自助修改（员工侧）——
          DraftAwareGoRoute(
            path: RouteName.profileEdit,
            name: 'profile-edit',
            // ?field=xxx：从「我的」页字段铅笔进入，编辑页定位聚焦该字段。
            builder: (_, s) =>
                ProfileEditPage(initialField: s.uri.queryParameters['field']),
          ),
          // 独立草稿页(登录即可：本人表单草稿，无业务权限概念；2026-09-27
          // 基础资料/建议箱/HR/品质任务中心顶栏「草稿」按钮的落点)。
          DraftAwareGoRoute(
            path: RouteName.formDrafts,
            name: 'form-drafts',
            builder: (_, s) =>
                FormDraftsPage(categoryId: s.pathParameters['categoryId']!),
          ),
          DraftAwareGoRoute(
            path: RouteName.profileMyChanges,
            name: 'profile-my-changes',
            builder: (_, _) => const MyProfileChangesPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.profileMyDepartment,
            name: 'profile-my-department',
            builder: (_, _) => const MyDepartmentPage(),
          ),
          // 我的车辆与号码(/profile/me/vehicles)、我的文件(/profile/me/documents)
          // 独立页已吸收为「我的」页 Tab（我的页 v7），路由下线。

          // —— HR 端：工作台（今日概览 + 转正/生日/周年/新入职子页，ADR-021） ——
          DraftAwareGoRoute(
            path: RouteName.hrTaskCenter,
            name: 'hr-task-center',
            builder: (_, _) => const HrWorkbenchPage(),
            routes: [
              DraftAwareGoRoute(
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
          DraftAwareGoRoute(
            path: RouteName.hrProfileChanges,
            name: 'hr-profile-changes',
            builder: (_, _) => const HrProfileChangesListPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.hrProfileChangeDetail,
            name: 'hr-profile-change-detail',
            builder: (_, s) =>
                HrProfileChangeDetailPage(batchId: s.pathParameters['id']!),
          ),

          // —— 业务页面内权限设置（超管 / 部门负责人）——
          DraftAwareGoRoute(
            path: RouteName.pagePermissions,
            name: 'page-permissions',
            builder: (_, state) => PagePermissionSettingsPage(
              surfaceKey: state.pathParameters['surfaceKey'] ?? '',
            ),
          ),

          // —— 系统管理（超管）——
          DraftAwareGoRoute(
            path: RouteName.adminPermissions,
            name: 'admin-permissions',
            builder: (_, state) => AdminPermissionsPage(
              initialEmployeeId: state.uri.queryParameters['employeeId'],
              initialDepartmentId: state.uri.queryParameters['departmentId'],
            ),
          ),
          DraftAwareGoRoute(
            path: RouteName.adminAuditLogs,
            name: 'admin-audit-logs',
            builder: (_, state) => AdminAuditLogPage(
              initialRequestId: state.uri.queryParameters['requestId'],
            ),
          ),
          DraftAwareGoRoute(
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
          DraftAwareGoRoute(
            path: RouteName.adminSystemSettings,
            name: 'admin-system-settings',
            builder: (_, _) => const AdminSystemSettingsPage(),
          ),
          DraftAwareGoRoute(
            path: RouteName.adminServerStatus,
            name: 'admin-server-status',
            builder: (_, _) => const ServerStatusPage(),
          ),
          // AI 服务设置(ADR-133): 不是表单草稿页, 密钥绝不进草稿快照。
          DraftAwareGoRoute(
            path: RouteName.adminAiSettings,
            name: 'admin-ai-settings',
            builder: (_, _) => const AdminAiSettingsPage(),
          ),
        ],
      ),
    ],
    errorBuilder: (_, _) => const _ErrorPage(),
  );

  // 「返回即刷新」信号源：任何导航落定(go / push / replace / pop / 系统返回
  // 手势 / 深链)后，把最新路径写入 pageResumeProvider；页面据此在自己重新可见
  // 时刷新数据。接线本体在 page_resume_provider.attachPageResume(与页面导航
  // 测试共用同一份，测试复现的就是线上触发链)。
  final detachPageResume = attachPageResume(
    router,
    ref.read(pageResumeProvider.notifier),
  );

  ref.listen(sessionProvider, (_, _) {
    router.refresh();
  });
  ref.listen(visitorSessionProvider, (_, _) {
    router.refresh();
  });

  ref.onDispose(() {
    detachPageResume();
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
