import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';

void main() {
  testWidgets(
    'late initial selection synchronizes after the parent Form build without disturbing another input',
    (tester) async {
      final selection = ValueNotifier<List<DeptSelection>>(const []);
      final text = TextEditingController(text: '输入草稿');
      final focus = FocusNode();
      addTearDown(selection.dispose);
      addTearDown(text.dispose);
      addTearDown(focus.dispose);
      var selectedCallbacks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              child: Column(
                children: [
                  TextField(controller: text, focusNode: focus),
                  ValueListenableBuilder<List<DeptSelection>>(
                    valueListenable: selection,
                    builder: (_, value, _) => UtenDepartmentPicker(
                      mode: UtenDepartmentPickerMode.single,
                      treeOverride: const [],
                      initialSelection: value,
                      onChanged: (_) => selectedCallbacks++,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      const composing = TextEditingValue(
        text: '输入草稿 ',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 4, end: 5),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      final inputState = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      selection.value = const [
        DeptSelection(
          id: 'department',
          name: '后到的部门',
          fullPath: '公司-后到的部门',
          level: 'DEPARTMENT',
        ),
      ];
      await tester.pumpAndSettle();
      final formField = tester.state<FormFieldState<List<DeptSelection>>>(
        find.byType(FormField<List<DeptSelection>>),
      );
      expect(formField.value!.single.id, 'department');
      expect(find.text('公司-后到的部门'), findsOneWidget);
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(inputState),
      );
      expect(text.value, composing);
      expect(focus.hasFocus, isTrue);
      expect(
        selectedCallbacks,
        0,
        reason: 'Source readback is not a user selection command',
      );
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(
      centerText.hitTestable(),
      findsNothing,
      reason:
          'exiting children cannot receive selection during the short collapse fade',
    );
    await tester.pumpAndSettle();
    expect(centerText, findsNothing);
    expect(
      tester.widget<UtenDepartmentTreeView>(treeView).selectedIds,
      isEmpty,
    );
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确定'))
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
    expect(
      tester
          .widget<InputDecorator>(find.byType(InputDecorator))
          .decoration
          .hintText,
      '部门',
    );
    expect(
      tester.widget<InputDecorator>(find.byType(InputDecorator)).isEmpty,
      isTrue,
    );
  });

  for (final mode in UtenDepartmentPickerMode.values) {
    testWidgets('直接部门滑窗入口 $mode 选中暂存、取消保留初值、确定返回', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final tree = _organizationTree();
      final selections = buildDeptSelectionMap(tree);
      final initial = [selections['department']!];
      final results = <List<DeptSelection>?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => results.add(
                  await showUtenDepartmentPickerPanel(
                    context,
                    tree: tree,
                    mode: mode,
                    initialSelection: initial,
                    initiallyExpandedIds: const {'decision', 'center'},
                  ),
                ),
                child: const Text('打开部门'),
              ),
            ),
          ),
        ),
      );
      Future<void> selectCenter() async {
        await tester.tap(find.text('打开部门'));
        await tester.pumpAndSettle();
        final treeView = find.byType(UtenDepartmentTreeView);
        expect(tester.widget<UtenDepartmentTreeView>(treeView).selectedIds, {
          'department',
        });
        await tester.tap(
          find.descendant(of: treeView, matching: find.text('制造与研发管理中心')),
        );
        await tester.pump();
        expect(tester.widget<UtenDepartmentTreeView>(treeView).selectedIds, {
          if (mode == UtenDepartmentPickerMode.multi) 'department',
          'center',
        });
      }

      await selectCenter();
      expect(results, isEmpty);
      await tester.tap(find.widgetWithText(UtenButton, '取消'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      expect(initial.map((selection) => selection.id), ['department']);
      await selectCenter();
      expect(results, [null]);
      await tester.tap(
        find.widgetWithText(
          UtenButton,
          mode == UtenDepartmentPickerMode.multi ? '确定(2)' : '确定',
        ),
      );
      await tester.pumpAndSettle();
      expect(results.last!.map((selection) => selection.id), [
        if (mode == UtenDepartmentPickerMode.multi) 'department',
        'center',
      ]);
    });
  }

  testWidgets('部门初值必须仍存在并满足当前选择策略', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    List<DeptSelection>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showUtenDepartmentPickerPanel(
                    context,
                    tree: _organizationTree(),
                    selectablePredicate: isBusinessDepartmentNode,
                    initiallyExpandedIds: const {'decision', 'center'},
                    initialSelection: const [
                      DeptSelection(
                        id: 'missing',
                        name: '已删',
                        fullPath: '旧路径',
                        level: '',
                      ),
                      DeptSelection(
                        id: 'center',
                        name: '不允许的中心',
                        fullPath: '',
                        level: '',
                      ),
                    ],
                  ),
              child: const Text('打开部门'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开部门'));
    await tester.pumpAndSettle();
    final treeView = find.byType(UtenDepartmentTreeView);
    expect(
      tester.widget<UtenDepartmentTreeView>(treeView).selectedIds,
      isEmpty,
    );
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确定'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.descendant(of: treeView, matching: find.text('生产部')));
    await tester.pump();
    expect(result, isNull);
    await tester.tap(find.widgetWithText(UtenButton, '确定'));
    await tester.pumpAndSettle();
    expect(result!.single.id, 'department');
    expect(result!.single.fullPath, '生产部');
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
