// UtenCollapsibleSection - 可折叠分区
//
// 分区内容多的时候（如工作台功能模块、待办清单）允许整段收起，
// 只留标题栏。点标题行切换展开/收起， chevron 旋转 + AnimatedCrossFade 过渡。
//
// 折叠状态两种模式：
// - 非受控（默认）：保存在组件 State 内（页面存活期间有效）；
// - 受控：传入 expanded + onExpandedChanged，由外部状态（如工作台布局
//   Provider）驱动，可持久化。admin 页权限矩阵等旧用法不受影响。

import 'package:flutter/material.dart';

import '../../core/theme/uten_anim.dart';

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
  });

  final String title;
  final Color? accentColor;
  final bool initiallyExpanded;
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;
  final Widget? trailing;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行（整行可点）
        Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: Row(
                children: [
                  if (widget.accentColor != null) ...[
                    Container(
                      width: 4,
                      height: 16,
                      decoration: BoxDecoration(
                        color: widget.accentColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 附加组件（如拖动排序手柄），在 chevron 左侧
                  if (widget.trailing != null) ...[
                    widget.trailing!,
                    const SizedBox(width: 4),
                  ],
                  AnimatedRotation(
                    turns: isExpanded ? 0 : -0.5,
                    duration: UtenAnim.normal,
                    curve: UtenAnim.standard,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(width: double.infinity, child: widget.child),
          ),
          secondChild: const SizedBox(width: double.infinity),
          crossFadeState: isExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          duration: UtenAnim.normal,
          sizeCurve: UtenAnim.standard,
        ),
      ],
    );
  }
}
