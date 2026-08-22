// 部门编辑保存后右侧详情面板刷新回归测试。
//
// 背景：部门页 _doUpdate 只 _load() 重拉组织树；DepartmentOverviewPane 以
// node.id 判断是否需要重载，树整体换新但 id 不变时详情卡（名称/负责人）
// 停在编辑前的旧数据——须手动刷新。修复：pane 的 didUpdateWidget 在
// 树节点对象被替换（!identical）时也重载。本测试锁死该行为。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/models/workforce_overview.dart';
import 'package:uten_imp/features/department/pages/department_page.dart';
import 'package:uten_imp/features/department/repositories/department_repository.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('部门编辑保存后详情卡自动重载显示新名称（无需手动刷新）', (tester) async {
    final departments = _FakeDepartmentRepository();
    await _pumpPage(tester, departments);

    // 选中「销售部」→ 详情卡加载（第 1 次 detail）。
    await tester.tap(find.text('销售部'));
    await tester.pumpAndSettle();
    expect(departments.detailCalls('sales'), 1);

    // 打开编辑弹窗：改名 → 保存。
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == '销售部',
      ),
      '销售一部',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 保存后：树与详情卡都显示新名称；详情卡是重拉的（第 2 次 detail），
    // 不是残留旧 State。
    expect(departments.detailCalls('sales'), 2);
    expect(find.text('销售一部'), findsWidgets);
    expect(find.text('销售部'), findsNothing);
  });
  testWidgets('总经办隐藏删除入口，普通一级部门仍可删除', (tester) async {
    final departments = _FakeDepartmentRepository();
    await _pumpPage(tester, departments);

    expect(find.byTooltip('删除 总经办'), findsNothing);
    expect(find.byTooltip('删除 销售部'), findsOneWidget);

    await tester.tap(find.text('总经办'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsNothing);

    if (find.text('销售部').evaluate().isEmpty) {
      await tester.tap(find.byIcon(Icons.account_tree_rounded));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('销售部'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  _FakeDepartmentRepository departments,
) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({
          Perm.departmentView,
          Perm.departmentEdit,
          Perm.departmentDelete,
        }),
        departmentRepositoryProvider.overrideWithValue(departments),
        employeeRepositoryProvider.overrideWithValue(_FakeEmployeeRepository()),
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
}

/// 记录 detail 调用次数的假部门仓储：update 会真实改名，模拟服务端已生效。
class _FakeDepartmentRepository implements DepartmentRepository {
  final _tree = <DepartmentNode>[
    DepartmentNode(
      id: 'root',
      code: 'ROOT',
      name: '公司',
      level: '公司',
      children: [
        DepartmentNode(
          id: 'general-manager-office',
          code: kCompanyExecutiveOfficeCode,
          name: '总经办',
          level: '一级部门',
          parentId: 'root',
          children: const [],
        ),
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
  final _detailCalls = <String, int>{};

  int detailCalls(String id) => _detailCalls[id] ?? 0;

  DepartmentNode _node(String id) => _tree
      .expand((root) => [root, ...root.children])
      .firstWhere((candidate) => candidate.id == id);

  @override
  Future<List<DepartmentNode>> tree() async => _tree;

  @override
  Future<DepartmentInfo> detail(String id) async {
    _detailCalls[id] = (_detailCalls[id] ?? 0) + 1;
    final node = _node(id);
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
  Future<DepartmentInfo> update(String id, DepartmentUpdateInput input) async {
    final node = _node(id);
    final replacement = DepartmentNode(
      id: node.id,
      code: node.code,
      name: input.name,
      level: node.level,
      parentId: node.parentId,
      children: node.children,
    );
    final children = _tree.first.children;
    _tree[0] = DepartmentNode(
      id: 'root',
      code: 'ROOT',
      name: '公司',
      level: '公司',
      children: [
        for (final child in children) child.id == id ? replacement : child,
      ],
    );
    // 注意：直接构造返回值，不走 detail() —— 调用计数只反映页面真实的详情重拉。
    return DepartmentInfo(
      id: replacement.id,
      code: replacement.code,
      name: replacement.name,
      level: replacement.level,
      path: replacement.name,
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

/// 编辑弹窗的负责人候选加载会打到员工仓储：返回空页即可。
class _FakeEmployeeRepository implements EmployeeRepository {
  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
  }) async => PagedResult(
    items: const [],
    page: page,
    size: size,
    total: 0,
    totalPages: 0,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
