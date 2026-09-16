// 分类工具条（UtenFilterToolbar）分段的共用点选助手。
//
// 2026-09-14 起窄屏/放不下时工具条收成一颗「分类」下拉按钮（不再左右拖）：
// 测试里点分段须先判形态——分段铺得开时直接点；收起时点开「分类」下拉再点
// 目标菜单项。页面测试统一走本助手，断言不随视口宽度漂移。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 点选工具条上标签为 [label] 的分类分段。
Future<void> selectFilterSegment(WidgetTester tester, String label) async {
  final segment = find.text(label);
  if (tester.any(segment)) {
    await tester.tap(segment);
    await tester.pump();
    return;
  }
  // 收起形态：打开「分类」下拉再点目标菜单项。触发按钮文案会变成已选分类名，
  // 统一用下拉箭头图标定位；菜单项在遮罩层里，取最后一个匹配。
  await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}
