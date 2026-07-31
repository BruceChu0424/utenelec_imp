// PermCatalogGroupSection - 权限目录分组（两级层级展示）
//
// 一级展示分组名、计数和可选批量操作；二级按需构建权限项。支持受控/非受控
// 展开状态，便于权限搜索命中时自动展开，并避免折叠状态仍构建全部权限行。
import 'package:flutter/material.dart';

import '../../../core/theme/uten_anim.dart';

class PermCatalogGroupSection extends StatefulWidget {
  const PermCatalogGroupSection({
    super.key,
    required this.title,
    required this.children,
    this.countLabel,
    this.initiallyExpanded = true,
    this.expanded,
    this.onExpandedChanged,
    this.trailing,
  });

  /// 分组名（权限目录 category，如「员工档案」）。
  final String title;

  /// 右侧计数胶囊文案（如 `2/6`）；null 不显示。
  final String? countLabel;

  /// 二级权限项（已排版好的行组件列表）。
  final List<Widget> children;

  /// 非受控模式的初始展开状态。
  final bool initiallyExpanded;

  /// 传入后进入受控模式。
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;

  /// 标题尾部操作（通常为整组批量设置菜单）。
  final Widget? trailing;

  @override
  State<PermCatalogGroupSection> createState() =>
      _PermCatalogGroupSectionState();
}

class _PermCatalogGroupSectionState extends State<PermCatalogGroupSection> {
  late bool _expanded = widget.initiallyExpanded;

  bool get _effectiveExpanded => widget.expanded ?? _expanded;

  void _toggle() {
    final next = !_effectiveExpanded;
    if (widget.expanded == null) {
      setState(() => _expanded = next);
    }
    widget.onExpandedChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final expanded = _effectiveExpanded;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            value: expanded ? '已展开' : '已折叠',
            child: Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _toggle,
                child: Ink(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: expanded ? 0 : -0.5,
                        duration: UtenAnim.normal,
                        curve: UtenAnim.standard,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (widget.countLabel != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            widget.countLabel!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: cs.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (widget.trailing != null) ...[
                        const SizedBox(width: 4),
                        widget.trailing!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: UtenAnim.normal,
              curve: UtenAnim.standard,
              alignment: Alignment.topCenter,
              child: expanded
                  ? Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(left: 10, top: 2),
                      padding: const EdgeInsets.only(left: 14, top: 6),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(width: 2, color: cs.outlineVariant),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: widget.children,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ),
        ],
      ),
    );
  }
}
