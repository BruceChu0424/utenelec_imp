import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_field_placeholder.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_month_field.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  test('字段名优先，普通请求词清除，真实搜索范围和字段语义保留', () {
    expect(utenFieldPlaceholder(label: '颜色', hint: '请选择颜色'), '颜色');
    expect(utenFieldPlaceholder(label: '输入方式'), '输入方式');
    expect(utenFieldPlaceholder(label: '货品名称 *'), '货品名称');
    expect(utenFieldPlaceholder(hint: '请输入姓名'), '姓名');
    expect(utenFieldPlaceholder(label: 'Input mode'), 'Input mode');
    expect(utenFieldPlaceholder(hint: 'Please enter name'), 'name');
    expect(utenFieldPlaceholder(hint: '搜索名称 / 编号'), '搜索名称 / 编号');
    expect(utenFieldPlaceholder(hint: '请选择', fallback: '员工'), '员工');
  });

  test('明确的筛选状态例外经copyWith和主题解析后仍保留', () {
    const decoration = UtenInputDecoration(
      InputDecoration(labelText: '仓库', hintText: '全部'),
      useFieldNameHint: false,
    );
    final resolved = decoration
        .copyWith(enabled: false)
        .applyDefaults(buildLightTheme().inputDecorationTheme);
    expect(resolved.hintText, '全部');
    expect(resolved.useFieldNameHint, isFalse);
    expect(resolved.enabled, isFalse);
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('空文本、下拉、日期和年月以框内字段名显示 dark=$dark scale=$scale', (
        tester,
      ) async {
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(
          _host(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenInput(
                  label: '颜色',
                  hint: '请选择颜色',
                  required: true,
                  focusNode: focus,
                ),
                UtenDropdownField(
                  label: '所属仓库',
                  value: null,
                  hintText: '请选择所属仓库',
                  items: const [UtenDropdownItem(value: 'w1', label: '成品仓')],
                  onChanged: (_) {},
                ),
                UtenDateField(label: '交货日期', value: null, onChanged: (_) {}),
                UtenMonthField(label: '制造年月', value: null, onChanged: (_) {}),
              ],
            ),
            dark: dark,
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        final semantics = tester.ensureSemantics();
        try {
          final decorations = tester
              .widgetList<InputDecorator>(find.byType(InputDecorator))
              .toList();
          expect(decorations.map((field) => field.decoration.hintText), [
            '颜色',
            '所属仓库',
            '交货日期',
            '制造年月',
          ]);
          expect(decorations.every((field) => field.isEmpty), isTrue);
          expect(find.text('请选择'), findsNothing);
          expect(find.text('未选择'), findsNothing);
          expect(find.bySemanticsLabel(RegExp('所属仓库')), findsWidgets);
          final warehouse = tester.widget<InputDecorator>(
            find.descendant(
              of: find.byType(UtenDropdownField),
              matching: find.byType(InputDecorator),
            ),
          );
          expect(
            warehouse.decoration.floatingLabelBehavior,
            FloatingLabelBehavior.auto,
          );
          focus.requestFocus();
          await tester.pumpAndSettle();
          final hint = find.text('颜色');
          expect(hint, findsOneWidget);
          expect(
            tester
                .widgetList<AnimatedOpacity>(
                  find.ancestor(
                    of: hint,
                    matching: find.byType(AnimatedOpacity),
                  ),
                )
                .any((opacity) => opacity.opacity == 1),
            isTrue,
          );
          final rect = tester.getRect(find.byType(UtenInput));
          expect(rect.contains(tester.getCenter(hint)), isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('格式样例进入框内说明，普通字段不再只剩浮动小标签', (tester) async {
    await tester.pumpWidget(
      _host(
        const TextField(
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText: '制造年月',
              hintText: '如 2018-07',
              floatingLabelBehavior: FloatingLabelBehavior.always,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final decoration = tester
        .widget<InputDecorator>(find.byType(InputDecorator))
        .decoration;
    expect(decoration.hintText, '制造年月');
    expect(decoration.floatingLabelBehavior, FloatingLabelBehavior.auto);
    expect(find.byTooltip('如 2018-07'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pump();
    expect(find.text('如 2018-07'), findsOneWidget);
  });

  testWidgets('清空下拉后恢复字段名，禁用字段保持值和说明可读', (tester) async {
    String? value = 'w1';
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              UtenDropdownField(
                label: '仓库',
                value: value,
                items: const [UtenDropdownItem(value: 'w1', label: '成品仓')],
                onChanged: (next) => setState(() => value = next),
              ),
              UtenInput(
                label: '受控编号',
                enabled: false,
                controller: controller,
                info: '由系统分配',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不选'));
    await tester.pumpAndSettle();
    expect(value, isNull);
    final dropdown = tester.widget<InputDecorator>(
      find.descendant(
        of: find.byType(UtenDropdownField),
        matching: find.byType(InputDecorator),
      ),
    );
    expect(dropdown.isEmpty, isTrue);
    expect(dropdown.decoration.hintText, '仓库');
    final disabled = tester.widget<InputDecorator>(
      find.descendant(
        of: find.byType(UtenInput),
        matching: find.byType(InputDecorator),
      ),
    );
    expect(disabled.decoration.hintText, '受控编号');
    expect(disabled.decoration.enabled, isFalse);
    await tester.tap(find.byTooltip('由系统分配'));
    await tester.pump();
    expect(find.text('由系统分配'), findsOneWidget);
    expect(controller.text, isEmpty);
  });
}

Widget _host(Widget child, {bool dark = false, double scale = 1}) =>
    ProviderScope(
      child: MaterialApp(
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Center(
              child: SizedBox(
                width: 360,
                child: SingleChildScrollView(child: child),
              ),
            ),
          ),
        ),
      ),
    );
