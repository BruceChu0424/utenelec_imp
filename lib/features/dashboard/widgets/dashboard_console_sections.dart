// 工作台部门指标带与横向待办网格，使用真实计数、截止时间与目标路由。
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

class DashboardMetricStrip extends StatefulWidget {
  const DashboardMetricStrip({
    super.key,
    required this.metrics,
    required this.departmentName,
    this.sweepTrigger = 0,
  });
  final List<DashboardMetric> metrics;
  final String departmentName;
  final int sweepTrigger;

  @override
  State<DashboardMetricStrip> createState() => _DashboardMetricStripState();
}

class _DashboardMetricStripState extends State<DashboardMetricStrip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.metrics.isEmpty) {
      return _DepartmentEmpty(
        icon: Icons.insights_outlined,
        message: widget.departmentName.isEmpty
            ? '本部门暂无概览指标'
            : '${widget.departmentName}暂无概览指标',
      );
    }
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaledWidth =
            constraints.maxWidth /
            MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.6);
        final maxColumns = scaledWidth >= 1050
            ? 4
            : scaledWidth >= 680
            ? 3
            : scaledWidth >= 420
            ? 2
            : 1;
        final columns = maxColumns.clamp(1, widget.metrics.length);
        final visible = _expanded
            ? widget.metrics
            : widget.metrics.take(columns).toList();
        return UtenConsolePanel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var start = 0; start < visible.length; start += columns) ...[
                if (start > 0) Divider(height: 1, color: colors.outlineVariant),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var col = 0; col < columns; col++) ...[
                        if (col > 0)
                          VerticalDivider(
                            width: 1,
                            color: colors.outlineVariant.withValues(alpha: .6),
                          ),
                        Expanded(
                          child: start + col < visible.length
                              ? _MetricCell(metric: visible[start + col])
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (widget.metrics.length > columns)
                TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                  label: Text(
                    _expanded
                        ? '收起'
                        : '展开其余 ${widget.metrics.length - visible.length} 项',
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.metric});
  final DashboardMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = dashboardToneColor(theme, metric.tone);
    final numeric = double.tryParse(metric.value.replaceAll(',', ''));
    final valueStyle = theme.textTheme.headlineMedium?.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Semantics(
      button: metric.route != null,
      label: '${metric.title}，${metric.value}，${metric.subtitle}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: metric.route == null
              ? null
              : () => goFrom(context, metric.route!),
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        metric.title,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      metric.sensitive
                          ? Icons.lock_outline
                          : dashboardMetricIcon(metric.id),
                      size: 18,
                      color: color,
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s8),
                numeric == null
                    ? Text(metric.value, style: valueStyle)
                    : UtenAnimatedNumber(value: numeric, style: valueStyle),
                if (metric.subtitle.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s4),
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
        ),
      ),
    );
  }
}

/// 宽屏并排展示任务队列，窄屏按实际可用宽度换行。
class DashboardTodoLane extends StatelessWidget {
  const DashboardTodoLane({
    super.key,
    required this.todos,
    required this.departmentName,
    this.sweepTrigger = 0,
  });
  final List<DashboardTodo> todos;
  final String departmentName;
  final int sweepTrigger;

  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) {
      return _DepartmentEmpty(
        icon: Icons.task_alt_rounded,
        message: departmentName.isEmpty ? '本部门当前没有待办' : '$departmentName当前没有待办',
      );
    }
    final ordered = [...todos]
      ..sort((a, b) {
        final urgency = b.urgentCount.compareTo(a.urgentCount);
        if (urgency != 0) return urgency;
        if (a.dueAt != null && b.dueAt != null) {
          return a.dueAt!.compareTo(b.dueAt!);
        }
        return todos.indexOf(a).compareTo(todos.indexOf(b));
      });
    return LayoutBuilder(
      builder: (context, constraints) {
        final minWidth =
            300 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.6);
        final columns = ((constraints.maxWidth + 12) / (minWidth + 12))
            .floor()
            .clamp(1, todos.length.clamp(1, 4));
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final todo in ordered)
              SizedBox(
                key: ValueKey('dashboard-todo-${todo.id}'),
                width: width,
                child: _TodoTile(todo: todo),
              ),
          ],
        );
      },
    );
  }
}

class _TodoTile extends StatelessWidget {
  const _TodoTile({required this.todo});
  final DashboardTodo todo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = dashboardToneColor(theme, todo.tone);
    final urgent = todo.urgentCount > 0 || todo.tone == 'danger';
    return Semantics(
      button: todo.route != null,
      label:
          '${todo.title}，${todo.count} 项${urgent ? '，紧急' : ''}${_DueCountdownChip.describe(todo.dueAt)}，${todo.summary}',
      child: ExcludeSemantics(
        child: UtenConsolePanel(
          padding: EdgeInsets.zero,
          child: InkWell(
            onTap: todo.route == null
                ? null
                : () => goFrom(context, todo.route!),
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (urgent)
                        UtenLivePulseDot(color: color, pulse: todo.count)
                      else
                        Icon(
                          Icons.pending_actions_outlined,
                          color: theme.colorScheme.primary,
                          size: 18,
                        ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          todo.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      UtenNotificationBadge(count: todo.count, size: 20),
                    ],
                  ),
                  if (todo.summary.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      todo.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (todo.dueAt != null)
                        _DueCountdownChip(dueAt: todo.dueAt!),
                      if (urgent)
                        Text(
                          '需优先处理',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: color,
                          ),
                        ),
                      if (todo.route != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '去处理',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_rounded,
                              size: 15,
                              color: theme.colorScheme.primary,
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DepartmentEmpty extends StatelessWidget {
  const _DepartmentEmpty({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenConsolePanel(
      child: Row(
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
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
