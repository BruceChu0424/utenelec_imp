import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/shared/auth/document_permission_set.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/role.dart';
import 'package:uten_imp/shared/models/user.dart';

void main() {
  group('page route permission dependencies', () {
    test('master-data pages require their category read dependency', () {
      const cases = <(String, String, String)>[
        (RouteName.basicinfoGoods, Perm.goodsView, Perm.materialCategoryView),
        ('/basicinfo/goods/goods-1', Perm.goodsView, Perm.materialCategoryView),
        (RouteName.basicinfoMould, Perm.mouldView, Perm.mouldCategoryView),
        (RouteName.basicinfoClient, Perm.clientView, Perm.clientCategoryView),
        (
          RouteName.basicinfoSupplier,
          Perm.supplierView,
          Perm.supplierCategoryView,
        ),
        (RouteName.financeCustomers, Perm.clientView, Perm.clientCategoryView),
        (
          RouteName.financeSuppliers,
          Perm.supplierView,
          Perm.supplierCategoryView,
        ),
      ];

      for (final (location, primaryView, categoryView) in cases) {
        expect(
          requiredAllPermsFor(location),
          contains(categoryView),
          reason: location,
        );
        expect(
          employeePermissionRedirect(_userWith([primaryView]), location),
          RouteName.accessDenied,
          reason: location,
        );
        expect(
          employeePermissionRedirect(
            _userWith([primaryView, categoryView]),
            location,
          ),
          isNull,
          reason: location,
        );
      }
    });

    test(
      'goods create deep link requires create and both read dependencies',
      () {
        const location = '/basicinfo/goods/new';
        expect(requiredAnyPermFor(location), const [Perm.goodsCreate]);
        expect(requiredAllPermsFor(location), const [
          Perm.goodsView,
          Perm.materialCategoryView,
        ]);

        expect(
          employeePermissionRedirect(_userWith([Perm.goodsCreate]), location),
          RouteName.accessDenied,
        );
        expect(
          employeePermissionRedirect(
            _userWith([Perm.goodsCreate, Perm.goodsView]),
            location,
          ),
          RouteName.accessDenied,
        );
        expect(
          employeePermissionRedirect(
            _userWith([Perm.goodsView, Perm.materialCategoryView]),
            location,
          ),
          RouteName.accessDenied,
        );
        expect(
          employeePermissionRedirect(
            _userWith([
              Perm.goodsCreate,
              Perm.goodsView,
              Perm.materialCategoryView,
            ]),
            location,
          ),
          isNull,
        );
      },
    );

    test('employee and department pages require their first-screen reads', () {
      for (final (location, action) in [
        ('/employee/employee-1/edit', Perm.employeeEdit),
        ('/employee/employee-1/offboarding', Perm.employeeOffboard),
      ]) {
        expect(requiredAllPermsFor(location), const [Perm.employeeView]);
        expect(
          employeePermissionRedirect(_userWith([action]), location),
          RouteName.accessDenied,
        );
        expect(
          employeePermissionRedirect(
            _userWith([action, Perm.employeeView]),
            location,
          ),
          isNull,
        );
      }

      expect(requiredAllPermsFor('/employee/onboarding'), const [
        Perm.employeeCreate,
        Perm.employeePiiEdit,
        Perm.departmentView,
      ]);
      expect(
        employeePermissionRedirect(
          _userWith([Perm.employeeCreate, Perm.employeePiiEdit]),
          '/employee/onboarding',
        ),
        RouteName.accessDenied,
      );
      expect(
        employeePermissionRedirect(
          _userWith([
            Perm.employeeCreate,
            Perm.employeePiiEdit,
            Perm.departmentView,
          ]),
          '/employee/onboarding',
        ),
        isNull,
      );

      expect(requiredAllPermsFor(RouteName.department), const [
        Perm.employeeView,
      ]);
      expect(
        employeePermissionRedirect(
          _userWith([Perm.departmentView]),
          RouteName.department,
        ),
        RouteName.accessDenied,
      );
    });

    test('dynamic document action routes require action and view', () {
      const families = <(String, Map<String, DocumentPermissionSet>)>[
        ('purchase', DocumentPermissionCatalog.purchaseBySegment),
        ('sales', DocumentPermissionCatalog.salesBySegment),
        ('subcontract', DocumentPermissionCatalog.subcontractBySegment),
        ('finance', DocumentPermissionCatalog.financeBySegment),
        ('warehouse', DocumentPermissionCatalog.stockBySegment),
        ('production', DocumentPermissionCatalog.productionBySegment),
      ];

      for (final (root, documents) in families) {
        for (final entry in documents.entries) {
          final permissions = entry.value;
          final routes = <(String, String?)>[
            ('new', permissions.create),
            ('doc-1/edit', permissions.edit),
          ];
          for (final (suffix, action) in routes) {
            final location = '/$root/${entry.key}/$suffix';
            if (location == '/subcontract/material-issues/new') {
              expect(requiredAnyPermFor(location), [permissions.view]);
              expect(
                employeePermissionRedirect(
                  _userWith([permissions.view]),
                  location,
                ),
                isNull,
              );
              continue;
            }
            if (action == null) {
              expect(requiredAnyPermFor(location), isEmpty, reason: location);
              expect(
                employeePermissionRedirect(
                  _userWith([permissions.view]),
                  location,
                ),
                RouteName.notFound,
                reason: location,
              );
              continue;
            }

            expect(requiredAnyPermFor(location), [action], reason: location);
            expect(requiredAllPermsFor(location), [
              permissions.view,
            ], reason: location);
            expect(
              employeePermissionRedirect(_userWith([action]), location),
              RouteName.accessDenied,
              reason: location,
            );
            expect(
              employeePermissionRedirect(
                _userWith([action, permissions.view]),
                location,
              ),
              isNull,
              reason: location,
            );
          }
        }
      }
    });

    test(
      'finance and warehouse shipment roles reach task pages and shared read-only detail only',
      () {
        final financeAuditor = _userWith([Perm.financeShipmentAudit]);
        final warehouseOperator = _userWith([Perm.salesShipmentWarehouseWork]);

        for (final location in [
          '/sales/shipments',
          '/sales/shipments/shipment-1',
        ]) {
          expect(requiredAnyPermFor(location), const [
            Perm.salesShipmentView,
            Perm.financeShipmentAudit,
            Perm.salesShipmentWarehouseWork,
          ]);
          expect(employeePermissionRedirect(financeAuditor, location), isNull);
          expect(
            employeePermissionRedirect(warehouseOperator, location),
            isNull,
          );
        }

        expect(requiredAnyPermFor(RouteName.financeSalesShipmentAudit), const [
          Perm.financeShipmentAudit,
        ]);
        expect(
          employeePermissionRedirect(
            financeAuditor,
            RouteName.financeSalesShipmentAudit,
          ),
          isNull,
        );
        expect(requiredAnyPermFor(RouteName.warehouseSalesOutbound), const [
          Perm.salesShipmentWarehouseWork,
        ]);
        expect(
          employeePermissionRedirect(
            warehouseOperator,
            RouteName.warehouseSalesOutbound,
          ),
          isNull,
        );
        expect(
          employeePermissionRedirect(
            financeAuditor,
            RouteName.warehouseSalesOutbound,
          ),
          RouteName.accessDenied,
        );
        expect(
          employeePermissionRedirect(
            warehouseOperator,
            RouteName.financeSalesShipmentAudit,
          ),
          RouteName.accessDenied,
        );
        expect(
          requiredAnyPermFor(RouteName.finance),
          containsAll([Perm.salesOrderFinanceView, Perm.financeShipmentAudit]),
        );
        expect(
          employeePermissionRedirect(financeAuditor, RouteName.finance),
          isNull,
        );
        expect(
          employeePermissionRedirect(
            _userWith([Perm.salesOrderFinanceView]),
            RouteName.finance,
          ),
          isNull,
        );
        expect(
          requiredAnyPermFor(RouteName.warehouse),
          contains(Perm.salesShipmentWarehouseWork),
        );
        expect(
          employeePermissionRedirect(warehouseOperator, RouteName.warehouse),
          isNull,
        );

        for (final user in [financeAuditor, warehouseOperator]) {
          expect(
            employeePermissionRedirect(user, '/sales/shipments/new'),
            RouteName.accessDenied,
          );
          expect(
            employeePermissionRedirect(
              user,
              '/sales/shipments/shipment-1/edit',
            ),
            RouteName.accessDenied,
          );
        }
      },
    );

    test('legacy plan creation requires both analysis create and view', () {
      final location = RoutePath.productionPlanNew();
      for (final permissions in [
        <String>[],
        [Perm.productionMaterialAnalysisCreate],
        [Perm.productionMaterialAnalysisView],
      ]) {
        expect(
          employeePermissionRedirect(_userWith(permissions), location),
          RouteName.accessDenied,
        );
      }
      expect(
        employeePermissionRedirect(
          _userWith([
            Perm.productionMaterialAnalysisCreate,
            Perm.productionMaterialAnalysisView,
          ]),
          location,
        ),
        isNull,
      );
    });

    test('material analysis requires view besides action permissions', () {
      final summaryPath = RoutePath.productionMaterialAnalysisSummary(
        'analysis-1',
      );
      expect(requiredAnyPermFor(RouteName.productionMaterialAnalysis), const [
        Perm.productionMaterialAnalysisView,
      ]);
      expect(requiredAllPermsFor(RouteName.productionMaterialAnalysis), const [
        Perm.productionMaterialAnalysisView,
      ]);
      expect(requiredAnyPermFor(summaryPath), const [
        Perm.productionMaterialAnalysisView,
      ]);
      expect(requiredAllPermsFor(summaryPath), const [
        Perm.productionMaterialAnalysisView,
      ]);
      expect(
        employeePermissionRedirect(
          _userWith([Perm.productionMaterialAnalysisView]),
          RouteName.productionMaterialAnalysis,
        ),
        isNull,
      );
      for (final action in [
        Perm.productionMaterialAnalysisCreate,
        Perm.productionMaterialAnalysisRefresh,
        Perm.productionMaterialAnalysisRoute,
        Perm.productionMaterialAnalysisNotify,
        Perm.productionMaterialAnalysisGenerate,
        Perm.productionMaterialAnalysisCancel,
        Perm.productionMaterialAnalysisReallocate,
        Perm.productionMaterialAnalysisCrossReallocate,
        Perm.productionMaterialAnalysisOverSupply,
        Perm.productionMaterialAnalysisClaimSharedFuture,
      ]) {
        expect(
          employeePermissionRedirect(
            _userWith([action]),
            RouteName.productionMaterialAnalysis,
          ),
          RouteName.accessDenied,
        );
        expect(
          employeePermissionRedirect(
            _userWith([Perm.productionMaterialAnalysisView, action]),
            RouteName.productionMaterialAnalysis,
          ),
          isNull,
        );
      }
    });

    test(
      'subcontract outbound actions cannot replace page view permission',
      () {
        expect(
          requiredAnyPermFor(RouteName.warehouse),
          contains(Perm.subcontractOutboundView),
        );
        expect(
          requiredAnyPermFor(RouteName.warehouseSubcontractOutbound),
          const [Perm.subcontractOutboundView],
        );
        expect(
          employeePermissionRedirect(
            _userWith(const ['subcontract_outbound:handle']),
            RouteName.warehouseSubcontractOutbound,
          ),
          RouteName.accessDenied,
        );
        expect(
          employeePermissionRedirect(
            _userWith([Perm.subcontractOutboundExecute]),
            RouteName.warehouseSubcontractOutbound,
          ),
          RouteName.accessDenied,
        );
        expect(
          employeePermissionRedirect(
            _userWith([Perm.subcontractOutboundView]),
            RouteName.warehouseSubcontractOutbound,
          ),
          isNull,
        );
      },
    );

    test('subcontract preparation deep link is retired and routed to hub', () {
      // 2026-09-05 委外准备中心退役：旧深链由 GoRouter 重定向到 /subcontract；
      // 守卫沿用 hub 同款权限（任一委外 view），持权用户落到 hub 而非 404。
      const location = '/subcontract/preparations';
      expect(requiredAnyPermFor(location), const [
        Perm.subcontractInquiryView,
        Perm.subcontractApplicationView,
        Perm.subcontractOrderView,
        Perm.subcontractReceiptView,
        Perm.subcontractMaterialIssueView,
        Perm.subcontractReturnView,
        Perm.subcontractMaterialReturnView,
        Perm.subcontractWasteView,
      ]);
      expect(
        employeePermissionRedirect(_userWith(const []), location),
        RouteName.accessDenied,
      );
      expect(
        employeePermissionRedirect(
          _userWith([Perm.subcontractOrderView]),
          location,
        ),
        isNull,
      );
    });

    test('application decomposition new flow requires all source actions', () {
      const location =
          '/subcontract/orders/new?applicationItemIds=item-1,item-2';
      expect(requiredAnyPermFor(location), const [Perm.subcontractOrderCreate]);
      expect(requiredAllPermsFor(location), const [
        Perm.subcontractOrderView,
        Perm.subcontractApplicationView,
        Perm.subcontractOrderDecompose,
      ]);
      expect(
        employeePermissionRedirect(
          _userWith([
            Perm.subcontractOrderCreate,
            Perm.subcontractOrderView,
            Perm.subcontractApplicationView,
          ]),
          location,
        ),
        RouteName.accessDenied,
      );
      expect(
        employeePermissionRedirect(
          _userWith([
            Perm.subcontractOrderCreate,
            Perm.subcontractOrderView,
            Perm.subcontractApplicationView,
            Perm.subcontractOrderDecompose,
          ]),
          location,
        ),
        isNull,
      );
    });

    test('subcontract decomposition workbench reads applications only', () {
      expect(
        requiredAnyPermFor(RouteName.operationsSubcontractWorkbench),
        const [Perm.subcontractApplicationView],
      );
      expect(
        employeePermissionRedirect(
          _userWith([Perm.subcontractOrderView]),
          RouteName.operationsSubcontractWorkbench,
        ),
        RouteName.accessDenied,
      );
    });

    test(
      'historical material issue create path is a view-only guidance page',
      () {
        const location = '/subcontract/material-issues/new';
        expect(
          Perm.buttonActionCodes,
          isNot(contains(Perm.subcontractMaterialIssueCreate)),
          reason:
              'retired manual create must not return as a Flutter action candidate',
        );
        expect(requiredAnyPermFor(location), const [
          Perm.subcontractMaterialIssueView,
        ]);
        for (final action in [
          Perm.subcontractMaterialIssueCreate,
          Perm.subcontractMaterialIssueEdit,
          Perm.subcontractMaterialIssueApprove,
        ]) {
          expect(
            employeePermissionRedirect(_userWith([action]), location),
            RouteName.accessDenied,
          );
        }
      },
    );

    test('IQC rejection actions never replace the exact page view grant', () {
      const locations = <String>[
        '/procurement/iqc-rejections',
        '/procurement/iqc-rejections?source=warehouse',
        '/procurement/iqc-rejections/case-1',
        '/procurement/iqc-rejections/case-1?source=notice',
      ];
      const actions = <String>[
        Perm.procurementIqcRejectionRecordReturn,
        Perm.procurementIqcRejectionConfirmCredit,
        Perm.procurementIqcRejectionCloseNoCredit,
        Perm.procurementIqcRejectionReverse,
      ];

      for (final location in locations) {
        expect(requiredAnyPermFor(location), const [
          Perm.procurementIqcRejectionView,
        ]);
        for (final action in actions) {
          expect(
            employeePermissionRedirect(_userWith([action]), location),
            RouteName.accessDenied,
            reason: '$location must reject action-only $action',
          );
        }
        expect(
          employeePermissionRedirect(
            _userWith([Perm.procurementIqcRejectionView]),
            location,
          ),
          isNull,
        );
      }
    });
  });
}

AppUser _userWith(Iterable<String> permissions) => AppUser(
  id: 'permission-test-user',
  code: 'P001',
  name: '权限测试用户',
  roles: const [Role.employee],
  permissions: permissions.toList(growable: false),
);
