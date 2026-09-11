// 文件行内的「分类」控件（ADR-074，2026-09-11 改版）。
//
// 分类是上传之后、在文件旁边可选设置的标注，上传流程本身不再询问分类，
// 也没有任何「先选分类再上传」的模式开关。两种形态共用同一几何：
// - 未设置：安静的「＋分类」虚位（描边、次要色），不抢文件名的注意力；
// - 已设置：同尺寸的分类胶囊（浅底深字）。
// 描边与填充都保留 1px 边框，切换两态不改变行高，窄屏与大字号下不跳动。
// 无管理权限（或单据已锁定）时退化为纯标签：没有分类就不占位。

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// 只读分类/头像小标签：胶囊形，浅底深字，不打断文件名阅读。
class AttachmentCategoryTag extends StatelessWidget {
  const AttachmentCategoryTag({
    super.key,
    required this.label,
    this.highlighted = false,
  });

  final String label;

  /// true = 品牌色强调（「头像」等状态标签）。
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _CategoryChip(
      label: label,
      color: highlighted
          ? theme.colorScheme.primary
          : theme.colorScheme.onSurfaceVariant,
      filled: true,
    );
  }
}

/// 文件行内的可选分类控件：点一下出紧凑菜单（本页分类 + 清除），没有二级弹窗。
class AttachmentCategoryControl extends StatelessWidget {
  const AttachmentCategoryControl({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  /// 本页的分类词表；为空时不提供设置入口。
  final List<String> categories;

  final String? value;

  /// null = 只读（无 attachment:upload 或单据已锁定）：只展示已有分类。
  final ValueChanged<String?>? onChanged;

  /// false = 正在保存上一次选择，暂不接受新点击。
  final bool enabled;

  /// 「清除」在菜单里的取值；showMenu 的 null 表示「点外部取消」，故用哨兵区分。
  static const String _clearChoice = '\u0000clear';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = value;
    if (onChanged == null || categories.isEmpty) {
      return current == null
          ? const SizedBox.shrink()
          : AttachmentCategoryTag(label: current);
    }
    final assigned = current != null;
    final color = assigned
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.outline;
    return Tooltip(
      message: assigned ? '分类：$current，点击修改' : '设置分类（可选）',
      child: InkWell(
        onTap: enabled ? () => _open(context) : null,
        borderRadius: BorderRadius.circular(999),
        child: _CategoryChip(
          label: assigned ? current : '分类',
          color: color,
          filled: assigned,
          icon: assigned ? null : Icons.add_rounded,
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final theme = Theme.of(context);
    final anchor = context.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (anchor is! RenderBox || overlay is! RenderBox) return;
    final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = anchor.localToGlobal(
      anchor.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.controlAll),
      items: [
        for (final category in categories)
          CheckedPopupMenuItem<String>(
            value: category,
            checked: category == value,
            child: Text(category),
          ),
        if (value != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: _clearChoice,
            child: Row(
              children: [
                Icon(
                  Icons.backspace_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                const Text('清除分类'),
              ],
            ),
          ),
        ],
      ],
    );
    // null = 点外部关闭：保持原样，不当作「清除」。
    if (choice == null) return;
    onChanged!(choice == _clearChoice ? null : choice);
  }
}

/// 胶囊本体：填充态与描边态几何完全一致（同内边距 + 同 1px 边框），切换不跳行高。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.color,
    required this.filled,
    this.icon,
  });

  final String label;
  final Color color;
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 图标随字号一起缩放，1.5 倍字号下仍与文字同高。
    final iconSize = MediaQuery.textScalerOf(context).scale(12);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: filled ? 0.1 : 0),
        // 两态都留着这条 1px 边（填充态设为全透明），行高才不会跟着变。
        border: Border.all(color: color.withValues(alpha: filled ? 0 : 0.5)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: iconSize, color: color),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
