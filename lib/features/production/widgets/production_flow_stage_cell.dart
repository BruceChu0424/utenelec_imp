import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/production_flow_stage.dart';

/// 流程进度条：线性进度 + 百分比文字（顶层产品完工进度 / 车间报工进度）。
///
/// 2026-09-27 用户口径「所有进度颜色统一」：全站业务进度条（线性 + 环形
/// ProgressRing + 各表格内裸 LinearProgressIndicator）统一主题主色，
/// 不再随状态/百分比变色；本组件是公共落点之一。
class ProductionFlowProgress extends StatelessWidget {
  const ProductionFlowProgress({
    super.key,
    required this.ratio,
    this.height = 8,
    this.showPercentText = true,
    this.semanticsLabel,
    this.color,
  });

  /// 0-1；null 表示尚无可计算的进度（不伪装 0%）。
  final double? ratio;
  final double height;

  /// 进度条前景色；null = 主题主色（全站进度统一色）。
  final Color? color;
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
                  valueColor: AlwaysStoppedAnimation(
                    color ?? theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            if (showPercentText) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: 44,
                child: Text(
                  '$percent%',
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
    '领料发外',
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

/// 词表阶段 → 徽章档位（ADR-169 档位锚定，2026-10-08 重定）。
///
/// 本表服务「我的车间任务」的**生产中/历史段**整格底色，并作为词表兜底档位：
/// 同一分段的同现状态互可区分、不违背锚定语义；与 [productionReadinessCellColor]
/// （等待物料段独立口径）按分段各自独立，不强求跨段同色。
UtenStatusBadgeType productionFlowBadgeType(ProductionFlowStage stage) =>
    switch (stage.tone) {
      ProductionFlowTone.done => UtenStatusBadgeType.success,
      // 生产中=车间自己正在执行（info 蓝）；「他方执行中」的青绿档留给
      // 仓库处理中(pending)与计划详情等统筹视角。
      ProductionFlowTone.active => UtenStatusBadgeType.info,
      ProductionFlowTone.ready => UtenStatusBadgeType.success,
      // 部分已投可开工=紫（部分就绪档，与全领齐的绿分开）。
      ProductionFlowTone.readyPartial => UtenStatusBadgeType.violet,
      ProductionFlowTone.toDraw => UtenStatusBadgeType.info,
      ProductionFlowTone.toDrawPartial => UtenStatusBadgeType.accent,
      // 生产中段里的 waiting 是「已报完 · 待品质/待入库」——等待外部且无异常，
      // 取琥珀（不是等待物料段的缺料红，两段独立口径）。
      ProductionFlowTone.waiting => UtenStatusBadgeType.warning,
      ProductionFlowTone.waitPlanning => UtenStatusBadgeType.fuchsia,
      ProductionFlowTone.decide => UtenStatusBadgeType.danger,
      // 生产中/历史段里的 pending 是报工草稿待审核/已拆分/已取消——中性灰。
      ProductionFlowTone.pending => UtenStatusBadgeType.neutral,
    };

/// 等待物料状态列的**整格底色**（等待物料段独立口径，ADR-169 档位锚定）。
///
/// 色源一律走 `utenStatusBadgeCellColor`（深色实底、明暗同色），文字对比度由
/// MasterDataTableView 的 cellColor 双向约定自动保证（深底白字、浅底黑字）。
/// 八档同现互可区分（2026-09-26 用户口径「不同就绪度颜色差别大点」延续）：
///
/// - 可开工（物料已领齐/齐套/无需领料）—— 绿 success：就绪可动手的绿灯。
/// - 部分物料已投 · 可开工 —— 紫 violet：部分就绪。锚定把「部分已投可开工」
///   与「部分物料可领」同归紫族，但两档同页同现必须互可区分（硬规矩），
///   紫给「已投可开工」（原先此处为琥珀/青绿，2026-10-08 改锚）。
/// - 物料已备齐 · 去领料 —— 蓝 info：2026-09-26 用户拍板的动作分类色
///   （绿=开工、蓝=去领料两个动作一眼分开；锚定的「可领=绿」在同为绿灯的
///   可开工同现时让位给同页可区分硬规矩）。
/// - 部分物料可领 · 去领料 —— 亮琥珀 warning：部分到位、余量等到货——
///   「可先领这部分+其余等外部」的提示档（紫已被部分已投占用）。
/// - 已提交领料 · 待仓库发料 —— 青绿 accent：仓库正在处理（他方执行中）。
/// - 缺料等待（等到货/等自制子件/等待到齐）—— 红 danger：料没到齐=车间被
///   锁死不能开工，用户口径「不能往下=红」；ADR-169 明确「不能执行不是等待」
///   （委外等物料齐套走红是本次改版的锚定正例）。原先的灰不再表示缺料。
/// - 等计划下单 —— 品红 fuchsia：分类强调（料还没人去订，区别于已下单在途）。
/// - 待选生产路线 —— 橙 orange：阻断但车间**自己一选即解锁**（需决定的注意档）；
///   真正的深红留给「等外部到货、自己解决不了」的缺料——红橙相邻靠明度分层，
///   语义确实不同（ADR-169 §2.2 红橙同页的适用场景）。
///
/// [ProductionFlowTone.active] / [ProductionFlowTone.done] 只出现在生产中/历史段，
/// 不铺整格色，返回 null。
Color? productionReadinessCellColor(ProductionFlowTone tone) =>
    switch (_readinessBadgeType(tone)) {
      null => null,
      final type => utenStatusBadgeCellColor(type),
    };

UtenStatusBadgeType? _readinessBadgeType(ProductionFlowTone tone) =>
    switch (tone) {
      ProductionFlowTone.ready => UtenStatusBadgeType.success,
      ProductionFlowTone.readyPartial => UtenStatusBadgeType.violet,
      ProductionFlowTone.toDraw => UtenStatusBadgeType.info,
      ProductionFlowTone.toDrawPartial => UtenStatusBadgeType.warning,
      ProductionFlowTone.pending => UtenStatusBadgeType.accent,
      ProductionFlowTone.waiting => UtenStatusBadgeType.danger,
      ProductionFlowTone.waitPlanning => UtenStatusBadgeType.fuchsia,
      ProductionFlowTone.decide => UtenStatusBadgeType.orange,
      ProductionFlowTone.active => null,
      ProductionFlowTone.done => null,
    };

/// 阶段色调 → 图标/文字色。一处定义，图标/文字/时间线点/产品卡共用，
/// 避免各页各写一套 switch 又漏掉新档（2026-09-11 扩到 6 档时的教训）。
/// 供计划详情执行段计数、物料分析产品行等**统筹视角**的图标/文字着色
/// （浅色档深、深色档亮，成对出现）；与徽章/整格档位（ADR-169 实底十档）
/// 同族不同表——本表按主题适配前景，消费方所在页与车间任务页独立配色，
/// 不逐档对齐（如 active 在统筹视角是品牌青绿「他方执行中」，车间任务
/// 生产中段是 info 蓝「自己正在执行」）。waiting 在本表保持琥珀：它的
/// 消费方多为「等收货/待品质」等等待外部无异常的语境。
Color productionFlowToneColor(ThemeData theme, ProductionFlowTone tone) =>
    switch (tone) {
      ProductionFlowTone.done =>
        theme.brightness == Brightness.dark
            ? UtenColors.successOnDark
            : UtenColors.success,
      ProductionFlowTone.active => UtenColors.teal600,
      ProductionFlowTone.ready =>
        theme.brightness == Brightness.dark
            ? UtenColors.successOnDark
            : UtenColors.success,
      ProductionFlowTone.readyPartial => UtenColors.teal600,
      ProductionFlowTone.toDraw =>
        theme.brightness == Brightness.dark
            ? UtenColors.infoOnDark
            : UtenColors.info,
      ProductionFlowTone.toDrawPartial =>
        theme.brightness == Brightness.dark
            ? UtenColors.violetOnDark
            : UtenColors.violet,
      ProductionFlowTone.waiting => UtenColors.warning,
      ProductionFlowTone.waitPlanning =>
        theme.brightness == Brightness.dark
            ? UtenColors.fuchsiaOnDark
            : UtenColors.fuchsia,
      ProductionFlowTone.decide =>
        theme.brightness == Brightness.dark
            ? UtenColors.errorOnDark
            : UtenColors.error,
      ProductionFlowTone.pending => theme.colorScheme.outline,
    };
