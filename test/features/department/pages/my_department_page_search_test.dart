import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/models/my_department.dart';
import 'package:uten_imp/features/department/pages/my_department_page.dart';
import 'package:uten_imp/features/department/repositories/my_department_repository.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('左侧按员工工号搜索会展开并选中员工所在部门', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          myDepartmentRepositoryProvider.overrideWithValue(
            _FakeMyDepartmentRepository(),
          ),
        ],
        child: const MaterialApp(home: MyDepartmentPage()),
      ),
    );
    await tester.pumpAndSettle();

    if (find.byType(UtenDepartmentTreeView).evaluate().isEmpty) {
      await tester.tap(find.byTooltip('部门列表'));
      await tester.pumpAndSettle();
    }
    final treeFinder = find.byType(UtenDepartmentTreeView);
    expect(treeFinder, findsOneWidget);
    final searchField = find.descendant(
      of: treeFinder,
      matching: find.byType(TextField),
    );
    final searchController = tester.widget<TextField>(searchField).controller!;

    await tester.enterText(searchField, 'e-alpha');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    final tree = tester.widget<UtenDepartmentTreeView>(treeFinder);
    expect(tree.selectedIds, const {'production'});
    expect(find.text('张三'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(UtenDepartmentTreeView),
        matching: find.text('制造中心'),
      ),
    );
    await tester.pumpAndSettle();

    expect(searchController.text, 'e-alpha');
    expect(find.text('张三'), findsOneWidget);
  });

  testWidgets('compact 按部门名搜索会定位部门并显示完整花名册', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          myDepartmentRepositoryProvider.overrideWithValue(
            _FakeMyDepartmentRepository(),
          ),
        ],
        child: const MaterialApp(home: MyDepartmentPage()),
      ),
    );
    await tester.pumpAndSettle();

    final compactSearch = find.descendant(
      of: find.byKey(const ValueKey('my-department-compact-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(compactSearch, '生产部');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('张三'), findsOneWidget);
    expect(find.textContaining('未找到匹配'), findsNothing);
    expect(find.textContaining('匹配员工 0'), findsNothing);
  });

  testWidgets('较早的员工搜索响应不会覆盖较新的定位结果', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = _DelayedMyDepartmentRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          myDepartmentRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: MyDepartmentPage()),
      ),
    );
    await tester.pumpAndSettle();
    if (find.byType(UtenDepartmentTreeView).evaluate().isEmpty) {
      await tester.tap(find.byTooltip('部门列表'));
      await tester.pumpAndSettle();
    }
    final search = find.descendant(
      of: find.byType(UtenDepartmentTreeView),
      matching: find.byType(TextField),
    );

    await tester.enterText(search, 'E-Alpha');
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.pendingSearches, hasLength(1));
    await tester.enterText(search, 'E-Beta');
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.pendingSearches, hasLength(2));

    repository.pendingSearches[1].complete(
      _DelayedMyDepartmentRepository.branchRoster(const [
        _DelayedMyDepartmentRepository.beta,
      ]),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenDepartmentTreeView>(find.byType(UtenDepartmentTreeView))
          .selectedIds,
      const {'finance'},
    );
    expect(find.text('李四'), findsOneWidget);

    repository.pendingSearches[0].complete(
      _DelayedMyDepartmentRepository.branchRoster(const [
        _DelayedMyDepartmentRepository.alpha,
      ]),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenDepartmentTreeView>(find.byType(UtenDepartmentTreeView))
          .selectedIds,
      const {'finance'},
    );
    expect(find.text('李四'), findsOneWidget);
    expect(find.text('张三'), findsNothing);
  });
}

class _FakeMyDepartmentRepository extends MyDepartmentRepository {
  _FakeMyDepartmentRepository() : super(ApiClient(Dio()));

  static final DepartmentNode _production = DepartmentNode(
    id: 'production',
    code: 'DEPT_PROD',
    name: '生产部',
    level: '一级部门',
    parentId: 'center',
    children: const [],
  );

  static final DepartmentNode _center = DepartmentNode(
    id: 'center',
    code: 'MFG_CENTER',
    name: '制造中心',
    level: '管理中心',
    children: [_production],
  );

  static const MyDepartmentStaffRow _employee = MyDepartmentStaffRow(
    employeeId: 'employee-1',
    departmentId: 'production',
    code: 'E-Alpha',
    fullName: '张三',
    departmentName: '生产部',
  );

  @override
  Future<List<DepartmentNode>> myBranchTree() async => [_center];

  @override
  Future<MyDepartmentRoster> roster(String departmentId) async =>
      MyDepartmentRoster(
        departmentId: departmentId,
        departmentName: departmentId == 'center' ? '制造中心' : '生产部',
        staff: const [_employee],
      );
}

class _DelayedMyDepartmentRepository extends MyDepartmentRepository {
  _DelayedMyDepartmentRepository() : super(ApiClient(Dio()));

  final pendingSearches = <Completer<MyDepartmentRoster>>[];
  var _rootRosterReads = 0;

  static final DepartmentNode production = DepartmentNode(
    id: 'production',
    code: 'DEPT_PROD',
    name: '生产部',
    level: '一级部门',
    parentId: 'center',
    children: const [],
  );
  static final DepartmentNode finance = DepartmentNode(
    id: 'finance',
    code: 'DEPT_FIN',
    name: '财务部',
    level: '一级部门',
    parentId: 'center',
    children: const [],
  );
  static final DepartmentNode center = DepartmentNode(
    id: 'center',
    code: 'MFG_CENTER',
    name: '制造中心',
    level: '管理中心',
    children: [production, finance],
  );
  static const alpha = MyDepartmentStaffRow(
    employeeId: 'employee-alpha',
    departmentId: 'production',
    code: 'E-Alpha',
    fullName: '张三',
    departmentName: '生产部',
  );
  static const beta = MyDepartmentStaffRow(
    employeeId: 'employee-beta',
    departmentId: 'finance',
    code: 'E-Beta',
    fullName: '李四',
    departmentName: '财务部',
  );

  static MyDepartmentRoster branchRoster(List<MyDepartmentStaffRow> staff) =>
      MyDepartmentRoster(
        departmentId: 'center',
        departmentName: '制造中心',
        staff: staff,
      );

  @override
  Future<List<DepartmentNode>> myBranchTree() async => [center];

  @override
  Future<MyDepartmentRoster> roster(String departmentId) {
    if (departmentId == 'center' && _rootRosterReads++ > 0) {
      final completer = Completer<MyDepartmentRoster>();
      pendingSearches.add(completer);
      return completer.future;
    }
    final staff = departmentId == 'production'
        ? const [alpha]
        : departmentId == 'finance'
        ? const [beta]
        : const [alpha, beta];
    return Future.value(
      MyDepartmentRoster(
        departmentId: departmentId,
        departmentName: departmentId,
        staff: staff,
      ),
    );
  }
}
