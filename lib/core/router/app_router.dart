// 路由配置
// 文档：docs/05-架构/路由设计.md · 全局机制权限见 docs/05-架构/全局机制.md
// 使用 go_router，扁平路由（静态段声明在 :id 之前避免冲突）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/pages/admin_audit_log_page.dart';
import '../../features/admin/pages/admin_system_settings_page.dart';
import '../../features/admin/pages/admin_permissions_page.dart';
import '../../features/auth/pages/login_page.dart';
import '../../features/basic_data/pages/basic_data_hub_page.dart';
import '../../features/basic_data/pages/client_category_page.dart';
import '../../features/basic_data/pages/color_page.dart';
import '../../features/basic_data/pages/account_page.dart';
import '../../features/basic_data/pages/currency_page.dart';
import '../../features/basic_data/pages/mould_category_page.dart';
import '../../features/basic_data/pages/payment_style_page.dart';
import '../../features/basic_data/pages/product_category_page.dart';
import '../../features/basic_data/pages/supplier_category_page.dart';
import '../../features/basic_data/pages/unit_page.dart';
import '../../features/basic_data/pages/warehouse_page.dart';
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
import '../../features/finance/models/finance_doc.dart';
import '../../features/finance/pages/finance_ar_ap_page.dart';
import '../../features/finance/pages/finance_assets_page.dart';
import '../../features/finance/pages/finance_doc_detail_page.dart';
import '../../features/finance/pages/finance_doc_edit_page.dart';
import '../../features/finance/pages/finance_doc_list_page.dart';
import '../../features/finance/pages/finance_hub_page.dart';
import '../../features/finance/pages/finance_reconciliation_page.dart';
import '../../features/finance/pages/finance_report_table_page.dart';
import '../../features/finance/pages/finance_ar_ap_overview_page.dart';
import '../../features/finance/pages/finance_statement_page.dart';
import '../../features/finance/pages/finance_account_flow_page.dart';
import '../../features/hr_profile/pages/hr_profile_change_detail_page.dart';
import '../../features/hr_profile/pages/hr_profile_changes_list_page.dart';
import '../../features/hvac/pages/hvac_control_page.dart';
import '../../features/hvac/pages/hvac_overview_page.dart';
import '../../features/lab/pages/lab_test_list_page.dart';
import '../../features/lab/pages/lab_test_report_page.dart';
import '../../features/lab/pages/lab_test_upload_page.dart';
import '../../features/notice/pages/notice_detail_page.dart';
import '../../features/purchase/pages/purchase_doc_detail_page.dart';
import '../../features/purchase/pages/purchase_doc_edit_page.dart';
import '../../features/purchase/pages/purchase_doc_list_page.dart';
import '../../features/purchase/pages/purchase_hub_page.dart';
import '../../features/purchase/pages/purchase_report_page.dart';
import '../../features/purchase/pages/purchase_report_table_page.dart';
import '../../features/purchase/config/purchase_report_config.dart';
import '../../features/purchase/models/purchase_doc.dart';
import '../../features/stock/pages/instant_inventory_page.dart';
import '../../features/stock/pages/stock_balance_page.dart';
import '../../features/stock/pages/stock_movement_page.dart';
import '../../features/warehouse/models/stock_doc.dart';
import '../../features/warehouse/pages/stock_doc_detail_page.dart';
import '../../features/warehouse/pages/stock_doc_edit_page.dart';
import '../../features/warehouse/pages/stock_doc_list_page.dart';
import '../../features/warehouse/config/warehouse_report_config.dart';
import '../../features/warehouse/pages/warehouse_hub_page.dart';
import '../../features/warehouse/pages/warehouse_report_table_page.dart';
import '../../features/notice/pages/notice_list_page.dart';
import '../../features/notice/pages/notice_publish_page.dart';
import '../../features/payroll/pages/payroll_generate_page.dart';
import '../../features/payroll/pages/payroll_review_page.dart';
import '../../features/payroll/pages/payroll_slip_detail_page.dart';
import '../../features/payroll/pages/payroll_slip_list_page.dart';
import '../../features/placeholder/pages/feature_placeholder_page.dart';
import '../../features/production/config/production_report_config.dart';
import '../../features/production/pages/production_daily_report_detail_page.dart';
import '../../features/production/pages/production_daily_report_edit_page.dart';
import '../../features/production/pages/production_daily_report_list_page.dart';
import '../../features/production/pages/production_hub_page.dart';
import '../../features/production/pages/production_plan_detail_page.dart';
import '../../features/production/pages/production_plan_edit_page.dart';
import '../../features/production/pages/production_plan_list_page.dart';
import '../../features/production/pages/production_report_page.dart';
import '../../features/production/pages/production_board_page.dart';
import '../../features/production/pages/where_used_report_page.dart';
import '../../features/profile/pages/my_profile_changes_page.dart';
import '../../features/profile/pages/profile_edit_page.dart';
import '../../features/profile/pages/profile_page.dart';
import '../../features/settings/pages/settings_page.dart';
import '../../features/shell/pages/main_shell_page.dart';
import '../../features/suggestion/pages/suggestion_detail_page.dart';
import '../../features/suggestion/pages/suggestion_list_page.dart';
import '../../features/suggestion/pages/suggestion_new_page.dart';
import '../../features/sales/models/sales_doc.dart';
import '../../features/sales/pages/sales_doc_detail_page.dart';
import '../../features/sales/pages/sales_doc_edit_page.dart';
import '../../features/sales/pages/sales_doc_list_page.dart';
import '../../features/sales/pages/sales_hub_page.dart';
import '../../features/sales/config/sales_report_config.dart';
import '../../features/sales/pages/sales_report_page.dart';
import '../../features/subcontract/models/subcontract_doc.dart';
import '../../features/subcontract/pages/subcontract_doc_detail_page.dart';
import '../../features/subcontract/pages/subcontract_doc_edit_page.dart';
import '../../features/subcontract/pages/subcontract_doc_list_page.dart';
import '../../features/subcontract/pages/subcontract_hub_page.dart';
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
        if (session.status == AuthStatus.authenticated) {
          return RouteName.dashboard;
        }
        if (vSession.isLoggedIn) return null;
        return loc == RouteName.visitorLogin ? null : RouteName.visitorLogin;
      }

      // 3) 入口选择页：两端都未登录才显示
      if (isEntry) {
        if (session.status == AuthStatus.authenticated) {
          return RouteName.dashboard;
        }
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

          // —— 财税部新模块（占位页：权限已可配置，功能规划接入中）——
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
            path: RouteName.basicinfoPaymentStyle,
            name: 'basicinfo-payment-style',
            builder: (_, _) => const PaymentStylePage(),
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
            builder: (_, _) => const PurchaseDocListPage(docType: PurchaseDocType.request),
          ),
          GoRoute(
            path: RouteName.purchaseOrderList,
            name: 'purchase-order-list',
            builder: (_, _) => const PurchaseDocListPage(docType: PurchaseDocType.order),
          ),
          GoRoute(
            path: RouteName.purchaseReceiptList,
            name: 'purchase-receipt-list',
            builder: (_, _) => const PurchaseDocListPage(docType: PurchaseDocType.receipt),
          ),
          GoRoute(
            path: RouteName.purchaseReturnList,
            name: 'purchase-return-list',
            builder: (_, _) => const PurchaseDocListPage(docType: PurchaseDocType.returnDoc),
          ),
          // 采购报表（9 张，参数化）：必须在 /purchase/:doc/:id 之前，literal "report" 段优先。
          GoRoute(
            path: '/purchase/report/:kind',
            name: 'purchase-report-table',
            builder: (_, s) => PurchaseReportTablePage(kind: PurchaseReportKind.byName(s.pathParameters['kind']!)),
          ),
          GoRoute(
            path: '/purchase/:doc/new',
            name: 'purchase-doc-new',
            builder: (_, s) => PurchaseDocEditPage(docType: PurchaseDocType.byPath(s.pathParameters['doc']!)),
          ),
          GoRoute(
            path: '/purchase/:doc/:id/edit',
            name: 'purchase-doc-edit',
            builder: (_, s) => PurchaseDocEditPage(
              docType: PurchaseDocType.byPath(s.pathParameters['doc']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/purchase/:doc/:id',
            name: 'purchase-doc-detail',
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

          // —— 库存查询（余额 + 流水）——
          GoRoute(
            path: RouteName.stockBalance,
            name: 'stock-balance',
            builder: (_, _) => const StockBalancePage(),
          ),
          GoRoute(
            path: RouteName.stockMovement,
            name: 'stock-movement',
            // goodsId / warehouseId 查询参数：即时库存/余额/货品详情行点击带入过滤
            builder: (_, state) => StockMovementPage(
                goodsId: state.uri.queryParameters['goodsId'],
                warehouseId: state.uri.queryParameters['warehouseId']),
          ),
          GoRoute(
            path: RouteName.stockInstantInventory,
            name: 'stock-instant-inventory',
            builder: (_, _) => const InstantInventoryPage(),
          ),

          // —— 仓库管理（8 单据 hub + 列表 + new/detail/edit + 报表）——
          GoRoute(
            path: RouteName.warehouse,
            name: 'warehouse-hub',
            builder: (_, _) => const WarehouseHubPage(),
          ),
          // 报表（静态段，需在 /warehouse/:code 之前声明以免被当作 :code 匹配）
          GoRoute(
            path: RouteName.warehouseReport,
            name: 'warehouse-report',
            redirect: (_, _) => RouteName.warehouseReportDetail,
            routes: [
              GoRoute(
                path: 'detail',
                name: 'warehouse-report-detail',
                builder: (_, _) => const WarehouseReportTablePage(
                    kind: WarehouseReportKind.detail),
              ),
              GoRoute(
                path: 'summary',
                name: 'warehouse-report-summary',
                builder: (_, _) => const WarehouseReportTablePage(
                    kind: WarehouseReportKind.summary),
              ),
            ],
          ),
          GoRoute(
            path: '/warehouse/:code/new',
            name: 'stock-doc-new',
            builder: (_, s) => StockDocEditPage(docType: StockDocType.byCode(s.pathParameters['code']!)),
          ),
          GoRoute(
            path: '/warehouse/:code/:id/edit',
            name: 'stock-doc-edit',
            builder: (_, s) => StockDocEditPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/warehouse/:code/:id',
            name: 'stock-doc-detail',
            builder: (_, s) => StockDocDetailPage(
              docType: StockDocType.byCode(s.pathParameters['code']!),
              id: s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/warehouse/:code',
            name: 'stock-doc-list',
            builder: (_, s) => StockDocListPage(docType: StockDocType.byCode(s.pathParameters['code']!)),
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

          // —— 销售管理（综合营销部；静态段 /sales/report 在 :seg 参数路由前）——
          GoRoute(
            path: RouteName.sales,
            name: 'sales-hub',
            builder: (_, _) => const SalesHubPage(),
          ),
          GoRoute(
            path: RouteName.salesReport,
            name: 'sales-report',
            redirect: (_, _) => RouteName.salesReportDetail,
            routes: [
              GoRoute(
                path: 'detail',
                name: 'sales-report-detail',
                builder: (_, _) => const SalesReportPage(kind: SalesReportKind.detail),
              ),
              GoRoute(
                path: 'summary',
                name: 'sales-report-summary',
                builder: (_, _) => const SalesReportPage(kind: SalesReportKind.summary),
              ),
            ],
          ),
          GoRoute(
            path: '/sales/:seg/new',
            name: 'sales-doc-new',
            builder: (_, s) => SalesDocEditPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
            ),
          ),
          GoRoute(
            path: '/sales/:seg/:id/edit',
            name: 'sales-doc-edit',
            builder: (_, s) => SalesDocEditPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/sales/:seg/:id',
            name: 'sales-doc-detail',
            builder: (_, s) => SalesDocDetailPage(
              docType: SalesDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/sales/:seg',
            name: 'sales-doc-list',
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
          // 委外报表（3 卡：明细/汇总/出入状况，静态段 report 优先于 :seg 参数路由）
          GoRoute(
            path: '/subcontract/report/:kind',
            name: 'subcontract-report-table',
            builder: (_, s) => SubcontractReportTablePage(
                kind: SubcontractReportKind.byRouteSegment(s.pathParameters['kind']!)),
          ),
          GoRoute(
            path: '/subcontract/:seg/new',
            name: 'subcontract-doc-new',
            builder: (_, s) => SubcontractDocEditPage(
              docType: SubcontractDocType.byPath(s.pathParameters['seg']!),
            ),
          ),
          GoRoute(
            path: '/subcontract/:seg/:id/edit',
            name: 'subcontract-doc-edit',
            builder: (_, s) => SubcontractDocEditPage(
              docType: SubcontractDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/subcontract/:seg/:id',
            name: 'subcontract-doc-detail',
            builder: (_, s) => SubcontractDocDetailPage(
              docType: SubcontractDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/subcontract/:seg',
            name: 'subcontract-doc-list',
            builder: (_, s) => SubcontractDocListPage(
              docType: SubcontractDocType.byPath(s.pathParameters['seg']!),
            ),
          ),

          // —— 生产管理（生产部；静态段在 :id 参数路由前）——
          GoRoute(
            path: RouteName.production,
            name: 'production-hub',
            builder: (_, _) => const ProductionHubPage(),
          ),
          GoRoute(
            path: RouteName.productionSchedule,
            name: 'production-schedule',
            builder: (_, _) => const ProductionBoardPage(),
          ),
          GoRoute(
            path: RouteName.productionProgress,
            name: 'production-progress',
            builder: (_, _) => const ProductionBoardPage(initialTab: 1),
          ),
          GoRoute(
            path: '/production/plans/new',
            name: 'production-plan-new',
            builder: (_, _) => const ProductionPlanEditPage(),
          ),
          GoRoute(
            path: '/production/plans/:id/edit',
            name: 'production-plan-edit',
            builder: (_, s) =>
                ProductionPlanEditPage(id: s.pathParameters['id']),
          ),
          GoRoute(
            path: '/production/plans/:id',
            name: 'production-plan-detail',
            builder: (_, s) =>
                ProductionPlanDetailPage(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: RouteName.productionPlanList,
            name: 'production-plan-list',
            builder: (_, _) => const ProductionPlanListPage(),
          ),
          GoRoute(
            path: '/production/daily-reports/new',
            name: 'production-daily-report-new',
            builder: (_, _) => const ProductionDailyReportEditPage(),
          ),
          GoRoute(
            path: '/production/daily-reports/:id/edit',
            name: 'production-daily-report-edit',
            builder: (_, s) =>
                ProductionDailyReportEditPage(id: s.pathParameters['id']),
          ),
          GoRoute(
            path: '/production/daily-reports/:id',
            name: 'production-daily-report-detail',
            builder: (_, s) =>
                ProductionDailyReportDetailPage(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: RouteName.productionDailyReportList,
            name: 'production-daily-report-list',
            builder: (_, _) => const ProductionDailyReportListPage(),
          ),
          // 生产报表入口（静态段，无 :id 冲突）：计划明细/汇总 2 卡
          // （日报本期 0 行未挂入口，后端 endpoint/页面代码保留待未来启用）
          GoRoute(
            path: RoutePath.productionReport('plan-detail'),
            name: 'production-report-plan-detail',
            builder: (_, _) => const ProductionReportPage(
                kind: ProductionReportKind.detail),
          ),
          GoRoute(
            path: RoutePath.productionReport('plan-summary'),
            name: 'production-report-plan-summary',
            builder: (_, _) => const ProductionReportPage(
                kind: ProductionReportKind.summary),
          ),
          // 物料反查产成品（BOM where-used）：输入材料查用在哪些产成品
          GoRoute(
            path: RouteName.productionWhereUsed,
            name: 'production-where-used',
            builder: (_, _) => const WhereUsedReportPage(),
          ),

          // —— 钱流管理（财税部；静态段 /finance/{report|ar-ap|reconciliations|checks|
          //    customers|suppliers|accounts} 必须在 :seg 参数路由前声明）——
          GoRoute(
            path: RouteName.finance,
            name: 'finance-hub',
            builder: (_, _) => const FinanceHubPage(),
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
            builder: (_, _) => const AccountPage(
                initialAccountTypeFilter: 'CHECK'),
          ),
          GoRoute(
            path: RouteName.financeAssets,
            name: 'finance-assets',
            builder: (_, _) => const FinanceAssetsPage(),
          ),
          GoRoute(
            path: '/finance/:seg/new',
            name: 'finance-doc-new',
            builder: (_, s) => FinanceDocEditPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
            ),
          ),
          GoRoute(
            path: '/finance/:seg/:id/edit',
            name: 'finance-doc-edit',
            builder: (_, s) => FinanceDocEditPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/finance/:seg/:id',
            name: 'finance-doc-detail',
            builder: (_, s) => FinanceDocDetailPage(
              docType: FinanceDocType.byPath(s.pathParameters['seg']!),
              id: s.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/finance/:seg',
            name: 'finance-doc-list',
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
          GoRoute(
            path: RouteName.adminAuditLogs,
            name: 'admin-audit-logs',
            builder: (_, _) => const AdminAuditLogPage(),
          ),
          GoRoute(
            path: RouteName.adminSystemSettings,
            name: 'admin-system-settings',
            builder: (_, _) => const AdminSystemSettingsPage(),
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
