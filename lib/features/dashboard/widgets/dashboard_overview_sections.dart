import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../notice/widgets/notice_detail_dialog.dart';
import '../models/dashboard_overview.dart';
import '../providers/dashboard_overview_provider.dart';

class DashboardOverviewSections extends ConsumerWidget {
  const DashboardOverviewSections({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(dashboardOverviewProvider);
    return overview.when(
      loading: () => const _LoadingSections(),
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

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});

  final List<DashboardMetric> metrics;

  @override
  Widget build(BuildContext context) {
    if (metrics.isEmpty) {
      return const _EmptyCard(text: '当前权限下暂无概览指标');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1050
            ? 4
            : constraints.maxWidth >= 680
            ? 3
            : constraints.maxWidth >= 420
            ? 2
            : 1;
        final width =
            (constraints.maxWidth - (columns - 1) * UtenSpacing.s12) / columns;
        return Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          children: [
            for (final metric in metrics)
              SizedBox(
                width: width,
                child: Semantics(
                  button: metric.route != null,
                  label: '${metric.title}，${metric.value}，${metric.subtitle}',
                  child: UtenCard(
                    onTap: metric.route == null
                        ? null
                        : () => goFrom(context, metric.route!),
                    child: _MetricContent(metric: metric),
                  ),
                ),
              ),
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

class _PolicyList extends StatelessWidget {
  const _PolicyList({required this.items});

  final List<PolicyBrief> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 840;
        if (!twoColumns) {
          return Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                _PolicyCard(item: items[i]),
                if (i != items.length - 1)
                  const SizedBox(height: UtenSpacing.s8),
              ],
            ],
          );
        }
        return Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          children: [
            for (final item in items)
              SizedBox(
                width: (constraints.maxWidth - UtenSpacing.s12) / 2,
                child: _PolicyCard(item: item),
              ),
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

class _LoadingSections extends StatelessWidget {
  const _LoadingSections();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenSectionHeader(title: '今日概览'),
        SizedBox(height: UtenSpacing.s12),
        LinearProgressIndicator(),
        SizedBox(height: UtenSpacing.s24),
        UtenSectionHeader(title: '待办任务'),
        SizedBox(height: UtenSpacing.s12),
        _EmptyCard(text: '正在加载工作台数据…'),
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
