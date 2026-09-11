// UtenFilterPickerField - 「点开侧滑面板选」的筛选入口字段（全平台唯一形态）。
// 文档：docs/02-组件库/UtenFilterPickerField.md
//
// 2026-09-11 全平台统一：页面工具栏里凡是「层级数据筛选」（货品分类、仓库层级
// 等树形/父子口径），一律用本字段 + 侧滑面板，不再用 DropdownButtonFormField
// —— 下拉把树摊平成缩进长条，层级一多就成滚动噩梦，也和详情页/单据里
// 「点开侧滑窗选分类」的范式割裂（用户口径：应该和货品资料里一样）。
//
// 形态：单行紧凑字段 = 标签 + 当前值 + 尾部 chevron；
// - 圆角 UtenRadius.control（全平台唯一控件圆角）；
// - 高度与 UtenSearchBar（内容驱动 ≈44）对齐：纵向内边距 11 + 20 图标 + 1px 边框；
//   字号放大时跟随内容自然增高，不写死高度；
// - 已生效（[value] 非空）时边框/文字走 primary，一眼看出「这个筛选正开着」；
//   未生效显示 [placeholder]（默认「全部」）与中性描边。
//
// 只负责呈现与点击；面板内容、数据加载与选中语义都在调用方
//（如 showUtenProductCategoryPickerPanel / showUtenWarehousePickerPanel）。
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

class UtenFilterPickerField extends StatelessWidget {
  const UtenFilterPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.placeholder = '全部', // TODO(l10n): 补 arb
    this.icon,
    this.width = 200,
    this.enabled = true,
  });

  /// 字段标签（如「货品分类」「仓库」）。
  final String label;

  /// 当前选中值的显示文案；null/空 = 未筛选，显示 [placeholder]。
  final String? value;

  /// 点击打开侧滑面板。
  final VoidCallback onTap;

  /// 未筛选时的占位文案。
  final String placeholder;

  /// 可选前置图标（如 Icons.category_outlined / Icons.warehouse_outlined）。
  final IconData? icon;

  /// 固定宽度（工具栏 Wrap 里排版用）。传 null 表示交给父级约束——此时父级必须
  /// 给出有界宽度（Wrap 的直接子级是无界的，务必留着默认值或自己套 SizedBox）。
  final double? width;

  final bool enabled;

  /// 是否处于「已筛选」态（值非空）。
  bool get isActive => value != null && value!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = isActive;
    final borderColor = !enabled
        ? scheme.outlineVariant
        : active
        ? scheme.primary
        : scheme.outlineVariant;
    final foreground = !enabled
        ? scheme.onSurfaceVariant
        : active
        ? scheme.primary
        : scheme.onSurface;

    // 值文案：有界宽度下可收缩省略；width=null（父级自带约束）时不套 Flexible，
    // 避免落进无界 Row 触发 flex 断言。
    final Widget valueText = Text(
      active ? value! : placeholder,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: foreground,
        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
      ),
    );

    final field = Material(
      color: enabled && active
          ? scheme.primaryContainer.withValues(alpha: 0.35)
          : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.controlAll,
        side: BorderSide(color: borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: UtenSpacing.s8),
              ],
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              if (width == null) valueText else Flexible(child: valueText),
              const SizedBox(width: UtenSpacing.s4),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );

    return width == null ? field : SizedBox(width: width, child: field);
  }
}
