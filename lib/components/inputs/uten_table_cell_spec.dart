import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/performance/ui_work_budget.dart';

import '../../core/theme/uten_tokens.dart';

/// 表格单元输入控件统一规格 —— 单一事实源。
///
/// 2026-10-16：全站表格输入使用14号正文、横向内距10、6圆角；桌面视觉
/// 最小高32、触控至少48。竖向内距按正文行高和视觉密度补偿，真实轮廓与
/// 点击盒同高、同中线，不能只用minHeight撑大盒子（ADR-161）。
///
/// 各消费方必须同源，缺一处同行就高低不齐（grid_cell_height_uniformity_test
/// 行为锁）：
/// - [UtenEditableGrid] 行级 [UtenTableCellInputTheme] 注入（编辑表全部裸输入格）；
/// - [MasterDataTableView] 数据格/卡片 cellBuilder 注入（读表内联输入格）；
/// - [UtenDropdownField] dense 形态显式 [contentPaddingOf]（下拉格不依赖注入路径）；
/// - 库存盘点实盘格等自带装饰的格也使用 [contentPaddingOf]。
///
/// 各列 cellBuilder **不得**自带 OutlineInputBorder/contentPadding/bodySmall/
/// maxLines:2——2026-09-10 前币种/供应商/仓库/车间格各画各的，同一行格高、
/// 圆角、字号三种口径并存。
abstract final class UtenEditableGridCellSpec {
  /// 表格使用更平直的描边；普通页面字段保留自己的较大圆角。
  static const double radius = UtenRadius.sm;
  static const BorderRadius borderRadius = UtenRadius.smAll;

  /// 兼容既有横向估宽与最小留白；实际字段必须调用 [contentPaddingOf]。
  static const EdgeInsets contentPadding = EdgeInsets.fromLTRB(10, 6, 10, 6);

  /// 兼容既有估宽；选择格和输入格都用 [contentPaddingOf]，无额外+1补偿。
  static const EdgeInsets pickerCellPadding = contentPadding;

  /// 兼容既有列宽定义。单元格说明/预填/错误提示已无图标，不再额外占宽。
  static const double hintIconWidth = 0;

  /// 下拉/选择格的右侧展开箭头占宽。
  static const double dropdownChevronWidth = 20;

  static double heightOf(BuildContext context) =>
      UtenControlMetrics.minimumHitExtent(
        context,
        desktop: UtenControlMetrics.cellHeight,
      );

  /// InputDecorator applies visual density to its painted container before the
  /// outer minimum constraint. Compensate in the content itself, otherwise a
  /// 32/48px field can paint a 25/33px outline aligned to its top edge.
  static EdgeInsets contentPaddingOf(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(body?.fontSize ?? 14) *
        (body?.height ?? 1.5);
    final density = UtenControlMetrics.usesTouchTargets(context)
        ? VisualDensity.standard
        : VisualDensity.compact;
    final vertical = math.max(
      contentPadding.top,
      (heightOf(context) - lineHeight - density.baseSizeAdjustment.dy) / 2,
    );
    return EdgeInsets.symmetric(
      horizontal: contentPadding.left,
      vertical: vertical,
    );
  }
}

/// 表格单元的紧凑输入主题注入：不自带装饰的输入框/下拉/选择格自动
/// isDense + [UtenEditableGridCellSpec.contentPaddingOf]；显式自带装饰的格
/// （实盘格、dense 下拉、选择格）与注入值同源等高。
/// 编辑表行、读表数据格、读表卡片格三处宿主共用。
class UtenTableCellInputTheme extends StatelessWidget {
  const UtenTableCellInputTheme({super.key, required this.child});

  final Widget child;
  static final _themes = Expando<Map<Object, ThemeData>>();

  /// Input geometry belongs to the table host, independently of the cell's
  /// optional validation/help registration in UtenTableCellHints.
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_UtenTableCellInputScope>() !=
      null;

  @override
  Widget build(BuildContext context) {
    final observer = debugUiWorkSliceObserver;
    final clock = observer == null ? null : (Stopwatch()..start());
    try {
      return _UtenTableCellInputScope(
        child: Theme(data: _themeFor(context), child: child),
      );
    } finally {
      if (clock != null) observer!('table-cell-theme-build', clock.elapsed);
    }
  }

  ThemeData _themeFor(BuildContext context) {
    final theme = Theme.of(context);
    final height = UtenEditableGridCellSpec.heightOf(context);
    final padding = UtenEditableGridCellSpec.contentPaddingOf(context);
    final touch = UtenControlMetrics.usesTouchTargets(context);
    final variants = _themes[theme] ??= <Object, ThemeData>{};
    final key = (height, padding, touch);
    final cached = variants[key];
    if (cached != null) return cached;
    final observer = debugUiWorkSliceObserver;
    final clock = observer == null ? null : (Stopwatch()..start());
    final decoration = theme.inputDecorationTheme;
    ButtonStyle commandStyle(ButtonStyle? style) =>
        (style ?? const ButtonStyle()).copyWith(
          // 原生按钮的点击高度已经由命令角色给定，不再二次扣减密度。
          visualDensity: VisualDensity.standard,
        );
    InputBorder? compactBorder(InputBorder? border) =>
        border is OutlineInputBorder
        ? border.copyWith(borderRadius: UtenEditableGridCellSpec.borderRadius)
        : border;
    final result = theme.copyWith(
      textTheme: theme.textTheme.copyWith(
        bodyLarge: theme.textTheme.bodyMedium,
      ),
      textButtonTheme: TextButtonThemeData(
        style: commandStyle(theme.textButtonTheme.style),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: commandStyle(theme.filledButtonTheme.style),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: commandStyle(theme.outlinedButtonTheme.style),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: commandStyle(theme.elevatedButtonTheme.style),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: (theme.iconButtonTheme.style ?? const ButtonStyle()).copyWith(
          minimumSize: WidgetStatePropertyAll(Size.square(height)),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
          iconSize: const WidgetStatePropertyAll(18),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      inputDecorationTheme: decoration.copyWith(
        // 紧凑密度只改变字段轮廓，不能再把格内命令的32/48点击高度扣掉8。
        visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
        isDense: true,
        contentPadding: padding,
        floatingLabelBehavior: FloatingLabelBehavior.never,
        border: compactBorder(decoration.border),
        enabledBorder: compactBorder(decoration.enabledBorder),
        focusedBorder: compactBorder(decoration.focusedBorder),
        disabledBorder: compactBorder(decoration.disabledBorder),
        errorBorder: compactBorder(decoration.errorBorder),
        focusedErrorBorder: compactBorder(decoration.focusedErrorBorder),
        // A native prefix/suffix and its IconButton must share the cell's
        // role. Material's default 48px icon slot otherwise inflates a row.
        prefixIconConstraints: BoxConstraints(
          minWidth: height,
          minHeight: height,
        ),
        suffixIconConstraints: BoxConstraints(
          minWidth: height,
          minHeight: height,
        ),
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        constraints: BoxConstraints(minHeight: height),
      ),
    );
    // ThemeData is immutable and weakly keyed. Bound zoom/touch variants per
    // source theme; the field subtree, controllers and focus are untouched.
    if (variants.length >= 8) variants.remove(variants.keys.first);
    variants[key] = result;
    if (clock != null) observer!('table-cell-theme-create', clock.elapsed);
    return result;
  }
}

class _UtenTableCellInputScope extends InheritedWidget {
  const _UtenTableCellInputScope({required super.child});

  @override
  bool updateShouldNotify(_UtenTableCellInputScope oldWidget) => false;
}
