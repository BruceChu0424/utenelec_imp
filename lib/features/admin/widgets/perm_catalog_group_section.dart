// PermCatalogGroupSection - 权限目录分组（两级层级展示）
//
// 同一组件复用于两级：一级=功能模块（level=module），二级=子类（level=category）。
// 一级展示模块名、计数和可选批量操作，段内为二级子类 section；二级按需构建权限项。
// 支持受控/非受控展开状态，便于权限搜索命中时自动展开，并避免折叠状态仍构建全部权限行。
import '../../../core/theme/uten_tokens.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/uten_anim.dart';
import '../../../components/feedback/uten_motion.dart';
import '../../../components/layout/uten_collapsible_content.dart';
import '../../../components/data_display/uten_tree_branch_guide.dart';

/// 目录层级：[module] 一级功能模块，[category] 二级子类。
enum PermCatalogLevel { module, category }

class PermCatalogGroupSection extends StatefulWidget {
  const PermCatalogGroupSection({
    super.key,
    required this.title,
    required this.children,
    this.level = PermCatalogLevel.category,
    this.countLabel,
    this.initiallyExpanded = false,
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

    return UtenMotion(
      duration: UtenAnim.normal,
      builder: (context, duration) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            value: expanded ? '已展开' : '已折叠',
            child: Material(
              color: isModule ? cs.surfaceContainerLow : Colors.transparent,
              borderRadius: UtenRadius.xsAll,
              child: InkWell(
                borderRadius: UtenRadius.xsAll,
                onTap: _toggle,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 38),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4, right: 4),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: expanded ? 0.25 : 0,
                          duration: duration,
                          curve: UtenAnim.standard,
                          child: Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: isModule
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.countLabel != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              widget.countLabel!,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (widget.trailing != null)
                          IconButtonTheme(
                            data: IconButtonThemeData(
                              style: IconButton.styleFrom(
                                minimumSize: const Size(32, 32),
                                padding: const EdgeInsets.all(4),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                            child: widget.trailing!,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          UtenCollapsibleContent(
            expanded: expanded,
            maintainState: false,
            child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < widget.children.length; i++)
                    _PermissionBranch(
                      isLast: i == widget.children.length - 1,
                      // A category owns its own child rails. Its parent rail
                      // joins the header, rather than the middle of the subtree.
                      headerOnly: isModule,
                      child: widget.children[i],
                    ),
                ],
              ),
            ),
          ),
          if (isModule) const SizedBox(height: 2),
        ],
      ),
    );
  }
}

class _PermissionBranch extends StatelessWidget {
  const _PermissionBranch({
    required this.isLast,
    required this.headerOnly,
    required this.child,
  });
  final bool isLast;
  final bool headerOnly;
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        left: 0,
        top: 0,
        bottom: headerOnly ? null : 0,
        width: 16,
        height: headerOnly ? 38 : null,
        child: UtenTreeBranchGuide(
          depth: 1,
          ancestorContinuations: const [],
          isLastChild: isLast,
          hasExpandedChildren: false,
          indent: 16,
          toggleExtent: 16,
          maxVisualDepth: 10,
          dotted: true,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      Padding(padding: const EdgeInsets.only(left: 16), child: child),
    ],
  );
}
