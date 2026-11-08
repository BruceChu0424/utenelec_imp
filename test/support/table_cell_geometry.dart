import 'dart:ui' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_table_surface.dart';

/// Inspect the actual stable cell frame rather than an incidental Container or
/// SizedBox/decoration combination. Width budgets and pointer bounds use this.
Finder tableCellFrame(Finder descendant) => find
    .ancestor(of: descendant, matching: find.byType(UtenTableCellFrame))
    .first;

double tableCellWidth(WidgetTester tester, Finder descendant) =>
    tester.getSize(tableCellFrame(descendant)).width;

/// Header cell frame of the column whose label is [label].
///
/// 2026-11 a78fa7ce4 起列宽手柄搬进表头行上层 overlay（分隔线两侧各 8px 命中），
/// 不再是表头格的后代；表头格改按列标签文本锚定（与
/// uten_editable_grid_column_resize_test 的 canonical 写法一致）。仅适用于该
/// 标签原文可见（未激活筛选值替换显示）的场景。
Finder tableHeaderCell(String label) => tableCellFrame(find.text(label));

Color tableCellBackgroundColor(WidgetTester tester, Finder descendant) {
  final color = tester
      .widget<UtenTableCellFrame>(tableCellFrame(descendant))
      .backgroundColor;
  expect(color, isNotNull, reason: 'Read the actual semantic cell surface.');
  return color!;
}
