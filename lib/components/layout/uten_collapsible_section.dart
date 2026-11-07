// UtenCollapsibleSection - 可折叠分区
//
// 分区内容多的时候（如工作台功能模块、待办清单）允许整段收起，
// 只留标题栏。点标题行切换展开/收起， chevron 旋转 + 裁剪展开过渡
// (收起时箭头朝下、展开后朝上, 与 ExpansionTile / expand_more·expand_less 同一口径)。
//
// 折叠状态两种模式：
// - 非受控（默认）：保存在组件 State 内（页面存活期间有效）；
// - 受控：传入 expanded + onExpandedChanged，由外部状态（如工作台布局
//   Provider）驱动，可持久化。admin 页权限矩阵等旧用法不受影响。

import '../../core/theme/uten_tokens.dart';
import 'package:flutter/material.dart';

import '../../core/theme/uten_anim.dart';
import '../../core/responsive/breakpoint.dart';
import '../feedback/uten_motion.dart';
import 'uten_collapsible_content.dart';

class UtenCollapsibleSection extends StatefulWidget {
  const UtenCollapsibleSection({
    super.key,
    required this.title,
    required this.child,

    /// 标题左侧色条颜色；null 不显示色条
    this.accentColor,
    this.initiallyExpanded = true,

    /// 受控展开状态；不传则内部自维护（非受控）
    this.expanded,

    /// 展开状态变更回调（受控/非受控都会触发）
    this.onExpandedChanged,

    /// 标题行右侧附加组件（chevron 左侧），如拖动排序手柄
    this.trailing,

    /// 紧贴标题文字右侧的附加组件（如待办总数徽章）。
    /// 与 [trailing] 不同：它紧跟标题文字，不会被挤到行尾。
    this.titleTrailing,

    /// Current status centered in the header, with a second row on compact widths.
    this.headerCenter,
  });

  final String title;
  final Color? accentColor;
  final bool initiallyExpanded;
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;
  final Widget? trailing;
  final Widget? titleTrailing;
  final Widget? headerCenter;
  final Widget child;

  @override
  State<UtenCollapsibleSection> createState() => _UtenCollapsibleSectionState();
}

class _UtenCollapsibleSectionState extends State<UtenCollapsibleSection> {
  late bool _expanded = widget.initiallyExpanded;

  /// 当前展开值：受控取外部传入，非受控取内部 State
  bool get _isExpanded => widget.expanded ?? _expanded;

  @override
  void didUpdateWidget(covariant UtenCollapsibleSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 非受控 → 受控切换时同步一次内部值，避免再切回非受控时状态跳变
    if (oldWidget.expanded == null && widget.expanded != null) {
      _expanded = widget.expanded!;
    }
  }

  void _toggle() {
    final next = !_isExpanded;
    if (widget.expanded == null) {
      setState(() => _expanded = next);
    }
    widget.onExpandedChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExpanded = _isExpanded;

    return UtenMotion(
      duration: UtenAnim.normal,
      builder: (context, duration) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行（整行可点）
          Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(UtenRadius.md),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                child: _header(theme, isExpanded, duration),
              ),
            ),
          ),
          UtenCollapsibleContent(
            expanded: isExpanded,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SizedBox(width: double.infinity, child: widget.child),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, bool expanded, Duration duration) {
    final title = Row(
      children: [
        if (widget.accentColor != null) ...[
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: widget.accentColor,
              borderRadius: BorderRadius.circular(UtenRadius.xs),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            widget.title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // 紧贴标题文字的附加组件（如待办总数徽章）
        if (widget.titleTrailing != null) ...[
          const SizedBox(width: 8),
          widget.titleTrailing!,
        ],
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // 附加组件（如拖动排序手柄），在 chevron 左侧
        if (widget.trailing != null) ...[
          Flexible(child: widget.trailing!),
          const SizedBox(width: 4),
        ],
        // 与全站展开箭头同一口径: 收起时朝下(点开往下展开), 展开后朝上。
        AnimatedRotation(
          turns: expanded ? 0.5 : 0,
          duration: duration,
          curve: UtenAnim.standard,
          child: Icon(
            Icons.keyboard_arrow_down_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final center = widget.headerCenter;
    if (center == null) {
      return Row(
        children: [
          Expanded(child: title),
          actions,
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (breakpointForWidth(constraints.maxWidth).isCompact) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: title),
                  Expanded(child: actions),
                ],
              ),
              const SizedBox(height: UtenSpacing.s4),
              Center(child: center),
            ],
          );
        }
        return Row(
          spacing: UtenSpacing.s8,
          children: [
            Expanded(child: title),
            Expanded(flex: 2, child: Center(child: center)),
            Expanded(child: actions),
          ],
        );
      },
    );
  }
}
