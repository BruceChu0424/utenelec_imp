// 工作台「今日概览 / 待办任务」的控制台形态（2026-09-12 改版）。
//
// 改版缘由（用户原话）：「今日概览 和 待办任务 能不能设计的不是卡片，能够更好看、
// UI 更酷炫、更加高级、很科幻」。
//
// ## 做了什么
//
// - **今日概览**：N 张独立卡片 → **一整条指标带**（[UtenConsolePanel] 里用 1px 细线
//   切格）。每格左侧一条竖状态条 + 图标，标题压成小字放开字距，数值用最大字重、
//   等宽数字并做滚动上数（[UtenAnimatedNumber]）。视觉重量从"卡片边框与阴影"
//   转移到"数据本身"。
// - **待办任务**：折叠列表 → **优先级泳道**。左侧一条竖轴，每条待办是轴上的节点；
//   紧急项节点更大，并在计数变化时脉冲一次（复用 [UtenLivePulseDot]，一次性不循环）。
// - **任务计时器**（2026-09-11 补）：服务端一直在下发 dueAt，模型解析完却没展示。
//   现在每条有截止的待办带一枚倒计时芯片（逾期红 / 临期 6 小时内黄 / 其余中性），
//   等宽数字。紧急待办底部加一条紧急占比负荷条（urgentCount/count 的真实比例）。
// - **数据到达扫光**（2026-09-11 补）：[UtenConsolePanel.sweepTrigger] 之前定义了
//   却没人传——现在两块都接 data.generatedAt，数据每次到达（含手动刷新）扫一次。
//
// ## 刻意没做的
//
// - 没上霓虹/高饱和渐变：本系统是车间与财务每天盯的 ERP，项目准则里有适老化基线与
//   WCAG 对比度要求，霓虹会直接违反。"科幻感"由结构、细线、背景辉光承担，
//   前景文字一律实色高对比。
// - 没做视差、没做 3D 倾斜：对滚动性能与眩晕敏感人群都是负担，收益只有"看起来炫"。
//
// ## 无障碍
//
// - `MediaQuery.disableAnimationsOf` 为真、lite 档或 `TickerMode` 关闭时：不扫光、
//   不脉冲、数值不滚动；静态形态信息完整（动效不承载任何信息）。紧急与否始终由
//   节点尺寸、颜色、字重与红徽章表达，不靠"在动"。
// - 状态不只靠颜色：每格有图标 + 竖条 + 文案（准则 §1 color-not-only）。
// - 不设固定高度，字号放到最大档时面板长高而非裁切。
// - 每格/每行都有 Semantics 标签，读屏能念出「标题，数值，副标题」。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_animated_number.dart';
import '../../../components/feedback/uten_live_pulse_dot.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/dashboard_overview.dart';
import 'dashboard_overview_sections.dart'
    show dashboardMetricIcon, dashboardToneColor;
import 'uten_console_panel.dart';

/// 指标带：连续面板内用细线切格，不是卡片堆。
class DashboardMetricStrip extends StatefulWidget {
  const DashboardMetricStrip({
    super.key,
    required this.metrics,
    required this.departmentName,
    this.sweepTrigger = 0,
  });

  final List<DashboardMetric> metrics;
  final String departmentName;

  /// 传给 [UtenConsolePanel.sweepTrigger]：数据每次到达（含手动刷新）扫一次光。
  final int sweepTrigger;

  @override
  State<DashboardMetricStrip> createState() => _DashboardMetricStripState();
}

class _DashboardMetricStripState extends State<DashboardMetricStrip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.metrics.isEmpty) {
      return UtenConsolePanel(
        sweepTrigger: widget.sweepTrigger,
        child: Row(
          children: [
            Icon(
              Icons.sensors_off_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                widget.departmentName.isEmpty
                    ? '本部门暂无概览指标'
                    : '${widget.departmentName}暂无概览指标',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 列数与旧实现保持一致的断点，避免改版顺手改了响应式行为。
        final columns = constraints.maxWidth >= 1050
            ? 4
            : constraints.maxWidth >= 680
            ? 3
            : constraints.maxWidth >= 420
            ? 2
            : 1;
        final overflow = widget.metrics.length > columns;
        final visible = _expanded
            ? widget.metrics
            : widget.metrics.take(columns).toList();
        final hidden = widget.metrics.length - visible.length;

        return UtenConsolePanel(
          padding: EdgeInsets.zero,
          sweepTrigger: widget.sweepTrigger,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 分行渲染：行内用竖线分隔、行间用横线分隔，拼出一张连续的仪表格，
              // 而不是 N 个各带边框的卡片。
              for (var row = 0; row * columns < visible.length; row++) ...[
                if (row > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (
                        var col = 0;
                        col < columns && row * columns + col < visible.length;
                        col++
                      ) ...[
                        if (col > 0)
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        Expanded(
                          child: _MetricCell(
                            metric: visible[row * columns + col],
                          ),
                        ),
                      ],
                      // 末行不足整列时补空白格，保证竖线对齐、不出现半截格。
                      for (
                        var pad = visible.length - row * columns;
                        pad < columns &&
                            row * columns + columns > visible.length;
                        pad++
                      ) ...[
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.6,
                          ),
                        ),
                        const Expanded(child: SizedBox.shrink()),
                      ],
                    ],
                  ),
                ),
              ],
              if (overflow) ...[
                Divider(
                  height: 1,
                  thickness: 1,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                  ),
                  label: Text(_expanded ? '收起' : '展开其余 $hidden 项'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 单个指标格：竖状态条 + 图标 + 小标题 + 大数值。
class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.metric});

  final DashboardMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = dashboardToneColor(theme, metric.tone);
    final numeric = double.tryParse(metric.value.replaceAll(',', ''));
    final tappable = metric.route != null;

    return Semantics(
      button: tappable,
      label: '${metric.title}，${metric.value}，${metric.subtitle}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: tappable ? () => goFrom(context, metric.route!) : null,
          child: Stack(
            children: [
              // 巨型数字水印：同一个数值当底纹重复一次，格子立刻有分量。
              Positioned.fill(
                child: UtenGhostNumeral(text: metric.value, color: color),
              ),
              _body(context, theme, color, numeric, tappable),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    ThemeData theme,
    Color color,
    double? numeric,
    bool tappable,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 竖状态条：色盲用户靠它 + 图标分档，不只靠颜色。
          Container(
            width: 3,
            margin: const EdgeInsets.only(
              top: 2,
              bottom: 2,
              right: UtenSpacing.s12,
            ),
            constraints: const BoxConstraints(minHeight: 36),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      metric.sensitive
                          ? Icons.lock_outline_rounded
                          : dashboardMetricIcon(metric.id),
                      size: 15,
                      color: color,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        metric.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 数值是这一格的主角：最大字重 + 等宽数字（列对齐不跳动）。
                // 能解析成数字的才滚动；"—"「已锁定」这类文案原样显示。
                numeric == null
                    ? Text(
                        metric.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      )
                    : UtenAnimatedNumber(
                        value: numeric,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                if (metric.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    metric.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (tappable)
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
  }
}

/// 待办泳道：左侧竖轴 + 节点，紧急项节点更大并带脉冲环。
class DashboardTodoLane extends StatelessWidget {
  const DashboardTodoLane({
    super.key,
    required this.todos,
    required this.departmentName,
    this.sweepTrigger = 0,
  });

  final List<DashboardTodo> todos;
  final String departmentName;

  /// 同 [DashboardMetricStrip.sweepTrigger]。
  final int sweepTrigger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (todos.isEmpty) {
      return UtenConsolePanel(
        sweepTrigger: sweepTrigger,
        child: Row(
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                departmentName.isEmpty ? '本部门当前没有待办' : '$departmentName当前没有待办',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return UtenConsolePanel(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s8,
      ),
      sweepTrigger: sweepTrigger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < todos.length; i++)
            _TodoNode(
              todo: todos[i],
              isFirst: i == 0,
              isLast: i == todos.length - 1,
            ),
        ],
      ),
    );
  }
}

class _TodoNode extends StatelessWidget {
  const _TodoNode({
    required this.todo,
    required this.isFirst,
    required this.isLast,
  });

  final DashboardTodo todo;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = dashboardToneColor(theme, todo.tone);
    final urgent = todo.urgentCount > 0 || todo.tone == 'danger';
    final axis = theme.colorScheme.outlineVariant;

    return Semantics(
      button: todo.route != null,
      label:
          '${todo.title}，${todo.count} 项${urgent ? '，紧急' : ''}'
          '${_DueCountdownChip.describe(todo.dueAt)}，${todo.summary}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: todo.route == null ? null : () => goFrom(context, todo.route!),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 竖轴 + 节点：首尾各截掉半段轴线，让整条泳道有起止感。
                SizedBox(
                  width: 26,
                  child: Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: Container(
                            width: 2,
                            color: isFirst ? Colors.transparent : axis,
                          ),
                        ),
                      ),
                      // 轴上的节点。脉冲光晕一次性播放，计数变化时才响一下——
                      // 无限循环的呼吸灯在保活的工作台 Tab 上会一直烧帧，也过不了
                      // 准则 07 §七 的门槛。lite/减少动画/TickerMode 关闭由
                      // UtenLivePulseDot 内部兜底，这里只决定"要不要有节奏"。
                      UtenLivePulseDot(
                        pulse: urgent ? todo.count : 0,
                        color: color,
                        size: urgent ? 14 : 10,
                      ),
                      Expanded(
                        child: Center(
                          child: Container(
                            width: 2,
                            color: isLast ? Colors.transparent : axis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                todo.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: urgent
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: UtenSpacing.s8),
                            UtenNotificationBadge(count: todo.count, size: 18),
                          ],
                        ),
                        if (todo.summary.isNotEmpty || todo.dueAt != null) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Expanded(
                                child: todo.summary.isEmpty
                                    ? const SizedBox.shrink()
                                    : Text(
                                        todo.summary,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                              ),
                              // 截止倒计时芯片：任务控制台的「任务计时器」。
                              // 服务端早就给了 dueAt，此前模型解析完就扔了。
                              if (todo.dueAt != null) ...[
                                const SizedBox(width: UtenSpacing.s8),
                                _DueCountdownChip(dueAt: todo.dueAt!),
                              ],
                            ],
                          ),
                        ],
                        // 紧急占比负荷条：urgentCount/count 的真实比例，不是装饰。
                        // 没有紧急项时不画——干净比满装饰重要。
                        if (todo.urgentCount > 0) ...[
                          const SizedBox(height: 6),
                          _UrgencyMeter(
                            count: todo.count,
                            urgentCount: todo.urgentCount,
                            color: color,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (todo.route != null)
                  Center(
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 截止倒计时芯片：逾期红、临期黄、其余中性；等宽数字，读起来像仪器计时。
class _DueCountdownChip extends StatelessWidget {
  const _DueCountdownChip({required this.dueAt});

  final DateTime dueAt;

  /// 读屏用的一句话描述（Semantics label 拼接用）；无截止时间返回空串。
  static String describe(DateTime? dueAt) {
    if (dueAt == null) return '';
    final remaining = dueAt.difference(DateTime.now());
    if (remaining.isNegative) return '，已逾期 ${_format(-remaining)}';
    return '，剩余 ${_format(remaining)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = dueAt.difference(DateTime.now());
    final overdue = remaining.isNegative;
    final imminent = !overdue && remaining <= const Duration(hours: 6);
    final color = overdue
        ? theme.colorScheme.error
        : imminent
        ? UtenColors.warningText
        : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: UtenRadius.pillAll,
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            overdue ? Icons.event_busy_rounded : Icons.schedule_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            overdue ? '已逾期 ${_format(-remaining)}' : '剩 ${_format(remaining)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  static String _format(Duration value) {
    if (value.inMinutes < 60) return '${value.inMinutes} 分钟';
    if (value.inHours < 48) return '${value.inHours} 小时';
    return '${value.inDays} 天';
  }
}

/// 紧急占比负荷条：urgent 段着色、其余走中性底，一眼看出这条队列有多「烫」。
class _UrgencyMeter extends StatelessWidget {
  const _UrgencyMeter({
    required this.count,
    required this.urgentCount,
    required this.color,
  });

  final int count;
  final int urgentCount;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = count <= 0
        ? 0.0
        : (urgentCount / count).clamp(0.0, 1.0).toDouble();
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: Stack(
          children: [
            ColoredBox(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
            FractionallySizedBox(
              widthFactor: fraction,
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
