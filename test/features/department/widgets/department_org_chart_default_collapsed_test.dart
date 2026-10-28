import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/department/widgets/department_org_chart_dialog.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
}

DepartmentNode _tree() => DepartmentNode(
  id: 'root',
  code: 'ROOT',
  name: '组织总根',
  level: '管理中心',
  children: [
    DepartmentNode(
      id: 'child',
      code: 'CHILD',
      name: '子部门',
      level: '一级部门',
      children: [
        DepartmentNode(
          id: 'leaf',
          code: 'LEAF',
          name: '班组',
          level: '二级班组',
          children: const [],
        ),
      ],
    ),
  ],
);

class _Departments extends Fake implements DepartmentRepository {
  int reads = 0;
  @override
  Future<List<DepartmentNode>> subtree(String id) async {
    reads++;
    return [_tree()];
  }
}

class _Employees extends Fake implements EmployeeRepository {
  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
  }) async => PagedResult(
    items: const [
      EmployeeSummary(
        id: 'e-root',
        code: 'E1',
        fullName: '根部门员工',
        departmentId: 'root',
        status: 'active',
      ),
      EmployeeSummary(
        id: 'e-child',
        code: 'E2',
        fullName: '子部门员工',
        departmentId: 'child',
        status: 'active',
      ),
    ],
    page: page,
    size: size,
    total: 2,
    totalPages: 1,
  );
}

void main() {
  testWidgets('组织架构图默认收起人员和下级，刷新保留手动展开与收起', (tester) async {
    final departments = _Departments();
    final permissions = {Perm.employeeView};
    final boundary = SensitiveReadBoundary(
      identity: null,
      api: ApiClient(Dio(BaseOptions(baseUrl: 'https://erp.test/api'))),
      permissions: permissions,
      superAdmin: false,
    );
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sensitiveReadBoundaryProvider.overrideWithValue(boundary),
          exportContextEpochProvider.overrideWith(_Epoch.new),
          currentPermissionsProvider.overrideWithValue(permissions),
          departmentRepositoryProvider.overrideWithValue(departments),
          employeeRepositoryProvider.overrideWithValue(_Employees()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DepartmentOrgChartDialog(node: _tree())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('子部门'), findsNothing);
    expect(find.text('根部门员工'), findsNothing);
    await tester.tap(find.text('组织总根'));
    await tester.pumpAndSettle();
    expect(find.text('子部门'), findsOneWidget);
    expect(find.text('根部门员工'), findsOneWidget);
    expect(find.text('子部门员工'), findsNothing);
    await tester.tap(find.text('子部门'));
    await tester.pumpAndSettle();
    expect(find.text('班组'), findsOneWidget);
    expect(find.text('子部门员工'), findsOneWidget);
    await tester.tap(find.text('子部门'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(departments.reads, 2);
    expect(find.text('子部门'), findsOneWidget);
    expect(find.text('班组'), findsNothing);
    expect(find.text('子部门员工'), findsNothing);
    await tester.tap(find.text('组织总根'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('子部门'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
