// PermCatalogGroupSection - 权限目录分组（两级层级展示）
//
// 层级设计：
//   一级 = 分组标题行： tonal 底色整行 + 加粗标题 + 右侧计数胶囊，整行可点折叠；
//   二级 = 权限项列表：左侧竖向引导线 + 整体缩进，视觉上从属于标题。
// 权限管理页「按部门」「按员工」两个 Tab 共用，保证两边观感一致。
import 'package:flutter/material.dart';

import '../../../core/theme/uten_anim.dart';

class PermCatalogGroupSection extends StatefulWidget {
  const PermCatalogGroupSection({
    super.key,
    required this.title,

    /// 右侧计数胶囊文案（如 `2/6`）；null 不显示
    this.countLabel,
    required this.children,
    this.initiallyExpanded = true,
  });

  /// 分组名（权限目录 category，如「员工档案」）
  final String title;
  final String? countLabel;

  /// 二级权限项（已排版好的行组件列表）
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  State<PermCatalogGroupSection> createState() =>
      _PermCatalogGroupSectionState();
}

class _PermCatalogGroupSectionState extends State<PermCatalogGroupSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ===== 一级：分组标题行（tonal 底色，整行可点折叠） =====
          Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Ink(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: _expanded ? 0 : -0.5,
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
                        maxLines: 1,
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
                  ],
                ),
              ),
            ),
          ),
          // ===== 二级：权限项（引导线 + 缩进） =====
          AnimatedCrossFade(
            firstChild: Padding(
              padding: const EdgeInsets.only(left: 10, top: 2),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 竖向层级引导线
                    Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: cs.outlineVariant,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: widget.children,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            secondChild: const SizedBox(width: double.infinity),
            crossFadeState: _expanded
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            duration: UtenAnim.normal,
            sizeCurve: UtenAnim.standard,
          ),
        ],
      ),
    );
  }
}
