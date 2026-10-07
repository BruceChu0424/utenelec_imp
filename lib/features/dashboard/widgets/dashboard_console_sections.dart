// 工作台「今日概览」合并面板：标题栏、横向指标带与待办任务共用一块面板。
// 指标从未读通知右侧依次排列，空间不足时换行；宽屏右侧放待办任务，
// 窄屏待办移到指标下方。待办只显示一行，剩余任务通过行末入口查看。
// 使用真实计数、截止时间与目标路由。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_animated_number.dart';
import '../../../components/feedback/uten_live_pulse_dot.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/dashboard_overview.dart';
import 'dashboard_overview_sections.dart' show dashboardToneColor;
import 'uten_console_panel.dart';

/// 今日概览合并面板：横向指标带 + 待办任务装进同一块面板。
///
/// 结构：标题栏（今日概览 + 部门范围 + 采样时刻）→ [celebration] 插槽 →
/// 面板体(宽屏：指标带 │ 竖线 │ 待办区并排；窄屏：上下堆叠)。
/// 两区空态各自说明「本部门」，不用隐藏组件替代数据授权。
class DashboardOverviewPanel extends StatelessWidget {
  const DashboardOverviewPanel({
    super.key,
    required this.metrics,
    required this.todos,
    required this.departmentName,
    required this.generatedAt,
    this.celebration,
  });

  final List<DashboardMetric> metrics;
  final List<DashboardTodo> todos;
  final String departmentName;
  final DateTime generatedAt;

  /// 插在标题栏与面板体之间的插槽（今日庆典卡；无庆典时不传，不占位）。
  final Widget? celebration;

  @override
  Widget build(BuildContext context) {
    return UtenConsolePanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelHeaderBand(
            departmentName: departmentName,
            generatedAt: generatedAt,
          ),
          if (celebration != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                UtenSpacing.s12,
                UtenSpacing.s16,
                0,
              ),
              child: celebration,
            ),
          _PanelBody(
            metrics: metrics,
            todos: todos,
            departmentName: departmentName,
          ),
        ],
      ),
    );
  }
}

/// 面板标题栏：浅底色带内的「今日概览」主标题、部门范围副标题与采样时刻。
/// 主色竖条延续全站分区标题语言，让这块面板在工作台里仍读作一个「区」。
class _PanelHeaderBand extends StatelessWidget {
  const _PanelHeaderBand({
    required this.departmentName,
    required this.generatedAt,
  });

  final String departmentName;
  final DateTime generatedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 口径：范围是「本部门」。
    final scopeLabel = departmentName.isEmpty
        ? '按本部门范围展示'
        : '$departmentName · 按本部门范围展示';
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 30,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '今日概览',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    // 采样时刻（HH:mm）给「这是实时仪表」一个锚点。
                    Text(
                      _sampledAt(generatedAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s2),
                Text(
                  scopeLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板体：宽屏(≥900)指标带与待办并排，指标最多占半幅，避免挤压待办；
/// 实际宽度随内容收缩。窄屏指标带使用全宽，待办移到下方。
class _PanelBody extends StatelessWidget {
  const _PanelBody({
    required this.metrics,
    required this.todos,
    required this.departmentName,
  });

  final List<DashboardMetric> metrics;
  final List<DashboardTodo> todos;
  final String departmentName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strip = _MetricStrip(
      metrics: metrics,
      departmentName: departmentName,
    );
    final todoSide = _TodoSide(todos: todos, departmentName: departmentName);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 900 起两区并排；各区内部仍按实际可用宽度换行。
        if (constraints.maxWidth < 900) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              strip,
              Divider(height: 1, color: colors.outlineVariant),
              todoSide,
            ],
          );
        }
        // 分隔线画在待办区左缘（随其全高）：不能给 Row 套 IntrinsicHeight 拉齐
        // 高度——待办网格的 LayoutBuilder 无法提供 intrinsic 尺寸，会直接断言。
        // 线的位置跟随指标实际内容宽度，不固定居中。
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
              child: strip,
            ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: .6),
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: UtenSpacing.s16),
                  child: todoSide,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 指标按服务端顺序横排，新增指标出现在右侧；空间不足时自然换行。
class _MetricStrip extends StatelessWidget {
  const _MetricStrip({required this.metrics, required this.departmentName});

  final List<DashboardMetric> metrics;
  final String departmentName;

  @override
  Widget build(BuildContext context) {
    return metrics.isEmpty
        ? IntrinsicWidth(
            child: _ZoneEmpty(
              icon: Icons.insights_outlined,
              message: departmentName.isEmpty
                  ? '本部门暂无概览指标'
                  : '$departmentName暂无概览指标',
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s16,
              vertical: UtenSpacing.s12,
            ),
            child: Wrap(
              spacing: UtenSpacing.s24,
              runSpacing: UtenSpacing.s12,
              children: [
                for (final metric in metrics)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: _StripMetric(metric: metric),
                  ),
              ],
            ),
          );
  }
}

class _StripMetric extends StatelessWidget {
  const _StripMetric({required this.metric});
  final DashboardMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final numeric = double.tryParse(metric.value.replaceAll(',', ''));
    final valueStyle = theme.textTheme.headlineMedium?.copyWith(
      fontSize: 24,
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
          // 行内左右居中（2026-09-28 用户口径）；装饰性小图标撤掉，
          // 仅敏感指标保留锁标识（它承载「无权看明细」的含义）。
          child: Column(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      metric.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (metric.sensitive) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: UtenSpacing.s4),
              numeric == null
                  ? Text(metric.value, style: valueStyle)
                  : UtenAnimatedNumber(value: numeric, style: valueStyle),
              if (metric.subtitle.isNotEmpty) ...[
                const SizedBox(height: UtenSpacing.s2),
                // 副标题只给一行，长文案不撑宽指标带。
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    metric.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 待办区：小节头与单行瓦片，剩余待办在独立面板查看。
class _TodoSide extends StatelessWidget {
  const _TodoSide({required this.todos, required this.departmentName});

  final List<DashboardTodo> todos;
  final String departmentName;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TodoZoneHeader(
          // 总数徽章 = 各待办 count 之和（无待办时徽章自身不渲染）。
          total: todos.fold<int>(0, (sum, t) => sum + t.count),
        ),
        if (todos.isEmpty)
          _ZoneEmpty(
            icon: Icons.task_alt_rounded,
            message: departmentName.isEmpty
                ? '本部门当前没有待办'
                : '$departmentName当前没有待办',
          )
        else
          _TodoTileRow(todos: _ordered()),
      ],
    );
  }

  /// 紧急优先，其次临近截止，其余保持服务端顺序。
  List<DashboardTodo> _ordered() {
    return [...todos]..sort((a, b) {
      final urgency = b.urgentCount.compareTo(a.urgentCount);
      if (urgency != 0) return urgency;
      if (a.dueAt != null && b.dueAt != null) {
        return a.dueAt!.compareTo(b.dueAt!);
      }
      return todos.indexOf(a).compareTo(todos.indexOf(b));
    });
  }
}

/// 待办区小节头：区内标题 + 排布说明 + 总数徽章。
class _TodoZoneHeader extends StatelessWidget {
  const _TodoZoneHeader({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s16,
        UtenSpacing.s4,
      ),
      child: Row(
        children: [
          Icon(
            Icons.task_alt_outlined,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s2,
              children: [
                Text(
                  '待办任务',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '按紧急度排布',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          UtenNotificationBadge(count: total, size: 20, showLabel: true),
        ],
      ),
    );
  }
}

/// 待办最多显示一行、两张卡；为剩余任务入口预留同行空间。
class _TodoTileRow extends StatelessWidget {
  const _TodoTileRow({required this.todos});

  final List<DashboardTodo> todos;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        0,
        UtenSpacing.s16,
        UtenSpacing.s16,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.6);
          final minWidth = 300 * scale;
          const gap = UtenSpacing.s12;
          final capacity = ((constraints.maxWidth + gap) / (minWidth + gap))
              .floor()
              .clamp(1, 2);
          final hasMore = todos.length > capacity;
          final moreWidth = hasMore
              ? (120 * scale).clamp(0.0, constraints.maxWidth * .34).toDouble()
              : 0.0;
          final visibleCount = hasMore
              ? ((constraints.maxWidth - moreWidth) / (minWidth + gap))
                    .floor()
                    .clamp(1, capacity)
              : todos.length;
          final remaining = todos.skip(visibleCount).toList();
          final remainingCount = remaining.fold<int>(
            0,
            (sum, todo) => sum + todo.count,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < visibleCount; i++) ...[
                if (i > 0) const SizedBox(width: gap),
                Expanded(
                  child: _TodoTile(
                    key: ValueKey('dashboard-todo-${todos[i].id}'),
                    todo: todos[i],
                  ),
                ),
              ],
              if (remaining.isNotEmpty) ...[
                const SizedBox(width: gap),
                SizedBox(
                  width: moreWidth,
                  child: TextButton(
                    key: const ValueKey('dashboard-todo-more'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s4,
                      ),
                    ),
                    onPressed: () => _showRemaining(context, remaining),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s12,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.more_horiz_rounded),
                          const SizedBox(height: UtenSpacing.s8),
                          Text(
                            AppLocalizations.of(
                              context,
                            ).dashboardMoreTasks(remainingCount),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _showRemaining(
    BuildContext context,
    List<DashboardTodo> remaining,
  ) async {
    final route = await showUtenAdaptivePanel<String>(
      context: context,
      drawerWidth: 520,
      builder: (panelContext) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s8,
              UtenSpacing.s8,
              UtenSpacing.s8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    AppLocalizations.of(panelContext).dashboardMoreTasksTitle,
                    style: Theme.of(panelContext).textTheme.titleMedium,
                  ),
                ),
                CloseButton(onPressed: () => Navigator.pop(panelContext)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              itemCount: remaining.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: UtenSpacing.s12),
              itemBuilder: (context, index) {
                final todo = remaining[index];
                return _TodoTile(
                  key: ValueKey('dashboard-more-todo-${todo.id}'),
                  todo: todo,
                  onTap: todo.route == null
                      ? null
                      : () => Navigator.pop(panelContext, todo.route),
                );
              },
            ),
          ),
        ],
      ),
    );
    // 使用工作台的路由上下文记录来源，先关闭面板再进入办理页。
    if (!context.mounted || route == null) return;
    goFrom(context, route);
  }
}

/// 待办瓦片：面板内的浅底浮块（不自带边框，靠底色与面板表面区分）。
class _TodoTile extends StatelessWidget {
  const _TodoTile({super.key, required this.todo, this.onTap});
  final DashboardTodo todo;
  final VoidCallback? onTap;

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
        child: Material(
          color: theme.colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: UtenRadius.controlAll,
            // hairline 边框：surfaceContainerLow 与面板 surface 的明度差在
            // 浅色/深色下都偏弱，靠细边框补足瓦片边界的可辨性。
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: .45),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: todo.route == null
                ? null
                : onTap ?? () => goFrom(context, todo.route!),
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
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

/// 区内空态：面板内的一行静默说明（面板自身就是容器，不再套子面板）。
class _ZoneEmpty extends StatelessWidget {
  const _ZoneEmpty({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
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

/// 标题栏右上角的采样时刻（HH:mm），给「这是实时仪表」一个锚点。
String _sampledAt(DateTime value) {
  final local = value.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')} 采样';
}
