import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

const double _treeIndent = 16;
const double _treeToggleExtent = 48;
const double _treeToggleCenter = _treeToggleExtent / 2;

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
    this.titleBadge,
    this.titleBadgeLabel,
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
    this.guideColor,
    this.toggleColor,
    this.indent = _treeIndent,
    this.mutedToggleWhenChildless = false,
  });

  /// 视觉缩进的深度上限（全站一个数，2026-09-15）：与业务侧的 BOM 展开上限
  /// （物料分析级联页 10 层）对齐。原来组件默认 8、级联页显式传 10，同一颗
  /// 第 9/10 层的料在两个页面缩进深浅不同。确有更浅需求的宿主再显式覆盖。
  static const int defaultMaxVisualDepth = 10;

  /// 连接线向单元格上下各溢出多少像素。
  ///
  /// 表格宿主（UtenEditableGrid / MasterDataTableView）给每个单元格加了纵向
  /// 内边距，单元格本身又比行矮——竖线只画到单元格边界时，行与行之间会留出
  /// 一段空白，整列连线看着像虚线（2026-09-14 用户口径「表示层级的竖线不对」）。
  /// 宿主把自己的纵向内边距传进来，连线就跨过那段空白连成一条。
  /// 0 = 独立使用（非表格宿主），不溢出。
  final double guideBleed;

  /// 层级连线的显式用色（2026-10-10 物料分析按产品视图）：非空时本行所有
  /// 连线（祖先竖线、肘线、父行向下引出段）整笔用这一色，优先级高于
  /// [foregroundColor] 的降调与默认明暗两档灰。宿主按「这行属于哪棵子树」
  /// 给色（如按产品序号两色轮换），轮换逻辑由宿主管理，组件不掺和。
  final Color? guideColor;

  /// 展开箭头圆底的显式用色（2026-10-10 物料分析按产品视图）：非空且有
  /// 下级时，圆底用这一色替代 depth%4 轮换的层级色，箭头按既有明暗自适应
  /// （圆底偏深一律反白）；无下级行的灰色占位图标不受影响。与 [guideColor]
  /// 配对使用时整棵子树「连线 + 箭头圆底」同色。默认 null 照旧轮换。
  final Color? toggleColor;

  /// 每级缩进宽度，默认 16。2026-10-10 物料分析口径「下面的箭头跟线挨在
  /// 一起」：连线与圆底按子树上色后，16px 缩进里祖先竖线离箭头圆底只剩
  /// 2px（间隙 = indent − 14），看着粘成一块；宿主可放宽（物料分析主表传
  /// 24，间隙 10px）。只改宽度，层级深度语义仍由 [maxVisualDepth] 与
  /// 序号/标签表达。
  final double indent;

  /// 无下级的行画灰色不可点的展开占位图标（2026-10-09 物料分析口径「没有
  /// 子层级的也在前面加个可以展开的 icon，但是灰色不能点击，统一好看」）：
  /// 展开位不再空着，与有下级行同一位置一枚灰底粗箭头——非按钮、无语义、
  /// 不吃指针，只做对齐。仅在 [showLeafMarker] 关闭时生效（叶子行已有圆点
  /// 标记，再叠占位图标是重复）。默认 false：既有宿主空位保持空位。
  final bool mutedToggleWhenChildless;

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

  /// 名称前的业务徽章（如「顶层」）：与级联号同排、同胶囊形态，但由宿主
  /// 自带整枚 Widget（语义色由徽章自己决定），层级色不掺和。不传即不变。
  final Widget? titleBadge;

  /// [titleBadge] 的语义朗读名（徽章本体在 ExcludeSemantics 里，读不到自己的
  /// 文本）；不传则徽章纯视觉、不进朗读标签。
  final String? titleBadgeLabel;

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
      if (titleBadgeLabel?.trim().isNotEmpty == true) titleBadgeLabel!,
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

    final guideWidth = visualDepth * indent;
    final hasExpandedChildren = hasChildren && expanded;
    // 连接线独立成一层浮在内容背后，高度跟着**整个单元格**（外加宿主的纵向
    // 内边距 [guideBleed]）——原来它被钉死在 48 高的 SizedBox 里，行一旦更高
    // （标题换行 / 有副标题 / 邻列两行文本）竖线就缩在中间，上下各露一截空白。
    // IgnorePointer：这层压住展开按钮左半边，不让它吃掉点击。
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _treeToggleExtent),
      child: Stack(
        clipBehavior: Clip.none,
        // 内容与连接线共用整格中线；邻列撑高或文字放大时仍对齐箭头圆心。
        alignment: Alignment.centerLeft,
        children: [
          if (depth > 0 || hasExpandedChildren)
            Positioned(
              left: 0,
              top: -guideBleed,
              bottom: -guideBleed,
              // 多画半个展开位：肘线的横段一直伸到展开按钮/叶子位的圆心，
              // 行才真的「挂」在树上（原来横段停在缩进区边缘，离标题还有 52px）。
              width: guideWidth + _treeToggleCenter,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TreeGuidePainter(
                    depth: depth,
                    maxVisualDepth: maxVisualDepth,
                    indent: indent,
                    // 连线用色三档：宿主显式色（2026-10-10 按产品轮换）→
                    // 行前景降调 → 默认明暗两档灰。宿主显式色整笔直用、不再
                    // 降调——轮换色的意义就是让整棵子树一眼同色。
                    color:
                        guideColor ??
                        foregroundColor?.withValues(alpha: 0.35) ??
                        // 2026-09-14 用户口径「浅色时候看不清，颜色深点；深色
                        // 模式下浅点」：原来两种明暗都取 outlineVariant——白底上
                        // 它几乎与表格网格线同色。改成按明暗两档对称调：浅色用
                        // onSurfaceVariant 七成不透明（明显能看出层级走向，又不至于
                        // 抢名称），深色用四成（深底上线条本就更跳，压下去才不刺眼）。
                        colors.onSurfaceVariant.withValues(
                          alpha: theme.brightness == Brightness.dark
                              ? 0.40
                              : 0.70,
                        ),
                    ancestorContinuations: ancestorContinuations,
                    isLastChild: isLastChild,
                    hasExpandedChildren: hasExpandedChildren,
                  ),
                ),
              ),
            ),
          Row(
            children: [
              SizedBox(width: guideWidth),
              SizedBox(
                width: _treeToggleExtent,
                height: _treeToggleExtent,
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
                            width: _treeToggleExtent,
                            height: _treeToggleExtent,
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
                            background:
                                toggleColor ?? foregroundColor ?? levelColor,
                            foreground: _toggleForeground(
                              circleColor:
                                  toggleColor ?? foregroundColor ?? levelColor,
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
                    : mutedToggleWhenChildless
                    ? ExcludeSemantics(
                        // 灰色占位展开图标（见字段注释）：同位置同尺寸，只是
                        // 灰底灰箭头、不可点也不进语义——一眼区分「能展开」
                        // 与「没有下级」，整列仍然对齐。
                        child: Center(
                          child: _ToggleGlyph(
                            expanded: false,
                            background: colors.onSurfaceVariant.withValues(
                              alpha: 0.16,
                            ),
                            foreground: colors.onSurfaceVariant.withValues(
                              alpha: 0.45,
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
                              if (titleBadge != null) ...[
                                titleBadge!,
                                const SizedBox(width: UtenSpacing.s4),
                              ],
                              Expanded(
                                child: Text(
                                  title,
                                  // 单行省略号（2026-09-16 全站口径）：树格名称
                                  // 不再折两行撑高整行，列宽由宿主列 textOf 量宽。
                                  maxLines: 1,
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
                              if (titleBadge != null) ...[
                                titleBadge!,
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
                            // 同上：单行省略号，不折两行撑高整行。
                            maxLines: 1,
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
  bool hasExpandedChildren = false,
  int maxVisualDepth = UtenTreeTableCell.defaultMaxVisualDepth,
  double indent = _treeIndent,
}) {
  final result = <({double x1, double y1, double x2, double y2})>[];
  double centerX(int level) =>
      level.clamp(0, maxVisualDepth) * indent + _treeToggleCenter;

  if (depth > 0) {
    // 每条竖线与对应父行的箭头圆心同轴。槽 level 承载深度 level+1
    // 节点的兄弟连接，仍按投影的绝对祖先深度读取续线标记。
    // 超过视觉深度上限后多层共用一条轨道，任一祖先仍有兄弟就续到行底。
    final verticalEnds = <double, double>{};
    for (var level = 0; level < depth - 1; level++) {
      final index = level + 1;
      final continues =
          index >= ancestorContinuations.length || ancestorContinuations[index];
      if (continues) verticalEnds[centerX(level)] = height;
    }
    final branchX = centerX(depth - 1);
    verticalEnds.putIfAbsent(branchX, () => isLastChild ? connectorY : height);
    for (final line in verticalEnds.entries) {
      result.add((x1: line.key, y1: 0, x2: line.key, y2: line.value));
    }
    if (branchX < width) {
      result.add((x1: branchX, y1: connectorY, x2: width, y2: connectorY));
    }
  }
  // 父行先从箭头圆心向下引出，再由下一行顶端接续；根行也必须画这一段。
  // 折叠时子行不显示，对应的向下连接也一起收起。
  final childStemAlreadyDrawn = result.any(
    (line) =>
        line.x1 == width &&
        line.x2 == width &&
        line.y1 <= connectorY &&
        line.y2 == height,
  );
  if (hasExpandedChildren && !childStemAlreadyDrawn) {
    result.add((x1: width, y1: connectorY, x2: width, y2: height));
  }
  return result;
}

class _TreeGuidePainter extends CustomPainter {
  const _TreeGuidePainter({
    required this.depth,
    required this.maxVisualDepth,
    required this.indent,
    required this.color,
    required this.ancestorContinuations,
    required this.isLastChild,
    required this.hasExpandedChildren,
  });

  final int depth;
  final int maxVisualDepth;
  final double indent;
  final Color color;

  /// `[i]` = 深度 i 的祖先后面还有没有兄弟。长度 = 本行深度
  /// （见 [UtenTreeTableCell.ancestorContinuations]）。
  final List<bool> ancestorContinuations;
  final bool isLastChild;

  final bool hasExpandedChildren;

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
      // Stack 和 Row 都垂直居中，画布上下 bleed 对称，故中线即箭头圆心。
      connectorY: size.height / 2,
      hasExpandedChildren: hasExpandedChildren,
      maxVisualDepth: maxVisualDepth,
      indent: indent,
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
      oldDelegate.maxVisualDepth != maxVisualDepth ||
      oldDelegate.indent != indent ||
      oldDelegate.color != color ||
      oldDelegate.isLastChild != isLastChild ||
      oldDelegate.hasExpandedChildren != hasExpandedChildren ||
      !listEquals(oldDelegate.ancestorContinuations, ancestorContinuations);
}
