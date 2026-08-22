import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/managed_permission_department_forest.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';

void main() {
  test('parses enriched managed department rows', () {
    final row = ManagedPermissionDepartment.fromJson({
      'departmentId': 'sales',
      'code': 'DEPT_SALES',
      'name': '销售部',
      'level': '一级部门',
      'parentId': 'center',
      'sortOrder': 20,
      'selectable': true,
    });

    expect(row.departmentName, '销售部');
    expect(row.code, 'DEPT_SALES');
    expect(row.parentId, 'center');
    expect(row.sortOrder, 20);
    expect(row.selectable, isTrue);
  });

  test('builds only server-cropped forest and preserves skeleton nodes', () {
    final forest = ManagedPermissionDepartmentForest.fromRows(const [
      ManagedPermissionDepartment(
        departmentId: 'team',
        departmentName: '销售一组',
        level: '二级班组',
        code: 'TEAM_1',
        parentId: 'sales',
        sortOrder: 10,
      ),
      ManagedPermissionDepartment(
        departmentId: 'company',
        departmentName: '优腾电器',
        level: '公司',
        code: 'ROOT',
        selectable: false,
      ),
      ManagedPermissionDepartment(
        departmentId: 'sales',
        departmentName: '销售部',
        level: '一级部门',
        code: 'DEPT_SALES',
        parentId: 'decision',
        sortOrder: 20,
      ),
      ManagedPermissionDepartment(
        departmentId: 'decision',
        departmentName: '决策层',
        level: '决策层',
        code: 'DECISION',
        parentId: 'company',
        selectable: false,
      ),
    ]);

    expect(forest.roots.single.id, 'company');
    final decision = forest.roots.single.children.single;
    expect(decision.id, 'decision');
    expect(decision.children.single.id, 'sales');
    expect(decision.children.single.children.single.id, 'team');
    expect(forest.selectableIds, {'sales', 'team'});
    expect(forest.selectableIds, isNot(contains('company')));
  });

  test('malformed parent cycles fail closed as separate roots', () {
    final forest = ManagedPermissionDepartmentForest.fromRows(const [
      ManagedPermissionDepartment(
        departmentId: 'a',
        departmentName: 'A',
        level: '一级部门',
        parentId: 'b',
      ),
      ManagedPermissionDepartment(
        departmentId: 'b',
        departmentName: 'B',
        level: '一级部门',
        parentId: 'a',
      ),
    ]);

    expect(forest.roots.map((node) => node.id), containsAll(['a', 'b']));
    expect(forest.roots.every((node) => node.children.isEmpty), isTrue);
  });
}
