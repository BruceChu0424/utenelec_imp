// PermCatalogGroupSection - 权限目录分组（两级层级展示）
//
// 同一组件复用于两级：一级=功能模块（level=module），二级=子类（level=category）。
// 一级展示模块名、计数和可选批量操作，段内为二级子类 section；二级按需构建权限项。
// 支持受控/非受控展开状态，便于权限搜索命中时自动展开，并避免折叠状态仍构建全部权限行。
import 'package:flutter/material.dart';

import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_colors.dart';

/// 目录层级：[module] 一级功能模块，[category] 二级子类。
enum PermCatalogLevel { module, category }

class PermCatalogGroupSection extends StatefulWidget {
  const PermCatalogGroupSection({
    super.key,
    required this.title,
    required this.children,
    this.level = PermCatalogLevel.category,
    this.countLabel,
    this.initiallyExpanded = true,
    this.expanded,
    this.onExpandedChanged,
    this.trailing,
  });

  /// 分组层级（决定标题字号/底色与正文缩进样式）。
  final PermCatalogLevel level;

  /// 分组名（一级为模块如「基础资料」，二级为子类如「货品资料」）。
  final String title;

  /// 右侧计数胶囊文案（如 `2/6`）；null 不显示。
  final String? countLabel;

  /// 二级权限项（已排版好的行组件列表）；一级则为二级子类 section 列表。
  final List<Widget> children;

  /// 非受控模式的初始展开状态。
  final bool initiallyExpanded;

  /// 传入后进入受控模式。
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;

  /// 标题尾部操作（通常为整组/整模块批量设置菜单）。
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
    final isModule = widget.level == PermCatalogLevel.module;

    // 一级（模块）用品牌深绿实心底 + 白字，与二级子类拉开明显层级；
    // 二级（子类）保持中性浅底、更小字号与更紧凑高度，从属于一级。
    final headerBg = isModule ? UtenColors.deepGreen : cs.surfaceContainerHigh;
    final headerFg = isModule ? Colors.white : cs.onSurfaceVariant;
    final titleStyle =
        (isModule ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)
            ?.copyWith(
              fontWeight: isModule ? FontWeight.w700 : FontWeight.w600,
              color: headerFg,
            );
    final headerPad = isModule
        ? const EdgeInsets.symmetric(horizontal: 14, vertical: 14)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 8);

    return Padding(
      padding: EdgeInsets.only(bottom: isModule ? 14 : 8),
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
                    color: headerBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: headerPad,
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: expanded ? 0 : -0.5,
                        duration: UtenAnim.normal,
                        curve: UtenAnim.standard,
                        child: Icon(
                          isModule
                              ? Icons.folder_open_outlined
                              : Icons.keyboard_arrow_down_rounded,
                          size: isModule ? 22 : 18,
                          color: headerFg,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: titleStyle,
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
                            color: isModule
                                ? Colors.white.withValues(alpha: 0.22)
                                : cs.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            widget.countLabel!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: isModule ? Colors.white : cs.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (widget.trailing != null) ...[
                        const SizedBox(width: 4),
                        // 一级深绿底上把批量菜单图标也染白，保持可读。
                        IconTheme(
                          data: IconThemeData(color: headerFg),
                          child: widget.trailing!,
                        ),
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
                  ? (isModule
                        ? Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(top: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: widget.children,
                            ),
                          )
                        : Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(left: 10, top: 2),
                            padding: const EdgeInsets.only(left: 14, top: 6),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  width: 2,
                                  color: cs.outlineVariant,
                                ),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: widget.children,
                            ),
                          ))
                  : const SizedBox(width: double.infinity),
            ),
          ),
        ],
      ),
    );
  }
}
