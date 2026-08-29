import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/department_employee_picker.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets('统一左侧搜索员工后展开所属部门并在右侧显示结果', (tester) async {
    final repository = _FakeEmployeeRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _tree,
          ),
          employeeRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: _Harness()),
      ),
    );

    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();

    final searchFields = find.descendant(
      of: find.byType(UtenDepartmentTreeView),
      matching: find.byType(TextField),
    );
    expect(searchFields, findsOneWidget);
    expect(
      tester.widget<TextField>(searchFields).decoration?.hintText,
      '搜索部门/员工姓名或工号',
    );

    await tester.enterText(searchFields, 'E-100');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    final tree = tester.widget<UtenDepartmentTreeView>(
      find.byType(UtenDepartmentTreeView),
    );
    expect(tree.visibleFilterIds, {'root', 'sales'});
    expect(tree.selectedIds, {'sales'});
    expect(find.text('张三(E-100)'), findsOneWidget);
    expect(repository.searches, contains('E-100'));
  });

  testWidgets('分页结果可继续加载并选择首屏之外的授权员工', (tester) async {
    final repository = _PagedEmployeeRepository();
    await _pumpPicker(tester, repository);

    final search = _pickerSearch(tester);
    await tester.enterText(search, 'E-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(find.text('第一页员工(E-001)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('department-employee-load-more')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('department-employee-load-more')),
    );
    await tester.pumpAndSettle();

    expect(find.text('第二页员工(E-101)'), findsOneWidget);
    expect(repository.requestedPages, containsAll(<int>[1, 2]));
  });

  testWidgets('纯部门命中点击仍保留左查询并浏览该部门全部员工', (tester) async {
    final repository = _FakeEmployeeRepository();
    await _pumpPicker(tester, repository);

    final search = _pickerSearch(tester);
    await tester.enterText(search, 'SALES');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    final tree = find.byType(UtenDepartmentTreeView);
    await tester.tap(
      find.descendant(of: tree, matching: find.text('销售部')).first,
    );
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(search).controller?.text, 'SALES');
    expect(find.text('张三(E-100)'), findsOneWidget);
    expect(repository.departmentIds.last, 'sales');
    expect(repository.searches.last, isNull);
  });

  testWidgets('继续输入会在防抖窗口内立即阻止旧员工结果回写', (tester) async {
    final repository = _DeferredEmployeeRepository();
    await _pumpPicker(tester, repository);

    final search = _pickerSearch(tester);
    await tester.enterText(search, 'OLD');
    await tester.pump(const Duration(milliseconds: 301));
    expect(repository.oldRequested, isTrue);

    await tester.enterText(search, 'NEW');
    repository.completeOld();
    await tester.pump();
    expect(find.text('旧员工(OLD)'), findsNothing);

    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('新员工(NEW)'), findsOneWidget);
    expect(find.text('旧员工(OLD)'), findsNothing);
  });
}

Future<void> _pumpPicker(
  WidgetTester tester,
  EmployeeRepository repository,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        employeePickerDepartmentTreeProvider.overrideWith((ref) async => _tree),
        employeeRepositoryProvider.overrideWithValue(repository),
      ],
      child: const MaterialApp(home: _Harness()),
    ),
  );
  await tester.tap(find.text('打开选择器'));
  await tester.pumpAndSettle();
}

Finder _pickerSearch(WidgetTester tester) => find.descendant(
  of: find.byType(UtenDepartmentTreeView),
  matching: find.byType(TextField),
);

class _Harness extends ConsumerWidget {
  const _Harness();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: FilledButton(
      onPressed: () => showUtenDepartmentEmployeePicker(context, ref),
      child: const Text('打开选择器'),
    ),
  );
}

class _FakeEmployeeRepository implements EmployeeRepository {
  final searches = <String?>[];
  final departmentIds = <String?>[];

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    searches.add(search);
    departmentIds.add(departmentId);
    final items = search == 'E-100' || departmentId == 'sales'
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
      totalPages: 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PagedEmployeeRepository implements EmployeeRepository {
  final requestedPages = <int>[];

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    requestedPages.add(page);
    final employee = page == 1
        ? const EmployeeSummary(
            id: 'first',
            code: 'E-001',
            fullName: '第一页员工',
            departmentId: 'sales',
            departmentName: '销售部',
          )
        : const EmployeeSummary(
            id: 'second',
            code: 'E-101',
            fullName: '第二页员工',
            departmentId: 'sales',
            departmentName: '销售部',
          );
    return PagedResult(
      items: [employee],
      page: page,
      size: size,
      total: 101,
      totalPages: 2,
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
  }) {
    if (search == 'OLD') {
      oldRequested = true;
      return _old.future;
    }
    if (search == 'NEW') {
      return Future.value(
        PagedResult(
          items: const [
            EmployeeSummary(
              id: 'new',
              code: 'NEW',
              fullName: '新员工',
              departmentId: 'sales',
              departmentName: '销售部',
            ),
          ],
          page: page,
          size: size,
          total: 1,
          totalPages: 1,
        ),
      );
    }
    return Future.value(
      PagedResult(
        items: const [],
        page: page,
        size: size,
        total: 0,
        totalPages: 0,
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
    ],
  ),
];
