import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// 表格单元输入控件统一规格 —— 单一事实源。
///
/// 2026-10-08 用户口径：全站自研表格内的输入框统一为库存盘点「实盘数量」
/// 常驻输入格的紧凑尺寸（isDense + contentPadding(10,6,10,6)），上下边距收窄，
/// 取代 2026-10-06 的「格高 39」规格（ADR-161 修订）。
///
/// 各消费方必须同源，缺一处同行就高低不齐（grid_cell_height_uniformity_test
/// 行为锁）：
/// - [UtenEditableGrid] 行级 [UtenTableCellInputTheme] 注入（编辑表全部裸输入格）；
/// - [MasterDataTableView] 数据格/卡片 cellBuilder 注入（读表内联输入格）；
/// - [UtenDropdownField] dense 形态显式 contentPadding（下拉格不依赖注入路径）；
/// - 库存盘点实盘格等自带装饰的格直接引用 [contentPadding]。
///
/// 各列 cellBuilder **不得**自带 OutlineInputBorder/contentPadding/bodySmall/
/// maxLines:2——2026-09-10 前币种/供应商/仓库/车间格各画各的，同一行格高、
/// 圆角、字号三种口径并存。
abstract final class UtenEditableGridCellSpec {
  /// 单元内输入框圆角（与全站控件圆角同源）。
  static const double radius = UtenRadius.control;

  /// 单元内输入框内边距 = 库存盘点实盘格口径（原 14·12，2026-10-08 收紧）。
  static const EdgeInsets contentPadding = EdgeInsets.fromLTRB(10, 6, 10, 6);

  /// 选择格（InkWell + InputDecorator 结构）内边距：水平同 [contentPadding]，
  /// 垂直 +1——选择格正文 bodyMedium 行高比 TextField 输入文本 bodyLarge 矮
  /// 约 1px/侧，补偿后与同行输入格等高（grid_cell_height_uniformity_test 校准；
  /// 原 14·13 口径平移）。
  static const EdgeInsets pickerCellPadding = EdgeInsets.fromLTRB(10, 7, 10, 7);

  /// 兼容既有列宽定义。单元格说明/预填/错误提示已无图标，不再额外占宽。
  static const double hintIconWidth = 0;

  /// 下拉/选择格的右侧展开箭头占宽。
  static const double dropdownChevronWidth = 20;
}

/// 表格单元的紧凑输入主题注入：不自带装饰的输入框/下拉/选择格自动
/// isDense + [UtenEditableGridCellSpec.contentPadding]；显式自带装饰的格
/// （实盘格、dense 下拉、pickerCellPadding 选择格）与注入值同源等高。
/// 编辑表行、读表数据格、读表卡片格三处宿主共用。
class UtenTableCellInputTheme extends StatelessWidget {
  const UtenTableCellInputTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding: UtenEditableGridCellSpec.contentPadding,
        ),
      ),
      child: child,
    );
  }
}
