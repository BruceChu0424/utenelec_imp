// UtenSegmentRow - 按内容自适应宽度的分段行（M3 SegmentedButton 的替身）。
//
// 为什么不用 Material SegmentedButton：SDK 渲染对象把**每个分段强制铺成同一
// 宽度**（取最宽分段的固有宽度，或可用宽度均分，segmented_button.dart 的
// _calculateHorizontalChildSize），两个字的小格被撑到和最长格一样宽，整条
// 显得空。2026-10-04 用户口径：分类栏每格宽度跟随自身内容（字少格窄、
// 字多或带徽章自动变长），本组件逐格复刻 M3 样式但宽度各自自适应。
//
// 视觉与交互 1:1 对齐 M3 默认（无主题定制时的 _SegmentedButtonDefaultsM3）：
// - StadiumBorder 描边（enabled=outline，整条禁用=onSurface@12%）；
// - 选中格 secondaryContainer 填充、文字 onSecondaryContainer；未选格透明、
//   文字 onSurface；禁用格文字 onSurface@38%、不填充；
// - 格间 1px 分隔线（与描边同色）；高度下限 40，图标 18、图标与文字间距 8；
// - 点选语义照抄 SDK _handleOnPressed：单选点已选段不回调，
//   [emptySelectionAllowed] 放开空选（点已选段取消），[multiSelectionEnabled]
//   放开多选；
// - API 与 SegmentedButton 同形（segments/selected/onSelectionChanged/
//   showSelectedIcon/…），迁移调用方只改组件名。
//
// 计数徽章走 label 槽位（UtenSegmentBadgeLabel），文字颜色经 DefaultTextStyle
// 自动继承本组件的三态前景色。
// 文档：docs-02-组件库/UtenSegmentRow.md（待写）

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';

/// 自适应分段行：每格宽度跟随自身内容，整条按内容总宽收缩。
class UtenSegmentRow<T> extends StatelessWidget {
  const UtenSegmentRow({
    super.key,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.showSelectedIcon = true,
    this.selectedIcon,
    this.emptySelectionAllowed = false,
    this.multiSelectionEnabled = false,
    this.minCellWidth,
    this.minCellHeight = UtenFilterRow.minHeight,
  });

  /// 分段定义（复用 Material 的 ButtonSegment：value/label/icon/enabled）。
  final List<ButtonSegment<T>> segments;

  /// 当前选中值集合；空集须配 [emptySelectionAllowed]（否则按调用方约定
  /// 传入前已保证非空，本组件不为此断言）。
  final Set<T> selected;

  /// 点选回调（与 SegmentedButton 同形）；null = 只读不响应点击。
  final ValueChanged<Set<T>>? onSelectionChanged;

  /// 选中格是否显示 [selectedIcon]（默认 Icon(Icons.check)，M3 同款）。
  final bool showSelectedIcon;

  /// 选中格图标；默认对勾。
  final Widget? selectedIcon;

  /// 允许空选：单选形态下点已选段取消选择（回调空集）。
  final bool emptySelectionAllowed;

  /// 允许多选：每段独立开关。
  final bool multiSelectionEnabled;

  /// 每格宽度下限（个别调用方要等宽观感时用，如对账弹窗 132）；
  /// 默认不设限——宽度完全由内容决定。
  final double? minCellWidth;

  /// 每格高度下限，默认 [UtenFilterRow.minHeight]（40）——与 UtenSearchBar 的
  /// 图标约束下限同源，保证分类栏与搜索框药丸描边恒同高；工具条内由
  /// IntrinsicHeight 拉齐搜索框。
  final double minCellHeight;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final anyEnabled = segments.any((segment) => segment.enabled);
    final borderColor = anyEnabled
        ? colors.outline
        : colors.onSurface.withValues(alpha: 0.12);
    return Material(
      color: Colors.transparent,
      shape: StadiumBorder(side: BorderSide(color: borderColor)),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0) Container(width: 1, color: borderColor),
              _SegmentCell<T>(
                segment: segments[i],
                isSelected: selected.contains(segments[i].value),
                showSelectedIcon: showSelectedIcon,
                selectedIcon: selectedIcon,
                minCellWidth: minCellWidth,
                minCellHeight: minCellHeight,
                onPressed: () => _handlePressed(segments[i].value),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 点选语义照抄 SDK SegmentedButton._handleOnPressed：
  /// 单选点已选段不回调（[emptySelectionAllowed] 时取消回空集）；
  /// 多选逐段取反；集合无变化不回调。
  void _handlePressed(T value) {
    final onChanged = onSelectionChanged;
    if (onChanged == null) return;
    final onlySelected = selected.length == 1 && selected.contains(value);
    final validChange = emptySelectionAllowed || !onlySelected;
    if (!validChange) return;
    final toggle =
        multiSelectionEnabled || (emptySelectionAllowed && onlySelected);
    final Set<T> updated;
    if (toggle) {
      updated = selected.contains(value)
          ? selected.difference(<T>{value})
          : selected.union(<T>{value});
    } else {
      updated = <T>{value};
    }
    if (!setEquals(updated, selected)) {
      onChanged(updated);
    }
  }
}

class _SegmentCell<T> extends StatelessWidget {
  const _SegmentCell({
    required this.segment,
    required this.isSelected,
    required this.showSelectedIcon,
    required this.selectedIcon,
    required this.minCellWidth,
    required this.minCellHeight,
    required this.onPressed,
  });

  final ButtonSegment<T> segment;
  final bool isSelected;
  final bool showSelectedIcon;
  final Widget? selectedIcon;
  final double? minCellWidth;
  final double minCellHeight;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled = segment.enabled;
    // M3 三态前景：禁用 onSurface@38%、选中 onSecondaryContainer、未选 onSurface。
    final foreground = !enabled
        ? colors.onSurface.withValues(alpha: 0.38)
        : isSelected
        ? colors.onSecondaryContainer
        : colors.onSurface;
    final Widget? icon;
    if (isSelected && showSelectedIcon) {
      icon = selectedIcon ?? const Icon(Icons.check);
    } else {
      icon = segment.icon;
    }
    final overlayBase = isSelected
        ? colors.onSecondaryContainer
        : colors.onSurface;
    final Widget? label = segment.label;
    Widget content;
    if (icon == null) {
      content = label ?? const SizedBox.shrink();
    } else if (label == null) {
      content = icon;
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [icon, const SizedBox(width: 8), label],
      );
    }
    return Semantics(
      button: true,
      selected: isSelected,
      enabled: enabled,
      child: Material(
        color: isSelected && enabled
            ? colors.secondaryContainer
            : Colors.transparent,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return overlayBase.withValues(alpha: 0.1);
            }
            if (states.contains(WidgetState.hovered)) {
              return overlayBase.withValues(alpha: 0.08);
            }
            if (states.contains(WidgetState.focused)) {
              return overlayBase.withValues(alpha: 0.1);
            }
            return null;
          }),
          child: Container(
            constraints: BoxConstraints(
              minWidth: minCellWidth ?? 0,
              minHeight: minCellHeight,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            child: IconTheme.merge(
              data: IconThemeData(size: 18, color: foreground),
              child: DefaultTextStyle(
                style: (theme.textTheme.labelLarge ?? const TextStyle())
                    .copyWith(color: foreground),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
