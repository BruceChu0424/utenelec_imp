import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('partial batch route keeps exact workshop action permissions', () {
    const path = '${RouteName.productionBatchDraw}?segmentId=a&version=3';
    expect(requiredAnyPermFor(path), [Perm.productionExecutionView]);
    expect(requiredAllPermsFor(path), [
      Perm.productionExecutionView,
      Perm.productionExecutionStart,
    ]);
    expect(
      pagePermissionScopeFor(path)?.surfaceKey,
      'production.workshop-tasks',
    );
  });
  test(
    'draw review deep link requires both workshop read and operation grants',
    () {
      const path =
          '${RouteName.productionDrawRequest}?segmentIds=a,b&versions=1,2';
      expect(requiredAnyPermFor(path), [Perm.productionExecutionView]);
      expect(requiredAllPermsFor(path), [
        Perm.productionExecutionView,
        Perm.productionExecutionStart,
      ]);
      expect(
        pagePermissionScopeFor(path)?.surfaceKey,
        'production.workshop-tasks',
      );
      expect(
        pagePermissionScopeFor('${RouteName.productionDrawRequest}/unknown'),
        isNull,
      );
    },
  );
}
