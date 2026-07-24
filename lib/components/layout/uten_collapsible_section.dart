// UtenCollapsibleSection - 可折叠分区
//
// 分区内容多的时候（如工作台功能模块、待办清单）允许整段收起，
// 只留标题栏。点标题行切换展开/收起， chevron 旋转 + AnimatedCrossFade 过渡。
// 折叠状态保存在组件 State 内（页面存活期间有效）。

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
  });

  final String title;
  final Color? accentColor;
  final bool initiallyExpanded;
  final Widget child;

  @override
  State<UtenCollapsibleSection> createState() => _UtenCollapsibleSectionState();
}

class _UtenCollapsibleSectionState extends State<UtenCollapsibleSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行（整行可点）
        Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
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
                  AnimatedRotation(
                    turns: _expanded ? 0 : -0.5,
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
          crossFadeState: _expanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          duration: UtenAnim.normal,
          sizeCurve: UtenAnim.standard,
        ),
      ],
    );
  }
}
