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
    this.maxVisualDepth = defaultMaxVisualDepth,
    this.ancestorContinuations = const [],
    this.isLastChild = false,
    this.childCount,
    this.showLeafMarker = true,
    this.guideBleed = 0,
  });

  /// 视觉缩进的深度上限（全站一个数，2026-09-15）：与业务侧的 BOM 展开上限
  /// （物料分析级联页 10 层）对齐。原来组件默认 8、级联页显式传 10，同一颗
  /// 第 9/10 层的料在两个页面缩进深浅不同。确有更浅需求的宿主再显式覆盖。
  static const int defaultMaxVisualDepth = 10;

  /// 连接线横段（肘线）与展开位圆心的纵向位置：内容行顶端往下半个展开位。
  /// 展开按钮固定 48×48 且在 Stack 里**顶端对齐**，所以它恒在这里，
  /// 与单元格实际有多高无关（有副标题的行格子会更高，取 size.height/2 就会
  /// 让肘线掉到圆心下方）。
  static const double _connectorCenterY = 24;

  /// 连接线向单元格上下各溢出多少像素。
  ///
  /// 表格宿主（UtenEditableGrid / MasterDataTableView）给每个单元格加了纵向
  /// 内边距，单元格本身又比行矮——竖线只画到单元格边界时，行与行之间会留出
  /// 一段空白，整列连线看着像虚线（2026-09-14 用户口径「表示层级的竖线不对」）。
  /// 宿主把自己的纵向内边距传进来，连线就跨过那段空白连成一条。
  /// 0 = 独立使用（非表格宿主），不溢出。
  final double guideBleed;

  /// 叶子行（无下级）是否画那枚小圆点。2026-09-14 用户口径：物料分析主表与
  /// 三个分桶详情的最底层不要圆点——层级已由缩进 + 连接线表达，一列密密麻麻
  /// 的圆点只是噪音。占位宽度仍保留，名称列在各层级对齐不变。
  final bool showLeafMarker;

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

  /// 祖先链的连线续画标记。**长度恒等于 [depth]**，`[i]` = 深度 i 的祖先
  /// 后面还有没有同深度的兄弟；`[0]`（深度 0 的祖先）的竖线落在槽 −1，永远
  /// 画不出来，但必须占位，否则整串索引错开一格。
  ///
  /// 唯一权威的构造方式是 `utenTreeProjection`（uten_tree_row_projection.dart）——
  /// 不要在宿主里另写一套推导：2026-09-14 到 09-15 之间，主表按「深度 − 1 相对」
  /// 口径自建了一份，与本画笔差一级，末位子件的竖线永远不收口。
  /// 长度不足时按「祖先仍有兄弟」保守连画（不静默抹掉层级线）。
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

    final guideWidth = visualDepth * 16.0;
    // 连接线独立成一层浮在内容背后，高度跟着**整个单元格**（外加宿主的纵向
    // 内边距 [guideBleed]）——原来它被钉死在 48 高的 SizedBox 里，行一旦更高
    // （标题换行 / 有副标题 / 邻列两行文本）竖线就缩在中间，上下各露一截空白。
    // IgnorePointer：这层压住展开按钮左半边，不让它吃掉点击。
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (visualDepth > 0)
            Positioned(
              left: 0,
              top: -guideBleed,
              bottom: -guideBleed,
              // 多画半个展开位：肘线的横段一直伸到展开按钮/叶子位的圆心，
              // 行才真的「挂」在树上（原来横段停在缩进区边缘，离标题还有 52px）。
              width: guideWidth + 24,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TreeGuidePainter(
                    depth: visualDepth,
                    // 2026-09-14 用户口径「浅色时候看不清，颜色深点；深色模式下
                    // 浅点」：原来两种明暗都取 outlineVariant——白底上它几乎与
                    // 表格网格线同色。改成按明暗两档对称调：浅色用
                    // onSurfaceVariant 七成不透明（明显能看出层级走向，又不至于
                    // 抢名称），深色用四成（深底上线条本就更跳，压下去才不刺眼）。
                    color:
                        foregroundColor?.withValues(alpha: 0.35) ??
                        colors.onSurfaceVariant.withValues(
                          alpha: theme.brightness == Brightness.dark
                              ? 0.40
                              : 0.70,
                        ),
                    ancestorContinuations: ancestorContinuations,
                    isLastChild: isLastChild,
                    connectorY: guideBleed + _connectorCenterY,
                  ),
                ),
              ),
            ),
          Row(
            children: [
              SizedBox(width: guideWidth),
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
                    : showLeafMarker
                    ? ExcludeSemantics(
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
                      )
                    : const SizedBox.shrink(),
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
                              // 级联号（P1 / P1.1）是可选的：物料分析主表与分桶详情
                              // 2026-09-14 起传空串不再显示——层级由缩进+连接线表达，
                              // 名称前挂一串编号反而把货品名挤到后面。
                              if (sequence.trim().isNotEmpty) ...[
                                sequenceChip(theme),
                                const SizedBox(width: UtenSpacing.s4),
                              ],
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
                              if (sequence.trim().isNotEmpty) ...[
                                sequenceChip(theme),
                                const SizedBox(width: UtenSpacing.s4),
                              ],
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

/// 层级连线的纯几何：给定深度、祖先链与画布尺寸，算出要画哪几条线段。
///
/// 抽成独立函数是为了让口径可被直接断言——2026-09-14 把祖先槽的索引整体翻转
/// 过一次，两个宿主一好一坏而 CI 全绿，就是因为当时没有任何一条测试断言过线段
/// 坐标。宿主不需要调用它，画笔与单测各调一次。
List<({double x1, double y1, double x2, double y2})> utenTreeGuideSegments({
  required int depth,
  required List<bool> ancestorContinuations,
  required bool isLastChild,
  required double height,
  required double width,
  required double connectorY,
}) {
  if (depth <= 0) return const [];
  final result = <({double x1, double y1, double x2, double y2})>[];
  // 缩进槽 k（x = k*16+8）承载的是**深度 k+1** 那一层的竖线：本行深度 d
  // 的自身竖线就落在槽 d-1。所以祖先槽 level 要看「深度 level+1 的祖先
  // 后面还有没有兄弟」——与 utenTreeProjection 的绝对深度口径逐字对应。
  for (var level = 0; level < depth - 1; level++) {
    final index = level + 1;
    final continues =
        index >= ancestorContinuations.length || ancestorContinuations[index];
    if (!continues) continue;
    final x = level * 16.0 + 8;
    result.add((x1: x, y1: 0, x2: x, y2: height));
  }
  final branchX = (depth - 1) * 16.0 + 8;
  result.add((
    x1: branchX,
    y1: 0,
    // 末位子件的竖线收在肘线处（肘形收尾）；还有兄弟就一路画到底，与下一行
    // 顶端接上——guideBleed 保证这一笔跨过表格单元格的纵向内边距。
    x2: branchX,
    y2: isLastChild ? connectorY : height,
  ));
  result.add((x1: branchX, y1: connectorY, x2: width, y2: connectorY));
  return result;
}

class _TreeGuidePainter extends CustomPainter {
  const _TreeGuidePainter({
    required this.depth,
    required this.color,
    required this.ancestorContinuations,
    required this.isLastChild,
    required this.connectorY,
  });

  final int depth;
  final Color color;

  /// `[i]` = 深度 i 的祖先后面还有没有兄弟。长度 = 本行深度
  /// （见 [UtenTreeTableCell.ancestorContinuations]）。
  final List<bool> ancestorContinuations;
  final bool isLastChild;

  /// 肘线横段（也是末位子件竖线的收尾点）在画布上的 y。
  /// 由宿主内边距 + 展开位半高算得，**不是** size.height/2——单元格被
  /// 副标题或邻列撑高时，展开按钮仍固定在顶端 48px 内，取中线会让肘线脱节。
  final double connectorY;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final line in utenTreeGuideSegments(
      depth: depth,
      ancestorContinuations: ancestorContinuations,
      isLastChild: isLastChild,
      height: size.height,
      width: size.width,
      connectorY: connectorY,
    )) {
      canvas.drawLine(
        Offset(line.x1, line.y1),
        Offset(line.x2, line.y2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TreeGuidePainter oldDelegate) =>
      oldDelegate.depth != depth ||
      oldDelegate.color != color ||
      oldDelegate.isLastChild != isLastChild ||
      oldDelegate.connectorY != connectorY ||
      !listEquals(oldDelegate.ancestorContinuations, ancestorContinuations);
}
