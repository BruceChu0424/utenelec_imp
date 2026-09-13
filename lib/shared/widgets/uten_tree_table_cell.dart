import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// Reusable tree identity cell for data tables.
///
/// Hierarchy is deliberately redundant: indentation + continuous guide rails +
/// cascading sequence + an explicit level label. Colour only reinforces the
/// level and is never the sole signal. Expansion is a dedicated 48dp action so
/// row selection and tree navigation do not compete for the same gesture.
class UtenTreeTableCell extends StatelessWidget {
  const UtenTreeTableCell({
    super.key,
    required this.depth,
    required this.sequence,
    required this.title,
    this.subtitle,
    this.levelLabel,
    this.sequenceInline = false,
    this.foregroundColor,
    this.hasChildren = false,
    this.expanded = false,
    this.onToggle,
    this.toggleKey,
    this.maxVisualDepth = 8,
    this.ancestorContinuations = const [],
    this.isLastChild = false,
    this.childCount,
  });

  /// 下级数量（可选）：未展开时在展开按钮右下角叠一枚「N」小徽章，让"这行
  /// 还有子层"一眼可见；展开后不显示。懒加载宿主（展开前不知数量）不传。
  final int? childCount;

  /// Zero-based depth. The visible label is one-based.
  final int depth;
  final String sequence;
  final String title;
  final String? subtitle;
  final String? levelLabel;

  /// 紧凑身份行：序号徽章与标题同排（「P1 名字」），副标题（如编号）另起一行。
  /// 默认 false 保持原三层结构（徽标行 / 标题 / 副标题）——货品 BOM 等既有
  /// 宿主不传即不变。行高更矮，适合列多、以编号辅助识别的工作台表格。
  final bool sequenceInline;

  final Color? foregroundColor;
  final bool hasChildren;
  final bool expanded;
  final VoidCallback? onToggle;
  final Key? toggleKey;

  /// Caps indentation only; the explicit level label and semantics keep the
  /// true depth visible for unusually deep legacy BOMs.
  final int maxVisualDepth;

  /// For each ancestor level, whether a later sibling continues the vertical
  /// guide. Missing entries conservatively keep a continuous rail.
  final List<bool> ancestorContinuations;
  final bool isLastChild;

  Color _levelColor(ColorScheme colors) => switch (depth % 4) {
    0 => colors.primary,
    1 => colors.secondary,
    2 => colors.tertiary,
    _ => colors.onSurfaceVariant,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final levelColor = foregroundColor ?? _levelColor(colors);
    final textColor = foregroundColor ?? colors.onSurface;
    final secondaryColor =
        foregroundColor?.withValues(alpha: 0.82) ?? colors.onSurfaceVariant;
    final effectiveLevelLabel = levelLabel ?? '层级 ${depth + 1}';
    final visualDepth = depth.clamp(0, maxVisualDepth);
    final safeSubtitle = subtitle?.trim();
    // 2026-09-12 起不再有 pathLabel 路径行：货品 BOM 宿主按用户口径收敛为
    // 「名字 + 组件X级」（编号看「编号」列），物料分析宿主本就不传。语义朗读
    // 随副标题一并精简。
    final identityLabel = <String>[
      title,
      if (sequence.trim().isNotEmpty) '级联号 $sequence',
      if (!sequenceInline) effectiveLevelLabel,
      if (safeSubtitle?.isNotEmpty == true) safeSubtitle!,
    ].join('，');
    Widget sequenceChip(ThemeData theme) => Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s4,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: levelColor.withValues(alpha: 0.12),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: levelColor.withValues(alpha: 0.45)),
      ),
      child: Text(
        sequence,
        style: theme.textTheme.labelSmall?.copyWith(
          color: levelColor,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          SizedBox(
            width: visualDepth * 16.0,
            height: 48,
            child: CustomPaint(
              painter: _TreeGuidePainter(
                depth: visualDepth,
                color:
                    foregroundColor?.withValues(alpha: 0.35) ??
                    colors.outlineVariant,
                ancestorContinuations: ancestorContinuations,
                isLastChild: isLastChild,
              ),
            ),
          ),
          SizedBox(
            width: 48,
            height: 48,
            child: hasChildren
                ? Semantics(
                    button: true,
                    expanded: expanded,
                    excludeSemantics: true,
                    label: childCount != null && !expanded
                        ? '展开 $title 的 $childCount 个下级'
                        : '${expanded ? '收起' : '展开'} $title 的下级',
                    child: IconButton(
                      key: toggleKey,
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: expanded
                          ? '收起下级'
                          : (childCount != null
                                ? '展开 $childCount 个下级'
                                : '展开下级'),
                      onPressed: onToggle,
                      // 2026-09-10 用户口径「展开箭头要一眼看到」：由淡色线性图标
                      // 改为 28px 层级色实心圆底 + 反相箭头；2026-09-12 再加强
                      //（用户口径「箭头粗一点、浅色模式亮一点」）：箭头改自绘粗描边
                      //（3px 圆头，比线性图标明显更粗），且圆底偏深时箭头一律反白——
                      // 浅色模式黑底上的箭头从暗青色改白色更亮；选中行（白底）仍主色箭头。
                      // 未展开且已知子件数时叠「N」徽章。
                      icon: _ToggleGlyph(
                        expanded: expanded,
                        background: foregroundColor ?? levelColor,
                        foreground: _toggleForeground(
                          circleColor: foregroundColor ?? levelColor,
                          colors: colors,
                          explicitForeground: foregroundColor,
                        ),
                        badge: !expanded && (childCount ?? 0) > 0
                            ? childCount
                            : null,
                      ),
                    ),
                  )
                : ExcludeSemantics(
                    child: Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          // 叶子圆点降为 0.45，与实心圆底的展开按钮拉开对比。
                          color: levelColor.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: UtenSpacing.s4),
          Expanded(
            child: Semantics(
              container: true,
              label: identityLabel,
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (sequenceInline)
                      Row(
                        children: [
                          sequenceChip(theme),
                          const SizedBox(width: UtenSpacing.s4),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: textColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      )
                    else ...[
                      Row(
                        children: [
                          sequenceChip(theme),
                          const SizedBox(width: UtenSpacing.s4),
                          Text(
                            effectiveLevelLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: levelColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if (safeSubtitle?.isNotEmpty == true)
                      Text(
                        safeSubtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: secondaryColor,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 展开按钮箭头的前景色：圆底偏深一律反白（浅色模式黑底 → 白箭头，更亮）；
  /// 圆底偏浅时，层级色宿主用正文色、显式前景宿主（选中行白底）用主色。
  Color _toggleForeground({
    required Color circleColor,
    required ColorScheme colors,
    required Color? explicitForeground,
  }) {
    final circleIsDark =
        ThemeData.estimateBrightnessForColor(circleColor) == Brightness.dark;
    if (circleIsDark) return Colors.white;
    return explicitForeground == null ? colors.onSurface : colors.primary;
  }
}

/// 展开/收起按钮的图形：28px 实心圆底 + 自绘粗箭头（3px 圆头描边，2026-09-12
/// 起替换细线图标——浅色模式黑底上白色粗箭头一眼可见），未展开且已知子件数时
/// 右下角叠「N」徽章。命中区仍由外层 IconButton 的 48×48 保证。
class _ToggleGlyph extends StatelessWidget {
  const _ToggleGlyph({
    required this.expanded,
    required this.background,
    required this.foreground,
    this.badge,
  });

  final bool expanded;
  final Color background;
  final Color foreground;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: CustomPaint(
                size: const Size(14, 14),
                painter: _ThickChevronPainter(
                  direction: expanded ? _ChevronAxis.down : _ChevronAxis.right,
                  color: foreground,
                ),
              ),
            ),
          ),
          if (badge != null)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                constraints: const BoxConstraints(minWidth: 16),
                height: 16,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: background, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  badge! > 99 ? '99+' : '$badge',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: background == Colors.white
                        ? theme.colorScheme.primary
                        : background,
                    fontWeight: FontWeight.w800,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 粗箭头朝向：未展开朝右（›），展开后朝下（⌄）。
enum _ChevronAxis { right, down }

/// 自绘粗折线箭头：3px 圆头描边，比 Material 线性图标明显更粗（2026-09-12
/// 用户口径「箭头粗一点」）；14×14 视口，拐点内收防圆头出界。
class _ThickChevronPainter extends CustomPainter {
  const _ThickChevronPainter({required this.direction, required this.color});

  final _ChevronAxis direction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final w = size.width;
    final h = size.height;
    final path = direction == _ChevronAxis.right
        ? (Path()
            ..moveTo(w * 0.30, h * 0.18)
            ..lineTo(w * 0.72, h * 0.5)
            ..lineTo(w * 0.30, h * 0.82))
        : (Path()
            ..moveTo(w * 0.18, h * 0.32)
            ..lineTo(w * 0.5, h * 0.74)
            ..lineTo(w * 0.82, h * 0.32));
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ThickChevronPainter oldDelegate) =>
      oldDelegate.direction != direction || oldDelegate.color != color;
}

class _TreeGuidePainter extends CustomPainter {
  const _TreeGuidePainter({
    required this.depth,
    required this.color,
    required this.ancestorContinuations,
    required this.isLastChild,
  });

  final int depth;
  final Color color;
  final List<bool> ancestorContinuations;
  final bool isLastChild;

  @override
  void paint(Canvas canvas, Size size) {
    if (depth <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var level = 0; level < depth - 1; level++) {
      final continues =
          level >= ancestorContinuations.length || ancestorContinuations[level];
      if (!continues) continue;
      final x = level * 16.0 + 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    final branchX = (depth - 1) * 16.0 + 8;
    canvas.drawLine(
      Offset(branchX, 0),
      Offset(branchX, isLastChild ? size.height / 2 : size.height),
      paint,
    );
    canvas.drawLine(
      Offset(branchX, size.height / 2),
      Offset(size.width, size.height / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _TreeGuidePainter oldDelegate) =>
      oldDelegate.depth != depth ||
      oldDelegate.color != color ||
      oldDelegate.isLastChild != isLastChild ||
      !listEquals(oldDelegate.ancestorContinuations, ancestorContinuations);
}
