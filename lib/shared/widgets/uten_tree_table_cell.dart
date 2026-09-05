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
    this.pathLabel,
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
  });

  /// Zero-based depth. The visible label is one-based.
  final int depth;
  final String sequence;
  final String title;
  final String? subtitle;
  final String? pathLabel;
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
    final safePath = pathLabel?.trim();
    final identityLabel = <String>[
      title,
      if (sequence.trim().isNotEmpty) '级联号 $sequence',
      if (!sequenceInline) effectiveLevelLabel,
      if (safeSubtitle?.isNotEmpty == true) safeSubtitle!,
      if (safePath?.isNotEmpty == true) '路径 $safePath',
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
                    label: '${expanded ? '收起' : '展开'} $title 的下级',
                    child: IconButton(
                      key: toggleKey,
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      padding: EdgeInsets.zero,
                      tooltip: expanded ? '收起下级' : '展开下级',
                      onPressed: onToggle,
                      icon: Icon(
                        expanded
                            ? Icons.expand_more_rounded
                            : Icons.chevron_right_rounded,
                        color: levelColor,
                      ),
                    ),
                  )
                : ExcludeSemantics(
                    child: Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: levelColor.withValues(alpha: 0.7),
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
                    if (safePath?.isNotEmpty == true)
                      Tooltip(
                        message: safePath!,
                        child: Text(
                          '路径：$safePath',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: secondaryColor,
                          ),
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
