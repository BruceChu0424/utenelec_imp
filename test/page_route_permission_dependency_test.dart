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
    test('material analysis requires view besides action permissions', () {
      expect(
        requiredAnyPermFor(RouteName.productionMaterialAnalysis),
        contains(Perm.productionMaterialAnalysisCrossReallocate),
      );
      expect(requiredAllPermsFor(RouteName.productionMaterialAnalysis), const [
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
        Perm.productionMaterialAnalysisCrossReallocate,
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

    test('subcontract outbound handle cannot replace page view permission', () {
      expect(requiredAnyPermFor(RouteName.warehouseSubcontractOutbound), const [
        Perm.subcontractOutboundView,
      ]);
      expect(
        employeePermissionRedirect(
          _userWith([Perm.subcontractOutboundHandle]),
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
