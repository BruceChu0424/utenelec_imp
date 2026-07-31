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
        RouteName.dashboard,
      );
      expect(
        employeePermissionRedirect(ordinary, RouteName.adminAuditLogs),
        RouteName.dashboard,
      );
      expect(
        employeePermissionRedirect(auditor, RouteName.deviceAuditReceipts),
        isNull,
      );
      expect(
        employeePermissionRedirect(auditor, RouteName.adminAuditLogs),
        isNull,
      );
    });

    test(
      'finance report descendants and assets use finance report permission',
      () {
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
          RouteName.financeAssets,
        ]) {
          expect(requiredAnyPermFor(location), const [
            Perm.financeReportView,
          ], reason: location);
        }
      },
    );

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

    test('production progress and lab upload match backend permissions', () {
      expect(requiredAnyPermFor(RouteName.productionProgress), const [
        Perm.productionPlanView,
      ]);
      expect(requiredAnyPermFor('/lab/test/upload'), const [
        Perm.labTestUpload,
      ]);
      expect(requiredAnyPermFor('/lab/test'), const [Perm.labTestView]);
      expect(requiredAnyPermFor('/lab/test/1'), const [Perm.labTestView]);
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
      ]);
      expect(requiredAllPermsFor('/employee/1/edit'), isEmpty);
    });
  });
}
