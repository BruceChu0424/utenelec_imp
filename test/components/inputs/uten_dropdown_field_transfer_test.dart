// 2026-09-16 回归锁：报工页「产出去向」格 = UtenDropdownField 两选项、
// 「转下一道工序」按候选条件启用。有候选时必须能打开菜单并选中 WORKSHOP；
// 无候选时保持禁选且点了不回值——用户实测「明明有父工单却转不了」时，
// 服务端与数据均已验证正常，用这条测试钉死客户端交互。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  testWidgets('有候选时「转下一道工序」可打开菜单并选中', (tester) async {
    String? selected;
    await _pump(tester, canTransfer: true, onChanged: (v) => selected = v);
    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    expect(find.text('转下一道工序'), findsOneWidget);
    await tester.tap(find.text('转下一道工序'));
    await tester.pumpAndSettle();
    expect(selected, 'WORKSHOP');
  });

  testWidgets('无候选时「转下一道工序」禁选，点了不回值', (tester) async {
    String? selected;
    await _pump(tester, canTransfer: false, onChanged: (v) => selected = v);
    await tester.tap(find.byType(UtenDropdownField));
    await tester.pumpAndSettle();
    expect(find.text('转下一道工序(无同车间上层工单)'), findsOneWidget);
    await tester.tap(find.text('转下一道工序(无同车间上层工单)'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required bool canTransfer,
  required ValueChanged<String?> onChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 185,
            child: ValueListenableBuilder<String>(
              valueListenable: ValueNotifier('WAREHOUSE'),
              builder: (context, value, _) => UtenDropdownField(
                dense: true,
                value: value,
                items: [
                  const UtenDropdownItem(value: 'WAREHOUSE', label: '送入仓库'),
                  UtenDropdownItem(
                    value: 'WORKSHOP',
                    enabled: canTransfer,
                    label: canTransfer ? '转下一道工序' : '转下一道工序(无同车间上层工单)',
                  ),
                ],
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
