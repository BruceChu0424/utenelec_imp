// UtenTableCellAction - 表格单元格里的紧凑文字动作（2026-10-06 行高统一口径）。
//
// 读表（MasterDataTableView 系）单元格里需要放动作（去领料/查看/续报/恢复…）
// 时用本组件：高度=单行文本，不带按钮主题的最小高（TextButton 默认 min 40、
// UtenButton min 44 会把读行撑到 52-60，与单行文本行 37 的基线不齐）。
//
// 与编辑表（UtenEditableGrid 系）控件口径的分工：编辑行的行高由 39 高的输入
// 控件决定；读行的行高由单行文本决定——读行里的一切内容（动作/徽章/下拉/文本）
// 都不得超过单行文本高度。下拉用 UtenDropdownField(flat)，动作用本组件。

import 'package:flutter/material.dart';

/// 单元格内联文字动作：主色文字（可带 14px 前置图标），高度=单行文本。
///
/// [tooltip] 悬停说明（动作语义或补充信息）；[onPressed] 为 null 时置灰。
/// 文字样式继承宿主格 DefaultTextStyle（MDTV 读表是 bodySmall），保持与
/// 同行其它文本格同字号同高；超宽省略号 + Tooltip 兜底。
class UtenTableCellAction extends StatelessWidget {
  const UtenTableCellAction({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.tooltip,
    this.maxLines = 1,
    this.error = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final String? tooltip;

  /// 动作文案最多几行（默认 1：读行高度不因动作文案折行而变化）。
  final int maxLines;

  /// 必填未填等错误态：文字转 error 红（如「需要填写」），仍可点开选择。
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = error
        ? theme.colorScheme.error
        : onPressed == null
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.primary;
    final content = Text(
      label,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontWeight: FontWeight.w600),
    );
    final row = icon == null
        ? content
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(child: content),
            ],
          );
    final button = TextButton(
      onPressed: onPressed,
      // 关掉按钮主题的最小尺寸与内边距：动作高度完全由文本行高决定，
      // 点击区由宿主单元格（约 37 高）提供，不靠按钮自身撑。
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      child: row,
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
