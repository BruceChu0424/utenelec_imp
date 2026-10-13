// 分类工具条（UtenFilterToolbar）分段的共用点选助手。
//
// 2026-09-14 起窄屏/放不下时工具条收成一颗「分类」下拉按钮（不再左右拖）：
// 测试里点分段须先判形态——分段铺得开时直接点；收起时点开「分类」下拉再点
// 目标菜单项。页面测试统一走本助手，断言不随视口宽度漂移。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';

/// 点选工具条上标签为 [label] 的分类分段。
Future<void> selectFilterSegment(WidgetTester tester, String label) async {
  // 表格可能也有同名来源单元格，而且窄屏时位于视口外；只点分类/历史时间控件。
  final toolbars = find.byWidgetPredicate(
    (widget) =>
        widget is UtenFilterToolbar ||
        widget is UtenHistoryTimeFilter ||
        widget is UtenSegmentRow,
  );
  final segment = find
      .descendant(of: toolbars, matching: find.text(label))
      .hitTestable();
  if (tester.any(segment)) {
    // 点选可立即触发加载并卸掉原分类行；不要在 await 后再求 segment.first。
    final opensPopup = tester.any(
      find.ancestor(
        of: segment.first,
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuButton),
      ),
    );
    final compactButtons = find.ancestor(
      of: segment.first,
      matching: find.byType(OutlinedButton),
    );
    final opensPanel =
        tester.any(compactButtons) &&
        tester.any(
          find.descendant(
            of: compactButtons.first,
            matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
          ),
        );
    await tester.tap(segment.first);
    await tester.pump();
    // 下拉按钮会显示当前分类名；选一次相同菜单项以完成真实操作并关闭遮罩。
    if (opensPopup || opensPanel) {
      await _pumpMenuAnimation(tester);
      await tester.tap(_menuItem(label).last);
      await _pumpMenuAnimation(tester);
    }
    return;
  }
  // 收起形态：打开「分类」下拉再点目标菜单项。触发按钮文案会变成已选分类名，
  // 统一用下拉箭头图标定位；菜单项在遮罩层里，取最后一个匹配。
  final arrows = find
      .descendant(
        of: toolbars,
        matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
      )
      .hitTestable();
  final count = arrows.evaluate().length;
  for (var index = 0; index < count; index++) {
    await tester.tap(arrows.at(index));
    await _pumpMenuAnimation(tester);
    final item = _menuItem(label);
    if (tester.any(item)) {
      await tester.tap(item.last);
      await _pumpMenuAnimation(tester);
      return;
    }
    // 来源、状态各自折叠时，先关闭没有目标项的菜单再试下一颗分类按钮。
    await tester.tapAt(const Offset(1, 1));
    await _pumpMenuAnimation(tester);
  }
  throw TestFailure('没有可操作的分类：$label');
}

Finder _menuItem(String label) => find
    .descendant(
      of: find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem || widget is UtenDialogFrame,
      ),
      matching: find.text(label),
    )
    .hitTestable();

Future<void> _pumpMenuAnimation(WidgetTester tester) async {
  // Material popup menus animate for 300ms; a task request may deliberately stay pending.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
