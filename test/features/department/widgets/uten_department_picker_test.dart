import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';

void main() {
  test('默认人事策略可选管理中心，车间策略排除管理中心', () {
    final tree = _organizationTree();

    final workforce = buildDeptSelectionMap(tree);
    expect(workforce.keys, containsAll(['center', 'department', 'team']));
    expect(workforce['center']!.fullPath, '制造与研发管理中心');
    expect(workforce['department']!.fullPath, '制造与研发管理中心-生产部');

    final workshop = buildDeptSelectionMap(
      tree,
      selectablePredicate: isBusinessDepartmentNode,
    );
    expect(workshop, isNot(contains('center')));
    expect(workshop.keys, containsAll(['department', 'team']));
    expect(workshop['department']!.fullPath, '生产部');
  });

  testWidgets('单选在确认前只更新草稿，确认后完整路径稳定回填', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    String? selectedId;
    var changedCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setParentState) => UtenDepartmentPicker(
              key: const Key('department-picker'),
              mode: UtenDepartmentPickerMode.single,
              treeOverride: _organizationTree(),
              expandOnRowTap: true,
              allowClear: true,
              clearLabel: '显示全部可管理范围',
              initialSelection: selectedId == null
                  ? const []
                  : [
                      DeptSelection(
                        id: selectedId!,
                        name: '',
                        fullPath: '',
                        level: '',
                      ),
                    ],
              onChanged: (selection) {
                changedCalls++;
                setParentState(
                  () => selectedId = selection.isEmpty
                      ? null
                      : selection.first.id,
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(InputDecorator));
    await tester.pumpAndSettle();

    final treeView = find.byType(UtenDepartmentTreeView);
    final centerText = find.descendant(
      of: treeView,
      matching: find.text('制造与研发管理中心'),
    );
    final decisionText = find.descendant(
      of: treeView,
      matching: find.text('决策层'),
    );

    expect(centerText, findsOneWidget);
    await tester.tap(decisionText);
    await tester.pump();
    expect(centerText, findsNothing);
    expect(
      tester.widget<UtenDepartmentTreeView>(treeView).selectedIds,
      isEmpty,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
          .onPressed,
      isNull,
    );
    await tester.tap(decisionText);
    await tester.pump();
    await tester.tap(centerText);
    await tester.pump();

    expect(changedCalls, 0);
    expect(tester.widget<UtenDepartmentTreeView>(treeView).selectedIds, {
      'center',
    });

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(changedCalls, 1);
    expect(selectedId, 'center');
    expect(find.text('制造与研发管理中心'), findsOneWidget);

    expect(find.byTooltip('显示全部可管理范围'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('uten-department-picker-clear')),
    );
    await tester.pump();

    expect(changedCalls, 2);
    expect(selectedId, isNull);
    expect(find.text('请选择部门'), findsOneWidget);
  });
}

List<DepartmentNode> _organizationTree() => [
  DepartmentNode(
    id: 'company',
    code: 'ROOT',
    name: '优腾电器',
    level: kCompanyDepartmentLevel,
    children: [
      DepartmentNode(
        id: 'decision',
        code: 'DECISION',
        name: '决策层',
        level: '决策层',
        parentId: 'company',
        children: [
          DepartmentNode(
            id: 'center',
            code: 'MFG_CENTER',
            name: '制造与研发管理中心',
            level: '管理中心',
            parentId: 'decision',
            children: [
              DepartmentNode(
                id: 'department',
                code: 'DEPT_PROD',
                name: '生产部',
                level: '一级部门',
                parentId: 'center',
                children: [
                  DepartmentNode(
                    id: 'team',
                    code: 'WS_ASSEMBLY',
                    name: '装配车间',
                    level: '二级班组',
                    parentId: 'department',
                    children: const [],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  ),
];
