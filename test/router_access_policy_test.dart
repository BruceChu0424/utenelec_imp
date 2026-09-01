import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/role.dart';
import 'package:uten_imp/shared/models/user.dart';

void main() {
  group('visitor portal path policy', () {
    test('matches only the visitor path segment', () {
      expect(isVisitorPortalLocation('/visitor'), isTrue);
      expect(isVisitorPortalLocation('/visitor/login'), isTrue);
      expect(isVisitorPortalLocation('/visitor/applications/1'), isTrue);

      expect(isVisitorPortalLocation('/visitor-approval'), isFalse);
      expect(isVisitorPortalLocation('/visitor-approval/1'), isFalse);
      expect(isVisitorPortalLocation('/visitorish'), isFalse);
    });
  });

  group('report and operation route permissions', () {
    test('admin routes separate account support from authorization', () {
      expect(requiredAnyPermFor(RouteName.adminPermissions), const [
        Perm.accountSupport,
        Perm.authorizationManage,
      ]);
      expect(requiredAnyPermFor(RouteName.adminAuditLogs), const [
        Perm.auditLogView,
      ]);
      expect(requiredAnyPermFor(RouteName.deviceAuditReceipts), const [
        Perm.auditLogView,
      ]);
      expect(requiredAnyPermFor(RouteName.adminSystemSettings), const [
        Perm.authorizationManage,
      ]);
      expect(requiredAnyPermFor('/admin/unknown'), const [
        Perm.authorizationManage,
      ]);
    });

    test('ordinary employee deep links are redirected by the route guard', () {
      const ordinary = AppUser(
        id: 'employee-1',
        code: 'E001',
        name: '普通员工',
        roles: [Role.employee],
      );
      const auditor = AppUser(
        id: 'auditor-1',
        code: 'A001',
        name: '审计员',
        roles: [Role.employee],
        permissions: [Perm.auditLogView],
      );

      expect(
        employeePermissionRedirect(ordinary, RouteName.deviceAuditReceipts),
        RouteName.accessDenied,
      );
      expect(
        employeePermissionRedirect(ordinary, RouteName.adminAuditLogs),
        RouteName.accessDenied,
      );
      expect(
        employeePermissionRedirect(auditor, RouteName.deviceAuditReceipts),
        isNull,
      );
      expect(
        employeePermissionRedirect(auditor, RouteName.adminAuditLogs),
        isNull,
      );
      expect(
        employeePermissionRedirect(ordinary, RouteName.accessDenied),
        isNull,
      );
    });

    test('unknown dynamic document segments are 404 even for super admin', () {
      const employee = AppUser(
        id: 'employee-404',
        code: 'E404',
        name: 'Employee',
        roles: [Role.employee],
      );
      const superAdmin = AppUser(
        id: 'super-404',
        code: 'S404',
        name: 'Super admin',
        roles: [Role.admin],
        superAdmin: true,
      );
      const unknownLocations = [
        '/purchase/assets/new',
        '/warehouse/UNKNOWN/new',
        '/sales/assets/new',
        '/subcontract/unknown/new',
        '/finance/unknown/new',
      ];

      for (final location in unknownLocations) {
        expect(requiredAnyPermFor(location), isEmpty, reason: location);
        expect(
          employeePermissionRedirect(employee, location),
          RouteName.notFound,
          reason: location,
        );
        expect(
          employeePermissionRedirect(superAdmin, location),
          RouteName.notFound,
          reason: location,
        );
      }

      expect(
        employeePermissionRedirect(employee, '/purchase/orders/order-1'),
        RouteName.accessDenied,
      );
      expect(
        employeePermissionRedirect(superAdmin, '/purchase/orders/order-1'),
        isNull,
      );
    });

    test('finance procurement approval route uses view permission', () {
      expect(requiredAnyPermFor('/finance/procurement-approvals'), const [
        Perm.financeOrderApprovalView,
      ]);
    });

    test('finance payables route uses AR/AP ledger view permission', () {
      expect(requiredAnyPermFor(RouteName.financePayables), const [
        Perm.arApLedgerView,
        Perm.subcontractLossClaimView,
        Perm.supplierSettlementView,
      ]);
    });

    test('finance report descendants use finance report permission', () {
      for (final location in [
        RouteName.financeReport,
        RouteName.financeReportDetail,
        RouteName.financeReportSummary,
        RouteName.financeReportOverview,
        RouteName.financeReportStatement,
        RouteName.financeReportAccountFlow,
        RouteName.financeReportRecon,
        RouteName.financeReportCost,
        RouteName.financeReportGl,
      ]) {
        expect(requiredAnyPermFor(location), const [
          Perm.financeReportView,
        ], reason: location);
      }
    });

    test('sales and subcontract report descendants use report permissions', () {
      for (final location in [
        RouteName.salesReport,
        RouteName.salesReportDetail,
        RouteName.salesReportSummary,
      ]) {
        expect(requiredAnyPermFor(location), const [
          Perm.salesReportView,
        ], reason: location);
      }
      for (final location in [
        RouteName.subcontractReport,
        '${RouteName.subcontractReport}/summary',
      ]) {
        expect(requiredAnyPermFor(location), const [
          Perm.subcontractReportView,
        ], reason: location);
      }
    });

    test('asset workbench descendants require asset view permission', () {
      for (final location in [
        RouteName.financeAssets,
        '${RouteName.financeAssets}/fixed/asset-1',
      ]) {
        expect(requiredAnyPermFor(location), const [
          Perm.financeAssetView,
        ], reason: location);
      }
    });

    test('finance master-data aliases use their real backend permissions', () {
      expect(requiredAnyPermFor(RouteName.financeCustomers), const [
        Perm.clientView,
      ]);
      expect(requiredAnyPermFor(RouteName.financeSuppliers), const [
        Perm.supplierView,
      ]);
      expect(requiredAnyPermFor(RouteName.financeAccounts), const [
        Perm.accountView,
      ]);
    });

    test(
      'purchase and warehouse report descendants use report permissions',
      () {
        expect(requiredAnyPermFor(RouteName.purchaseReport), const [
          Perm.purchaseReportView,
        ]);
        expect(requiredAnyPermFor('/purchase/report/detail'), const [
          Perm.purchaseReportView,
        ]);
        expect(requiredAnyPermFor(RouteName.warehouseReport), const [
          Perm.stockReportView,
        ]);
        expect(requiredAnyPermFor(RouteName.warehouseReportDetail), const [
          Perm.stockReportView,
        ]);
        expect(requiredAnyPermFor(RouteName.warehouseReportSummary), const [
          Perm.stockReportView,
        ]);
      },
    );

    test(
      'IQC warehouse stock-in list and detail use exact view permission',
      () {
        for (final location in [
          RouteName.warehouseIqcStockIns,
          // 旧 IQC 待入库详情深链（现重定向到合并页详情）仍按原路径鉴权。
          '${RouteName.warehouseIqcStockIns}/PURCHASE/receipt-1',
        ]) {
          final required = requiredAnyPermFor(location);
          expect(required, const [Perm.warehouseIqcStockInView]);
          for (final oldPermission in const [
            Perm.procurementInspectionHandle,
            Perm.warehouseInboundStockIn,
            Perm.warehouseInboundView,
            Perm.stockDocEdit,
          ]) {
            expect(required, isNot(contains(oldPermission)));
          }
        }
        expect(
          requiredAnyPermFor(RouteName.warehouse),
          contains(Perm.warehouseIqcStockInView),
        );
      },
    );

    test(
      'purchase order create and detail deep links keep distinct authorities',
      () {
        expect(requiredAnyPermFor('/purchase/orders/new'), const [
          Perm.purchaseOrderCreate,
        ]);
        expect(requiredAnyPermFor('/purchase/orders/order-1'), const [
          Perm.purchaseOrderView,
          Perm.financeOrderApprovalView,
        ]);
      },
    );

    test('production progress uses the backend view permission', () {
      expect(requiredAnyPermFor(RouteName.productionProgress), const [
        Perm.productionPlanView,
      ]);
    });

    test('notice and suggestion routes use their backend permission codes', () {
      expect(requiredAnyPermFor(RouteName.notice), const [Perm.noticeRead]);
      expect(requiredAnyPermFor('/notice/notice-1'), const [Perm.noticeRead]);
      expect(requiredAnyPermFor('/notice/publish'), const [Perm.noticePublish]);
      expect(requiredAnyPermFor(RouteName.suggestion), const [
        Perm.suggestionSubmit,
      ]);
      expect(requiredAnyPermFor('/suggestion/new'), const [
        Perm.suggestionSubmit,
      ]);
      expect(requiredAnyPermFor('/suggestion/suggestion-1'), const [
        Perm.suggestionSubmit,
      ]);
    });

    test('security scan route requires verify instead of check-in', () {
      expect(requiredAnyPermFor(RouteName.securityScan), const [
        Perm.visitorVerify,
      ]);
    });
    test('basic-data routes use the matching master-data view permission', () {
      expect(requiredAnyPermFor(RouteName.basicinfo), contains(Perm.goodsView));
      expect(requiredAnyPermFor(RouteName.basicinfoGoods), const [
        Perm.goodsView,
      ]);
      expect(requiredAnyPermFor(RouteName.basicinfoMould), const [
        Perm.mouldView,
      ]);
      expect(requiredAnyPermFor(RouteName.basicinfoClient), const [
        Perm.clientView,
      ]);
      expect(requiredAnyPermFor(RouteName.basicinfoSupplier), const [
        Perm.supplierView,
      ]);
      expect(requiredAnyPermFor(RouteName.basicinfoColor), const [
        Perm.colorView,
      ]);
      expect(requiredAnyPermFor(RouteName.basicinfoUnit), const [
        Perm.unitView,
      ]);
      expect(requiredAnyPermFor(RouteName.basicinfoCurrency), const [
        Perm.currencyView,
      ]);
      expect(requiredAnyPermFor(RouteName.basicinfoWarehouse), const [
        Perm.warehouseView,
      ]);
      expect(requiredAnyPermFor(RouteName.basicinfoAccount), const [
        Perm.accountView,
      ]);
      expect(
        requiredAnyPermFor('/basicinfo/account/account-1?edit=true'),
        const [Perm.accountView],
      );
      expect(requiredAnyPermFor(RouteName.basicinfoPaymentStyle), const [
        Perm.paymentStyleView,
      ]);
    });

    test('payroll and expense routes protect sensitive data and actions', () {
      expect(requiredAnyPermFor('/payroll/slip'), const [
        Perm.payrollViewSelf,
        Perm.payrollViewAll,
      ]);
      expect(requiredAnyPermFor('/payroll/slip/slip-1'), const [
        Perm.payrollViewSelf,
        Perm.payrollViewAll,
      ]);
      expect(requiredAnyPermFor('/payroll/generate'), const [
        Perm.payrollGenerate,
      ]);
      expect(requiredAnyPermFor('/payroll/review'), const [
        Perm.payrollReview,
        Perm.payrollPublish,
      ]);
      expect(requiredAnyPermFor('/expense'), const [Perm.expenseApply]);
      expect(requiredAnyPermFor('/expense/claim-1'), const [Perm.expenseApply]);
      expect(requiredAnyPermFor('/expense/approval'), const [
        Perm.expenseApprove,
        Perm.expensePay,
      ]);
      expect(requiredAnyPermFor('/expense/approval/claim-1'), const [
        Perm.expenseApprove,
        Perm.expensePay,
      ]);
    });

    test('employee onboarding requires create and PII write permissions', () {
      expect(requiredAnyPermFor('/employee/onboarding'), const [
        Perm.employeeCreate,
      ]);
      expect(requiredAllPermsFor('/employee/onboarding'), const [
        Perm.employeeCreate,
        Perm.employeePiiEdit,
        Perm.departmentView,
      ]);
      expect(requiredAllPermsFor('/employee/1/edit'), const [
        Perm.employeeView,
      ]);
    });
  });
}
