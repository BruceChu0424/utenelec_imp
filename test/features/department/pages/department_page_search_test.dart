import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/models/workforce_overview.dart';
import 'package:uten_imp/features/department/pages/department_page.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/department/widgets/department_overview_pane.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('无 employee:view 时统一搜索只查部门且不触发员工接口', (tester) async {
    final employees = _RecordingEmployeeRepository();
    await _pumpPage(tester, employees, {Perm.departmentView});

    final search = _treeSearch();
    expect(tester.widget<TextField>(search).decoration?.hintText, '搜索部门名称/编号');
    await tester.enterText(search, 'SALES');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(employees.calls, isEmpty);
    expect(
      tester
          .widget<UtenDepartmentTreeView>(find.byType(UtenDepartmentTreeView))
          .selectedIds,
      {'sales'},
    );
  });

  testWidgets('员工定位与右侧在册列表使用完全相同的状态集合', (tester) async {
    final employees = _RecordingEmployeeRepository();
    await _pumpPage(tester, employees, {
      Perm.departmentView,
      Perm.employeeView,
    });

    await tester.enterText(_treeSearch(), 'E-100');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final locator = employees.calls.firstWhere(
      (call) => call.search == 'E-100' && call.departmentId == null,
    );
    expect(locator.statuses, currentDepartmentEmployeeStatuses);
    expect(
      employees.calls
          .where((call) => call.departmentId == 'sales')
          .every(
            (call) =>
                call.statuses != null &&
                setEquals(call.statuses!, currentDepartmentEmployeeStatuses),
          ),
      isTrue,
    );
  });

  testWidgets('新输入在防抖窗口内立即阻止旧部门定位回写', (tester) async {
    final employees = _DeferredEmployeeRepository();
    await _pumpPage(tester, employees, {
      Perm.departmentView,
      Perm.employeeView,
    });

    final search = _treeSearch();
    await tester.enterText(search, 'OLD');
    await tester.pump(const Duration(milliseconds: 350));
    expect(employees.oldRequested, isTrue);

    await tester.enterText(search, 'NEW');
    employees.completeOld();
    await tester.pump();
    expect(
      tester
          .widget<UtenDepartmentTreeView>(find.byType(UtenDepartmentTreeView))
          .selectedIds,
      isEmpty,
    );

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenDepartmentTreeView>(find.byType(UtenDepartmentTreeView))
          .selectedIds,
      {'engineering'},
    );
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  EmployeeRepository employees,
  Set<String> permissions,
) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue(permissions),
        departmentRepositoryProvider.overrideWithValue(
          _FakeDepartmentRepository(),
        ),
        employeeRepositoryProvider.overrideWithValue(employees),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DepartmentPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (find.byType(UtenDepartmentTreeView).evaluate().isEmpty) {
    await tester.tap(find.byIcon(Icons.account_tree_rounded));
    await tester.pumpAndSettle();
  }
  expect(find.byType(UtenDepartmentTreeView), findsOneWidget);
}

Finder _treeSearch() => find.descendant(
  of: find.byType(UtenDepartmentTreeView),
  matching: find.byType(TextField),
);

class _FakeDepartmentRepository implements DepartmentRepository {
  @override
  Future<List<DepartmentNode>> tree() async => _tree;

  @override
  Future<DepartmentInfo> detail(String id) async {
    final node = _tree
        .expand((root) => [root, ...root.children])
        .firstWhere((candidate) => candidate.id == id);
    return DepartmentInfo(
      id: node.id,
      code: node.code,
      name: node.name,
      level: node.level,
      path: node.name,
      childCount: 0,
      employeeCount: 0,
    );
  }

  @override
  Future<WorkforceOverview> workforceOverview(String id) async =>
      WorkforceOverview.fromJson({
        'organizationId': id,
        'organizationName': id,
      });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmployeeCall {
  const _EmployeeCall(this.search, this.statuses, this.departmentId);
  final String? search;
  final Set<String>? statuses;
  final String? departmentId;
}

class _RecordingEmployeeRepository implements EmployeeRepository {
  final calls = <_EmployeeCall>[];

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
  }) async {
    calls.add(_EmployeeCall(search, statuses, departmentId));
    final items = search == 'E-100'
        ? const [
            EmployeeSummary(
              id: 'employee',
              code: 'E-100',
              fullName: '张三',
              departmentId: 'sales',
              departmentName: '销售部',
            ),
          ]
        : const <EmployeeSummary>[];
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: items.isEmpty ? 0 : 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DeferredEmployeeRepository implements EmployeeRepository {
  final _old = Completer<PagedResult<EmployeeSummary>>();
  bool oldRequested = false;

  void completeOld() => _old.complete(
    const PagedResult(
      items: [
        EmployeeSummary(
          id: 'old',
          code: 'OLD',
          fullName: '旧员工',
          departmentId: 'sales',
          departmentName: '销售部',
        ),
      ],
      page: 1,
      size: 100,
      total: 1,
      totalPages: 1,
    ),
  );

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
  }) {
    if (search == 'OLD' && departmentId == null) {
      oldRequested = true;
      return _old.future;
    }
    final items = search == 'NEW'
        ? const [
            EmployeeSummary(
              id: 'new',
              code: 'NEW',
              fullName: '新员工',
              departmentId: 'engineering',
              departmentName: '工程部',
            ),
          ]
        : const <EmployeeSummary>[];
    return Future.value(
      PagedResult(
        items: items,
        page: page,
        size: size,
        total: items.length,
        totalPages: items.isEmpty ? 0 : 1,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _tree = [
  DepartmentNode(
    id: 'root',
    code: 'ROOT',
    name: '公司',
    level: '公司',
    children: [
      DepartmentNode(
        id: 'sales',
        code: 'SALES',
        name: '销售部',
        level: '一级部门',
        parentId: 'root',
        children: const [],
      ),
      DepartmentNode(
        id: 'engineering',
        code: 'ENG',
        name: '工程部',
        level: '一级部门',
        parentId: 'root',
        children: const [],
      ),
    ],
  ),
];
