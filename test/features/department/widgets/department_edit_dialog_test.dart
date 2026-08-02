import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/department_edit_dialog.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/uten_location_field.dart';

void main() {
  testWidgets('管理中心编辑时不显示负责人选择器且不加载候选', (tester) async {
    var loadCalls = 0;
    DepartmentEditResult? submitted;

    await _pumpWideApp(
      tester,
      editing: _department(
        id: 'marketing-center',
        code: 'MKT_CENTER',
        name: '营销与新媒体管理中心',
        level: '管理中心',
        childCount: 2,
      ),
      managerLoader: (_) async {
        loadCalls++;
        return const [
          UtenEmployeePickerItem(
            id: 'employee-1',
            name: '张三',
            departmentName: '综合营销部',
          ),
        ];
      },
      onSubmit: (result) async {
        submitted = result;
        return true;
      },
    );

    expect(find.byType(UtenEmployeePicker), findsNothing);
    expect(find.text('部门负责人'), findsNothing);
    expect(
      find.text('此节点是组织骨架，上级部门不可更改，也不设置部门负责人；请在下级业务部门设置。'),
      findsOneWidget,
    );
    expect(loadCalls, 0);

    final locationField = tester.widget<UtenLocationField>(
      find.byType(UtenLocationField),
    );
    expect(locationField.enabled, isFalse);
    expect(find.text('管理中心'), findsOneWidget);

    await tester.tap(find.byType(UtenLocationField));
    await tester.pumpAndSettle();

    expect(find.text('选择上级部门'), findsNothing);

    await tester.enterText(_textFieldWithLabel('名称'), '营销管理中心');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(submitted!.name, '营销管理中心');
    expect(submitted!.parentId, isNull);
    expect(submitted!.managerId, isNull);
    expect(submitted!.level, '管理中心');
  });

  testWidgets('一级部门无直属在册员工时在宽屏右滑窗说明空候选原因', (tester) async {
    final loadedKeywords = <String?>[];

    await _pumpWideApp(
      tester,
      editing: _department(
        id: 'pmc-department',
        code: 'DEPT_PMC',
        name: 'PMC运营部',
        level: '一级部门',
      ),
      managerLoader: (keyword) async {
        loadedKeywords.add(keyword);
        return const [];
      },
    );

    expect(find.byType(UtenEmployeePicker), findsOneWidget);

    await tester.tap(find.text('从本部门直属在册员工中选择'));
    await tester.pumpAndSettle();

    expect(loadedKeywords, [null]);
    expect(find.text('选择部门负责人'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox &&
            widget.width == 420 &&
            widget.height == double.infinity,
      ),
      findsOneWidget,
    );
    expect(find.text('本部门暂无可选负责人'), findsOneWidget);
    expect(find.text('负责人只能从本部门直属在册员工中选择。请先添加或调入员工，再设置负责人。'), findsOneWidget);
    expect(find.text('未找到匹配的人员'), findsNothing);
  });

  testWidgets('编辑部门时上级选择先暂存，确定后仍可改名并设置负责人', (tester) async {
    DepartmentEditResult? submitted;

    await _pumpWideApp(
      tester,
      tree: [_companyWithManagementCenters()],
      editing: _department(
        id: 'sales-department',
        code: 'DEPT_SALES',
        name: '综合营销部',
        level: '一级部门',
        parentId: 'marketing-center',
        parentName: '营销与新媒体管理中心',
      ),
      managerLoader: (_) async => const [
        UtenEmployeePickerItem(
          id: 'employee-1',
          name: '张三',
          departmentName: '综合营销部',
        ),
      ],
      onSubmit: (result) async {
        submitted = result;
        return true;
      },
    );

    await tester.tap(find.byType(UtenLocationField));
    await tester.pumpAndSettle();

    await tester.tap(find.text('制造与研发管理中心'));
    await tester.pump();

    expect(find.text('选择上级部门'), findsOneWidget);
    expect(
      tester
          .widget<UtenDepartmentTreeView>(find.byType(UtenDepartmentTreeView))
          .selectedIds,
      {'manufacturing-center'},
    );

    await tester.tap(_pickerSheetAction('取消'));
    await tester.pumpAndSettle();

    expect(find.text('营销与新媒体管理中心'), findsOneWidget);
    expect(find.text('制造与研发管理中心'), findsNothing);

    await tester.tap(find.byType(UtenLocationField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('制造与研发管理中心'));
    await tester.pump();
    await tester.tap(_pickerSheetAction('确定'));
    await tester.pumpAndSettle();

    expect(find.text('制造与研发管理中心'), findsOneWidget);

    await tester.enterText(_textFieldWithLabel('名称'), '渠道营销部');
    await tester.tap(find.text('从本部门直属在册员工中选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('张三'));
    await tester.pumpAndSettle();

    expect(find.textContaining('张三'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(submitted!.parentId, 'manufacturing-center');
    expect(submitted!.name, '渠道营销部');
    expect(submitted!.managerId, 'employee-1');
  });
}

Future<void> _pumpWideApp(
  WidgetTester tester, {
  required DepartmentInfo editing,
  required UtenEmployeePickerLoader managerLoader,
  List<DepartmentNode>? tree,
  Future<bool> Function(DepartmentEditResult result)? onSubmit,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => DepartmentEditDialog(
                    tree: tree ?? [_company()],
                    editing: editing,
                    managerLoader: managerLoader,
                    onSubmit: onSubmit ?? (_) async => true,
                  ),
                ),
                child: const Text('打开部门编辑'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('打开部门编辑'));
  await tester.pumpAndSettle();
}

DepartmentNode _company() => DepartmentNode(
  id: 'company',
  code: 'ROOT',
  name: '优腾电器',
  level: kCompanyDepartmentLevel,
  children: const [],
);

DepartmentNode _companyWithManagementCenters() => DepartmentNode(
  id: 'company',
  code: 'ROOT',
  name: '优腾电器',
  level: kCompanyDepartmentLevel,
  children: [
    DepartmentNode(
      id: 'marketing-center',
      code: 'MKT_CENTER',
      name: '营销与新媒体管理中心',
      level: '管理中心',
      parentId: 'company',
      children: [
        DepartmentNode(
          id: 'sales-department',
          code: 'DEPT_SALES',
          name: '综合营销部',
          level: '一级部门',
          parentId: 'marketing-center',
          children: const [],
        ),
      ],
    ),
    DepartmentNode(
      id: 'manufacturing-center',
      code: 'MFG_CENTER',
      name: '制造与研发管理中心',
      level: '管理中心',
      parentId: 'company',
      children: const [],
    ),
  ],
);

DepartmentInfo _department({
  required String id,
  required String code,
  required String name,
  required String level,
  int childCount = 0,
  String? parentId = 'company',
  String? parentName = '优腾电器',
}) => DepartmentInfo(
  id: id,
  code: code,
  name: name,
  level: level,
  parentId: parentId,
  parentName: parentName,
  path: '${parentName ?? '公司'}/$name',
  childCount: childCount,
  employeeCount: 0,
);

Finder _pickerSheetAction(String label) {
  final sheet = find.byWidgetPredicate(
    (widget) =>
        widget is SizedBox &&
        widget.width == 420 &&
        widget.height == double.infinity,
  );
  return find.descendant(of: sheet, matching: find.text(label));
}

Finder _textFieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);
