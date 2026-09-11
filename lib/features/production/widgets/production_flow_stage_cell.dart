import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/production_flow_stage.dart';

/// 流程阶段徽章：图标 + 词表标签，表格单元格通用。
///
/// 词表与阶段推导见 [ProductionFlowStage]；本组件只负责展示，
/// 不承载任何状态判定逻辑。
class ProductionFlowStageBadge extends StatelessWidget {
  const ProductionFlowStageBadge({super.key, required this.stage});

  final ProductionFlowStage stage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = productionFlowToneColor(theme, stage.tone);
    return Semantics(
      container: true,
      label: stage.displayLabel,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(stage.icon, size: 16, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                stage.displayLabel,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 流程进度条：线性进度 + 百分比文字（顶层产品完工进度 / 车间报工进度）。
class ProductionFlowProgress extends StatelessWidget {
  const ProductionFlowProgress({
    super.key,
    required this.ratio,
    this.height = 8,
    this.showPercentText = true,
    this.semanticsLabel,
  });

  /// 0-1；null 表示尚无可计算的进度（不伪装 0%）。
  final double? ratio;
  final double height;
  final bool showPercentText;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = ratio == null || !ratio!.isFinite
        ? null
        : ratio!.clamp(0.0, 1.0).toDouble();
    // 无可计算进度时不渲染进度条（不用不确定动画条，也不用 0% 伪装）。
    if (value == null) {
      return Text(
        '—',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final percent = value >= 1 ? 100 : (value * 100).round().clamp(0, 99);
    final label = semanticsLabel ?? '进度';
    return Semantics(
      container: true,
      label: '$label $percent%',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(height / 2),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: height,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
                ),
              ),
            ),
            if (showPercentText) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 44,
                child: Text(
                  '$percent%',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 流程步骤条：快递追踪式横向步骤（详情弹窗 / 计划详情页头部）。
///
/// 已完成的步骤打勾着色，当前步骤高亮，未开始的步骤置灰；
/// 步骤名直接取自 [ProductionFlowStage] 所在链的词表。
class ProductionFlowSteps extends StatelessWidget {
  const ProductionFlowSteps({
    super.key,
    required this.route,
    required this.activeIndex,
    this.compact = false,
  });

  final ProductionFlowRoute route;
  final int activeIndex;

  /// 紧凑模式：只渲染圆点，不带步骤文字（窄屏/表格内用）。
  final bool compact;

  static const List<String> _makeSteps = [
    '等待下达车间',
    '计划待审核',
    '等待物料',
    '物料齐套 · 可开工',
    '生产中 · 可报工',
    '已完工',
  ];
  static const List<String> _buySteps = [
    '等待下发采购',
    '等待下单',
    '待财务审批',
    '等待收货',
    '等待品质验货',
    '等待入库',
    '已入库',
  ];
  static const List<String> _subcontractSteps = [
    '等待下发委外',
    '等待下单',
    '待财务审批',
    '目标件出仓',
    '等待回厂',
    '等待品质验货',
    '等待入库',
    '已入库',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final steps = switch (route) {
      ProductionFlowRoute.make => _makeSteps,
      ProductionFlowRoute.buy => _buySteps,
      ProductionFlowRoute.subcontract => _subcontractSteps,
    };
    final active = activeIndex.clamp(0, steps.length - 1);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var index = 0; index < steps.length; index++)
            _step(context, theme, steps[index], index, active, steps.length),
        ],
      ),
    );
  }

  Widget _step(
    BuildContext context,
    ThemeData theme,
    String label,
    int index,
    int active,
    int total,
  ) {
    final done = index < active;
    final isCurrent = index == active;
    final color = done
        ? theme.colorScheme.primary
        : isCurrent
        ? theme.colorScheme.tertiary
        : theme.colorScheme.outlineVariant;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          done
              ? Icons.check_circle_rounded
              : isCurrent
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_off_rounded,
          size: compact ? 14 : 18,
          color: color,
        ),
        if (!compact) ...[
          const SizedBox(width: 4),
          Text(
            label,
            style:
                (compact
                        ? theme.textTheme.labelSmall
                        : theme.textTheme.bodySmall)
                    ?.copyWith(
                      color: color,
                      fontWeight: isCurrent ? FontWeight.w700 : null,
                    ),
          ),
        ],
        if (index < total - 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Container(
              width: compact ? 10 : 18,
              height: 2,
              color: done
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
      ],
    );
    return row;
  }
}

/// 词表阶段 → 徽章类型的映射（需要胶囊形态时用 UtenStatusBadge）。
UtenStatusBadgeType productionFlowBadgeType(ProductionFlowStage stage) =>
    switch (stage.tone) {
      ProductionFlowTone.done => UtenStatusBadgeType.success,
      ProductionFlowTone.active => UtenStatusBadgeType.info,
      ProductionFlowTone.ready => UtenStatusBadgeType.info,
      ProductionFlowTone.toDraw => UtenStatusBadgeType.warning,
      ProductionFlowTone.waiting => UtenStatusBadgeType.warning,
      ProductionFlowTone.pending => UtenStatusBadgeType.neutral,
    };

/// 阶段色调 → 颜色。一处定义，图标/文字/时间线点/产品卡共用，
/// 避免各页各写一套 switch 又漏掉新档（2026-09-11 扩到 6 档时的教训）。
Color productionFlowToneColor(ThemeData theme, ProductionFlowTone tone) =>
    switch (tone) {
      ProductionFlowTone.done => theme.colorScheme.primary,
      ProductionFlowTone.active => UtenColors.teal600,
      // 「可开工」与「生产中」相邻，必须换一个色系才分得开。
      ProductionFlowTone.ready => UtenColors.info,
      // 「去领料」= 本人得跑一趟仓库，全链最需要被一眼看到。
      ProductionFlowTone.toDraw => UtenColors.catAmber,
      ProductionFlowTone.waiting => UtenColors.warning,
      ProductionFlowTone.pending => theme.colorScheme.outline,
    };
