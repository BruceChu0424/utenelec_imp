import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/models/position.dart';
import 'package:uten_imp/features/department/repositories/position_repository.dart';
import 'package:uten_imp/features/department/widgets/position_manager_sheet.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _PositionRepository implements PositionRepository {
  @override
  Future<List<Position>> listByDepartment(String deptId) async => [
    const Position(
      id: 'position-1',
      code: 'BUYER-01',
      name: '采购员',
      level: '员工',
      sortOrder: 1,
    ),
  ];

  @override
  Future<Position> create(String deptId, PositionSaveInput input) =>
      throw UnimplementedError();

  @override
  Future<void> delete(String id) => throw UnimplementedError();

  @override
  Future<Position> update(String id, PositionUpdateInput input) =>
      throw UnimplementedError();
}

final _node = DepartmentNode(
  id: 'department-1',
  code: 'DEPT-PMC',
  name: '运营部',
  level: '一级部门',
  children: const [],
);

Widget _app(Set<String> permissions) {
  return ProviderScope(
    overrides: [
      currentPermissionsProvider.overrideWithValue(permissions),
      positionRepositoryProvider.overrideWithValue(_PositionRepository()),
    ],
    child: MaterialApp(
      home: Scaffold(body: PositionManagerSheet(node: _node)),
    ),
  );
}

void main() {
  testWidgets('position sheet is read-only without position actions', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const {Perm.departmentView}));
    await tester.pumpAndSettle();

    expect(find.text('采购员'), findsOneWidget);
    expect(find.byTooltip('添加岗位'), findsNothing);
    expect(find.byTooltip('编辑'), findsNothing);
    expect(find.byTooltip('删除'), findsNothing);
  });

  testWidgets('position sheet exposes mutations with position actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const {
        Perm.departmentView,
        Perm.positionCreate,
        Perm.positionEdit,
        Perm.positionDelete,
      }),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('添加岗位'), findsOneWidget);
    expect(find.byTooltip('编辑'), findsOneWidget);
    expect(find.byTooltip('删除'), findsOneWidget);
  });
}
