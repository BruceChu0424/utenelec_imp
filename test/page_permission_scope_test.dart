import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';

void main() {
  group('PagePermissionScope', () {
    test('stable surface key resolves the same page definition', () {
      final routeScope = pagePermissionScopeFor('/basicinfo/goods/123');
      final keyScope = pagePermissionScopeBySurfaceKey('basic.goods');

      expect(routeScope, isNotNull);
      expect(keyScope, isNotNull);
      expect(keyScope!.surfaceKey, routeScope!.surfaceKey);
      expect(keyScope.title, '货品资料');
      expect(pagePermissionScopeBySurfaceKey('unknown.surface'), isNull);
    });

    test('account list and detail share the basic.account surface', () {
      final list = pagePermissionScopeFor('/basicinfo/account');
      final detail = pagePermissionScopeFor(
        '/basicinfo/account/8dd0f270-4341-4ba0-90db-4db70f402cc4?edit=true',
      );

      expect(list?.surfaceKey, 'basic.account');
      expect(detail?.surfaceKey, list?.surfaceKey);
      expect(detail?.title, list?.title);
    });

    test('shipment task workbenches use exact cross-department surfaces', () {
      final sales = pagePermissionScopeFor('/sales/shipments');
      final finance = pagePermissionScopeFor('/finance/sales-shipment-audits');
      final warehouse = pagePermissionScopeFor('/warehouse/sales-outbound');

      expect(sales?.surfaceKey, 'sales.shipment');
      expect(finance?.surfaceKey, 'finance.sales-shipment-audit');
      expect(finance?.title, '出货财务审核');
      expect(warehouse?.surfaceKey, 'warehouse.sales-outbound');
      expect(warehouse?.title, '仓库销售出库');
    });
  });

  group('pagePermissionScopeFor', () {
    test('covers every enumerated employee business path', () {
      for (final path in _businessPaths()) {
        final scope = pagePermissionScopeFor(path);
        expect(scope, isNotNull, reason: path);
        expect(scope!.surfaceKey, isNotEmpty, reason: path);
        expect(scope.title, isNotEmpty, reason: path);
        final reverse = pagePermissionScopeBySurfaceKey(scope.surfaceKey);
        expect(reverse?.surfaceKey, scope.surfaceKey, reason: path);
        expect(reverse?.title, scope.title, reason: path);
      }
    });

    test('every Flutter surface key exists in an immutable migration seed', () {
      final v328 = File(
        'server/src/main/resources/db/migration/'
        'V328__permission_catalog_action_taxonomy.sql',
      );
      final v437 = File(
        'server/src/main/resources/db/migration/'
        'V437__subcontract_permission_surfaces.sql',
      );
      final v440 = File(
        'server/src/main/resources/db/migration/'
        'V440__procurement_iqc_rejection_finance_closure.sql',
      );
      final v443 = File(
        'server/src/main/resources/db/migration/'
        'V443__sales_receivable_finance_release_and_client_payment_type.sql',
      );
      final v446 = File(
        'server/src/main/resources/db/migration/'
        'V446__iqc_release_warehouse_stock_in.sql',
      );
      final v450 = File(
        'server/src/main/resources/db/migration/'
        'V450__warehouse_task_centers_and_stock_item_read_indexes.sql',
      );
      final v455 = File(
        'server/src/main/resources/db/migration/'
        'V455__permission_surface_closure_and_orphan_code_retirement.sql',
      );
      final v475 = File(
        'server/src/main/resources/db/migration/'
        'V475__permission_surface_completion_and_viewcontext_retirement.sql',
      );
      expect(v328.existsSync(), isTrue);
      expect(v437.existsSync(), isTrue);
      expect(v440.existsSync(), isTrue);
      expect(v443.existsSync(), isTrue);
      expect(v446.existsSync(), isTrue);
      expect(v450.existsSync(), isTrue);
      expect(v455.existsSync(), isTrue);
      expect(v475.existsSync(), isTrue);
      final source = v328.readAsStringSync();
      final seedStart = source.indexOf('INSERT INTO permission_surfaces');
      final seedEnd = source.indexOf(
        '-- These are migration-only representations',
        seedStart,
      );
      expect(seedStart, isNonNegative);
      expect(seedEnd, greaterThan(seedStart));
      final seed =
          '${source.substring(seedStart, seedEnd)}\n'
          '${v437.readAsStringSync()}\n'
          '${v440.readAsStringSync()}\n'
          '${v443.readAsStringSync()}\n'
          '${v446.readAsStringSync()}\n'
          '${v450.readAsStringSync()}\n'
          '${v455.readAsStringSync()}\n'
          '${v475.readAsStringSync()}';
      final surfaceKeys = {
        for (final path in _businessPaths())
          pagePermissionScopeFor(path)!.surfaceKey,
      };
      for (final key in surfaceKeys) {
        expect(seed, contains("'$key'"), reason: key);
      }
    });

    test('normalizes query strings and trailing slashes', () {
      expect(pagePermissionScopeFor('/basicinfo/goods/?tab=1')?.title, '货品资料');
      expect(
        pagePermissionScopeFor('/finance/assets/?tab=events')?.title,
        '资产与待摊',
      );
    });

    test(
      'excludes auth, visitor portal, shell tabs, self-service and admin',
      () {
        const excluded = <String>[
          '/',
          '/entry',
          '/login',
          '/change-password',
          '/access-denied',
          '/not-found',
          '/visitor/login',
          '/visitor/home',
          '/visitor/settings',
          '/visitor/apply',
          '/visitor/apply/visit-1',
          '/dashboard',
          '/notice',
          '/notice/notice-1',
          '/profile',
          '/profile/edit',
          '/profile/me/changes',
          '/profile/me/department',
          '/profile/me/vehicles',
          '/profile/me/documents',
          '/settings',
          '/settings/device-receipts',
          '/payroll/slip',
          '/payroll/slip/slip-1',
          '/expense',
          '/expense/new',
          '/expense/claim-1',
          '/my-visitors',
          '/admin/permissions',
          '/admin/audit-logs',
          '/admin/system-settings',
          '/production/chain-health',
        ];

        for (final path in excluded) {
          expect(pagePermissionScopeFor(path), isNull, reason: path);
        }
      },
    );

    test('unknown dynamic segments fail closed', () {
      const unknown = <String>[
        '/purchase/unknown',
        '/warehouse/UNKNOWN',
        '/sales/unknown',
        '/subcontract/unknown',
        '/finance/unknown',
        '/production/reports/unknown',
      ];
      for (final path in unknown) {
        expect(pagePermissionScopeFor(path), isNull, reason: path);
      }
    });
  });
}

Iterable<String> _businessPaths() sync* {
  yield* const <String>[
    '/payroll/generate',
    '/payroll/review',
    '/expense/approval',
    '/expense/approval/claim-1',
    '/notice/publish',
    '/suggestion',
    '/suggestion/new',
    '/suggestion/suggestion-1',
    '/webinquiry',
    '/webinquiry/inquiry-1',
    '/employee',
    '/employee/onboarding',
    '/employee/employee-1',
    '/employee/employee-1/edit',
    '/employee/employee-1/offboarding',
    '/department',
    '/basicinfo',
    '/basicinfo/goods',
    '/basicinfo/goods/new',
    '/basicinfo/goods/goods-1',
    '/basicinfo/mould',
    '/basicinfo/client',
    '/basicinfo/supplier',
    '/basicinfo/color',
    '/basicinfo/unit',
    '/basicinfo/currency',
    '/basicinfo/warehouse',
    '/basicinfo/account',
    '/basicinfo/account/account-1',
    '/basicinfo/payment-style',
    '/finance/customers',
    '/finance/suppliers',
    '/finance/accounts',
    '/operations/workbench/warehouse',
    '/operations/workbench/purchase',
    '/operations/workbench/subcontract',
    '/rd/tasks',
    '/procurement/iqc-rejections',
    '/procurement/iqc-rejections?source=warehouse',
    '/procurement/iqc-rejections/case-1',
    '/procurement/iqc-rejections/case-1?source=notice',
    '/procurement/arrival-exceptions',
    '/procurement/arrival-exceptions/exception-1',
    '/stock/balance',
    '/stock/movement',
    '/stock/instant-inventory',
    '/stock/item/item-1',
    '/warehouse',
    '/warehouse/tasks/outbound',
    '/warehouse/tasks/inbound',
    '/warehouse/tasks/draw',
    '/warehouse/inspections',
    '/warehouse/iqc-stock-ins',
    '/warehouse/iqc-stock-ins/PURCHASE/receipt-1',
    '/warehouse/quality-results',
    '/quality/task-center',
    '/quality/production-inspections',
    '/quality/inspection-records',
    '/warehouse/inbound/expectations',
    '/warehouse/inbound/arrival-exceptions',
    '/warehouse/inbound/receipts/new',
    '/warehouse/report',
    '/warehouse/report/detail',
    '/warehouse/report/summary',
    '/warehouse/shelf-labels',
    '/warehouse/subcontract-outbound',
    '/warehouse/subcontract-outbound/plan-1',
    '/warehouse/sales-outbound',
    '/sales',
    '/sales/report',
    '/sales/report/detail',
    '/sales/report/summary',
    '/sales/scarcity',
    '/sales/progress',
    '/sales/progress/order-1',
    '/subcontract',
    '/subcontract/preparations',
    '/subcontract/report',
    '/subcontract/report/detail',
    '/production',
    '/production/schedule',
    '/production/progress',
    '/production/material-analysis',
    '/production/material-analyses',
    '/production/material-analyses/analysis-1/summary',
    '/production/plans',
    '/production/plans/new',
    '/production/plans/plan-1',
    '/production/plans/plan-1/edit',
    '/production/daily-reports',
    '/production/daily-reports/new',
    '/production/daily-reports/report-1',
    '/production/daily-reports/report-1/edit',
    '/production/reports/plan-detail',
    '/production/reports/plan-summary',
    '/production/where-used',
    '/finance',
    '/finance/procurement-approvals',
    '/finance/sales-order-confirmations',
    '/finance/sales-order-confirmations/order-1',
    '/finance/sales-shipment-audits',
    '/finance/procurement-arrival-exceptions',
    '/finance/procurement-arrival-exceptions/exception-1',
    '/finance/report',
    '/finance/report/detail',
    '/finance/report/summary',
    '/finance/report/overview',
    '/finance/report/statement',
    '/finance/report/account-flow',
    '/finance/report/recon',
    '/finance/report/cost',
    '/finance/report/gl',
    '/finance/ar-ap',
    '/finance/payables',
    '/finance/reconciliations',
    '/finance/checks',
    '/finance/assets',
    '/visitor-approval',
    '/visitor-approval/visit-1',
    '/security/scan',
    '/hr/tasks',
    '/hr/tasks/probation',
    '/hr/profile-changes',
    '/hr/profile-changes/change-1',
  ];

  for (final doc in const ['requests', 'orders', 'receipts', 'returns']) {
    yield '/purchase/$doc';
    yield '/purchase/$doc/new';
    yield '/purchase/$doc/doc-1';
    yield '/purchase/$doc/doc-1/edit';
  }
  yield '/purchase/report';
  yield '/purchase/report/detail';

  for (final code in const [
    'TRANSFER',
    'OTHER_IN',
    'OTHER_OUT',
    'DRAW',
    'WDRAW',
    'FINISHED_IN',
    'FINISHED_OUT',
    'CHECK',
  ]) {
    yield '/warehouse/$code';
    yield '/warehouse/$code/new';
    yield '/warehouse/$code/doc-1';
    yield '/warehouse/$code/doc-1/edit';
  }

  for (final doc in const [
    'quotes',
    'orders',
    'shipments',
    'other-shipments',
    'returns',
  ]) {
    yield '/sales/$doc';
    yield '/sales/$doc/new';
    yield '/sales/$doc/doc-1';
    yield '/sales/$doc/doc-1/edit';
  }

  for (final doc in const [
    'inquiries',
    'applications',
    'orders',
    'receipts',
    'material-issues',
    'returns',
    'material-returns',
    'wastes',
  ]) {
    yield '/subcontract/$doc';
    yield '/subcontract/$doc/new';
    yield '/subcontract/$doc/doc-1';
    yield '/subcontract/$doc/doc-1/edit';
  }

  for (final doc in const [
    'receipts',
    'payments',
    'expenses',
    'incomes',
    'bank-transfers',
  ]) {
    yield '/finance/$doc';
    yield '/finance/$doc/new';
    yield '/finance/$doc/doc-1';
    yield '/finance/$doc/doc-1/edit';
  }
}
