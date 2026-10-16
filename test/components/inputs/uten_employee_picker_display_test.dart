import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/employee/widgets/department_employee_picker.dart';
import 'package:uten_imp/shared/formatters/employee_display.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  const employee = UtenEmployeePickerItem(
    id: 'employee-1',
    name: '张三',
    employeeCode: 'E001',
    departmentName: '销售部',
  );

  test('员工主展示统一使用姓名加 ASCII 半角工号括号', () {
    expect(employee.displayName, '张三(E001)');
    expect(formatEmployeeDisplayName('张三', 'E001'), '张三(E001)');
    expect(employee.displayName, isNot(contains('（')));
    expect(employee.displayName, isNot(contains('）')));
    expect(
      const UtenEmployeePickerItem(id: 'legacy', name: '历史员工').displayName,
      '历史员工',
    );
  });

  testWidgets('单选和多选员工字段与日期共用主题高度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: UtenControlTheme(
            child: Row(
              children: [
                Expanded(
                  child: UtenEmployeePicker(
                    label: '经办人',
                    initial: employee,
                    loader: (_) async => const [employee],
                    onChanged: (_) {},
                  ),
                ),
                Expanded(
                  child: UtenEmployeeMultiPicker(
                    label: '参与人',
                    loader: (_) async => const [employee],
                    onChanged: (_) {},
                  ),
                ),
                Expanded(
                  child: UtenDateField(
                    label: '交货日期',
                    value: DateTime(2026, 10, 15),
                    onChanged: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    double outlineHeight(Type picker) => tester
        .getSize(
          find
              .descendant(
                of: find.byType(picker),
                matching: find.byType(InputDecorator),
              )
              .first,
        )
        .height;
    expect(outlineHeight(UtenEmployeePicker), outlineHeight(UtenDateField));
    expect(
      outlineHeight(UtenEmployeeMultiPicker),
      outlineHeight(UtenDateField),
    );
  });

  testWidgets('单选已选值和弹窗主行显示姓名(工号)，部门显示在下一行', (tester) async {
    UtenEmployeePickerItem? changed;
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          home: Scaffold(
            body: UtenEmployeePicker(
              label: '业务员',
              initial: employee,
              loader: (_) async => const [employee],
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      ),
    );

    expect(find.text('张三(E001)'), findsOneWidget);
    expect(find.text('张三(销售部)'), findsNothing);

    await tester.tap(find.text('张三(E001)'));
    await tester.pumpAndSettle();

    final tileFinder = find.widgetWithText(ListTile, '张三(E001)');
    expect(tileFinder, findsOneWidget);
    final tile = tester.widget<ListTile>(tileFinder);
    expect((tile.subtitle! as Text).data, '销售部');

    await tester.tap(tileFinder);
    await tester.pump();
    expect(find.text('已选择：张三(E001)'), findsOneWidget);
    await tester.tap(find.widgetWithText(UtenButton, '确定'));
    await tester.pumpAndSettle();

    expect(changed?.id, 'employee-1');
    expect(find.text('张三(E001)'), findsOneWidget);
  });

  testWidgets('历史已选值会通过 loader 补齐工号', (tester) async {
    String? requestedKeyword;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenEmployeePicker(
            label: '负责人',
            initial: const UtenEmployeePickerItem(
              id: 'employee-1',
              name: '张三',
              departmentName: '销售部',
            ),
            loader: (keyword) async {
              requestedKeyword = keyword;
              return const [employee];
            },
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(requestedKeyword, '张三');
    expect(find.text('张三(E001)'), findsOneWidget);
  });

  testWidgets('多选已选标签同样显示姓名(工号)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenEmployeeMultiPicker(
            label: '通知人员',
            initialSelection: const [employee],
            loader: (_) async => const [employee],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('张三(E001)'), findsOneWidget);
    expect(find.text('张三'), findsNothing);
  });

  testWidgets('部门员工字段会为历史已选值补齐工号', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DepartmentEmployeePickerField(
            label: '保管人',
            hint: '请选择保管人',
            initialId: 'employee-1',
            initialName: '张三',
            initialLoader: (_) async => employee,
            onChanged: (_) {},
            onPick: () async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('张三(E001)'), findsOneWidget);
  });
}
