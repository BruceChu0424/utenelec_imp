import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_lazy_mount.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../notice/widgets/notice_detail_dialog.dart';
import '../models/dashboard_overview.dart';
import '../providers/dashboard_overview_provider.dart';

class DashboardOverviewSections extends StatelessWidget {
  const DashboardOverviewSections({super.key});

  @override
  Widget build(BuildContext context) {
    // 延迟挂载：首帧只画骨架、不 watch dashboardOverviewProvider、不发那个重聚合
    // 请求；首帧绘制完后再构建 _DashboardOverviewBody 并行加载，避免进工作台时卡顿。
    // 范式同全项目 addPostFrameCallback「首帧让路」惯例。
    return UtenLazyMount(
      placeholder: (_) => const _DashboardOverviewSkeleton(),
      builder: (_) => const _DashboardOverviewBody(),
    );
  }
}

/// 概览数据体（首帧后才挂载）：watch dashboardOverviewProvider；loading 时仍用骨架，
/// 与 LazyMount 首帧占位视觉一致、无闪烁切换。
class _DashboardOverviewBody extends ConsumerWidget {
  const _DashboardOverviewBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(dashboardOverviewProvider);
    return overview.when(
      loading: () => const _DashboardOverviewSkeleton(),
      error: (error, _) =>
          _ErrorCard(onRetry: () => ref.invalidate(dashboardOverviewProvider)),
      data: (data) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenSectionHeader(
            title: data.departmentName.isEmpty
                ? '今日概览'
                : '今日概览 · ${data.departmentName}',
            trailing: const Text('按本人权限展示'),
          ),
          const SizedBox(height: UtenSpacing.s12),
          _MetricGrid(metrics: data.metrics),
          const SizedBox(height: UtenSpacing.s24),
          const UtenSectionHeader(title: '待办任务'),
          const SizedBox(height: UtenSpacing.s12),
          _TodoList(todos: data.todos),
          if (data.intelligence.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s24),
            const UtenSectionHeader(
              title: '政策与监管动态',
              trailing: Text('仅收录政府官网'),
            ),
            const SizedBox(height: UtenSpacing.s12),
            _PolicyList(items: data.intelligence),
          ],
        ],
      ),
    );
  }
}

class _MetricGrid extends StatefulWidget {
  const _MetricGrid({required this.metrics});

  final List<DashboardMetric> metrics;

  @override
  State<_MetricGrid> createState() => _MetricGridState();
}

class _MetricGridState extends State<_MetricGrid> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final metrics = widget.metrics;
    if (metrics.isEmpty) {
      return const _EmptyCard(text: '当前权限下暂无概览指标');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 列数随容器宽度实时变化，收起时只展示一行；
        // 超出一行的指标通过末尾「加载更多」展开。
        final columns = constraints.maxWidth >= 1050
            ? 4
            : constraints.maxWidth >= 680
            ? 3
            : constraints.maxWidth >= 420
            ? 2
            : 1;
        final overflow = metrics.length > columns;
        final visible = _expanded ? metrics : metrics.take(columns).toList();
        final hiddenCount = metrics.length - visible.length;
        final width =
            (constraints.maxWidth - (columns - 1) * UtenSpacing.s12) / columns;
        return Column(
          children: [
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s12,
              children: [
                for (final metric in visible)
                  SizedBox(
                    width: width,
                    child: Semantics(
                      button: metric.route != null,
                      label:
                          '${metric.title}，${metric.value}，${metric.subtitle}',
                      child: UtenCard(
                        onTap: metric.route == null
                            ? null
                            : () => goFrom(context, metric.route!),
                        child: _MetricContent(metric: metric),
                      ),
                    ),
                  ),
              ],
            ),
            if (overflow) ...[
              const SizedBox(height: UtenSpacing.s8),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(
                    _expanded ? '收起' : '加载更多（还有 $hiddenCount 项）',
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _MetricContent extends StatelessWidget {
  const _MetricContent({required this.metric});

  final DashboardMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _toneColor(theme, metric.tone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              metric.sensitive
                  ? Icons.lock_outline_rounded
                  : _metricIcon(metric.id),
              size: 18,
              color: color,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                metric.title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          metric.value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.onSurface,
          ),
        ),
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
    );
  }
}

class _TodoList extends StatelessWidget {
  const _TodoList({required this.todos});

  final List<DashboardTodo> todos;

  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) {
      return const _EmptyCard(text: '当前没有待办任务', icon: Icons.task_alt_rounded);
    }
    return Column(
      children: [
        for (var index = 0; index < todos.length; index++) ...[
          _TodoCard(todo: todos[index]),
          if (index != todos.length - 1) const SizedBox(height: UtenSpacing.s8),
        ],
      ],
    );
  }
}

class _TodoCard extends StatelessWidget {
  const _TodoCard({required this.todo});

  final DashboardTodo todo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _toneColor(theme, todo.tone);
    return Semantics(
      button: true,
      label: '${todo.title}。${todo.summary}',
      child: UtenCard(
        padding: EdgeInsets.zero,
        onTap: () => _open(context),
        child: ListTile(
          minTileHeight: 76,
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.12),
            foregroundColor: color,
            child: Icon(
              todo.sourceType == 'NOTICE'
                  ? Icons.notification_important_outlined
                  : Icons.assignment_outlined,
            ),
          ),
          title: Text(
            todo.title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(todo.summary),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    if (todo.sourceType == 'NOTICE' && todo.sourceId != null) {
      showNoticeDetailDialog(context, noticeId: todo.sourceId!);
      return;
    }
    if (todo.route != null) goFrom(context, todo.route!);
  }
}

class _PolicyList extends StatefulWidget {
  const _PolicyList({required this.items});

  final List<PolicyBrief> items;

  @override
  State<_PolicyList> createState() => _PolicyListState();
}

class _PolicyListState extends State<_PolicyList> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 列数随容器宽度实时变化（窗口拉宽/拉窄都会触发 LayoutBuilder 重建），
        // 收起时只展示一行；超出一行的内容通过末尾「加载更多」展开。
        final columns = constraints.maxWidth >= 840 ? 2 : 1;
        final overflow = items.length > columns;
        final visible = _expanded ? items : items.take(columns).toList();
        final hiddenCount = items.length - visible.length;
        return Column(
          children: [
            if (columns == 1)
              Column(
                children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    _PolicyCard(item: visible[i]),
                    if (i != visible.length - 1)
                      const SizedBox(height: UtenSpacing.s8),
                  ],
                ],
              )
            else
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s12,
                children: [
                  for (final item in visible)
                    SizedBox(
                      width: (constraints.maxWidth - UtenSpacing.s12) / 2,
                      child: _PolicyCard(item: item),
                    ),
                ],
              ),
            if (overflow) ...[
              const SizedBox(height: UtenSpacing.s8),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(
                    _expanded ? '收起' : '加载更多（还有 $hiddenCount 条）',
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PolicyCard extends StatelessWidget {
  const _PolicyCard({required this.item});

  final PolicyBrief item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '${item.title}，来源 ${item.sourceName}',
      child: UtenCard(
        onTap: () => _showPolicyDetail(context, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _CategoryBadge(category: item.category),
                const Spacer(),
                Text(
                  _date(item.publishedOn),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              item.summary,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            Row(
              children: [
                const Icon(Icons.verified_outlined, size: 16),
                const SizedBox(width: UtenSpacing.s4),
                Expanded(
                  child: Text(
                    item.sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const Icon(Icons.open_in_new_rounded, size: 16),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: UtenRadius.pillAll,
      ),
      child: Text(
        _categoryLabel(category),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 概览骨架占位：今日概览（一行指标灰卡）+ 待办任务（两行灰条）。
/// LazyMount 首帧占位 与 _DashboardOverviewBody 的 loading 分支共用，视觉连续无闪烁。
/// 政策与监管动态段按真实数据非空才渲染，骨架省略其占位，避免无数据时「先显后隐」。
class _DashboardOverviewSkeleton extends StatelessWidget {
  const _DashboardOverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenSectionHeader(title: '今日概览'),
        SizedBox(height: UtenSpacing.s12),
        _MetricSkeleton(),
        SizedBox(height: UtenSpacing.s24),
        UtenSectionHeader(title: '待办任务'),
        SizedBox(height: UtenSpacing.s12),
        _TodoSkeleton(),
      ],
    );
  }
}

class _MetricSkeleton extends StatelessWidget {
  const _MetricSkeleton();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s12,
      children: [
        for (var i = 0; i < 4; i++)
          const SizedBox(
            width: 220,
            child: UtenCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UtenSkeleton(width: 80, height: 12),
                  SizedBox(height: UtenSpacing.s12),
                  UtenSkeleton(width: 120, height: 22),
                  SizedBox(height: UtenSpacing.s4),
                  UtenSkeleton(height: 12),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _TodoSkeleton extends StatelessWidget {
  const _TodoSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 2; i++) ...[
          const UtenCard(
            padding: EdgeInsets.zero,
            child: ListTile(
              minTileHeight: 76,
              leading: UtenSkeleton(width: 40, height: 40, borderRadius: 20),
              title: UtenSkeleton(height: 14),
              subtitle: Padding(
                padding: EdgeInsets.only(top: UtenSpacing.s4),
                child: UtenSkeleton(height: 12),
              ),
            ),
          ),
          if (i != 1) const SizedBox(height: UtenSpacing.s8),
        ],
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: UtenSpacing.s12),
          const Expanded(child: Text('工作台数据暂时加载失败')),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.text, this.icon = Icons.inbox_outlined});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s8),
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showPolicyDetail(BuildContext context, PolicyBrief item) async {
  final content = _PolicyDetail(item: item);
  if (context.breakpoint.isCompact) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => content,
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: content,
        ),
      ),
    );
  }
}

class _PolicyDetail extends StatelessWidget {
  const _PolicyDetail({required this.item});

  final PolicyBrief item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(UtenSpacing.s24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CategoryBadge(category: item.category),
          const SizedBox(height: UtenSpacing.s12),
          Text(item.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '${item.sourceName} · ${_date(item.publishedOn)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Divider(height: UtenSpacing.s32),
          Text(item.summary, style: theme.textTheme.bodyLarge),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            '提示：摘要用于筛选信息，适用资格、申报期限与材料要求请以官方原文及主管部门答复为准。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openOfficialSource(context, item.sourceUrl),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('查看官方原文'),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _openOfficialSource(BuildContext context, String sourceUrl) async {
  final uri = Uri.tryParse(sourceUrl);
  if (uri == null ||
      uri.scheme != 'https' ||
      !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    if (context.mounted) context.appError('无法打开官方原文链接');
  }
}

Color _toneColor(ThemeData theme, String tone) => switch (tone) {
  'danger' => theme.colorScheme.error,
  'warning' => const Color(0xFFD97706),
  'success' => const Color(0xFF059669),
  'info' => theme.colorScheme.primary,
  _ => theme.colorScheme.onSurfaceVariant,
};

IconData _metricIcon(String id) {
  if (id.contains('production')) return Icons.precision_manufacturing_outlined;
  if (id.contains('sales')) return Icons.receipt_long_outlined;
  if (id.contains('notice')) return Icons.notifications_none_rounded;
  if (id.contains('ar-')) return Icons.south_west_rounded;
  if (id.contains('ap-')) return Icons.north_east_rounded;
  return Icons.insights_outlined;
}

String _categoryLabel(String value) => switch (value) {
  'TAX' => '税费',
  'SUBSIDY' => '补贴',
  'EXPORT' => '出口退税',
  'INSPECTION' => '检查',
  'SAFETY' => '安全生产',
  'QUALITY' => '质量监管',
  _ => '政策动态',
};

String _date(DateTime? value) {
  if (value == null) return '日期见原文';
  return '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
