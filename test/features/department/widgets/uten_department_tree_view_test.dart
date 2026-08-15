import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';

void main() {
  testWidgets('内部搜索大小写不敏感地匹配部门编号并展开路径', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenDepartmentTreeView(
            nodes: _tree(),
            showCompanyRoot: true,
            searchFieldKey: const Key('department-tree-search'),
            nodeEnabledPredicate: (_) => true,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('department-tree-search')),
      'dept_prod',
    );
    await tester.pump();

    expect(find.text('优腾电器'), findsOneWidget);
    expect(find.text('生产部'), findsOneWidget);
    expect(find.text('财务部'), findsNothing);
  });

  testWidgets('外部关联搜索显示加载、无结果与失败反馈', (tester) async {
    Future<void> pump({required bool loading, String? error}) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenDepartmentTreeView(
              nodes: _tree(),
              showCompanyRoot: true,
              showSearch: false,
              visibleFilterIds: const {},
              externalSearchQuery: 'E001',
              externalSearchLoading: loading,
              externalSearchError: error,
            ),
          ),
        ),
      );
    }

    await pump(loading: true);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    await pump(loading: false);
    expect(find.text('未找到匹配「E001」的部门或员工'), findsOneWidget);

    await pump(loading: false, error: '员工搜索失败，请重试');
    expect(find.text('员工搜索失败，请重试'), findsOneWidget);
  });
}

List<DepartmentNode> _tree() => [
  DepartmentNode(
    id: 'company',
    code: 'ROOT',
    name: '优腾电器',
    level: kCompanyDepartmentLevel,
    children: [
      DepartmentNode(
        id: 'production',
        code: 'DEPT_PROD',
        name: '生产部',
        level: '一级部门',
        parentId: 'company',
        children: const [],
      ),
      DepartmentNode(
        id: 'finance',
        code: 'DEPT_FIN',
        name: '财务部',
        level: '一级部门',
        parentId: 'company',
        children: const [],
      ),
    ],
  ),
];
